import Foundation
import Testing
@testable import CodexPortCore

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
