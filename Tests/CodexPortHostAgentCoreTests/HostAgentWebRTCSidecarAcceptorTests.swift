import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentWebRTCSidecarAcceptorAcceptsOfferAndBridgesDataChannelFrames() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let session = RelayP2POpenSessionResponse(
        sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let offer = RelayP2PSignalingMessageDTO(
        from: .device,
        to: .host,
        kind: .offer,
        payload: #"{"type":"offer","sdp":"v=0\r\ndevice-offer"}"#
    )
    let sidecar = RecordingWebRTCSidecarProcess()
    let acceptor = HostAgentWebRTCSidecarAcceptor(
        configuration: WebRTCSidecarConfiguration(
            command: HostAgentProcessCommand(executablePath: "/usr/bin/false"),
            iceConfiguration: WebRTCRuntimeConfiguration(iceServers: [
                WebRTCICEServerConfiguration(
                    urls: ["turn:turn.example.test:3478?transport=udp"],
                    username: "turn-user",
                    credential: "turn-secret"
                ),
            ])
        ),
        process: sidecar
    )

    let acceptTask = Task {
        try await acceptor.accept(HostAgentP2PAcceptRequest(session: session, offer: offer))
    }
    let acceptRequest = try await sidecar.waitForMessage(type: .accept)
    #expect(acceptRequest.sessionID == session.sessionID)
    #expect(acceptRequest.hostID == hostID)
    #expect(acceptRequest.deviceID == deviceID)
    #expect(acceptRequest.offer == offer)
    #expect(acceptRequest.iceConfiguration != nil)

    sidecar.deliver(WebRTCSidecarMessage(
        type: .accepted,
        sessionID: session.sessionID,
        answer: RelayP2PSignalingMessageDTO(
            from: .host,
            to: .device,
            kind: .answer,
            payload: #"{"type":"answer","sdp":"v=0\r\nhost-answer"}"#
        ),
        iceCandidates: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .iceCandidate,
                payload: #"{"sdp":"candidate:host-initial","sdpMid":"0","sdpMLineIndex":0}"#
            ),
        ]
    ))

    let response = try await acceptTask.value
    #expect(response.answer == RelayP2PSignalingMessageDTO(
        from: .host,
        to: .device,
        kind: .answer,
        payload: #"{"type":"answer","sdp":"v=0\r\nhost-answer"}"#
    ))
    #expect(response.iceCandidates == [
        RelayP2PSignalingMessageDTO(
            from: .host,
            to: .device,
            kind: .iceCandidate,
            payload: #"{"sdp":"candidate:host-initial","sdpMid":"0","sdpMLineIndex":0}"#
        ),
    ])

    var localICEIterator = response.localICECandidateUpdates.makeAsyncIterator()
    sidecar.deliver(WebRTCSidecarMessage(
        type: .localICE,
        sessionID: session.sessionID,
        candidate: RelayP2PSignalingMessageDTO(
            from: .host,
            to: .device,
            kind: .iceCandidate,
            payload: #"{"sdp":"candidate:host-follow-up","sdpMid":"0","sdpMLineIndex":0}"#
        )
    ))
    #expect(await localICEIterator.next() == RelayP2PSignalingMessageDTO(
        from: .host,
        to: .device,
        kind: .iceCandidate,
        payload: #"{"sdp":"candidate:host-follow-up","sdpMid":"0","sdpMLineIndex":0}"#
    ))

    sidecar.deliver(WebRTCSidecarMessage(
        type: .dataChannelState,
        sessionID: session.sessionID,
        state: "dataChannelOpen"
    ))
    sidecar.deliver(WebRTCSidecarMessage(
        type: .dataChannelMessage,
        sessionID: session.sessionID,
        base64: Data("hello-from-device".utf8).base64EncodedString()
    ))

    var stateIterator = response.dataChannel.stateUpdates.makeAsyncIterator()
    var messageIterator = response.dataChannel.incomingMessages.makeAsyncIterator()
    #expect(await stateIterator.next() == .dataChannelOpen)
    #expect(await messageIterator.next() == Data("hello-from-device".utf8))

    try await response.dataChannel.send(Data("hello-from-host".utf8))
    let sendRequest = try await sidecar.waitForMessage(type: .dataChannelSend)
    #expect(sendRequest.sessionID == session.sessionID)
    #expect(sendRequest.base64 == Data("hello-from-host".utf8).base64EncodedString())
}

@Test func hostAgentWebRTCSidecarAcceptorForwardsRemoteICEToSidecar() async throws {
    let session = RelayP2POpenSessionResponse(
        sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        pairingRecordID: "pairing-record",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let sidecar = RecordingWebRTCSidecarProcess()
    let acceptor = HostAgentWebRTCSidecarAcceptor(
        configuration: WebRTCSidecarConfiguration(
            command: HostAgentProcessCommand(executablePath: "/usr/bin/false"),
            iceConfiguration: WebRTCRuntimeConfiguration(iceServers: [])
        ),
        process: sidecar
    )
    let acceptTask = Task {
        try await acceptor.accept(HostAgentP2PAcceptRequest(
            session: session,
            offer: RelayP2PSignalingMessageDTO(from: .device, to: .host, kind: .offer, payload: "offer")
        ))
    }
    _ = try await sidecar.waitForMessage(type: .accept)
    sidecar.deliver(WebRTCSidecarMessage(
        type: .accepted,
        sessionID: session.sessionID,
        answer: RelayP2PSignalingMessageDTO(
            from: .host,
            to: .device,
            kind: .answer,
            payload: "answer"
        ),
        iceCandidates: []
    ))
    let response = try await acceptTask.value

    let remoteICE = RelayP2PSignalingMessageDTO(
        from: .device,
        to: .host,
        kind: .iceCandidate,
        payload: #"{"sdp":"candidate:device-follow-up","sdpMid":"0","sdpMLineIndex":0}"#
    )
    try await acceptor.addRemoteICECandidate(remoteICE, sessionID: session.sessionID, to: response.dataChannel)

    let remoteICERequest = try await sidecar.waitForMessage(type: .remoteICE)
    #expect(remoteICERequest.sessionID == session.sessionID)
    #expect(remoteICERequest.candidate == remoteICE)
}

private final class RecordingWebRTCSidecarProcess: HostAgentWebRTCSidecarProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var sentMessages: [WebRTCSidecarMessage] = []
    private let inboundContinuation: AsyncStream<WebRTCSidecarMessage>.Continuation
    let messages: AsyncStream<WebRTCSidecarMessage>

    init() {
        var continuation: AsyncStream<WebRTCSidecarMessage>.Continuation!
        messages = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        inboundContinuation = continuation
    }

    func start(command: HostAgentProcessCommand) async throws {}

    func send(_ message: WebRTCSidecarMessage) async throws {
        lock.withLock {
            sentMessages.append(message)
        }
    }

    func stop() async {}

    func deliver(_ message: WebRTCSidecarMessage) {
        inboundContinuation.yield(message)
    }

    func waitForMessage(type: WebRTCSidecarMessage.MessageType) async throws -> WebRTCSidecarMessage {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let message = lock.withLock({ sentMessages.first(where: { $0.type == type }) }) {
                return message
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RecordingWebRTCSidecarProcessError.timedOut(type)
    }
}

private enum RecordingWebRTCSidecarProcessError: Error, CustomStringConvertible {
    case timedOut(WebRTCSidecarMessage.MessageType)

    var description: String {
        switch self {
        case let .timedOut(type):
            return "Timed out waiting for sidecar message \(type)"
        }
    }
}
