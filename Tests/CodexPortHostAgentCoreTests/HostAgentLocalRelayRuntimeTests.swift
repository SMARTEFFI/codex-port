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

@Test func hostAgentLocalRelayRuntimeTreatsDuplicateWriteIDsAsIdempotent() async throws {
    let adapter = CountingHostAgentLiveSessionAdapter()
    let runtime = HostAgentLocalRelayRuntime { _ in
        AnyHostAgentLiveSessionAdapter(adapter, description: "counting adapter")
    }
    let request = HostAgentLocalRelayAttachRequest(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1"
    )

    _ = try await runtime.attach(clientID: "iphone-a", request: request)

    let prompt = RelayLiveSessionWrite.prompt(writeID: "write-same", threadID: "thread-1", text: "hello once")
    #expect(await runtime.submit(prompt, from: "iphone-a", sessionID: "session-1") == .handled)
    #expect(await runtime.submit(prompt, from: "iphone-a", sessionID: "session-1") == .handled)

    let approval = RelayLiveSessionWrite.approval(writeID: "approval-same", requestID: "approval-1", action: .accept)
    #expect(await runtime.submit(approval, from: "iphone-a", sessionID: "session-1") == .handled)
    #expect(await runtime.submit(approval, from: "iphone-a", sessionID: "session-1") == .handled)

    let interrupt = RelayLiveSessionWrite.interrupt(writeID: "interrupt-same", threadID: "thread-1", turnID: "turn-1")
    #expect(await runtime.submit(interrupt, from: "iphone-a", sessionID: "session-1") == .handled)
    #expect(await runtime.submit(interrupt, from: "iphone-a", sessionID: "session-1") == .handled)

    #expect(await adapter.handledWrites == [prompt, approval, interrupt])
}

private final class CountingHostAgentLiveSessionAdapter: HostAgentLiveSessionAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var handledWritesStorage: [RelayLiveSessionWrite] = []

    var handledWrites: [RelayLiveSessionWrite] {
        lock.withLock {
            handledWritesStorage
        }
    }

    func start() throws {}

    func stop() {}

    func events() -> AsyncStream<RelayLiveSessionEvent> {
        AsyncStream { continuation in
            continuation.yield(.sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
        }
    }

    func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        lock.withLock {
            handledWritesStorage.append(write)
        }
        return .handled
    }
}
