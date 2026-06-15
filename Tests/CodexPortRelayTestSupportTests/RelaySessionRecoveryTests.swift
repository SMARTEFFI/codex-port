import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func fakeRelayReattachesSameSessionAfterHostReconnectAndReloadsVisibleState() async throws {
    let harness = try makeRecoveryHarness()
    let hub = FakeRelayLiveSessionHub(
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: harness.adapter,
        title: "Fix login flow"
    )
    hub.attach(harness.clientA)
    harness.clientA.clearEvents()

    hub.emitSessionEvent(.assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Working"))
    hub.emitSessionEvent(.commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test"))
    hub.emitSessionEvent(.approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "Allow file edit"))
    harness.clientA.close(errorCode: "relay.closed")
    hub.detach(harness.clientA)

    _ = harness.relay.disconnectHostAgent(hostID: harness.host.identity.id, at: Date(timeIntervalSince1970: 10))
    #expect(throws: RelayProtocolError.hostNotRegistered(hostID: harness.host.identity.id)) {
        _ = try harness.attachClientA()
    }
    _ = try harness.relay.registerHostAgent(harness.host)

    let reattached = try harness.attachClientA()
    hub.attach(reattached)
    let snapshot = hub.recoveredSnapshot(sessionID: reattached.sessionID)

    #expect(snapshot.title == "Fix login flow")
    #expect(snapshot.state == .running(turnID: "turn-1"))
    #expect(snapshot.recentEvents == [
        .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Working"),
        .commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test"),
        .approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "Allow file edit"),
    ])
    #expect(snapshot.pendingApprovals == [
        RelayPendingApproval(requestID: "approval-1", summary: "Allow file edit")
    ])
    #expect(reattached.events == [
        .sessionStarted(sessionID: reattached.sessionID, threadID: "thread-1", turnID: "turn-1"),
        .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Working"),
        .commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test"),
        .approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "Allow file edit"),
    ])
}

@Test func fakeRelayRecoverySnapshotTracksCompletedStateAndReattachFailure() async throws {
    let harness = try makeRecoveryHarness()
    let hub = FakeRelayLiveSessionHub(
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: harness.adapter,
        title: "Ship reconnect"
    )
    hub.attach(harness.clientA)
    harness.clientA.clearEvents()
    hub.emitSessionEvent(.assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Done"))
    hub.emitSessionEvent(.turnCompleted(turnID: "turn-1"))

    #expect(hub.recoveredSnapshot(sessionID: harness.clientA.sessionID).state == .completed)

    _ = try harness.relay.revoke(deviceID: harness.iPhoneA.identity.id, forHostID: harness.host.identity.id, at: Date(timeIntervalSince1970: 20))
    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: harness.host.identity.id, deviceID: harness.iPhoneA.identity.id)) {
        _ = try harness.attachClientA()
    }
}

private struct RelayRecoveryHarness {
    var relay: FakeRelay
    var host: FakeHostAgentEndpoint
    var iPhoneA: FakeIOSDeviceEndpoint
    var clientA: FakeRelayLiveSessionClient
    var adapter: FakeCodexCLILiveAdapter

    func attachClientA() throws -> FakeRelayLiveSessionClient {
        let attachment = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
        return try relay.openLiveSession(
            from: attachment,
            threadID: "thread-1",
            turnID: "turn-1",
            adapter: adapter
        )
    }
}

private func makeRecoveryHarness() throws -> RelayRecoveryHarness {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = FakeHostAgentEndpoint(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let iPhoneA = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
    )
    let adapter = FakeCodexCLILiveAdapter(script: [])

    _ = try relay.registerHostAgent(host)
    _ = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 1))
    let attachmentA = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let clientA = try relay.openLiveSession(from: attachmentA, threadID: "thread-1", turnID: "turn-1", adapter: adapter)

    return RelayRecoveryHarness(
        relay: relay,
        host: host,
        iPhoneA: iPhoneA,
        clientA: clientA,
        adapter: adapter
    )
}
