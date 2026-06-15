import Foundation
import CodexPortShared

public struct HostAgentLocalRelayAttachRequest: Equatable, Sendable {
    public var sessionID: String
    public var threadID: String
    public var turnID: String
    public var cwd: String?

    public init(sessionID: String, threadID: String, turnID: String, cwd: String? = nil) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.cwd = cwd
    }
}

public actor HostAgentLocalRelayRuntime {
    public typealias CommandFactory = @Sendable (HostAgentLocalRelayAttachRequest) -> HostAgentProcessCommand
    public typealias AdapterFactory = @Sendable (HostAgentLocalRelayAttachRequest) -> AnyHostAgentLiveSessionAdapter

    private final class SessionEntry: @unchecked Sendable {
        let request: HostAgentLocalRelayAttachRequest
        let bridge: HostAgentLiveSessionBridge<AnyHostAgentLiveSessionAdapter>

        init(
            request: HostAgentLocalRelayAttachRequest,
            bridge: HostAgentLiveSessionBridge<AnyHostAgentLiveSessionAdapter>
        ) {
            self.request = request
            self.bridge = bridge
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
        return await entry.bridge.enqueue(write)
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
        let entry = SessionEntry(request: request, bridge: bridge)
        sessions[request.sessionID] = entry
        try bridge.start()
        return entry
    }
}
