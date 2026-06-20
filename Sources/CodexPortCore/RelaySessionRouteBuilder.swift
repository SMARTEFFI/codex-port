import Foundation
import CodexPortShared

public enum RelaySessionRouteBuilder {
    public typealias TransportFactory = @Sendable (_ relayHost: RelayHost) -> RelayJSONLTransport?

    public static func route(
        profileDefaultDirectory: String,
        relayHost: RelayHost,
        threadSnapshots: [RelayThreadSummarySnapshot] = [],
        existingRegistry: RelaySessionContextRegistry? = nil,
        makeTransport: @escaping TransportFactory
    ) -> ConnectedSessionRoute {
        let threadSummaries = threadSnapshots.map(ThreadSummary.init(relaySnapshot:))
        let registry = existingRegistry ?? sessionRegistry(
            relayHost: relayHost,
            allowedThreads: threadSummaries,
            makeTransport: makeTransport
        )
        registry.updateAllowedThreads(threadSummaries)
        return .relay(
            hostID: relayHost.hostAgentID.uuidString,
            clientID: relayHost.pairingRecordID,
            threads: threadSummaries,
            sessionRegistry: registry
        )
    }

    public static func sessionRegistry(
        relayHost: RelayHost,
        allowedThreads: [ThreadSummary] = [],
        makeTransport: @escaping TransportFactory
    ) -> RelaySessionContextRegistry {
        RelaySessionContextRegistry(
            allowedThreads: allowedThreads,
            storeFactory: { threadID in
                SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: threadID))
            },
            clientFactory: { requestedThread, sessionStore, options in
                guard let transport = makeTransport(relayHost) else {
                    return nil
                }
                return RelayJSONLSessionClient(
                    clientID: relayHost.pairingRecordID,
                    sessionID: requestedThread.id,
                    threadID: requestedThread.id,
                    turnID: "\(requestedThread.id)-turn",
                    cwd: requestedThread.cwd,
                    loadInitialHistoryOnAttach: options.loadInitialHistory,
                    resumeLiveSessionOnAttach: options.resumeLiveSession,
                    transport: transport,
                    sessionStore: sessionStore
                )
            }
        )
    }
}

public extension ThreadSummary {
    init(relaySnapshot snapshot: RelayThreadSummarySnapshot) {
        let gitInfo: GitInfo?
        if let repository = snapshot.gitRepository, let branch = snapshot.gitBranch {
            gitInfo = GitInfo(repository: repository, branch: branch)
        } else {
            gitInfo = nil
        }
        self.init(
            id: snapshot.id,
            cwd: snapshot.cwd,
            updatedAt: Date(timeIntervalSince1970: snapshot.updatedAtUnixTime),
            preview: snapshot.preview,
            gitInfo: gitInfo,
            status: ThreadRunStatus(raw: snapshot.status),
            isUnread: false,
            remoteUnread: false
        )
    }
}
