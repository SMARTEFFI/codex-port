import Foundation
import Testing
@testable import CodexPortCore

@Test func appServerSessionConnectsOverSSHStreamAndInitializesCodexProtocol() async throws {
    let stdout = AsyncBytesReader(chunks: [
        Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"0.1.0"}}"#.utf8 + Data([0x0A]))
    ])
    let stdin = AsyncBytesWriter()
    let driver = FakeSSHDriver()
    driver.stream = SSHByteStream(stdin: stdin, stdout: stdout)
    let shell = AppServerShellCommand(codexPath: "/usr/local/bin/codex")
    driver.commandResults = [
        shell.versionCommand: SSHCommandResult(stdout: Data("codex-cli 0.133.0\n".utf8), exitStatus: 0),
        shell.appServerHelpCommand: SSHCommandResult(stdout: Data("Usage: codex app-server\n".utf8), exitStatus: 0),
    ]

    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "codex",
        auth: .password(credentialID: "credential-1"),
        codexPath: "/usr/local/bin/codex",
        startupCommand: "legacy daemon start && proxy command",
        defaultDirectory: "/home/codex",
        knownHostFingerprint: nil
    )
    let service = AppServerSessionConnector(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
        codec: JSONRPCCodec()
    )

    let session = try await service.connect(
        profile: profile,
        credential: .password("secret"),
        unknownHostDecision: .confirmUnknownHost,
        clientName: "Codex Port"
    )

    #expect(session.connection.state == .connected)
    #expect(driver.commands == [
        shell.versionCommand,
        shell.appServerHelpCommand,
    ])
    #expect(driver.lastConnection?.command == shell.appServerCommand)
    #expect(driver.lastConnection?.command != profile.startupCommand)
    let outbound = try #require(String(data: await stdin.joinedWrittenData(), encoding: .utf8))
    let outboundLines = outbound.split(separator: "\n").map(String.init)
    let initializeData = try #require(outboundLines[0].data(using: .utf8))
    let initialize = try #require(try JSONSerialization.jsonObject(with: initializeData) as? [String: Any])
    let initializeParams = try #require(initialize["params"] as? [String: Any])
    let clientInfo = try #require(initializeParams["clientInfo"] as? [String: Any])
    let capabilities = try #require(initializeParams["capabilities"] as? [String: Any])
    #expect(initialize["method"] as? String == "initialize")
    #expect(clientInfo["name"] as? String == "Codex Port")
    #expect(clientInfo["version"] as? String == "0.1.0")
    #expect(clientInfo["title"] is NSNull)
    #expect(capabilities["experimentalApi"] as? Bool == true)
    #expect(capabilities["requestAttestation"] as? Bool == false)
    #expect((capabilities["optOutNotificationMethods"] as? [Any])?.isEmpty == true)
    let initializedData = try #require(outboundLines[1].data(using: .utf8))
    let initialized = try #require(try JSONSerialization.jsonObject(with: initializedData) as? [String: Any])
    #expect(initialized["method"] as? String == "initialized")
}

@Test func appServerSessionBlocksUnsupportedCodexBeforeProxyHandshake() async {
    let driver = FakeSSHDriver()
    let shell = AppServerShellCommand(codexPath: "codex")
    driver.commandResults = [
        shell.versionCommand: SSHCommandResult(stdout: Data("codex-cli 0.132.9\n".utf8), exitStatus: 0)
    ]
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "codex",
        auth: .password(credentialID: "credential-1"),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "/home/codex",
        knownHostFingerprint: nil
    )
    let service = AppServerSessionConnector(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
        codec: JSONRPCCodec()
    )

    await #expect(throws: AppServerPreflightError.unsupportedCodexVersion(.tooOld(required: "0.133.0", actual: "codex-cli 0.132.9\n"))) {
        _ = try await service.connect(
            profile: profile,
            credential: .password("secret"),
            unknownHostDecision: .confirmUnknownHost,
            clientName: "Codex Port"
        )
    }
    #expect(driver.lastConnection?.command != profile.startupCommand)
}

@Test func approvalResponderSendsJSONRPCResponseForServerApprovalRequest() async throws {
    let transport = InMemoryJSONRPCTransport()
    let client = JSONRPCClient(transport: transport)
    let responder = ApprovalResponder(jsonRPCClient: client)

    _ = Task {
        try? await client.request(method: "thread/list", params: .object([:]))
    }
    _ = try await transport.nextOutbound()
    try await transport.deliver(.request(
        id: .string("approval-1"),
        method: "item/commandExecution/requestApproval",
        params: .object([
            "command": .array([.string("git"), .string("status")]),
            "cwd": .string("/repo")
        ])
    ))

    let request = try await responder.nextApprovalRequest()
    try await responder.respond(to: request, action: .acceptForSession)

    let response = try await transport.nextOutboundResponse()
    #expect(response.id == .string("approval-1"))
    #expect(response.result == .object(["decision": .string("approved_for_session")]))
}

@Test func codexHostConnectorResolvesCredentialAndStartsInitializedAppServerSession() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = try vault.saveSecret("secret", protection: .localEncrypted)
    let stdout = AsyncBytesReader(chunks: [
        Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"0.1.0"}}"#.utf8 + Data([0x0A]))
    ])
    let stdin = AsyncBytesWriter()
    let driver = FakeSSHDriver()
    driver.stream = SSHByteStream(stdin: stdin, stdout: stdout)
    let shell = AppServerShellCommand(codexPath: "codex")
    driver.commandResults = [
        shell.versionCommand: SSHCommandResult(stdout: Data("codex-cli 0.133.0\n".utf8), exitStatus: 0),
        shell.appServerHelpCommand: SSHCommandResult(stdout: Data("Usage: codex app-server\n".utf8), exitStatus: 0),
    ]
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "codex",
        auth: .password(credentialID: credentialID),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let connector = CodexHostConnector(
        credentialResolver: HostCredentialResolver(vault: vault),
        appServer: AppServerSessionConnector(
            ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
            codec: JSONRPCCodec()
        )
    )

    let session = try await connector.connect(
        profile: profile,
        credentialAuthorization: .granted,
        unknownHostDecision: .confirmUnknownHost
    )

    #expect(session.connection.state == .connected)
    #expect(driver.lastConnection?.credential == .password("secret"))
}

@Test func appServerSessionSurfacesRawInvalidProxyOutputDuringInitialize() async {
    let stdout = AsyncBytesReader(chunks: [
        Data("daemon already running\n".utf8)
    ])
    let driver = FakeSSHDriver()
    driver.stream = SSHByteStream(stdin: AsyncBytesWriter(), stdout: stdout)
    let shell = AppServerShellCommand(codexPath: "codex")
    driver.commandResults = [
        shell.versionCommand: SSHCommandResult(stdout: Data("codex-cli 0.133.0\n".utf8), exitStatus: 0),
        shell.appServerHelpCommand: SSHCommandResult(stdout: Data("Usage: codex app-server\n".utf8), exitStatus: 0),
    ]
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "codex",
        auth: .password(credentialID: "credential-1"),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let service = AppServerSessionConnector(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
        codec: JSONRPCCodec()
    )

    await #expect(throws: JSONRPCCodecError.invalidMessage("daemon already running")) {
        _ = try await service.connect(
            profile: profile,
            credential: .password("secret"),
            unknownHostDecision: .confirmUnknownHost,
            clientName: "Codex Port"
        )
    }
    #expect(driver.lastConnection?.command == shell.appServerCommand)
}

@Test func appServerSessionTimesOutWhenInitializeResponseNeverArrives() async {
    let stdout = AsyncBytesReader(chunks: [], isFinished: false)
    let driver = FakeSSHDriver()
    driver.stream = SSHByteStream(stdin: AsyncBytesWriter(), stdout: stdout)
    let shell = AppServerShellCommand(codexPath: "codex")
    driver.commandResults = [
        shell.versionCommand: SSHCommandResult(stdout: Data("codex-cli 0.133.0\n".utf8), exitStatus: 0),
        shell.appServerHelpCommand: SSHCommandResult(stdout: Data("Usage: codex app-server\n".utf8), exitStatus: 0),
    ]
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "codex",
        auth: .password(credentialID: "credential-1"),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let service = AppServerSessionConnector(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
        codec: JSONRPCCodec(),
        observer: AppServerConnectionObserver(),
        initializeTimeoutSeconds: 0.05
    )

    await #expect(throws: JSONRPCError.requestTimedOut(method: "initialize", seconds: 0.05)) {
        _ = try await service.connect(
            profile: profile,
            credential: .password("secret"),
            unknownHostDecision: .confirmUnknownHost,
            clientName: "Codex Port"
        )
    }
}
