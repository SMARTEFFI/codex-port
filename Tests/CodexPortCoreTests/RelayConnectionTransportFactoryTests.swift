import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func relayConnectionTransportFactoryDefaultsToDeferredP2PTransport() throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )

    let transport = RelayConnectionTransportFactory().makeTransport(for: relayHost)

    #expect(transport is RelayDeferredJSONLTransport)
}

@Test func relayConnectionTransportFactoryUsesLegacyWebSocketJSONLTransportWhenExplicitlySelected() throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )

    let transport = RelayConnectionTransportFactory(mode: .legacyWebSocketJSONL).makeTransport(for: relayHost)

    #expect(transport is RelayWebSocketJSONLTransport)
}

@Test func relayConnectionTransportFactoryUsesDeferredP2PTransportWhenExplicitlySelected() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let factory = RelayConnectionTransportFactory(
        mode: .p2pWebRTCDataChannel,
        relayBaseURL: URL(string: "https://relay.example.test")!,
        signalingHTTPClient: RelayP2PSignalingHTTPClientForConnectionFactory(
            presenceResponse: RelayP2PPresenceResponse(
                hostID: hostID,
                deviceID: deviceID,
                presence: .online,
                authorization: .authorizedToSignal,
                pairingRecordID: relayHost.pairingRecordID,
                activeConnectionCount: 1
            ),
            openResponse: RelayP2POpenSessionResponse(
                sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                hostID: hostID,
                deviceID: deviceID,
                pairingRecordID: relayHost.pairingRecordID,
                selectedVersion: .v0_2_0,
                openedAtUnixTime: 100
            )
        ),
        dataChannelFactory: UnavailableRelayP2PDataChannelFactory()
    )

    let transport = try #require(factory.makeTransport(for: relayHost))

    #expect(transport is RelayDeferredJSONLTransport)
    await #expect(throws: RelayP2PDataChannelRuntimeError.runtimeUnavailable(
        "Real WebRTC DataChannel runtime is not linked. Configure a production RelayP2PDataChannelFactory before enabling P2P route selection."
    )) {
        try await transport.sendLine(#"{"type":"attach"}"#)
    }
}

@Test func relayConnectionTransportFactoryDefaultP2PRouteUsesWebRTCFactoryGuard() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let factory = RelayConnectionTransportFactory(
        mode: .p2pWebRTCDataChannel,
        relayBaseURL: URL(string: "https://relay.example.test")!,
        signalingHTTPClient: RelayP2PSignalingHTTPClientForConnectionFactory(
            presenceResponse: RelayP2PPresenceResponse(
                hostID: hostID,
                deviceID: deviceID,
                presence: .online,
                authorization: .authorizedToSignal,
                pairingRecordID: relayHost.pairingRecordID,
                activeConnectionCount: 1
            ),
            openResponse: RelayP2POpenSessionResponse(
                sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                hostID: hostID,
                deviceID: deviceID,
                pairingRecordID: relayHost.pairingRecordID,
                selectedVersion: .v0_2_0,
                openedAtUnixTime: 100
            )
        )
    )

    let transport = try #require(factory.makeTransport(for: relayHost))

    await #expect(throws: WebRTCPlatformRuntimeError.runtimeUnavailable(
        "Real WebRTC SDK runtime is not linked. Link a platform WebRTC implementation before enabling P2P route selection."
    )) {
        try await transport.sendLine(#"{"type":"attach"}"#)
    }
}

@Test func relayConnectionTransportModeParsesEnvironmentAndDefaultsToP2P() {
    #expect(RelayConnectionTransportMode.parse(environmentValue: nil) == .p2pWebRTCDataChannel)
    #expect(RelayConnectionTransportMode.parse(environmentValue: "") == .p2pWebRTCDataChannel)
    #expect(RelayConnectionTransportMode.parse(environmentValue: "legacy") == .legacyWebSocketJSONL)
    #expect(RelayConnectionTransportMode.parse(environmentValue: "legacy-websocket-jsonl") == .legacyWebSocketJSONL)
    #expect(RelayConnectionTransportMode.parse(environmentValue: "unknown") == .p2pWebRTCDataChannel)
    #expect(RelayConnectionTransportMode.parse(environmentValue: "p2p") == .p2pWebRTCDataChannel)
    #expect(RelayConnectionTransportMode.parse(environmentValue: "p2p-webrtc-datachannel") == .p2pWebRTCDataChannel)
    #expect(RelayConnectionTransportMode.parse(environmentValue: " WebRTC-DataChannel ") == .p2pWebRTCDataChannel)
}

@Test func relayConnectionTransportFactoryDerivesDefaultSTUNFromRelayBaseURL() {
    let factory = RelayConnectionTransportFactory(
        mode: .p2pWebRTCDataChannel,
        relayBaseURL: URL(string: "https://relay.example.test")!
    )

    #expect(factory.webRTCConfigurationForTesting.iceServers == [
        WebRTCICEServerConfiguration(urls: ["stun:relay.example.test:3478"]),
    ])
}

private final class RelayP2PSignalingHTTPClientForConnectionFactory: RelayP2PSignalingHTTPClient, @unchecked Sendable {
    let presenceResponse: RelayP2PPresenceResponse
    let openResponse: RelayP2POpenSessionResponse

    init(
        presenceResponse: RelayP2PPresenceResponse,
        openResponse: RelayP2POpenSessionResponse
    ) {
        self.presenceResponse = presenceResponse
        self.openResponse = openResponse
    }

    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        presenceResponse
    }

    func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        openResponse
    }

    func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse {
        RelayP2PICEConfigurationResponse(
            configuration: WebRTCRuntimeConfiguration(iceServers: []),
            expiresAtUnixTime: 0
        )
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {}

    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        RelayP2PDrainMessagesResponse(messages: [])
    }
}
