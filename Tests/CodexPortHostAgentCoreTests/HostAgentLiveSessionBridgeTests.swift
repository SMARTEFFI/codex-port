import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentLiveSessionBridgeFansOutProcessEventsAndSerializedWrites() async throws {
    let adapter = HostAgentProcessLiveAdapter(
        command: HostAgentProcessCommand(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                """
                printf 'codex:assistant:ready\\n'
                while IFS= read -r line; do
                  printf 'codex:assistant:%s\\n' "$line"
                done
                """,
            ]
        ),
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1"
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriberA = bridge.subscribe().makeAsyncIterator()
    var subscriberB = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriberA.next() == .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    #expect(await subscriberB.next() == .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    #expect(await subscriberA.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "ready"))
    #expect(await subscriberB.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "ready"))

    let prompt = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "thread-1", text: "hello bridge")
    #expect(await bridge.enqueue(prompt) == .handled)

    #expect(await subscriberA.next() == .writeStatusChanged(writeID: "write-1", status: .queued))
    #expect(await subscriberA.next() == .writeStatusChanged(writeID: "write-1", status: .running))
    #expect(await subscriberA.next() == .writeStatusChanged(writeID: "write-1", status: .handled))
    #expect(await subscriberA.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "hello bridge"))

    #expect(await subscriberB.next() == .writeStatusChanged(writeID: "write-1", status: .queued))
    #expect(await subscriberB.next() == .writeStatusChanged(writeID: "write-1", status: .running))
    #expect(await subscriberB.next() == .writeStatusChanged(writeID: "write-1", status: .handled))
    #expect(await subscriberB.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "hello bridge"))

    bridge.stop()
    #expect(adapter.lifecycle == .stopped)
}
