import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentRelayConfigurationStoresProductionEndpointAndDerivesHostConnectURL() throws {
    let configuration = try HostAgentRelayConfiguration(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        host: RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
    )

    #expect(configuration.relayBaseURL == URL(string: "https://relay.example.test")!)
    #expect(configuration.hostConnectURL == URL(string: "wss://relay.example.test/v0/host/connect")!)
    #expect(configuration.streamEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
    #expect(configuration.pairingPublishURL == URL(string: "https://relay.example.test/v0/pairing/publish")!)
    #expect(configuration.diagnosticSummary == "Relay configured: relay.example.test")
}

@Test func hostAgentRelayConfigurationDefinesProductionEndpointForDefaultPairing() {
    #expect(HostAgentRelayConfiguration.productionRelayBaseURL == URL(string: "https://codexport.smarteffi.net")!)
}

@Test func hostAgentRelayConnectionStatePresentsMissingConfiguredOnlineAndFailureStates() {
    #expect(HostAgentRelayConnectionState.notConfigured.presentation == .init(
        statusText: "HostAgent Not Paired",
        detail: "Use New Pairing to pair this Mac with an iPhone."
    ))
    #expect(HostAgentRelayConnectionState.configured(URL(string: "https://relay.example.test")!).presentation == .init(
        statusText: "Relay Configured",
        detail: "relay.example.test"
    ))
    #expect(HostAgentRelayConnectionState.online(activeConnectionCount: 2).presentation == .init(
        statusText: "Relay Online",
        detail: "2 connected devices"
    ))
    #expect(HostAgentRelayConnectionState.failed("network down").presentation == .init(
        statusText: "Relay Failed",
        detail: "network down"
    ))
}

@Test func hostAgentRelayConnectorBuildsNoSecretHostRegistrationRequest() throws {
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let task = RecordingHostAgentRelayWebSocketTask()
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: URL(string: "wss://relay.example.test/v0/host/connect")!,
        service: HostAgentLocalRelayService(commandFactory: { _ in
            HostAgentProcessCommand(executablePath: "/bin/echo", arguments: [])
        }),
        makeTask: { request in
            task.request = request
            return task
        }
    )

    connector.connect()

    let request = try #require(task.request)
    #expect(task.didResume)
    #expect(request.url == URL(string: "wss://relay.example.test/v0/host/connect")!)
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Host-Agent-ID") == host.id.uuidString)
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Host-Display-Name") == "Mac Studio")
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Host-User") == "chenm")
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Relay-Versions") == "0.2.0")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Host-Public-Key") == Data("host-public-key".utf8).base64EncodedString())
    #expect(!String(describing: request.allHTTPHeaderFields).contains("secret"))
}

@Test func hostAgentRelayConnectorReconnectsWhenHostStreamCloses() async throws {
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let factory = RecordingHostAgentRelayWebSocketTaskFactory()
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: URL(string: "wss://relay.example.test/v0/host/connect")!,
        service: HostAgentLocalRelayService(commandFactory: { _ in
            HostAgentProcessCommand(executablePath: "/bin/echo", arguments: [])
        }),
        reconnectDelay: .milliseconds(10),
        makeTask: factory.makeTask(request:)
    )

    connector.connect()
    await waitUntil {
        factory.tasks.count == 1
    }
    factory.tasks.first?.finish()
    await waitUntil {
        factory.tasks.count >= 2
    }
    connector.stop()

    #expect(factory.tasks.count >= 2)
    #expect(factory.tasks.allSatisfy { $0.didResume })
}

@Test func hostAgentRelayConnectorReconnectsWhenHeartbeatTimesOut() async throws {
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let factory = RecordingHostAgentRelayWebSocketTaskFactory()
    factory.configureNextTask = { task in
        task.pingBehavior = .hang
    }
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: URL(string: "wss://relay.example.test/v0/host/connect")!,
        service: HostAgentLocalRelayService(commandFactory: { _ in
            HostAgentProcessCommand(executablePath: "/bin/echo", arguments: [])
        }),
        reconnectDelay: .milliseconds(10),
        heartbeatInterval: .milliseconds(10),
        heartbeatTimeout: .milliseconds(20),
        makeTask: factory.makeTask(request:)
    )

    connector.connect()
    await waitUntil {
        (factory.tasks.first?.pingCount ?? 0) >= 1
    }
    await waitUntil(timeout: .seconds(1)) {
        factory.tasks.count >= 2
    }
    connector.stop()

    #expect(factory.tasks.count >= 2)
    #expect(factory.tasks.first?.didCancel == true)
}

@Test func hostAgentRelayConnectorReconnectsWhenBridgeResponseSendFails() async throws {
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let factory = RecordingHostAgentRelayWebSocketTaskFactory()
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in
            HostAgentProcessCommand(executablePath: "/bin/false", arguments: [])
        },
        threadListProvider: StubConnectorThreadListProvider(threads: [
            RelayThreadSummarySnapshot(
                id: "thread-1",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay live session",
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            ),
        ])
    )
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: URL(string: "wss://relay.example.test/v0/host/connect")!,
        service: service,
        reconnectDelay: .milliseconds(10),
        heartbeatInterval: .seconds(60),
        makeTask: factory.makeTask(request:)
    )

    connector.connect()
    await waitUntil {
        factory.tasks.count == 1
    }
    factory.tasks.first?.sendStringError = TestConnectorError.expected
    try factory.tasks.first?.receive(RelayHostBridgeEnvelope.encode(RelayHostBridgeEnvelope(
        streamID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        clientID: "iphone-a",
        line: #"{"type":"listThreads","clientID":"iphone-a","requestID":"request-1","limit":20}"#
    )) + "\n")
    await waitUntil(timeout: .seconds(1)) {
        factory.tasks.count >= 2
    }
    connector.stop()

    #expect(factory.tasks.count >= 2)
    #expect(factory.tasks.first?.didCancel == true)
}

@Test func hostAgentRelayConnectorKeepsReadingBridgeRequestsWhilePromptIsRunning() async throws {
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let factory = RecordingHostAgentRelayWebSocketTaskFactory()
    let service = HostAgentLocalRelayService(
        adapterFactory: { _ in
            AnyHostAgentLiveSessionAdapter(SlowPromptAdapter())
        },
        threadListProvider: StubConnectorThreadListProvider(threads: [
            RelayThreadSummarySnapshot(
                id: "thread-while-prompt-runs",
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: "Relay live session",
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            ),
        ])
    )
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: URL(string: "wss://relay.example.test/v0/host/connect")!,
        service: service,
        reconnectDelay: .milliseconds(10),
        heartbeatInterval: .seconds(60),
        makeTask: factory.makeTask(request:)
    )

    connector.connect()
    await waitUntil {
        factory.tasks.count == 1
    }
    let task = try #require(factory.tasks.first)
    let sessionID = "session-while-prompt-runs"
    try task.receive(RelayHostBridgeEnvelope.encode(RelayHostBridgeEnvelope(
        streamID: UUID(uuidString: "22222222-3333-4444-5555-666666666661")!,
        clientID: "iphone-a",
        line: #"{"type":"attach","clientID":"iphone-a","sessionID":"\#(sessionID)","threadID":"thread-while-prompt-runs","turnID":"turn-1"}"#
    )) + "\n")
    try task.receive(RelayHostBridgeEnvelope.encode(RelayHostBridgeEnvelope(
        streamID: UUID(uuidString: "22222222-3333-4444-5555-666666666662")!,
        clientID: "iphone-a",
        line: #"{"type":"prompt","clientID":"iphone-a","sessionID":"\#(sessionID)","threadID":"thread-while-prompt-runs","writeID":"write-slow","text":"slow prompt"}"#
    )) + "\n")
    try task.receive(RelayHostBridgeEnvelope.encode(RelayHostBridgeEnvelope(
        streamID: UUID(uuidString: "22222222-3333-4444-5555-666666666663")!,
        clientID: "iphone-a",
        line: #"{"type":"listThreads","clientID":"iphone-a","requestID":"list-during-prompt","limit":20}"#
    )) + "\n")

    await waitUntil(timeout: .milliseconds(200)) {
        task.sentStringsSnapshot().contains { $0.contains("list-during-prompt") }
    }
    connector.stop()
    await service.stopAll()

    let sentStrings = task.sentStringsSnapshot()
    #expect(sentStrings.contains { $0.contains("list-during-prompt") })
    #expect(sentStrings.contains { $0.contains("thread-while-prompt-runs") })
}

private final class RecordingHostAgentRelayWebSocketTask: HostAgentRelayWebSocketTask, @unchecked Sendable {
    enum PingBehavior {
        case succeed
        case hang
    }

    let receivedStrings: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    var request: URLRequest?
    var didResume = false
    var didCancel = false
    var pingBehavior = PingBehavior.succeed
    var pingCount = 0
    var sendStringError: (any Error)?
    private let sentStringsLock = NSLock()
    private var sentStrings: [String] = []

    init() {
        var capturedContinuation: AsyncStream<String>.Continuation?
        receivedStrings = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func resume() {
        didResume = true
    }

    func sendString(_ string: String) async throws {
        if let sendStringError {
            throw sendStringError
        }
        sentStringsLock.withLock {
            sentStrings.append(string)
        }
    }

    func sentStringsSnapshot() -> [String] {
        sentStringsLock.withLock {
            sentStrings
        }
    }

    func sendPing() async throws {
        pingCount += 1
        switch pingBehavior {
        case .succeed:
            return
        case .hang:
            try await Task.sleep(for: .seconds(60))
        }
    }

    func cancel() {
        didCancel = true
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }

    func receive(_ string: String) {
        continuation.yield(string)
    }
}

private final class RecordingHostAgentRelayWebSocketTaskFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var tasks: [RecordingHostAgentRelayWebSocketTask] = []
    var configureNextTask: ((RecordingHostAgentRelayWebSocketTask) -> Void)?

    func makeTask(request: URLRequest) -> HostAgentRelayWebSocketTask {
        let task = RecordingHostAgentRelayWebSocketTask()
        task.request = request
        if let configureNextTask {
            configureNextTask(task)
            self.configureNextTask = nil
        }
        lock.withLock {
            tasks.append(task)
        }
        return task
    }
}

private struct StubConnectorThreadListProvider: HostAgentThreadListProviding {
    var threads: [RelayThreadSummarySnapshot]

    func listThreads(limit: Int, cursor: String?) async throws -> RelayThreadListResponse {
        RelayThreadListResponse(threads: Array(threads.prefix(limit)))
    }
}

private enum TestConnectorError: Error {
    case expected
}

private final class SlowPromptAdapter: HostAgentLiveSessionAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<RelayLiveSessionEvent>.Continuation] = []

    func events() -> AsyncStream<RelayLiveSessionEvent> {
        AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    func start() throws {
        emit(.sessionStarted(sessionID: "session-while-prompt-runs", threadID: "thread-while-prompt-runs", turnID: "turn-1"))
    }

    func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        try? await Task.sleep(for: .seconds(60))
        return .handled
    }

    func stop() {
        let continuations = lock.withLock {
            let continuations = self.continuations
            self.continuations = []
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func emit(_ event: RelayLiveSessionEvent) {
        let continuations = lock.withLock {
            self.continuations
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }
}

private func waitUntil(
    timeout: Duration = .milliseconds(300),
    condition: @escaping @Sendable () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
