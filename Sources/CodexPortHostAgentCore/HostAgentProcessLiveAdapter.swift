import Foundation
import CodexPortShared

public struct HostAgentProcessCommand: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum HostAgentProcessLifecycle: Equatable, Sendable {
    case idle
    case running(processID: Int32)
    case exited(code: Int32)
    case failed(reason: String)
    case stopped

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

public protocol HostAgentRelayWriteHandling: Sendable {
    func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus
}

public protocol HostAgentLiveSessionAdapter: HostAgentRelayWriteHandling {
    func events() -> AsyncStream<RelayLiveSessionEvent>
    func start() throws
    func stop()
}

public actor HostAgentSerializedWriteQueue<Adapter: HostAgentRelayWriteHandling> {
    private let adapter: Adapter
    private var tailTask: Task<RelayWriteStatus, Never>?

    public init(adapter: Adapter) {
        self.adapter = adapter
    }

    public func enqueue(
        _ write: RelayLiveSessionWrite,
        onStatus: @escaping @Sendable (RelayWriteStatus) -> Void = { _ in }
    ) async -> RelayWriteStatus {
        let previousTask = tailTask
        let adapter = self.adapter
        let task = Task { @Sendable in
            if let previousTask {
                _ = await previousTask.value
            }
            onStatus(.queued)
            onStatus(.running)
            let terminalStatus = await adapter.handle(write)
            onStatus(terminalStatus)
            return terminalStatus
        }
        tailTask = task
        return await task.value
    }
}

public final class HostAgentProcessLiveAdapter: HostAgentLiveSessionAdapter, @unchecked Sendable {
    private let command: HostAgentProcessCommand
    private let sessionID: String
    private let threadID: String
    private let turnID: String
    private let logger: HostAgentLogRecorder
    private let lock = NSLock()

    private var process: Process?
    private var standardInputPipe: Pipe?
    private var standardOutputPipe: Pipe?
    private var standardErrorPipe: Pipe?
    private var lifecycleStorage: HostAgentProcessLifecycle = .idle
    private var eventContinuations: [UUID: AsyncStream<RelayLiveSessionEvent>.Continuation] = [:]
    private var stdoutLineBuffer = ""
    private var stderrLineBuffer = ""
    private var streamedStdoutByteCount = 0
    private var streamedStderrByteCount = 0

    public init(
        command: HostAgentProcessCommand,
        sessionID: String,
        threadID: String,
        turnID: String,
        logger: HostAgentLogRecorder = HostAgentLogRecorder()
    ) {
        self.command = command
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.logger = logger
    }

    public var lifecycle: HostAgentProcessLifecycle {
        lock.withLock {
            lifecycleStorage
        }
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
        let process = Process()
        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, override in
                override
            }
        }
        if let workingDirectory = command.workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        lock.withLock {
            self.process = process
            self.standardInputPipe = standardInputPipe
            self.standardOutputPipe = standardOutputPipe
            self.standardErrorPipe = standardErrorPipe
        }

        logger.record("codex process starting executable=\(command.executablePath) args=\(command.arguments.count)")
        do {
            try process.run()
            lock.withLock {
                lifecycleStorage = .running(processID: process.processIdentifier)
            }
            logger.record("codex process started executable=\(command.executablePath) args=\(command.arguments.count)")
            installLiveOutputHandlers(stdout: standardOutputPipe, stderr: standardErrorPipe, process: process)
            emit(.sessionStarted(sessionID: sessionID, threadID: threadID, turnID: turnID))
        } catch {
            let reason = "Failed to start Codex CLI process."
            lock.withLock {
                lifecycleStorage = .failed(reason: reason)
            }
            logger.record("codex process start failed executable=\(command.executablePath) args=\(command.arguments.count) reasonBytes=\(String(describing: error).utf8.count)")
            throw error
        }
    }

    public func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        guard let handle = lock.withLock({ standardInputPipe?.fileHandleForWriting }) else {
            logger.record("codex write failed write=\(write.writeID) reason=no-stdin")
            return .failed(reason: "Codex CLI process is not accepting input.")
        }

        switch write {
        case let .prompt(writeID, _, text):
            logger.record("codex write prompt write=\(writeID) bytes=\(text.utf8.count)")
            return writeLine(text, to: handle)
        case let .approval(writeID, requestID, action):
            let line = "approval \(requestID) \(action.wireValue)"
            logger.record("codex write approval write=\(writeID) request=\(requestID) action=\(action.wireValue)")
            return writeLine(line, to: handle)
        case let .interrupt(writeID, _, _):
            logger.record("codex write interrupt write=\(writeID)")
            interrupt()
            return .handled
        }
    }

    public func collectUntilExit(timeout: Duration) async throws -> [RelayLiveSessionEvent] {
        guard let process = lock.withLock({ self.process }) else {
            return [.turnFailed(turnID: turnID, reason: "Codex CLI process has not been started.")]
        }

        let exitedBeforeTimeout = await waitUntilExit(process, timeout: timeout)
        if !exitedBeforeTimeout {
            stop()
            throw HostAgentProcessLiveAdapterError.timedOut
        }

        let stdout = readDataToEndOfFile(from: standardOutputPipe)
        let stderr = readDataToEndOfFile(from: standardErrorPipe)
        let exitCode = process.terminationStatus

        lock.withLock {
            if lifecycleStorage != .stopped {
                lifecycleStorage = .exited(code: exitCode)
            }
        }
        logger.record("codex process exited code=\(exitCode) stdoutBytes=\(stdout.count) stderrBytes=\(stderr.count)")

        var events = [RelayLiveSessionEvent.sessionStarted(sessionID: sessionID, threadID: threadID, turnID: turnID)]
        events.append(contentsOf: HostAgentProcessOutputMapper(threadID: threadID, turnID: turnID).events(from: stdout))
        if exitCode != 0 {
            events.append(.turnFailed(turnID: turnID, reason: "Codex CLI process exited with code \(exitCode)."))
        }
        return events
    }

    public func closeInput() {
        lock.withLock {
            try? standardInputPipe?.fileHandleForWriting.close()
        }
    }

    public func stop() {
        let currentProcess = lock.withLock {
            lifecycleStorage = .stopped
            return process
        }
        closeInput()
        if let currentProcess, currentProcess.isRunning {
            currentProcess.terminate()
            currentProcess.waitUntilExit()
        }
        logger.record("codex process stopped")
        finishEvents()
    }

    private func interrupt() {
        closeInput()
        lock.withLock {
            lifecycleStorage = .stopped
        }
        logger.record("codex process interrupted")
    }

    private func writeLine(_ line: String, to handle: FileHandle) -> RelayWriteStatus {
        guard lifecycle.isRunning else {
            logger.record("codex write failed reason=not-running bytes=\(line.utf8.count)")
            return .failed(reason: "Codex CLI process is not running.")
        }
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
            return .handled
        } catch {
            logger.record("codex write failed reasonBytes=\(String(describing: error).utf8.count) bytes=\(line.utf8.count)")
            return .failed(reason: "Codex CLI process write failed.")
        }
    }

    private func readDataToEndOfFile(from pipe: Pipe?) -> Data {
        guard let pipe else { return Data() }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private func installLiveOutputHandlers(stdout: Pipe, stderr: Pipe, process: Process) {
        guard hasEventSubscribers else { return }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeLiveOutput(data, buffer: \.stdoutLineBuffer, byteCount: \.streamedStdoutByteCount)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeLiveOutput(data, buffer: \.stderrLineBuffer, byteCount: \.streamedStderrByteCount)
        }
        process.terminationHandler = { [weak self] process in
            self?.handleLiveProcessTermination(process)
        }
    }

    private var hasEventSubscribers: Bool {
        lock.withLock {
            !eventContinuations.isEmpty
        }
    }

    private func consumeLiveOutput(
        _ data: Data,
        buffer bufferKeyPath: ReferenceWritableKeyPath<HostAgentProcessLiveAdapter, String>,
        byteCount byteCountKeyPath: ReferenceWritableKeyPath<HostAgentProcessLiveAdapter, Int>
    ) {
        let lines: [String] = lock.withLock {
            self[keyPath: byteCountKeyPath] += data.count
            self[keyPath: bufferKeyPath] += String(data: data, encoding: .utf8) ?? ""
            return drainCompleteLines(from: bufferKeyPath)
        }
        let mapper = HostAgentProcessOutputMapper(threadID: threadID, turnID: turnID)
        for line in lines {
            if let event = mapper.event(fromLine: line) {
                emit(event)
            }
        }
    }

    private func drainCompleteLines(from bufferKeyPath: ReferenceWritableKeyPath<HostAgentProcessLiveAdapter, String>) -> [String] {
        var lines: [String] = []
        while let newlineRange = self[keyPath: bufferKeyPath].range(of: "\n") {
            let line = String(self[keyPath: bufferKeyPath][..<newlineRange.lowerBound])
            self[keyPath: bufferKeyPath].removeSubrange(...newlineRange.lowerBound)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private func handleLiveProcessTermination(_ process: Process) {
        let bufferedLines: [String] = lock.withLock {
            var lines: [String] = []
            if !stdoutLineBuffer.isEmpty {
                lines.append(stdoutLineBuffer)
                stdoutLineBuffer = ""
            }
            if !stderrLineBuffer.isEmpty {
                lines.append(stderrLineBuffer)
                stderrLineBuffer = ""
            }
            if lifecycleStorage != .stopped {
                lifecycleStorage = .exited(code: process.terminationStatus)
            }
            return lines
        }
        let mapper = HostAgentProcessOutputMapper(threadID: threadID, turnID: turnID)
        for line in bufferedLines {
            if let event = mapper.event(fromLine: line) {
                emit(event)
            }
        }
        if process.terminationStatus != 0, lifecycle != .stopped {
            emit(.turnFailed(turnID: turnID, reason: "Codex CLI process exited with code \(process.terminationStatus)."))
        }
        logger.record("codex process stream finished code=\(process.terminationStatus) stdoutBytes=\(streamedStdoutBytes) stderrBytes=\(streamedStderrBytes)")
        finishEvents()
    }

    private var streamedStdoutBytes: Int {
        lock.withLock {
            streamedStdoutByteCount
        }
    }

    private var streamedStderrBytes: Int {
        lock.withLock {
            streamedStderrByteCount
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
            standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
            standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func waitUntilExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

public enum HostAgentProcessLiveAdapterError: Error, Equatable, Sendable {
    case timedOut
}

public enum HostAgentProcessOutputMappingMode: Equatable, Sendable {
    case fixtureAndCodexExecJSON
    case codexExecJSONOnly
}

public struct HostAgentProcessOutputMapper: Sendable {
    private let threadID: String
    private let turnID: String
    private let mode: HostAgentProcessOutputMappingMode

    public init(
        threadID: String,
        turnID: String,
        mode: HostAgentProcessOutputMappingMode = .fixtureAndCodexExecJSON
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.mode = mode
    }

    public func events(from data: Data) -> [RelayLiveSessionEvent] {
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap(event(fromLine:))
    }

    public func event(fromLine line: String) -> RelayLiveSessionEvent? {
        if let jsonEvent = eventFromCodexExecJSONLine(line) {
            return jsonEvent
        }
        if isIgnoredCodexExecJSONLine(line) {
            return nil
        }
        if mode == .codexExecJSONOnly {
            return nil
        }
        if let text = line.droppingPrefix("codex:assistant:") {
            return .assistantTextDelta(turnID: turnID, itemID: "process-assistant", text: text)
        }
        if let text = line.droppingPrefix("codex:command:") {
            return .commandOutputDelta(turnID: turnID, itemID: "process-command", text: text)
        }
        if let payload = line.droppingPrefix("codex:file:") {
            let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                return .commandOutputDelta(turnID: turnID, itemID: "process-output", text: line)
            }
            return .fileChange(turnID: turnID, itemID: "process-file", path: parts[0], diff: parts[1])
        }
        if line == "codex:complete" {
            return .turnCompleted(turnID: turnID)
        }
        return .commandOutputDelta(turnID: turnID, itemID: "process-output", text: line)
    }

    private func eventFromCodexExecJSONLine(_ line: String) -> RelayLiveSessionEvent? {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return nil
        }

        switch type {
        case "thread.started":
            guard let threadID = object["thread_id"] as? String ?? object["threadId"] as? String else {
                return nil
            }
            return .sessionStarted(sessionID: threadID, threadID: threadID, turnID: turnID)
        case "item.completed":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else {
                return nil
            }
            let itemID = item["id"] as? String ?? "process-assistant"
            let text = itemText(from: item)
            switch itemType {
            case "agent_message":
                guard let text else { return nil }
                return .assistantTextDelta(turnID: turnID, itemID: itemID, text: text)
            case "commandOutput", "command_output", "commandExecutionOutput":
                guard let text else { return nil }
                return .commandOutputDelta(turnID: turnID, itemID: itemID, text: text)
            case "commandExecution", "command_execution":
                guard let output = item["aggregatedOutput"] as? String
                    ?? item["aggregated_output"] as? String
                    ?? item["output"] as? String
                    ?? text
                else { return nil }
                return .commandOutputDelta(turnID: turnID, itemID: itemID, text: output)
            case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
                guard let output = commandOutputText(from: item["result"]) else { return nil }
                return .commandOutputDelta(turnID: turnID, itemID: itemID, text: output)
            case "fileChange", "file_change", "diff":
                let change = fileChangeDetails(from: item)
                return .fileChange(turnID: turnID, itemID: itemID, path: change.path, diff: change.diff)
            default:
                guard let text else { return nil }
                return .assistantTextDelta(turnID: turnID, itemID: itemID, text: text)
            }
        case "turn.completed":
            return .turnCompleted(turnID: turnID)
        default:
            return nil
        }
    }

    private func isIgnoredCodexExecJSONLine(_ line: String) -> Bool {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return false
        }
        return type == "turn.started"
    }

    private func itemText(from object: [String: Any]) -> String? {
        object["text"] as? String
            ?? object["message"] as? String
            ?? object["content"] as? String
            ?? textContent(from: object["content"] as? [[String: Any]])
            ?? object["delta"] as? String
    }

    private func textContent(from content: [[String: Any]]?) -> String? {
        content?.compactMap { $0["text"] as? String }.joined()
    }

    private func commandOutputText(from result: Any?) -> String? {
        if let text = result as? String {
            return text
        }
        guard let object = result as? [String: Any] else {
            return nil
        }
        if let text = object["text"] as? String ?? object["output"] as? String {
            return text
        }
        if let content = object["content"] as? [[String: Any]] {
            return textContent(from: content)
        }
        if let structured = object["structuredContent"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    private func fileChangeDetails(from object: [String: Any]) -> (path: String, diff: String) {
        if let changes = object["changes"] as? [[String: Any]],
           let first = changes.first {
            return (
                path: first["path"] as? String ?? first["file"] as? String ?? "",
                diff: first["diff"] as? String ?? first["text"] as? String ?? ""
            )
        }
        return (
            path: object["path"] as? String ?? object["file"] as? String ?? "",
            diff: object["diff"] as? String ?? itemText(from: object) ?? ""
        )
    }
}

private extension String {
    func droppingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
