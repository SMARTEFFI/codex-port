import Foundation

public enum RelayEndpointJSONLMessage: Equatable, Sendable {
    case event(clientID: String, RelayLiveSessionEvent)
    case writeStatus(clientID: String, sessionID: String, writeID: String, RelayWriteStatus)
    case threadList(clientID: String, requestID: String, threads: [RelayThreadSummarySnapshot], nextCursor: String?)
    case threadStarted(clientID: String, requestID: String, thread: RelayThreadSummarySnapshot)
    case threadHistoryPage(clientID: String, RelayThreadHistoryPage)
    case fileContent(clientID: String, RelayRemoteFileContent)
    case fileOperationResult(clientID: String, operation: String, requestID: String, path: String)
    case error(clientID: String?, reason: String)

    public var telemetryDescription: String {
        switch self {
        case let .event(clientID, event):
            "event client=\(clientID) \(event.telemetryDescription)"
        case let .writeStatus(clientID, sessionID, writeID, status):
            "writeStatus client=\(clientID) session=\(sessionID) write=\(writeID) status=\(status.wireStatus)"
        case let .threadList(clientID, requestID, threads, _):
            "threadList client=\(clientID) request=\(requestID) count=\(threads.count)"
        case let .threadStarted(clientID, requestID, thread):
            "threadStarted client=\(clientID) request=\(requestID) thread=\(thread.id)"
        case let .threadHistoryPage(clientID, page):
            "threadHistoryPage client=\(clientID) request=\(page.requestID) thread=\(page.threadID) items=\(page.items.count) status=\(page.status.rawValue)"
        case let .fileContent(clientID, content):
            "fileContent client=\(clientID) request=\(content.requestID) pathBytes=\(content.path.utf8.count) bytes=\(content.byteCount)"
        case let .fileOperationResult(clientID, operation, requestID, path):
            "fileOperationResult client=\(clientID) operation=\(operation) request=\(requestID) pathBytes=\(path.utf8.count)"
        case let .error(clientID, reason):
            "error client=\(clientID ?? "none") reasonBytes=\(reason.utf8.count)"
        }
    }
}

public struct RelayRemoteFileContent: Codable, Equatable, Sendable {
    public var requestID: String
    public var path: String
    public var contentType: String?
    public var byteCount: Int
    public var dataBase64: String

    public init(
        requestID: String,
        path: String,
        contentType: String?,
        byteCount: Int,
        dataBase64: String
    ) {
        self.requestID = requestID
        self.path = path
        self.contentType = contentType
        self.byteCount = byteCount
        self.dataBase64 = dataBase64
    }
}

public enum RelayEndpointJSONLCodecError: Error, Equatable, Sendable {
    case invalidJSON
    case missingField(String)
    case unsupportedType(String)
}

public enum RelayEndpointJSONLCodec {
    public static func encodeEvent(_ event: RelayLiveSessionEvent, clientID: String) throws -> String {
        var object = event.endpointObject
        object["type"] = "event"
        object["clientID"] = clientID
        return try encode(object)
    }

    public static func encodeWriteStatus(
        _ status: RelayWriteStatus,
        clientID: String,
        sessionID: String,
        writeID: String
    ) throws -> String {
        var object: [String: Any] = [
            "type": "writeStatus",
            "clientID": clientID,
            "sessionID": sessionID,
            "writeID": writeID,
            "status": status.wireStatus,
        ]
        if case let .failed(reason) = status {
            object["reason"] = reason
        }
        return try encode(object)
    }

    public static func encodeError(_ reason: String, clientID: String? = nil) throws -> String {
        var object: [String: Any] = [
            "type": "error",
            "reason": reason,
        ]
        if let clientID {
            object["clientID"] = clientID
        }
        return try encode(object)
    }

    public static func encodeThreadList(
        _ threads: [RelayThreadSummarySnapshot],
        clientID: String,
        requestID: String,
        nextCursor: String? = nil
    ) throws -> String {
        let threadData = try JSONEncoder().encode(threads)
        let threadObjects = try JSONSerialization.jsonObject(with: threadData) as? [[String: Any]] ?? []
        var object: [String: Any] = [
            "type": "threadList",
            "clientID": clientID,
            "requestID": requestID,
            "threads": threadObjects,
        ]
        if let nextCursor {
            object["nextCursor"] = nextCursor
        }
        return try encode(object)
    }

    public static func encodeThreadStarted(
        _ thread: RelayThreadSummarySnapshot,
        clientID: String,
        requestID: String
    ) throws -> String {
        let threadData = try JSONEncoder().encode(thread)
        let threadObject = try JSONSerialization.jsonObject(with: threadData) as? [String: Any] ?? [:]
        return try encode([
            "type": "threadStarted",
            "clientID": clientID,
            "requestID": requestID,
            "thread": threadObject,
        ])
    }

    public static func encodeThreadHistoryPage(_ page: RelayThreadHistoryPage, clientID: String) throws -> String {
        let itemData = try JSONEncoder().encode(page.items)
        let itemObjects = try JSONSerialization.jsonObject(with: itemData) as? [[String: Any]] ?? []
        var object: [String: Any] = [
            "type": "threadHistoryPage",
            "clientID": clientID,
            "requestID": page.requestID,
            "threadID": page.threadID,
            "items": itemObjects,
            "status": page.status.rawValue,
        ]
        if let nextCursor = page.nextCursor {
            object["nextCursor"] = nextCursor
        }
        return try encode(object)
    }

    public static func encodeFileContent(_ content: RelayRemoteFileContent, clientID: String) throws -> String {
        var object: [String: Any] = [
            "type": "fileContent",
            "clientID": clientID,
            "requestID": content.requestID,
            "path": content.path,
            "byteCount": content.byteCount,
            "dataBase64": content.dataBase64,
        ]
        if let contentType = content.contentType {
            object["contentType"] = contentType
        }
        return try encode(object)
    }

    public static func encodeFileOperationResult(
        operation: String,
        requestID: String,
        path: String,
        clientID: String
    ) throws -> String {
        try encode([
            "type": "fileOperationResult",
            "clientID": clientID,
            "operation": operation,
            "requestID": requestID,
            "path": path,
        ])
    }

    public static func decodeLine(_ line: String) throws -> RelayEndpointJSONLMessage {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayEndpointJSONLCodecError.invalidJSON
        }

        let type = try string("type", in: object)
        switch type {
        case "event":
            return .event(
                clientID: try string("clientID", in: object),
                try event(from: object)
            )
        case "writeStatus":
            return .writeStatus(
                clientID: try string("clientID", in: object),
                sessionID: try string("sessionID", in: object),
                writeID: try string("writeID", in: object),
                try writeStatus(try string("status", in: object), reason: object["reason"] as? String)
            )
        case "threadList":
            return .threadList(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                threads: try threads(from: object),
                nextCursor: object["nextCursor"] as? String
            )
        case "threadStarted":
            return .threadStarted(
                clientID: try string("clientID", in: object),
                requestID: try string("requestID", in: object),
                thread: try thread(from: object)
            )
        case "threadHistoryPage":
            return .threadHistoryPage(
                clientID: try string("clientID", in: object),
                RelayThreadHistoryPage(
                    requestID: try string("requestID", in: object),
                    threadID: try string("threadID", in: object),
                    items: try historyItems(from: object),
                    status: RelayThreadRunStatus(rawValue: try string("status", in: object)) ?? .completed,
                    nextCursor: object["nextCursor"] as? String
                )
            )
        case "fileContent":
            return .fileContent(
                clientID: try string("clientID", in: object),
                RelayRemoteFileContent(
                    requestID: try string("requestID", in: object),
                    path: try string("path", in: object),
                    contentType: object["contentType"] as? String,
                    byteCount: int("byteCount", in: object) ?? 0,
                    dataBase64: try string("dataBase64", in: object)
                )
            )
        case "fileOperationResult":
            return .fileOperationResult(
                clientID: try string("clientID", in: object),
                operation: try string("operation", in: object),
                requestID: try string("requestID", in: object),
                path: try string("path", in: object)
            )
        case "error":
            return .error(clientID: object["clientID"] as? String, reason: (object["reason"] as? String) ?? "")
        default:
            throw RelayEndpointJSONLCodecError.unsupportedType(type)
        }
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func threads(from object: [String: Any]) throws -> [RelayThreadSummarySnapshot] {
        guard let threadObjects = object["threads"] as? [[String: Any]] else {
            throw RelayEndpointJSONLCodecError.missingField("threads")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: threadObjects, options: [])
            return try JSONDecoder().decode([RelayThreadSummarySnapshot].self, from: data)
        } catch {
            throw RelayEndpointJSONLCodecError.invalidJSON
        }
    }

    private static func thread(from object: [String: Any]) throws -> RelayThreadSummarySnapshot {
        guard let threadObject = object["thread"] as? [String: Any] else {
            throw RelayEndpointJSONLCodecError.missingField("thread")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: threadObject, options: [])
            return try JSONDecoder().decode(RelayThreadSummarySnapshot.self, from: data)
        } catch {
            throw RelayEndpointJSONLCodecError.invalidJSON
        }
    }

    private static func event(from object: [String: Any]) throws -> RelayLiveSessionEvent {
        let event = try string("event", in: object)
        switch event {
        case "sessionStarted":
            return .sessionStarted(
                sessionID: try string("sessionID", in: object),
                threadID: try string("threadID", in: object),
                turnID: try string("turnID", in: object)
            )
        case "threadHistoryLoaded":
            return .threadHistoryLoaded(
                threadID: try string("threadID", in: object),
                items: try historyItems(from: object),
                status: RelayThreadRunStatus(rawValue: try string("status", in: object)) ?? .completed
            )
        case "assistantTextDelta":
            return .assistantTextDelta(
                turnID: try string("turnID", in: object),
                itemID: try string("itemID", in: object),
                text: try string("text", in: object)
            )
        case "userMessage":
            return .userMessage(
                turnID: try string("turnID", in: object),
                itemID: try string("itemID", in: object),
                text: try string("text", in: object)
            )
        case "commandOutputDelta":
            return .commandOutputDelta(
                turnID: try string("turnID", in: object),
                itemID: try string("itemID", in: object),
                text: try string("text", in: object)
            )
        case "fileChange":
            return .fileChange(
                turnID: try string("turnID", in: object),
                itemID: try string("itemID", in: object),
                path: try string("path", in: object),
                diff: try string("diff", in: object)
            )
        case "approvalRequested":
            return .approvalRequested(
                turnID: try string("turnID", in: object),
                requestID: try string("requestID", in: object),
                summary: try string("summary", in: object)
            )
        case "turnCompleted":
            return .turnCompleted(turnID: try string("turnID", in: object))
        case "turnFailed":
            return .turnFailed(
                turnID: try string("turnID", in: object),
                reason: try string("reason", in: object)
            )
        case "writeStatusChanged":
            return .writeStatusChanged(
                writeID: try string("writeID", in: object),
                status: try writeStatus(try string("status", in: object), reason: object["reason"] as? String)
            )
        case "streamClosed":
            return .streamClosed(
                sessionID: try string("sessionID", in: object),
                threadID: try string("threadID", in: object),
                errorCode: object["errorCode"] as? String
            )
        default:
            throw RelayEndpointJSONLCodecError.unsupportedType(event)
        }
    }

    private static func historyItems(from object: [String: Any]) throws -> [RelayThreadHistoryItem] {
        guard let itemObjects = object["items"] as? [[String: Any]] else {
            throw RelayEndpointJSONLCodecError.missingField("items")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: itemObjects, options: [])
            return try JSONDecoder().decode([RelayThreadHistoryItem].self, from: data)
        } catch {
            throw RelayEndpointJSONLCodecError.invalidJSON
        }
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw RelayEndpointJSONLCodecError.missingField(key)
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

    private static func writeStatus(_ value: String, reason: String? = nil) throws -> RelayWriteStatus {
        switch value {
        case "queued":
            return .queued
        case "running":
            return .running
        case "handled":
            return .handled
        case "failed":
            return .failed(reason: reason ?? "")
        default:
            throw RelayEndpointJSONLCodecError.unsupportedType(value)
        }
    }
}

private extension RelayLiveSessionEvent {
    var endpointObject: [String: Any] {
        switch self {
        case let .sessionStarted(sessionID, threadID, turnID):
            return [
                "event": "sessionStarted",
                "sessionID": sessionID,
                "threadID": threadID,
                "turnID": turnID,
            ]
        case let .threadHistoryLoaded(threadID, items, status):
            let data = (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
            let itemObjects = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            return [
                "event": "threadHistoryLoaded",
                "threadID": threadID,
                "items": itemObjects,
                "status": status.rawValue,
            ]
        case let .userMessage(turnID, itemID, text):
            return [
                "event": "userMessage",
                "turnID": turnID,
                "itemID": itemID,
                "text": text,
            ]
        case let .assistantTextDelta(turnID, itemID, text):
            return [
                "event": "assistantTextDelta",
                "turnID": turnID,
                "itemID": itemID,
                "text": text,
            ]
        case let .commandOutputDelta(turnID, itemID, text):
            return [
                "event": "commandOutputDelta",
                "turnID": turnID,
                "itemID": itemID,
                "text": text,
            ]
        case let .fileChange(turnID, itemID, path, diff):
            return [
                "event": "fileChange",
                "turnID": turnID,
                "itemID": itemID,
                "path": path,
                "diff": diff,
            ]
        case let .approvalRequested(turnID, requestID, summary):
            return [
                "event": "approvalRequested",
                "turnID": turnID,
                "requestID": requestID,
                "summary": summary,
            ]
        case let .turnCompleted(turnID):
            return [
                "event": "turnCompleted",
                "turnID": turnID,
            ]
        case let .turnFailed(turnID, reason):
            return [
                "event": "turnFailed",
                "turnID": turnID,
                "reason": reason,
            ]
        case let .writeStatusChanged(writeID, status):
            var object: [String: Any] = [
                "event": "writeStatusChanged",
                "writeID": writeID,
                "status": status.wireStatus,
            ]
            if case let .failed(reason) = status {
                object["reason"] = reason
            }
            return object
        case let .streamClosed(sessionID, threadID, errorCode):
            var object = [
                "event": "streamClosed",
                "sessionID": sessionID,
                "threadID": threadID,
            ]
            if let errorCode {
                object["errorCode"] = errorCode
            }
            return object
        }
    }

    var telemetryDescription: String {
        switch self {
        case let .sessionStarted(sessionID, threadID, turnID):
            return "sessionStarted session=\(sessionID) thread=\(threadID) turn=\(turnID)"
        case let .threadHistoryLoaded(threadID, items, status):
            return "threadHistoryLoaded thread=\(threadID) items=\(items.count) status=\(status.rawValue)"
        case let .userMessage(turnID, itemID, text):
            return "userMessage turn=\(turnID) item=\(itemID) textBytes=\(text.utf8.count)"
        case let .assistantTextDelta(turnID, itemID, text):
            return "assistantTextDelta turn=\(turnID) item=\(itemID) textBytes=\(text.utf8.count)"
        case let .commandOutputDelta(turnID, itemID, text):
            return "commandOutputDelta turn=\(turnID) item=\(itemID) textBytes=\(text.utf8.count)"
        case let .fileChange(turnID, itemID, path, diff):
            return "fileChange turn=\(turnID) item=\(itemID) path=\(path) diffBytes=\(diff.utf8.count)"
        case let .approvalRequested(turnID, requestID, summary):
            return "approvalRequested turn=\(turnID) request=\(requestID) summaryBytes=\(summary.utf8.count)"
        case let .turnCompleted(turnID):
            return "turnCompleted turn=\(turnID)"
        case let .turnFailed(turnID, reason):
            return "turnFailed turn=\(turnID) reasonBytes=\(reason.utf8.count)"
        case let .writeStatusChanged(writeID, status):
            return "writeStatusChanged write=\(writeID) status=\(status.wireStatus)"
        case let .streamClosed(sessionID, threadID, errorCode):
            return "streamClosed session=\(sessionID) thread=\(threadID) error=\(errorCode ?? "none")"
        }
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
