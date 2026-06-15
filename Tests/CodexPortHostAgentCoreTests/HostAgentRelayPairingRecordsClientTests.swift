import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentRelayConfigurationDerivesPairingRecordsURL() throws {
    let configuration = try HostAgentRelayConfiguration(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        host: RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
    )

    #expect(configuration.pairingRecordsURL == URL(
        string: "https://relay.example.test/v0/hosts/11111111-2222-3333-4444-555555555555/pairings"
    )!)
}

@Test func hostAgentRelayPairingRecordsClientMapsRelayRecordsToMenuDevices() async throws {
    let configuration = try HostAgentRelayConfiguration(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        host: RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
    )
    let httpClient = RecordingHostAgentRelayPairingRecordsHTTPClient(response: RelayHostPairingRecordsResponse(
        devices: [
            RelayPairedDeviceSummary(
                pairingRecordID: "pairing-active",
                deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                deviceDisplayName: "iPhone A",
                pairedAtUnixTime: 100,
                activeConnectionCount: 1,
                revokedAtUnixTime: nil
            ),
            RelayPairedDeviceSummary(
                pairingRecordID: "pairing-paired",
                deviceID: UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                deviceDisplayName: "iPhone Paired",
                pairedAtUnixTime: 95,
                activeConnectionCount: 0,
                revokedAtUnixTime: nil
            ),
            RelayPairedDeviceSummary(
                pairingRecordID: "pairing-revoked",
                deviceID: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                deviceDisplayName: "iPhone B",
                pairedAtUnixTime: 90,
                activeConnectionCount: 0,
                revokedAtUnixTime: 110
            ),
        ]
    ))
    let client = HostAgentRelayPairingRecordsClient(configuration: configuration, httpClient: httpClient)

    let devices = try await client.pairedDevices()

    #expect(httpClient.requestedURL == URL(
        string: "https://relay.example.test/v0/hosts/11111111-2222-3333-4444-555555555555/pairings"
    )!)
    #expect(devices == [
        HostAgentMenuPairedDevice(
            id: "pairing-active",
            displayName: "iPhone A",
            status: .connected(activeConnectionCount: 1),
            pairedAt: Date(timeIntervalSince1970: 100),
            lastActiveAt: nil,
            management: .revoke(pairingRecordID: "pairing-active")
        ),
        HostAgentMenuPairedDevice(
            id: "pairing-paired",
            displayName: "iPhone Paired",
            status: .paired,
            pairedAt: Date(timeIntervalSince1970: 95),
            lastActiveAt: nil,
            management: .revoke(pairingRecordID: "pairing-paired")
        ),
    ])
}

@Test func hostAgentRelayPairingRecordsClientRevokesDevicePairing() async throws {
    let configuration = try HostAgentRelayConfiguration(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        host: RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
    )
    let httpClient = RecordingHostAgentRelayPairingRecordsHTTPClient(response: RelayHostPairingRecordsResponse(devices: []))
    let client = HostAgentRelayPairingRecordsClient(configuration: configuration, httpClient: httpClient)

    try await client.revokePairing(recordID: "pairing-active")

    #expect(httpClient.revokedURL == URL(
        string: "https://relay.example.test/v0/hosts/11111111-2222-3333-4444-555555555555/pairings/pairing-active/revoke"
    )!)
}

private final class RecordingHostAgentRelayPairingRecordsHTTPClient: HostAgentRelayPairingRecordsHTTPClient, @unchecked Sendable {
    private(set) var requestedURL: URL?
    private(set) var revokedURL: URL?
    private let response: RelayHostPairingRecordsResponse

    init(response: RelayHostPairingRecordsResponse) {
        self.response = response
    }

    func fetchPairingRecords(at url: URL) async throws -> RelayHostPairingRecordsResponse {
        requestedURL = url
        return response
    }

    func revokePairingRecord(at url: URL) async throws {
        revokedURL = url
    }
}
