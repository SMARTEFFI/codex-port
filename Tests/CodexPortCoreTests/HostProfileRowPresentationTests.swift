import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayHostRowPresentationDoesNotTreatPresenceOnlineAsReady() {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let loading = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostID,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .online(activeConnectionCount: 2),
                readiness: .loading(stage: .threadList),
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
    let ready = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostID,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .online(activeConnectionCount: 2),
                readiness: .ready(loadedThreadCount: 3),
                diagnosticsSummary: "Host Agent ready"
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
                readiness: .offline(lastSeenAt: Date(timeIntervalSince1970: 100)),
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

    #expect(HostProfileRowPresentation(profile: loading) == HostProfileRowPresentation(
        title: "Mac Studio Relay",
        subtitle: "Mac: Mac Studio Relay · chenm",
        statusText: "读取会话中...",
        statusKind: .loading,
        canOpenWorkspaces: false
    ))
    #expect(HostProfileRowPresentation(profile: ready) == HostProfileRowPresentation(
        title: "Mac Studio Relay",
        subtitle: "Mac: Mac Studio Relay · chenm",
        statusText: "在线",
        statusKind: .online
    ))
    #expect(HostProfileRowPresentation(profile: offline) == HostProfileRowPresentation(
        title: "Mac Studio Relay",
        subtitle: "Mac: Mac Studio Relay · chenm",
        statusText: "离线 · 最后在线 1970-01-01 00:01:40Z",
        statusKind: .offline,
        canOpenWorkspaces: true
    ))
}

@Test func relayHostRowPresentationTreatsFreshOnlinePairingAsOpenable() {
    let profile = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .online(activeConnectionCount: 1),
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

    let presentation = HostProfileRowPresentation(profile: profile)
    #expect(presentation.statusText == "在线")
    #expect(presentation.statusKind == .online)
    #expect(presentation.canOpenWorkspaces)
}

@Test func relayHostRowPresentationShowsActionableFailureWithoutConnectionLogSheet() {
    let profile = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .online(activeConnectionCount: 1),
                readiness: .failed(reason: .threadListTimeout, message: "读取会话列表超时"),
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

    #expect(HostProfileRowPresentation(profile: profile).statusText == "读取会话列表超时")
    #expect(HostProfileRowPresentation(profile: profile).statusKind == .failed)
    #expect(HostProfileRowPresentation(profile: profile).canOpenWorkspaces)
}

@Test func relayHostRowPresentationShowsRemoteConnectionPathSummaryWhenAvailable() {
    var path = RemoteConnectionPathState.fromPresence(
        .online(activeConnectionCount: 1),
        authorization: .authorizedToSignal(pairingRecordID: "pairing-record")
    )
    path.apply(.iceGathering)
    path.apply(.turnRelayedConnected)
    path.apply(.dataChannelOpen)
    path.markDirectProbeActive(reason: "relay fallback")
    let profile = HostProfile(
        id: UUID(),
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                displayName: "Mac Studio",
                userName: "chenm",
                pairingRecordID: "pairing-record",
                presence: .online(activeConnectionCount: 1),
                readiness: .ready(loadedThreadCount: 3),
                diagnosticsSummary: "Host Agent ready",
                connectionPathState: path
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

    #expect(HostProfileRowPresentation(profile: profile).statusText == "中转 · 尝试直连中")
    #expect(HostProfileRowPresentation(profile: profile).statusKind == .online)
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
