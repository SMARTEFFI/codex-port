import Foundation
import CodexPortShared

public enum RelayJSONLSessionClientManagerError: Error, Equatable, Sendable {
    case clientUnavailable
}

public final class RelayJSONLSessionClientManager: @unchecked Sendable {
    public typealias ClientFactory = @Sendable (_ sessionStore: SessionStore) -> RelayJSONLSessionClient?

    private let sessionStore: SessionStore
    private let makeClient: ClientFactory
    private let lock = NSLock()
    private var currentClient: RelayJSONLSessionClient?

    public init(
        sessionStore: SessionStore,
        makeClient: @escaping ClientFactory
    ) {
        self.sessionStore = sessionStore
        self.makeClient = makeClient
    }

    public var client: RelayJSONLSessionClient? {
        lock.withLock {
            currentClient
        }
    }

    @discardableResult
    public func attach() async throws -> RelayJSONLSessionClient {
        if let client {
            return client
        }
        return try await makeAttachedClient()
    }

    public func sendPrompt(_ text: String, writeID: String = UUID().uuidString) async throws {
        let client = try await attach()
        do {
            try await client.sendPrompt(text, writeID: writeID)
        } catch {
            guard Self.shouldRecreateClient(after: error) else {
                throw error
            }
            discardCurrentClient(client)
            let replacement = try await makeAttachedClient()
            try await replacement.sendPrompt(text, writeID: writeID)
        }
    }

    @discardableResult
    public func sendPromptAndWaitForAcceptance(
        _ text: String,
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        let client = try await attach()
        do {
            return try await client.sendPromptAndWaitForAcceptance(text, writeID: writeID, timeout: timeout)
        } catch {
            guard Self.shouldRecreateClient(after: error) else {
                throw error
            }
            discardCurrentClient(client)
            let replacement = try await makeAttachedClient()
            return try await replacement.sendPromptAndWaitForAcceptance(text, writeID: writeID, timeout: timeout)
        }
    }

    @discardableResult
    public func send(
        composer: InputComposer,
        pendingAttachments: [PendingAttachment],
        remoteRoot: String = "~/.codex-port/attachments",
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        let client = try await attach()
        do {
            return try await client.send(
                composer: composer,
                pendingAttachments: pendingAttachments,
                remoteRoot: remoteRoot,
                writeID: writeID,
                timeout: timeout
            )
        } catch {
            guard Self.shouldRecreateClient(after: error) else {
                throw error
            }
            discardCurrentClient(client)
            let replacement = try await makeAttachedClient()
            return try await replacement.send(
                composer: composer,
                pendingAttachments: pendingAttachments,
                remoteRoot: remoteRoot,
                writeID: writeID,
                timeout: timeout
            )
        }
    }

    public func interrupt(writeID: String = UUID().uuidString) async throws {
        let client = try await attach()
        do {
            try await client.interrupt(writeID: writeID)
        } catch {
            guard Self.shouldRecreateClient(after: error) else {
                throw error
            }
            discardCurrentClient(client)
            let replacement = try await makeAttachedClient()
            try await replacement.interrupt(writeID: writeID)
        }
    }

    public func loadEarlierHistory(
        cursor: String?,
        limit: Int = SessionStore.defaultHistoryTurnPageSize,
        requestID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayThreadHistoryPage {
        let client = try await attach()
        do {
            return try await client.loadEarlierHistory(
                cursor: cursor,
                limit: limit,
                requestID: requestID,
                timeout: timeout
            )
        } catch {
            guard Self.shouldRecreateClient(after: error) else {
                throw error
            }
            discardCurrentClient(client)
            let replacement = try await makeAttachedClient()
            return try await replacement.loadEarlierHistory(
                cursor: cursor,
                limit: limit,
                requestID: requestID,
                timeout: timeout
            )
        }
    }

    public func readRemoteFile(path: String, maxBytes: Int) async -> Result<RemoteFileContent, RemoteImageReadError> {
        do {
            let client = try await attach()
            let result = await client.readRemoteFile(path: path, maxBytes: maxBytes)
            if case let .failure(error) = result,
               case .transport = error {
                discardCurrentClient(client)
            }
            return result
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }

    public func stop() {
        lock.withLock {
            let client = currentClient
            currentClient = nil
            return client
        }?.stop()
    }

    private func makeAttachedClient() async throws -> RelayJSONLSessionClient {
        guard let client = makeClient(sessionStore) else {
            throw RelayJSONLSessionClientManagerError.clientUnavailable
        }
        try await client.attach()
        let previous = lock.withLock {
            let previous = currentClient
            currentClient = client
            return previous
        }
        previous?.stop()
        return client
    }

    private func discardCurrentClient(_ client: RelayJSONLSessionClient) {
        let discarded = lock.withLock {
            guard currentClient === client else { return nil as RelayJSONLSessionClient? }
            currentClient = nil
            return client
        }
        discarded?.stop()
    }

    public static func shouldRecreateClient(after error: Error) -> Bool {
        if let posix = error as? POSIXError {
            return retryablePOSIXCodes.contains(posix.code)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return retryablePOSIXCodes.contains(code)
        }
        if nsError.domain == NSURLErrorDomain {
            return retryableURLErrorCodes.contains(nsError.code)
        }
        return false
    }

    private static let retryablePOSIXCodes: Set<POSIXErrorCode> = [
        .ECONNABORTED,
        .ECONNRESET,
        .ENOTCONN,
        .EPIPE,
    ]

    private static let retryableURLErrorCodes: Set<Int> = [
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut,
        NSURLErrorDNSLookupFailed,
    ]
}

extension RelayJSONLSessionClientManager: RemoteImageReading {}
