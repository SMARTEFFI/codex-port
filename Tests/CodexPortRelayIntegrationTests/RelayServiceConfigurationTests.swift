import Foundation
import Testing
@testable import CodexPortRelayCore

@Test func relayServiceConfigurationParsesDockerFriendlyOperatorSettings() throws {
    let configuration = try RelayServiceConfiguration(
        arguments: [
            "codexport-relay",
            "--listen-host",
            "0.0.0.0",
            "--port",
            "8080",
        ],
        environment: [
            "CODEXPORT_RELAY_PUBLIC_BASE_URL": "https://relay.example.test",
            "CODEXPORT_RELAY_STORAGE_PATH": "/var/lib/codexport-relay",
            "CODEXPORT_RELAY_LOG_LEVEL": "info",
            "CODEXPORT_RELAY_TLS_MODE": "reverse-proxy",
            "CODEXPORT_RELAY_TURN_SHARED_SECRET": "turn-shared-secret",
            "CODEXPORT_RELAY_STUN_URLS": "stun:relay.example.test:3478",
            "CODEXPORT_RELAY_TURN_URLS": "turn:relay.example.test:3478?transport=udp turn:relay.example.test:3478?transport=tcp",
            "CODEXPORT_RELAY_TURN_TTL_SECONDS": "600",
            "CODEXPORT_RELAY_WEBRTC_DATA_CHANNEL_LABEL": "codexport-test-channel",
        ]
    )

    #expect(configuration.listenHost == "0.0.0.0")
    #expect(configuration.listenPort == 8_080)
    #expect(configuration.publicBaseURL == URL(string: "https://relay.example.test")!)
    #expect(configuration.storagePath == "/var/lib/codexport-relay")
    #expect(configuration.logLevel == "info")
    #expect(configuration.tlsMode == .reverseProxy)
    #expect(configuration.turnSharedSecret == "turn-shared-secret")
    #expect(configuration.stunURLs == ["stun:relay.example.test:3478"])
    #expect(configuration.turnURLs == [
        "turn:relay.example.test:3478?transport=udp",
        "turn:relay.example.test:3478?transport=tcp",
    ])
    #expect(configuration.turnCredentialTTL == .seconds(600))
    #expect(configuration.webRTCDataChannelLabel == "codexport-test-channel")
    #expect(configuration.streamEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
    #expect(configuration.hostConnectURL == URL(string: "wss://relay.example.test/v0/host/connect")!)
    #expect(configuration.pairingConsumeURL == URL(string: "https://relay.example.test/v0/pairing/consume")!)
}

@Test func relayServiceConfigurationDefaultsTURNURLsFromPublicBaseURLAndBuildsICEProvider() throws {
    let configuration = try RelayServiceConfiguration(
        arguments: ["codexport-relay"],
        environment: [
            "CODEXPORT_RELAY_PUBLIC_BASE_URL": "https://codexport.smarteffi.net",
            "CODEXPORT_RELAY_TURN_SHARED_SECRET": "turn-shared-secret",
        ]
    )

    #expect(configuration.stunURLs == ["stun:codexport.smarteffi.net:3478"])
    #expect(configuration.turnURLs == [
        "turn:codexport.smarteffi.net:3478?transport=udp",
        "turn:codexport.smarteffi.net:3478?transport=tcp",
    ])
    #expect(configuration.turnCredentialTTL == .seconds(600))

    let response = try configuration.makeICEConfigurationProvider().issueICEConfiguration(
        for: RelayP2PICEConfigurationContext(
            hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            pairingRecordID: "pairing-record",
            issuedAt: Date(timeIntervalSince1970: 1_000)
        )
    )

    #expect(response.expiresAtUnixTime == 1_600)
    #expect(response.configuration.iceServers[1].username == "1600:pairing-record")
    #expect(response.configuration.iceServers[1].credential != nil)
    #expect(!String(describing: response).contains(response.configuration.iceServers[1].credential ?? ""))
}

@Test func relayServiceConfigurationRejectsInvalidPortsAndPublicBaseURL() {
    #expect(throws: RelayServiceConfigurationError.invalidPort("70000")) {
        _ = try RelayServiceConfiguration(
            arguments: ["codexport-relay", "--port", "70000"],
            environment: ["CODEXPORT_RELAY_PUBLIC_BASE_URL": "https://relay.example.test"]
        )
    }

    #expect(throws: RelayServiceConfigurationError.invalidPublicBaseURL("not a url")) {
        _ = try RelayServiceConfiguration(
            arguments: ["codexport-relay"],
            environment: ["CODEXPORT_RELAY_PUBLIC_BASE_URL": "not a url"]
        )
    }
}
