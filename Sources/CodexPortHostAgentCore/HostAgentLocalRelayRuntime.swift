import Foundation
import CodexPortShared

public struct HostAgentLocalRelayAttachRequest: Equatable, Sendable {
    public var sessionID: String
    public var threadID: String
    public var turnID: String
    public var cwd: String?
    public var loadInitialHistory: Bool
    public var resumeLiveSession: Bool

    public init(
        sessionID: String,
        threadID: String,
        turnID: String,
        cwd: String? = nil,
        loadInitialHistory: Bool = true,
        resumeLiveSession: Bool = true
    ) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.cwd = cwd
        self.loadInitialHistory = loadInitialHistory
        self.resumeLiveSession = resumeLiveSession
    }
}

public actor HostAgentLocalRelayRuntime {
    public typealias CommandFactory = @Sendable (HostAgentLocalRelayAttachRequest) -> HostAgentProcessCommand
    public typealias AdapterFactory = @Sendable (HostAgentLocalRelayAttachRequest) -> AnyHostAgentLiveSessionAdapter

    private final class SessionEntry: @unchecked Sendable {
        let request: HostAgentLocalRelayAttachRequest
        let bridge: HostAgentLiveSessionBridge<AnyHostAgentLiveSessionAdapter>
        private let lock = NSLock()
        private var writeStatuses: [String: RelayWriteStatus] = [:]
        private var isLiveStarted: Bool

        init(
            request: HostAgentLocalRelayAttachRequest,
            bridge: HostAgentLiveSessionBridge<AnyHostAgentLiveSessionAdapter>,
            isLiveStarted: Bool
        ) {
            self.request = request
            self.bridge = bridge
            self.isLiveStarted = isLiveStarted
        }

        func knownStatus(for writeID: String) -> RelayWriteStatus? {
            lock.withLock {
                writeStatuses[writeID]
            }
        }

        func recordStatus(_ status: RelayWriteStatus, for writeID: String) {
            lock.withLock {
                writeStatuses[writeID] = status
            }
        }

        func shouldStartLive(for write: RelayLiveSessionWrite) -> Bool {
            lock.withLock {
                guard !isLiveStarted else { return false }
                guard case .prompt = write else { return false }
                isLiveStarted = true
                return true
            }
        }
    }

    private let adapterFactory: AdapterFactory
    private var sessions: [String: SessionEntry] = [:]
    private var attachedClients: [String: Set<String>] = [:]

    public init(commandFactory: @escaping CommandFactory) {
        self.init(adapterFactory: { request in
            let command = commandFactory(request)
            return AnyHostAgentLiveSessionAdapter(HostAgentProcessLiveAdapter(
                command: command,
                sessionID: request.sessionID,
                threadID: request.threadID,
                turnID: request.turnID
            ))
        })
    }

    public init(adapterFactory: @escaping AdapterFactory) {
        self.adapterFactory = adapterFactory
    }

    public func attach(
        clientID: String,
        request: HostAgentLocalRelayAttachRequest
    ) async throws -> AsyncStream<RelayLiveSessionEvent> {
        let entry = try sessionEntry(for: request)
        var clients = attachedClients[request.sessionID, default: []]
        clients.insert(clientID)
        attachedClients[request.sessionID] = clients
        return entry.bridge.subscribe()
    }

    public func submit(
        _ write: RelayLiveSessionWrite,
        from clientID: String,
        sessionID: String
    ) async -> RelayWriteStatus {
        guard attachedClients[sessionID]?.contains(clientID) == true else {
            return .failed(reason: "Client is not attached to this session.")
        }
        guard let entry = sessions[sessionID] else {
            return .failed(reason: "Relay session is not running.")
        }
        if let knownStatus = entry.knownStatus(for: write.writeID) {
            return knownStatus
        }
        if entry.shouldStartLive(for: write) {
            do {
                try entry.bridge.start()
            } catch {
                let status = RelayWriteStatus.failed(reason: String(describing: error))
                entry.recordStatus(status, for: write.writeID)
                return status
            }
        }
        let status = await entry.bridge.enqueue(write)
        entry.recordStatus(status, for: write.writeID)
        return status
    }

    public func detach(clientID: String, sessionID: String) {
        guard var clients = attachedClients[sessionID] else { return }
        clients.remove(clientID)
        if clients.isEmpty {
            attachedClients[sessionID] = nil
        } else {
            attachedClients[sessionID] = clients
        }
    }

    public func stop(sessionID: String) {
        attachedClients[sessionID] = nil
        sessions.removeValue(forKey: sessionID)?.bridge.stop()
    }

    public func stopAll() {
        attachedClients.removeAll()
        let bridges = sessions.values.map(\.bridge)
        sessions.removeAll()
        for bridge in bridges {
            bridge.stop()
        }
    }

    private func sessionEntry(for request: HostAgentLocalRelayAttachRequest) throws -> SessionEntry {
        if let existing = sessions[request.sessionID] {
            return existing
        }

        let adapter = adapterFactory(request)
        let bridge = HostAgentLiveSessionBridge(adapter: adapter)
        let startsImmediately = request.resumeLiveSession
        let entry = SessionEntry(request: request, bridge: bridge, isLiveStarted: startsImmediately)
        sessions[request.sessionID] = entry
        if startsImmediately {
            try bridge.start()
        }
        return entry
    }
}
