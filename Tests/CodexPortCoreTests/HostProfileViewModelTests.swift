import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

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

@Test func hostProfileFormRoundTripsRelayHostWithoutSSHCredential() throws {
    let hostAgentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayEndpointURL = try #require(URL(string: "ws://127.0.0.1:7788/v0/streams"))
    let profile = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostAgentID,
                displayName: "Mac Studio Agent",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                deviceID: deviceID,
                relayEndpointURL: relayEndpointURL,
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
        defaultDirectory: "~/Projects",
        knownHostFingerprint: nil
    )

    let form = HostProfileFormModel(profile: profile)
    let draft = try form.makeDraft()

    #expect(draft.connectionMethod == .relay(
        RelayHostDraft(
            hostAgentID: hostAgentID,
            displayName: "Mac Studio Agent",
            userName: "chenm",
            pairingRecordID: "pairing-record",
            deviceID: deviceID,
            relayEndpointURL: relayEndpointURL,
            presence: .offline(),
            diagnosticsSummary: "Not connected"
        )
    ))
    #expect(draft.auth == .none)
}

@Test func hostProfileFormBuildsRelayPairingInputWithoutDirectSSHFields() throws {
    var form = HostProfileFormModel()
    form.selectRelayConnection()
    form.name = "CodexPort Dev Mac"
    form.host = ""
    form.port = ""
    form.username = ""
    form.pairingMaterial = "codexport://pair?token=pairing-token-ios"
    form.deviceDisplayName = "iPhone 17 Pro"

    let input = try form.makeRelayPairingInput(defaultDeviceDisplayName: "Fallback iPhone")

    #expect(form.relayServerEndpoint.isEmpty)
    #expect(input.relayBaseURL == URL(string: "https://codexport.smarteffi.net")!)
    #expect(input.pairingTokenID == "pairing-token-ios")
    #expect(input.deviceDisplayName == "iPhone 17 Pro")
    #expect(input.streamEndpointURL == URL(string: "wss://codexport.smarteffi.net/v0/streams")!)
}
