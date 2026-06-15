import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentLocalRelayRuntimeSharesOneLiveSessionAcrossTwoClients() async throws {
    let runtime = HostAgentLocalRelayRuntime { _ in
        HostAgentProcessCommand(
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
        )
    }
    let request = HostAgentLocalRelayAttachRequest(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1"
    )

    var clientA = try await runtime.attach(clientID: "iphone-a", request: request).makeAsyncIterator()
    var clientB = try await runtime.attach(clientID: "iphone-b", request: request).makeAsyncIterator()

    defer {
        Task {
            await runtime.stop(sessionID: "session-1")
        }
    }

    #expect(await clientA.next() == .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    #expect(await clientB.next() == .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    #expect(await clientA.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "ready"))
    #expect(await clientB.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "ready"))

    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "thread-1", text: "hello from iphone-a")
    #expect(await runtime.submit(write, from: "iphone-a", sessionID: "session-1") == .handled)

    #expect(await clientA.next() == .writeStatusChanged(writeID: "write-1", status: .queued))
    #expect(await clientA.next() == .writeStatusChanged(writeID: "write-1", status: .running))
    #expect(await clientA.next() == .writeStatusChanged(writeID: "write-1", status: .handled))
    #expect(await clientA.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "hello from iphone-a"))

    #expect(await clientB.next() == .writeStatusChanged(writeID: "write-1", status: .queued))
    #expect(await clientB.next() == .writeStatusChanged(writeID: "write-1", status: .running))
    #expect(await clientB.next() == .writeStatusChanged(writeID: "write-1", status: .handled))
    #expect(await clientB.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "hello from iphone-a"))
}
