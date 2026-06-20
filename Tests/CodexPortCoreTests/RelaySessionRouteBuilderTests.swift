import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relaySessionRouteBuilderExposesRealThreadSummariesAndClientsOnly() throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 2),
        diagnosticsSummary: "Ready"
    )
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost,
        threadSnapshots: [
            RelayThreadSummarySnapshot(
                id: "thread-1",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay thread",
                gitRepository: "git@github.com:zhxsinc/codex-port.git",
                gitBranch: "main",
                status: "completed"
            ),
        ],
        makeTransport: { _ in RecordingRelayJSONLTransportForBuilder() }
    )

    #expect(route.relayThreadSummaries.map(\.id) == ["thread-1"])
    #expect(route.relayThreadSummaries[0].cwd == "/Users/chenm/Projects/codex-port")
    #expect(route.relaySessionContext(threadID: "thread-1") != nil)
    #expect(route.relaySessionContext(threadID: "relay-pairing-1") == nil)
}

@Test func relaySessionRouteBuilderReusesSessionContextForThreadDuringHostConnection() throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost,
        threadSnapshots: [
            RelayThreadSummarySnapshot(
                id: "thread-1",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay thread",
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            ),
        ],
        makeTransport: { _ in RecordingRelayJSONLTransportForBuilder() }
    )

    let first = route.relaySessionContext(threadID: "thread-1")
    let second = route.relaySessionContext(threadID: "thread-1")

    #expect(first != nil)
    #expect(first === second)
    #expect(first?.sessionStore === second?.sessionStore)
    #expect(first?.clientManager === second?.clientManager)
}

@Test func relaySessionRouteCanAppendNewRelayThreadAndExposeContext() throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm",
        relayHost: relayHost,
        threadSnapshots: [
            RelayThreadSummarySnapshot(
                id: "thread-1",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay thread",
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            ),
        ],
        makeTransport: { _ in RecordingRelayJSONLTransportForBuilder() }
    )
    let newThread = ThreadSummary(
        id: "new-thread",
        cwd: "/Users/chenm/Projects/codex-port",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        preview: "新会话",
        gitInfo: nil
    )

    let updatedRoute = route.appendingRelayThread(newThread)

    #expect(updatedRoute.relayThreadSummaries.map(\.id) == ["new-thread", "thread-1"])
    #expect(updatedRoute.relaySessionContext(threadID: "new-thread") != nil)
}

@Test func relaySessionRouteBuilderPassesThreadCWDIntoRelaySessionClientAttach() async throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let transport = RecordingRelayJSONLTransportForBuilder()
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm",
        relayHost: relayHost,
        threadSnapshots: [
            RelayThreadSummarySnapshot(
                id: "thread-1",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay thread",
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            ),
        ],
        makeTransport: { _ in transport }
    )
    let context = try #require(route.relaySessionContext(threadID: "thread-1"))

    _ = try await context.clientManager.attach()

    let attach = try #require(transport.firstSentJSONObject())
    #expect(attach["type"] as? String == "attach")
    #expect(attach["clientID"] as? String == "pairing-1")
    #expect(attach["sessionID"] as? String == "thread-1")
    #expect(attach["threadID"] as? String == "thread-1")
    #expect(attach["turnID"] as? String == "thread-1-turn")
    #expect(attach["cwd"] as? String == "/Users/chenm/Projects/codex-port")
    #expect(attach["loadInitialHistory"] as? Bool == true)
    #expect(attach["resumeLiveSession"] as? Bool == true)
}

@Test func relaySessionRouteBuilderPassesFreshSessionAttachOptionsIntoRelayClient() async throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let transport = RecordingRelayJSONLTransportForBuilder()
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm",
        relayHost: relayHost,
        threadSnapshots: [
            RelayThreadSummarySnapshot(
                id: "fresh-thread",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "fresh-thread",
                gitRepository: nil,
                gitBranch: nil,
                status: "running"
            ),
        ],
        makeTransport: { _ in transport }
    )
    let context = try #require(route.relaySessionContext(
        threadID: "fresh-thread",
        options: .init(loadInitialHistory: false, resumeLiveSession: false)
    ))

    _ = try await context.clientManager.attach()

    let attach = try #require(transport.firstSentJSONObject())
    #expect(attach["type"] as? String == "attach")
    #expect(attach["threadID"] as? String == "fresh-thread")
    #expect(attach["loadInitialHistory"] as? Bool == false)
    #expect(attach["resumeLiveSession"] as? Bool == false)
}

@Test func relaySessionRouteBuilderCanUseProductionWebSocketTransportFactory() throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let factory = RecordingRelayEndpointTransportFactory()
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost,
        makeTransport: factory.makeTransport(for:)
    )

    #expect(route.relaySessionContext(threadID: "missing-relay-thread") == nil)
    #expect(factory.requestedEndpointURLs.isEmpty)
    #expect(factory.requestedPairingRecordIDs.isEmpty)
}

@Test func relaySessionRouteBuilderCanUseDeferredP2PTransportFactoryForSessionAttach() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let signaling = RelayP2PSignalingRecordingHTTPClientForRoute(
        presenceResponse: RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: .online,
            authorization: .authorizedToSignal,
            pairingRecordID: relayHost.pairingRecordID,
            activeConnectionCount: 1
        ),
        openResponse: RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        )
    )
    let dataChannelFactory = RecordingRelayP2PDataChannelFactoryForRoute(
        transport: RecordingDataChannelTransportForRoute()
    )
    let p2pFactory = RelayP2PSessionTransportFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signaling
        ),
        dataChannelFactory: dataChannelFactory
    )
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost,
        threadSnapshots: [
            RelayThreadSummarySnapshot(
                id: "thread-1",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay thread",
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            ),
        ],
        makeTransport: p2pFactory.makeDeferredTransport(for:)
    )
    let context = try #require(route.relaySessionContext(threadID: "thread-1"))

    _ = try await context.clientManager.attach()

    let sent = try #require(dataChannelFactory.transport.sentMessages.first)
    let sentLine = String(decoding: sent, as: UTF8.self)
    let sentObject = try #require(
        try JSONSerialization.jsonObject(with: Data(sentLine.dropLast().utf8)) as? [String: Any]
    )

    #expect(signaling.presenceURL == URL(string: "https://relay.example.test/v0/p2p/hosts/\(hostID.uuidString)/presence?deviceID=\(deviceID.uuidString)")!)
    #expect(dataChannelFactory.openRequest?.session.sessionID == sessionID)
    #expect(sentObject["type"] as? String == "attach")
    #expect(sentObject["clientID"] as? String == relayHost.pairingRecordID)
    #expect(sentObject["sessionID"] as? String == "thread-1")
    #expect(sentObject["threadID"] as? String == "thread-1")
    #expect(sentObject["loadInitialHistory"] as? Bool == true)
    #expect(sentObject["resumeLiveSession"] as? Bool == true)
    #expect(sentObject["turnID"] as? String == "thread-1-turn")
    #expect(sentObject["cwd"] as? String == "/Users/chenm/Projects/codex-port")
}

@Test func relaySessionRouteBuilderDoesNotExposePlaceholderThreadSummaries() throws {
    let relayHost = RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 2),
        diagnosticsSummary: "Ready"
    )
    let route = RelaySessionRouteBuilder.route(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost,
        makeTransport: { _ in RecordingRelayJSONLTransportForBuilder() }
    )

    #expect(route.relayThreadSummaries.isEmpty)
}

private final class RecordingRelayJSONLTransportForBuilder: RelayJSONLTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentLines: [String] = []
    let incomingLines = AsyncStream<String> { _ in }

    func sendLine(_ line: String) async throws {
        lock.withLock {
            sentLines.append(line)
        }
    }

    func sentLinesSnapshot() -> [String] {
        lock.withLock {
            sentLines
        }
    }

    func firstSentJSONObject() -> [String: Any]? {
        guard let first = sentLinesSnapshot().first,
              let data = first.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class RecordingRelayEndpointTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RelayHost] = []

    var requestedEndpointURLs: [URL] {
        lock.withLock {
            requests.compactMap(\.relayEndpointURL)
        }
    }

    var requestedPairingRecordIDs: [String] {
        lock.withLock {
            requests.map(\.pairingRecordID)
        }
    }

    func makeTransport(for host: RelayHost) -> RelayJSONLTransport? {
        lock.withLock {
            requests.append(host)
        }
        guard host.relayEndpointURL != nil else { return nil }
        return RecordingRelayJSONLTransportForBuilder()
    }
}

private final class RelayP2PSignalingRecordingHTTPClientForRoute: RelayP2PSignalingHTTPClient, @unchecked Sendable {
    let presenceResponse: RelayP2PPresenceResponse
    let openResponse: RelayP2POpenSessionResponse
    private(set) var presenceURL: URL?

    init(
        presenceResponse: RelayP2PPresenceResponse,
        openResponse: RelayP2POpenSessionResponse
    ) {
        self.presenceResponse = presenceResponse
        self.openResponse = openResponse
    }

    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        presenceURL = url
        return presenceResponse
    }

    func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        openResponse
    }

    func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse {
        RelayP2PICEConfigurationResponse(
            configuration: WebRTCRuntimeConfiguration(iceServers: []),
            expiresAtUnixTime: 0
        )
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {}

    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        RelayP2PDrainMessagesResponse(messages: [])
    }
}

private final class RecordingRelayP2PDataChannelFactoryForRoute: RelayP2PDataChannelFactory, @unchecked Sendable {
    let transport: RecordingDataChannelTransportForRoute
    private(set) var openRequest: RelayP2PDataChannelOpenRequest?

    init(transport: RecordingDataChannelTransportForRoute) {
        self.transport = transport
    }

    func openDataChannel(_ request: RelayP2PDataChannelOpenRequest) async throws -> any WebRTCDataChannelTransport {
        openRequest = request
        return transport
    }
}

private final class RecordingDataChannelTransportForRoute: WebRTCDataChannelTransport, @unchecked Sendable {
    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages = AsyncStream<Data> { _ in }
    let stateUpdates = AsyncStream<WebRTCDataChannelConnectionState> { _ in }
    private(set) var sentMessages: [Data] = []

    func send(_ message: Data) async throws {
        sentMessages.append(message)
    }
}
