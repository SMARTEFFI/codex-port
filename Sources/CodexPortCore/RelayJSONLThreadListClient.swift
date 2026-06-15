import Foundation
import CodexPortShared

public enum RelayJSONLThreadListClientError: Error, Equatable, Sendable {
    case transportUnavailable
    case timedOut
    case hostAgentError(String)
}

public enum RelayThreadListProgressEvent: Equatable, Sendable {
    case requestingPage(requestID: String, limit: Int, cursor: String?)
    case receivedPage(requestID: String, count: Int, nextCursor: String?)
}

public final class RelayJSONLThreadListClient: @unchecked Sendable {
    public typealias ProgressObserver = @Sendable (RelayThreadListProgressEvent) async -> Void

    private let clientID: String
    private let transport: RelayJSONLTransport
    private let timeout: Duration
    private let pageSize: Int
    private let progressObserver: ProgressObserver?

    public init(
        clientID: String,
        transport: RelayJSONLTransport,
        timeout: Duration = .seconds(10),
        pageSize: Int = 20,
        progressObserver: ProgressObserver? = nil
    ) {
        self.clientID = clientID
        self.transport = transport
        self.timeout = timeout
        self.pageSize = max(1, pageSize)
        self.progressObserver = progressObserver
    }

    public func listThreads(limit: Int = 100, requestID: String = UUID().uuidString) async throws -> [RelayThreadSummarySnapshot] {
        var allThreads: [RelayThreadSummarySnapshot] = []
        var cursor: String?
        repeat {
            let response: RelayThreadListResponse
            do {
                response = try await listThreadPage(
                    limit: min(pageSize, max(1, limit - allThreads.count)),
                    cursor: cursor,
                    requestID: allThreads.isEmpty ? requestID : "\(requestID)-\(allThreads.count)"
                )
            } catch {
                if allThreads.isEmpty {
                    throw error
                }
                break
            }
            allThreads.append(contentsOf: response.threads)
            cursor = response.nextCursor
            if response.threads.isEmpty {
                cursor = nil
            }
        } while allThreads.count < limit && cursor != nil
        return Array(allThreads.prefix(limit))
    }

    private func listThreadPage(limit: Int, cursor: String?, requestID: String) async throws -> RelayThreadListResponse {
        let incomingLines = transport.incomingLines
        var command: [String: Any] = [
            "type": "listThreads",
            "clientID": clientID,
            "requestID": requestID,
            "limit": max(1, limit),
        ]
        if let cursor {
            command["cursor"] = cursor
        }
        await progressObserver?(.requestingPage(requestID: requestID, limit: max(1, limit), cursor: cursor))
        try await transport.sendLine(try encode(command))

        let clientID = self.clientID
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: RelayThreadListResponse.self) { group in
            group.addTask {
                var iterator = incomingLines.makeAsyncIterator()
                while let line = await iterator.next() {
                    guard let message = try? RelayEndpointJSONLCodec.decodeLine(line) else {
                        continue
                    }
                    switch message {
                    case let .threadList(messageClientID, messageRequestID, threads, nextCursor):
                        guard messageClientID == clientID, messageRequestID == requestID else { continue }
                        let response = RelayThreadListResponse(threads: threads, nextCursor: nextCursor)
                        await self.progressObserver?(.receivedPage(requestID: requestID, count: threads.count, nextCursor: nextCursor))
                        return response
                    case let .error(messageClientID, reason):
                        guard messageClientID == nil || messageClientID == clientID else { continue }
                        throw RelayJSONLThreadListClientError.hostAgentError(reason)
                    case .event, .writeStatus, .threadHistoryPage, .fileContent:
                        continue
                    }
                }
                throw RelayJSONLThreadListClientError.timedOut
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RelayJSONLThreadListClientError.timedOut
            }
            guard let response = try await group.next() else {
                throw RelayJSONLThreadListClientError.timedOut
            }
            group.cancelAll()
            return response
        }
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

}
