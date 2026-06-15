import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentRelayPairingPublisherPublishesPairingTokenMetadataOnly() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let configuration = try HostAgentRelayConfiguration(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        host: RelayHostIdentity(
            id: hostID,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
    )
    let httpClient = RecordingHostAgentRelayPairingPublishHTTPClient()
    let publisher = HostAgentRelayPairingPublisher(configuration: configuration, httpClient: httpClient)
    let snapshot = HostAgentMenuPairingSnapshot(
        state: .ready,
        tokenID: "pairing-token-menu",
        pairingKey: "123-456",
        qrPayload: "codexport://pair?token=pairing-token-menu",
        expiresAt: Date(timeIntervalSince1970: 1_600),
        hostID: hostID
    )

    try await publisher.publish(snapshot)

    #expect(httpClient.requestedURL == URL(string: "https://relay.example.test/v0/pairing/publish")!)
    #expect(httpClient.request == RelayPairingPublishRequest(
        tokenID: "pairing-token-menu",
        hostID: hostID,
        expiresAtUnixTime: 1_600,
        manualCode: "123-456",
        hostDisplayName: "Mac Studio",
        hostUserName: "chenm",
        hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
    ))
    #expect(httpClient.request?.manualCode == "123-456")
}

@Test func hostAgentRelayPairingPublisherRejectsIdleSnapshot() async throws {
    let configuration = try HostAgentRelayConfiguration(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        host: RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
    )
    let publisher = HostAgentRelayPairingPublisher(
        configuration: configuration,
        httpClient: RecordingHostAgentRelayPairingPublishHTTPClient()
    )

    await #expect(throws: HostAgentRelayPairingPublisherError.noPairingToken) {
        try await publisher.publish(.idle)
    }
}

private final class RecordingHostAgentRelayPairingPublishHTTPClient: HostAgentRelayPairingPublishHTTPClient, @unchecked Sendable {
    private(set) var requestedURL: URL?
    private(set) var request: RelayPairingPublishRequest?

    func publish(_ request: RelayPairingPublishRequest, at url: URL) async throws {
        self.request = request
        self.requestedURL = url
    }
}
