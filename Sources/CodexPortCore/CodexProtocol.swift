import Foundation

public protocol CodexTransport: AnyObject, Sendable {
    func request(method: String, params: JSONValue) async throws -> JSONValue
}

public enum TurnAttachment: Equatable, Sendable {
    case localImage(path: String, detail: String?)
    case remoteFile(path: String)
}

public enum CollaborationMode: Equatable, Sendable {
    case `default`
    case plan

    public var json: JSONValue {
        switch self {
        case .default:
            return .object(["mode": .string("default"), "settings": .object([:])])
        case .plan:
            return .object(["mode": .string("plan"), "settings": .object([:])])
        }
    }
}

public enum PermissionMode: Equatable, Hashable, CaseIterable, Sendable {
    case remoteDefault
    case autoReview
    case fullAccess
    case customConfigToml

    public func turnOverrides() -> [String: JSONValue] {
        switch self {
        case .remoteDefault:
            return [:]
        case .autoReview:
            return ["approvalsReviewer": .string("auto_review")]
        case .fullAccess:
            return [
                "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
                "approvalPolicy": .string("never")
            ]
        case .customConfigToml:
            return ["useConfiguredPermissions": .bool(true)]
        }
    }
}

public final class CodexProtocolFacade: CodexProtocolClient {
    private let transport: CodexTransport

    public static let clientVersion = "0.1.0"

    public init(transport: CodexTransport) {
        self.transport = transport
    }

    @discardableResult
    public func initialize(clientName: String, suppressNotifications: [String]) async throws -> JSONValue {
        try await transport.request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string(clientName),
                    "title": .null,
                    "version": .string(Self.clientVersion)
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                    "requestAttestation": .bool(false),
                    "optOutNotificationMethods": .array(suppressNotifications.map(JSONValue.string))
                ])
            ])
        )
    }

    @discardableResult
    public func listThreads(limit: Int) async throws -> JSONValue {
        try await transport.request(method: "thread/list", params: .object(["limit": .number(Double(limit))]))
    }

    @discardableResult
    public func readThread(id: String, includeTurns: Bool) async throws -> JSONValue {
        try await transport.request(method: "thread/read", params: .object(["threadId": .string(id), "includeTurns": .bool(includeTurns)]))
    }

    @discardableResult
    public func resumeThread(id: String) async throws -> JSONValue {
        try await transport.request(method: "thread/resume", params: .object(["threadId": .string(id)]))
    }

    @discardableResult
    public func startThread(cwd: String) async throws -> String {
        let response = try await transport.request(method: "thread/start", params: .object(["cwd": .string(cwd)]))
        let thread = response.object?["thread"]?.object
        return thread?["id"]?.string ?? thread?["sessionId"]?.string ?? response.object?["threadId"]?.string ?? response.object?["id"]?.string ?? ""
    }

    @discardableResult
    public func startTurn(
        threadID: String,
        prompt: String,
        attachments: [TurnAttachment] = [],
        permissionMode: PermissionMode = .remoteDefault,
        collaborationMode: CollaborationMode = .default
    ) async throws -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(inputItems(prompt: prompt, attachments: attachments))
        ]
        if collaborationMode != .default {
            params["collaborationMode"] = collaborationMode.json
        }
        for (key, value) in permissionMode.turnOverrides() {
            params[key] = value
        }
        return try await transport.request(method: "turn/start", params: .object(params))
    }

    @discardableResult
    public func steerTurn(threadID: String, turnID: String, prompt: String, attachments: [TurnAttachment] = []) async throws -> JSONValue {
        try await transport.request(
            method: "turn/steer",
            params: .object([
                "threadId": .string(threadID),
                "input": .array(inputItems(prompt: prompt, attachments: attachments)),
                "expectedTurnId": .string(turnID)
            ])
        )
    }

    @discardableResult
    public func interruptTurn(threadID: String, turnID: String) async throws -> JSONValue {
        try await transport.request(method: "turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    }

    @discardableResult
    public func unsubscribeThread(id: String) async throws -> JSONValue {
        try await transport.request(method: "thread/unsubscribe", params: .object(["threadId": .string(id)]))
    }

    public func readDirectory(path: String) async throws -> [RemoteDirectoryEntry] {
        let response = try await transport.request(method: "fs/readDirectory", params: .object(["path": .string(path)]))
        return response.object?["entries"]?.array?.compactMap(RemoteDirectoryEntry.init(json:)) ?? []
    }

    public func getMetadata(path: String) async throws -> RemoteMetadata {
        let response = try await transport.request(method: "fs/getMetadata", params: .object(["path": .string(path)]))
        var object = response.object ?? [:]
        if object["path"] == nil {
            object["path"] = .string(path)
        }
        return RemoteMetadata(json: .object(object)) ?? RemoteMetadata(path: path, kind: .missing)
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        _ = try await transport.request(method: "fs/createDirectory", params: .object(["path": .string(path), "recursive": .bool(recursive)]))
    }

    public func writeFile(path: String, dataBase64: String) async throws {
        _ = try await transport.request(method: "fs/writeFile", params: .object(["path": .string(path), "dataBase64": .string(dataBase64)]))
    }

    private func inputItems(prompt: String, attachments: [TurnAttachment]) -> [JSONValue] {
        var items: [JSONValue] = []
        if !prompt.isEmpty {
            items.append(textInput(prompt))
        }
        for attachment in attachments {
            switch attachment {
            case let .localImage(path, detail):
                var image: [String: JSONValue] = ["type": .string("localImage"), "path": .string(path)]
                if let detail {
                    image["detail"] = .string(detail)
                }
                items.append(.object(image))
            case let .remoteFile(path):
                items.append(textInput("Uploaded file: \(path)"))
            }
        }
        return items
    }

    private func textInput(_ text: String) -> JSONValue {
        .object([
            "type": .string("text"),
            "text": .string(text),
            "text_elements": .array([])
        ])
    }
}

extension CodexProtocolFacade: @unchecked Sendable {}
