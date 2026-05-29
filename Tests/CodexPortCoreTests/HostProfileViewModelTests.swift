import Foundation
import Testing
@testable import CodexPortCore

@Test func hostProfileFormBuildsPasswordDraftWithAppServerStdioCommand() throws {
    var form = HostProfileFormModel()
    form.name = "Public VPS"
    form.host = "203.0.113.10"
    form.port = "2222"
    form.username = "deploy"
    form.password = "secret-password"
    form.codexPath = "/opt/homebrew/bin/codex"
    form.defaultDirectory = "~/Projects"

    let draft = try form.makeDraft()

    #expect(draft.name == "Public VPS")
    #expect(draft.host == "203.0.113.10")
    #expect(draft.port == 2222)
    #expect(draft.username == "deploy")
    #expect(draft.auth == .password("secret-password", protection: .localEncrypted))
    #expect(draft.codexPath == "/opt/homebrew/bin/codex")
    #expect(draft.startupCommand == AppServerShellCommand(codexPath: "/opt/homebrew/bin/codex").appServerCommand)
    #expect(draft.defaultDirectory == "~/Projects")
}

@Test func hostProfileFormBuildsPrivateKeyDraftWithLabelAndSecretMaterial() throws {
    var form = HostProfileFormModel()
    form.name = "Mac"
    form.host = "mac.local"
    form.port = "22"
    form.username = "chenm"
    form.authMethod = .key
    form.privateKeyLabel = "id_ed25519"
    form.privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nkey\n-----END OPENSSH PRIVATE KEY-----"
    form.codexPath = "codex"
    form.defaultDirectory = "~"

    let draft = try form.makeDraft()

    #expect(draft.auth == .key(
        label: "id_ed25519",
        privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nkey\n-----END OPENSSH PRIVATE KEY-----",
        protection: .localEncrypted
    ))
}

@Test func hostProfileFormCanEditMetadataWithoutReenteringStoredCredential() throws {
    let passwordProfile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "deploy",
        auth: .password(credentialID: "credential-password"),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    var passwordForm = HostProfileFormModel(profile: passwordProfile)
    passwordForm.name = "VPS prod"

    let passwordDraft = try passwordForm.makeDraft()

    #expect(passwordDraft.name == "VPS prod")
    #expect(passwordDraft.auth == HostProfileDraftAuth.existingPassword(credentialID: "credential-password"))

    let keyProfile = HostProfile(
        id: UUID(),
        name: "Mac",
        host: "mac.local",
        port: 22,
        username: "chenm",
        auth: .key(label: "id_ed25519", credentialID: "credential-key"),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    var keyForm = HostProfileFormModel(profile: keyProfile)
    keyForm.privateKeyLabel = "work-key"

    let keyDraft = try keyForm.makeDraft()

    #expect(keyDraft.auth == HostProfileDraftAuth.existingKey(label: "work-key", credentialID: "credential-key"))
}
