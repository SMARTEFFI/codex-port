import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayHostPairingDraftBuilderCreatesRelayHostWithoutSSHCredentials() throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let result = RelayPairingResult(
        tokenID: "pairing-token",
        host: RelayHostIdentity(
            id: hostID,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        ),
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
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
        presence: .online(activeConnectionCount: 0)
    )

    let draft = RelayHostPairingDraftBuilder().makeHostProfileDraft(
        from: result,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        codexPath: "codex",
        defaultDirectory: "~/Projects"
    )
    let store = HostProfileStore(credentialVault: InMemoryCredentialVault())
    let profile = try store.create(draft)
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let repository = FileHostProfileRepository(fileURL: directory.appending(path: "profiles.json"))
    let persistentStore = try PersistentHostProfileStore(repository: repository, credentialVault: InMemoryCredentialVault())
    let persisted = try persistentStore.create(draft)
    let reloaded = try #require(try repository.load().first)

    #expect(draft.name == "Mac Studio Relay")
    #expect(draft.host == "relay://11111111-2222-3333-4444-555555555555")
    #expect(draft.port == 443)
    #expect(draft.username == "chenm")
    #expect(draft.auth == .none)
    #expect(draft.startupCommand == "")
    #expect(profile.auth == .none)
    #expect(profile.startupCommand == "")
    #expect(persisted.auth == .none)
    #expect(persisted.startupCommand == "")
    #expect(reloaded.auth == .none)
    #expect(reloaded.startupCommand == "")
    #expect(profile.knownHostFingerprint == nil)
    #expect(profile.connectionMethod.relayHost == RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 0),
        diagnosticsSummary: "Host Agent online (0 clients)"
    ))
}

@Test func relayHostPairingDraftBuilderPreservesUserEnteredHostProfileName() throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let result = RelayPairingResult(
        tokenID: "pairing-token",
        host: RelayHostIdentity(
            id: hostID,
            displayName: "CodexPort Dev Mac",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        ),
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
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
        presence: .online(activeConnectionCount: 0)
    )

    let draft = RelayHostPairingDraftBuilder().makeHostProfileDraft(
        from: result,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        codexPath: "codex",
        defaultDirectory: "~/Projects",
        profileName: "m5mba"
    )

    #expect(draft.name == "m5mba")
    #expect(draft.connectionMethod.relayDraft?.displayName == "CodexPort Dev Mac")
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
