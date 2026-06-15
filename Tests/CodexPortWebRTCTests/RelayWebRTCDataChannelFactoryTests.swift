import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func relayWebRTCDataChannelFactoryForwardsTrickleICEInBothDirections() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let localCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:local 1 udp 2122260223 192.0.2.10 54545 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let followUpLocalCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:local-follow-up 1 udp 2122260223 192.0.2.12 54547 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let remoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:remote 1 udp 2122260223 192.0.2.11 54546 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let followUpRemoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:remote-follow-up 1 udp 2122260223 192.0.2.13 54548 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessageBatches: [
            [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .answer,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
                ),
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteCandidate)
                ),
            ],
            [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(followUpRemoteCandidate)
                ),
            ],
        ]
    )
    let localICEUpdateStream = AsyncStream<WebRTCICECandidatePayload> { continuation in
        Task {
            try await Task.sleep(for: .milliseconds(10))
            continuation.yield(followUpLocalCandidate)
            continuation.finish()
        }
    }
    let dataChannel = RecordingWebRTCDataChannelTransport()
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [localCandidate],
            localICECandidateUpdates: localICEUpdateStream,
            dataChannel: dataChannel
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
        ]),
        runtime: runtime,
        answerTimeout: .milliseconds(250),
        remoteICEPollingDuration: .milliseconds(250)
    )

    let opened = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: session
    ))
    try await signalingHTTP.waitForSentMessageCount(3)
    try await runtime.waitForAddedCandidateCount(2)
    try await opened.send(Data("keep-alive".utf8))

    #expect(await runtime.openedSessions == [session])
    #expect(await runtime.appliedAnswers == [remoteAnswer])
    #expect(await runtime.addedCandidates == [remoteCandidate, followUpRemoteCandidate])
    #expect(signalingHTTP.sentMessages.map(\.kind) == [.offer, .iceCandidate, .iceCandidate])
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(signalingHTTP.sentMessages[0].payload).type == .offer)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(signalingHTTP.sentMessages[1].payload) == localCandidate)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(signalingHTTP.sentMessages[2].payload) == followUpLocalCandidate)
}

@Test func relayWebRTCDataChannelFactorySendsOfferAndLocalICEThenAppliesRemoteAnswerAndICE() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let localCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:local 1 udp 2122260223 192.0.2.10 54545 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let remoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:remote 1 udp 2122260223 192.0.2.11 54546 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .iceCandidate,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteCandidate)
            ),
        ]
    )
    let dataChannel = RecordingWebRTCDataChannelTransport()
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [localCandidate],
            dataChannel: dataChannel
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
        ]),
        runtime: runtime,
        answerTimeout: .milliseconds(250)
    )

    let opened = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: session
    ))

    try await opened.send(Data("ping".utf8))
    #expect(dataChannel.sentMessages == [Data("ping".utf8)])
    #expect(await runtime.openedSessions == [session])
    #expect(await runtime.appliedAnswers == [remoteAnswer])
    #expect(await runtime.addedCandidates == [remoteCandidate])
    #expect(signalingHTTP.sentMessages.map(\.kind) == [.offer, .iceCandidate])
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(signalingHTTP.sentMessages[0].payload).type == .offer)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(signalingHTTP.sentMessages[1].payload) == localCandidate)
}

@Test func relayWebRTCDataChannelFactoryWaitsForDataChannelOpenBeforeReturning() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
        ]
    )
    let dataChannel = RecordingWebRTCDataChannelTransport(autoOpen: false)
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [],
            dataChannel: dataChannel
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: runtime,
        answerTimeout: .milliseconds(250),
        dataChannelOpenTimeout: .seconds(1)
    )

    let completion = RelayWebRTCDataChannelOpenCompletionProbe()
    let openTask = Task {
        let transport = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
            relayHost: relayHost,
            session: session
        ))
        await completion.markFinished()
        return transport
    }

    try await signalingHTTP.waitForSentMessageCount(1)
    try await runtime.waitForAppliedAnswerCount(1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await completion.isFinished == false)

    dataChannel.deliverState(.dataChannelOpen)
    let opened = try await openTask.value
    try await opened.send(Data("after-open".utf8))

    #expect(dataChannel.sentMessages == [Data("after-open".utf8)])
}

@Test func relayWebRTCDataChannelFactoryTimesOutWhenHostNeverAnswers() async throws {
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
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(remoteMessages: [])
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [],
            dataChannel: RecordingWebRTCDataChannelTransport()
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: runtime,
        answerTimeout: .milliseconds(1)
    )

    await #expect(throws: WebRTCPlatformRuntimeError.answerTimedOut) {
        _ = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
            relayHost: relayHost,
            session: session
        ))
    }
}

private actor RecordingWebRTCOpeningRuntime: WebRTCPlatformDataChannelOpening {
    private let result: WebRTCPlatformDataChannelOpenResult
    private(set) var openedSessions: [RelayP2POpenSessionResponse] = []
    private(set) var appliedAnswers: [WebRTCSessionDescriptionPayload] = []
    private(set) var addedCandidates: [WebRTCICECandidatePayload] = []

    init(result: WebRTCPlatformDataChannelOpenResult) {
        self.result = result
    }

    func openDataChannel(
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        openedSessions.append(session)
        return result
    }

    func applyRemoteAnswer(
        _ answer: WebRTCSessionDescriptionPayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        appliedAnswers.append(answer)
    }

    func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        addedCandidates.append(candidate)
    }

    func waitForAddedCandidateCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while addedCandidates.count < count {
            if ContinuousClock.now >= deadline {
                throw RelayWebRTCDataChannelFactoryTestError.timedOutWaitingForRemoteICE(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForAppliedAnswerCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while appliedAnswers.count < count {
            if ContinuousClock.now >= deadline {
                throw RelayWebRTCDataChannelFactoryTestError.timedOutWaitingForAppliedAnswer(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class RecordingRelayP2PSignalingHTTPClient: RelayP2PSignalingHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var remoteMessageBatches: [[RelayP2PSignalingMessageDTO]]
    private var recordedSentMessages: [RelayP2PSignalingMessageDTO] = []

    var sentMessages: [RelayP2PSignalingMessageDTO] {
        lock.withLock { recordedSentMessages }
    }

    init(remoteMessages: [RelayP2PSignalingMessageDTO]) {
        remoteMessageBatches = [remoteMessages]
    }

    init(remoteMessageBatches: [[RelayP2PSignalingMessageDTO]]) {
        self.remoteMessageBatches = remoteMessageBatches
    }

    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: .online,
            authorization: .authorizedToSignal,
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            activeConnectionCount: 1
        )
    }

    func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        RelayP2POpenSessionResponse(
            sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            hostID: request.hostID,
            deviceID: request.deviceID,
            pairingRecordID: request.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        )
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        lock.withLock {
            recordedSentMessages.append(request.message)
        }
    }

    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        let messages = lock.withLock {
            guard !remoteMessageBatches.isEmpty else {
                return [RelayP2PSignalingMessageDTO]()
            }
            return remoteMessageBatches.removeFirst()
        }
        return RelayP2PDrainMessagesResponse(messages: messages)
    }

    func waitForSentMessageCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while lock.withLock({ recordedSentMessages.count }) < count {
            if ContinuousClock.now >= deadline {
                throw RelayWebRTCDataChannelFactoryTestError.timedOutWaitingForSentMessages(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class RecordingWebRTCDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    private let lock = NSLock()
    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages = AsyncStream<Data> { _ in }
    let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private var recordedSentMessages: [Data] = []

    init(autoOpen: Bool = true) {
        var capturedContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        stateUpdates = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        stateContinuation = capturedContinuation!
        if autoOpen {
            Task { [stateContinuation] in
                stateContinuation.yield(.dataChannelOpen)
            }
        }
    }

    var sentMessages: [Data] {
        lock.withLock { recordedSentMessages }
    }

    func send(_ message: Data) async throws {
        lock.withLock {
            recordedSentMessages.append(message)
        }
    }

    func deliverState(_ state: WebRTCDataChannelConnectionState) {
        stateContinuation.yield(state)
    }
}

private actor RelayWebRTCDataChannelOpenCompletionProbe {
    private var finished = false

    var isFinished: Bool {
        finished
    }

    func markFinished() {
        finished = true
    }
}

private enum RelayWebRTCDataChannelFactoryTestError: Error, CustomStringConvertible {
    case timedOutWaitingForSentMessages(Int)
    case timedOutWaitingForRemoteICE(Int)
    case timedOutWaitingForAppliedAnswer(Int)

    var description: String {
        switch self {
        case let .timedOutWaitingForSentMessages(count):
            "Timed out waiting for \(count) sent signaling messages"
        case let .timedOutWaitingForRemoteICE(count):
            "Timed out waiting for \(count) remote ICE candidates"
        case let .timedOutWaitingForAppliedAnswer(count):
            "Timed out waiting for \(count) applied WebRTC answers"
        }
    }
}
