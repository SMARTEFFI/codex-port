import Foundation
import Testing
@testable import CodexPortHostAgentCore

@Test func hostAgentDiagnosticsReportsReadyCodexCLIAndUserEnvironment() async {
    let runner = HostAgentDiagnosticsRunner(commandRunner: FakeHostAgentCommandRunner(results: [
        "which codex": HostAgentCommandResult(stdout: "/opt/homebrew/bin/codex\n", stderr: "", exitStatus: 0),
        "/opt/homebrew/bin/codex --version": HostAgentCommandResult(stdout: "codex-cli 0.133.0\n", stderr: "", exitStatus: 0),
        "/opt/homebrew/bin/codex proto --help": HostAgentCommandResult(stdout: "proto help\n", stderr: "", exitStatus: 0),
    ]))

    let report = await runner.run(codexPath: "codex", environment: HostAgentUserEnvironment(userName: "chenm", homeDirectory: "/Users/chenm"))

    #expect(report.rows == [
        HostAgentDiagnosticRow(title: "Codex CLI Path", status: .passed, message: "/opt/homebrew/bin/codex"),
        HostAgentDiagnosticRow(title: "Codex CLI Version", status: .passed, message: "codex-cli 0.133.0"),
        HostAgentDiagnosticRow(title: "User Environment", status: .passed, message: "chenm · /Users/chenm"),
        HostAgentDiagnosticRow(title: "CLI Live Session", status: .passed, message: "CLI live session adapter can be prepared."),
    ])
}

@Test func hostAgentDiagnosticsReportsMissingUnsupportedAndSessionStartFailed() async {
    let missingRunner = HostAgentDiagnosticsRunner(commandRunner: FakeHostAgentCommandRunner(results: [
        "which codex": HostAgentCommandResult(stdout: "", stderr: "codex not found", exitStatus: 1),
    ]))
    let unsupportedRunner = HostAgentDiagnosticsRunner(commandRunner: FakeHostAgentCommandRunner(results: [
        "which codex": HostAgentCommandResult(stdout: "/opt/homebrew/bin/codex\n", stderr: "", exitStatus: 0),
        "/opt/homebrew/bin/codex --version": HostAgentCommandResult(stdout: "codex-cli 0.132.9\n", stderr: "", exitStatus: 0),
    ]))
    let sessionFailedRunner = HostAgentDiagnosticsRunner(commandRunner: FakeHostAgentCommandRunner(results: [
        "which codex": HostAgentCommandResult(stdout: "/opt/homebrew/bin/codex\n", stderr: "", exitStatus: 0),
        "/opt/homebrew/bin/codex --version": HostAgentCommandResult(stdout: "codex-cli 0.133.0\n", stderr: "", exitStatus: 0),
        "/opt/homebrew/bin/codex proto --help": HostAgentCommandResult(stdout: "", stderr: "proto unavailable", exitStatus: 2),
    ]))

    let missing = await missingRunner.run(codexPath: "codex", environment: .placeholder)
    let unsupported = await unsupportedRunner.run(codexPath: "codex", environment: .placeholder)
    let sessionFailed = await sessionFailedRunner.run(codexPath: "codex", environment: .placeholder)

    #expect(missing.rows == [
        HostAgentDiagnosticRow(title: "Codex CLI Path", status: .failed, message: "Codex CLI not found. Set an absolute codexPath or install Codex CLI.")
    ])
    #expect(unsupported.rows == [
        HostAgentDiagnosticRow(title: "Codex CLI Path", status: .passed, message: "/opt/homebrew/bin/codex"),
        HostAgentDiagnosticRow(title: "Codex CLI Version", status: .failed, message: "codex-cli 0.132.9 is below minimum 0.133.0."),
    ])
    #expect(sessionFailed.rows == [
        HostAgentDiagnosticRow(title: "Codex CLI Path", status: .passed, message: "/opt/homebrew/bin/codex"),
        HostAgentDiagnosticRow(title: "Codex CLI Version", status: .passed, message: "codex-cli 0.133.0"),
        HostAgentDiagnosticRow(title: "User Environment", status: .passed, message: "unknown · ~"),
        HostAgentDiagnosticRow(title: "CLI Live Session", status: .failed, message: "proto unavailable"),
    ])
}

@Test func hostAgentLiveSyncDiagnosticsRejectsPersistedHistoryOnlySources() {
    let execJSONReport = HostAgentLiveSyncDiagnosticReport.make(source: .codexExecJSON)
    let daemonSocketReport = HostAgentLiveSyncDiagnosticReport.make(source: .standaloneDaemonControlSocket)

    #expect(execJSONReport.rows == [
        HostAgentDiagnosticRow(
            title: "Live Source",
            status: .failed,
            message: "codex exec --json is persisted-history-only and cannot update an already-open Codex TUI session."
        ),
        HostAgentDiagnosticRow(
            title: "TUI Live Sync",
            status: .notRun,
            message: "Requires TUI live-source evidence from the public CLI/TUI live protocol."
        ),
    ])
    #expect(daemonSocketReport.rows == [
        HostAgentDiagnosticRow(
            title: "Live Source",
            status: .failed,
            message: "Standalone app-server control socket access without #80 TUI live producer evidence remains diagnostic-only."
        ),
        HostAgentDiagnosticRow(
            title: "TUI Live Sync",
            status: .notRun,
            message: "Requires TUI live-source evidence from the public CLI/TUI live protocol."
        ),
    ])
}

@Test func hostAgentLiveSyncDiagnosticsAcceptsOnlyVerifiedCodexCLILiveAdapter() {
    let report = HostAgentLiveSyncDiagnosticReport.make(
        source: .codexCLILiveAdapter(evidence: "open Codex TUI session received user prompt and final assistant delta without reopen")
    )

    #expect(report.rows == [
        HostAgentDiagnosticRow(
            title: "Live Source",
            status: .passed,
            message: "Codex CLI Live Adapter uses the public CLI/TUI live protocol."
        ),
        HostAgentDiagnosticRow(
            title: "TUI Live Sync",
            status: .passed,
            message: "open Codex TUI session received user prompt and final assistant delta without reopen"
        ),
    ])
}

@Test func hostAgentLiveSyncDiagnosticsAcceptsVerifiedControlSocketTUILiveSource() {
    let report = HostAgentLiveSyncDiagnosticReport.make(
        source: .appServerControlSocketTUILive(evidence: "#80 HITL: control socket turn/start appeared in already-open Codex TUI")
    )

    #expect(report.rows == [
        HostAgentDiagnosticRow(
            title: "Live Source",
            status: .passed,
            message: "App-server control socket updates an already-open Codex TUI through the public CLI/TUI live protocol."
        ),
        HostAgentDiagnosticRow(
            title: "TUI Live Sync",
            status: .passed,
            message: "#80 HITL: control socket turn/start appeared in already-open Codex TUI"
        ),
    ])
}

private struct FakeHostAgentCommandRunner: HostAgentCommandRunning {
    var results: [String: HostAgentCommandResult]

    func run(_ command: String) async -> HostAgentCommandResult {
        results[command] ?? HostAgentCommandResult(stdout: "", stderr: "missing fake command: \(command)", exitStatus: 127)
    }
}
