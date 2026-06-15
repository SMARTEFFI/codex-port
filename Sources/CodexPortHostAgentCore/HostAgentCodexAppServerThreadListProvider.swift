import Foundation
import CodexPortShared

public protocol HostAgentThreadListProviding: Sendable {
    func listThreads(limit: Int, cursor: String?) async throws -> RelayThreadListResponse
}

public extension HostAgentThreadListProviding {
    func listThreads(limit: Int) async throws -> [RelayThreadSummarySnapshot] {
        try await listThreads(limit: limit, cursor: nil).threads
    }
}

public protocol HostAgentThreadHistoryProviding: Sendable {
    func history(threadID: String) async throws -> RelayThreadHistorySnapshot
    func historyPage(threadID: String, limit: Int, cursor: String?) async throws -> RelayThreadHistoryPage
}

public extension HostAgentThreadHistoryProviding {
    func historyPage(threadID: String, limit: Int, cursor: String?) async throws -> RelayThreadHistoryPage {
        let snapshot = try await history(threadID: threadID)
        return RelayThreadHistoryPage(
            requestID: "",
            threadID: snapshot.threadID,
            items: snapshot.items,
            status: snapshot.status,
            nextCursor: nil
        )
    }
}

public enum HostAgentThreadListProviderError: Error, Equatable, Sendable {
    case missingResponse(method: String)
    case invalidResponse(method: String)
    case timedOut(method: String)
}

protocol HostAgentAppServerJSONRPCTransporting: Sendable {
    func sendNotification(method: String, params: [String: Any]) throws
    func request(id: Int, method: String, params: [String: Any], timeout: Duration) async throws -> [String: Any]
}

public struct HostAgentCodexAppServerThreadListProvider: HostAgentThreadListProviding, HostAgentThreadHistoryProviding {
    private static let maxHistorySnapshotBytes = 6 * 1024
    private static let maxCommandOutputBytes = 160
    private static let maxFileChangeBytes = 768
    private static let initialHistoryTurnLimit = 10

    private let command: HostAgentProcessCommand
    private let timeout: Duration

    public init(
        command: HostAgentProcessCommand = HostAgentProcessCommand(
            executablePath: HostAgentCodexCommandResolver.executablePath(
                explicitCommand: ProcessInfo.processInfo.environment["CODEXPORT_HOST_AGENT_COMMAND"]
            ),
            arguments: ["app-server", "--listen", "stdio://"]
        ),
        timeout: Duration = .seconds(10)
    ) {
        self.command = command
        self.timeout = timeout
    }

    public func listThreads(limit: Int, cursor: String? = nil) async throws -> RelayThreadListResponse {
        let runner = HostAgentCodexAppServerJSONRPCProcess(command: command)
        return try await runner.withProcess(timeout: timeout) { transport in
            _ = try await transport.request(
                id: 1,
                method: "initialize",
                params: Self.initializeParams(),
                timeout: timeout
            )
            try transport.sendNotification(method: "initialized", params: [:])
            var params: [String: Any] = ["limit": max(1, limit)]
            if let cursor, !cursor.isEmpty {
                params["cursor"] = cursor
            }
            let response = try await transport.request(
                id: 2,
                method: "thread/list",
                params: params,
                timeout: timeout
            )
            return try Self.threadListResponse(from: response)
        }
    }

    public func history(threadID: String) async throws -> RelayThreadHistorySnapshot {
        let runner = HostAgentCodexAppServerJSONRPCProcess(command: command)
        return try await runner.withProcess(timeout: timeout) { transport in
            try await Self.loadHistorySnapshot(threadID: threadID, transport: transport, timeout: timeout)
        }
    }

    public func historyPage(threadID: String, limit: Int, cursor: String?) async throws -> RelayThreadHistoryPage {
        let runner = HostAgentCodexAppServerJSONRPCProcess(command: command)
        return try await runner.withProcess(timeout: timeout) { transport in
            try await Self.loadHistoryPage(
                threadID: threadID,
                limit: limit,
                cursor: cursor,
                transport: transport,
                timeout: timeout
            )
        }
    }

    static func loadHistorySnapshot(
        threadID: String,
        transport: HostAgentAppServerJSONRPCTransporting,
        timeout: Duration
    ) async throws -> RelayThreadHistorySnapshot {
        _ = try await transport.request(
            id: 1,
            method: "initialize",
            params: Self.initializeParams(),
            timeout: timeout
        )
        try transport.sendNotification(method: "initialized", params: [:])
        let response = try await transport.request(
            id: 2,
            method: "thread/resume",
            params: [
                "threadId": threadID,
                "excludeTurns": true,
                "initialTurnsPage": [
                    "limit": initialHistoryTurnLimit,
                    "sortDirection": "desc",
                    "itemsView": "full",
                ],
            ],
            timeout: timeout
        )
        return Self.historySnapshot(from: response, fallbackThreadID: threadID)
    }

    static func loadHistoryPage(
        threadID: String,
        limit: Int,
        cursor: String?,
        transport: HostAgentAppServerJSONRPCTransporting,
        timeout: Duration
    ) async throws -> RelayThreadHistoryPage {
        _ = try await transport.request(
            id: 1,
            method: "initialize",
            params: Self.initializeParams(),
            timeout: timeout
        )
        try transport.sendNotification(method: "initialized", params: [:])
        var turnsPage: [String: Any] = [
            "limit": max(1, limit),
            "sortDirection": "desc",
            "itemsView": "full",
        ]
        if let cursor, !cursor.isEmpty {
            turnsPage["cursor"] = cursor
        }
        let response = try await transport.request(
            id: 2,
            method: "thread/resume",
            params: [
                "threadId": threadID,
                "excludeTurns": true,
                "initialTurnsPage": turnsPage,
            ],
            timeout: timeout
        )
        let snapshot = Self.historySnapshot(from: response, fallbackThreadID: threadID)
        let nextCursor = Self.historyNextCursor(from: response)
        return RelayThreadHistoryPage(
            requestID: "",
            threadID: snapshot.threadID,
            items: snapshot.items,
            status: snapshot.status,
            nextCursor: nextCursor
        )
    }

    public static func initializeParams() -> [String: Any] {
        [
            "clientInfo": [
                "name": "CodexPort Host Agent",
                "version": "0.2.x",
            ],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false,
            ],
        ]
    }

    private static func threadListResponse(from response: [String: Any]) throws -> RelayThreadListResponse {
        let result = response["result"] as? [String: Any]
        let containers: [[String: Any]?] = [
            result,
            response,
        ]
        let threadObjects = containers.compactMap { container -> [[String: Any]]? in
            guard let container else { return nil }
            return container["data"] as? [[String: Any]]
                ?? container["threads"] as? [[String: Any]]
                ?? container["items"] as? [[String: Any]]
        }.first ?? []
        return RelayThreadListResponse(
            threads: threadObjects.compactMap(snapshot(from:)),
            nextCursor: result?["nextCursor"] as? String ?? response["nextCursor"] as? String
        )
    }

    private static func snapshot(from object: [String: Any]) -> RelayThreadSummarySnapshot? {
        guard let id = string("id", in: object) ?? string("sessionId", in: object) else {
            return nil
        }
        let git = object["gitInfo"] as? [String: Any] ?? object["git"] as? [String: Any]
        return RelayThreadSummarySnapshot(
            id: id,
            cwd: string("cwd", in: object),
            updatedAtUnixTime: unixTime(from: object["updatedAt"] ?? object["updated_at"]),
            preview: string("preview", in: object)
                ?? string("name", in: object)
                ?? string("title", in: object)
                ?? string("lastMessage", in: object)
                ?? "",
            gitRepository: git.flatMap { string("repository", in: $0) ?? string("repo", in: $0) ?? string("originUrl", in: $0) },
            gitBranch: git.flatMap { string("branch", in: $0) },
            status: status(from: object["status"] ?? object["state"])
        )
    }

    private static func string(_ key: String, in object: [String: Any]) -> String? {
        object[key] as? String
    }

    private static func unixTime(from value: Any?) -> TimeInterval {
        if let value = value as? TimeInterval {
            return value
        }
        if let value = value as? Int {
            return TimeInterval(value)
        }
        if let value = value as? String,
           let date = ISO8601DateFormatter().date(from: value) {
            return date.timeIntervalSince1970
        }
        return 0
    }

    private static func status(from value: Any?) -> String {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let object = value as? [String: Any],
           let type = object["type"] as? String,
           !type.isEmpty {
            return type
        }
        return "completed"
    }

    public static func historySnapshot(from response: [String: Any], fallbackThreadID: String) -> RelayThreadHistorySnapshot {
        let result = response["result"] as? [String: Any] ?? response
        let thread = result["thread"] as? [String: Any] ?? result
        let threadID = string("id", in: thread)
            ?? string("threadId", in: thread)
            ?? fallbackThreadID
        let turns: [[String: Any]]
        if let page = result["initialTurnsPage"] as? [String: Any],
           let data = page["data"] as? [[String: Any]] {
            turns = data.reversed()
        } else {
            turns = (thread["turns"] as? [[String: Any]]) ?? []
        }
        let items = turns.flatMap { turn -> [RelayThreadHistoryItem] in
            let itemObjects = (turn["items"] as? [[String: Any]])
                ?? (turn["events"] as? [[String: Any]])
                ?? (turn["messages"] as? [[String: Any]])
                ?? []
            return itemObjects.compactMap(historyItem(from:))
        }
        let rawStatus = turns.last.flatMap { $0["status"] } ?? thread["status"]
        return RelayThreadHistorySnapshot(
            threadID: threadID,
            items: cappedHistoryItems(items),
            status: relayRunStatus(from: rawStatus),
            nextCursor: historyNextCursor(from: response)
        )
    }

    private static func historyNextCursor(from response: [String: Any]) -> String? {
        let result = response["result"] as? [String: Any] ?? response
        let page = result["initialTurnsPage"] as? [String: Any]
            ?? result["turnsPage"] as? [String: Any]
        return page?["nextCursor"] as? String
    }

    private static func historyItem(from object: [String: Any]) -> RelayThreadHistoryItem? {
        let type = object["type"] as? String ?? object["kind"] as? String
        let text = object["text"] as? String
            ?? object["message"] as? String
            ?? object["content"] as? String
            ?? textContent(from: object["content"] as? [[String: Any]])
            ?? object["delta"] as? String
        switch type {
        case "userMessage", "user_message", "userInput":
            return text.map(RelayThreadHistoryItem.userMessage)
        case "assistantMessage", "assistant_message", "agentMessage", "message", "plan", "reasoning":
            return text.map(RelayThreadHistoryItem.assistantMessage)
        case "commandOutput", "command_output", "commandExecutionOutput":
            return text.map(RelayThreadHistoryItem.commandOutput)
        case "commandExecution":
            return (object["aggregatedOutput"] as? String ?? object["output"] as? String ?? text).map(RelayThreadHistoryItem.commandOutput)
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return commandOutputText(from: object["result"]).map(RelayThreadHistoryItem.commandOutput)
        case "fileChange", "file_change", "diff":
            if let changes = object["changes"] as? [[String: Any]],
               let first = changes.first {
                return .fileChange(
                    path: first["path"] as? String ?? first["file"] as? String ?? "",
                    diff: first["diff"] as? String ?? first["text"] as? String ?? ""
                )
            }
            return .fileChange(
                path: object["path"] as? String ?? object["file"] as? String ?? "",
                diff: object["diff"] as? String ?? text ?? ""
            )
        default:
            return text.map(RelayThreadHistoryItem.assistantMessage)
        }
    }

    private static func textContent(from content: [[String: Any]]?) -> String? {
        content?.compactMap { $0["text"] as? String }.joined()
    }

    private static func commandOutputText(from result: Any?) -> String? {
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

    private static func cappedHistoryItems(_ items: [RelayThreadHistoryItem]) -> [RelayThreadHistoryItem] {
        let perItemCapped = items.map(cappedHistoryItem)
        var selected: [RelayThreadHistoryItem] = []
        var selectedBytes = 0
        for item in perItemCapped.reversed() {
            let itemBytes = estimatedBytes(of: item)
            if selectedBytes + itemBytes > maxHistorySnapshotBytes, !selected.isEmpty {
                continue
            }
            selected.append(item)
            selectedBytes += itemBytes
        }
        return selected.reversed()
    }

    private static func cappedHistoryItem(_ item: RelayThreadHistoryItem) -> RelayThreadHistoryItem {
        switch item {
        case let .commandOutput(text):
            return .commandOutput(commandOutputSummary(text))
        case let .fileChange(path, diff):
            return .fileChange(path: path, diff: cappedText(diff, maxBytes: maxFileChangeBytes, label: "diff"))
        case .userMessage, .assistantMessage:
            return item
        }
    }

    private static func commandOutputSummary(_ text: String) -> String {
        guard text.utf8.count > maxCommandOutputBytes else {
            return text
        }
        let marker = "[CodexPort output truncated: \(text.utf8.count) bytes]\n"
        return marker + suffix(text, maxBytes: max(0, maxCommandOutputBytes - marker.utf8.count))
    }

    private static func cappedText(_ text: String, maxBytes: Int, label: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let marker = "\n[CodexPort \(label) truncated: \(text.utf8.count) bytes]\n"
        let availableBytes = max(0, maxBytes - marker.utf8.count)
        let headBytes = availableBytes / 2
        let tailBytes = availableBytes - headBytes
        return prefix(text, maxBytes: headBytes) + marker + suffix(text, maxBytes: tailBytes)
    }

    private static func prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = ""
        var byteCount = 0
        for character in text {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= maxBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func suffix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = ""
        var byteCount = 0
        for character in text.reversed() {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= maxBytes else { break }
            result.insert(character, at: result.startIndex)
            byteCount += characterBytes
        }
        return result
    }

    private static func estimatedBytes(of item: RelayThreadHistoryItem) -> Int {
        switch item {
        case let .userMessage(text), let .assistantMessage(text), let .commandOutput(text):
            return text.utf8.count
        case let .fileChange(path, diff):
            return path.utf8.count + diff.utf8.count
        }
    }

    private static func relayRunStatus(from value: Any?) -> RelayThreadRunStatus {
        let raw: String?
        if let string = value as? String {
            raw = string
        } else if let object = value as? [String: Any] {
            raw = object["type"] as? String
        } else {
            raw = nil
        }
        switch raw {
        case "running", "inProgress", "active":
            return .running
        case "interrupting":
            return .interrupting
        case "failed":
            return .failed
        default:
            return .completed
        }
    }
}

private final class HostAgentCodexAppServerJSONRPCProcess: @unchecked Sendable {
    private let command: HostAgentProcessCommand

    init(command: HostAgentProcessCommand) {
        self.command = command
    }

    func withProcess<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable (HostAgentCodexAppServerJSONRPCTransport) async throws -> T
    ) async throws -> T {
        let transport = HostAgentCodexAppServerJSONRPCTransport(command: command)
        try transport.start()
        defer {
            transport.stop()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation(transport)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HostAgentThreadListProviderError.timedOut(method: "thread/list")
            }
            guard let result = try await group.next() else {
                throw HostAgentThreadListProviderError.missingResponse(method: "thread/list")
            }
            group.cancelAll()
            return result
        }
    }
}

public final class HostAgentCodexAppServerJSONRPCTransport: @unchecked Sendable {
    private let command: HostAgentProcessCommand
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var outputBuffer = ""
    private lazy var outputLines: AsyncStream<String> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    public init(command: HostAgentProcessCommand) {
        self.command = command
    }

    public func start() throws {
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, override in
                override
            }
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        _ = outputLines
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }
        try process.run()
    }

    public func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        finish()
    }

    public func sendNotification(method: String, params: [String: Any]) throws {
        try send([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    public func request(
        id: Int,
        method: String,
        params: [String: Any],
        timeout: Duration
    ) async throws -> [String: Any] {
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        for await line in outputLines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard object["id"] as? Int == id else {
                continue
            }
            return object
        }
        throw HostAgentThreadListProviderError.missingResponse(method: method)
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try inputPipe.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }

    private func receive(_ data: Data) {
        let lines = lock.withLock {
            outputBuffer.append(String(decoding: data, as: UTF8.self))
            var completed: [String] = []
            while let newlineIndex = outputBuffer.firstIndex(of: "\n") {
                completed.append(String(outputBuffer[..<newlineIndex]))
                outputBuffer.removeSubrange(...newlineIndex)
            }
            return completed
        }
        for line in lines where !line.isEmpty {
            continuation?.yield(line)
        }
    }

    private func finish() {
        let remaining = lock.withLock {
            guard !outputBuffer.isEmpty else { return nil as String? }
            let line = outputBuffer
            outputBuffer = ""
            return line
        }
        if let remaining {
            continuation?.yield(remaining)
        }
        continuation?.finish()
    }

}

extension HostAgentCodexAppServerJSONRPCTransport: HostAgentAppServerJSONRPCTransporting {}
