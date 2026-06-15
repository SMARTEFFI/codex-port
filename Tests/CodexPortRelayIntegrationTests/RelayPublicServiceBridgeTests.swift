import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortHostAgentCore
@testable import CodexPortRelayCore
@testable import CodexPortShared

@Test func publicRelayServiceBridgesIOSStreamToOutboundHostAgentConnection() async throws {
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
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let hostAgentService = HostAgentLocalRelayService(
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
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: endpoints.hostConnectURL,
        service: hostAgentService
    )
    connector.connect()

    await waitForRelayIntegration(timeout: .seconds(2)) {
        await gateway.presence(for: hostID) == .online(activeConnectionCount: 0)
    }

    let pairing = try await gateway.authorize(device: device, forHostID: hostID, pairedAt: Date(timeIntervalSince1970: 1))
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpoints.streamEndpointURL,
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
    try await client.sendPrompt("public relay prompt", writeID: "write-public-relay")

    await waitForRelayIntegration(timeout: .seconds(3)) {
        store.hasAssistantText(containing: "public relay prompt")
    }

    let telemetry = await gateway.telemetrySnapshot().values.first
    #expect(store.hasAssistantText(containing: "public relay prompt"))
    #expect((telemetry?.deviceToHostByteCount ?? 0) > 0)
    #expect((telemetry?.hostToDeviceByteCount ?? 0) > 0)

    transport.stop()
    connector.stop()
    await relay.stop()
    await hostAgentService.stopAll()
}

@Test func publicRelayServiceKeepsReplacementHostConnectionWhenOldConnectionCloses() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let oldHost = RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio Old",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key-old".utf8))
    )
    let replacementHost = RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio Replacement",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key-new".utf8))
    )
    let device = DeviceIdentity(
        id: deviceID,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let oldService = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadListProvider: RelayBridgeStubThreadListProvider(threadIDs: ["old-thread"])
    )
    let replacementService = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadListProvider: RelayBridgeStubThreadListProvider(threadIDs: ["replacement-thread"])
    )
    let oldConnector = HostAgentRelayConnector(
        host: oldHost,
        endpointURL: endpoints.hostConnectURL,
        service: oldService
    )
    let replacementConnector = HostAgentRelayConnector(
        host: replacementHost,
        endpointURL: endpoints.hostConnectURL,
        service: replacementService
    )

    oldConnector.connect()
    await waitForRelayIntegration(timeout: .seconds(2)) {
        await gateway.presence(for: hostID) == .online(activeConnectionCount: 0)
    }
    let pairing = try await gateway.authorize(device: device, forHostID: hostID, pairedAt: Date(timeIntervalSince1970: 1))
    let oldThreadIDs = await waitForRelayBridgeThreadIDs(
        endpoints: endpoints,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id,
        expected: ["old-thread"]
    )
    #expect(oldThreadIDs == ["old-thread"])

    replacementConnector.connect()
    let liveReplacementThreadIDs = await waitForRelayBridgeThreadIDs(
        endpoints: endpoints,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id,
        expected: ["replacement-thread"]
    )
    #expect(liveReplacementThreadIDs == ["replacement-thread"])

    oldConnector.stop()
    try? await Task.sleep(for: .milliseconds(50))
    let replacementThreadIDs = await waitForRelayBridgeThreadIDs(
        endpoints: endpoints,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id,
        expected: ["replacement-thread"]
    )

    #expect(replacementThreadIDs == ["replacement-thread"])

    replacementConnector.stop()
    await relay.stop()
    await oldService.stopAll()
    await replacementService.stopAll()
}

@Test func publicRelayServiceBridgesLargeThreadListResponseBackToDeviceStream() async throws {
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
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadListProvider: RelayBridgeStubThreadListProvider(
            threadIDs: (0..<20).map { "large-thread-\($0)-" + String(repeating: "x", count: 800) }
        )
    )
    let connector = HostAgentRelayConnector(
        host: host,
        endpointURL: endpoints.hostConnectURL,
        service: service
    )
    connector.connect()

    await waitForRelayIntegration(timeout: .seconds(2)) {
        await gateway.presence(for: hostID) == .online(activeConnectionCount: 0)
    }

    let pairing = try await gateway.authorize(device: device, forHostID: hostID, pairedAt: Date(timeIntervalSince1970: 1))
    let threadIDs = try await relayBridgeThreadIDs(
        endpoints: endpoints,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id,
        timeout: .seconds(2)
    )

    #expect(threadIDs.count == 20)
    #expect(threadIDs.first?.hasPrefix("large-thread-0-") == true)

    connector.stop()
    await relay.stop()
    await service.stopAll()
}

private extension SessionStore {
    func hasAssistantText(containing needle: String) -> Bool {
        visibleItems.contains { item in
            guard case let .assistantMessage(text) = item else { return false }
            return text.contains(needle)
        }
    }
}

private final class RelayHarnessProtocolClient: CodexProtocolClient, @unchecked Sendable {
    func readThread(id: String, includeTurns: Bool) async throws -> JSONValue { .object([:]) }
    func resumeThread(id: String) async throws -> JSONValue { .object([:]) }
    func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue { .object([:]) }
    func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue { .object([:]) }
    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String) async throws -> JSONValue {
        .object(["data": .array([]), "nextCursor": .null])
    }
    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String, timeoutSeconds: Double?) async throws -> JSONValue {
        .object(["data": .array([]), "nextCursor": .null])
    }
    func startThread(cwd: String, model: CodexModel) async throws -> String { "thread-1" }
    func startTurn(threadID: String, prompt: String, attachments: [TurnAttachment], model: CodexModel, reasoningEffort: ReasoningEffort, permissionMode: PermissionMode, collaborationMode: CollaborationMode) async throws -> JSONValue {
        .object(["turnId": .string("turn-1")])
    }
    func steerTurn(threadID: String, turnID: String, prompt: String, attachments: [TurnAttachment]) async throws -> JSONValue {
        .object(["turnId": .string(turnID)])
    }
    func interruptTurn(threadID: String, turnID: String) async throws -> JSONValue { .object([:]) }
    func unsubscribeThread(id: String) async throws -> JSONValue { .object([:]) }
    func readDirectory(path: String) async throws -> [RemoteDirectoryEntry] { [] }
    func getMetadata(path: String) async throws -> RemoteMetadata { RemoteMetadata(path: path, kind: .directory) }
    func createDirectory(path: String, recursive: Bool) async throws {}
    func writeFile(path: String, dataBase64: String) async throws {}
}

private struct RelayBridgeStubThreadListProvider: HostAgentThreadListProviding {
    var threadIDs: [String]

    func listThreads(limit: Int, cursor: String?) async throws -> RelayThreadListResponse {
        RelayThreadListResponse(threads: threadIDs.prefix(limit).map { threadID in
            RelayThreadSummarySnapshot(
                id: threadID,
                cwd: "/Users/chenm/Projects/codex-port",
                updatedAtUnixTime: 1_780_991_312,
                preview: threadID,
                gitRepository: nil,
                gitBranch: nil,
                status: "completed"
            )
        })
    }
}

private func relayBridgeThreadIDs(
    endpoints: RelayPublicServiceEndpoints,
    hostID: UUID,
    deviceID: UUID,
    pairingRecordID: String,
    timeout: Duration = .milliseconds(300)
) async throws -> [String] {
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpoints.streamEndpointURL,
        hostAgentID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairingRecordID
    )
    defer {
        transport.stop()
    }
    let client = RelayJSONLThreadListClient(
        clientID: pairingRecordID,
        transport: transport,
        timeout: timeout,
        pageSize: 20
    )
    return try await client.listThreads(limit: 20).map(\.id)
}

private func waitForRelayBridgeThreadIDs(
    endpoints: RelayPublicServiceEndpoints,
    hostID: UUID,
    deviceID: UUID,
    pairingRecordID: String,
    expected: [String],
    timeout: Duration = .seconds(2)
) async -> [String]? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var latest: [String]?
    while clock.now < deadline {
        latest = try? await relayBridgeThreadIDs(
            endpoints: endpoints,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: pairingRecordID
        )
        if latest == expected {
            return latest
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return latest
}

private func waitForRelayIntegration(
    timeout: Duration = .milliseconds(200),
    condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
