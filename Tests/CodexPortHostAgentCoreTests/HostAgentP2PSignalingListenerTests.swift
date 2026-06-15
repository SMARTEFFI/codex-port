import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Suite(.serialized)
struct HostAgentP2PSignalingListenerTests {

@Test func hostAgentP2PSignalingListenerAcceptsOfferSendsAnswerAndStartsDataChannelEndpoint() async throws {
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
        payload: "sdp-offer"
    )
    let dataChannel = ListenerRecordingDataChannelTransport()
    let signalingHTTP = ListenerRecordingP2PHTTPClient(hostMessages: [
        RelayP2PHostDrainedMessageDTO(session: session, message: offer)
    ])
    let acceptor = ListenerRecordingDataChannelAcceptor(
        response: HostAgentP2PAcceptResponse(
            answer: RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: "sdp-answer"
            ),
            iceCandidates: [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: "candidate:1 udp host"
                ),
            ],
            dataChannel: dataChannel
        )
    )
    let thread = RelayThreadSummarySnapshot(
        id: "thread-1",
        cwd: "/Users/chenm/Projects/codex-port",
        updatedAtUnixTime: 1_780_991_312,
        preview: "HostAgent P2P listener session",
        gitRepository: "git@github.com:zhxsinc/codex-port.git",
        gitBranch: "main",
        status: "completed"
    )
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadListProvider: ListenerStubThreadListProvider(threads: [thread])
    )
    let eventRecorder = ListenerEventRecorder()
    let listener = HostAgentP2PSignalingListener(
        host: RelayHostIdentity(
            id: hostID,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        ),
        signalingClient: HostAgentP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        acceptor: acceptor,
        service: service,
        pollInterval: .milliseconds(25),
        onEvent: { event in
            await eventRecorder.record(event)
        }
    )

    listener.start()
    try await acceptor.waitForRequestCount(1)
    await dataChannel.deliver(Data((#"{"type":"listThreads","clientID":"iphone-a","requestID":"list-1","limit":1}"# + "\n").utf8))
    let line = try await dataChannel.waitForSentLine(containing: #""type":"threadList""#)
    listener.stop()

    #expect(signalingHTTP.drainURL == URL(string: "https://relay.example.test/v0/p2p/hosts/\(hostID.uuidString)/messages")!)
    #expect(signalingHTTP.publishedPresenceRequest == RelayP2PHostPresencePublishRequest(
        hostID: hostID,
        hostDisplayName: "Mac Studio",
        hostUserName: "chenm",
        hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
    ))
    #expect(signalingHTTP.publishedPresenceURL == URL(string: "https://relay.example.test/v0/p2p/hosts/\(hostID.uuidString)/presence")!)
    #expect(await acceptor.requests == [
        HostAgentP2PAcceptRequest(session: session, offer: offer)
    ])
    #expect(signalingHTTP.sentMessages == [
        .init(
            sessionID: session.sessionID,
            message: RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: "sdp-answer"
            )
        ),
        .init(
            sessionID: session.sessionID,
            message: RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .iceCandidate,
                payload: "candidate:1 udp host"
            )
        ),
    ])
    #expect(try RelayEndpointJSONLCodec.decodeLine(line) == .threadList(
        clientID: "iphone-a",
        requestID: "list-1",
        threads: [thread],
        nextCursor: nil
    ))
    let recordedEvents = await eventRecorder.events
    #expect(recordedEvents.contains(.hostPresencePublished(hostID: hostID)))
    #expect(recordedEvents.contains(.offerReceived(sessionID: session.sessionID, deviceID: deviceID)))
    #expect(recordedEvents.contains(.dataChannelAccepted(sessionID: session.sessionID, deviceID: deviceID)))
}

@Test func hostAgentP2PSignalingListenerIgnoresDuplicateOffersForAcceptedSession() async throws {
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
        payload: "sdp-offer"
    )
    let signalingHTTP = ListenerRecordingP2PHTTPClient(hostMessages: [
        RelayP2PHostDrainedMessageDTO(session: session, message: offer),
        RelayP2PHostDrainedMessageDTO(session: session, message: offer),
    ])
    let acceptor = ListenerRecordingDataChannelAcceptor(
        response: HostAgentP2PAcceptResponse(
            answer: RelayP2PSignalingMessageDTO(from: .host, to: .device, kind: .answer, payload: "sdp-answer"),
            iceCandidates: [],
            dataChannel: ListenerRecordingDataChannelTransport()
        )
    )
    let listener = HostAgentP2PSignalingListener(
        hostID: hostID,
        signalingClient: HostAgentP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        acceptor: acceptor,
        service: HostAgentLocalRelayService(
            commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
        )
    )

    listener.start()
    try await acceptor.waitForRequestCount(1)
    try await Task.sleep(for: .milliseconds(80))
    listener.stop()

    #expect(await acceptor.requests.count == 1)
    #expect(signalingHTTP.sentMessages.count == 1)
}

@Test func hostAgentP2PSignalingListenerForwardsTrickleICEInBothDirections() async throws {
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
        payload: "sdp-offer"
    )
    let remoteCandidate = RelayP2PSignalingMessageDTO(
        from: .device,
        to: .host,
        kind: .iceCandidate,
        payload: "candidate:device-follow-up"
    )
    let localCandidate = RelayP2PSignalingMessageDTO(
        from: .host,
        to: .device,
        kind: .iceCandidate,
        payload: "candidate:host-follow-up"
    )
    let signalingHTTP = ListenerRecordingP2PHTTPClient(hostMessages: [
        RelayP2PHostDrainedMessageDTO(session: session, message: offer),
        RelayP2PHostDrainedMessageDTO(session: session, message: remoteCandidate),
    ])
    let localICEUpdateStream = AsyncStream<RelayP2PSignalingMessageDTO> { continuation in
        Task {
            try await Task.sleep(for: .milliseconds(10))
            continuation.yield(localCandidate)
            continuation.finish()
        }
    }
    let dataChannel = ListenerRecordingDataChannelTransport()
    let acceptor = ListenerRecordingDataChannelAcceptor(
        response: HostAgentP2PAcceptResponse(
            answer: RelayP2PSignalingMessageDTO(from: .host, to: .device, kind: .answer, payload: "sdp-answer"),
            iceCandidates: [],
            localICECandidateUpdates: localICEUpdateStream,
            dataChannel: dataChannel
        )
    )
    let listener = HostAgentP2PSignalingListener(
        hostID: hostID,
        signalingClient: HostAgentP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        acceptor: acceptor,
        service: HostAgentLocalRelayService(
            commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
        ),
        pollInterval: .milliseconds(25)
    )

    listener.start()
    try await acceptor.waitForRequestCount(1)
    try await signalingHTTP.waitForSentMessageCount(2)
    try await acceptor.waitForRemoteICEMessageCount(1)
    listener.stop()

    #expect(signalingHTTP.sentMessages.map(\.message) == [
        RelayP2PSignalingMessageDTO(from: .host, to: .device, kind: .answer, payload: "sdp-answer"),
        localCandidate,
    ])
    #expect(await acceptor.remoteICEMessages == [
        ListenerRemoteICEMessage(sessionID: session.sessionID, message: remoteCandidate)
    ])
}

@Test func hostAgentP2PSignalingListenerReportsUnavailableRuntimeWithoutStartingEndpoint() async throws {
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
        payload: "sdp-offer"
    )
    let signalingHTTP = ListenerRecordingP2PHTTPClient(hostMessages: [
        RelayP2PHostDrainedMessageDTO(session: session, message: offer)
    ])
    let eventRecorder = ListenerEventRecorder()
    let listener = HostAgentP2PSignalingListener(
        hostID: hostID,
        signalingClient: HostAgentP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        acceptor: UnavailableHostAgentP2PDataChannelAcceptor(),
        service: HostAgentLocalRelayService(
            commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
        ),
        onEvent: { event in
            await eventRecorder.record(event)
        }
    )

    listener.start()
    try await eventRecorder.waitForEvent { event in
        if case .dataChannelAcceptFailed = event {
            return true
        }
        return false
    }
    listener.stop()

    #expect(signalingHTTP.sentMessages.isEmpty)
    #expect(await eventRecorder.events.contains {
        guard case let .dataChannelAcceptFailed(sessionID, reason) = $0 else {
            return false
        }
        return sessionID == session.sessionID
            && reason.contains("runtimeUnavailable")
            && reason.contains("Real HostAgent WebRTC DataChannel runtime is not linked")
    })
}

@Test func hostAgentP2PSignalingListenerReportsPlatformWebRTCRuntimeUnavailableWithoutStartingEndpoint() async throws {
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
    let offerPayload = try RelayP2PWebRTCSignalingPayloadCodec.encode(
        WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nremote-offer")
    )
    let signalingHTTP = ListenerRecordingP2PHTTPClient(hostMessages: [
        RelayP2PHostDrainedMessageDTO(
            session: session,
            message: RelayP2PSignalingMessageDTO(
                from: .device,
                to: .host,
                kind: .offer,
                payload: offerPayload
            )
        ),
    ])
    let eventRecorder = ListenerEventRecorder()
    let listener = HostAgentP2PSignalingListener(
        hostID: hostID,
        signalingClient: HostAgentP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        acceptor: HostAgentWebRTCDataChannelAcceptor(configuration: WebRTCRuntimeConfiguration(iceServers: [])),
        service: HostAgentLocalRelayService(
            commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
        ),
        onEvent: { event in
            await eventRecorder.record(event)
        }
    )

    listener.start()
    try await eventRecorder.waitForEvent { event in
        if case .dataChannelAcceptFailed = event {
            return true
        }
        return false
    }
    listener.stop()

    #expect(signalingHTTP.sentMessages.isEmpty)
    #expect(await eventRecorder.events.contains {
        guard case let .dataChannelAcceptFailed(sessionID, reason) = $0 else {
            return false
        }
        return sessionID == session.sessionID
            && reason.contains("runtimeUnavailable")
            && reason.contains("Real WebRTC SDK runtime is not linked")
    })
}

}

private struct ListenerStubThreadListProvider: HostAgentThreadListProviding {
    var threads: [RelayThreadSummarySnapshot]

    func listThreads(limit: Int, cursor: String?) async throws -> RelayThreadListResponse {
        RelayThreadListResponse(threads: Array(threads.prefix(limit)))
    }
}

private actor ListenerEventRecorder {
    private(set) var events: [HostAgentP2PSignalingListenerEvent] = []

    func record(_ event: HostAgentP2PSignalingListenerEvent) {
        events.append(event)
    }

    func waitForEvent(
        _ matches: @escaping @Sendable (HostAgentP2PSignalingListenerEvent) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !events.contains(where: matches) {
            if ContinuousClock.now >= deadline {
                throw HostAgentP2PSignalingListenerTestError.timedOutWaitingForEvent
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ListenerRecordingP2PHTTPClient: HostAgentP2PSignalingHTTPClient, @unchecked Sendable {
    private let lock = NSLock()

    struct SentMessage: Equatable {
        var sessionID: UUID
        var message: RelayP2PSignalingMessageDTO
    }

    private var hostMessages: [RelayP2PHostDrainedMessageDTO]
    private(set) var publishedPresenceRequest: RelayP2PHostPresencePublishRequest?
    private(set) var publishedPresenceURL: URL?
    private(set) var drainURL: URL?
    private(set) var sendURLs: [URL] = []
    private var recordedSentMessages: [SentMessage] = []

    var sentMessages: [SentMessage] {
        lock.withLock { recordedSentMessages }
    }

    init(hostMessages: [RelayP2PHostDrainedMessageDTO]) {
        self.hostMessages = hostMessages
    }

    func publishHostPresence(
        _ request: RelayP2PHostPresencePublishRequest,
        at url: URL
    ) async throws -> RelayP2PHostPresencePublishResponse {
        lock.withLock {
            publishedPresenceRequest = request
            publishedPresenceURL = url
        }
        return RelayP2PHostPresencePublishResponse(
            hostID: request.hostID,
            presence: .online,
            activeConnectionCount: 0
        )
    }

    func drainHostMessages(at url: URL) async throws -> RelayP2PDrainHostMessagesResponse {
        let messages = lock.withLock {
            drainURL = url
            guard !hostMessages.isEmpty else {
                return [RelayP2PHostDrainedMessageDTO]()
            }
            return [hostMessages.removeFirst()]
        }
        return RelayP2PDrainHostMessagesResponse(messages: messages)
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        let sessionID = try #require(Self.sessionID(from: url))
        lock.withLock {
            sendURLs.append(url)
            recordedSentMessages.append(SentMessage(sessionID: sessionID, message: request.message))
        }
    }

    func waitForSentMessageCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while lock.withLock({ recordedSentMessages.count }) < count {
            if ContinuousClock.now >= deadline {
                throw HostAgentP2PSignalingListenerTestError.timedOutWaitingForSentMessages(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func sessionID(from url: URL) -> UUID? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 6,
              parts[0] == "v0",
              parts[1] == "p2p",
              parts[2] == "sessions"
        else {
            return nil
        }
        return UUID(uuidString: parts[3])
    }
}

private actor ListenerRecordingDataChannelAcceptor: HostAgentP2PDataChannelAccepting {
    private(set) var requests: [HostAgentP2PAcceptRequest] = []
    private(set) var remoteICEMessages: [ListenerRemoteICEMessage] = []
    private let response: HostAgentP2PAcceptResponse

    init(response: HostAgentP2PAcceptResponse) {
        self.response = response
    }

    func accept(_ request: HostAgentP2PAcceptRequest) async throws -> HostAgentP2PAcceptResponse {
        requests.append(request)
        return response
    }

    func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        remoteICEMessages.append(ListenerRemoteICEMessage(sessionID: sessionID, message: message))
    }

    func waitForRequestCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while requests.count < count {
            if ContinuousClock.now >= deadline {
                throw HostAgentP2PSignalingListenerTestError.timedOutWaitingForAcceptorRequest(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForRemoteICEMessageCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while remoteICEMessages.count < count {
            if ContinuousClock.now >= deadline {
                throw HostAgentP2PSignalingListenerTestError.timedOutWaitingForRemoteICE(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ListenerRemoteICEMessage: Equatable {
    var sessionID: UUID
    var message: RelayP2PSignalingMessageDTO
}

private actor ListenerRecordingDataChannelTransport: WebRTCDataChannelTransport {
    nonisolated let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    nonisolated let incomingMessages: AsyncStream<Data>
    nonisolated let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>

    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private var sentLines: [String] = []
    private var sentBuffer = Data()

    init() {
        var capturedIncoming: AsyncStream<Data>.Continuation?
        var capturedState: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        incomingMessages = AsyncStream { continuation in
            capturedIncoming = continuation
        }
        stateUpdates = AsyncStream { continuation in
            capturedState = continuation
        }
        incomingContinuation = capturedIncoming!
        stateContinuation = capturedState!
    }

    deinit {
        incomingContinuation.finish()
        stateContinuation.finish()
    }

    func send(_ message: Data) async throws {
        sentBuffer.append(message)
        let lines = drainCompleteLines()
        for line in lines {
            sentLines.append(line)
        }
    }

    func deliver(_ message: Data) {
        incomingContinuation.yield(message)
    }

    func waitForSentLine(containing needle: String) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while true {
            if let line = sentLines.first(where: { $0.contains(needle) }) {
                return line
            }
            if ContinuousClock.now >= deadline {
                throw HostAgentP2PSignalingListenerTestError.timedOutWaitingForLine(needle)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = sentBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = sentBuffer[..<newlineIndex]
            sentBuffer.removeSubrange(...newlineIndex)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }
}

private enum HostAgentP2PSignalingListenerTestError: Error, CustomStringConvertible {
    case timedOutWaitingForLine(String)
    case timedOutWaitingForAcceptorRequest(Int)
    case timedOutWaitingForEvent
    case timedOutWaitingForSentMessages(Int)
    case timedOutWaitingForRemoteICE(Int)

    var description: String {
        switch self {
        case let .timedOutWaitingForLine(needle):
            "Timed out waiting for DataChannel line containing \(needle)"
        case let .timedOutWaitingForAcceptorRequest(count):
            "Timed out waiting for \(count) accepted P2P request(s)"
        case .timedOutWaitingForEvent:
            "Timed out waiting for listener event"
        case let .timedOutWaitingForSentMessages(count):
            "Timed out waiting for \(count) sent signaling messages"
        case let .timedOutWaitingForRemoteICE(count):
            "Timed out waiting for \(count) remote ICE messages"
        }
    }
}
