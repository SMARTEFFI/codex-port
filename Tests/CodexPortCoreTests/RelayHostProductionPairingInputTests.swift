import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayHostProductionPairingInputParsesManualAndQRMaterialsWithEndpointValidation() throws {
    let productionDefault = try RelayHostProductionPairingInput(
        pairingMaterial: "production-token",
        deviceDisplayName: "iPhone A"
    )

    #expect(productionDefault.relayBaseURL == URL(string: "https://codexport.smarteffi.net")!)
    #expect(productionDefault.streamEndpointURL == URL(string: "wss://codexport.smarteffi.net/v0/streams")!)
    #expect(productionDefault.pairingConsumeURL == URL(string: "https://codexport.smarteffi.net/v0/pairing/consume")!)

    let manual = try RelayHostProductionPairingInput(
        relayServerEndpoint: "https://relay.example.test",
        pairingMaterial: "123-456",
        deviceDisplayName: "iPhone A"
    )

    #expect(manual.relayBaseURL == URL(string: "https://relay.example.test")!)
    #expect(manual.streamEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
    #expect(manual.pairingTokenID == "123-456")
    #expect(manual.safeEndpointSummary == "relay.example.test")

    let qr = try RelayHostProductionPairingInput(
        relayServerEndpoint: "https://relay.example.test",
        pairingMaterial: "codexport://pair?token=pairing-token-qr",
        deviceDisplayName: "iPhone A"
    )

    #expect(qr.pairingTokenID == "pairing-token-qr")
}

@Test func relayHostProductionPairingInputRejectsInvalidEndpointAndMissingToken() {
    #expect(throws: RelayHostProductionPairingInputError.invalidRelayEndpoint("ftp://relay.example.test")) {
        _ = try RelayHostProductionPairingInput(
            relayServerEndpoint: "ftp://relay.example.test",
            pairingMaterial: "123-456",
            deviceDisplayName: "iPhone A"
        )
    }

    #expect(throws: RelayHostProductionPairingInputError.missingPairingToken) {
        _ = try RelayHostProductionPairingInput(
            relayServerEndpoint: "https://relay.example.test",
            pairingMaterial: "codexport://pair",
            deviceDisplayName: "iPhone A"
        )
    }
}

@Test func relayHostProductionPairingInputBuildsRelayHostDraftFromPairingResult() throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let input = try RelayHostProductionPairingInput(
        relayServerEndpoint: "https://relay.example.test",
        pairingMaterial: "pairing-token",
        deviceDisplayName: "iPhone A"
    )
    let result = RelayPairingResult(
        tokenID: input.pairingTokenID,
        host: RelayHostIdentity(
            id: hostID,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        ),
        device: DeviceIdentity(
            id: deviceID,
            displayName: input.deviceDisplayName,
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        record: PairingRecord(
            id: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            hostID: hostID,
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            pairedAt: Date(timeIntervalSince1970: 10),
            revokedAt: nil
        ),
        negotiatedVersion: .v0_2_0,
        presence: .online(activeConnectionCount: 1)
    )

    let draft = input.makeHostProfileDraft(from: result, codexPath: "codex", defaultDirectory: "~/Projects")

    #expect(draft.connectionMethod.relayDraft?.relayEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
    #expect(draft.connectionMethod.relayDraft?.deviceID == deviceID)
    #expect(draft.auth == .none)
    #expect(draft.startupCommand == "")
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
