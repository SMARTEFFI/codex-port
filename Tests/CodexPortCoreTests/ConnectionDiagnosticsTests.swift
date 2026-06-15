import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func connectionDiagnosticsClassifiesFailuresAcrossSshAndCodexStartup() async {
    let diagnostics = ConnectionDiagnostics()

    #expect(await diagnostics.classify(.networkUnreachable) == .network)
    #expect(await diagnostics.classify(.authenticationRejected) == .authentication)
    #expect(await diagnostics.classify(.hostKeyChanged(expected: "old", presented: "new")) == .hostKeyChanged)
    #expect(await diagnostics.classify(.remoteCommandFailed("codex: command not found")) == .codexMissing)
    #expect(await diagnostics.classify(.remoteCommandFailed("zsh:1: command not found: codex")) == .codexMissing)
    #expect(await diagnostics.classify(.codexVersion("0.132.0")) == .codexTooOld(required: "0.133.0", actual: "0.132.0"))
    #expect(await diagnostics.classify(.proxyHelpUnavailable) == .proxyUnsupported)
    #expect(await diagnostics.classify(.initializeFailed("bad handshake")) == .protocolHandshake)
}

@Test func codexVersionCompatibilityAcceptsMinimumAndWarnsOnNewerVersions() {
    #expect(CodexVersionCompatibility.evaluate("0.132.9") == .tooOld(required: "0.133.0", actual: "0.132.9"))
    #expect(CodexVersionCompatibility.evaluate("0.133.0") == .supported)
    #expect(CodexVersionCompatibility.evaluate("0.134.0") == .untestedNewer("0.134.0"))
}

@Test func diagnosticReportMapsCategoriesToUserVisibleRows() async {
    let diagnostics = ConnectionDiagnostics()

    let report = await diagnostics.report(for: [
        .networkUnreachable,
        .codexVersion("0.132.0"),
        .initializeFailed("bad handshake")
    ])

    #expect(report.rows.map(\.title) == ["SSH 连接", "Codex 版本", "协议握手"])
    #expect(report.rows.map(\.status) == [.failed, .failed, .failed])
    #expect(report.rows[1].message.contains("0.133.0"))
}

@Test func connectionDiagnosticsMapsSSHConnectionErrorsIntoReportRows() async {
    let diagnostics = ConnectionDiagnostics()

    let report = await diagnostics.report(for: SSHConnectionError.hostKeyChanged(expected: "old", presented: "new"))

    #expect(report.rows == [
        DiagnosticRow(title: "Host Key", status: .failed, message: "远端 host key 与已信任记录不一致。确认安全后再重新信任。")
    ])
}

@Test func relayDiagnosticsDistinguishesUnavailableOfflineRevokedAndVersionMismatch() async {
    let diagnostics = ConnectionDiagnostics()
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    #expect(await diagnostics.report(for: RelayDiagnosticFailure.relayUnavailable("network down")).rows == [
        DiagnosticRow(title: "Relay 连接", status: .failed, message: "无法连接 CodexPort Relay：network down")
    ])
    #expect(await diagnostics.report(for: RelayDiagnosticFailure.hostAgentOffline(hostID: hostID, lastSeenAt: Date(timeIntervalSince1970: 100))).rows == [
        DiagnosticRow(title: "Host Agent", status: .failed, message: "Host Agent 离线。最后在线 1970-01-01 00:01:40Z。请检查 Mac 是否开机、联网并运行 CodexPort Host Agent。")
    ])
    #expect(await diagnostics.report(for: RelayPairingError.pairingRecordNotFound(hostID: hostID, deviceID: deviceID)).rows == [
        DiagnosticRow(title: "Pairing", status: .failed, message: "该 iPhone 的 Pairing 已失效或被撤销，请在 Mac Host Agent 上重新配对。")
    ])
    #expect(await diagnostics.report(for: RelayPairingError.versionMismatch(clientSupported: [RelayProtocolVersion(major: 1, minor: 0, patch: 0)], relaySupported: [.v0_2_0])).rows == [
        DiagnosticRow(title: "Relay 版本", status: .failed, message: "Relay protocol 版本不兼容。iOS 支持 [1.0.0]，Relay 支持 [0.2.0]。请升级 iOS app 或 Host Agent。")
    ])
}

@Test func remoteConnectionPathStateMapsToIOSHostAgentMenuAndSupportProbeRows() {
    let state = RemoteConnectionPathState(
        signaling: .reachable,
        ice: .gathering,
        dataPath: .directConnected,
        dataChannel: .open,
        hostProtocol: .failed(reason: "Host protocol handshake timed out."),
        codexLiveSource: .notReady(reason: "Codex Desktop event source disconnected.")
    )

    #expect(state.iosConnectionLogLines == [
        "Signaling: reachable",
        "ICE: gathering",
        "Path: direct connected",
        "DataChannel: open",
        "Host protocol: failed - Host protocol handshake timed out.",
        "Codex live source: not ready - Codex Desktop event source disconnected.",
    ])
    #expect(state.hostAgentMenuItems == [
        "Signaling reachable",
        "DataChannel direct connected",
        "Host protocol failed",
        "Codex live source not ready",
    ])
    #expect(state.supportProbeReport.rows == [
        DiagnosticRow(title: "Signaling", status: .passed, message: "reachable"),
        DiagnosticRow(title: "ICE", status: .notRun, message: "gathering"),
        DiagnosticRow(title: "Connection Path", status: .passed, message: "direct connected"),
        DiagnosticRow(title: "DataChannel", status: .passed, message: "open"),
        DiagnosticRow(title: "Host Protocol", status: .failed, message: "Host protocol handshake timed out."),
        DiagnosticRow(title: "Codex Live Source", status: .failed, message: "Codex Desktop event source disconnected."),
    ])
}

@Test func remoteConnectionPresenceDoesNotImplyHostProtocolReady() {
    let state = RemoteConnectionPathState.fromPresence(
        .online(activeConnectionCount: 0),
        authorization: .authorizedToSignal(pairingRecordID: "pairing-1")
    )

    #expect(state.iosConnectionLogLines == [
        "Signaling: authorized to signal",
        "ICE: not started",
        "Path: not connected",
        "DataChannel: closed",
        "Host protocol: not ready",
        "Codex live source: not ready",
    ])
    #expect(state.supportProbeReport.rows.contains(DiagnosticRow(
        title: "Host Protocol",
        status: .notRun,
        message: "not ready"
    )))
}

@Test func remoteConnectionPathStateAppliesWebRTCDataChannelStateUpdates() {
    var state = RemoteConnectionPathState.fromPresence(
        .online(activeConnectionCount: 1),
        authorization: .authorizedToSignal(pairingRecordID: "pairing-1")
    )

    state.apply(.iceGathering)
    state.apply(.directConnected)
    state.apply(.dataChannelOpen)
    state.markHostProtocolReady()
    state.markCodexLiveSourceReady()

    #expect(state.iosConnectionLogLines == [
        "Signaling: authorized to signal",
        "ICE: gathering",
        "Path: direct connected",
        "DataChannel: open",
        "Host protocol: ready",
        "Codex live source: ready",
    ])

    state.apply(.dataChannelClosed)
    #expect(state.supportProbeReport.rows.contains(DiagnosticRow(
        title: "DataChannel",
        status: .notRun,
        message: "closed"
    )))
}

@Test func remoteConnectionPathStateDistinguishesTurnFallbackSuccessAndFailure() {
    var turnState = RemoteConnectionPathState.fromPresence(
        .online(activeConnectionCount: 1),
        authorization: .authorizedToSignal(pairingRecordID: "pairing-1")
    )
    turnState.apply(.iceGathering)
    turnState.apply(.directFailed(reason: "peer reflexive candidate timed out"))
    turnState.apply(.turnRelayedConnected)
    turnState.apply(.dataChannelOpen)

    #expect(turnState.iosConnectionLogLines.contains("Path: TURN relayed connected"))
    #expect(turnState.hostAgentMenuItems.contains("DataChannel TURN relayed connected"))
    #expect(turnState.supportProbeReport.rows.contains(DiagnosticRow(
        title: "Connection Path",
        status: .passed,
        message: "TURN relayed connected"
    )))

    var failedState = RemoteConnectionPathState.fromPresence(
        .online(activeConnectionCount: 1),
        authorization: .authorizedToSignal(pairingRecordID: "pairing-1")
    )
    failedState.apply(.iceGathering)
    failedState.apply(.directFailed(reason: "symmetric NAT blocked direct candidates"))
    failedState.apply(.turnFailed(reason: "TURN credentials rejected"))

    #expect(failedState.supportProbeReport.rows.contains(DiagnosticRow(
        title: "Connection Path",
        status: .failed,
        message: "TURN failed - TURN credentials rejected"
    )))
    #expect(failedState.iosConnectionLogLines.contains("Path: failed - TURN failed - TURN credentials rejected"))
}

@Test func p2pConnectionRecoveryReplacesStaleDataChannelWithoutClearingLoadedHistory() {
    var recovery = P2PConnectionRecoveryState(
        pathState: RemoteConnectionPathState(
            signaling: .authorizedToSignal,
            ice: .gathering,
            dataPath: .directConnected,
            dataChannel: .open,
            hostProtocol: .ready,
            codexLiveSource: .ready
        ),
        loadedHistoryItems: [
            .userMessage("older question"),
            .assistantMessage("older answer"),
        ]
    )

    recovery.apply(.foregrounded)
    recovery.apply(.staleDataChannelClosed(reason: "app returned from background"))
    recovery.apply(.replacementStarted)
    recovery.apply(.webRTC(.iceGathering))
    recovery.apply(.webRTC(.turnRelayedConnected))
    recovery.apply(.webRTC(.dataChannelOpen))
    recovery.apply(.hostProtocolReady)
    recovery.apply(.codexLiveSourceReady)

    #expect(recovery.status == .completed)
    #expect(recovery.pathState.iosConnectionLogLines.contains("Path: TURN relayed connected"))
    #expect(recovery.loadedHistoryItems == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
    ])
}

@Test func p2pConnectionRecoveryReportsFailedReplacementWithoutMarkingHostProtocolReady() {
    var recovery = P2PConnectionRecoveryState(
        pathState: RemoteConnectionPathState.fromPresence(
            .online(activeConnectionCount: 1),
            authorization: .authorizedToSignal(pairingRecordID: "pairing-1")
        ),
        loadedHistoryItems: [.assistantMessage("cached answer")]
    )

    recovery.apply(.networkChanged)
    recovery.apply(.replacementStarted)
    recovery.apply(.webRTC(.iceGathering))
    recovery.apply(.webRTC(.turnFailed(reason: "TURN allocation timed out")))

    #expect(recovery.status == .failed("TURN allocation timed out"))
    #expect(recovery.pathState.supportProbeReport.rows.contains(DiagnosticRow(
        title: "Host Protocol",
        status: .notRun,
        message: "not ready"
    )))
    #expect(recovery.loadedHistoryItems == [.assistantMessage("cached answer")])
}

@Test func p2pConnectionRecoveryHostAgentWakeRefreshesPresenceAndRequiresReplacement() {
    var recovery = P2PConnectionRecoveryState(
        pathState: RemoteConnectionPathState(
            signaling: .authorizedToSignal,
            ice: .gathering,
            dataPath: .directConnected,
            dataChannel: .open,
            hostProtocol: .ready,
            codexLiveSource: .ready
        ),
        loadedHistoryItems: [.assistantMessage("cached answer")]
    )

    recovery.apply(.hostAgentWoke(
        presence: .online(activeConnectionCount: 0),
        authorization: .authorizedToSignal(pairingRecordID: "pairing-1")
    ))

    #expect(recovery.status == .replacingStaleConnection)
    #expect(recovery.pathState.iosConnectionLogLines == [
        "Signaling: authorized to signal",
        "ICE: not started",
        "Path: not connected",
        "DataChannel: closed",
        "Host protocol: not ready",
        "Codex live source: not ready",
    ])
    #expect(recovery.loadedHistoryItems == [.assistantMessage("cached answer")])
}

@MainActor
@Test func connectionDiagnosticRunnerRunsCodexPreflightAndReportsSuccess() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = try vault.saveSecret("secret", protection: .localEncrypted)
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "deploy",
        auth: .password(credentialID: credentialID),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let driver = FakeSSHDriver()
    let shell = AppServerShellCommand(codexPath: "codex")
    driver.commandResults[shell.versionCommand] = SSHCommandResult(stdout: Data("codex-cli 0.133.0\n".utf8), exitStatus: 0)
    driver.commandResults[shell.appServerHelpCommand] = SSHCommandResult(stdout: Data("app-server help\n".utf8), exitStatus: 0)
    let runner = ConnectionDiagnosticRunner(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
        credentialResolver: HostCredentialResolver(vault: vault)
    )

    let report = await runner.run(profile: profile, decision: .confirmUnknownHost)

    #expect(report.rows.map(\.status) == [.passed, .passed, .passed])
    #expect(driver.commands == [
        shell.versionCommand,
        shell.appServerHelpCommand,
    ])
}

@MainActor
@Test func connectionDiagnosticRunnerClassifiesCodexPreflightFailures() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = try vault.saveSecret("secret", protection: .localEncrypted)
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "deploy",
        auth: .password(credentialID: credentialID),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let driver = FakeSSHDriver()
    let shell = AppServerShellCommand(codexPath: "codex")
    driver.commandResults[shell.versionCommand] = SSHCommandResult(stdout: Data("codex-cli 0.132.9\n".utf8), exitStatus: 0)
    let runner = ConnectionDiagnosticRunner(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier()),
        credentialResolver: HostCredentialResolver(vault: vault)
    )

    let report = await runner.run(profile: profile, decision: .confirmUnknownHost)

    #expect(report.rows == [
        DiagnosticRow(title: "Codex 版本", status: .failed, message: "远端版本 codex-cli 0.132.9\n 低于最低要求 0.133.0。")
    ])
}

@MainActor
@Test func connectionDiagnosticRunnerTimesOutInsteadOfSpinningForever() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = try vault.saveSecret("secret", protection: .localEncrypted)
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "deploy",
        auth: .password(credentialID: credentialID),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let driver = FakeSSHDriver()
    driver.shouldHangHostKey = true
    let runner = ConnectionDiagnosticRunner(
        ssh: SSHConnectionService(driver: driver, knownHosts: KnownHostVerifier(), timeoutSeconds: 0.05),
        credentialResolver: HostCredentialResolver(vault: vault)
    )

    let report = await runner.run(profile: profile, decision: .confirmUnknownHost)

    #expect(report.rows == [
        DiagnosticRow(title: "SSH 连接", status: .failed, message: "连接或远端命令超过 0.05 秒未响应。请检查 host、端口、网络和 SSH 服务。")
    ])
}
