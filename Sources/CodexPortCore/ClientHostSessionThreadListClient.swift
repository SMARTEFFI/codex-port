import Foundation
import CodexPortShared

public typealias ClientHostSessionThreadListClientError = RelayJSONLThreadListClientError
public typealias ClientHostSessionThreadListProgressEvent = RelayThreadListProgressEvent

public final class ClientHostSessionThreadListClient: @unchecked Sendable {
    public typealias ProgressObserver = RelayJSONLThreadListClient.ProgressObserver

    private let client: RelayJSONLThreadListClient

    public init(
        clientID: String,
        transport: RelayJSONLTransport,
        timeout: Duration = .seconds(10),
        pageSize: Int = 20,
        progressObserver: ProgressObserver? = nil
    ) {
        self.client = RelayJSONLThreadListClient(
            clientID: clientID,
            transport: transport,
            timeout: timeout,
            pageSize: pageSize,
            progressObserver: progressObserver
        )
    }

    public func listThreads(
        limit: Int = 100,
        requestID: String = UUID().uuidString
    ) async throws -> [RelayThreadSummarySnapshot] {
        try await client.listThreads(limit: limit, requestID: requestID)
    }
}
