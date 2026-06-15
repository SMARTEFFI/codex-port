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
        ]
    )

    #expect(configuration.listenHost == "0.0.0.0")
    #expect(configuration.listenPort == 8_080)
    #expect(configuration.publicBaseURL == URL(string: "https://relay.example.test")!)
    #expect(configuration.storagePath == "/var/lib/codexport-relay")
    #expect(configuration.logLevel == "info")
    #expect(configuration.tlsMode == .reverseProxy)
    #expect(configuration.streamEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
    #expect(configuration.hostConnectURL == URL(string: "wss://relay.example.test/v0/host/connect")!)
    #expect(configuration.pairingConsumeURL == URL(string: "https://relay.example.test/v0/pairing/consume")!)
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
