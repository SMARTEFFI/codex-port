import Foundation

public enum RelayLiveSessionEvent: Equatable, Sendable {
    case sessionStarted(sessionID: String, threadID: String, turnID: String)
    case threadHistoryLoaded(threadID: String, items: [RelayThreadHistoryItem], status: RelayThreadRunStatus)
    case userMessage(turnID: String, itemID: String, text: String)
    case assistantTextDelta(turnID: String, itemID: String, text: String)
    case commandOutputDelta(turnID: String, itemID: String, text: String)
    case fileChange(turnID: String, itemID: String, path: String, diff: String)
    case approvalRequested(turnID: String, requestID: String, summary: String)
    case turnCompleted(turnID: String)
    case turnFailed(turnID: String, reason: String)
    case writeStatusChanged(writeID: String, status: RelayWriteStatus)
    case streamClosed(sessionID: String, threadID: String, errorCode: String?)

    public var sealedPayloadForRelayTelemetry: RelaySealedPayload {
        RelaySealedPayload(ciphertext: Data(debugWireDescription.utf8))
    }

    private var debugWireDescription: String {
        switch self {
        case let .sessionStarted(sessionID, threadID, turnID):
            "sessionStarted session=\(sessionID) thread=\(threadID) turn=\(turnID)"
        case let .threadHistoryLoaded(threadID, items, status):
            "threadHistoryLoaded thread=\(threadID) items=\(items.count) status=\(status.rawValue)"
        case let .userMessage(turnID, itemID, text):
            "userMessage turn=\(turnID) item=\(itemID) bytes=\(text.utf8.count)"
        case let .assistantTextDelta(turnID, itemID, text):
            "assistantTextDelta turn=\(turnID) item=\(itemID) bytes=\(text.utf8.count)"
        case let .commandOutputDelta(turnID, itemID, text):
            "commandOutputDelta turn=\(turnID) item=\(itemID) bytes=\(text.utf8.count)"
        case let .fileChange(turnID, itemID, path, diff):
            "fileChange turn=\(turnID) item=\(itemID) path=\(path) bytes=\(diff.utf8.count)"
        case let .approvalRequested(turnID, requestID, summary):
            "approvalRequested turn=\(turnID) request=\(requestID) summaryBytes=\(summary.utf8.count)"
        case let .turnCompleted(turnID):
            "turnCompleted turn=\(turnID)"
        case let .turnFailed(turnID, reason):
            "turnFailed turn=\(turnID) reasonBytes=\(reason.utf8.count)"
        case let .writeStatusChanged(writeID, status):
            "writeStatusChanged write=\(writeID) status=\(status.debugWireDescription)"
        case let .streamClosed(sessionID, threadID, errorCode):
            "streamClosed session=\(sessionID) thread=\(threadID) error=\(errorCode ?? "none")"
        }
    }
}

public enum TurnAttachment: Equatable, Sendable {
    case localImage(path: String, detail: String?)
    case remoteFile(path: String)
}

public enum RelayThreadRunStatus: String, Codable, Equatable, Sendable {
    case running
    case interrupting
    case completed
    case failed
}

public enum RelayThreadHistoryItem: Codable, Equatable, Sendable {
    case userMessage(String)
    case structuredUserMessage(text: String, imagePaths: [String])
    case assistantMessage(String)
    case commandOutput(String)
    case fileChange(path: String, diff: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imagePaths
        case path
        case diff
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "userMessage":
            let text = try container.decode(String.self, forKey: .text)
            let imagePaths = try container.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
            if imagePaths.isEmpty {
                self = .userMessage(text)
            } else {
                self = .structuredUserMessage(text: text, imagePaths: imagePaths)
            }
        case "assistantMessage":
            self = .assistantMessage(try container.decode(String.self, forKey: .text))
        case "commandOutput":
            self = .commandOutput(try container.decode(String.self, forKey: .text))
        case "fileChange":
            self = .fileChange(
                path: try container.decode(String.self, forKey: .path),
                diff: try container.decode(String.self, forKey: .diff)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported RelayThreadHistoryItem type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .userMessage(text):
            try container.encode("userMessage", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .structuredUserMessage(text, imagePaths):
            try container.encode("userMessage", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(imagePaths, forKey: .imagePaths)
        case let .assistantMessage(text):
            try container.encode("assistantMessage", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .commandOutput(text):
            try container.encode("commandOutput", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .fileChange(path, diff):
            try container.encode("fileChange", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(diff, forKey: .diff)
        }
    }
}

public enum RelayApprovalAction: Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel

    public var wireValue: String {
        switch self {
        case .accept:
            "accept"
        case .acceptForSession:
            "accept-for-session"
        case .decline:
            "decline"
        case .cancel:
            "cancel"
        }
    }
}

public enum RelayLiveSessionWrite: Equatable, Sendable {
    case prompt(writeID: String, threadID: String, text: String, attachments: [TurnAttachment] = [])
    case interrupt(writeID: String, threadID: String, turnID: String)
    case approval(writeID: String, requestID: String, action: RelayApprovalAction)

    public var writeID: String {
        switch self {
        case let .prompt(writeID, _, _, _), let .interrupt(writeID, _, _), let .approval(writeID, _, _):
            writeID
        }
    }
}

public enum RelayWriteStatus: Equatable, Sendable {
    case queued
    case running
    case handled
    case failed(reason: String)

    public var isAccepted: Bool {
        switch self {
        case .queued, .running, .handled:
            true
        case .failed:
            false
        }
    }

    var debugWireDescription: String {
        switch self {
        case .queued:
            "queued"
        case .running:
            "running"
        case .handled:
            "handled"
        case let .failed(reason):
            "failed reasonBytes=\(reason.utf8.count)"
        }
    }
}
