import Foundation
import CodexPortShared

public struct RelayHostWorkspaceConnection: Sendable {
    public var route: ConnectedSessionRoute
    public var threadSnapshots: [RelayThreadSummarySnapshot]

    public init(route: ConnectedSessionRoute, threadSnapshots: [RelayThreadSummarySnapshot]) {
        self.route = route
        self.threadSnapshots = threadSnapshots
    }
}

public struct RelayHostWorkspaceConnector: Sendable {
    public typealias ProgressObserver = RelayJSONLThreadListClient.ProgressObserver

    private let profileDefaultDirectory: String
    private let relayHost: RelayHost
    private let existingRegistry: RelaySessionContextRegistry?
    private let makeTransport: RelaySessionRouteBuilder.TransportFactory
    private let timeout: Duration
    private let pageSize: Int
    private let progressObserver: ProgressObserver?

    public init(
        profileDefaultDirectory: String,
        relayHost: RelayHost,
        existingRegistry: RelaySessionContextRegistry? = nil,
        makeTransport: @escaping RelaySessionRouteBuilder.TransportFactory,
        timeout: Duration = .seconds(10),
        pageSize: Int = 20,
        progressObserver: ProgressObserver? = nil
    ) {
        self.profileDefaultDirectory = profileDefaultDirectory
        self.relayHost = relayHost
        self.existingRegistry = existingRegistry
        self.makeTransport = makeTransport
        self.timeout = timeout
        self.pageSize = pageSize
        self.progressObserver = progressObserver
    }

    public func connect(
        limit: Int = 100,
        requestID: String = UUID().uuidString
    ) async throws -> RelayHostWorkspaceConnection {
        guard let listTransport = makeTransport(relayHost) else {
            throw RelayJSONLThreadListClientError.transportUnavailable
        }
        let threadSnapshots = try await RelayJSONLThreadListClient(
            clientID: relayHost.pairingRecordID,
            transport: listTransport,
            timeout: timeout,
            pageSize: pageSize,
            progressObserver: progressObserver
        ).listThreads(limit: limit, requestID: requestID)
        let route = RelaySessionRouteBuilder.route(
            profileDefaultDirectory: profileDefaultDirectory,
            relayHost: relayHost,
            threadSnapshots: threadSnapshots,
            existingRegistry: existingRegistry,
            makeTransport: makeTransport
        )
        return RelayHostWorkspaceConnection(route: route, threadSnapshots: threadSnapshots)
    }
}
