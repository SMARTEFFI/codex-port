import Foundation

public enum HostAgentDiagnosticStatus: Equatable, Sendable {
    case passed
    case failed
    case notRun
}

public struct HostAgentDiagnosticRow: Equatable, Sendable {
    public var title: String
    public var status: HostAgentDiagnosticStatus
    public var message: String

    public init(title: String, status: HostAgentDiagnosticStatus, message: String) {
        self.title = title
        self.status = status
        self.message = message
    }
}

public struct HostAgentDiagnosticReport: Equatable, Sendable {
    public var rows: [HostAgentDiagnosticRow]

    public init(rows: [HostAgentDiagnosticRow]) {
        self.rows = rows
    }
}

public enum HostAgentLiveSyncSource: Equatable, Sendable {
    case codexCLILiveAdapter(evidence: String)
    case appServerControlSocketTUILive(evidence: String)
    case codexExecJSON
    case standaloneDaemonControlSocket
    case unknown(reason: String)
}

public struct HostAgentLiveSyncDiagnosticReport: Sendable {
    public static func make(source: HostAgentLiveSyncSource) -> HostAgentDiagnosticReport {
        switch source {
        case let .codexCLILiveAdapter(evidence):
            return HostAgentDiagnosticReport(rows: [
                HostAgentDiagnosticRow(
                    title: "Live Source",
                    status: .passed,
                    message: "Codex CLI Live Adapter uses the public CLI/TUI live protocol."
                ),
                HostAgentDiagnosticRow(
                    title: "TUI Live Sync",
                    status: .passed,
                    message: evidence
                ),
            ])
        case let .appServerControlSocketTUILive(evidence):
            return HostAgentDiagnosticReport(rows: [
                HostAgentDiagnosticRow(
                    title: "Live Source",
                    status: .passed,
                    message: "App-server control socket updates an already-open Codex TUI through the public CLI/TUI live protocol."
                ),
                HostAgentDiagnosticRow(
                    title: "TUI Live Sync",
                    status: .passed,
                    message: evidence
                ),
            ])
        case .codexExecJSON:
            return persistedHistoryOnlyReport(
                reason: "codex exec --json is persisted-history-only and cannot update an already-open Codex TUI session."
            )
        case .standaloneDaemonControlSocket:
            return persistedHistoryOnlyReport(
                reason: "Standalone app-server control socket access without #80 TUI live producer evidence remains diagnostic-only."
            )
        case let .unknown(reason):
            return HostAgentDiagnosticReport(rows: [
                HostAgentDiagnosticRow(title: "Live Source", status: .failed, message: reason),
                HostAgentDiagnosticRow(
                    title: "TUI Live Sync",
                    status: .notRun,
                    message: "Requires TUI live-source evidence from the public CLI/TUI live protocol."
                ),
            ])
        }
    }

    private static func persistedHistoryOnlyReport(reason: String) -> HostAgentDiagnosticReport {
        HostAgentDiagnosticReport(rows: [
            HostAgentDiagnosticRow(title: "Live Source", status: .failed, message: reason),
            HostAgentDiagnosticRow(
                title: "TUI Live Sync",
                status: .notRun,
                message: "Requires TUI live-source evidence from the public CLI/TUI live protocol."
            ),
        ])
    }
}

public struct HostAgentCommandResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitStatus: Int32

    public init(stdout: String, stderr: String, exitStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    var trimmedStdout: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedStderr: String {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var readableFailure: String {
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        if !trimmedStdout.isEmpty {
            return trimmedStdout
        }
        return "Command failed with exit status \(exitStatus)."
    }
}

public protocol HostAgentCommandRunning: Sendable {
    func run(_ command: String) async -> HostAgentCommandResult
}

public struct HostAgentUserEnvironment: Equatable, Sendable {
    public var userName: String
    public var homeDirectory: String

    public init(userName: String, homeDirectory: String) {
        self.userName = userName
        self.homeDirectory = homeDirectory
    }

    public static let placeholder = HostAgentUserEnvironment(userName: "unknown", homeDirectory: "~")

    var displayText: String {
        "\(userName) · \(homeDirectory)"
    }
}

public struct HostAgentDiagnosticsRunner<CommandRunner: HostAgentCommandRunning>: Sendable {
    private let commandRunner: CommandRunner
    private let minimumCodexVersion = HostAgentSemanticVersion(major: 0, minor: 133, patch: 0)

    public init(commandRunner: CommandRunner) {
        self.commandRunner = commandRunner
    }

    public func run(codexPath: String, environment: HostAgentUserEnvironment) async -> HostAgentDiagnosticReport {
        switch await resolveCodexPath(codexPath) {
        case let .failure(message):
            return HostAgentDiagnosticReport(rows: [
                HostAgentDiagnosticRow(title: "Codex CLI Path", status: .failed, message: message)
            ])
        case let .success(resolvedPath):
            var rows = [
                HostAgentDiagnosticRow(title: "Codex CLI Path", status: .passed, message: resolvedPath)
            ]

            let versionResult = await commandRunner.run("\(resolvedPath) --version")
            let rawVersion = versionResult.trimmedStdout.isEmpty ? versionResult.trimmedStderr : versionResult.trimmedStdout
            guard versionResult.exitStatus == 0 else {
                rows.append(HostAgentDiagnosticRow(title: "Codex CLI Version", status: .failed, message: versionResult.readableFailure))
                return HostAgentDiagnosticReport(rows: rows)
            }

            guard let actualVersion = HostAgentSemanticVersion.parse(rawVersion) else {
                rows.append(HostAgentDiagnosticRow(title: "Codex CLI Version", status: .failed, message: "\(rawVersion) could not be parsed."))
                return HostAgentDiagnosticReport(rows: rows)
            }

            guard actualVersion >= minimumCodexVersion else {
                rows.append(HostAgentDiagnosticRow(title: "Codex CLI Version", status: .failed, message: "\(rawVersion) is below minimum \(minimumCodexVersion.description)."))
                return HostAgentDiagnosticReport(rows: rows)
            }

            rows.append(HostAgentDiagnosticRow(title: "Codex CLI Version", status: .passed, message: rawVersion))
            rows.append(HostAgentDiagnosticRow(title: "User Environment", status: .passed, message: environment.displayText))

            let sessionResult = await commandRunner.run("\(resolvedPath) proto --help")
            if sessionResult.exitStatus == 0 {
                rows.append(HostAgentDiagnosticRow(title: "CLI Live Session", status: .passed, message: "CLI live session adapter can be prepared."))
            } else {
                rows.append(HostAgentDiagnosticRow(title: "CLI Live Session", status: .failed, message: sessionResult.readableFailure))
            }

            return HostAgentDiagnosticReport(rows: rows)
        }
    }

    private func resolveCodexPath(_ codexPath: String) async -> HostAgentCodexPathResolution {
        if codexPath.contains("/") {
            return .success(codexPath)
        }

        let pathResult = await commandRunner.run("which \(codexPath)")
        guard pathResult.exitStatus == 0, !pathResult.trimmedStdout.isEmpty else {
            return .failure("Codex CLI not found. Set an absolute codexPath or install Codex CLI.")
        }
        return .success(pathResult.trimmedStdout)
    }
}

private enum HostAgentCodexPathResolution: Sendable {
    case success(String)
    case failure(String)
}

private struct HostAgentSemanticVersion: Comparable, CustomStringConvertible, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func parse(_ rawValue: String) -> HostAgentSemanticVersion? {
        let parts = rawValue
            .split { !$0.isNumber && $0 != "." }
            .flatMap { $0.split(separator: ".") }
            .compactMap { Int($0) }

        guard parts.count >= 3 else {
            return nil
        }
        return HostAgentSemanticVersion(major: parts[0], minor: parts[1], patch: parts[2])
    }

    static func < (lhs: HostAgentSemanticVersion, rhs: HostAgentSemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
