import Foundation
import Testing
@testable import CodexPortHostAgentCore

@Test func hostAgentCommandLineDefaultsToManifestMode() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent"],
        environment: [:]
    )

    #expect(configuration.mode == .manifest)
}

@Test func hostAgentCommandLineParsesListIdleThreadsJSONModeWithoutRelayConfiguration() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--list-idle-threads-json", "--limit", "12"],
        environment: [:]
    )

    #expect(configuration.mode == .listIdleThreadsJSON(limit: 12))
    #expect(configuration.relayConfiguration == nil)
}

@Test func hostAgentCodexCommandResolverUsesExplicitCommandAndSearchesPathForDefaultCodex() throws {
    let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codexport-command-resolver-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    let codex = temporaryDirectory.appendingPathComponent("codex")
    try "#!/bin/sh\n".write(to: codex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

    #expect(HostAgentCodexCommandResolver.executablePath(
        explicitCommand: "/bin/sh",
        environment: ["PATH": temporaryDirectory.path]
    ) == "/bin/sh")
    #expect(HostAgentCodexCommandResolver.executablePath(
        explicitCommand: nil,
        environment: ["PATH": temporaryDirectory.path]
    ) == codex.path)
}

@Test func hostAgentCommandLineParsesLocalRelayJSONLModeWithFixtureCommand() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--local-relay-jsonl"],
        environment: [
            "CODEXPORT_HOST_AGENT_BACKEND": "process-stdio",
            "CODEXPORT_HOST_AGENT_COMMAND": "/bin/sh",
            "CODEXPORT_HOST_AGENT_ARGUMENTS_JSON": #"["-c","printf 'codex:assistant:ready\\n'"]"#,
        ]
    )
    let command = configuration.commandFactory(
        HostAgentLocalRelayAttachRequest(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1")
    )

    #expect(configuration.mode == .localRelayJSONL)
    #expect(command.executablePath == "/bin/sh")
    #expect(command.arguments == ["-c", "printf 'codex:assistant:ready\\n'"])
}

@Test func hostAgentCommandLineParsesLocalRelayWebSocketModeWithPairingSeed() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--local-relay-websocket", "--port", "7788"],
        environment: [
            "CODEXPORT_HOST_AGENT_BACKEND": "process-stdio",
            "CODEXPORT_HOST_AGENT_COMMAND": "/bin/sh",
            "CODEXPORT_HOST_AGENT_ARGUMENTS_JSON": #"["-c","printf 'codex:assistant:ready\\n'"]"#,
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
            "CODEXPORT_RELAY_DEVICE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "CODEXPORT_RELAY_DEVICE_NAME": "iPhone A",
        ]
    )
    let command = configuration.commandFactory(
        HostAgentLocalRelayAttachRequest(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1")
    )

    #expect(configuration.mode == .localRelayWebSocket(port: 7_788))
    #expect(command.executablePath == "/bin/sh")
    #expect(command.arguments == ["-c", "printf 'codex:assistant:ready\\n'"])
    #expect(configuration.localRelaySeed?.host.id.uuidString == "11111111-2222-3333-4444-555555555555")
    #expect(configuration.localRelaySeed?.host.displayName == "Mac Studio")
    #expect(configuration.localRelaySeed?.host.userName == "chenm")
    #expect(configuration.localRelaySeed?.device.id.uuidString == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    #expect(configuration.localRelaySeed?.device.displayName == "iPhone A")
}

@Test func hostAgentCommandLineParsesLocalRelayWebSocketModeWithMultipleDeviceSeeds() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--local-relay-websocket", "--port", "7788"],
        environment: [
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
            "CODEXPORT_RELAY_DEVICES_JSON": #"""
            [
              {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"iPhone A"},
              {"id":"BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF","name":"iPhone B"}
            ]
            """#,
        ]
    )

    #expect(configuration.mode == .localRelayWebSocket(port: 7_788))
    #expect(configuration.localRelaySeed?.devices.map(\.id.uuidString) == [
        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF",
    ])
    #expect(configuration.localRelaySeed?.devices.map(\.displayName) == ["iPhone A", "iPhone B"])
}

@Test func hostAgentCommandLineDefaultsToCodexCLILiveBackendForProductionTUILiveSync() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--p2p-listen"],
        environment: [
            "CODEXPORT_RELAY_BASE_URL": "https://relay.example.test",
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
            "HOME": "/Users/chenm",
        ]
    )

    #expect(configuration.mode == .p2pListen)
    #expect(configuration.backend == .codexCLILive)
    #expect(configuration.codexControlSocketPath == "/Users/chenm/.codex/app-server-control/app-server-control.sock")

    let adapter = configuration.adapterFactory(
        HostAgentLocalRelayAttachRequest(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1")
    )
    #expect(adapter.description == "Codex CLI live adapter")
}

@Test func hostAgentCommandLineStillAllowsProcessStdioBackendOverrideForFixtures() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--local-relay-jsonl"],
        environment: [
            "CODEXPORT_HOST_AGENT_BACKEND": "process-stdio",
            "CODEXPORT_HOST_AGENT_COMMAND": "/bin/sh",
            "CODEXPORT_HOST_AGENT_ARGUMENTS_JSON": #"["-c","printf 'codex:assistant:ready\\n'"]"#,
        ]
    )
    let command = configuration.commandFactory(
        HostAgentLocalRelayAttachRequest(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1")
    )

    #expect(configuration.mode == .localRelayJSONL)
    #expect(configuration.backend == .processStdio)
    #expect(command.executablePath == "/bin/sh")
    #expect(command.arguments == ["-c", "printf 'codex:assistant:ready\\n'"])
}

@Test func hostAgentCommandLineParsesCodexExecJSONBackend() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--local-relay-jsonl"],
        environment: [
            "CODEXPORT_HOST_AGENT_BACKEND": "codex-exec-json",
            "CODEXPORT_HOST_AGENT_COMMAND": "/Users/chenm/.local/bin/codex",
            "CODEXPORT_CODEX_EXEC_ARGUMENTS_JSON": #"["--skip-git-repo-check","--json"]"#,
            "CODEXPORT_CODEX_EXEC_RESUME_ARGUMENTS_JSON": #"["--skip-git-repo-check","--json"]"#,
            "CODEXPORT_CODEX_EXEC_TIMEOUT_SECONDS": "45",
        ]
    )

    #expect(configuration.mode == .localRelayJSONL)
    #expect(configuration.backend == .codexExecJSON)
    #expect(configuration.codexExecTimeout == .seconds(45))
}

@Test func hostAgentCommandLineParsesCodexCLILiveBackend() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--local-relay-jsonl"],
        environment: [
            "CODEXPORT_HOST_AGENT_BACKEND": "codex-cli-live",
            "CODEXPORT_CODEX_CONTROL_SOCKET_PATH": "/tmp/codex-control.sock",
        ]
    )

    #expect(configuration.mode == .localRelayJSONL)
    #expect(configuration.backend == .codexCLILive)
    #expect(configuration.codexControlSocketPath == "/tmp/codex-control.sock")

    let adapter = configuration.adapterFactory(
        HostAgentLocalRelayAttachRequest(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1")
    )
    #expect(adapter.description == "Codex CLI live adapter")
}

@Test func hostAgentRuntimeAdapterFactoryBuildsCodexCLILiveAdapter() {
    let factory = HostAgentRuntimeAdapterFactory.make(configuration: HostAgentRuntimeAdapterFactoryConfiguration(
        backend: .codexCLILive,
        executablePath: "/usr/bin/codex",
        processArguments: [],
        codexExecBaseArguments: [],
        codexExecResumeArguments: [],
        codexExecTimeout: .seconds(120),
        codexControlSocketPath: "/tmp/codex-control.sock"
    ))

    let adapter = factory(
        HostAgentLocalRelayAttachRequest(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1")
    )

    #expect(adapter.description == "Codex CLI live adapter")
}

@Test func hostAgentRuntimeAdapterFactoryDefersFreshCodexCLILiveResumeUntilFirstPrompt() {
    let factory = HostAgentRuntimeAdapterFactory.make(configuration: HostAgentRuntimeAdapterFactoryConfiguration(
        backend: .codexCLILive,
        executablePath: "/usr/bin/codex",
        processArguments: [],
        codexExecBaseArguments: [],
        codexExecResumeArguments: [],
        codexExecTimeout: .seconds(120),
        codexControlSocketPath: "/tmp/codex-control.sock"
    ))

    let adapter = factory(HostAgentLocalRelayAttachRequest(
        sessionID: "fresh-thread",
        threadID: "fresh-thread",
        turnID: "fresh-thread-turn",
        loadInitialHistory: false,
        resumeLiveSession: false
    ))

    #expect(adapter.description == "Codex CLI live adapter")
    #expect(adapter.metadata["resumeThreadOnStart"] == "false")
}

@Test func hostAgentRuntimeThreadProviderFactoryUsesControlSocketForCodexCLILiveThreadStarts() async throws {
    let providers = HostAgentRuntimeThreadProviderFactory.make(
        backend: .codexCLILive,
        codexControlSocketPath: "/tmp/missing-codex-control.sock"
    )

    #expect(providers.threadListProvider is HostAgentCodexAppServerThreadListProvider)
    #expect(providers.threadStarter is HostAgentCodexAppServerControlThreadProvider)
    #expect(providers.threadHistoryProvider is HostAgentCodexAppServerThreadListProvider)
}

@Test func hostAgentCommandLineParsesProductionRelayConnectMode() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--relay-connect"],
        environment: [
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
        ]
    )

    #expect(configuration.mode == .relayConnect)
    #expect(configuration.relayConfiguration?.relayBaseURL == URL(string: "https://codexport.smarteffi.net")!)
    #expect(configuration.relayConfiguration?.hostConnectURL == URL(string: "wss://codexport.smarteffi.net/v0/host/connect")!)
    #expect(configuration.relayConfiguration?.host.id.uuidString == "11111111-2222-3333-4444-555555555555")
    #expect(configuration.relayConfiguration?.host.displayName == "Mac Studio")
    #expect(configuration.relayConfiguration?.host.userName == "chenm")
}

@Test func hostAgentCommandLineRejectsLegacySyntheticHostDisplayName() throws {
    #expect(throws: HostAgentCommandLineConfigurationError.missingRelaySeed("CODEXPORT_RELAY_HOST_NAME")) {
        _ = try HostAgentCommandLineConfiguration(
            arguments: ["codexport-host-agent", "--p2p-listen"],
            environment: [
                "CODEXPORT_RELAY_BASE_URL": "https://relay.example.test",
                "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
                "CODEXPORT_RELAY_HOST_NAME": "CodexPort Dev Mac",
                "CODEXPORT_RELAY_HOST_USER": "chenm",
            ]
        )
    }
}

@Test func hostAgentCommandLineStillAllowsRelayEndpointOverrideForLocalVerification() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--relay-connect"],
        environment: [
            "CODEXPORT_RELAY_BASE_URL": "https://relay.example.test",
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
        ]
    )

    #expect(configuration.relayConfiguration?.relayBaseURL == URL(string: "https://relay.example.test")!)
    #expect(configuration.relayConfiguration?.hostConnectURL == URL(string: "wss://relay.example.test/v0/host/connect")!)
}

@Test func hostAgentCommandLineParsesP2PListenModeWithoutLegacyBridgeWebSocket() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--p2p-listen"],
        environment: [
            "CODEXPORT_RELAY_BASE_URL": "https://relay.example.test",
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
        ]
    )

    #expect(configuration.mode == .p2pListen)
    #expect(configuration.relayConfiguration?.relayBaseURL == URL(string: "https://relay.example.test")!)
    #expect(configuration.relayConfiguration?.hostConnectURL == URL(string: "wss://relay.example.test/v0/host/connect")!)
    #expect(configuration.relayConfiguration?.host.id.uuidString == "11111111-2222-3333-4444-555555555555")
}

@Test func hostAgentCommandLineParsesWebRTCSidecarCommandForP2PListenMode() throws {
    let configuration = try HostAgentCommandLineConfiguration(
        arguments: ["codexport-host-agent", "--p2p-listen"],
        environment: [
            "CODEXPORT_RELAY_BASE_URL": "https://relay.example.test",
            "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
            "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
            "CODEXPORT_RELAY_HOST_USER": "chenm",
            "CODEXPORT_WEBRTC_SIDECAR_PATH": "/Applications/CodexPort WebRTC Sidecar.app/Contents/MacOS/CodexPortWebRTCSidecar",
            "CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON": #"["--stdio-jsonl"]"#,
        ]
    )

    #expect(configuration.mode == .p2pListen)
    #expect(configuration.webRTCSidecarCommand == HostAgentProcessCommand(
        executablePath: "/Applications/CodexPort WebRTC Sidecar.app/Contents/MacOS/CodexPortWebRTCSidecar",
        arguments: ["--stdio-jsonl"]
    ))
}
