import Foundation
@testable import CodexPortCore

final class InMemoryCredentialVault: CredentialVault {
    private var secrets: [String: (secret: String, protection: CredentialProtection)] = [:]
    private var nextID = 1

    func saveSecret(_ secret: String, protection: CredentialProtection) throws -> String {
        let id = "credential-\(nextID)"
        nextID += 1
        secrets[id] = (secret, protection)
        return id
    }

    func deleteSecret(id: String) throws {
        secrets[id] = nil
    }

    func readSecret(id: String, authorization: CredentialAuthorization) throws -> String {
        guard let stored = secrets[id] else {
            throw CredentialVaultError.notFound
        }
        return stored.secret
    }

    func rawStoredSecret(id: String) -> String? {
        secrets[id]?.secret
    }
}

actor InMemoryJSONRPCTransport: JSONRPCTransport {
    private var outboundRequests: [JSONRPCOutboundRequest] = []
    private var outboundNotifications: [JSONRPCNotification] = []
    private var outboundResponses: [JSONRPCOutboundResponse] = []
    private var inbound: [JSONRPCInboundMessage] = []

    func sendRequest(_ request: JSONRPCOutboundRequest) async throws {
        outboundRequests.append(request)
    }

    func sendNotification(_ notification: JSONRPCNotification) async throws {
        outboundNotifications.append(notification)
    }

    func sendResponse(_ response: JSONRPCOutboundResponse) async throws {
        outboundResponses.append(response)
    }

    func receive() async throws -> JSONRPCInboundMessage {
        while inbound.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return inbound.removeFirst()
    }

    func deliver(_ message: JSONRPCInboundMessage) async throws {
        inbound.append(message)
    }

    func nextOutbound() async throws -> JSONRPCOutboundRequest {
        while outboundRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return outboundRequests.removeFirst()
    }

    func nextOutboundResponse() async throws -> JSONRPCOutboundResponse {
        while outboundResponses.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return outboundResponses.removeFirst()
    }

    func nextOutboundNotification() async throws -> JSONRPCNotification {
        while outboundNotifications.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return outboundNotifications.removeFirst()
    }
}

final class RecordingCodexTransport: CodexTransport, @unchecked Sendable {
    struct Request: Equatable {
        var method: String
        var params: JSONValue
        var timeoutSeconds: Double?
    }

    private(set) var requests: [Request] = []
    var stubbedResponses: [String: JSONValue] = [:]
    var error: Error?
    var methods: [String] { requests.map(\.method) }

    func request(method: String, params: JSONValue, timeoutSeconds: Double? = nil) async throws -> JSONValue {
        if let error {
            throw error
        }
        requests.append(Request(method: method, params: params, timeoutSeconds: timeoutSeconds))
        if let response = stubbedResponses[method] {
            return response
        }
        switch method {
        case "thread/start":
            return .object(["threadId": .string("thread-started")])
        case "turn/start":
            return .object(["turnId": .string("turn-started")])
        case "turn/steer":
            return .object(["turnId": params.object?["expectedTurnId"] ?? .string("turn-steered")])
        default:
            return .object([:])
        }
    }
}

final class JSONRPCClientCodexTransport: CodexTransport, @unchecked Sendable {
    private let client: JSONRPCClient

    init(client: JSONRPCClient) {
        self.client = client
    }

    func request(method: String, params: JSONValue, timeoutSeconds: Double?) async throws -> JSONValue {
        try await client.request(method: method, params: params, timeoutSeconds: timeoutSeconds)
    }
}

class FakeCodexProtocol: CodexProtocolClient, ThreadDetailProviding, @unchecked Sendable {
    var directoryListings: [String: [RemoteDirectoryEntry]] = [:]
    var metadata: [String: RemoteMetadata] = [:]
    var createdDirectories: [CreatedDirectory] = []
    var writtenFiles: [(path: String, dataBase64: String)] = []
    var startedThreadID = "thread-started"
    var startedThreadCWD: String?
    var startedThreadModel: CodexModel?
    var thread: ThreadDetail?
    var resumeThreadResponse: JSONValue?
    var pagedTurnResponses: [JSONValue] = []
    var calls: [String] = []
    var interrupted: InterruptRequest?
    var lastTurnStart: TurnStartRecord?
    var lastTurnSteer: TurnSteerRecord?

    func readThread(id: String, includeTurns: Bool) async throws -> JSONValue {
        calls.append("thread/read(includeTurns:\(includeTurns))")
        return .object([:])
    }

    func resumeThread(id: String) async throws -> JSONValue {
        calls.append("thread/resume")
        return resumeThreadResponse ?? .object(["threadId": .string(id)])
    }

    func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue {
        calls.append("thread/resume(initialTurnLimit:\(initialTurnLimit))")
        return resumeThreadResponse ?? .object(["threadId": .string(id)])
    }

    func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue {
        calls.append("thread/resume(initialTurnLimit:\(initialTurnLimit),timeout:\(timeoutDescription(timeoutSeconds)))")
        return resumeThreadResponse ?? .object(["threadId": .string(id)])
    }

    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String) async throws -> JSONValue {
        calls.append("thread/turns/list(cursor:\(cursor ?? "nil"),limit:\(limit),sort:\(sortDirection),items:\(itemsView))")
        if pagedTurnResponses.isEmpty {
            return .object(["data": .array([]), "nextCursor": .null])
        }
        return pagedTurnResponses.removeFirst()
    }

    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String, timeoutSeconds: Double?) async throws -> JSONValue {
        calls.append("thread/turns/list(cursor:\(cursor ?? "nil"),limit:\(limit),sort:\(sortDirection),items:\(itemsView),timeout:\(timeoutDescription(timeoutSeconds)))")
        if pagedTurnResponses.isEmpty {
            return .object(["data": .array([]), "nextCursor": .null])
        }
        return pagedTurnResponses.removeFirst()
    }

    func startThread(cwd: String, model: CodexModel) async throws -> String {
        startedThreadCWD = cwd
        startedThreadModel = model
        calls.append("thread/start")
        return startedThreadID
    }

    func startTurn(threadID: String, prompt: String, attachments: [TurnAttachment], model: CodexModel, reasoningEffort: ReasoningEffort, permissionMode: PermissionMode, collaborationMode: CollaborationMode) async throws -> JSONValue {
        calls.append("turn/start")
        lastTurnStart = TurnStartRecord(
            threadID: threadID,
            prompt: prompt,
            attachments: attachments,
            model: model,
            reasoningEffort: reasoningEffort,
            permissionMode: permissionMode,
            collaborationMode: collaborationMode
        )
        return .object(["turnId": .string("turn-started")])
    }

    func steerTurn(threadID: String, turnID: String, prompt: String, attachments: [TurnAttachment]) async throws -> JSONValue {
        calls.append("turn/steer")
        lastTurnSteer = TurnSteerRecord(
            threadID: threadID,
            turnID: turnID,
            prompt: prompt,
            attachments: attachments
        )
        return .object(["turnId": .string(turnID)])
    }

    func interruptTurn(threadID: String, turnID: String) async throws -> JSONValue {
        interrupted = InterruptRequest(threadID: threadID, turnID: turnID)
        return .object([:])
    }

    func unsubscribeThread(id: String) async throws -> JSONValue {
        calls.append("thread/unsubscribe")
        return .object(["status": .string("unsubscribed")])
    }

    func readDirectory(path: String) async throws -> [RemoteDirectoryEntry] {
        directoryListings[path] ?? []
    }

    func getMetadata(path: String) async throws -> RemoteMetadata {
        metadata[path] ?? RemoteMetadata(path: path, kind: .missing)
    }

    func createDirectory(path: String, recursive: Bool) async throws {
        calls.append("fs/createDirectory")
        createdDirectories.append(CreatedDirectory(path: path, recursive: recursive))
    }

    func writeFile(path: String, dataBase64: String) async throws {
        calls.append("fs/writeFile")
        writtenFiles.append((path, dataBase64))
    }
}

struct CreatedDirectory: Equatable {
    var path: String
    var recursive: Bool
}

struct InterruptRequest: Equatable {
    var threadID: String
    var turnID: String
}

struct TurnStartRecord: Equatable {
    var threadID: String
    var prompt: String
    var attachments: [TurnAttachment]
    var model: CodexModel
    var reasoningEffort: ReasoningEffort
    var permissionMode: PermissionMode
    var collaborationMode: CollaborationMode
}

struct TurnSteerRecord: Equatable {
    var threadID: String
    var turnID: String
    var prompt: String
    var attachments: [TurnAttachment]
}

final class LegacyResumeOnlyCodexProtocol: FakeCodexProtocol, @unchecked Sendable {
    override func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue {
        calls.append("thread/resume(initialTurnLimit:\(initialTurnLimit))")
        throw JSONRPCError.remote(code: -32602, message: "unknown field initialTurnsPage")
    }

    override func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue {
        calls.append("thread/resume(initialTurnLimit:\(initialTurnLimit),timeout:\(timeoutDescription(timeoutSeconds)))")
        throw JSONRPCError.remote(code: -32602, message: "unknown field initialTurnsPage")
    }
}

private func timeoutDescription(_ timeoutSeconds: Double?) -> String {
    timeoutSeconds.map { "\($0)" } ?? "nil"
}

final class FakeSSHDriver: SSHDriver, @unchecked Sendable {
    var presentedFingerprint = "SHA256:test"
    var stream = SSHByteStream(stdin: AsyncBytesWriter(), stdout: AsyncBytesReader())
    var error: SSHConnectionError?
    var shouldHangHostKey = false
    var shouldHangCommand = false
    var lastConnection: SSHConnectionRequest?
    var commandResults: [String: SSHCommandResult] = [:]
    var commandErrors: [String: SSHConnectionError] = [:]
    var commands: [String] = []
    var presentedHostKeyCredentials: [SSHCredential] = []

    func presentedHostKeyFingerprint(host: String, port: Int, username: String, credential: SSHCredential) async throws -> String {
        presentedHostKeyCredentials.append(credential)
        if shouldHangHostKey {
            try? await Task.sleep(for: .seconds(60))
        }
        return presentedFingerprint
    }

    func connect(_ request: SSHConnectionRequest) async throws -> SSHByteStream {
        if let error {
            throw error
        }
        lastConnection = request
        return stream
    }

    func runCommand(_ request: SSHConnectionRequest) async throws -> SSHCommandResult {
        commands.append(request.command)
        lastConnection = request
        if shouldHangCommand {
            try? await Task.sleep(for: .seconds(60))
        }
        if let error = commandErrors[request.command] {
            throw error
        }
        return commandResults[request.command] ?? SSHCommandResult(stdout: Data(), stderr: Data(), exitStatus: 0)
    }
}
