import Foundation
import CodexPortShared

public struct CodexAppServerControlRequest: Equatable, Sendable {
    public var method: String
    public var params: ControlJSONValue

    public init(method: String, params: ControlJSONValue) {
        self.method = method
        self.params = params
    }
}

public enum CodexAppServerControlProducerError: Error, Equatable, Sendable, CustomStringConvertible {
    case requestFailed(String)

    public var description: String {
        switch self {
        case let .requestFailed(reason):
            return reason
        }
    }
}

public protocol CodexAppServerControlTransporting: Sendable {
    func connect() async throws
    func notifications() async -> AsyncStream<ControlJSONRPCNotification>
    func request(method: String, params: ControlJSONValue) async throws -> ControlJSONValue
    func close() async
}

public final class CodexAppServerControlSocketLiveProducer: CodexCLILiveProducing, @unchecked Sendable {
    private let transport: CodexAppServerControlTransporting
    private let clientName: String
    private let lock = NSLock()

    private var session: CodexCLILiveSessionDescriptor?
    private var eventContinuations: [UUID: AsyncStream<CodexCLILiveProducerEvent>.Continuation] = [:]
    private var notificationTask: Task<Void, Never>?
    private var pendingPrompts: [CodexCLILivePrompt] = []
    private var emittedUserMessageKeys = Set<String>()

    public init(
        transport: CodexAppServerControlTransporting = CodexAppServerControlWebSocketTransport(),
        clientName: String = "CodexPort HostAgent"
    ) {
        self.transport = transport
        self.clientName = clientName
    }

    public func events() async -> AsyncStream<CodexCLILiveProducerEvent> {
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

    public func start(session: CodexCLILiveSessionDescriptor) async throws {
        lock.withLock {
            self.session = session
        }
        try await transport.connect()
        let notifications = await transport.notifications()
        notificationTask = Task { [weak self] in
            for await notification in notifications {
                self?.handle(notification)
            }
            self?.finishEvents()
        }
        _ = try await transport.request(
            method: "initialize",
            params: Self.initializeParams(clientName: clientName)
        )
        _ = try await transport.request(
            method: "thread/resume",
            params: .object(["threadId": .string(session.threadID)])
        )
        emit(.sessionOpened(session))
    }

    public func submitPrompt(_ prompt: CodexCLILivePrompt) async -> CodexCLILiveProducerWriteResult {
        do {
            lock.withLock {
                pendingPrompts.append(prompt)
            }
            _ = try await transport.request(
                method: "turn/start",
                params: Self.turnStartParams(threadID: prompt.threadID, text: prompt.text)
            )
            return .accepted
        } catch let error as CodexAppServerControlProducerError {
            removePendingPrompt(writeID: prompt.writeID)
            return .rejected(reason: error.description)
        } catch {
            removePendingPrompt(writeID: prompt.writeID)
            return .rejected(reason: "Codex app-server control request failed.")
        }
    }

    public func stop() async {
        notificationTask?.cancel()
        notificationTask = nil
        await transport.close()
        finishEvents()
    }

    private func handle(_ notification: ControlJSONRPCNotification) {
        switch notification.method {
        case "turn/started", "turnStarted":
            guard let turnID = Self.turnID(from: notification.params) else { return }
            if let event = popPendingPromptEvent(turnID: turnID) {
                emit(event)
            }
        case "item/started", "itemStarted":
            for event in Self.startedItemEvents(from: notification.params) {
                emitUserMessageDeduplicated(event)
            }
        case "item/agentMessage/delta", "agentMessage/delta":
            guard let mapped = Self.agentMessageDeltaEvent(from: notification.params) else { return }
            emit(mapped)
        case "item/completed", "itemCompleted":
            for event in Self.completedItemEvents(from: notification.params) {
                emitUserMessageDeduplicated(event)
            }
        case "turn/completed", "turnCompleted":
            guard let turnID = Self.turnID(from: notification.params) else { return }
            emit(.turnCompleted(turnID: turnID))
        case "turn/failed", "turnFailed":
            guard let object = notification.params.object,
                  let turnID = Self.turnID(from: notification.params)
            else { return }
            let reason = object["reason"]?.string
                ?? object["turn"]?.object?["error"]?.string
                ?? "Codex turn failed."
            emit(.turnFailed(turnID: turnID, reason: reason))
        default:
            break
        }
    }

    private static func initializeParams(clientName: String) -> ControlJSONValue {
        .object([
            "clientInfo": .object([
                "name": .string(clientName),
                "title": .null,
                "version": .string("0.2.x"),
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "requestAttestation": .bool(false),
                "optOutNotificationMethods": .array([]),
            ]),
        ])
    }

    private static func turnStartParams(threadID: String, text: String) -> ControlJSONValue {
        .object([
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "text_elements": .array([]),
                ]),
            ]),
        ])
    }

    private static func agentMessageDeltaEvent(from params: ControlJSONValue) -> CodexCLILiveProducerEvent? {
        guard let object = params.object else { return nil }
        guard let turnID = turnID(from: params) else { return nil }
        let itemID = object["itemId"]?.string ?? object["itemID"]?.string ?? "agent-message"
        let text = object["delta"]?.string ?? object["text"]?.string ?? object["chunk"]?.string
        guard let text else { return nil }
        return .assistantTextDelta(turnID: turnID, itemID: itemID, text: text)
    }

    private static func startedItemEvents(from params: ControlJSONValue) -> [CodexCLILiveProducerEvent] {
        guard let object = params.object else { return [] }
        guard let turnID = turnID(from: params) else { return [] }
        let item = object["item"]?.object ?? object
        if let userEvent = userMessageEvent(from: item, outerObject: object, turnID: turnID) {
            return [userEvent]
        }
        if let toolEvent = toolStartedEvent(from: item, outerObject: object, turnID: turnID) {
            return [toolEvent]
        }
        return []
    }

    private static func completedItemEvents(from params: ControlJSONValue) -> [CodexCLILiveProducerEvent] {
        guard let object = params.object else { return [] }
        guard let turnID = turnID(from: params) else { return [] }
        let item = object["item"]?.object ?? object
        let itemID = item["id"]?.string ?? object["itemId"]?.string ?? object["itemID"]?.string ?? "completed-item"
        let type = item["type"]?.string ?? item["kind"]?.string ?? ""
        if let userEvent = userMessageEvent(from: item, outerObject: object, turnID: turnID) {
            return [userEvent]
        }
        if type == "agent_message" || type == "agentMessage" || type == "assistant_message" {
            let text = item["text"]?.string ?? item["message"]?.string ?? item["content"]?.string
            if let text {
                return [.assistantTextDelta(turnID: turnID, itemID: itemID, text: text)]
            }
        }
        if isCommandOutputItemType(type) {
            let text = commandOutputText(from: item)
            if let text {
                return [.commandOutputDelta(turnID: turnID, itemID: itemID, text: text)]
            }
        }
        return []
    }

    private static func userMessageEvent(
        from item: [String: ControlJSONValue],
        outerObject: [String: ControlJSONValue],
        turnID: String
    ) -> CodexCLILiveProducerEvent? {
        let type = item["type"]?.string ?? item["kind"]?.string ?? ""
        guard type == "userMessage" || type == "user_message" || type == "userInput" else { return nil }
        let itemID = item["id"]?.string
            ?? outerObject["itemId"]?.string
            ?? outerObject["itemID"]?.string
            ?? "user-message"
        guard let text = itemText(from: item) else { return nil }
        return .userMessage(turnID: turnID, itemID: itemID, text: text)
    }

    private static func toolStartedEvent(
        from item: [String: ControlJSONValue],
        outerObject: [String: ControlJSONValue],
        turnID: String
    ) -> CodexCLILiveProducerEvent? {
        let type = item["type"]?.string ?? item["kind"]?.string ?? ""
        guard isCommandOutputItemType(type) else { return nil }
        let itemID = item["id"]?.string
            ?? outerObject["itemId"]?.string
            ?? outerObject["itemID"]?.string
            ?? "tool-started"
        if isCommandExecutionItemType(type), let command = commandLine(from: item) {
            return .commandOutputDelta(turnID: turnID, itemID: itemID, text: "$ \(command)\n")
        }
        let label = toolLabel(from: item, fallbackType: type)
        if let path = readFilePath(from: item, label: label) {
            return .commandOutputDelta(turnID: turnID, itemID: itemID, text: "读取文件：\(path)\n")
        }
        return .commandOutputDelta(turnID: turnID, itemID: itemID, text: "工具调用：\(label)\n")
    }

    private static func isCommandOutputItemType(_ type: String) -> Bool {
        switch type {
        case "command_output", "commandOutput", "exec",
             "commandExecution", "command_execution", "commandExecutionOutput",
             "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return true
        default:
            return false
        }
    }

    private static func isCommandExecutionItemType(_ type: String) -> Bool {
        switch type {
        case "commandExecution", "command_execution", "commandExecutionOutput", "exec":
            return true
        default:
            return false
        }
    }

    private static func toolLabel(from item: [String: ControlJSONValue], fallbackType: String) -> String {
        item["name"]?.string
            ?? item["toolName"]?.string
            ?? item["tool_name"]?.string
            ?? item["title"]?.string
            ?? fallbackType
    }

    private static func itemText(from item: [String: ControlJSONValue]) -> String? {
        if let text = item["text"]?.string ?? item["message"]?.string ?? item["delta"]?.string {
            return text
        }
        if let content = item["content"] {
            if let text = content.string {
                return text
            }
            let joined = content.array?
                .compactMap { contentItemText(from: $0) }
                .joined()
            if let joined, !joined.isEmpty {
                return joined
            }
        }
        return nil
    }

    private static func commandOutputText(from result: ControlJSONValue?) -> String? {
        guard let result else { return nil }
        if let text = result.string {
            return text
        }
        guard let object = result.object else {
            return nil
        }
        if let text = object["text"]?.string ?? object["output"]?.string {
            return text
        }
        if let content = object["content"]?.array {
            let joined = content.compactMap { contentItemText(from: $0) }.joined()
            if !joined.isEmpty {
                return joined
            }
        }
        if let structured = object["structuredContent"]?.foundationValue,
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    private static func commandOutputText(from item: [String: ControlJSONValue]) -> String? {
        if isCommandExecutionItemType(item["type"]?.string ?? item["kind"]?.string ?? "") {
            let output = rawCommandOutputText(from: item) ?? ""
            if let command = commandLine(from: item) {
                let prefix = "$ \(command)\n"
                return output.hasPrefix(prefix) ? output : prefix + output
            }
            return output.isEmpty ? nil : output
        }
        let type = item["type"]?.string ?? item["kind"]?.string ?? ""
        if isNamedToolCallItemType(type),
           let output = rawCommandOutputText(from: item) {
            guard let label = toolLabelIfPresent(from: item) else {
                return output
            }
            if let path = readFilePath(from: item, label: label) {
                return prependingReadFile(path, to: output)
            }
            return prependingToolLabel(label, to: output)
        }
        return rawCommandOutputText(from: item)
    }

    private static func rawCommandOutputText(from item: [String: ControlJSONValue]) -> String? {
        for key in ["text", "aggregatedOutput", "aggregated_output", "output"] {
            if let text = item[key]?.string {
                return text
            }
        }
        if let content = item["content"] {
            if let text = content.string {
                return text
            }
            let joined = content.array?.compactMap { contentItemText(from: $0) }.joined()
            if let joined, !joined.isEmpty {
                return joined
            }
        }
        return commandOutputText(from: item["result"])
    }

    private static func toolLabelIfPresent(from item: [String: ControlJSONValue]) -> String? {
        item["name"]?.string
            ?? item["toolName"]?.string
            ?? item["tool_name"]?.string
            ?? item["title"]?.string
    }

    private static func isNamedToolCallItemType(_ type: String) -> Bool {
        switch type {
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return true
        default:
            return false
        }
    }

    private static func commandLine(from item: [String: ControlJSONValue]) -> String? {
        for key in ["command", "cmd"] {
            if let command = commandLine(from: item[key]) {
                return command
            }
        }
        for key in ["arguments", "args", "argv"] {
            if let command = commandLine(fromArgumentArray: item[key]) {
                return command
            }
        }
        return nil
    }

    private static func commandLine(from value: ControlJSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.string {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = value.array {
            let command = array.compactMap(\.string).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        guard let object = value.object else { return nil }
        for key in ["text", "command", "cmd", "shell"] {
            if let command = commandLine(from: object[key]) {
                return command
            }
        }
        for key in ["arguments", "args", "argv"] {
            if let command = commandLine(fromArgumentArray: object[key]) {
                return command
            }
        }
        return nil
    }

    private static func commandLine(fromArgumentArray value: ControlJSONValue?) -> String? {
        guard let array = value?.array else { return nil }
        let command = array.compactMap(\.string).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    private static func readFilePath(from item: [String: ControlJSONValue], label: String) -> String? {
        let normalizedLabel = label.lowercased()
        guard normalizedLabel.contains("read") || normalizedLabel.contains("file") else {
            return nil
        }
        for key in ["path", "file", "filePath", "file_path"] {
            if let path = nonEmptyString(item[key]) {
                return lastPathComponent(path)
            }
        }
        for key in ["arguments", "args", "input"] {
            if let path = readFilePath(from: item[key]) {
                return path
            }
        }
        return nil
    }

    private static func readFilePath(from value: ControlJSONValue?) -> String? {
        guard let value else { return nil }
        if let string = nonEmptyString(value) {
            return lastPathComponent(string)
        }
        if let object = value.object {
            for key in ["path", "file", "filePath", "file_path"] {
                if let path = nonEmptyString(object[key]) {
                    return lastPathComponent(path)
                }
            }
        }
        return nil
    }

    private static func nonEmptyString(_ value: ControlJSONValue?) -> String? {
        let trimmed = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }

    private static func prependingReadFile(_ path: String, to output: String) -> String {
        let prefix = "读取文件：\(path)\n"
        return output.hasPrefix(prefix) ? output : prefix + output
    }

    private static func prependingToolLabel(_ label: String, to output: String) -> String {
        let prefix = "工具调用：\(label)\n"
        return output.hasPrefix(prefix) ? output : prefix + output
    }

    private static func contentItemText(from value: ControlJSONValue) -> String? {
        guard let object = value.object else { return value.string }
        switch object["type"]?.string {
        case "text", "input_text", "output_text", nil:
            return object["text"]?.string
        default:
            return object["text"]?.string
        }
    }

    private static func turnID(from params: ControlJSONValue) -> String? {
        guard let object = params.object else { return nil }
        return object["turnId"]?.string
            ?? object["turnID"]?.string
            ?? object["turn"]?.object?["id"]?.string
    }

    private func emit(_ event: CodexCLILiveProducerEvent) {
        let continuations = lock.withLock {
            Array(eventContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func emitUserMessageDeduplicated(_ event: CodexCLILiveProducerEvent) {
        guard case let .userMessage(turnID, _, text) = event else {
            emit(event)
            return
        }
        let shouldEmit = lock.withLock {
            emittedUserMessageKeys.insert(Self.userMessageKey(turnID: turnID, text: text)).inserted
        }
        guard shouldEmit else { return }
        emit(event)
    }

    private func popPendingPromptEvent(turnID: String) -> CodexCLILiveProducerEvent? {
        lock.withLock {
            guard !pendingPrompts.isEmpty else { return nil }
            let prompt = pendingPrompts.removeFirst()
            emittedUserMessageKeys.insert(Self.userMessageKey(turnID: turnID, text: prompt.text))
            return .userMessage(turnID: turnID, itemID: prompt.writeID, text: prompt.text)
        }
    }

    private func removePendingPrompt(writeID: String) {
        lock.withLock {
            pendingPrompts.removeAll { $0.writeID == writeID }
        }
    }

    private static func userMessageKey(turnID: String, text: String) -> String {
        "\(turnID)::\(text)"
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
