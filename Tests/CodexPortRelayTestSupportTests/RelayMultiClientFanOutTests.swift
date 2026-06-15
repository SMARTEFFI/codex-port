import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func fakeRelayFansOutPromptApprovalAndInterruptAcrossTwoIPhones() async throws {
    let harness = try makeFanOutHarness()
    let hub = FakeRelayLiveSessionHub(
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: harness.adapter
    )
    hub.attach(harness.clientA)
    hub.attach(harness.clientB)
    harness.clientA.clearEvents()
    harness.clientB.clearEvents()

    let promptFromA = RelayLiveSessionWrite.prompt(writeID: "write-a", threadID: "thread-1", text: "from A")
    #expect(await hub.enqueue(promptFromA, from: harness.clientA) == .handled)

    #expect(harness.clientB.events == [
        .writeStatusChanged(writeID: "write-a", status: .queued),
        .writeStatusChanged(writeID: "write-a", status: .running),
        .assistantTextDelta(turnID: "turn-1", itemID: "write-a-assistant", text: "reply to from A"),
        .turnCompleted(turnID: "turn-1"),
        .writeStatusChanged(writeID: "write-a", status: .handled),
    ])

    harness.clientA.clearEvents()
    harness.clientB.clearEvents()

    let promptFromB = RelayLiveSessionWrite.prompt(writeID: "write-b", threadID: "thread-1", text: "from B")
    #expect(await hub.enqueue(promptFromB, from: harness.clientB) == .handled)
    #expect(harness.clientA.events == [
        .writeStatusChanged(writeID: "write-b", status: .queued),
        .writeStatusChanged(writeID: "write-b", status: .running),
        .assistantTextDelta(turnID: "turn-1", itemID: "write-b-assistant", text: "reply to from B"),
        .turnCompleted(turnID: "turn-1"),
        .writeStatusChanged(writeID: "write-b", status: .handled),
    ])

    harness.clientA.clearEvents()
    harness.clientB.clearEvents()

    let approval = RelayLiveSessionWrite.approval(writeID: "approval-write", requestID: "approval-1", action: .accept)
    #expect(await hub.enqueue(approval, from: harness.clientA) == .handled)
    #expect(harness.clientA.events.contains(.writeStatusChanged(writeID: "approval-write", status: .handled)))
    #expect(harness.clientB.events.contains(.writeStatusChanged(writeID: "approval-write", status: .handled)))
    #expect(hub.handledApprovalRequestIDs == ["approval-1"])

    harness.clientA.clearEvents()
    harness.clientB.clearEvents()

    let interrupt = RelayLiveSessionWrite.interrupt(writeID: "interrupt-write", threadID: "thread-1", turnID: "turn-1")
    #expect(await hub.enqueue(interrupt, from: harness.clientB) == .handled)
    #expect(harness.clientA.events == [
        .writeStatusChanged(writeID: "interrupt-write", status: .queued),
        .writeStatusChanged(writeID: "interrupt-write", status: .running),
        .turnCompleted(turnID: "turn-1"),
        .writeStatusChanged(writeID: "interrupt-write", status: .handled),
    ])
    #expect(harness.clientB.events == harness.clientA.events)
}

@Test func fakeRelayFanOutStopsDetachedClientsAndReattachesWithVisibleState() async throws {
    let harness = try makeFanOutHarness()
    let hub = FakeRelayLiveSessionHub(
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: harness.adapter
    )
    hub.attach(harness.clientA)
    hub.attach(harness.clientB)
    harness.clientA.clearEvents()
    harness.clientB.clearEvents()
    hub.detach(harness.clientB)

    let prompt = RelayLiveSessionWrite.prompt(writeID: "write-a", threadID: "thread-1", text: "from A")
    #expect(await hub.enqueue(prompt, from: harness.clientA) == .handled)
    #expect(harness.clientB.events.isEmpty)

    let reattachedB = try harness.attachClientB()
    hub.attach(reattachedB)

    #expect(reattachedB.events == [
        .sessionStarted(sessionID: reattachedB.sessionID, threadID: "thread-1", turnID: "turn-1"),
        .writeStatusChanged(writeID: "write-a", status: .queued),
        .writeStatusChanged(writeID: "write-a", status: .running),
        .assistantTextDelta(turnID: "turn-1", itemID: "write-a-assistant", text: "reply to from A"),
        .turnCompleted(turnID: "turn-1"),
        .writeStatusChanged(writeID: "write-a", status: .handled),
    ])
}

private struct RelayFanOutHarness {
    var relay: FakeRelay
    var host: FakeHostAgentEndpoint
    var adapter: FakeCodexCLILiveAdapter
    var clientA: FakeRelayLiveSessionClient
    var clientB: FakeRelayLiveSessionClient
    var iPhoneB: FakeIOSDeviceEndpoint

    func attachClientB() throws -> FakeRelayLiveSessionClient {
        let attachment = try relay.attach(device: iPhoneB, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
        return try relay.openLiveSession(
            from: attachment,
            threadID: "thread-1",
            turnID: "turn-1",
            adapter: adapter
        )
    }
}

private func makeFanOutHarness() throws -> RelayFanOutHarness {
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
    let iPhoneB = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone B",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-b-public-key".utf8))
    )
    let adapter = FakeCodexCLILiveAdapter(script: [])

    _ = try relay.registerHostAgent(host)
    _ = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 1))
    _ = relay.authorize(device: iPhoneB, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 2))
    let attachmentA = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let attachmentB = try relay.attach(device: iPhoneB, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let clientA = try relay.openLiveSession(from: attachmentA, threadID: "thread-1", turnID: "turn-1", adapter: adapter)
    let clientB = try relay.openLiveSession(from: attachmentB, threadID: "thread-1", turnID: "turn-1", adapter: adapter)

    return RelayFanOutHarness(
        relay: relay,
        host: host,
        adapter: adapter,
        clientA: clientA,
        clientB: clientB,
        iPhoneB: iPhoneB
    )
}
