import Foundation
import CodexPortShared

public struct ThreadDetail: Equatable, Sendable {
    public var id: String
    public var turns: [Turn]

    public init(id: String, turns: [Turn]) {
        self.id = id
        self.turns = turns
    }
}

public struct Turn: Equatable, Sendable {
    public var id: String
    public var status: TurnStatus
    public var items: [VisibleItem]

    public init(id: String, status: TurnStatus, items: [VisibleItem]) {
        self.id = id
        self.status = status
        self.items = items
    }
}

public enum TurnStatus: Equatable, Sendable {
    case running
    case interrupting
    case completed
    case failed(String)
}

public enum VisibleItem: Equatable, Sendable {
    case userMessage(String)
    case structuredUserMessage(StructuredUserMessage)
    case assistantMessage(String)
    case commandOutput(String)
    case fileChange(path: String, diff: String)
}

public enum SessionEvent: Equatable, Sendable {
    case turnStarted(threadID: String, turnID: String)
    case threadStatusChanged(threadID: String, status: TurnStatus?)
    case itemCompleted(turnID: String, itemID: String, item: VisibleItem)
    case agentMessageDelta(turnID: String, itemID: String, delta: String)
    case commandOutputDelta(turnID: String, itemID: String, delta: String)
    case fileChangeDelta(turnID: String, itemID: String, path: String, diff: String)
    case turnCompleted(turnID: String)
}

public final class SessionStore {
    public static let defaultInitialVisibleItemLimit = 120
    public static let defaultInitialTurnPageSize = 10
    public static let defaultHistoryTurnPageSize = 10
    public static let defaultLegacyHistoryItemPageSize = 80
    public static let defaultHistoryRequestTimeoutSeconds: Double = 30

    private let protocolClient: CodexProtocolClient
    private let initialVisibleItemLimit: Int
    private let initialTurnPageSize: Int
    private let historyTurnPageSize: Int
    private let legacyHistoryItemPageSize: Int
    private let historyRequestTimeoutSeconds: Double
    public private(set) var thread: ThreadDetail?
    public private(set) var loadedTurnCount = 0
    public private(set) var runningTurnID: String?
    public private(set) var runningThreadID: String?
    public private(set) var status: TurnStatus?
    public private(set) var visibleItems: [VisibleItem] = []
    public private(set) var isTotalHistoryCountKnown = false
    private var itemIndexByID: [String: Int] = [:]
    private var allHistoryItems: [VisibleItem] = []
    private var visibleHistoryStartIndex = 0
    private var earlierTurnsCursor: String?
    private var usesServerPagedHistory = false

    public init(
        protocolClient: CodexProtocolClient,
        initialVisibleItemLimit: Int = SessionStore.defaultInitialVisibleItemLimit,
        initialTurnPageSize: Int = SessionStore.defaultInitialTurnPageSize,
        historyTurnPageSize: Int = SessionStore.defaultHistoryTurnPageSize,
        legacyHistoryItemPageSize: Int = SessionStore.defaultLegacyHistoryItemPageSize,
        historyRequestTimeoutSeconds: Double = SessionStore.defaultHistoryRequestTimeoutSeconds
    ) {
        self.protocolClient = protocolClient
        self.initialVisibleItemLimit = max(1, initialVisibleItemLimit)
        self.initialTurnPageSize = max(1, initialTurnPageSize)
        self.historyTurnPageSize = max(1, historyTurnPageSize)
        self.legacyHistoryItemPageSize = max(1, legacyHistoryItemPageSize)
        self.historyRequestTimeoutSeconds = max(0.05, historyRequestTimeoutSeconds)
    }

    public var hasEarlierHistory: Bool {
        visibleHistoryStartIndex > 0 || earlierTurnsCursor != nil
    }

    public var earlierHistoryCursor: String? {
        earlierTurnsCursor
    }

    public var totalHistoryItemCount: Int {
        allHistoryItems.count
    }

    public var loadedHistoryItemCount: Int {
        allHistoryItems.count - visibleHistoryStartIndex
    }

    public func open(threadID: String) async throws {
        let response: JSONValue
        do {
            response = try await protocolClient.resumeThread(
                id: threadID,
                initialTurnLimit: initialTurnPageSize,
                timeoutSeconds: historyRequestTimeoutSeconds
            )
        } catch JSONRPCError.remote {
            response = try await protocolClient.resumeThread(id: threadID)
        }
        if let fake = protocolClient as? ThreadDetailProviding {
            thread = fake.thread
        } else {
            thread = ThreadDetail(json: response, fallbackID: threadID)
        }
        itemIndexByID.removeAll()

        if let page = ThreadTurnsPage(json: response.object?["initialTurnsPage"]?.object, fallbackThreadID: threadID) {
            applyInitialPagedTurns(page)
        } else {
            applyLegacyFullHistoryWindow()
        }

        restoreRunningState(threadID: threadID)
    }

    public func openNew(threadID: String) {
        thread = ThreadDetail(id: threadID, turns: [])
        loadedTurnCount = 0
        runningTurnID = nil
        runningThreadID = threadID
        status = nil
        visibleItems = []
        isTotalHistoryCountKnown = true
        itemIndexByID.removeAll()
        allHistoryItems = []
        visibleHistoryStartIndex = 0
        earlierTurnsCursor = nil
        usesServerPagedHistory = false
    }

    public func loadEarlierHistory() async throws {
        guard hasEarlierHistory else { return }
        if usesServerPagedHistory, let earlierTurnsCursor {
            let response = try await protocolClient.listThreadTurns(
                threadID: thread?.id ?? runningThreadID ?? "",
                cursor: earlierTurnsCursor,
                limit: historyTurnPageSize,
                sortDirection: "desc",
                itemsView: "full",
                timeoutSeconds: historyRequestTimeoutSeconds
            )
            guard let page = ThreadTurnsPage(json: response.object, fallbackThreadID: thread?.id ?? runningThreadID ?? "") else { return }
            prependPagedTurns(page)
            return
        }

        let previousStartIndex = visibleHistoryStartIndex
        visibleHistoryStartIndex = max(0, visibleHistoryStartIndex - legacyHistoryItemPageSize)
        let addedVisibleCount = previousStartIndex - visibleHistoryStartIndex
        visibleItems = Array(allHistoryItems[visibleHistoryStartIndex...])
        itemIndexByID = itemIndexByID.mapValues { $0 + addedVisibleCount }
    }

    public func send(prompt: String) async throws {
        var composer = InputComposer(modelDisplay: "")
        composer.text = prompt
        try await send(composer: composer)
    }

    public func appendOptimisticUserMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let item = VisibleItem.userMessage(text)
        allHistoryItems.append(item)
        visibleItems.append(item)
    }

    public func appendOptimisticUserMessage(_ message: StructuredUserMessage) {
        guard !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty || !message.mentions.isEmpty else { return }
        if message.mentions.isEmpty, message.attachments.isEmpty {
            appendOptimisticUserMessage(message.body)
            return
        }
        let item = VisibleItem.structuredUserMessage(message)
        allHistoryItems.append(item)
        visibleItems.append(item)
    }

    public func send(composer: InputComposer) async throws {
        let threadID = thread?.id ?? runningThreadID ?? ""
        let protocolPrompt = composer.message.protocolPrompt
        let protocolAttachments = composer.attachments.isEmpty ? composer.message.protocolAttachments : composer.attachments
        if let runningTurnID {
            let response = try await protocolClient.steerTurn(
                threadID: threadID,
                turnID: runningTurnID,
                prompt: protocolPrompt,
                attachments: protocolAttachments
            )
            self.runningTurnID = response.object?["turnId"]?.string ?? runningTurnID
        } else {
            let response = try await protocolClient.startTurn(
                threadID: threadID,
                prompt: protocolPrompt,
                attachments: protocolAttachments,
                model: composer.model,
                reasoningEffort: composer.reasoningEffort,
                permissionMode: composer.permissionMode,
                collaborationMode: composer.collaborationMode
            )
            runningTurnID = response.object?["turn"]?.object?["id"]?.string
                ?? response.object?["turnId"]?.string
                ?? "turn-started"
        }
        runningThreadID = threadID
        status = .running
        appendOptimisticUserMessage(composer.message)
    }

    public func receive(notification: JSONRPCNotification) {
        if let notificationThreadID = notification.params.object?["threadId"]?.string ?? notification.params.object?["thread_id"]?.string {
            let currentThreadID = thread?.id ?? runningThreadID
            if let currentThreadID, notificationThreadID != currentThreadID {
                return
            }
        }
        guard let event = SessionEvent(notification: notification) else { return }
        receive(event)
        mergeTurnItems(from: notification)
    }

    public func send(
        composer: InputComposer,
        pendingAttachments: [PendingAttachment],
        attachmentBridge: AttachmentComposerBridge
    ) async throws {
        let threadID = thread?.id ?? runningThreadID ?? ""
        var composer = composer
        if !pendingAttachments.isEmpty {
            composer.attachments.removeAll()
            try await attachmentBridge.attach(pendingAttachments, threadID: threadID, to: &composer)
        }
        try await send(composer: composer)
    }

    public func receive(_ event: SessionEvent) {
        switch event {
        case let .turnStarted(threadID, turnID):
            runningThreadID = threadID
            runningTurnID = turnID
            status = .running
        case let .threadStatusChanged(threadID, newStatus):
            runningThreadID = threadID
            status = newStatus
            if newStatus != .running {
                runningTurnID = nil
            }
        case let .itemCompleted(turnID, itemID, item):
            let itemKey = self.itemKey(turnID: turnID, itemID: itemID)
            if let index = itemIndexByID[itemKey] {
                visibleItems[index] = item
                updateHistoryItem(atVisibleIndex: index, with: item)
                return
            }
            if isDuplicateOptimisticUserMessage(item) {
                itemIndexByID[itemKey] = visibleItems.count - 1
                return
            }
            itemIndexByID[itemKey] = visibleItems.count
            allHistoryItems.append(item)
            visibleItems.append(item)
        case let .agentMessageDelta(turnID, itemID, delta):
            append(delta: delta, turnID: turnID, itemID: itemID, make: VisibleItem.assistantMessage, merge: mergeAssistant)
        case let .commandOutputDelta(turnID, itemID, delta):
            append(delta: delta, turnID: turnID, itemID: itemID, make: VisibleItem.commandOutput, merge: mergeCommand)
        case let .fileChangeDelta(turnID, itemID, path, diff):
            let itemKey = self.itemKey(turnID: turnID, itemID: itemID)
            if let index = itemIndexByID[itemKey] {
                visibleItems[index] = .fileChange(path: path, diff: diff)
                updateHistoryItem(atVisibleIndex: index, with: .fileChange(path: path, diff: diff))
            } else {
                itemIndexByID[itemKey] = visibleItems.count
                allHistoryItems.append(.fileChange(path: path, diff: diff))
                visibleItems.append(.fileChange(path: path, diff: diff))
            }
        case .turnCompleted:
            status = .completed
            runningTurnID = nil
        }
    }

    public func receive(relayEvent: RelayLiveSessionEvent) {
        switch relayEvent {
        case let .sessionStarted(_, threadID, turnID):
            receive(.turnStarted(threadID: threadID, turnID: turnID))
        case let .threadHistoryLoaded(threadID, items, status):
            let historyItems = items.map(VisibleItem.init(relayHistoryItem:))
            thread = ThreadDetail(
                id: threadID,
                turns: [
                    Turn(
                        id: "\(threadID)-history",
                        status: TurnStatus(relayStatus: status),
                        items: historyItems
                    )
                ]
            )
            runningThreadID = threadID
            runningTurnID = status == .running ? "\(threadID)-history" : nil
            self.status = TurnStatus(relayStatus: status)
            allHistoryItems = historyItems
            visibleHistoryStartIndex = max(0, allHistoryItems.count - initialVisibleItemLimit)
            visibleItems = Array(allHistoryItems[visibleHistoryStartIndex...])
            loadedTurnCount = historyItems.isEmpty ? 0 : 1
            isTotalHistoryCountKnown = true
            earlierTurnsCursor = nil
            usesServerPagedHistory = false
            itemIndexByID.removeAll()
        case let .userMessage(turnID, itemID, text):
            receive(.itemCompleted(turnID: turnID, itemID: itemID, item: .userMessage(text)))
        case let .assistantTextDelta(turnID, itemID, text):
            receive(.agentMessageDelta(turnID: turnID, itemID: itemID, delta: text))
        case let .commandOutputDelta(turnID, itemID, text):
            receive(.commandOutputDelta(turnID: turnID, itemID: itemID, delta: text))
        case let .fileChange(turnID, itemID, path, diff):
            receive(.fileChangeDelta(turnID: turnID, itemID: itemID, path: path, diff: diff))
        case .approvalRequested:
            break
        case let .turnCompleted(turnID):
            receive(.turnCompleted(turnID: turnID))
        case let .turnFailed(turnID, reason):
            runningTurnID = nil
            status = .failed(reason)
            runningThreadID = runningThreadID ?? thread?.id
            if runningThreadID == nil {
                runningThreadID = turnID
            }
        case .writeStatusChanged:
            break
        case let .streamClosed(_, threadID, _):
            runningThreadID = threadID
        }
    }

    public func receive(relayHistoryPage page: RelayThreadHistoryPage) {
        guard page.threadID == (thread?.id ?? runningThreadID ?? page.threadID) else { return }
        let pageItems = page.items.map(VisibleItem.init(relayHistoryItem:))
        if page.requestID == "initial" {
            let optimisticItems = optimisticItemsNotPresent(in: pageItems)
            let mergedItems = pageItems + optimisticItems
            thread = ThreadDetail(
                id: page.threadID,
                turns: [
                    Turn(
                        id: "\(page.threadID)-history",
                        status: TurnStatus(relayStatus: page.status),
                        items: mergedItems
                    )
                ]
            )
            runningThreadID = page.threadID
            runningTurnID = page.status == .running ? "\(page.threadID)-history" : nil
            status = TurnStatus(relayStatus: page.status)
            allHistoryItems = mergedItems
            visibleHistoryStartIndex = max(0, allHistoryItems.count - initialVisibleItemLimit)
            visibleItems = Array(allHistoryItems[visibleHistoryStartIndex...])
            loadedTurnCount = mergedItems.isEmpty ? 0 : 1
            isTotalHistoryCountKnown = page.nextCursor == nil
            earlierTurnsCursor = page.nextCursor
            itemIndexByID.removeAll()
            return
        }
        guard !pageItems.isEmpty else {
            earlierTurnsCursor = page.nextCursor
            if page.nextCursor == nil {
                isTotalHistoryCountKnown = true
            }
            return
        }
        let existingItems = allHistoryItems
        var uniquePageItems: [VisibleItem] = []
        for item in pageItems where !existingItems.contains(item) && !uniquePageItems.contains(item) {
            uniquePageItems.append(item)
        }
        guard !uniquePageItems.isEmpty else {
            earlierTurnsCursor = page.nextCursor
            if page.nextCursor == nil {
                isTotalHistoryCountKnown = true
            }
            return
        }
        allHistoryItems = uniquePageItems + existingItems
        if let thread {
            self.thread = ThreadDetail(
                id: thread.id,
                turns: [
                    Turn(
                        id: "\(page.threadID)-history",
                        status: TurnStatus(relayStatus: page.status),
                        items: allHistoryItems
                    )
                ]
            )
        } else {
            thread = ThreadDetail(
                id: page.threadID,
                turns: [
                    Turn(
                        id: "\(page.threadID)-history",
                        status: TurnStatus(relayStatus: page.status),
                        items: allHistoryItems
                    )
                ]
            )
        }
        visibleHistoryStartIndex = 0
        visibleItems = allHistoryItems
        earlierTurnsCursor = page.nextCursor
        isTotalHistoryCountKnown = page.nextCursor == nil
        loadedTurnCount += pageItems.isEmpty ? 0 : 1
        itemIndexByID = itemIndexByID.mapValues { $0 + uniquePageItems.count }
    }

    private func isDuplicateOptimisticUserMessage(_ item: VisibleItem) -> Bool {
        guard let text = item.userMessageBody,
              let lastText = visibleItems.last?.userMessageBody
        else { return false }
        return lastText == text
    }

    private func optimisticItemsNotPresent(in historyItems: [VisibleItem]) -> [VisibleItem] {
        visibleItems.filter { item in
            guard item.userMessageBody != nil else { return false }
            return !historyItems.contains(item)
        }
    }

    private func restoreRunningState(threadID fallbackThreadID: String) {
        guard let thread else {
            runningThreadID = fallbackThreadID
            runningTurnID = nil
            status = nil
            return
        }
        runningThreadID = thread.id
        if let runningTurn = thread.turns.last(where: { $0.status == .running }) {
            runningTurnID = runningTurn.id
            status = .running
        } else if let latestTurn = thread.turns.last {
            runningTurnID = nil
            status = latestTurn.status
        } else {
            runningTurnID = nil
            status = nil
        }
    }

    private func applyInitialPagedTurns(_ page: ThreadTurnsPage) {
        usesServerPagedHistory = true
        isTotalHistoryCountKnown = false
        earlierTurnsCursor = page.nextCursor
        let displayTurns = Array(page.turns.reversed())
        loadedTurnCount = displayTurns.count
        var thread = thread ?? ThreadDetail(id: page.threadID, turns: [])
        thread.turns = displayTurns
        self.thread = thread
        allHistoryItems = displayTurns.flatMap(\.items)
        visibleHistoryStartIndex = 0
        visibleItems = allHistoryItems
    }

    private func applyLegacyFullHistoryWindow() {
        usesServerPagedHistory = false
        isTotalHistoryCountKnown = true
        earlierTurnsCursor = nil
        loadedTurnCount = thread?.turns.count ?? 0
        allHistoryItems = thread?.turns.flatMap(\.items) ?? []
        visibleHistoryStartIndex = max(0, allHistoryItems.count - initialVisibleItemLimit)
        visibleItems = Array(allHistoryItems[visibleHistoryStartIndex...])
    }

    private func prependPagedTurns(_ page: ThreadTurnsPage) {
        let earlierTurns = Array(page.turns.reversed())
        guard !earlierTurns.isEmpty else {
            earlierTurnsCursor = page.nextCursor
            return
        }
        earlierTurnsCursor = page.nextCursor
        loadedTurnCount += earlierTurns.count
        let earlierItems = earlierTurns.flatMap(\.items)
        thread?.turns.insert(contentsOf: earlierTurns, at: 0)
        allHistoryItems.insert(contentsOf: earlierItems, at: 0)
        visibleItems.insert(contentsOf: earlierItems, at: 0)
        itemIndexByID = itemIndexByID.mapValues { $0 + earlierItems.count }
    }

    private func mergeTurnItems(from notification: JSONRPCNotification) {
        guard notification.method == "turn/started" || notification.method == "turn/completed" else { return }
        guard let object = notification.params.object else { return }
        let turnObject = object["turn"]?.object ?? [:]
        let turnID = turnObject["id"]?.string
            ?? object["turnId"]?.string
            ?? object["turn_id"]?.string
            ?? ""
        for itemJSON in turnObject["items"]?.array ?? [] {
            guard
                let itemID = itemJSON.object?["id"]?.string,
                let item = VisibleItem(json: itemJSON)
            else { continue }
            receive(.itemCompleted(turnID: turnID, itemID: itemID, item: item))
        }
    }

    public func interrupt() async throws {
        guard let threadID = runningThreadID, let turnID = runningTurnID else { return }
        _ = try await protocolClient.interruptTurn(threadID: threadID, turnID: turnID)
        status = .interrupting
    }

    public func close() async {
        guard let threadID = thread?.id ?? runningThreadID else { return }
        do {
            _ = try await protocolClient.unsubscribeThread(id: threadID)
        } catch {
            // Closing a view should not surface stale unsubscribe failures.
        }
    }

    private func append(delta: String, turnID: String, itemID: String, make: (String) -> VisibleItem, merge: (VisibleItem, String) -> VisibleItem) {
        let itemKey = self.itemKey(turnID: turnID, itemID: itemID)
        if let index = itemIndexByID[itemKey] {
            visibleItems[index] = merge(visibleItems[index], delta)
            updateHistoryItem(atVisibleIndex: index, with: visibleItems[index])
        } else {
            let item = make(delta)
            itemIndexByID[itemKey] = visibleItems.count
            allHistoryItems.append(item)
            visibleItems.append(item)
        }
    }

    private func itemKey(turnID: String, itemID: String) -> String {
        "\(turnID):\(itemID)"
    }

    private func updateHistoryItem(atVisibleIndex visibleIndex: Int, with item: VisibleItem) {
        let historyIndex = visibleHistoryStartIndex + visibleIndex
        guard allHistoryItems.indices.contains(historyIndex) else { return }
        allHistoryItems[historyIndex] = item
    }

    private func mergeAssistant(_ item: VisibleItem, _ delta: String) -> VisibleItem {
        if case let .assistantMessage(text) = item {
            return .assistantMessage(text + delta)
        }
        return item
    }

    private func mergeCommand(_ item: VisibleItem, _ delta: String) -> VisibleItem {
        if case let .commandOutput(text) = item {
            return .commandOutput(text + deduplicatingToolHeader(delta, after: text))
        }
        return item
    }

    private func deduplicatingToolHeader(_ delta: String, after existing: String) -> String {
        let existingFirstLine = firstLine(in: existing)
        let deltaFirst = firstLineAndRest(in: delta)
        guard isToolHeaderLine(existingFirstLine),
              existingFirstLine == deltaFirst.line
        else {
            return delta
        }
        return deltaFirst.rest
    }

    private func firstLine(in text: String) -> String {
        guard let newline = text.firstIndex(where: \.isNewline) else { return text }
        return String(text[..<newline])
    }

    private func firstLineAndRest(in text: String) -> (line: String, rest: String) {
        guard let newline = text.firstIndex(where: \.isNewline) else { return (text, "") }
        let restStart = text.index(after: newline)
        return (String(text[..<newline]), String(text[restStart...]))
    }

    private func isToolHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("$ ")
            || line.hasPrefix("读取文件：")
            || line.hasPrefix("读取文件:")
            || line.hasPrefix("已读取 ")
            || line.hasPrefix("工具调用：")
            || line.hasPrefix("工具调用:")
            || line.hasPrefix("开始工具调用：")
            || line.hasPrefix("开始工具调用:")
    }
}

extension SessionStore: @unchecked Sendable {}

extension ThreadDetail {
    init(json: JSONValue, fallbackID: String) {
        let root = json.object?["thread"]?.object ?? json.object ?? [:]
        self.id = root["id"]?.string ?? root["threadId"]?.string ?? fallbackID
        self.turns = (root["turns"]?.array ?? root["items"]?.array ?? [])
            .compactMap(Turn.init(json:))
    }
}

extension Turn {
    init?(json: JSONValue) {
        guard let object = json.object else { return nil }
        self.id = object["id"]?.string ?? object["turnId"]?.string ?? UUID().uuidString
        self.status = TurnStatus(raw: object["status"]?.string)
        self.items = (object["items"]?.array ?? object["events"]?.array ?? object["messages"]?.array ?? [])
            .compactMap(VisibleItem.init(json:))
    }
}

extension TurnStatus {
    init(raw: String?) {
        switch raw {
        case "running", "inProgress", "active":
            self = .running
        case "interrupting":
            self = .interrupting
        case "failed":
            self = .failed("")
        case "interrupted":
            self = .completed
        default:
            self = .completed
        }
    }

    init(relayStatus: RelayThreadRunStatus) {
        switch relayStatus {
        case .running:
            self = .running
        case .interrupting:
            self = .interrupting
        case .completed:
            self = .completed
        case .failed:
            self = .failed("")
        }
    }
}

extension VisibleItem {
    var userMessageBody: String? {
        switch self {
        case let .userMessage(text):
            return text
        case let .structuredUserMessage(message):
            return message.body
        case .assistantMessage, .commandOutput, .fileChange:
            return nil
        }
    }

    init(relayHistoryItem item: RelayThreadHistoryItem) {
        switch item {
        case let .userMessage(text):
            self = .userMessage(text)
        case let .assistantMessage(text):
            self = .assistantMessage(text)
        case let .commandOutput(text):
            self = .commandOutput(text)
        case let .fileChange(path, diff):
            self = .fileChange(path: path, diff: diff)
        }
    }

    init?(json: JSONValue) {
        guard let object = json.object else { return nil }
        let type = object["type"]?.string ?? object["kind"]?.string
        let text = object["text"]?.string
            ?? object["message"]?.string
            ?? object["content"]?.string
            ?? object["content"]?.array?.compactMap(Self.textContent).joined()
            ?? object["delta"]?.string

        switch type {
        case "userMessage", "user_message", "userInput":
            guard let text else { return nil }
            self = .userMessage(text)
        case "assistantMessage", "assistant_message", "agentMessage", "message", "plan", "reasoning":
            guard let text else { return nil }
            self = .assistantMessage(text)
        case "commandOutput", "command_output", "commandExecutionOutput":
            guard let text else { return nil }
            self = .commandOutput(text)
        case "commandExecution":
            let output = object["aggregatedOutput"]?.string
                ?? object["aggregated_output"]?.string
                ?? object["output"]?.string
                ?? text
                ?? ""
            guard let command = Self.commandLine(from: object) else {
                guard !output.isEmpty else { return nil }
                self = .commandOutput(output)
                return
            }
            self = .commandOutput(Self.prependingCommand(command, to: output))
        case "fileChange", "file_change", "diff":
            if let change = object["changes"]?.array?.compactMap(Self.fileChangeDetails).first {
                self = .fileChange(path: change.path, diff: change.diff)
                return
            }
            self = .fileChange(
                path: object["path"]?.string ?? object["file"]?.string ?? "",
                diff: object["diff"]?.string ?? text ?? ""
            )
        default:
            guard let text else { return nil }
            self = .assistantMessage(text)
        }
    }

    private static func textContent(_ json: JSONValue) -> String? {
        guard let object = json.object else { return nil }
        switch object["type"]?.string {
        case "text", "input_text", "output_text":
            return object["text"]?.string
        default:
            return object["text"]?.string
        }
    }

    fileprivate static func fileChangeDetails(_ json: JSONValue) -> (path: String, diff: String)? {
        guard let object = json.object else { return nil }
        return (
            object["path"]?.string ?? object["file"]?.string ?? "",
            object["diff"]?.string ?? object["text"]?.string ?? ""
        )
    }

    private static func commandLine(from object: [String: JSONValue]) -> String? {
        for key in ["command", "cmd"] {
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

    private static func commandLine(from value: JSONValue?) -> String? {
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

    private static func commandLine(fromArgumentArray value: JSONValue?) -> String? {
        guard let array = value?.array else { return nil }
        let command = array.compactMap(\.string).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    private static func prependingCommand(_ command: String, to output: String) -> String {
        let prefix = "$ \(command)\n"
        return output.hasPrefix(prefix) ? output : prefix + output
    }
}

extension SessionEvent {
    init?(notification: JSONRPCNotification) {
        let object = notification.params.object ?? [:]
        let threadID = object["threadId"]?.string ?? object["thread_id"]?.string ?? ""
        let turnID = object["turnId"]?.string
            ?? object["turn_id"]?.string
            ?? object["turn"]?.object?["id"]?.string
            ?? object["id"]?.string
            ?? ""
        let itemID = object["itemId"]?.string ?? object["item_id"]?.string ?? object["id"]?.string ?? UUID().uuidString
        let delta = object["delta"]?.string ?? object["text"]?.string ?? object["output"]?.string ?? object["content"]?.string ?? ""

        switch notification.method {
        case "turn/started", "turnStarted":
            guard !turnID.isEmpty else { return nil }
            self = .turnStarted(threadID: threadID, turnID: turnID)
        case "thread/status/changed":
            let statusType = object["status"]?.object?["type"]?.string ?? object["status"]?.string
            switch statusType {
            case "active", "running", "inProgress":
                self = .threadStatusChanged(threadID: threadID, status: .running)
            case "idle", "completed", "notLoaded":
                self = .threadStatusChanged(threadID: threadID, status: .completed)
            default:
                return nil
            }
        case "item/started":
            guard
                let item = object["item"].flatMap(VisibleItem.init(json:)),
                let startedItemID = object["item"]?.object?["id"]?.string ?? object["itemId"]?.string ?? object["item_id"]?.string
            else { return nil }
            self = .itemCompleted(turnID: turnID, itemID: startedItemID, item: item)
        case "item/completed":
            guard
                let item = object["item"].flatMap(VisibleItem.init(json:)),
                let completedItemID = object["item"]?.object?["id"]?.string ?? object["itemId"]?.string ?? object["item_id"]?.string
            else { return nil }
            self = .itemCompleted(turnID: turnID, itemID: completedItemID, item: item)
        case "item/agentMessage/delta", "agentMessage/delta", "item/message/delta":
            self = .agentMessageDelta(turnID: turnID, itemID: itemID, delta: delta)
        case "item/commandExecution/output", "item/commandExecution/outputDelta", "item/commandOutput/delta", "commandOutput/delta":
            self = .commandOutputDelta(turnID: turnID, itemID: itemID, delta: delta)
        case "item/fileChange/delta", "item/fileChange/outputDelta", "item/fileChange/patchUpdated", "fileChange/delta":
            let change = object["changes"]?.array?.compactMap(VisibleItem.fileChangeDetails).first
            self = .fileChangeDelta(
                turnID: turnID,
                itemID: itemID,
                path: change?.path ?? object["path"]?.string ?? object["file"]?.string ?? "",
                diff: change?.diff ?? object["diff"]?.string ?? delta
            )
        case "turn/completed", "turnCompleted":
            self = .turnCompleted(turnID: turnID)
        default:
            return nil
        }
    }
}

public protocol ThreadDetailProviding: AnyObject {
    var thread: ThreadDetail? { get }
}

private struct ThreadTurnsPage {
    var threadID: String
    var turns: [Turn]
    var nextCursor: String?

    init?(json: [String: JSONValue]?, fallbackThreadID: String) {
        guard let json else { return nil }
        self.threadID = fallbackThreadID
        self.turns = (json["data"]?.array ?? []).compactMap(Turn.init(json:))
        self.nextCursor = json["nextCursor"]?.string
    }
}
