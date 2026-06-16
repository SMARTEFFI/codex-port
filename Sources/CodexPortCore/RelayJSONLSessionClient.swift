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
    private var pendingRemoteFiles: [String: CheckedContinuation<RemoteFileContent, Error>] = [:]
    private var pendingFileOperations: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingWriteStatusAcceptances: [String: CheckedContinuation<RelayWriteStatus, Error>] = [:]
    private var pendingPromptMessages: [String: StructuredUserMessage] = [:]

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
        try await transport.sendLine(try promptCommandLine(
            text: text,
            attachments: [],
            writeID: writeID
        ))
        sessionStore.appendOptimisticUserMessage(text)
    }

    @discardableResult
    public func sendPromptAndWaitForAcceptance(
        _ text: String,
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        try await sendPromptAndWaitForAcceptance(
            StructuredUserMessage(body: text),
            attachments: [],
            writeID: writeID,
            timeout: timeout
        )
    }

    @discardableResult
    public func sendPromptAndWaitForAcceptance(
        _ message: StructuredUserMessage,
        attachments: [TurnAttachment] = [],
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        startReceivingIfNeeded()
        let line = try promptCommandLine(
            text: message.protocolPrompt,
            attachments: attachments,
            writeID: writeID
        )
        let status: RelayWriteStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let replacedContinuation = lock.withLock {
                    var pendingMessage = message
                    if pendingMessage.attachments.isEmpty {
                        pendingMessage.attachments.append(contentsOf: messageAttachments(from: attachments))
                    }
                    pendingPromptMessages[writeID] = pendingMessage
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

    @discardableResult
    public func send(
        composer: InputComposer,
        pendingAttachments: [PendingAttachment],
        remoteRoot: String = "~/.codex-port/attachments",
        writeID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async throws -> RelayWriteStatus {
        startReceivingIfNeeded()
        var relayComposer = composer
        if !pendingAttachments.isEmpty {
            relayComposer.attachments.removeAll()
            let bridge = AttachmentComposerBridge(uploader: AttachmentUploader(
                protocolClient: self,
                remoteRoot: remoteRoot
            ))
            try await bridge.attach(pendingAttachments, threadID: threadID, to: &relayComposer)
        }
        return try await sendPromptAndWaitForAcceptance(
            relayComposer.message,
            attachments: relayComposer.attachments,
            writeID: writeID,
            timeout: timeout
        )
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

    public func readRemoteFile(
        path: String,
        maxBytes: Int,
        requestID: String = UUID().uuidString,
        timeout: Duration = .seconds(10)
    ) async -> Result<RemoteFileContent, RemoteImageReadError> {
        startReceivingIfNeeded()
        let line: String
        do {
            line = try encodeCommand([
                "type": "readFile",
                "clientID": clientID,
                "requestID": requestID,
                "path": path,
                "maxBytes": max(1, maxBytes),
            ])
        } catch {
            return .failure(.transport(String(describing: error)))
        }
        do {
            let content = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let replacedContinuation = lock.withLock {
                        pendingRemoteFiles.updateValue(continuation, forKey: requestID)
                    }
                    replacedContinuation?.resume(throwing: RelayJSONLSessionClientError.timedOut)
                    Task { [weak self] in
                        guard let self else { return }
                        let timeoutTask = Task { [weak self] in
                            try? await Task.sleep(for: timeout)
                            self?.resumePendingRemoteFile(
                                requestID: requestID,
                                result: .failure(RelayJSONLSessionClientError.timedOut)
                            )
                        }
                        do {
                            try await self.transport.sendLine(line)
                        } catch {
                            timeoutTask.cancel()
                            self.resumePendingRemoteFile(requestID: requestID, result: .failure(error))
                        }
                    }
                }
            } onCancel: {
                resumePendingRemoteFile(
                    requestID: requestID,
                    result: .failure(RelayJSONLSessionClientError.timedOut)
                )
            }
            return .success(content)
        } catch RelayJSONLSessionClientError.timedOut {
            return .failure(.transport("远端图片读取超时"))
        } catch let error as RelayJSONLSessionClientError {
            return .failure(.transport(String(describing: error)))
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }

    public func readRemoteFile(path: String, maxBytes: Int) async -> Result<RemoteFileContent, RemoteImageReadError> {
        await readRemoteFile(path: path, maxBytes: maxBytes, requestID: UUID().uuidString, timeout: .seconds(10))
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        try await performFileOperation(
            type: "createDirectory",
            requestID: UUID().uuidString,
            timeout: .seconds(10),
            fields: [
                "path": path,
                "recursive": recursive,
            ]
        )
    }

    public func writeFile(path: String, dataBase64: String) async throws {
        try await performFileOperation(
            type: "writeFile",
            requestID: UUID().uuidString,
            timeout: .seconds(20),
            fields: [
                "path": path,
                "dataBase64": dataBase64,
            ]
        )
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        let (historyContinuations, fileContinuations, fileOperationContinuations, writeContinuations) = lock.withLock {
            let historyContinuations = Array(pendingHistoryPages.values)
            let fileContinuations = Array(pendingRemoteFiles.values)
            let fileOperationContinuations = Array(pendingFileOperations.values)
            let writeContinuations = Array(pendingWriteStatusAcceptances.values)
            pendingHistoryPages.removeAll()
            pendingRemoteFiles.removeAll()
            pendingFileOperations.removeAll()
            pendingWriteStatusAcceptances.removeAll()
            pendingPromptMessages.removeAll()
            return (historyContinuations, fileContinuations, fileOperationContinuations, writeContinuations)
        }
        for continuation in historyContinuations {
            continuation.resume(throwing: RelayJSONLSessionClientError.timedOut)
        }
        for continuation in fileContinuations {
            continuation.resume(throwing: RelayJSONLSessionClientError.timedOut)
        }
        for continuation in fileOperationContinuations {
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
        case let .fileContent(messageClientID, content):
            guard messageClientID == clientID else { return }
            guard let data = Data(base64Encoded: content.dataBase64) else {
                resumePendingRemoteFile(
                    requestID: content.requestID,
                    result: .failure(RelayJSONLSessionClientError.hostAgentError("invalid file data"))
                )
                return
            }
            resumePendingRemoteFile(
                requestID: content.requestID,
                result: .success(RemoteFileContent(
                    path: content.path,
                    contentType: content.contentType,
                    byteCount: content.byteCount,
                    data: data
                ))
            )
        case let .fileOperationResult(messageClientID, _, requestID, _):
            guard messageClientID == clientID else { return }
            resumePendingFileOperation(requestID: requestID, result: .success(()))
        case let .error(messageClientID, reason):
            guard messageClientID == nil || messageClientID == clientID else { return }
            let (historyContinuations, fileContinuations, fileOperationContinuations, writeContinuations) = lock.withLock {
                let historyContinuations = Array(pendingHistoryPages.values)
                let fileContinuations = Array(pendingRemoteFiles.values)
                let fileOperationContinuations = Array(pendingFileOperations.values)
                let writeContinuations = Array(pendingWriteStatusAcceptances.values)
                pendingHistoryPages.removeAll()
                pendingRemoteFiles.removeAll()
                pendingFileOperations.removeAll()
                pendingWriteStatusAcceptances.removeAll()
                pendingPromptMessages.removeAll()
                return (historyContinuations, fileContinuations, fileOperationContinuations, writeContinuations)
            }
            for continuation in historyContinuations {
                continuation.resume(throwing: RelayJSONLSessionClientError.hostAgentError(reason))
            }
            for continuation in fileContinuations {
                continuation.resume(throwing: RelayJSONLSessionClientError.hostAgentError(reason))
            }
            for continuation in fileOperationContinuations {
                continuation.resume(throwing: RelayJSONLSessionClientError.hostAgentError(reason))
            }
            for continuation in writeContinuations {
                continuation.resume(throwing: RelayJSONLSessionClientError.hostAgentError(reason))
            }
        }
    }

    private func recordWriteStatus(sessionID: String, writeID: String, status: RelayWriteStatus) {
        let (acceptanceContinuation, pendingPromptMessage) = lock.withLock {
            latestWriteStatusStorage = WriteStatusUpdate(
                sessionID: sessionID,
                writeID: writeID,
                status: status
            )
            let acceptanceContinuation = pendingWriteStatusAcceptances.removeValue(forKey: writeID)
            let pendingPromptMessage = status.isAccepted ? pendingPromptMessages.removeValue(forKey: writeID) : nil
            if case .failed = status {
                pendingPromptMessages.removeValue(forKey: writeID)
            }
            return (acceptanceContinuation, pendingPromptMessage)
        }
        if case let .failed(reason) = status {
            sessionStore.receive(relayEvent: .turnFailed(turnID: "\(turnID)-\(writeID)-failed", reason: reason))
            acceptanceContinuation?.resume(throwing: RelayJSONLSessionClientError.writeFailed(reason))
        } else {
            if let pendingPromptMessage {
                sessionStore.appendOptimisticUserMessage(pendingPromptMessage)
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
                pendingPromptMessages.removeValue(forKey: writeID)
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

    private func resumePendingRemoteFile(
        requestID: String,
        result: Result<RemoteFileContent, Error>
    ) {
        let continuation = lock.withLock {
            pendingRemoteFiles.removeValue(forKey: requestID)
        }
        switch result {
        case let .success(content):
            continuation?.resume(returning: content)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func resumePendingFileOperation(
        requestID: String,
        result: Result<Void, Error>
    ) {
        let continuation = lock.withLock {
            pendingFileOperations.removeValue(forKey: requestID)
        }
        switch result {
        case .success:
            continuation?.resume()
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func performFileOperation(
        type: String,
        requestID: String,
        timeout: Duration,
        fields: [String: Any]
    ) async throws {
        startReceivingIfNeeded()
        var command = fields
        command["type"] = type
        command["clientID"] = clientID
        command["requestID"] = requestID
        let line = try encodeCommand(command)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let replacedContinuation = lock.withLock {
                    pendingFileOperations.updateValue(continuation, forKey: requestID)
                }
                replacedContinuation?.resume(throwing: RelayJSONLSessionClientError.timedOut)
                Task { [weak self] in
                    guard let self else { return }
                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.resumePendingFileOperation(
                            requestID: requestID,
                            result: .failure(RelayJSONLSessionClientError.timedOut)
                        )
                    }
                    do {
                        try await self.transport.sendLine(line)
                    } catch {
                        timeoutTask.cancel()
                        self.resumePendingFileOperation(requestID: requestID, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            resumePendingFileOperation(
                requestID: requestID,
                result: .failure(RelayJSONLSessionClientError.timedOut)
            )
        }
    }

    private func promptCommandLine(text: String, attachments: [TurnAttachment], writeID: String) throws -> String {
        var command: [String: Any] = [
            "type": "prompt",
            "clientID": clientID,
            "sessionID": sessionID,
            "threadID": threadID,
            "writeID": writeID,
            "text": text,
        ]
        let encodedAttachments = attachments.map(\.jsonObject)
        if !encodedAttachments.isEmpty {
            command["attachments"] = encodedAttachments
        }
        return try encodeCommand(command)
    }

    private func encodeCommand(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension RelayJSONLSessionClient: RemoteImageReading {}
extension RelayJSONLSessionClient: RemoteFileWriting {}

private extension TurnAttachment {
    var jsonObject: [String: Any] {
        switch self {
        case let .localImage(path, detail):
            var object: [String: Any] = [
                "type": "localImage",
                "path": path,
            ]
            if let detail {
                object["detail"] = detail
            }
            return object
        case let .remoteFile(path):
            return [
                "type": "remoteFile",
                "path": path,
            ]
        }
    }
}

private func messageAttachments(from attachments: [TurnAttachment]) -> [MessageAttachment] {
    attachments.map { attachment in
        switch attachment {
        case let .localImage(path, detail):
            return MessageAttachment(
                id: path,
                kind: .image(contentType: nil, detail: detail),
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                source: .remoteHostPath(path)
            )
        case let .remoteFile(path):
            return MessageAttachment(
                id: path,
                kind: .file(contentType: nil),
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                source: .remoteHostPath(path)
            )
        }
    }
}
