import Foundation

public struct AppServerSession {
    public var connection: SSHConnection
    public var protocolClient: CodexProtocolFacade
    public var events: AppServerEventSource?

    public init(connection: SSHConnection, protocolClient: CodexProtocolFacade, events: AppServerEventSource? = nil) {
        self.connection = connection
        self.protocolClient = protocolClient
        self.events = events
    }
}

public protocol AppServerEventSource: AnyObject, Sendable {
    func nextNotification() async -> JSONRPCNotification?
    func nextServerRequest() async -> JSONRPCServerRequest?
    func respond(to id: JSONRPCID, result: JSONValue) async throws
}

public enum AppServerPreflightError: Error, Equatable {
    case unsupportedCodexVersion(CodexVersionCompatibility)
    case codexVersionCommandFailed(String)
    case proxyHelpUnavailable(String)
    case daemonStartFailed(String)
}

public struct AppServerConnectionObserver: Sendable {
    public var log: @Sendable (String) async -> Void

    public init(log: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.log = log
    }
}

public final class AppServerSessionConnector {
    private let ssh: SSHConnectionService
    private let codec: JSONRPCCodec
    private let observer: AppServerConnectionObserver

    public init(
        ssh: SSHConnectionService,
        codec: JSONRPCCodec = JSONRPCCodec(),
        observer: AppServerConnectionObserver = AppServerConnectionObserver()
    ) {
        self.ssh = ssh
        self.codec = codec
        self.observer = observer
    }

    public func connect(
        profile: HostProfile,
        credential: SSHCredential,
        unknownHostDecision: UnknownHostDecision,
        clientName: String
    ) async throws -> AppServerSession {
        let shell = AppServerShellCommand(codexPath: profile.codexPath)
        await observer.log("获取并校验远端 Host Key。")
        try await runPreflight(profile: profile, credential: credential, unknownHostDecision: unknownHostDecision)
        await observer.log("打开 app-server 共享 control socket bridge。")
        let connection = try await ssh.connect(
            profile: profile,
            credential: credential,
            decision: unknownHostDecision,
            commandOverride: shell.appServerCommand
        )
        let jsonRPC = JSONRPCClient(
            transport: JSONRPCByteStreamTransport(stream: connection.stream, codec: codec)
        )
        let facade = CodexProtocolFacade(transport: JSONRPCCodexTransport(client: jsonRPC))
        await observer.log("发送 initialize 握手。")
        _ = try await facade.initialize(clientName: clientName, suppressNotifications: [])
        try await jsonRPC.sendNotification(method: "initialized")
        return AppServerSession(connection: connection, protocolClient: facade, events: jsonRPC)
    }

    private func runPreflight(profile: HostProfile, credential: SSHCredential, unknownHostDecision: UnknownHostDecision) async throws {
        let shell = AppServerShellCommand(codexPath: profile.codexPath)
        await observer.log("检查远端 Codex 版本：\(profile.codexPath) --version")
        let version = try await ssh.runCommand(
            profile: profile,
            credential: credential,
            decision: unknownHostDecision,
            command: shell.versionCommand
        )
        guard version.exitStatus == 0 else {
            throw AppServerPreflightError.codexVersionCommandFailed(version.stderrString + version.stdoutString)
        }
        switch CodexVersionCompatibility.evaluate(version.stdoutString) {
        case .supported, .untestedNewer:
            break
        case let .tooOld(required, actual):
            throw AppServerPreflightError.unsupportedCodexVersion(.tooOld(required: required, actual: actual))
        }

        await observer.log("检查 app-server 是否可用。")
        let appServerHelp = try await ssh.runCommand(
            profile: profile,
            credential: credential,
            decision: unknownHostDecision,
            command: shell.appServerHelpCommand
        )
        guard appServerHelp.exitStatus == 0 else {
            throw AppServerPreflightError.proxyHelpUnavailable(appServerHelp.stderrString + appServerHelp.stdoutString)
        }
    }
}

extension AppServerSessionConnector: @unchecked Sendable {}

public final class CodexHostConnector {
    private let credentialResolver: HostCredentialResolver
    private let appServer: AppServerSessionConnector
    private let clientName: String

    public init(
        credentialResolver: HostCredentialResolver,
        appServer: AppServerSessionConnector,
        clientName: String = "Codex Port"
    ) {
        self.credentialResolver = credentialResolver
        self.appServer = appServer
        self.clientName = clientName
    }

    public func connect(
        profile: HostProfile,
        credentialAuthorization: CredentialAuthorization,
        unknownHostDecision: UnknownHostDecision
    ) async throws -> AppServerSession {
        let credential = try credentialResolver.resolve(profile, authorization: credentialAuthorization)
        return try await appServer.connect(
            profile: profile,
            credential: credential,
            unknownHostDecision: unknownHostDecision,
            clientName: clientName
        )
    }
}

extension CodexHostConnector: @unchecked Sendable {}

private final class JSONRPCCodexTransport: CodexTransport, @unchecked Sendable {
    private let client: JSONRPCClient

    init(client: JSONRPCClient) {
        self.client = client
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await client.request(method: method, params: params)
    }
}

private final class JSONRPCByteStreamTransport: JSONRPCTransport, @unchecked Sendable {
    private let stream: SSHByteStream
    private let codec: JSONRPCCodec
    private var framer: JSONRPCFramer
    private var queuedMessages: [JSONRPCInboundMessage] = []

    init(stream: SSHByteStream, codec: JSONRPCCodec) {
        self.stream = stream
        self.codec = codec
        self.framer = JSONRPCFramer(codec: codec)
    }

    func sendRequest(_ request: JSONRPCOutboundRequest) async throws {
        let encoded = try codec.encodeRequest(request)
        try await stream.stdin.write(lineDelimited(encoded))
    }

    func sendNotification(_ notification: JSONRPCNotification) async throws {
        let encoded = try codec.encodeNotification(notification)
        try await stream.stdin.write(lineDelimited(encoded))
    }

    func sendResponse(_ response: JSONRPCOutboundResponse) async throws {
        let encoded = try codec.encodeResponse(response)
        try await stream.stdin.write(lineDelimited(encoded))
    }

    func receive() async throws -> JSONRPCInboundMessage {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        guard let data = await stream.stdout.read() else {
            throw JSONRPCError.connectionClosed
        }
        queuedMessages.append(contentsOf: try framer.receive(data))
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        return try await receive()
    }

    private func lineDelimited(_ data: Data) -> Data {
        var output = data
        output.append(0x0A)
        return output
    }
}
