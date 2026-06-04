import Foundation
import Testing
@testable import CodexPortCore

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
