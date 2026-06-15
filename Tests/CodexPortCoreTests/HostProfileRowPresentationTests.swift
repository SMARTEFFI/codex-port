import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayHostRowPresentationShowsOnlineOfflineLastSeenWithoutActiveConnectionCount() {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let online = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostID,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .online(activeConnectionCount: 2),
                diagnosticsSummary: "Host Agent online"
            )
        ),
        name: "Mac Studio Relay",
        host: "relay://11111111-2222-3333-4444-555555555555",
        port: 443,
        username: "chenm",
        auth: .none,
        codexPath: "codex",
        startupCommand: "",
        defaultDirectory: "~/Projects",
        knownHostFingerprint: nil
    )
    let offline = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostID,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .offline(lastSeenAt: Date(timeIntervalSince1970: 100)),
                diagnosticsSummary: "Host Agent offline"
            )
        ),
        name: "Mac Studio Relay",
        host: "relay://11111111-2222-3333-4444-555555555555",
        port: 443,
        username: "chenm",
        auth: .none,
        codexPath: "codex",
        startupCommand: "",
        defaultDirectory: "~/Projects",
        knownHostFingerprint: nil
    )

    #expect(HostProfileRowPresentation(profile: online) == HostProfileRowPresentation(
        title: "Mac Studio Relay",
        subtitle: "Mac: Mac Studio Relay · chenm",
        statusText: "在线",
        statusKind: .online
    ))
    #expect(HostProfileRowPresentation(profile: offline) == HostProfileRowPresentation(
        title: "Mac Studio Relay",
        subtitle: "Mac: Mac Studio Relay · chenm",
        statusText: "离线 · 最后在线 1970-01-01 00:01:40Z",
        statusKind: .offline
    ))
}

@Test func directSSHRowPresentationKeepsExistingTrustStatus() {
    let untrusted = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "deploy",
        auth: .password(credentialID: "credential"),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    var trusted = untrusted
    trusted.knownHostFingerprint = "SHA256:trusted"

    #expect(HostProfileRowPresentation(profile: untrusted).statusText == "待确认")
    #expect(HostProfileRowPresentation(profile: untrusted).statusKind == .pending)
    #expect(HostProfileRowPresentation(profile: trusted).statusText == "已信任")
    #expect(HostProfileRowPresentation(profile: trusted).statusKind == .trusted)
}
