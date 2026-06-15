import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func fakeHostAgentWriteQueueSerializesPromptInterruptAndApprovalWrites() async throws {
    let harness = try makeWritePathHarness()
    let queue = FakeHostAgentRelayWriteQueue(adapter: harness.adapter)

    let prompt = RelayLiveSessionWrite.prompt(
        writeID: "write-1",
        threadID: "thread-1",
        text: "hello from iPhone"
    )
    let interrupt = RelayLiveSessionWrite.interrupt(
        writeID: "write-2",
        threadID: "thread-1",
        turnID: "turn-1"
    )
    let approval = RelayLiveSessionWrite.approval(
        writeID: "write-3",
        requestID: "approval-1",
        action: .accept
    )

    #expect(await queue.enqueue(prompt, from: harness.clientA, broadcastTo: [harness.clientA]) == .handled)
    #expect(await queue.enqueue(interrupt, from: harness.clientA, broadcastTo: [harness.clientA]) == .handled)
    #expect(await queue.enqueue(approval, from: harness.clientA, broadcastTo: [harness.clientA]) == .handled)

    #expect(harness.adapter.receivedWrites == [prompt, interrupt, approval])
    #expect(harness.clientA.events == [
        .writeStatusChanged(writeID: "write-1", status: .queued),
        .writeStatusChanged(writeID: "write-1", status: .running),
        .writeStatusChanged(writeID: "write-1", status: .handled),
        .writeStatusChanged(writeID: "write-2", status: .queued),
        .writeStatusChanged(writeID: "write-2", status: .running),
        .writeStatusChanged(writeID: "write-2", status: .handled),
        .writeStatusChanged(writeID: "write-3", status: .queued),
        .writeStatusChanged(writeID: "write-3", status: .running),
        .writeStatusChanged(writeID: "write-3", status: .handled),
    ])
}

@Test func fakeHostAgentWriteQueueBroadcastsHandledStateAndAdapterFailure() async throws {
    let harness = try makeWritePathHarness()
    let clientB = try harness.attachSecondClient()
    harness.adapter.failWrites(withIDs: ["write-fail"], reason: "adapter unavailable")
    let queue = FakeHostAgentRelayWriteQueue(adapter: harness.adapter)

    let approval = RelayLiveSessionWrite.approval(
        writeID: "write-ok",
        requestID: "approval-1",
        action: .decline
    )
    let failingPrompt = RelayLiveSessionWrite.prompt(
        writeID: "write-fail",
        threadID: "thread-1",
        text: "will fail"
    )

    #expect(await queue.enqueue(approval, from: harness.clientA, broadcastTo: [harness.clientA, clientB]) == .handled)
    #expect(await queue.enqueue(failingPrompt, from: clientB, broadcastTo: [harness.clientA, clientB]) == .failed(reason: "adapter unavailable"))

    #expect(harness.adapter.receivedWrites == [approval, failingPrompt])
    #expect(harness.clientA.events.contains(.writeStatusChanged(writeID: "write-ok", status: .handled)))
    #expect(clientB.events.contains(.writeStatusChanged(writeID: "write-ok", status: .handled)))
    #expect(harness.clientA.events.last == .writeStatusChanged(writeID: "write-fail", status: .failed(reason: "adapter unavailable")))
    #expect(clientB.events.last == .writeStatusChanged(writeID: "write-fail", status: .failed(reason: "adapter unavailable")))
}

@Test func fakeHostAgentWriteQueueDoesNotInterleaveConcurrentWrites() async throws {
    let harness = try makeWritePathHarness()
    harness.adapter.delayWrites(withIDs: ["write-slow"])
    let queue = FakeHostAgentRelayWriteQueue(adapter: harness.adapter)
    let slow = RelayLiveSessionWrite.prompt(writeID: "write-slow", threadID: "thread-1", text: "slow")
    let fast = RelayLiveSessionWrite.prompt(writeID: "write-fast", threadID: "thread-1", text: "fast")

    async let slowStatus = queue.enqueue(slow, from: harness.clientA, broadcastTo: [harness.clientA])
    async let fastStatus = queue.enqueue(fast, from: harness.clientA, broadcastTo: [harness.clientA])

    #expect(await [slowStatus, fastStatus] == [.handled, .handled])
    let slowBlock: [RelayLiveSessionEvent] = [
        .writeStatusChanged(writeID: "write-slow", status: .queued),
        .writeStatusChanged(writeID: "write-slow", status: .running),
        .writeStatusChanged(writeID: "write-slow", status: .handled),
    ]
    let fastBlock: [RelayLiveSessionEvent] = [
        .writeStatusChanged(writeID: "write-fast", status: .queued),
        .writeStatusChanged(writeID: "write-fast", status: .running),
        .writeStatusChanged(writeID: "write-fast", status: .handled),
    ]
    #expect(harness.clientA.events == slowBlock + fastBlock || harness.clientA.events == fastBlock + slowBlock)
}

private struct RelayWritePathHarness {
    var relay: FakeRelay
    var host: FakeHostAgentEndpoint
    var clientA: FakeRelayLiveSessionClient
    var adapter: FakeCodexCLILiveAdapter
    var iPhoneB: FakeIOSDeviceEndpoint

    func attachSecondClient() throws -> FakeRelayLiveSessionClient {
        _ = relay.authorize(device: iPhoneB, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 2))
        let attachment = try relay.attach(device: iPhoneB, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
        return try relay.openLiveSession(
            from: attachment,
            threadID: "thread-1",
            turnID: "turn-1",
            adapter: adapter
        )
    }
}

private func makeWritePathHarness() throws -> RelayWritePathHarness {
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
    let attachmentA = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let clientA = try relay.openLiveSession(
        from: attachmentA,
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: adapter
    )

    return RelayWritePathHarness(
        relay: relay,
        host: host,
        clientA: clientA,
        adapter: adapter,
        iPhoneB: iPhoneB
    )
}
