import Foundation

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
    case assistantMessage(String)
    case commandOutput(String)
    case fileChange(path: String, diff: String)
}

public enum SessionEvent: Equatable, Sendable {
    case turnStarted(threadID: String, turnID: String)
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

    public func send(composer: InputComposer) async throws {
        let threadID = thread?.id ?? runningThreadID ?? ""
        if let runningTurnID {
            let response = try await protocolClient.steerTurn(
                threadID: threadID,
                turnID: runningTurnID,
                prompt: composer.text,
                attachments: composer.attachments
            )
            self.runningTurnID = response.object?["turnId"]?.string ?? runningTurnID
        } else {
            let response = try await protocolClient.startTurn(
                threadID: threadID,
                prompt: composer.text,
                attachments: composer.attachments,
                permissionMode: composer.permissionMode,
                collaborationMode: composer.collaborationMode
            )
            runningTurnID = response.object?["turn"]?.object?["id"]?.string
                ?? response.object?["turnId"]?.string
                ?? "turn-started"
        }
        runningThreadID = threadID
        status = .running
        if !composer.text.isEmpty {
            allHistoryItems.append(.userMessage(composer.text))
            visibleItems.append(.userMessage(composer.text))
        }
    }

    public func receive(notification: JSONRPCNotification) {
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
        case let .itemCompleted(_, itemID, item):
            if let index = itemIndexByID[itemID] {
                visibleItems[index] = item
                updateHistoryItem(atVisibleIndex: index, with: item)
                return
            }
            if isDuplicateOptimisticUserMessage(item) {
                itemIndexByID[itemID] = visibleItems.count - 1
                return
            }
            itemIndexByID[itemID] = visibleItems.count
            allHistoryItems.append(item)
            visibleItems.append(item)
        case let .agentMessageDelta(_, itemID, delta):
            append(delta: delta, itemID: itemID, make: VisibleItem.assistantMessage, merge: mergeAssistant)
        case let .commandOutputDelta(_, itemID, delta):
            append(delta: delta, itemID: itemID, make: VisibleItem.commandOutput, merge: mergeCommand)
        case let .fileChangeDelta(_, itemID, path, diff):
            if let index = itemIndexByID[itemID] {
                visibleItems[index] = .fileChange(path: path, diff: diff)
                updateHistoryItem(atVisibleIndex: index, with: .fileChange(path: path, diff: diff))
            } else {
                itemIndexByID[itemID] = visibleItems.count
                allHistoryItems.append(.fileChange(path: path, diff: diff))
                visibleItems.append(.fileChange(path: path, diff: diff))
            }
        case .turnCompleted:
            status = .completed
            runningTurnID = nil
        }
    }

    private func isDuplicateOptimisticUserMessage(_ item: VisibleItem) -> Bool {
        guard case let .userMessage(text) = item else { return false }
        guard case let .userMessage(lastText) = visibleItems.last else { return false }
        return lastText == text
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

    private func append(delta: String, itemID: String, make: (String) -> VisibleItem, merge: (VisibleItem, String) -> VisibleItem) {
        if let index = itemIndexByID[itemID] {
            visibleItems[index] = merge(visibleItems[index], delta)
            updateHistoryItem(atVisibleIndex: index, with: visibleItems[index])
        } else {
            let item = make(delta)
            itemIndexByID[itemID] = visibleItems.count
            allHistoryItems.append(item)
            visibleItems.append(item)
        }
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
            return .commandOutput(text + delta)
        }
        return item
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
}

extension VisibleItem {
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
        case "assistantMessage", "assistant_message", "agentMessage", "message":
            guard let text else { return nil }
            self = .assistantMessage(text)
        case "commandOutput", "command_output", "commandExecutionOutput":
            guard let text else { return nil }
            self = .commandOutput(text)
        case "commandExecution":
            guard let output = object["aggregatedOutput"]?.string ?? object["output"]?.string else { return nil }
            self = .commandOutput(output)
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
            guard !turnID.isEmpty else { return nil }
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
