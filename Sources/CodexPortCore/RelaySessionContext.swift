import Foundation
import CodexPortShared

public final class RelaySessionContext: @unchecked Sendable {
    public struct AttachOptions: Sendable {
        public var loadInitialHistory: Bool
        public var resumeLiveSession: Bool

        public init(loadInitialHistory: Bool = true, resumeLiveSession: Bool = true) {
            self.loadInitialHistory = loadInitialHistory
            self.resumeLiveSession = resumeLiveSession
        }
    }

    public let threadID: String
    public let sessionStore: SessionStore
    public let clientManager: RelayJSONLSessionClientManager

    public init(
        threadID: String,
        sessionStore: SessionStore,
        clientManager: RelayJSONLSessionClientManager
    ) {
        self.threadID = threadID
        self.sessionStore = sessionStore
        self.clientManager = clientManager
    }

    public func stop() {
        clientManager.stop()
    }
}

public final class RelaySessionContextRegistry: @unchecked Sendable {
    public typealias StoreFactory = @Sendable (_ threadID: String) -> SessionStore
    public typealias ClientFactory = @Sendable (
        _ thread: ThreadSummary,
        _ sessionStore: SessionStore,
        _ options: RelaySessionContext.AttachOptions
    ) -> RelayJSONLSessionClient?

    private let storeFactory: StoreFactory
    private let clientFactory: ClientFactory
    private let lock = NSLock()
    private var allowedThreadsByID: [String: ThreadSummary]
    private var contexts: [String: RelaySessionContext] = [:]

    public init(
        allowedThreadIDs: Set<String> = [],
        allowedThreads: [ThreadSummary] = [],
        storeFactory: @escaping StoreFactory,
        clientFactory: @escaping ClientFactory
    ) {
        var threadsByID = Dictionary(uniqueKeysWithValues: allowedThreads.map { ($0.id, $0) })
        for threadID in allowedThreadIDs where threadsByID[threadID] == nil {
            threadsByID[threadID] = ThreadSummary(
                id: threadID,
                cwd: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                preview: "",
                gitInfo: nil
            )
        }
        self.allowedThreadsByID = threadsByID
        self.storeFactory = storeFactory
        self.clientFactory = clientFactory
    }

    public func updateAllowedThreadIDs(_ threadIDs: Set<String>) {
        lock.withLock {
            allowedThreadsByID = Dictionary(uniqueKeysWithValues: threadIDs.map { threadID in
                (
                    threadID,
                    allowedThreadsByID[threadID] ?? ThreadSummary(
                        id: threadID,
                        cwd: nil,
                        updatedAt: Date(timeIntervalSince1970: 0),
                        preview: "",
                        gitInfo: nil
                    )
                )
            })
        }
    }

    public func updateAllowedThreads(_ threads: [ThreadSummary]) {
        lock.withLock {
            allowedThreadsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        }
    }

    public func upsertAllowedThread(_ thread: ThreadSummary) {
        lock.withLock {
            allowedThreadsByID[thread.id] = thread
        }
    }

    public func context(
        threadID: String,
        options: RelaySessionContext.AttachOptions = .init()
    ) -> RelaySessionContext? {
        lock.withLock {
            guard let thread = allowedThreadsByID[threadID] else { return nil }
            if let context = contexts[threadID] {
                return context
            }
            let store = storeFactory(threadID)
            let manager = RelayJSONLSessionClientManager(sessionStore: store) { [clientFactory] sessionStore in
                clientFactory(thread, sessionStore, options)
            }
            let context = RelaySessionContext(
                threadID: threadID,
                sessionStore: store,
                clientManager: manager
            )
            contexts[threadID] = context
            return context
        }
    }

    public func stopAll() {
        let contexts = lock.withLock {
            let contexts = Array(self.contexts.values)
            self.contexts.removeAll()
            return contexts
        }
        for context in contexts {
            context.stop()
        }
    }
}

public final class RelaySessionPlaceholderProtocolClient: CodexProtocolClient, @unchecked Sendable {
    private let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    public func readThread(id: String, includeTurns: Bool) async throws -> JSONValue {
        .object(["threadId": .string(id), "turns": .array([])])
    }

    public func resumeThread(id: String) async throws -> JSONValue {
        .object(["threadId": .string(id), "turns": .array([])])
    }

    public func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue {
        .object(["threadId": .string(id), "turns": .array([])])
    }

    public func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue {
        .object(["threadId": .string(id), "turns": .array([])])
    }

    public func listThreadTurns(
        threadID: String,
        cursor: String?,
        limit: Int,
        sortDirection: String,
        itemsView: String
    ) async throws -> JSONValue {
        .object(["data": .array([]), "nextCursor": .null])
    }

    public func listThreadTurns(
        threadID: String,
        cursor: String?,
        limit: Int,
        sortDirection: String,
        itemsView: String,
        timeoutSeconds: Double?
    ) async throws -> JSONValue {
        .object(["data": .array([]), "nextCursor": .null])
    }

    public func startThread(cwd: String, model: CodexModel) async throws -> String {
        threadID
    }

    public func startTurn(
        threadID: String,
        prompt: String,
        attachments: [TurnAttachment],
        model: CodexModel,
        reasoningEffort: ReasoningEffort,
        permissionMode: PermissionMode,
        collaborationMode: CollaborationMode
    ) async throws -> JSONValue {
        .object(["turnId": .string("relay-turn")])
    }

    public func steerTurn(
        threadID: String,
        turnID: String,
        prompt: String,
        attachments: [TurnAttachment]
    ) async throws -> JSONValue {
        .object(["turnId": .string(turnID)])
    }

    public func interruptTurn(threadID: String, turnID: String) async throws -> JSONValue {
        .object([:])
    }

    public func unsubscribeThread(id: String) async throws -> JSONValue {
        .object(["status": .string("unsubscribed")])
    }

    public func readDirectory(path: String) async throws -> [RemoteDirectoryEntry] {
        []
    }

    public func getMetadata(path: String) async throws -> RemoteMetadata {
        RemoteMetadata(path: path, kind: .directory)
    }

    public func createDirectory(path: String, recursive: Bool) async throws {}

    public func writeFile(path: String, dataBase64: String) async throws {}
}
