import Foundation

public enum ConnectedSessionRoute: Sendable {
    public typealias RelaySessionClientFactory = @Sendable (_ threadID: String, _ sessionStore: SessionStore) -> RelayJSONLSessionClient?

    case directSSH(protocolClient: CodexProtocolClient, events: AppServerEventSource?)
    case relay(
        hostID: String,
        clientID: String,
        threads: [ThreadSummary],
        sessionRegistry: RelaySessionContextRegistry
    )

    public var directProtocolClient: CodexProtocolClient? {
        switch self {
        case let .directSSH(protocolClient, _):
            return protocolClient
        case .relay:
            return nil
        }
    }

    public var directEvents: AppServerEventSource? {
        switch self {
        case let .directSSH(_, events):
            return events
        case .relay:
            return nil
        }
    }

    public var relayThreadSummaries: [ThreadSummary] {
        switch self {
        case .directSSH:
            return []
        case let .relay(_, _, threads, _):
            return threads
        }
    }

    public var isRelay: Bool {
        if case .relay = self {
            return true
        }
        return false
    }

    public var canStartProjectSession: Bool {
        switch self {
        case .directSSH, .relay:
            return true
        }
    }

    public var relaySessionRegistry: RelaySessionContextRegistry? {
        switch self {
        case .directSSH:
            return nil
        case let .relay(_, _, _, registry):
            return registry
        }
    }

    public func appendingRelayThread(_ thread: ThreadSummary) -> ConnectedSessionRoute {
        switch self {
        case .directSSH:
            return self
        case let .relay(hostID, clientID, threads, registry):
            registry.upsertAllowedThread(thread)
            var updatedThreads = threads.filter { $0.id != thread.id }
            updatedThreads.insert(thread, at: 0)
            return .relay(
                hostID: hostID,
                clientID: clientID,
                threads: updatedThreads,
                sessionRegistry: registry
            )
        }
    }

    public func relaySessionContext(threadID: String) -> RelaySessionContext? {
        switch self {
        case .directSSH:
            return nil
        case let .relay(_, _, _, registry):
            return registry.context(threadID: threadID)
        }
    }

    public func stopRelaySessions() {
        switch self {
        case .directSSH:
            return
        case let .relay(_, _, _, registry):
            registry.stopAll()
        }
    }
}
