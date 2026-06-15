import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func userCanManageHostProfilesWithoutLeakingSavedPassword() throws {
    let vault = InMemoryCredentialVault()
    let store = HostProfileStore(credentialVault: vault)

    let saved = try store.create(
        HostProfileDraft(
            name: "Public VPS",
            host: "203.0.113.10",
            port: 2222,
            username: "deploy",
            auth: .password("secret-password", protection: .localEncrypted),
            codexPath: "/opt/homebrew/bin/codex",
            startupCommand: "codex app-server daemon start && codex app-server proxy",
            defaultDirectory: "~/Projects"
        )
    )

    #expect(saved.name == "Public VPS")
    #expect(saved.startupCommand == AppServerStartupCommand(codexPath: "/opt/homebrew/bin/codex").shellCommand)
    #expect(!saved.startupCommand.contains("daemon"))
    #expect(!saved.startupCommand.contains("proxy"))
    #expect(saved.auth == .password(credentialID: saved.auth.credentialID!))
    #expect(vault.rawStoredSecret(id: saved.auth.credentialID!) == "secret-password")
    #expect(try vault.readSecret(id: saved.auth.credentialID!, authorization: .denied) == "secret-password")
    #expect(try vault.readSecret(id: saved.auth.credentialID!, authorization: .granted) == "secret-password")

    let edited = try store.update(
        saved.id,
        with: HostProfileDraft(
            name: "Mac Studio",
            host: "mac-studio.local",
            port: 22,
            username: "chenm",
            auth: .key(label: "id_ed25519", privateKey: "raw-private-key", protection: .localEncrypted),
            codexPath: "codex",
            startupCommand: "codex app-server daemon start && codex app-server proxy",
            defaultDirectory: "~/Code"
        )
    )

    #expect(edited.name == "Mac Studio")
    #expect(edited.startupCommand == AppServerStartupCommand(codexPath: "codex").shellCommand)
    guard case let .key(label, credentialID) = edited.auth else {
        Issue.record("Expected key auth")
        return
    }
    #expect(label == "id_ed25519")
    #expect(vault.rawStoredSecret(id: credentialID) == "raw-private-key")
    #expect(store.list().map(\.id) == [saved.id])

    try store.delete(saved.id)
    #expect(store.list().isEmpty)
}

@Test func hostCredentialResolverReadsSavedPrivateKeyForSSHConnection() throws {
    let vault = InMemoryCredentialVault()
    let privateKeyID = try vault.saveSecret("raw-private-key", protection: .localEncrypted)
    let profile = HostProfile(
        id: UUID(),
        name: "Mac",
        host: "mac.local",
        port: 22,
        username: "chenm",
        auth: .key(label: "id_ed25519", credentialID: privateKeyID),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )

    let resolver = HostCredentialResolver(vault: vault)

    #expect(try resolver.resolve(profile, authorization: .granted) == .key(Data("raw-private-key".utf8)))
    #expect(try resolver.resolve(profile, authorization: .denied) == .key(Data("raw-private-key".utf8)))
}

@Test func hostKeyVerificationStoresFirstFingerprintAndBlocksChanges() throws {
    let verifier = KnownHostVerifier()
    let profileID = UUID()

    #expect(verifier.evaluate(profileID: profileID, presentedFingerprint: "SHA256:first") == .needsUserConfirmation("SHA256:first"))
    verifier.trust(profileID: profileID, fingerprint: "SHA256:first")

    #expect(verifier.evaluate(profileID: profileID, presentedFingerprint: "SHA256:first") == .trusted)
    #expect(verifier.evaluate(profileID: profileID, presentedFingerprint: "SHA256:changed") == .changed(expected: "SHA256:first", presented: "SHA256:changed"))
}

@Test func hostProfileStoreDoesNotPersistDraftStartupCommand() throws {
    let vault = InMemoryCredentialVault()
    let store = HostProfileStore(credentialVault: vault)

    let saved = try store.create(
        HostProfileDraft(
            name: "Mac",
            host: "mac.local",
            port: 22,
            username: "chenm",
            auth: .password("secret-password", protection: .localEncrypted),
            codexPath: "codex",
            startupCommand: "codex app-server daemon restart && rm -rf ~/.codex/app-server-control",
            defaultDirectory: "~"
        )
    )

    #expect(saved.startupCommand == AppServerStartupCommand(codexPath: "codex").shellCommand)
    #expect(!saved.startupCommand.contains("daemon restart"))
    #expect(!saved.startupCommand.contains("rm -rf"))
}

@Test func hostProfileStoreKeepsDirectSSHAndRelayHostsIndependentForTheSameMac() throws {
    let vault = InMemoryCredentialVault()
    let store = HostProfileStore(credentialVault: vault)
    let relayHostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    let direct = try store.create(
        HostProfileDraft(
            connectionMethod: .directSSH,
            name: "Mac Studio SSH",
            host: "mac-studio.local",
            port: 22,
            username: "chenm",
            auth: .password("secret-password", protection: .localEncrypted),
            codexPath: "codex",
            startupCommand: "codex app-server --listen stdio://",
            defaultDirectory: "~/Projects"
        )
    )
    let relay = try store.create(
        HostProfileDraft(
            connectionMethod: .relay(
                RelayHostDraft(
                    hostAgentID: relayHostID,
                    displayName: "Mac Studio Agent",
                    userName: "chenm",
                    pairingRecordID: "pairing-record",
                    presence: .offline(),
                    diagnosticsSummary: "Not connected"
                )
            ),
            name: "Mac Studio Relay",
            host: "mac-studio.local",
            port: 22,
            username: "chenm",
            auth: .none,
            codexPath: "codex",
            startupCommand: "",
            defaultDirectory: "~/Projects"
        )
    )

    try store.trustKnownHost(profileID: direct.id, fingerprint: "SHA256:direct")
    let editedRelay = try store.update(
        relay.id,
        with: HostProfileDraft(
            connectionMethod: .relay(
                RelayHostDraft(
                    hostAgentID: relayHostID,
                    displayName: "Mac Studio Agent Renamed",
                    userName: "chenm",
                    pairingRecordID: "pairing-record",
                    presence: .online(activeConnectionCount: 1),
                    diagnosticsSummary: "Host Agent online"
                )
            ),
            name: "Mac Studio Relay",
            host: "mac-studio.local",
            port: 22,
            username: "chenm",
            auth: .none,
            codexPath: "codex",
            startupCommand: "",
            defaultDirectory: "~/Projects"
        )
    )

    let profiles = store.list()
    #expect(profiles.map(\.name) == ["Mac Studio SSH", "Mac Studio Relay"])
    #expect(profiles[0].connectionMethod == .directSSH)
    #expect(profiles[0].auth.credentialID == direct.auth.credentialID)
    #expect(vault.rawStoredSecret(id: direct.auth.credentialID!) == "secret-password")
    #expect(profiles[0].knownHostFingerprint == "SHA256:direct")
    #expect(editedRelay.connectionMethod.relayHost?.displayName == "Mac Studio Agent Renamed")
    #expect(editedRelay.connectionMethod.relayHost?.presence == .online(activeConnectionCount: 1))
    #expect(editedRelay.auth == .none)
    #expect(editedRelay.knownHostFingerprint == nil)
}

@Test func hostConnectionMethodReportsRelayState() {
    let relay = RelayHost(
        hostAgentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        presence: .offline(lastSeenAt: nil),
        diagnosticsSummary: "paired"
    )

    #expect(HostConnectionMethod.directSSH.isRelay == false)
    #expect(HostConnectionMethod.relay(relay).isRelay == true)
}
