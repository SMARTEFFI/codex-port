import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortHostAgentCore
@testable import CodexPortRelayCore
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func relayEndpointClientsShareHostAgentLocalRelayServicePromptAndInterruptState() async throws {
    let harness = HostAgentLocalRelayEndpointHarness(
        service: HostAgentLocalRelayService(
            commandFactory: { _ in
                HostAgentProcessCommand(
                    executablePath: "/bin/sh",
                    arguments: [
                        "-c",
                        """
                        printf 'codex:assistant:ready\\n'
                        while IFS= read -r line; do
                          printf 'codex:assistant:%s\\n' "$line"
                        done
                        """,
                    ]
                )
            }
        )
    )
    let iPhoneAStore = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let iPhoneBStore = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let iPhoneA = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: await harness.makeTransport(),
        sessionStore: iPhoneAStore
    )
    let iPhoneB = RelayJSONLSessionClient(
        clientID: "iphone-b",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: await harness.makeTransport(),
        sessionStore: iPhoneBStore
    )

    try await iPhoneA.attach()
    try await iPhoneB.attach()
    try await iPhoneA.sendPrompt("integration prompt from a", writeID: "write-a")

    await waitForRelayIntegration(timeout: .milliseconds(1_500)) {
        iPhoneAStore.hasAssistantText(containing: "integration prompt from a")
            && iPhoneBStore.hasAssistantText(containing: "integration prompt from a")
    }

    try await iPhoneB.interrupt(writeID: "interrupt-b")

    await waitForRelayIntegration(timeout: .milliseconds(1_500)) {
        iPhoneA.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-b", status: .handled)
            && iPhoneB.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-b", status: .handled)
    }

    #expect(iPhoneAStore.hasAssistantText(containing: "integration prompt from a"))
    #expect(iPhoneBStore.hasAssistantText(containing: "integration prompt from a"))
    #expect(iPhoneA.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-b", status: .handled))
    #expect(iPhoneB.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-b", status: .handled))

    await harness.stop()
}

@Test func relayEndpointClientLoadsEarlierHistoryPageThroughHostAgentLocalRelayService() async throws {
    let historyProvider = RelayIntegrationThreadHistoryProvider(
        initial: RelayThreadHistorySnapshot(
            threadID: "thread-1",
            items: [
                .userMessage("recent question"),
                .assistantMessage("recent answer"),
            ],
            status: .completed,
            nextCursor: "older-cursor-1"
        ),
        pages: [
            RelayThreadHistoryPage(
                requestID: "provider-placeholder",
                threadID: "thread-1",
                items: [
                    .userMessage("older question"),
                    .assistantMessage("older answer"),
                ],
                status: .completed,
                nextCursor: nil
            ),
        ]
    )
    let harness = HostAgentLocalRelayEndpointHarness(
        service: HostAgentLocalRelayService(
            commandFactory: { _ in
                HostAgentProcessCommand(executablePath: "/bin/sh", arguments: ["-c", "sleep 0.05"])
            },
            threadHistoryProvider: historyProvider
        )
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "thread-1",
        threadID: "thread-1",
        turnID: "thread-1-turn",
        transport: await harness.makeTransport(),
        sessionStore: store
    )

    try await client.attach()
    await waitForRelayIntegration(timeout: .milliseconds(500)) {
        store.visibleItems == [
            .userMessage("recent question"),
            .assistantMessage("recent answer"),
        ] && store.earlierHistoryCursor == "older-cursor-1"
    }

    _ = try await client.loadEarlierHistory(
        cursor: store.earlierHistoryCursor,
        limit: 10,
        requestID: "history-request-1"
    )

    #expect(await historyProvider.requests == [
        .init(threadID: "thread-1", limit: 10, cursor: "older-cursor-1")
    ])
    #expect(store.visibleItems == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
        .userMessage("recent question"),
        .assistantMessage("recent answer"),
    ])
    #expect(store.hasEarlierHistory == false)

    await harness.stop()
}

@Test func authorizedRelayStreamOpenDrivesHostAgentLocalRelayServiceEndpointClients() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let host = FakeHostAgentEndpoint(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let iPhone = FakeIOSDeviceEndpoint(
        id: deviceID,
        displayName: "iPhone A",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    _ = try relay.registerHostAgent(host)
    let pairing = relay.authorize(device: iPhone, forHostID: hostID, pairedAt: Date(timeIntervalSince1970: 1))
    let stream = try relay.openStream(RelayStreamOpenRequest(
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id,
        supportedVersions: [.v0_2_0],
        tags: ["purpose": "host-agent-jsonl"]
    ))
    let harness = HostAgentLocalRelayEndpointHarness(
        service: HostAgentLocalRelayService(
            commandFactory: { _ in
                HostAgentProcessCommand(
                    executablePath: "/bin/sh",
                    arguments: [
                        "-c",
                        """
                        printf 'codex:assistant:ready\\n'
                        while IFS= read -r line; do
                          printf 'codex:assistant:%s\\n' "$line"
                        done
                        """,
                    ]
                )
            }
        )
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: pairing.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: await harness.makeTransport(for: stream),
        sessionStore: store
    )

    try await client.attach()
    try await client.sendPrompt("authorized stream prompt", writeID: "write-authorized")

    await waitForRelayIntegration(timeout: .milliseconds(1_500)) {
        store.hasAssistantText(containing: "authorized stream prompt")
    }

    #expect(store.hasAssistantText(containing: "authorized stream prompt"))
    #expect(relay.telemetry(for: stream.id)?.metadata.tags == ["purpose": "host-agent-jsonl"])

    _ = try relay.revoke(deviceID: deviceID, forHostID: hostID, at: Date(timeIntervalSince1970: 2))
    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: hostID, deviceID: deviceID)) {
        _ = try relay.openStream(RelayStreamOpenRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: pairing.id,
            supportedVersions: [.v0_2_0],
            tags: ["purpose": "host-agent-jsonl"]
        ))
    }

    await harness.stop()
}

@Test func webSocketOpenRequestGatewayAuthorizesAndDrivesHostAgentLocalRelayService() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let host = RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let device = DeviceIdentity(
        id: deviceID,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(host)
    let pairing = try await gateway.authorize(device: device, forHostID: hostID, pairedAt: Date(timeIntervalSince1970: 1))
    var request = URLRequest(url: try #require(URL(string: "wss://relay.example.test/v0/streams")))
    RelayStreamOpenRequestWebSocketCodec.encode(
        RelayStreamOpenRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: pairing.id,
            supportedVersions: [.v0_2_0],
            tags: ["purpose": "host-agent-jsonl"]
        ),
        into: &request
    )

    let opened = try await gateway.openWebSocketStream(from: request)
    let harness = HostAgentLocalRelayEndpointHarness(
        service: HostAgentLocalRelayService(
            commandFactory: { _ in
                HostAgentProcessCommand(
                    executablePath: "/bin/sh",
                    arguments: [
                        "-c",
                        """
                        printf 'codex:assistant:ready\\n'
                        while IFS= read -r line; do
                          printf 'codex:assistant:%s\\n' "$line"
                        done
                        """,
                    ]
                )
            }
        )
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: opened.clientID,
        sessionID: opened.sessionID,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: await harness.makeTransport(for: opened, gateway: gateway),
        sessionStore: store
    )

    try await client.attach()
    try await client.sendPrompt("websocket gateway prompt", writeID: "write-websocket-gateway")

    await waitForRelayIntegration(timeout: .milliseconds(1_500)) {
        store.hasAssistantText(containing: "websocket gateway prompt")
    }

    #expect(store.hasAssistantText(containing: "websocket gateway prompt"))
    let telemetry = await gateway.telemetry(for: opened.id)
    #expect(telemetry?.metadata.tags == ["purpose": "host-agent-jsonl"])
    #expect((telemetry?.deviceToHostByteCount ?? 0) > 0)
    #expect((telemetry?.hostToDeviceByteCount ?? 0) > 0)

    _ = try await gateway.revoke(deviceID: deviceID, forHostID: hostID, at: Date(timeIntervalSince1970: 2))
    do {
        _ = try await gateway.openWebSocketStream(from: request)
        Issue.record("revoked device unexpectedly opened a WebSocket stream")
    } catch RelayProtocolError.deviceNotAuthorized(hostID: hostID, deviceID: deviceID) {
    }

    await harness.stop()
}

@Test func webSocketOpenRequestGatewayRejectsInvalidStreamHandshake() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairing = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    var missingDeviceRequest = URLRequest(url: try #require(URL(string: "wss://relay.example.test/v0/streams")))
    missingDeviceRequest.setValue(hostID.uuidString, forHTTPHeaderField: "X-CodexPort-Host-Agent-ID")
    missingDeviceRequest.setValue(pairing.id, forHTTPHeaderField: "X-CodexPort-Pairing-Record-ID")
    missingDeviceRequest.setValue("0.2.0", forHTTPHeaderField: "X-CodexPort-Relay-Versions")
    do {
        _ = try await gateway.openWebSocketStream(from: missingDeviceRequest)
        Issue.record("missing device header unexpectedly opened a WebSocket stream")
    } catch RelayStreamOpenRequestWebSocketCodec.Error.missingHeader("X-CodexPort-Device-ID") {
    }

    var incompatibleRequest = URLRequest(url: try #require(URL(string: "wss://relay.example.test/v0/streams")))
    RelayStreamOpenRequestWebSocketCodec.encode(
        RelayStreamOpenRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: pairing.id,
            supportedVersions: [RelayProtocolVersion(major: 9, minor: 9, patch: 9)],
            tags: ["purpose": "host-agent-jsonl"]
        ),
        into: &incompatibleRequest
    )

    do {
        _ = try await gateway.openWebSocketStream(from: incompatibleRequest)
        Issue.record("incompatible version unexpectedly opened a WebSocket stream")
    } catch RelayProtocolError.incompatibleVersion(
        clientSupported: [RelayProtocolVersion(major: 9, minor: 9, patch: 9)],
        relaySupported: [.v0_2_0]
    ) {
    }
}

@Test func relayWebSocketTransportTalksToNetworkListenerAndHostAgentLocalService() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairing = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in
            HostAgentProcessCommand(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    printf 'codex:assistant:ready\\n'
                    while IFS= read -r line; do
                      printf 'codex:assistant:%s\\n' "$line"
                    done
                    """,
                ]
            )
        }
    )
    let server = RelayWebSocketLineStreamServer(gateway: gateway) { _, line, writer in
        try await service.handleLine(line) { outputLine in
            try? await writer.sendLine(outputLine)
        }
    }
    let endpointURL = try await server.start()
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: pairing.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try await client.sendPrompt("network listener prompt", writeID: "write-network-listener")

    await waitForRelayIntegration(timeout: .seconds(2)) {
        store.hasAssistantText(containing: "network listener prompt")
    }

    let telemetry = await gateway.telemetrySnapshot().values.first
    #expect(store.hasAssistantText(containing: "network listener prompt"))
    #expect((telemetry?.deviceToHostByteCount ?? 0) > 0)
    #expect((telemetry?.hostToDeviceByteCount ?? 0) > 0)

    transport.stop()
    await server.stop()
    await service.stopAll()
}

@Test func relayWebSocketTransportPropagatesCodexExecTimeoutFailureToIOSStore() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairing = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let runner = RelayIntegrationHangingCodexExecJSONProcessRunner()
    let service = HostAgentLocalRelayService(adapterFactory: { request in
        AnyHostAgentLiveSessionAdapter(HostAgentCodexExecJSONAdapter(
            command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
            sessionID: request.sessionID,
            initialThreadID: request.threadID,
            turnID: request.turnID,
            processRunner: runner,
            processTimeout: .milliseconds(10)
        ))
    })
    let server = RelayWebSocketLineStreamServer(gateway: gateway) { _, line, writer in
        try await service.handleLine(line) { outputLine in
            try? await writer.sendLine(outputLine)
        }
    }
    let endpointURL = try await server.start()
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: pairing.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try await client.sendPrompt("<redacted-test-payload>", writeID: "write-timeout")

    await waitForRelayIntegration(timeout: .seconds(2)) {
        store.status == .failed("Codex CLI exec timed out.")
            && client.latestWriteStatus == .init(
                sessionID: hostID.uuidString,
                writeID: "write-timeout",
                status: .failed(reason: "Codex CLI exec timed out.")
            )
    }

    let rows = TranscriptPresentation.rows(for: store.visibleItems, status: store.status)
    #expect(store.status == .failed("Codex CLI exec timed out."))
    #expect(client.latestWriteStatus == .init(
        sessionID: hostID.uuidString,
        writeID: "write-timeout",
        status: .failed(reason: "Codex CLI exec timed out.")
    ))
    #expect(rows.contains { row in
        row.id == "status-failed"
            && row.kind == .status
            && row.body == "会话失败：Codex CLI exec timed out."
    })
    #expect(await runner.wasCancelled)

    transport.stop()
    await server.stop()
    await service.stopAll()
}

@Test func relayWebSocketTransportShowsThinkingBeforeCodexExecCompletes() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairing = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let runner = RelayIntegrationHangingCodexExecJSONProcessRunner()
    let service = HostAgentLocalRelayService(adapterFactory: { request in
        AnyHostAgentLiveSessionAdapter(HostAgentCodexExecJSONAdapter(
            command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
            sessionID: request.sessionID,
            initialThreadID: request.threadID,
            turnID: request.turnID,
            processRunner: runner,
            processTimeout: .seconds(5)
        ))
    })
    let server = RelayWebSocketLineStreamServer(gateway: gateway) { _, line, writer in
        try await service.handleLine(line) { outputLine in
            try? await writer.sendLine(outputLine)
        }
    }
    let endpointURL = try await server.start()
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: pairing.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    let acceptedStatus = try await client.sendPromptAndWaitForAcceptance(
        "show progress before final response",
        writeID: "write-progress",
        timeout: .seconds(2)
    )

    let rows = TranscriptPresentation.rows(for: store.visibleItems, status: store.status)
    #expect(acceptedStatus == .queued)
    #expect(store.visibleItems == [.userMessage("show progress before final response")])
    #expect(store.status == .running)
    #expect(rows.contains { row in
        row.id == "thinking"
            && row.kind == .thinking
            && row.body == "正在思考..."
    })
    #expect(!store.hasAssistantText(containing: "show progress before final response"))

    transport.stop()
    await server.stop()
    await service.stopAll()
}

@Test func relayWebSocketTransportFansOutCodexExecSuccessAcrossTwoIOSStores() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceAID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let deviceBID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairingA = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceAID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let pairingB = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceBID,
            displayName: "iPhone B",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-b-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let runner = RelayIntegrationScriptedCodexExecJSONProcessRunner(results: [
        .success(.init(
            stdout: """
            {"type":"thread.started","thread_id":"019ea65c-1f12-700d-8a41-5d9c3f3cb101"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"answer from b"}}
            {"type":"turn.completed"}
            """,
            stderr: "",
            exitCode: 0
        )),
    ])
    let service = HostAgentLocalRelayService(adapterFactory: { request in
        AnyHostAgentLiveSessionAdapter(HostAgentCodexExecJSONAdapter(
            command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
            sessionID: request.sessionID,
            initialThreadID: request.threadID,
            turnID: request.turnID,
            processRunner: runner
        ))
    })
    let server = RelayWebSocketLineStreamServer(gateway: gateway) { _, line, writer in
        try await service.handleLine(line) { outputLine in
            try? await writer.sendLine(outputLine)
        }
    }
    let endpointURL = try await server.start()
    let transportA = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceAID,
        pairingRecordID: pairingA.id
    )
    let transportB = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceBID,
        pairingRecordID: pairingB.id
    )
    let storeA = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let storeB = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let clientA = RelayJSONLSessionClient(
        clientID: pairingA.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transportA,
        sessionStore: storeA
    )
    let clientB = RelayJSONLSessionClient(
        clientID: pairingB.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transportB,
        sessionStore: storeB
    )

    try await clientA.attach()
    try await clientB.attach()
    try await clientB.sendPrompt("<redacted-b-request>", writeID: "write-b")

    await waitForRelayIntegration(timeout: .seconds(2)) {
        storeA.hasAssistantText(containing: "answer from b")
            && storeB.hasAssistantText(containing: "answer from b")
            && clientA.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "write-b", status: .handled)
            && clientB.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "write-b", status: .handled)
    }

    #expect(storeA.hasAssistantText(containing: "answer from b"))
    #expect(storeB.hasAssistantText(containing: "answer from b"))
    #expect(clientA.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "write-b", status: .handled))
    #expect(clientB.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "write-b", status: .handled))

    transportA.stop()
    transportB.stop()
    await server.stop()
    await service.stopAll()
}

@Test func relayWebSocketTransportFansOutCodexExecInterruptHandledAcrossTwoIOSStores() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceAID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let deviceBID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairingA = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceAID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let pairingB = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceBID,
            displayName: "iPhone B",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-b-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    let service = HostAgentLocalRelayService(adapterFactory: { request in
        AnyHostAgentLiveSessionAdapter(HostAgentCodexExecJSONAdapter(
            command: HostAgentCodexExecJSONCommand(executablePath: "/usr/local/bin/codex"),
            sessionID: request.sessionID,
            initialThreadID: request.threadID,
            turnID: request.turnID,
            processRunner: RelayIntegrationScriptedCodexExecJSONProcessRunner(results: [])
        ))
    })
    let server = RelayWebSocketLineStreamServer(gateway: gateway) { _, line, writer in
        try await service.handleLine(line) { outputLine in
            try? await writer.sendLine(outputLine)
        }
    }
    let endpointURL = try await server.start()
    let transportA = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceAID,
        pairingRecordID: pairingA.id
    )
    let transportB = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceBID,
        pairingRecordID: pairingB.id
    )
    let storeA = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let storeB = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let clientA = RelayJSONLSessionClient(
        clientID: pairingA.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transportA,
        sessionStore: storeA
    )
    let clientB = RelayJSONLSessionClient(
        clientID: pairingB.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transportB,
        sessionStore: storeB
    )

    try await clientA.attach()
    try await clientB.attach()
    try await clientB.interrupt(writeID: "interrupt-b")

    await waitForRelayIntegration(timeout: .seconds(2)) {
        clientA.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "interrupt-b", status: .handled)
            && clientB.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "interrupt-b", status: .handled)
    }

    #expect(clientA.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "interrupt-b", status: .handled))
    #expect(clientB.latestWriteStatus == .init(sessionID: hostID.uuidString, writeID: "interrupt-b", status: .handled))

    transportA.stop()
    transportB.stop()
    await server.stop()
    await service.stopAll()
}

@Test func relayWebSocketNetworkListenerRejectsRevokedPairingBeforeJSONLAttach() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let pairing = try await gateway.authorize(
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        forHostID: hostID,
        pairedAt: Date(timeIntervalSince1970: 1)
    )
    _ = try await gateway.revoke(deviceID: deviceID, forHostID: hostID, at: Date(timeIntervalSince1970: 2))
    let server = RelayWebSocketLineStreamServer(gateway: gateway) { _, _, _ in
        Issue.record("revoked stream unexpectedly reached JSONL handler")
    }
    let endpointURL = try await server.start()
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id
    )
    let store = SessionStore(protocolClient: RelayHarnessProtocolClient())
    let client = RelayJSONLSessionClient(
        clientID: pairing.id,
        sessionID: hostID.uuidString,
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try? await client.attach()
    try? await client.sendPrompt("revoked network prompt", writeID: "write-revoked-network")
    try? await Task.sleep(for: .milliseconds(300))

    #expect(!store.hasAssistantText(containing: "revoked network prompt"))
    #expect(await gateway.telemetrySnapshot().isEmpty)

    transport.stop()
    await server.stop()
}

private extension SessionStore {
    func hasAssistantText(containing needle: String) -> Bool {
        visibleItems.contains { item in
            guard case let .assistantMessage(text) = item else { return false }
            return text.contains(needle)
        }
    }
}

private actor RelayIntegrationHangingCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    private var cancelled = false

    var wasCancelled: Bool {
        cancelled
    }

    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }
}

private actor RelayIntegrationScriptedCodexExecJSONProcessRunner: HostAgentCodexExecJSONProcessRunning {
    private let results: [Result<HostAgentCodexExecJSONProcessResult, Error>]
    private var index = 0

    init(results: [Result<HostAgentCodexExecJSONProcessResult, Error>]) {
        self.results = results
    }

    func run(_ invocation: HostAgentCodexExecJSONProcessInvocation) async throws -> HostAgentCodexExecJSONProcessResult {
        guard results.indices.contains(index) else {
            throw RelayIntegrationScriptedCodexExecJSONProcessRunnerError.exhausted
        }
        let result = results[index]
        index += 1
        return try result.get()
    }
}

private enum RelayIntegrationScriptedCodexExecJSONProcessRunnerError: Error {
    case exhausted
}

private actor RelayIntegrationThreadHistoryProvider: HostAgentThreadHistoryProviding {
    struct Request: Equatable {
        var threadID: String
        var limit: Int
        var cursor: String?
    }

    private let initial: RelayThreadHistorySnapshot
    private var pages: [RelayThreadHistoryPage]
    private(set) var requests: [Request] = []

    init(initial: RelayThreadHistorySnapshot, pages: [RelayThreadHistoryPage]) {
        self.initial = initial
        self.pages = pages
    }

    func history(threadID: String) async throws -> RelayThreadHistorySnapshot {
        initial
    }

    func historyPage(threadID: String, limit: Int, cursor: String?) async throws -> RelayThreadHistoryPage {
        requests.append(.init(threadID: threadID, limit: limit, cursor: cursor))
        var page = pages.removeFirst()
        page.threadID = threadID
        return page
    }
}

private actor HostAgentLocalRelayEndpointHarness {
    private let service: HostAgentLocalRelayService
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    init(service: HostAgentLocalRelayService) {
        self.service = service
    }

    func makeTransport() -> RelayLineLoopTransport {
        RelayLineLoopTransport(incomingLines: makeIncomingStream()) { line in
            try await self.service.handleLine(line) { outputLine in
                await self.broadcast(outputLine)
            }
        }
    }

    func makeTransport(for stream: FakeRelayStream) -> RelayLineLoopTransport {
        RelayLineLoopTransport(incomingLines: makeIncomingStream()) { line in
            stream.sendDeviceToHost(RelaySealedPayload(ciphertext: Data(line.utf8)))
            try await self.service.handleLine(line) { outputLine in
                stream.sendHostToDevice(RelaySealedPayload(ciphertext: Data(outputLine.utf8)))
                await self.broadcast(outputLine)
            }
        }
    }

    func makeTransport(
        for stream: RelayAuthorizedStream,
        gateway: RelayAuthenticatedStreamGateway
    ) -> RelayLineLoopTransport {
        RelayLineLoopTransport(incomingLines: makeIncomingStream()) { line in
            await gateway.recordDeviceToHost(streamID: stream.id, byteCount: Data(line.utf8).count)
            try await self.service.handleLine(line) { outputLine in
                await gateway.recordHostToDevice(streamID: stream.id, byteCount: Data(outputLine.utf8).count)
                await self.broadcast(outputLine)
            }
        }
    }

    private func makeIncomingStream() -> AsyncStream<String> {
        let id = UUID()
        var capturedContinuation: AsyncStream<String>.Continuation?
        let incomingLines = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        if let capturedContinuation {
            continuations[id] = capturedContinuation
        }
        return incomingLines
    }

    func stop() async {
        await service.stopAll()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func broadcast(_ line: String) {
        for continuation in continuations.values {
            continuation.yield(line)
        }
    }
}

private final class RelayHarnessProtocolClient: CodexProtocolClient, @unchecked Sendable {
    func readThread(id: String, includeTurns: Bool) async throws -> JSONValue {
        .object([:])
    }

    func resumeThread(id: String) async throws -> JSONValue {
        .object([:])
    }

    func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue {
        .object([:])
    }

    func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue {
        .object([:])
    }

    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String) async throws -> JSONValue {
        .object(["data": .array([]), "nextCursor": .null])
    }

    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String, timeoutSeconds: Double?) async throws -> JSONValue {
        .object(["data": .array([]), "nextCursor": .null])
    }

    func startThread(cwd: String, model: CodexModel) async throws -> String {
        "thread-1"
    }

    func startTurn(threadID: String, prompt: String, attachments: [TurnAttachment], model: CodexModel, reasoningEffort: ReasoningEffort, permissionMode: PermissionMode, collaborationMode: CollaborationMode) async throws -> JSONValue {
        .object(["turnId": .string("turn-1")])
    }

    func steerTurn(threadID: String, turnID: String, prompt: String, attachments: [TurnAttachment]) async throws -> JSONValue {
        .object(["turnId": .string(turnID)])
    }

    func interruptTurn(threadID: String, turnID: String) async throws -> JSONValue {
        .object([:])
    }

    func unsubscribeThread(id: String) async throws -> JSONValue {
        .object([:])
    }

    func readDirectory(path: String) async throws -> [RemoteDirectoryEntry] {
        []
    }

    func getMetadata(path: String) async throws -> RemoteMetadata {
        RemoteMetadata(path: path, kind: .directory)
    }

    func createDirectory(path: String, recursive: Bool) async throws {}

    func writeFile(path: String, dataBase64: String) async throws {}
}

private func waitForRelayIntegration(
    timeout: Duration = .milliseconds(200),
    condition: @escaping @Sendable () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
