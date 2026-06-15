import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func processLiveAdapterStartsMapsOutputAndReportsSuccessfulExit() async throws {
    let logger = HostAgentLogRecorder()
    let adapter = HostAgentProcessLiveAdapter(
        command: HostAgentProcessCommand(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                """
                printf 'codex:assistant:hello from fixture\\n'
                printf 'codex:command:swift test\\n'
                printf 'codex:file:Sources/App.swift:+print("hi")\\n'
                printf 'codex:complete\\n'
                """,
            ]
        ),
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        logger: logger
    )

    try adapter.start()
    let events = try await adapter.collectUntilExit(timeout: .seconds(2))

    #expect(adapter.lifecycle == .exited(code: 0))
    #expect(events == [
        .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
        .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "hello from fixture"),
        .commandOutputDelta(turnID: "turn-1", itemID: "process-command", text: "swift test"),
        .fileChange(turnID: "turn-1", itemID: "process-file", path: "Sources/App.swift", diff: "+print(\"hi\")"),
        .turnCompleted(turnID: "turn-1"),
    ])
    #expect(logger.entries.contains("codex process started executable=/bin/sh args=2"))
    #expect(logger.entries.contains("codex process exited code=0 stdoutBytes=117 stderrBytes=0"))
}

@Test func processOutputMapperMapsCodexExecJSONEvents() throws {
    let mapper = HostAgentProcessOutputMapper(threadID: "thread-fallback", turnID: "turn-fallback")
    let output = """
    {"type":"thread.started","thread_id":"019ea614-099c-7d62-bd25-4a190377ef52"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"codex-port-json-smoke"}}
    {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
    """

    #expect(mapper.events(from: Data(output.utf8)) == [
        .sessionStarted(
            sessionID: "019ea614-099c-7d62-bd25-4a190377ef52",
            threadID: "019ea614-099c-7d62-bd25-4a190377ef52",
            turnID: "turn-fallback"
        ),
        .assistantTextDelta(turnID: "turn-fallback", itemID: "item_0", text: "codex-port-json-smoke"),
        .turnCompleted(turnID: "turn-fallback"),
    ])
}

@Test func processOutputMapperMapsCodexExecJSONCommandAndFileItems() throws {
    let mapper = HostAgentProcessOutputMapper(threadID: "thread-fallback", turnID: "turn-fallback", mode: .codexExecJSONOnly)
    let output = """
    {"type":"item.completed","item":{"id":"cmd_0","type":"command_execution","aggregated_output":"swift test\\n"}}
    {"type":"item.completed","item":{"id":"file_0","type":"file_change","path":"README.md","diff":"+done"}}
    """

    #expect(mapper.events(from: Data(output.utf8)) == [
        .commandOutputDelta(turnID: "turn-fallback", itemID: "cmd_0", text: "swift test\n"),
        .fileChange(turnID: "turn-fallback", itemID: "file_0", path: "README.md", diff: "+done"),
    ])
}

@Test func processLiveAdapterReportsNonZeroExitAsTurnFailure() async throws {
    let adapter = HostAgentProcessLiveAdapter(
        command: HostAgentProcessCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'codex:assistant:before failure\\n'; exit 7"]
        ),
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1"
    )

    try adapter.start()
    let events = try await adapter.collectUntilExit(timeout: .seconds(2))

    #expect(adapter.lifecycle == .exited(code: 7))
    #expect(events == [
        .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
        .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "before failure"),
        .turnFailed(turnID: "turn-1", reason: "Codex CLI process exited with code 7."),
    ])
}

@Test func processLiveAdapterWritesPromptApprovalAndInterruptThroughSerializedQueue() async throws {
    let logger = HostAgentLogRecorder()
    let adapter = HostAgentProcessLiveAdapter(
        command: HostAgentProcessCommand(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                """
                while IFS= read -r line; do
                  printf 'codex:assistant:%s\\n' "$line"
                done
                """,
            ]
        ),
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        logger: logger
    )
    let queue = HostAgentSerializedWriteQueue(adapter: adapter)
    let statusRecorder = HostAgentProcessWriteStatusRecorder()

    try adapter.start()
    let prompt = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "thread-1", text: "private prompt text")
    let approval = RelayLiveSessionWrite.approval(writeID: "write-2", requestID: "approval-1", action: .accept)
    let interrupt = RelayLiveSessionWrite.interrupt(writeID: "write-3", threadID: "thread-1", turnID: "turn-1")

    #expect(await queue.enqueue(prompt) { statusRecorder.record(writeID: prompt.writeID, status: $0) } == .handled)
    #expect(await queue.enqueue(approval) { statusRecorder.record(writeID: approval.writeID, status: $0) } == .handled)
    #expect(await queue.enqueue(interrupt) { statusRecorder.record(writeID: interrupt.writeID, status: $0) } == .handled)

    let events = try await adapter.collectUntilExit(timeout: .seconds(2))

    #expect(statusRecorder.events == [
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
    #expect(events.contains(.assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "private prompt text")))
    #expect(events.contains(.assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "approval approval-1 accept")))
    #expect(adapter.lifecycle == .stopped)
}

@Test func processLiveAdapterStreamsOutputBeforeProcessExit() async throws {
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

    var iterator = adapter.events().makeAsyncIterator()
    try adapter.start()
    defer {
        adapter.stop()
    }

    #expect(await iterator.next() == .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    #expect(await iterator.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "ready"))

    #expect(await adapter.handle(.prompt(writeID: "write-1", threadID: "thread-1", text: "hello while running")) == .handled)
    #expect(await iterator.next() == .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "hello while running"))
}

private final class HostAgentProcessWriteStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [RelayLiveSessionEvent] = []

    var events: [RelayLiveSessionEvent] {
        lock.withLock {
            recordedEvents
        }
    }

    func record(writeID: String, status: RelayWriteStatus) {
        lock.withLock {
            recordedEvents.append(.writeStatusChanged(writeID: writeID, status: status))
        }
    }
}

@Test func processLiveAdapterLogsDoNotContainPromptSecretsOrCommandOutputPlaintext() async throws {
    let promptSecret = "PROMPT_SECRET_98b7c"
    let outputSecret = "COMMAND_OUTPUT_SECRET_31a9"
    let pairingSecret = "pairing-token-this-must-not-leak"
    let apiSecret = "sk-thisMustNotLeak"
    let logger = HostAgentLogRecorder()
    let adapter = HostAgentProcessLiveAdapter(
        command: HostAgentProcessCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'codex:command:\(outputSecret)\\n'"]
        ),
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        logger: logger
    )

    try adapter.start()
    _ = await adapter.handle(.prompt(writeID: "write-secret", threadID: "thread-1", text: "\(promptSecret) \(pairingSecret) \(apiSecret)"))
    _ = try await adapter.collectUntilExit(timeout: .seconds(2))

    let rawLogs = logger.entries.joined(separator: "\n")
    #expect(!rawLogs.contains(promptSecret))
    #expect(!rawLogs.contains(outputSecret))
    #expect(!rawLogs.contains(pairingSecret))
    #expect(!rawLogs.contains(apiSecret))

    let exportedLogs = HostAgentDiagnosticExporter().export(
        logs: logger.entries,
        extraSecretHints: [promptSecret, outputSecret, pairingSecret, apiSecret]
    )
    #expect(!exportedLogs.contains(promptSecret))
    #expect(!exportedLogs.contains(outputSecret))
    #expect(!exportedLogs.contains(pairingSecret))
    #expect(!exportedLogs.contains(apiSecret))
}
