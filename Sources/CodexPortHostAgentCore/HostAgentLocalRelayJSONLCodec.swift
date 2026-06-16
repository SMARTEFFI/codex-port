import Foundation
import CodexPortShared

public enum HostAgentLocalRelayJSONLCommand: Equatable, Sendable {
    case listThreads(clientID: String, requestID: String, limit: Int, cursor: String?)
    case loadHistory(clientID: String, requestID: String, threadID: String, limit: Int, cursor: String?)
    case readFile(clientID: String, requestID: String, path: String, maxBytes: Int)
    case createDirectory(clientID: String, requestID: String, path: String, recursive: Bool)
    case writeFile(clientID: String, requestID: String, path: String, dataBase64: String)
    case attach(clientID: String, request: HostAgentLocalRelayAttachRequest)
    case submit(clientID: String, sessionID: String, write: RelayLiveSessionWrite)
    case detach(clientID: String, sessionID: String)
    case stop(sessionID: String)
}

public enum HostAgentLocalRelayJSONLCodecError: Error, Equatable, Sendable {
    case invalidJSON
    case missingField(String)
    case unsupportedType(String)
}

public enum HostAgentLocalRelayJSONLCodec {
    public static func decodeCommand(from line: String) throws -> HostAgentLocalRelayJSONLCommand {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostAgentLocalRelayJSONLCodecError.invalidJSON
        }

        let type = try string("type", in: object)
        switch type {
        case "listThreads":
            return .listThreads(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                limit: int("limit", in: object) ?? 100,
                cursor: object["cursor"] as? String
            )
        case "loadHistory":
            return .loadHistory(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                threadID: try string("threadID", in: object),
                limit: int("limit", in: object) ?? 10,
                cursor: object["cursor"] as? String
            )
        case "readFile":
            return .readFile(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                path: try string("path", in: object),
                maxBytes: int("maxBytes", in: object) ?? 5_000_000
            )
        case "createDirectory":
            return .createDirectory(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                path: try string("path", in: object),
                recursive: bool("recursive", in: object) ?? true
            )
        case "writeFile":
            return .writeFile(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                path: try string("path", in: object),
                dataBase64: try string("dataBase64", in: object)
            )
        case "attach":
            return .attach(
                clientID: try string("clientID", in: object),
                request: HostAgentLocalRelayAttachRequest(
                    sessionID: try string("sessionID", in: object),
                    threadID: try string("threadID", in: object),
                    turnID: try string("turnID", in: object),
                    cwd: object["cwd"] as? String
                )
            )
        case "prompt":
            let threadID = try string("threadID", in: object)
            return .submit(
                clientID: try string("clientID", in: object),
                sessionID: try string("sessionID", in: object),
                write: .prompt(
                    writeID: try string("writeID", in: object),
                    threadID: threadID,
                    text: try string("text", in: object),
                    attachments: try attachments(from: object)
                )
            )
        case "interrupt":
            return .submit(
                clientID: try string("clientID", in: object),
                sessionID: try string("sessionID", in: object),
                write: .interrupt(
                    writeID: try string("writeID", in: object),
                    threadID: try string("threadID", in: object),
                    turnID: try string("turnID", in: object)
                )
            )
        case "approval":
            return .submit(
                clientID: try string("clientID", in: object),
                sessionID: try string("sessionID", in: object),
                write: .approval(
                    writeID: try string("writeID", in: object),
                    requestID: try string("requestID", in: object),
                    action: try approvalAction(try string("action", in: object))
                )
            )
        case "detach":
            return .detach(
                clientID: try string("clientID", in: object),
                sessionID: try string("sessionID", in: object)
            )
        case "stop":
            return .stop(sessionID: try string("sessionID", in: object))
        default:
            throw HostAgentLocalRelayJSONLCodecError.unsupportedType(type)
        }
    }

    public static func encodeEvent(_ event: RelayLiveSessionEvent, clientID: String) throws -> String {
        try encode(event.telemetryObject(clientID: clientID))
    }

    public static func encodeWriteStatus(
        _ status: RelayWriteStatus,
        clientID: String,
        sessionID: String,
        writeID: String
    ) throws -> String {
        try encode([
            "type": "writeStatus",
            "clientID": clientID,
            "sessionID": sessionID,
            "writeID": writeID,
            "status": status.wireStatus,
        ])
    }

    public static func encodeThreadList(
        _ threads: [RelayThreadSummarySnapshot],
        clientID: String,
        requestID: String,
        nextCursor: String? = nil
    ) throws -> String {
        try RelayEndpointJSONLCodec.encodeThreadList(threads, clientID: clientID, requestID: requestID, nextCursor: nextCursor)
    }

    public static func encodeThreadHistoryPage(_ page: RelayThreadHistoryPage, clientID: String) throws -> String {
        try RelayEndpointJSONLCodec.encodeThreadHistoryPage(page, clientID: clientID)
    }

    public static func encodeFileOperationResult(
        operation: String,
        requestID: String,
        path: String,
        clientID: String
    ) throws -> String {
        try RelayEndpointJSONLCodec.encodeFileOperationResult(
            operation: operation,
            requestID: requestID,
            path: path,
            clientID: clientID
        )
    }

    public static func encodeError(_ reason: String, clientID: String? = nil) throws -> String {
        var object: [String: Any] = [
            "type": "error",
            "reasonBytes": reason.utf8.count,
        ]
        if let clientID {
            object["clientID"] = clientID
        }
        return try encode(object)
    }

    public static func diagnosticOutputSummary(from line: String) -> HostAgentLocalRelayOutputDiagnosticSummary? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return nil
        }
        return HostAgentLocalRelayOutputDiagnosticSummary(
            type: type,
            event: object["event"] as? String,
            clientID: object["clientID"] as? String,
            sessionID: object["sessionID"] as? String,
            threadID: object["threadID"] as? String,
            turnID: object["turnID"] as? String,
            itemID: object["itemID"] as? String,
            requestID: object["requestID"] as? String,
            writeID: object["writeID"] as? String,
            status: object["status"] as? String,
            outputBytes: line.utf8.count
        )
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object.sortedForStableEncoding(), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw HostAgentLocalRelayJSONLCodecError.missingField(key)
        }
        return value
    }

    private static func int(_ key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? Double {
            return Int(value)
        }
        if let value = object[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func bool(_ key: String, in object: [String: Any]) -> Bool? {
        if let value = object[key] as? Bool {
            return value
        }
        if let value = object[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func attachments(from object: [String: Any]) throws -> [TurnAttachment] {
        guard let attachmentObjects = object["attachments"] as? [[String: Any]] else {
            return []
        }
        return try attachmentObjects.map { attachmentObject in
            switch try string("type", in: attachmentObject) {
            case "localImage":
                return .localImage(path: try string("path", in: attachmentObject), detail: attachmentObject["detail"] as? String)
            case "remoteFile":
                return .remoteFile(path: try string("path", in: attachmentObject))
            default:
                throw HostAgentLocalRelayJSONLCodecError.unsupportedType(try string("type", in: attachmentObject))
            }
        }
    }

    private static func approvalAction(_ value: String) throws -> RelayApprovalAction {
        switch value {
        case "accept":
            return .accept
        case "accept-for-session":
            return .acceptForSession
        case "decline":
            return .decline
        case "cancel":
            return .cancel
        default:
            throw HostAgentLocalRelayJSONLCodecError.unsupportedType(value)
        }
    }
}

public extension HostAgentLocalRelayJSONLCommand {
    func diagnosticSummary(inputBytes: Int) -> HostAgentLocalRelayCommandDiagnosticSummary {
        switch self {
        case let .listThreads(clientID, _, _, _):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "listThreads", clientID: clientID, inputBytes: inputBytes)
        case let .loadHistory(clientID, _, threadID, _, _):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "loadHistory", clientID: clientID, threadID: threadID, inputBytes: inputBytes)
        case let .readFile(clientID, _, _, _):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "readFile", clientID: clientID, inputBytes: inputBytes)
        case let .createDirectory(clientID, _, _, _):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "createDirectory", clientID: clientID, inputBytes: inputBytes)
        case let .writeFile(clientID, _, _, _):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "writeFile", clientID: clientID, inputBytes: inputBytes)
        case let .attach(clientID, request):
            HostAgentLocalRelayCommandDiagnosticSummary(
                type: "attach",
                clientID: clientID,
                sessionID: request.sessionID,
                threadID: request.threadID,
                inputBytes: inputBytes
            )
        case let .submit(clientID, sessionID, write):
            HostAgentLocalRelayCommandDiagnosticSummary(
                type: write.diagnosticType,
                clientID: clientID,
                sessionID: sessionID,
                threadID: write.diagnosticThreadID,
                writeID: write.writeID,
                inputBytes: inputBytes
            )
        case let .detach(clientID, sessionID):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "detach", clientID: clientID, sessionID: sessionID, inputBytes: inputBytes)
        case let .stop(sessionID):
            HostAgentLocalRelayCommandDiagnosticSummary(type: "stop", sessionID: sessionID, inputBytes: inputBytes)
        }
    }
}

private extension RelayLiveSessionWrite {
    var diagnosticType: String {
        switch self {
        case .prompt:
            "prompt"
        case .interrupt:
            "interrupt"
        case .approval:
            "approval"
        }
    }

    var diagnosticThreadID: String? {
        switch self {
        case let .prompt(_, threadID, _, _), let .interrupt(_, threadID, _):
            threadID
        case .approval:
            nil
        }
    }
}

private extension RelayLiveSessionEvent {
    func telemetryObject(clientID: String) -> [String: Any] {
        var object: [String: Any] = [
            "type": "event",
            "clientID": clientID,
        ]
        switch self {
        case let .sessionStarted(sessionID, threadID, turnID):
            object["event"] = "sessionStarted"
            object["sessionID"] = sessionID
            object["threadID"] = threadID
            object["turnID"] = turnID
        case let .threadHistoryLoaded(threadID, items, status):
            object["event"] = "threadHistoryLoaded"
            object["threadID"] = threadID
            object["itemCount"] = items.count
            object["status"] = status.rawValue
        case let .userMessage(turnID, itemID, text):
            object["event"] = "userMessage"
            object["turnID"] = turnID
            object["itemID"] = itemID
            object["textBytes"] = text.utf8.count
        case let .assistantTextDelta(turnID, itemID, text):
            object["event"] = "assistantTextDelta"
            object["turnID"] = turnID
            object["itemID"] = itemID
            object["textBytes"] = text.utf8.count
        case let .commandOutputDelta(turnID, itemID, text):
            object["event"] = "commandOutputDelta"
            object["turnID"] = turnID
            object["itemID"] = itemID
            object["textBytes"] = text.utf8.count
        case let .fileChange(turnID, itemID, path, diff):
            object["event"] = "fileChange"
            object["turnID"] = turnID
            object["itemID"] = itemID
            object["path"] = path
            object["diffBytes"] = diff.utf8.count
        case let .approvalRequested(turnID, requestID, summary):
            object["event"] = "approvalRequested"
            object["turnID"] = turnID
            object["requestID"] = requestID
            object["summaryBytes"] = summary.utf8.count
        case let .turnCompleted(turnID):
            object["event"] = "turnCompleted"
            object["turnID"] = turnID
        case let .turnFailed(turnID, reason):
            object["event"] = "turnFailed"
            object["turnID"] = turnID
            object["reasonBytes"] = reason.utf8.count
        case let .writeStatusChanged(writeID, status):
            object["event"] = "writeStatusChanged"
            object["writeID"] = writeID
            object["status"] = status.wireStatus
        case let .streamClosed(sessionID, threadID, errorCode):
            object["event"] = "streamClosed"
            object["sessionID"] = sessionID
            object["threadID"] = threadID
            object["errorCode"] = errorCode ?? "none"
        }
        return object
    }
}

private extension RelayWriteStatus {
    var wireStatus: String {
        switch self {
        case .queued:
            return "queued"
        case .running:
            return "running"
        case .handled:
            return "handled"
        case .failed:
            return "failed"
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func sortedForStableEncoding() -> [String: Any] {
        reduce(into: [String: Any]()) { partialResult, pair in
            partialResult[pair.key] = pair.value
        }
    }
}
