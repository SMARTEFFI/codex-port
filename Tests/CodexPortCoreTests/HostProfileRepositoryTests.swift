import Foundation
import Testing
@testable import CodexPortCore

@Test func fileBackedHostProfileRepositoryPersistsProfilesWithoutSecretMaterial() throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let url = directory.appending(path: "profiles.json")
    let repository = FileHostProfileRepository(fileURL: url)

    let profile = HostProfile(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "root",
        auth: .password(credentialID: "credential-1"),
        codexPath: "codex",
        startupCommand: "codex app-server daemon start && codex app-server proxy",
        defaultDirectory: "~/Projects",
        knownHostFingerprint: "SHA256:abc"
    )

    try repository.save([profile])
    let rawJSON = try String(contentsOf: url, encoding: .utf8)
    #expect(rawJSON.contains("credential-1"))
    #expect(!rawJSON.contains("secret-password"))

    let loaded = try repository.load()
    #expect(loaded == [profile])
}

@Test func persistentHostProfileStoreCreatesUpdatesDeletesAndPersistsProfiles() throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let url = directory.appending(path: "profiles.json")
    let repository = FileHostProfileRepository(fileURL: url)
    let vault = InMemoryCredentialVault()
    let store = try PersistentHostProfileStore(repository: repository, credentialVault: vault)

    let profile = try store.create(HostProfileDraft(
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "root",
        auth: .password("secret-password", protection: .localEncrypted),
        codexPath: "codex",
        startupCommand: "codex app-server daemon restart && rm -rf ~/.codex/app-server-control",
        defaultDirectory: "~"
    ))
    let originalCredentialID = profile.auth.credentialID
    #expect(profile.startupCommand == AppServerStartupCommand(codexPath: "codex").shellCommand)
    #expect(!profile.startupCommand.contains("daemon restart"))
    #expect(!profile.startupCommand.contains("rm -rf"))

    let reloaded = try PersistentHostProfileStore(repository: repository, credentialVault: vault)
    #expect(reloaded.list().map(\.id) == [profile.id])
    #expect(reloaded.list().first?.auth.credentialID == profile.auth.credentialID)

    let trustedBeforeEdit = try reloaded.markKnownHostTrusted(id: profile.id, fingerprint: "SHA256:trusted")
    #expect(trustedBeforeEdit.knownHostFingerprint == "SHA256:trusted")
    #expect(try repository.load().first?.knownHostFingerprint == "SHA256:trusted")

    let updated = try reloaded.update(profile.id, with: HostProfileDraft(
        name: "Mac",
        host: "mac.local",
        port: 2222,
        username: "chenm",
        auth: .key(label: "id_ed25519", privateKey: "raw-private-key", protection: .localEncrypted),
        codexPath: "/opt/homebrew/bin/codex",
        startupCommand: AppServerStartupCommand(codexPath: "/opt/homebrew/bin/codex").shellCommand,
        defaultDirectory: "~/Projects"
    ))
    #expect(updated.name == "Mac")
    #expect(updated.auth.credentialID != nil)
    #expect(vault.rawStoredSecret(id: updated.auth.credentialID!) == "raw-private-key")
    #expect(vault.rawStoredSecret(id: originalCredentialID!) == nil)
    #expect(updated.knownHostFingerprint == "SHA256:trusted")
    #expect(try repository.load().first?.name == "Mac")
    let storedJSON = try String(contentsOf: url, encoding: .utf8)
    #expect(!storedJSON.contains("raw-private-key"))
    #expect(!storedJSON.contains("daemon restart"))
    #expect(!storedJSON.contains("rm -rf"))

    let metadataOnlyUpdate = try reloaded.update(profile.id, with: HostProfileDraft(
        name: "Mac Studio",
        host: "mac-studio.local",
        port: 2222,
        username: "chenm",
        auth: .existingKey(label: "id_ed25519", credentialID: updated.auth.credentialID!),
        codexPath: "/opt/homebrew/bin/codex",
        startupCommand: AppServerStartupCommand(codexPath: "/opt/homebrew/bin/codex").shellCommand,
        defaultDirectory: "~/Projects"
    ))
    #expect(metadataOnlyUpdate.auth == .key(label: "id_ed25519", credentialID: updated.auth.credentialID!))
    #expect(vault.rawStoredSecret(id: updated.auth.credentialID!) == "raw-private-key")
    #expect(metadataOnlyUpdate.knownHostFingerprint == "SHA256:trusted")

    try reloaded.delete(profile.id)
    #expect(try repository.load() == [])
}

@Test func fileBackedKnownHostStorePersistsTrustedFingerprintsAcrossVerifierInstances() throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let url = directory.appending(path: "known-hosts.json")
    let store = FileKnownHostStore(fileURL: url)
    let profileID = UUID()

    var verifier = try PersistentKnownHostVerifier(store: store)
    #expect(verifier.evaluate(profileID: profileID, presentedFingerprint: "SHA256:first") == .needsUserConfirmation("SHA256:first"))
    try verifier.trust(profileID: profileID, fingerprint: "SHA256:first")

    verifier = try PersistentKnownHostVerifier(store: store)
    #expect(verifier.evaluate(profileID: profileID, presentedFingerprint: "SHA256:first") == .trusted)
    #expect(verifier.evaluate(profileID: profileID, presentedFingerprint: "SHA256:changed") == .changed(expected: "SHA256:first", presented: "SHA256:changed"))
}

@Test func localEncryptedCredentialVaultPersistsSecretsWithoutPlaintextAndReadsWithoutAuthorizationPrompt() throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let vault = try LocalEncryptedCredentialVault(directory: directory)

    let credentialID = try vault.saveSecret("secret-password", protection: .localEncrypted)

    let rawCredentials = try String(contentsOf: directory.appending(path: "credentials.json"), encoding: .utf8)
    #expect(rawCredentials.contains(credentialID))
    #expect(!rawCredentials.contains("secret-password"))
    #expect(try vault.readSecret(id: credentialID, authorization: .denied) == "secret-password")

    let reloaded = try LocalEncryptedCredentialVault(directory: directory)
    #expect(try reloaded.readSecret(id: credentialID, authorization: .granted) == "secret-password")

    try reloaded.deleteSecret(id: credentialID)
    #expect(throws: CredentialVaultError.notFound) {
        try reloaded.readSecret(id: credentialID, authorization: .granted)
    }
}
