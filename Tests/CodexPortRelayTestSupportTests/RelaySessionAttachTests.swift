import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func fakeRelaySingleClientAttachOpensCLIBackedSessionStream() async throws {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = relaySessionHost()
    let iPhoneA = relaySessionDevice(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone A")

    _ = try relay.registerHostAgent(host)
    _ = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 1))
    let attachment = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let adapter = FakeCodexCLILiveAdapter(script: [
        .assistantTextChunk(itemID: "assistant-1", text: "Hello"),
        .commandOutputChunk(itemID: "cmd-1", text: "swift test\n"),
        .fileChange(itemID: "file-1", path: "README.md", diff: "+hi"),
        .turnCompleted,
    ])

    let client = try relay.openLiveSession(
        from: attachment,
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: adapter
    )
    try await client.runAdapterScript()

    #expect(client.events == [
        .sessionStarted(sessionID: client.sessionID, threadID: "thread-1", turnID: "turn-1"),
        .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Hello"),
        .commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test\n"),
        .fileChange(turnID: "turn-1", itemID: "file-1", path: "README.md", diff: "+hi"),
        .turnCompleted(turnID: "turn-1"),
    ])

    let telemetry = try #require(relay.telemetry(for: client.streamID))
    #expect(telemetry.metadata.tags["purpose"] == "codex-live-session")
    #expect(telemetry.hostToDeviceByteCount > 0)
    #expect(relay.plaintextInspectionLog.isEmpty)
}

@Test func fakeRelaySessionReportsAdapterFailureAndStreamClose() async throws {
    var clock = ManualRelaySessionClock(now: Date(timeIntervalSince1970: 10))
    let relay = FakeRelay(supportedVersions: [.v0_2_0], now: { clock.now })
    let host = relaySessionHost()
    let iPhoneA = relaySessionDevice(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone A")

    _ = try relay.registerHostAgent(host)
    _ = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: clock.now)
    let attachment = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let adapter = FakeCodexCLILiveAdapter(script: [
        .turnFailed(reason: "adapter failed")
    ])

    let client = try relay.openLiveSession(
        from: attachment,
        threadID: "thread-1",
        turnID: "turn-1",
        adapter: adapter
    )
    try await client.runAdapterScript()

    #expect(client.events == [
        .sessionStarted(sessionID: client.sessionID, threadID: "thread-1", turnID: "turn-1"),
        .turnFailed(turnID: "turn-1", reason: "adapter failed"),
    ])

    clock.advance(by: 2)
    client.close(errorCode: "relay.closed")

    #expect(client.events.last == .streamClosed(sessionID: client.sessionID, threadID: "thread-1", errorCode: "relay.closed"))
    let telemetry = try #require(relay.telemetry(for: client.streamID))
    #expect(telemetry.metadata.closedAt == Date(timeIntervalSince1970: 12))
    #expect(telemetry.metadata.errorCode == "relay.closed")
}

private func relaySessionHost() -> FakeHostAgentEndpoint {
    FakeHostAgentEndpoint(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
}

private func relaySessionDevice(id: String, name: String) -> FakeIOSDeviceEndpoint {
    FakeIOSDeviceEndpoint(
        id: UUID(uuidString: id)!,
        displayName: name,
        publicKey: EndpointPublicKey(rawValue: Data("\(name)-public-key".utf8))
    )
}

private struct ManualRelaySessionClock {
    var now: Date

    mutating func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
