import Foundation
import CodexPortShared

public struct HostAgentCodexExecJSONCommand: Equatable, Sendable {
    public static let defaultArguments = ["--skip-git-repo-check", "--json"]

    public var executablePath: String
    public var baseArguments: [String]
    public var resumeArguments: [String]
    public var environment: [String: String]

    public init(
        executablePath: String,
        baseArguments: [String] = HostAgentCodexExecJSONCommand.defaultArguments,
        resumeArguments: [String] = HostAgentCodexExecJSONCommand.defaultArguments,
        environment: [String: String] = [:]
    ) {
        self.executablePath = executablePath
        self.baseArguments = baseArguments
        self.resumeArguments = resumeArguments
        self.environment = environment
    }
}

public struct HostAgentCodexExecJSONProcessInvocation: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var stdin: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        stdin: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
    }
}

public struct HostAgentCodexExecJSONProcessResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct HostAgentCodexExecJSONProcessChunk: Equatable, Sendable {
    public var stdout: String
    public var stderr: String

    public init(stdout: String = "", stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol HostAgentCodexExecJSONProcessRunning: Sendable {
    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult
    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult
}

public extension HostAgentCodexExecJSONProcessRunning {
    func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        try await run(invocation)
    }
}

public enum HostAgentCodexExecJSONAdapterError: Error, Equatable, Sendable {
    case timedOut
}

public struct HostAgentCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    public init() {}

    public func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        try await run(invocation, onChunk: { _ in })
    }

    public func run(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        onChunk: @escaping @Sendable (HostAgentCodexExecJSONProcessChunk) -> Void
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, override in
                override
            }
        }
        if let workingDirectory = invocation.workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let processControl = HostAgentCodexExecJSONProcessControl()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try process.run()
            processControl.setProcess(process)
            let waitTask = Task.detached(priority: .utility) {
                process.waitUntilExit()
            }
            let stdoutTask = Task.detached(priority: .utility) {
                Self.readPipeData(from: stdout.fileHandleForReading) { data in
                    onChunk(.init(stdout: String(decoding: data, as: UTF8.self)))
                }
            }
            let stderrTask = Task.detached(priority: .utility) {
                Self.readPipeData(from: stderr.fileHandleForReading) { data in
                    onChunk(.init(stderr: String(decoding: data, as: UTF8.self)))
                }
            }
            do {
                try stdin.fileHandleForWriting.write(contentsOf: Data(invocation.stdin.utf8))
                try stdin.fileHandleForWriting.close()
                await waitTask.value
                try Task.checkCancellation()
            } catch is CancellationError {
                try? stdin.fileHandleForWriting.close()
                processControl.terminateIfRunning()
                waitTask.cancel()
                stdoutTask.cancel()
                stderrTask.cancel()
                throw CancellationError()
            } catch {
                try? stdin.fileHandleForWriting.close()
                processControl.terminateIfRunning()
                waitTask.cancel()
                stdoutTask.cancel()
                stderrTask.cancel()
                throw error
            }

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value
            try Task.checkCancellation()
            return HostAgentCodexExecJSONProcessResult(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitCode: process.terminationStatus
            )
        } onCancel: {
            processControl.terminateIfRunning()
        }
    }

    private static func readPipeData(
        from fileHandle: FileHandle,
        onData: @escaping @Sendable (Data) -> Void
    ) -> Data {
        var accumulated = Data()
        while true {
            let data = fileHandle.availableData
            guard !data.isEmpty else { break }
            accumulated.append(data)
            onData(data)
        }
        return accumulated
    }
}

private final class HostAgentCodexExecJSONProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func setProcess(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func terminateIfRunning() {
        let process = lock.withLock {
            self.process
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

public final class HostAgentCodexExecJSONAdapter: HostAgentLiveSessionAdapter, @unchecked Sendable {
    private let command: HostAgentCodexExecJSONCommand
    private let sessionID: String
    private let initialThreadID: String
    private let turnID: String
    private let sessionWorkingDirectory: String?
    private let logger: HostAgentLogRecorder
    private let processRunner: HostAgentCodexExecJSONProcessRunning
    private let processTimeout: Duration
    private let lock = NSLock()

    private var started = false
    private var currentCodexThreadID: String?
    private var eventContinuations: [UUID: AsyncStream<RelayLiveSessionEvent>.Continuation] = [:]
    private var streamingOutputBuffers: [String: String] = [:]
    private var streamingOutputWriteIDs: Set<String> = []

    public init(
        command: HostAgentCodexExecJSONCommand,
        sessionID: String,
        initialThreadID: String,
        turnID: String,
        sessionWorkingDirectory: String? = nil,
        logger: HostAgentLogRecorder = HostAgentLogRecorder(),
        processRunner: HostAgentCodexExecJSONProcessRunning = HostAgentCodexExecJSONProcessRunner(),
        processTimeout: Duration = .seconds(120)
    ) {
        self.command = command
        self.sessionID = sessionID
        self.initialThreadID = initialThreadID
        self.turnID = turnID
        self.sessionWorkingDirectory = sessionWorkingDirectory
        self.logger = logger
        self.processRunner = processRunner
        self.processTimeout = processTimeout
    }

    public func events() -> AsyncStream<RelayLiveSessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.eventContinuations[id] = nil
                }
            }
        }
    }

    public func start() throws {
        lock.withLock {
            started = true
            currentCodexThreadID = initialThreadID
        }
        logger.record("codex exec json adapter started executable=\(command.executablePath)")
        emit(.sessionStarted(sessionID: sessionID, threadID: initialThreadID, turnID: turnID))
    }

    public func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        guard isStarted else {
            logger.record("codex exec write failed write=\(write.writeID) reason=not-started")
            return .failed(reason: "Codex CLI exec adapter is not running.")
        }

        switch write {
        case let .prompt(writeID, _, text):
            logger.record("codex exec prompt write=\(writeID) bytes=\(text.utf8.count)")
            return await runPrompt(text, writeID: writeID)
        case let .approval(writeID, requestID, action):
            logger.record("codex exec approval unsupported write=\(writeID) request=\(requestID) action=\(action.codexExecWireValue)")
            return .failed(reason: "Codex CLI exec JSON adapter does not support approvals yet.")
        case let .interrupt(writeID, _, _):
            logger.record("codex exec interrupt write=\(writeID)")
            return .handled
        }
    }

    public func stop() {
        lock.withLock {
            started = false
        }
        logger.record("codex exec json adapter stopped")
        finishEvents()
    }

    private var isStarted: Bool {
        lock.withLock {
            started
        }
    }

    private func runPrompt(_ text: String, writeID: String) async -> RelayWriteStatus {
        let invocation = makeInvocation(prompt: text)
        do {
            let result = try await runProcessWithTimeout(invocation, writeID: writeID)
            logger.record("codex exec completed code=\(result.exitCode) stdoutBytes=\(result.stdout.utf8.count) stderrBytes=\(result.stderr.utf8.count)")
            let alreadyStreamedStdout = hasStreamedStdout(writeID: writeID)
            processStreamingStdout(
                alreadyStreamedStdout ? "" : result.stdout,
                writeID: writeID,
                flushRemainder: true
            )

            guard result.exitCode == 0 else {
                let reason = failureReason(exitCode: result.exitCode, stderr: result.stderr, prompt: text)
                emit(.turnFailed(turnID: turnID, reason: reason))
                return .failed(reason: reason)
            }
            return .handled
        } catch HostAgentCodexExecJSONAdapterError.timedOut {
            let reason = "Codex CLI exec timed out."
            logger.record("codex exec timed out timeout=\(processTimeout)")
            emit(.turnFailed(turnID: turnID, reason: reason))
            return .failed(reason: reason)
        } catch {
            let reason = "Codex CLI exec failed to run."
            logger.record("codex exec failed reasonBytes=\(String(describing: error).utf8.count)")
            emit(.turnFailed(turnID: turnID, reason: reason))
            return .failed(reason: reason)
        }
    }

    private func runProcessWithTimeout(
        _ invocation: HostAgentCodexExecJSONProcessInvocation,
        writeID: String
    ) async throws -> HostAgentCodexExecJSONProcessResult {
        let processRunner = self.processRunner
        let processTimeout = self.processTimeout
        return try await withThrowingTaskGroup(of: HostAgentCodexExecJSONProcessResult.self) { group in
            group.addTask {
                try await processRunner.run(invocation) { [weak self] chunk in
                    guard !chunk.stdout.isEmpty else { return }
                    self?.processStreamingStdout(chunk.stdout, writeID: writeID, flushRemainder: false)
                }
            }
            group.addTask {
                try await Task.sleep(for: processTimeout)
                throw HostAgentCodexExecJSONAdapterError.timedOut
            }
            guard let result = try await group.next() else {
                throw HostAgentCodexExecJSONAdapterError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func processStreamingStdout(_ stdout: String, writeID: String, flushRemainder: Bool) {
        let lines = lock.withLock {
            var buffer = streamingOutputBuffers[writeID, default: ""]
            if !stdout.isEmpty {
                streamingOutputWriteIDs.insert(writeID)
                buffer.append(stdout)
            }
            var completedLines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: "\n") {
                completedLines.append(String(buffer[..<newlineIndex]))
                buffer.removeSubrange(...newlineIndex)
            }
            if flushRemainder, !buffer.isEmpty {
                completedLines.append(buffer)
                buffer = ""
            }
            if flushRemainder {
                streamingOutputBuffers[writeID] = nil
                streamingOutputWriteIDs.remove(writeID)
            } else {
                streamingOutputBuffers[writeID] = buffer
            }
            return completedLines
        }
        let mapper = HostAgentProcessOutputMapper(
            threadID: currentThreadIDForMapping,
            turnID: turnID,
            mode: .codexExecJSONOnly
        )
        for line in lines where !line.isEmpty {
            guard let event = mapper.event(fromLine: line) else { continue }
            let namespacedEvent = namespace(event, writeID: writeID)
            rememberCodexThreadID(from: namespacedEvent)
            emit(namespacedEvent)
        }
    }

    private func hasStreamedStdout(writeID: String) -> Bool {
        lock.withLock {
            streamingOutputWriteIDs.contains(writeID)
        }
    }

    private func failureReason(exitCode: Int32, stderr: String, prompt: String) -> String {
        let summary = sanitizedStderrSummary(stderr, prompt: prompt)
        guard !summary.isEmpty else {
            return "Codex CLI exec failed during prompt execution with exit code \(exitCode)."
        }
        return "Codex CLI exec failed during prompt execution with exit code \(exitCode). stderr: \(summary)"
    }

    private func sanitizedStderrSummary(_ stderr: String, prompt: String) -> String {
        let promptLines = Set(prompt
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let sanitizedLines = stderr
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !promptLines.contains($0) }
        let joined = sanitizedLines.joined(separator: " ")
        guard joined.count > 240 else { return joined }
        return String(joined.prefix(237)) + "..."
    }

    private func makeInvocation(prompt: String) -> HostAgentCodexExecJSONProcessInvocation {
        let codexThreadID = lock.withLock {
            currentCodexThreadID
        }
        let arguments: [String]
        if let codexThreadID {
            arguments = ["exec", "resume"] + command.resumeArguments + [codexThreadID, "-"]
        } else {
            arguments = ["exec"] + command.baseArguments + ["-"]
        }
        return HostAgentCodexExecJSONProcessInvocation(
            executablePath: command.executablePath,
            arguments: arguments,
            environment: command.environment,
            workingDirectory: sessionWorkingDirectory,
            stdin: prompt
        )
    }

    private var currentThreadIDForMapping: String {
        lock.withLock {
            currentCodexThreadID ?? initialThreadID
        }
    }

    private func rememberCodexThreadID(from event: RelayLiveSessionEvent) {
        guard case let .sessionStarted(_, threadID, _) = event else { return }
        lock.withLock {
            currentCodexThreadID = threadID
        }
        logger.record("codex exec thread observed thread=\(threadID)")
    }

    private func namespace(_ event: RelayLiveSessionEvent, writeID: String) -> RelayLiveSessionEvent {
        let namespacedTurnID = "\(turnID)-\(writeID)"
        switch event {
        case let .sessionStarted(sessionID, threadID, _):
            return .sessionStarted(sessionID: sessionID, threadID: threadID, turnID: namespacedTurnID)
        case .threadHistoryLoaded:
            return event
        case let .userMessage(_, itemID, text):
            return .userMessage(turnID: namespacedTurnID, itemID: "\(writeID)-\(itemID)", text: text)
        case let .assistantTextDelta(_, itemID, text):
            return .assistantTextDelta(turnID: namespacedTurnID, itemID: "\(writeID)-\(itemID)", text: text)
        case let .commandOutputDelta(_, itemID, text):
            return .commandOutputDelta(turnID: namespacedTurnID, itemID: "\(writeID)-\(itemID)", text: text)
        case let .fileChange(_, itemID, path, diff):
            return .fileChange(turnID: namespacedTurnID, itemID: "\(writeID)-\(itemID)", path: path, diff: diff)
        case let .approvalRequested(_, requestID, summary):
            return .approvalRequested(turnID: namespacedTurnID, requestID: requestID, summary: summary)
        case .turnCompleted:
            return .turnCompleted(turnID: namespacedTurnID)
        case let .turnFailed(_, reason):
            return .turnFailed(turnID: namespacedTurnID, reason: reason)
        case .writeStatusChanged, .streamClosed:
            return event
        }
    }

    private func emit(_ event: RelayLiveSessionEvent) {
        let continuations = lock.withLock {
            Array(eventContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func finishEvents() {
        let continuations = lock.withLock {
            let continuations = Array(eventContinuations.values)
            eventContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}

private extension RelayApprovalAction {
    var codexExecWireValue: String {
        switch self {
        case .accept:
            "accept"
        case .acceptForSession:
            "accept-for-session"
        case .decline:
            "decline"
        case .cancel:
            "cancel"
        }
    }
}
