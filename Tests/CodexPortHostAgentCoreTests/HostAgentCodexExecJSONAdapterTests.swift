import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func codexExecJSONAdapterResumesInitialThreadThenObservedThreadAndFansOutEvents() async throws {
    let runner = ScriptedCodexExecJSONProcessRunner(results: [
        .success(.init(
            stdout: """
            {"type":"thread.started","thread_id":"019ea65c-1f12-700d-8a41-5d9c3f3cb101"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"first answer"}}
            {"type":"turn.completed"}
            """,
            stderr: "2026-06-08T00:00:00.000000Z WARN plugin noise\n",
            exitCode: 0
        )),
        .success(.init(
            stdout: """
            {"type":"thread.started","thread_id":"019ea65c-1f12-700d-8a41-5d9c3f3cb101"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"second answer"}}
            {"type":"turn.completed"}
            """,
            stderr: "",
            exitCode: 0
        )),
    ])
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(
            executablePath: "/usr/local/bin/codex",
            baseArguments: ["--skip-git-repo-check", "--json"],
            resumeArguments: ["--skip-git-repo-check", "--json"]
        ),
        sessionID: "relay-session-1",
        initialThreadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        turnID: "turn-1",
        processRunner: runner
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriberA = bridge.subscribe().makeAsyncIterator()
    var subscriberB = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriberA.next() == .sessionStarted(sessionID: "relay-session-1", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", turnID: "turn-1"))
    #expect(await subscriberB.next() == .sessionStarted(sessionID: "relay-session-1", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", turnID: "turn-1"))

    let firstWrite = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", text: "first prompt")
    #expect(await bridge.enqueue(firstWrite) == .handled)

    let firstEventsA = await collectNext(6, from: &subscriberA)
    let firstEventsB = await collectNext(6, from: &subscriberB)
    assertEvents(
        firstEventsA,
        contain: firstWriteEvents(writeID: "write-1", itemID: "write-1-item_0", text: "first answer")
    )
    assertEvents(
        firstEventsB,
        contain: firstWriteEvents(writeID: "write-1", itemID: "write-1-item_0", text: "first answer")
    )

    let secondWrite = RelayLiveSessionWrite.prompt(writeID: "write-2", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", text: "second prompt")
    #expect(await bridge.enqueue(secondWrite) == .handled)

    let secondEventsA = await collectNext(6, from: &subscriberA)
    assertEvents(
        secondEventsA,
        contain: firstWriteEvents(writeID: "write-2", itemID: "write-2-item_0", text: "second answer")
    )

    #expect(await runner.snapshotInvocations() == [
        .init(executablePath: "/usr/local/bin/codex", arguments: ["exec", "resume", "--skip-git-repo-check", "--json", "019ea65c-1f12-700d-8a41-5d9c3f3cb101", "-"], stdin: "first prompt"),
        .init(executablePath: "/usr/local/bin/codex", arguments: ["exec", "resume", "--skip-git-repo-check", "--json", "019ea65c-1f12-700d-8a41-5d9c3f3cb101", "-"], stdin: "second prompt"),
    ])
}

@Test func codexExecJSONAdapterDefaultCommandSkipsGitRepoCheckForResume() async throws {
    let runner = ScriptedCodexExecJSONProcessRunner(results: [
        .success(.init(
            stdout: """
            {"type":"thread.started","thread_id":"019ea65c-1f12-700d-8a41-5d9c3f3cb101"}
            {"type":"turn.started"}
            {"type":"turn.completed"}
            """,
            stderr: "",
            exitCode: 0
        )),
    ])
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        turnID: "turn-1",
        processRunner: runner
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriber = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriber.next() == .sessionStarted(sessionID: "relay-session-1", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", turnID: "turn-1"))
    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", text: "hello")

    #expect(await bridge.enqueue(write) == .handled)
    #expect(await runner.snapshotInvocations() == [
        .init(executablePath: "/usr/local/bin/codex", arguments: ["exec", "resume", "--skip-git-repo-check", "--json", "019ea65c-1f12-700d-8a41-5d9c3f3cb101", "-"], stdin: "hello"),
    ])
}

@Test func codexExecJSONAdapterReportsFailedWriteWithoutLeakingPromptToLogs() async throws {
    let promptSecret = "PROMPT_SECRET_41"
    let logger = HostAgentLogRecorder()
    let runner = ScriptedCodexExecJSONProcessRunner(results: [
        .success(.init(stdout: "", stderr: "not authenticated", exitCode: 12)),
    ])
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "relay-thread-placeholder",
        turnID: "turn-1",
        logger: logger,
        processRunner: runner
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriber = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriber.next() == .sessionStarted(sessionID: "relay-session-1", threadID: "relay-thread-placeholder", turnID: "turn-1"))
    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "relay-thread-placeholder", text: promptSecret)

    let expectedReason = "Codex CLI exec failed during prompt execution with exit code 12. stderr: not authenticated"
    #expect(await bridge.enqueue(write) == .failed(reason: expectedReason))
    #expect(await subscriber.next() == .writeStatusChanged(writeID: "write-1", status: .queued))
    #expect(await subscriber.next() == .writeStatusChanged(writeID: "write-1", status: .running))
    let events = await collectNext(2, from: &subscriber)
    assertEvents(events, contain: [
        .turnFailed(turnID: "turn-1", reason: expectedReason),
        .writeStatusChanged(writeID: "write-1", status: .failed(reason: expectedReason)),
    ])
    #expect(!logger.entries.joined(separator: "\n").contains(promptSecret))
}

@Test func codexExecJSONAdapterIncludesSanitizedStderrWhenExecExitsNonZero() async throws {
    let promptSecret = "PROMPT_SECRET_99"
    let logger = HostAgentLogRecorder()
    let runner = ScriptedCodexExecJSONProcessRunner(results: [
        .success(.init(
            stdout: "",
            stderr: "error: session 019ea failed\n\(promptSecret)\nRun with --help for usage\n",
            exitCode: 1
        )),
    ])
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "relay-thread-placeholder",
        turnID: "turn-1",
        logger: logger,
        processRunner: runner
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriber = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriber.next() == .sessionStarted(sessionID: "relay-session-1", threadID: "relay-thread-placeholder", turnID: "turn-1"))
    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "relay-thread-placeholder", text: promptSecret)

    let expectedReason = "Codex CLI exec failed during prompt execution with exit code 1. stderr: error: session 019ea failed Run with --help for usage"
    #expect(await bridge.enqueue(write) == .failed(reason: expectedReason))

    let events = await collectNext(4, from: &subscriber)
    assertEvents(events, contain: [
        .turnFailed(turnID: "turn-1", reason: expectedReason),
        .writeStatusChanged(writeID: "write-1", status: .failed(reason: expectedReason)),
    ])
    #expect(!expectedReason.contains(promptSecret))
    #expect(!logger.entries.joined(separator: "\n").contains(promptSecret))
}

@Test func codexExecJSONAdapterTimesOutHungProcessAndReportsFailedWrite() async throws {
    let runner = HangingCodexExecJSONProcessRunner()
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "relay-thread-placeholder",
        turnID: "turn-1",
        processRunner: runner,
        processTimeout: .milliseconds(10)
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriber = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriber.next() == .sessionStarted(sessionID: "relay-session-1", threadID: "relay-thread-placeholder", turnID: "turn-1"))
    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "relay-thread-placeholder", text: "hello")

    #expect(await bridge.enqueue(write) == .failed(reason: "Codex CLI exec timed out."))
    #expect(await runner.wasCancelled)
    let events = await collectNext(4, from: &subscriber)
    assertEvents(events, contain: [
        .writeStatusChanged(writeID: "write-1", status: .queued),
        .writeStatusChanged(writeID: "write-1", status: .running),
        .turnFailed(turnID: "turn-1", reason: "Codex CLI exec timed out."),
        .writeStatusChanged(writeID: "write-1", status: .failed(reason: "Codex CLI exec timed out.")),
    ])
}

@Test func codexExecJSONAdapterFansOutStdoutEventsBeforeExecProcessExits() async throws {
    let runner = StreamingCodexExecJSONProcessRunner()
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        turnID: "turn-1",
        processRunner: runner,
        processTimeout: .milliseconds(500)
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    let recorder = RelayEventRecorder()
    let recordingTask = Task {
        for await event in bridge.subscribe() {
            await recorder.record(event)
        }
    }

    try bridge.start()
    defer {
        recordingTask.cancel()
        bridge.stop()
    }

    let started = RelayLiveSessionEvent.sessionStarted(
        sessionID: "relay-session-1",
        threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        turnID: "turn-1"
    )
    await waitUntilEvent {
        await recorder.contains(started)
    }
    #expect(await recorder.contains(started))
    let write = RelayLiveSessionWrite.prompt(writeID: "write-stream", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", text: "hello")
    let enqueueTask = Task {
        await bridge.enqueue(write)
    }

    let streamedEvent = RelayLiveSessionEvent.assistantTextDelta(
        turnID: "turn-1-write-stream",
        itemID: "write-stream-item_stream",
        text: "streamed answer"
    )
    await waitUntilEvent(timeout: .milliseconds(250)) {
        await recorder.contains(streamedEvent)
    }
    #expect(await recorder.contains(streamedEvent))
    _ = await enqueueTask.value
}

@Test func codexExecJSONAdapterFansOutCommandAndFileStdoutItemsBeforeExecProcessExits() async throws {
    let runner = StreamingCodexExecJSONToolProcessRunner()
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        turnID: "turn-1",
        processRunner: runner,
        processTimeout: .milliseconds(500)
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    let recorder = RelayEventRecorder()
    let recordingTask = Task {
        for await event in bridge.subscribe() {
            await recorder.record(event)
        }
    }

    try bridge.start()
    defer {
        recordingTask.cancel()
        bridge.stop()
    }

    let write = RelayLiveSessionWrite.prompt(
        writeID: "write-tools",
        threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        text: "run tools"
    )
    let enqueueTask = Task {
        await bridge.enqueue(write)
    }

    let commandEvent = RelayLiveSessionEvent.commandOutputDelta(
        turnID: "turn-1-write-tools",
        itemID: "write-tools-cmd_0",
        text: "swift test\n"
    )
    let fileEvent = RelayLiveSessionEvent.fileChange(
        turnID: "turn-1-write-tools",
        itemID: "write-tools-file_0",
        path: "README.md",
        diff: "+done"
    )
    await waitUntilEvent(timeout: .milliseconds(250)) {
        let hasCommandEvent = await recorder.contains(commandEvent)
        let hasFileEvent = await recorder.contains(fileEvent)
        return hasCommandEvent && hasFileEvent
    }

    #expect(await recorder.contains(commandEvent))
    #expect(await recorder.contains(fileEvent))
    _ = await enqueueTask.value
}

@Test func codexExecJSONAdapterDoesNotReplayStreamedStdoutAfterProcessExit() async throws {
    let runner = CompletingStreamingCodexExecJSONProcessRunner()
    let adapter = HostAgentCodexExecJSONAdapter(
        command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
        sessionID: "relay-session-1",
        initialThreadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101",
        turnID: "turn-1",
        processRunner: runner
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    let recorder = RelayEventRecorder()
    let recordingTask = Task {
        for await event in bridge.subscribe() {
            await recorder.record(event)
        }
    }

    try bridge.start()
    defer {
        recordingTask.cancel()
        bridge.stop()
    }

    let write = RelayLiveSessionWrite.prompt(writeID: "write-stream", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", text: "hello")

    #expect(await bridge.enqueue(write) == .handled)
    let streamedEvent = RelayLiveSessionEvent.assistantTextDelta(
        turnID: "turn-1-write-stream",
        itemID: "write-stream-item_stream",
        text: "streamed answer"
    )
    #expect(await recorder.count(of: streamedEvent) == 1)
}

@Test func codexExecJSONProcessRunnerDrainsOutputWhileProcessIsRunning() async throws {
    let runner = HostAgentCodexExecJSONProcessRunner()
    let script = #"""
    $SIG{ALRM} = sub { exit 42 };
    alarm 2;
    for (1..3000) {
        print STDOUT "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_$_\",\"type\":\"agent_message\",\"text\":\"" . ("x" x 256) . "\"}}\n";
    }
    print STDERR "stderr-ok\n";
    exit 0;
    """#

    let result = try await runner.run(.init(
        executablePath: "/usr/bin/perl",
        arguments: ["-e", script],
        stdin: ""
    ))

    #expect(result.exitCode == 0)
    #expect(result.stdout.contains(#""id":"item_3000""#))
    #expect(result.stderr == "stderr-ok\n")
}

@Test func codexExecJSONProcessRunnerStreamsStdoutBeforeProcessExits() async throws {
    let runner = HostAgentCodexExecJSONProcessRunner()
    let recorder = ProcessChunkRecorder()
    let script = #"""
    $| = 1;
    print "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_stream\",\"type\":\"agent_message\",\"text\":\"runner streamed\"}}\n";
    sleep 1;
    exit 0;
    """#

    let runTask = Task {
        try await runner.run(.init(
            executablePath: "/usr/bin/perl",
            arguments: ["-e", script],
            stdin: ""
        )) { chunk in
            Task {
                await recorder.record(chunk)
            }
        }
    }

    await waitUntilEvent(timeout: .milliseconds(300)) {
        await recorder.stdoutContains("runner streamed")
    }
    #expect(await recorder.stdoutContains("runner streamed"))
    let result = try await runTask.value
    #expect(result.exitCode == 0)
}

@Test func codexExecJSONProcessRunnerRunsInConfiguredWorkingDirectory() async throws {
    let runner = HostAgentCodexExecJSONProcessRunner()
    let workingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexport-working-directory-test", isDirectory: true)
    try? FileManager.default.removeItem(at: workingDirectory)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    let result = try await runner.run(.init(
        executablePath: "/bin/pwd",
        arguments: [],
        workingDirectory: workingDirectory.path,
        stdin: ""
    ))

    #expect(result.exitCode == 0)
    #expect(URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path == workingDirectory.standardizedFileURL.path)
}

private func firstWriteEvents(writeID: String, itemID: String, text: String) -> [RelayLiveSessionEvent] {
    [
        .writeStatusChanged(writeID: writeID, status: .queued),
        .writeStatusChanged(writeID: writeID, status: .running),
        .sessionStarted(sessionID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", threadID: "019ea65c-1f12-700d-8a41-5d9c3f3cb101", turnID: "turn-1-\(writeID)"),
        .assistantTextDelta(turnID: "turn-1-\(writeID)", itemID: itemID, text: text),
        .turnCompleted(turnID: "turn-1-\(writeID)"),
        .writeStatusChanged(writeID: writeID, status: .handled),
    ]
}

private func collectNext(
    _ count: Int,
    from iterator: inout AsyncStream<RelayLiveSessionEvent>.Iterator
) async -> [RelayLiveSessionEvent] {
    var events: [RelayLiveSessionEvent] = []
    for _ in 0..<count {
        if let event = await iterator.next() {
            events.append(event)
        }
    }
    return events
}

private func waitUntilEvent(
    timeout: Duration = .milliseconds(300),
    condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func assertEvents(_ events: [RelayLiveSessionEvent], contain expectedEvents: [RelayLiveSessionEvent]) {
    for expectedEvent in expectedEvents {
        #expect(events.contains(expectedEvent))
    }
}

private actor ScriptedCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    private let results: [Result<HostAgentCodexExecJSONProcessResult, Error>]
    private var index = 0
    private var recordedInvocations: [HostAgentCodexExecJSONProcessInvocation] = []

    init(results: [Result<HostAgentCodexExecJSONProcessResult, Error>]) {
        self.results = results
    }

    func snapshotInvocations() -> [HostAgentCodexExecJSONProcessInvocation] {
        recordedInvocations
    }

    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        recordedInvocations.append(invocation)
        guard results.indices.contains(index) else {
            throw ScriptedCodexExecJSONProcessRunnerError.exhausted
        }
        let result = results[index]
        index += 1
        return try result.get()
    }

    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        try await run(invocation)
    }
}

private enum ScriptedCodexExecJSONProcessRunnerError: Error {
    case exhausted
}

private actor HangingCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    private var cancelled = false

    var wasCancelled: Bool {
        cancelled
    }

    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        try await run(invocation)
    }
}

private actor RelayEventRecorder {
    private var events: [RelayLiveSessionEvent] = []

    func record(_ event: RelayLiveSessionEvent) {
        events.append(event)
    }

    func contains(_ event: RelayLiveSessionEvent) -> Bool {
        events.contains(event)
    }

    func count(of event: RelayLiveSessionEvent) -> Int {
        events.filter { $0 == event }.count
    }
}

private actor ProcessChunkRecorder {
    private var chunks: [HostAgentCodexExecJSONProcessChunk] = []

    func record(_ chunk: HostAgentCodexExecJSONProcessChunk) {
        chunks.append(chunk)
    }

    func stdoutContains(_ needle: String) -> Bool {
        chunks.contains { $0.stdout.contains(needle) }
    }
}

private actor StreamingCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    static let stdout = """
    {"type":"thread.started","thread_id":"019ea65c-1f12-700d-8a41-5d9c3f3cb101"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_stream","type":"agent_message","text":"streamed answer"}}
    """ + "\n"

    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        try await Task.sleep(for: .seconds(60))
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        try await Task.sleep(for: .milliseconds(20))
        onChunk(.init(stdout: Self.stdout))
        try await Task.sleep(for: .seconds(60))
        return .init(stdout: "", stderr: "", exitCode: 0)
    }
}

private actor StreamingCodexExecJSONToolProcessRunner: HostAgentCodexExecJSONProcessRunning {
    static let stdout = """
    {"type":"item.completed","item":{"id":"cmd_0","type":"command_execution","aggregated_output":"swift test\\n"}}
    {"type":"item.completed","item":{"id":"file_0","type":"file_change","path":"README.md","diff":"+done"}}
    """ + "\n"

    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        try await Task.sleep(for: .seconds(60))
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        try await Task.sleep(for: .milliseconds(20))
        onChunk(.init(stdout: Self.stdout))
        try await Task.sleep(for: .seconds(60))
        return .init(stdout: "", stderr: "", exitCode: 0)
    }
}

private actor CompletingStreamingCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        .init(stdout: StreamingCodexExecJSONProcessRunner.stdout, stderr: "", exitCode: 0)
    }

    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        onChunk(.init(stdout: StreamingCodexExecJSONProcessRunner.stdout))
        return .init(stdout: StreamingCodexExecJSONProcessRunner.stdout, stderr: "", exitCode: 0)
    }
}
