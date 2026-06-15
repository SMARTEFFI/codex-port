import Foundation
import CodexPortShared

public typealias ClientHostSessionClientError = RelayJSONLSessionClientError

public final class ClientHostSessionClient: @unchecked Sendable {
    public typealias WriteStatusUpdate = RelayJSONLSessionClient.WriteStatusUpdate

    private let client: RelayJSONLSessionClient

    public init(
        clientID: String,
        sessionID: String,
        threadID: String,
        turnID: String,
        cwd: String? = nil,
        transport: RelayJSONLTransport,
        sessionStore: SessionStore
    ) {
        self.client = RelayJSONLSessionClient(
            clientID: clientID,
            sessionID: sessionID,
            threadID: threadID,
            turnID: turnID,
            cwd: cwd,
            transport: transport,
            sessionStore: sessionStore
        )
    }

    public func attach() async throws {
        try await client.attach()
    }

    public var latestWriteStatus: WriteStatusUpdate? {
        client.latestWriteStatus
    }

    public func sendPrompt(_ text: String, writeID: String = UUID().uuidString) async throws {
        try await client.sendPrompt(text, writeID: writeID)
    }

    public func interrupt(writeID: String = UUID().uuidString) async throws {
        try await client.interrupt(writeID: writeID)
    }

    public func sendApproval(
        requestID: String,
        action: RelayApprovalAction,
        writeID: String = UUID().uuidString
    ) async throws {
        try await client.sendApproval(requestID: requestID, action: action, writeID: writeID)
    }

    @discardableResult
    public func sendPromptAndWaitForAcceptance(
        _ text: String,
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        try await client.sendPromptAndWaitForAcceptance(
            text,
            writeID: writeID,
            timeout: timeout
        )
    }

    public func loadEarlierHistory(
        cursor: String?,
        limit: Int = SessionStore.defaultHistoryTurnPageSize,
        requestID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayThreadHistoryPage {
        try await client.loadEarlierHistory(
            cursor: cursor,
            limit: limit,
            requestID: requestID,
            timeout: timeout
        )
    }

    public func stop() {
        client.stop()
    }
}
