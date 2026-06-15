import Foundation
import CodexPortShared

public protocol RelayJSONLTransport: Sendable {
    var incomingLines: AsyncStream<String> { get }
    func sendLine(_ line: String) async throws
}

public enum RelayJSONLSessionClientError: Error, Equatable, Sendable {
    case timedOut
    case hostAgentError(String)
    case writeFailed(String)
}

public final class RelayJSONLSessionClient: @unchecked Sendable {
    public struct WriteStatusUpdate: Equatable, Sendable {
        public var sessionID: String
        public var writeID: String
        public var status: RelayWriteStatus

        public init(sessionID: String, writeID: String, status: RelayWriteStatus) {
            self.sessionID = sessionID
            self.writeID = writeID
            self.status = status
        }
    }

    private let clientID: String
    private let sessionID: String
    private let threadID: String
    private let turnID: String
    private let cwd: String?
    private let transport: RelayJSONLTransport
    private let sessionStore: SessionStore
    private let lock = NSLock()
    private var latestWriteStatusStorage: WriteStatusUpdate?
    private var receiveTask: Task<Void, Never>?
    private var pendingHistoryPages: [String: CheckedContinuation<RelayThreadHistoryPage, Error>] = [:]
    private var pendingWriteStatusAcceptances: [String: CheckedContinuation<RelayWriteStatus, Error>] = [:]
    private var pendingPromptTexts: [String: String] = [:]

    public init(
        clientID: String,
        sessionID: String,
        threadID: String,
        turnID: String,
        cwd: String? = nil,
        transport: RelayJSONLTransport,
        sessionStore: SessionStore
    ) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.cwd = cwd
        self.transport = transport
        self.sessionStore = sessionStore
    }

    deinit {
        stop()
    }

    public var latestWriteStatus: WriteStatusUpdate? {
        lock.withLock {
            latestWriteStatusStorage
        }
    }

    public func attach() async throws {
        startReceivingIfNeeded()
        var command: [String: Any] = [
            "type": "attach",
            "clientID": clientID,
            "sessionID": sessionID,
            "threadID": threadID,
            "turnID": turnID,
        ]
        if let cwd, !cwd.isEmpty {
            command["cwd"] = cwd
        }
        try await transport.sendLine(try encodeCommand(command))
    }

    public func sendPrompt(_ text: String, writeID: String = UUID().uuidString) async throws {
        try await transport.sendLine(try encodeCommand([
            "type": "prompt",
            "clientID": clientID,
            "sessionID": sessionID,
            "threadID": threadID,
            "writeID": writeID,
            "text": text,
        ]))
        sessionStore.appendOptimisticUserMessage(text)
    }

    @discardableResult
    public func sendPromptAndWaitForAcceptance(
        _ text: String,
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        startReceivingIfNeeded()
        let line = try encodeCommand([
            "type": "prompt",
            "clientID": clientID,
            "sessionID": sessionID,
            "threadID": threadID,
            "writeID": writeID,
            "text": text,
        ])
        let status: RelayWriteStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let replacedContinuation = lock.withLock {
                    pendingPromptTexts[writeID] = text
                    return pendingWriteStatusAcceptances.updateValue(continuation, forKey: writeID)
                }
                replacedContinuation?.resume(throwing: RelayJSONLSessionClientError.timedOut)
                Task { [weak self] in
                    guard let self else {
                        return
                    }
                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.resumePendingWriteStatusAcceptance(
                            writeID: writeID,
                            result: .failure(RelayJSONLSessionClientError.timedOut)
                        )
                    }
                    do {
                        try await self.transport.sendLine(line)
                    } catch {
                        timeoutTask.cancel()
                        self.resumePendingWriteStatusAcceptance(writeID: writeID, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            resumePendingWriteStatusAcceptance(
                writeID: writeID,
                result: .failure(RelayJSONLSessionClientError.timedOut)
            )
        }
        return status
    }

    public func interrupt(writeID: String = UUID().uuidString) async throws {
        try await transport.sendLine(try encodeCommand([
            "type": "interrupt",
            "clientID": clientID,
            "sessionID": sessionID,
            "threadID": threadID,
            "turnID": turnID,
            "writeID": writeID,
        ]))
    }

    public func sendApproval(
        requestID: String,
        action: RelayApprovalAction,
        writeID: String = UUID().uuidString
    ) async throws {
        try await transport.sendLine(try encodeCommand([
            "type": "approval",
            "clientID": clientID,
            "sessionID": sessionID,
            "requestID": requestID,
            "action": action.wireValue,
            "writeID": writeID,
        ]))
    }

    public func loadEarlierHistory(
        cursor: String?,
        limit: Int = SessionStore.defaultHistoryTurnPageSize,
        requestID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayThreadHistoryPage {
        startReceivingIfNeeded()
        var command: [String: Any] = [
            "type": "loadHistory",
            "clientID": clientID,
            "requestID": requestID,
            "threadID": threadID,
            "limit": max(1, limit),
        ]
        if let cursor, !cursor.isEmpty {
            command["cursor"] = cursor
        }
        let line = try encodeCommand(command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let replacedContinuation = lock.withLock {
                    pendingHistoryPages.updateValue(continuation, forKey: requestID)
                }
                replacedContinuation?.resume(throwing: RelayJSONLSessionClientError.timedOut)
                Task { [weak self] in
                    guard let self else {
                        return
                    }
                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.resumePendingHistoryPage(requestID: requestID, result: .failure(RelayJSONLSessionClientError.timedOut))
                    }
                    do {
                        try await self.transport.sendLine(line)
                    } catch {
                        timeoutTask.cancel()
                        self.resumePendingHistoryPage(requestID: requestID, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            resumePendingHistoryPage(requestID: requestID, result: .failure(RelayJSONLSessionClientError.timedOut))
        }
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        let (historyContinuations, writeContinuations) = lock.withLock {
            let historyContinuations = Array(pendingHistoryPages.values)
            let writeContinuations = Array(pendingWriteStatusAcceptances.values)
            pendingHistoryPages.removeAll()
            pendingWriteStatusAcceptances.removeAll()
            pendingPromptTexts.removeAll()
            return (historyContinuations, writeContinuations)
        }
        for continuation in historyContinuations {
            continuation.resume(throwing: RelayJSONLSessionClientError.timedOut)
        }
        for continuation in writeContinuations {
            continuation.resume(throwing: RelayJSONLSessionClientError.timedOut)
        }
    }

    private func startReceivingIfNeeded() {
        guard receiveTask == nil else { return }
        let incomingLines = transport.incomingLines
        receiveTask = Task { [weak self] in
            for await line in incomingLines {
                self?.receive(line)
            }
        }
    }

    private func receive(_ line: String) {
        guard let message = try? RelayEndpointJSONLCodec.decodeLine(line) else { return }
        switch message {
        case let .event(messageClientID, event):
            guard messageClientID == clientID else { return }
            if case let .writeStatusChanged(writeID, status) = event {
                recordWriteStatus(sessionID: sessionID, writeID: writeID, status: status)
            }
            sessionStore.receive(relayEvent: event)
        case let .writeStatus(messageClientID, messageSessionID, writeID, status):
            guard messageClientID == clientID, messageSessionID == sessionID else { return }
            recordWriteStatus(sessionID: messageSessionID, writeID: writeID, status: status)
        case .threadList:
            break
        case let .threadHistoryPage(messageClientID, page):
            guard messageClientID == clientID else { return }
            sessionStore.receive(relayHistoryPage: page)
            guard page.requestID != "initial" else { return }
            resumePendingHistoryPage(requestID: page.requestID, result: .success(page))
        case let .error(messageClientID, reason):
            guard messageClientID == nil || messageClientID == clientID else { return }
            let (historyContinuations, writeContinuations) = lock.withLock {
                let historyContinuations = Array(pendingHistoryPages.values)
                let writeContinuations = Array(pendingWriteStatusAcceptances.values)
                pendingHistoryPages.removeAll()
                pendingWriteStatusAcceptances.removeAll()
                return (historyContinuations, writeContinuations)
            }
            for continuation in historyContinuations {
                continuation.resume(throwing: RelayJSONLSessionClientError.hostAgentError(reason))
            }
            for continuation in writeContinuations {
                continuation.resume(throwing: RelayJSONLSessionClientError.hostAgentError(reason))
            }
        }
    }

    private func recordWriteStatus(sessionID: String, writeID: String, status: RelayWriteStatus) {
        let (acceptanceContinuation, pendingPromptText) = lock.withLock {
            latestWriteStatusStorage = WriteStatusUpdate(
                sessionID: sessionID,
                writeID: writeID,
                status: status
            )
            let acceptanceContinuation = pendingWriteStatusAcceptances.removeValue(forKey: writeID)
            let pendingPromptText = status.isAccepted ? pendingPromptTexts.removeValue(forKey: writeID) : nil
            if case .failed = status {
                pendingPromptTexts.removeValue(forKey: writeID)
            }
            return (acceptanceContinuation, pendingPromptText)
        }
        if case let .failed(reason) = status {
            sessionStore.receive(relayEvent: .turnFailed(turnID: "\(turnID)-\(writeID)-failed", reason: reason))
            acceptanceContinuation?.resume(throwing: RelayJSONLSessionClientError.writeFailed(reason))
        } else {
            if let pendingPromptText {
                sessionStore.appendOptimisticUserMessage(pendingPromptText)
            }
            if status == .queued || status == .running {
                sessionStore.receive(.threadStatusChanged(threadID: threadID, status: .running))
            }
            acceptanceContinuation?.resume(returning: status)
        }
    }

    private func resumePendingWriteStatusAcceptance(
        writeID: String,
        result: Result<RelayWriteStatus, Error>
    ) {
        let continuation = lock.withLock {
            if case .failure = result {
                pendingPromptTexts.removeValue(forKey: writeID)
            }
            return pendingWriteStatusAcceptances.removeValue(forKey: writeID)
        }
        switch result {
        case let .success(status):
            continuation?.resume(returning: status)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func resumePendingHistoryPage(
        requestID: String,
        result: Result<RelayThreadHistoryPage, Error>
    ) {
        let continuation = lock.withLock {
            pendingHistoryPages.removeValue(forKey: requestID)
        }
        switch result {
        case let .success(page):
            continuation?.resume(returning: page)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func encodeCommand(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
