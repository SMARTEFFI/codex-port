import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

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

@Test func fileBackedHostProfileRepositoryPersistsRelayHostsWithoutSSHSecrets() throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let url = directory.appending(path: "profiles.json")
    let repository = FileHostProfileRepository(fileURL: url)
    let hostAgentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let profile = HostProfile(
        id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostAgentID,
                displayName: "Mac Studio Agent",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
                presence: .online(activeConnectionCount: 2),
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
        defaultDirectory: "~/Projects",
        knownHostFingerprint: nil
    )

    try repository.save([profile])

    let rawJSON = try String(contentsOf: url, encoding: .utf8)
    #expect(rawJSON.contains("pairing-record"))
    #expect(rawJSON.contains("Mac Studio Agent"))
    #expect(!rawJSON.contains("secret-password"))
    #expect(!rawJSON.contains("private-key"))
    #expect(!rawJSON.contains("bearer-token"))
    #expect(try repository.load() == [profile])
    #expect(try repository.load().first?.connectionMethod.relayHost?.relayEndpointURL == URL(string: "wss://relay.example.test/v0/streams")!)
}

@Test func persistentHostProfileStoreSeedsRelayHostOnlyOnceForAFKVerification() throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    let repository = FileHostProfileRepository(fileURL: directory.appending(path: "profiles.json"))
    let store = try PersistentHostProfileStore(repository: repository, credentialVault: InMemoryCredentialVault())
    let seed = try RelayHostLaunchSeed(environment: [
        "CODEXPORT_IOS_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
        "CODEXPORT_IOS_RELAY_HOST_NAME": "Mac Studio Relay",
        "CODEXPORT_IOS_RELAY_HOST_USER": "chenm",
        "CODEXPORT_IOS_RELAY_DEVICE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID": "pairing-record",
        "CODEXPORT_IOS_RELAY_ENDPOINT_URL": "ws://127.0.0.1:7788/v0/streams",
    ])

    let first = try store.seedRelayHostIfNeeded(seed)
    let second = try store.seedRelayHostIfNeeded(seed)

    #expect(first != nil)
    #expect(second == nil)
    #expect(store.list().count == 1)
    #expect(store.list().first?.connectionMethod.relayHost?.pairingRecordID == "pairing-record")
    #expect(store.list().first?.connectionMethod.relayHost?.relayEndpointURL == URL(string: "ws://127.0.0.1:7788/v0/streams"))
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
