import Foundation
import CodexPortShared

#if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(WebRTC)
import WebRTC

public final class WebRTCSDKRuntime: WebRTCPlatformDataChannelOpening, WebRTCPlatformDataChannelAccepting, @unchecked Sendable {
    private let factory: RTCPeerConnectionFactory

    public init(factory: RTCPeerConnectionFactory = WebRTCSDKRuntime.makePeerConnectionFactory()) {
        self.factory = factory
    }

    public func openDataChannel(
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        let transport = try WebRTCSDKDataChannelTransport(
            factory: factory,
            role: .offerer,
            configuration: configuration
        )
        let offer = try await transport.createOffer()
        let localCandidates = await transport.localICECandidatesSnapshot()
        return WebRTCPlatformDataChannelOpenResult(
            offer: offer,
            localICECandidates: localCandidates,
            localICECandidateUpdates: transport.localICECandidateUpdates,
            dataChannel: transport
        )
    }

    public func applyRemoteAnswer(
        _ answer: WebRTCSessionDescriptionPayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        guard let transport = dataChannel as? WebRTCSDKDataChannelTransport else {
            throw WebRTCSDKRuntimeError.unsupportedTransport
        }
        try await transport.applyRemoteDescription(answer)
    }

    public func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        guard let transport = dataChannel as? WebRTCSDKDataChannelTransport else {
            throw WebRTCSDKRuntimeError.unsupportedTransport
        }
        try await transport.addRemoteICECandidate(candidate)
    }

    public func acceptDataChannel(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelAcceptResult {
        let transport = try WebRTCSDKDataChannelTransport(
            factory: factory,
            role: .answerer,
            configuration: configuration
        )
        try await transport.applyRemoteDescription(offer)
        let answer = try await transport.createAnswer()
        let localCandidates = await transport.localICECandidatesSnapshot()
        return WebRTCPlatformDataChannelAcceptResult(
            answer: answer,
            localICECandidates: localCandidates,
            localICECandidateUpdates: transport.localICECandidateUpdates,
            dataChannel: transport
        )
    }

    public static func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }
}

public enum WebRTCSDKRuntimeError: Error, Equatable, Sendable {
    case unsupportedTransport
    case peerConnectionCreationFailed
    case dataChannelCreationFailed
    case invalidSDPType(String)
}

public final class WebRTCSDKDataChannelTransport:
    NSObject,
    WebRTCDataChannelTransport,
    RTCPeerConnectionDelegate,
    RTCDataChannelDelegate,
    @unchecked Sendable
{
    fileprivate enum Role: Sendable {
        case offerer
        case answerer
    }

    public let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    public let incomingMessages: AsyncStream<Data>
    public let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>
    fileprivate let localICECandidateUpdates: AsyncStream<WebRTCICECandidatePayload>

    private let lock = NSLock()
    private let peerConnection: RTCPeerConnection
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private let localICEContinuation: AsyncStream<WebRTCICECandidatePayload>.Continuation
    private var dataChannel: RTCDataChannel?
    private var localICECandidates: [WebRTCICECandidatePayload] = []

    fileprivate init(
        factory: RTCPeerConnectionFactory,
        role: Role,
        configuration: WebRTCRuntimeConfiguration
    ) throws {
        var incomingContinuation: AsyncStream<Data>.Continuation?
        self.incomingMessages = AsyncStream<Data> { continuation in
            incomingContinuation = continuation
        }
        var stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        self.stateUpdates = AsyncStream<WebRTCDataChannelConnectionState> { continuation in
            stateContinuation = continuation
        }
        var localICEContinuation: AsyncStream<WebRTCICECandidatePayload>.Continuation?
        self.localICECandidateUpdates = AsyncStream<WebRTCICECandidatePayload> { continuation in
            localICEContinuation = continuation
        }
        self.incomingContinuation = incomingContinuation!
        self.stateContinuation = stateContinuation!
        self.localICEContinuation = localICEContinuation!

        let rtcConfiguration = RTCConfiguration()
        rtcConfiguration.iceServers = configuration.iceServers.map { server in
            RTCIceServer(
                urlStrings: server.urls,
                username: server.username,
                credential: server.credential
            )
        }
        rtcConfiguration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peerConnection = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw WebRTCSDKRuntimeError.peerConnectionCreationFailed
        }
        self.peerConnection = peerConnection
        super.init()
        self.peerConnection.delegate = self

        if role == .offerer {
            let dataChannelConfiguration = RTCDataChannelConfiguration()
            dataChannelConfiguration.isOrdered = true
            guard let channel = peerConnection.dataChannel(
                forLabel: configuration.dataChannelLabel,
                configuration: dataChannelConfiguration
            ) else {
                throw WebRTCSDKRuntimeError.dataChannelCreationFailed
            }
            channel.delegate = self
            dataChannel = channel
        }
        self.stateContinuation.yield(.iceGathering)
    }

    public func send(_ message: Data) async throws {
        let channel = lock.withLock { dataChannel }
        guard let channel else {
            throw WebRTCDataChannelTransportError.dataChannelNotOpen
        }
        switch channel.readyState {
        case .open:
            let buffer = RTCDataBuffer(data: message, isBinary: true)
            if !channel.sendData(buffer) {
                throw WebRTCDataChannelTransportError.dataChannelClosed
            }
        case .closing, .closed:
            throw WebRTCDataChannelTransportError.dataChannelClosed
        case .connecting:
            throw WebRTCDataChannelTransportError.dataChannelNotOpen
        @unknown default:
            throw WebRTCDataChannelTransportError.dataChannelNotOpen
        }
    }

    fileprivate func createOffer() async throws -> WebRTCSessionDescriptionPayload {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let description = try await peerConnection.offer(for: constraints)
        try await setLocalDescription(description)
        return WebRTCSessionDescriptionPayload(type: .offer, sdp: description.sdp)
    }

    fileprivate func createAnswer() async throws -> WebRTCSessionDescriptionPayload {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let description = try await peerConnection.answer(for: constraints)
        try await setLocalDescription(description)
        return WebRTCSessionDescriptionPayload(type: .answer, sdp: description.sdp)
    }

    fileprivate func applyRemoteDescription(_ payload: WebRTCSessionDescriptionPayload) async throws {
        let description = try RTCSessionDescription(
            type: Self.rtcSDPType(payload.type),
            sdp: payload.sdp
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    fileprivate func addRemoteICECandidate(_ payload: WebRTCICECandidatePayload) async throws {
        let candidate = RTCIceCandidate(
            sdp: payload.sdp,
            sdpMLineIndex: payload.sdpMLineIndex,
            sdpMid: payload.sdpMid
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    fileprivate func localICECandidatesSnapshot() async -> [WebRTCICECandidatePayload] {
        lock.withLock { localICECandidates }
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func rtcSDPType(_ type: WebRTCSDPType) throws -> RTCSdpType {
        switch type {
        case .offer:
            return .offer
        case .answer:
            return .answer
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .checking:
            stateContinuation.yield(.iceGathering)
        case .connected, .completed:
            stateContinuation.yield(.directConnected)
        case .failed:
            stateContinuation.yield(.directFailed(reason: "ICE connection failed"))
        case .disconnected, .closed:
            stateContinuation.yield(.dataChannelClosed)
        case .new, .count:
            break
        @unknown default:
            break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .gathering {
            stateContinuation.yield(.iceGathering)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload = WebRTCICECandidatePayload(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        lock.withLock {
            localICECandidates.append(payload)
        }
        localICEContinuation.yield(payload)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        lock.withLock {
            self.dataChannel = dataChannel
        }
        dataChannel.delegate = self
    }

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            stateContinuation.yield(.dataChannelOpen)
        case .closing, .closed:
            stateContinuation.yield(.dataChannelClosed)
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        incomingContinuation.yield(buffer.data)
    }
}
#endif
