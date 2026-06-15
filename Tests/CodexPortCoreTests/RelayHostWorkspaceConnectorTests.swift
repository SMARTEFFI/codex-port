import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayHostWorkspaceConnectorDoesNotReturnRouteBeforeThreadListHandshake() async throws {
    let transport = RecordingRelayThreadListTransport()
    let connector = RelayHostWorkspaceConnector(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost(),
        makeTransport: { _ in transport },
        timeout: .milliseconds(30)
    )

    await #expect(throws: RelayJSONLThreadListClientError.timedOut) {
        _ = try await connector.connect(limit: 20, requestID: "request-1")
    }
    #expect(await transport.sentLinesSnapshot() == [
        #"{"clientID":"pairing-1","limit":20,"requestID":"request-1","type":"listThreads"}"#,
    ])
}

@Test func relayHostWorkspaceConnectorReturnsRouteAfterThreadListHandshake() async throws {
    let transport = RecordingRelayThreadListTransport()
    let connector = RelayHostWorkspaceConnector(
        profileDefaultDirectory: "/Users/chenm/Projects/codex-port",
        relayHost: relayHost(),
        makeTransport: { _ in transport },
        timeout: .milliseconds(300)
    )
    let threads = [
        RelayThreadSummarySnapshot(
            id: "thread-1",
            cwd: "/Users/chenm/Projects/codex-port",
            updatedAtUnixTime: 1_780_991_312,
            preview: "Relay thread",
            gitRepository: "git@github.com:zhxsinc/codex-port.git",
            gitBranch: "main",
            status: "completed"
        ),
    ]

    async let connection = connector.connect(limit: 20, requestID: "request-1")
    await waitUntil {
        transport.sentLinesSyncSnapshot().contains(#"{"clientID":"pairing-1","limit":20,"requestID":"request-1","type":"listThreads"}"#)
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        threads,
        clientID: "pairing-1",
        requestID: "request-1"
    ))

    let resolved = try await connection
    #expect(resolved.threadSnapshots == threads)
    #expect(resolved.route.relayThreadSummaries.map(\.id) == ["thread-1"])
    #expect(resolved.route.relayThreadSummaries.first?.cwd == "/Users/chenm/Projects/codex-port")
}

private func relayHost() -> RelayHost {
    RelayHost(
        hostAgentID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        displayName: "MacBook Air",
        userName: "chenm",
        pairingRecordID: "pairing-1",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
}

private final class RecordingRelayThreadListTransport: RelayJSONLTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentLines: [String] = []
    private var continuation: AsyncStream<String>.Continuation?
    let incomingLines: AsyncStream<String>

    init() {
        var capturedContinuation: AsyncStream<String>.Continuation?
        incomingLines = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func sendLine(_ line: String) async throws {
        lock.withLock {
            sentLines.append(line)
        }
    }

    func emit(_ line: String) {
        lock.withLock {
            continuation
        }?.yield(line)
    }

    func sentLinesSyncSnapshot() -> [String] {
        lock.withLock {
            sentLines
        }
    }

    func sentLinesSnapshot() async -> [String] {
        lock.withLock {
            sentLines
        }
    }
}

private func waitUntil(
    timeout: Duration = .milliseconds(200),
    condition: @escaping @Sendable () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
