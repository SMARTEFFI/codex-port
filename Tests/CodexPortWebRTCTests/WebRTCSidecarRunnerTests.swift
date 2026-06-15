import Foundation
import Testing
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func webRTCSidecarRunnerAcceptsOfferAndForwardsMessages() async throws {
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let dataChannel = SidecarRunnerRecordingDataChannel()
    let runtime = SidecarRunnerRecordingRuntime(
        result: WebRTCPlatformDataChannelAcceptResult(
            answer: WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nhost-answer"),
            localICECandidates: [
                WebRTCICECandidatePayload(sdp: "candidate:host-initial", sdpMid: "0", sdpMLineIndex: 0),
            ],
            localICECandidateUpdates: AsyncStream { continuation in
                Task {
                    try await Task.sleep(for: .milliseconds(20))
                    continuation.yield(WebRTCICECandidatePayload(sdp: "candidate:host-follow-up", sdpMid: "0", sdpMLineIndex: 0))
                    continuation.finish()
                }
            },
            dataChannel: dataChannel
        )
    )
    let io = SidecarRunnerRecordingIO()
    let runner = WebRTCSidecarRunner(runtime: runtime, io: io)
    let runnerTask = Task {
        await runner.run()
    }

    try await io.deliver(WebRTCSidecarMessage(
        type: .accept,
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        offer: RelayP2PSignalingMessageDTO(
            from: .device,
            to: .host,
            kind: .offer,
            payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\ndevice-offer"))
        ),
        iceConfiguration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["turn:turn.example.test:3478"], username: "u", credential: "p"),
        ])
    ))

    let accepted = try await io.waitForMessage(type: .accepted)
    #expect(accepted.sessionID == sessionID)
    #expect(accepted.answer?.from == .host)
    #expect(accepted.answer?.to == .device)
    #expect(accepted.answer?.kind == .answer)
    #expect(try accepted.answer.map { try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription($0.payload) } == WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nhost-answer"))
    #expect(accepted.iceCandidates?.map(\.from) == [.host])
    #expect(accepted.iceCandidates?.map(\.to) == [.device])
    #expect(accepted.iceCandidates?.map(\.kind) == [.iceCandidate])
    #expect(try accepted.iceCandidates?.map { try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate($0.payload) } == [
        WebRTCICECandidatePayload(sdp: "candidate:host-initial", sdpMid: "0", sdpMLineIndex: 0),
    ])
    #expect(await runtime.acceptedOffers == [
        WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\ndevice-offer"),
    ])

    let localICE = try await io.waitForMessage(type: .localICE)
    #expect(localICE.candidate?.from == .host)
    #expect(localICE.candidate?.to == .device)
    #expect(localICE.candidate?.kind == .iceCandidate)
    #expect(try localICE.candidate.map { try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate($0.payload) } == WebRTCICECandidatePayload(sdp: "candidate:host-follow-up", sdpMid: "0", sdpMLineIndex: 0))

    await dataChannel.deliver(.dataChannelOpen)
    await dataChannel.deliver(Data("device-to-host".utf8))
    let state = try await io.waitForMessage(type: .dataChannelState)
    let incoming = try await io.waitForMessage(type: .dataChannelMessage)
    #expect(state.state == "dataChannelOpen")
    #expect(incoming.base64 == Data("device-to-host".utf8).base64EncodedString())

    try await io.deliver(WebRTCSidecarMessage(
        type: .remoteICE,
        sessionID: sessionID,
        candidate: RelayP2PSignalingMessageDTO(
            from: .device,
            to: .host,
            kind: .iceCandidate,
            payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(WebRTCICECandidatePayload(sdp: "candidate:device-follow-up", sdpMid: "0", sdpMLineIndex: 0))
        )
    ))
    try await runtime.waitForRemoteICECount(1)
    #expect(await runtime.addedRemoteICE == [
        WebRTCICECandidatePayload(sdp: "candidate:device-follow-up", sdpMid: "0", sdpMLineIndex: 0),
    ])

    try await io.deliver(WebRTCSidecarMessage(
        type: .dataChannelSend,
        sessionID: sessionID,
        base64: Data("host-to-device".utf8).base64EncodedString()
    ))
    try await dataChannel.waitForSentMessageCount(1)
    #expect(await dataChannel.sentMessages == [Data("host-to-device".utf8)])

    await io.finish()
    await runnerTask.value
}

private actor SidecarRunnerRecordingRuntime: WebRTCPlatformDataChannelAccepting {
    private let result: WebRTCPlatformDataChannelAcceptResult
    private(set) var acceptedOffers: [WebRTCSessionDescriptionPayload] = []
    private(set) var addedRemoteICE: [WebRTCICECandidatePayload] = []

    init(result: WebRTCPlatformDataChannelAcceptResult) {
        self.result = result
    }

    func acceptDataChannel(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelAcceptResult {
        acceptedOffers.append(offer)
        return result
    }

    func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        addedRemoteICE.append(candidate)
    }

    func waitForRemoteICECount(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if addedRemoteICE.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SidecarRunnerTestError.timedOut("remote ICE")
    }
}

private actor SidecarRunnerRecordingDataChannel: WebRTCDataChannelTransport {
    nonisolated let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    nonisolated let incomingMessages: AsyncStream<Data>
    nonisolated let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private(set) var sentMessages: [Data] = []

    init() {
        var incomingContinuation: AsyncStream<Data>.Continuation!
        incomingMessages = AsyncStream { continuation in
            incomingContinuation = continuation
        }
        self.incomingContinuation = incomingContinuation
        var stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation!
        stateUpdates = AsyncStream { continuation in
            stateContinuation = continuation
        }
        self.stateContinuation = stateContinuation
    }

    func send(_ message: Data) async throws {
        sentMessages.append(message)
    }

    func deliver(_ message: Data) {
        incomingContinuation.yield(message)
    }

    func deliver(_ state: WebRTCDataChannelConnectionState) {
        stateContinuation.yield(state)
    }

    func waitForSentMessageCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if sentMessages.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SidecarRunnerTestError.timedOut("sent message")
    }
}

private actor SidecarRunnerRecordingIO: WebRTCSidecarInputOutput {
    nonisolated let inputLines: AsyncStream<String>
    private let inputContinuation: AsyncStream<String>.Continuation
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var outputMessages: [WebRTCSidecarMessage] = []

    init() {
        var inputContinuation: AsyncStream<String>.Continuation!
        inputLines = AsyncStream { continuation in
            inputContinuation = continuation
        }
        self.inputContinuation = inputContinuation
    }

    func sendLine(_ line: String) async throws {
        guard let data = line.data(using: .utf8) else { return }
        outputMessages.append(try decoder.decode(WebRTCSidecarMessage.self, from: data))
    }

    func deliver(_ message: WebRTCSidecarMessage) async throws {
        inputContinuation.yield(String(decoding: try encoder.encode(message), as: UTF8.self))
    }

    func finish() {
        inputContinuation.finish()
    }

    func waitForMessage(type: WebRTCSidecarMessage.MessageType) async throws -> WebRTCSidecarMessage {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let message = outputMessages.first(where: { $0.type == type }) {
                return message
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SidecarRunnerTestError.timedOut(type.rawValue)
    }
}

private enum SidecarRunnerTestError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case let .timedOut(value):
            return "Timed out waiting for \(value)"
        }
    }
}
