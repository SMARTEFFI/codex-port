import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayHostProductionPairingClientConsumesTokenAndBuildsRelayHostDraft() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let input = try RelayHostProductionPairingInput(
        relayServerEndpoint: "https://relay.example.test",
        pairingMaterial: "codexport://pair?token=pairing-token-ios",
        deviceDisplayName: "iPhone A"
    )
    let client = RelayHostProductionPairingClient(
        deviceID: deviceID,
        devicePublicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8)),
        httpClient: RelayHostProductionPairingRecordingHTTPClient(response: RelayPairingConsumeResponse(
            tokenID: "pairing-token-ios",
            hostID: hostID,
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString(),
            deviceID: deviceID,
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            selectedVersion: .v0_2_0,
            activeConnectionCount: 1
        ))
    )

    let draft = try await client.pair(
        input,
        codexPath: "codex",
        defaultDirectory: "~/Projects",
        profileName: "m5mba"
    )

    #expect(draft.name == "m5mba")
    #expect(draft.connectionMethod.relayDraft?.relayEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
    #expect(draft.connectionMethod.relayDraft?.displayName == "Mac Studio")
    #expect(draft.connectionMethod.relayDraft?.pairingRecordID == "pairing-\(hostID.uuidString)-\(deviceID.uuidString)")
    #expect(draft.auth == .none)
}

private final class RelayHostProductionPairingRecordingHTTPClient: RelayHostProductionPairingHTTPClient, @unchecked Sendable {
    let response: RelayPairingConsumeResponse
    private(set) var requestedURL: URL?
    private(set) var request: RelayPairingConsumeRequest?

    init(response: RelayPairingConsumeResponse) {
        self.response = response
    }

    func consume(_ request: RelayPairingConsumeRequest, at url: URL) async throws -> RelayPairingConsumeResponse {
        self.request = request
        self.requestedURL = url
        return response
    }
}

private extension HostConnectionMethodDraft {
    var relayDraft: RelayHostDraft? {
        switch self {
        case .directSSH:
            nil
        case let .relay(draft):
            draft
        }
    }
}
