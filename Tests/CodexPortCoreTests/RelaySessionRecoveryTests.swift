import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relaySessionRecoveryMovesStreamCloseIntoReconnectState() {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)
    var recovery = RelaySessionRecoveryState()

    store.receive(relayEvent: .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    store.receive(relayEvent: .streamClosed(sessionID: "session-1", threadID: "thread-1", errorCode: "relay.closed"))
    recovery.apply(.streamClosed(sessionID: "session-1", threadID: "thread-1", errorCode: "relay.closed"))

    #expect(store.status == .running)
    #expect(recovery.status == .reconnecting(reason: "Relay stream closed: relay.closed"))
    #expect(recovery.allowsManualReconnect)
}

@Test func relaySessionRecoveryReattachesAndRestoresVisibleSessionState() async throws {
    let source = FakeRelayRecoverySource(
        snapshot: RelayRecoveredSessionSnapshot(
            sessionID: "session-1",
            threadID: "thread-1",
            title: "Fix login flow",
            state: .running(turnID: "turn-1"),
            recentEvents: [
                .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
                .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Working"),
                .commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test"),
                .approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "Allow file edit"),
            ],
            pendingApprovals: [
                RelayPendingApproval(requestID: "approval-1", summary: "Allow file edit")
            ]
        )
    )
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)
    let coordinator = RelaySessionRecoveryCoordinator(source: source, session: store)

    let snapshot = try await coordinator.recover(sessionID: "session-1", threadID: "thread-1")

    #expect(coordinator.status == .completed)
    #expect(snapshot.title == "Fix login flow")
    #expect(snapshot.state == .running(turnID: "turn-1"))
    #expect(snapshot.pendingApprovals == [RelayPendingApproval(requestID: "approval-1", summary: "Allow file edit")])
    #expect(store.status == .running)
    #expect(store.visibleItems == [
        .assistantMessage("Working"),
        .commandOutput("swift test"),
    ])
}

@Test func relaySessionRecoveryReportsRelayUnavailableAndHostOfflineFailures() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)

    let relayUnavailable = RelaySessionRecoveryCoordinator(
        source: FakeRelayRecoverySource(error: RelayDiagnosticFailure.relayUnavailable("network down")),
        session: store
    )
    await #expect(throws: RelayDiagnosticFailure.relayUnavailable("network down")) {
        _ = try await relayUnavailable.recover(sessionID: "session-1", threadID: "thread-1")
    }
    #expect(relayUnavailable.status == .failed("无法连接 CodexPort Relay：network down"))
    #expect(relayUnavailable.allowsManualReconnect)

    let hostOffline = RelaySessionRecoveryCoordinator(
        source: FakeRelayRecoverySource(error: RelayDiagnosticFailure.hostAgentOffline(hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, lastSeenAt: Date(timeIntervalSince1970: 100))),
        session: store
    )
    await #expect(throws: RelayDiagnosticFailure.hostAgentOffline(hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, lastSeenAt: Date(timeIntervalSince1970: 100))) {
        _ = try await hostOffline.recover(sessionID: "session-1", threadID: "thread-1")
    }
    #expect(hostOffline.status == .failed("Host Agent 离线。最后在线 1970-01-01 00:01:40Z。请检查 Mac 是否开机、联网并运行 CodexPort Host Agent。"))
    #expect(hostOffline.allowsManualReconnect)
}

private struct FakeRelayRecoverySource: RelaySessionRecovering {
    var snapshot: RelayRecoveredSessionSnapshot?
    var error: Error?

    init(snapshot: RelayRecoveredSessionSnapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func recover(sessionID: String, threadID: String) async throws -> RelayRecoveredSessionSnapshot {
        if let error {
            throw error
        }
        if let snapshot {
            return snapshot
        }
        throw RelaySessionRecoveryError.sessionNotFound(sessionID: sessionID, threadID: threadID)
    }
}
