import Foundation
import CodexPortShared

public enum ConnectionFailure: Equatable, Sendable {
    case networkUnreachable
    case authenticationRejected
    case hostKeyChanged(expected: String, presented: String)
    case remoteCommandFailed(String)
    case codexVersion(String)
    case proxyHelpUnavailable
    case initializeFailed(String)
}

public enum DiagnosticCategory: Equatable, Sendable {
    case network
    case authentication
    case hostKeyChanged
    case remoteCommand
    case codexMissing
    case codexTooOld(required: String, actual: String)
    case proxyUnsupported
    case protocolHandshake
}

public enum RelayDiagnosticFailure: Error, Equatable, Sendable {
    case relayUnavailable(String)
    case hostAgentOffline(hostID: UUID, lastSeenAt: Date?)
}

public enum DiagnosticStatus: Equatable, Sendable {
    case passed
    case failed
    case notRun
}

public struct DiagnosticRow: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var status: DiagnosticStatus
    public var message: String

    public init(title: String, status: DiagnosticStatus, message: String) {
        self.title = title
        self.status = status
        self.message = message
    }
}

public struct DiagnosticReport: Equatable, Sendable {
    public var rows: [DiagnosticRow]

    public init(rows: [DiagnosticRow]) {
        self.rows = rows
    }
}

public struct ConnectionDiagnostics: Sendable {
    public init() {}

    public func classify(_ failure: ConnectionFailure) async -> DiagnosticCategory {
        switch failure {
        case .networkUnreachable:
            return .network
        case .authenticationRejected:
            return .authentication
        case .hostKeyChanged:
            return .hostKeyChanged
        case let .remoteCommandFailed(message):
            return Self.isCodexMissingMessage(message)
                ? .codexMissing
                : .remoteCommand
        case let .codexVersion(version):
            switch CodexVersionCompatibility.evaluate(version) {
            case .tooOld(let required, let actual):
                return .codexTooOld(required: required, actual: actual)
            case .supported, .untestedNewer:
                return .remoteCommand
            }
        case .proxyHelpUnavailable:
            return .proxyUnsupported
        case .initializeFailed:
            return .protocolHandshake
        }
    }

    public func report(for failures: [ConnectionFailure]) async -> DiagnosticReport {
        var rows: [DiagnosticRow] = []
        for failure in failures {
            rows.append(row(for: await classify(failure)))
        }
        return DiagnosticReport(rows: rows)
    }

    public func report(for error: Error) async -> DiagnosticReport {
        if let ssh = error as? SSHConnectionError {
            switch ssh {
            case .missingSSHCredential:
                return DiagnosticReport(rows: [
                    DiagnosticRow(title: "SSH 凭据", status: .failed, message: "该 Host 没有 SSH 凭据。请确认当前条目是 Direct SSH Host，而不是 HostAgent 配对 Host。")
                ])
            case let .networkUnreachable(message):
                return DiagnosticReport(rows: [
                    DiagnosticRow(title: "SSH 连接", status: .failed, message: "无法连接到远端 host。底层错误：\(message)")
                ])
            case .authenticationRejected:
                return await report(for: [.authenticationRejected])
            case let .hostKeyChanged(expected, presented):
                return await report(for: [.hostKeyChanged(expected: expected, presented: presented)])
            case let .remoteCommandFailed(message):
                return await report(for: [.remoteCommandFailed(message)])
            case let .unknownHostRejected(fingerprint):
                return DiagnosticReport(rows: [
                    DiagnosticRow(title: "Host Key", status: .failed, message: "未信任远端 host key：\(fingerprint)。")
                ])
            case let .timedOut(seconds):
                return DiagnosticReport(rows: [
                    DiagnosticRow(title: "SSH 连接", status: .failed, message: "连接或远端命令超过 \(Self.displaySeconds(seconds)) 秒未响应。请检查 host、端口、网络和 SSH 服务。")
                ])
            case let .connectionClosed(message):
                return DiagnosticReport(rows: [
                    DiagnosticRow(title: "SSH 连接", status: .failed, message: "SSH 连接提前关闭：\(message)")
                ])
            }
        }
        if let preflight = error as? AppServerPreflightError {
            switch preflight {
            case let .unsupportedCodexVersion(version):
                switch version {
                case let .tooOld(required, actual):
                    return DiagnosticReport(rows: [
                        DiagnosticRow(title: "Codex 版本", status: .failed, message: "远端版本 \(actual) 低于最低要求 \(required)。")
                    ])
                case .supported, .untestedNewer:
                    return await report(for: [.remoteCommandFailed(String(describing: preflight))])
                }
            case let .codexVersionCommandFailed(message):
                return await report(for: [.remoteCommandFailed(message)])
            case .proxyHelpUnavailable:
                return await report(for: [.proxyHelpUnavailable])
            case let .daemonStartFailed(message):
                return await report(for: [.remoteCommandFailed(message)])
            }
        }
        if let relay = error as? RelayDiagnosticFailure {
            return await report(for: relay)
        }
        if let p2pRuntime = error as? RelayP2PDataChannelRuntimeError {
            return await report(for: p2pRuntime)
        }
        if let pairing = error as? RelayPairingError {
            return await report(for: pairing)
        }
        if let codec = error as? JSONRPCCodecError {
            switch codec {
            case let .invalidMessage(message):
                return await report(for: [.initializeFailed("收到非 JSON-RPC 消息：\(message)")])
            }
        }
        if case let JSONRPCError.remote(_, message) = error {
            return await report(for: [.initializeFailed(message)])
        }
        if case let JSONRPCError.requestTimedOut(method, seconds) = error {
            return await report(for: [.initializeFailed("\(method) 超过 \(Self.displaySeconds(seconds)) 秒未响应")])
        }
        return DiagnosticReport(rows: [
            DiagnosticRow(title: "未知错误", status: .failed, message: String(describing: error))
        ])
    }

    public func report(for failure: RelayDiagnosticFailure) async -> DiagnosticReport {
        switch failure {
        case let .relayUnavailable(message):
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Relay 连接", status: .failed, message: "无法连接 CodexPort Relay：\(message)")
            ])
        case let .hostAgentOffline(_, lastSeenAt):
            let lastSeen = lastSeenAt.map { "最后在线 \(HostProfileRowPresentation.utcTimestamp($0))。" } ?? ""
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Host Agent", status: .failed, message: "Host Agent 离线。\(lastSeen)请检查 Mac 是否开机、联网并运行 CodexPort Host Agent。")
            ])
        }
    }

    public func report(for error: RelayPairingError) async -> DiagnosticReport {
        switch error {
        case .pairingRecordNotFound:
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Pairing", status: .failed, message: "该 iPhone 的 Pairing 已失效或被撤销，请在 Mac Host Agent 上重新配对。")
            ])
        case let .versionMismatch(clientSupported, relaySupported):
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Relay 版本", status: .failed, message: "Relay protocol 版本不兼容。iOS 支持 \(Self.versionList(clientSupported))，Relay 支持 \(Self.versionList(relaySupported))。请升级 iOS app 或 Host Agent。")
            ])
        case let .tokenExpired(tokenID, _):
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Pairing", status: .failed, message: "Pairing Token 已过期：\(tokenID)。请在 Mac Host Agent 上重新生成。")
            ])
        case let .tokenAlreadyUsed(tokenID):
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Pairing", status: .failed, message: "Pairing Token 已使用：\(tokenID)。请在 Mac Host Agent 上重新生成。")
            ])
        case let .tokenNotFound(tokenID):
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Pairing", status: .failed, message: "找不到 Pairing Token：\(tokenID)。请检查输入或重新生成。")
            ])
        case .unknownHost:
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "Host Agent", status: .failed, message: "Pairing Token 指向的 Host Agent 未注册或已离线。")
            ])
        }
    }

    public func report(for error: RelayP2PDataChannelRuntimeError) async -> DiagnosticReport {
        switch error {
        case let .runtimeUnavailable(message):
            return DiagnosticReport(rows: [
                DiagnosticRow(title: "WebRTC DataChannel", status: .failed, message: "P2P DataChannel runtime unavailable: \(message)")
            ])
        }
    }

    private func row(for category: DiagnosticCategory) -> DiagnosticRow {
        switch category {
        case .network:
            return DiagnosticRow(title: "SSH 连接", status: .failed, message: "无法连接到远端 host。请检查公网地址、端口、VPN/Tailscale/LAN 路由。")
        case .authentication:
            return DiagnosticRow(title: "SSH 认证", status: .failed, message: "远端拒绝了密码或 SSH key。请检查用户名和凭据。")
        case .hostKeyChanged:
            return DiagnosticRow(title: "Host Key", status: .failed, message: "远端 host key 与已信任记录不一致。确认安全后再重新信任。")
        case .remoteCommand:
            return DiagnosticRow(title: "远端命令", status: .failed, message: "远端命令启动失败。请检查 shell、PATH 和 codex 命令路径。")
        case .codexMissing:
            return DiagnosticRow(title: "Codex CLI", status: .failed, message: "远端找不到 codex 命令。已尝试常见 CLI 路径；请安装 Codex CLI，或在 Host 配置里把 codexPath 改成绝对路径。")
        case let .codexTooOld(required, actual):
            return DiagnosticRow(title: "Codex 版本", status: .failed, message: "远端版本 \(actual) 低于最低要求 \(required)。")
        case .proxyUnsupported:
            return DiagnosticRow(title: "App Server", status: .failed, message: "远端 Codex 不支持 app-server。请升级远端 Codex CLI。")
        case .protocolHandshake:
            return DiagnosticRow(title: "协议握手", status: .failed, message: "initialize 握手失败。请检查 app-server 输出。")
        }
    }

    public static func isCodexMissingMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("codex: command not found")
            || lowercased.contains("command not found: codex")
            || lowercased.contains("codex: not found")
            || lowercased.contains("no such file or directory") && lowercased.contains("codex")
    }

    private static func displaySeconds(_ seconds: Double) -> String {
        if seconds >= 1 {
            return "\(Int(seconds))"
        }
        return String(format: "%.2f", seconds)
    }

    private static func versionList(_ versions: [RelayProtocolVersion]) -> String {
        "[\(versions.map(\.description).joined(separator: ", "))]"
    }
}

public struct ConnectionDiagnosticRunner: Sendable {
    private let ssh: SSHConnectionService
    private let credentialResolver: HostCredentialResolver
    private let diagnostics: ConnectionDiagnostics

    public init(ssh: SSHConnectionService, credentialResolver: HostCredentialResolver, diagnostics: ConnectionDiagnostics = ConnectionDiagnostics()) {
        self.ssh = ssh
        self.credentialResolver = credentialResolver
        self.diagnostics = diagnostics
    }

    public func run(profile: HostProfile, authorization: CredentialAuthorization = .granted, decision: UnknownHostDecision = .rejectUnknownHost) async -> DiagnosticReport {
        do {
            let credential = try credentialResolver.resolve(profile, authorization: authorization)
            let rows = try await preflightRows(profile: profile, credential: credential, decision: decision)
            return DiagnosticReport(rows: rows)
        } catch {
            return await diagnostics.report(for: error)
        }
    }

    private func preflightRows(profile: HostProfile, credential: SSHCredential, decision: UnknownHostDecision) async throws -> [DiagnosticRow] {
        let shell = AppServerShellCommand(codexPath: profile.codexPath)
        let version = try await ssh.runCommand(
            profile: profile,
            credential: credential,
            decision: decision,
            command: shell.versionCommand
        )
        guard version.exitStatus == 0 else {
            throw AppServerPreflightError.codexVersionCommandFailed(version.stderrString + version.stdoutString)
        }
        let versionRow: DiagnosticRow
        switch CodexVersionCompatibility.evaluate(version.stdoutString) {
        case .supported:
            versionRow = DiagnosticRow(title: "Codex 版本", status: .passed, message: version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        case let .untestedNewer(raw):
            versionRow = DiagnosticRow(title: "Codex 版本", status: .passed, message: "远端版本 \(raw.trimmingCharacters(in: .whitespacesAndNewlines)) 高于已验证版本，允许继续尝试。")
        case let .tooOld(required, actual):
            throw AppServerPreflightError.unsupportedCodexVersion(.tooOld(required: required, actual: actual))
        }

        let appServerHelp = try await ssh.runCommand(
            profile: profile,
            credential: credential,
            decision: decision,
            command: shell.appServerHelpCommand
        )
        guard appServerHelp.exitStatus == 0 else {
            throw AppServerPreflightError.proxyHelpUnavailable(appServerHelp.stderrString + appServerHelp.stdoutString)
        }

        return [
            DiagnosticRow(title: "SSH 连接", status: .passed, message: "已获取远端 host key fingerprint。"),
            versionRow,
            DiagnosticRow(title: "App Server", status: .passed, message: "远端支持 app-server。"),
        ]
    }
}

public enum CodexVersionCompatibility: Equatable, Sendable {
    case tooOld(required: String, actual: String)
    case supported
    case untestedNewer(String)

    private static let minimum = SemanticVersion(major: 0, minor: 133, patch: 0)
    private static let latestVerified = SemanticVersion(major: 0, minor: 133, patch: 0)

    public static func evaluate(_ rawVersion: String) -> CodexVersionCompatibility {
        let version = SemanticVersion.parse(rawVersion)
        guard version >= minimum else {
            return .tooOld(required: minimum.description, actual: rawVersion)
        }
        if version > latestVerified {
            return .untestedNewer(rawVersion)
        }
        return .supported
    }
}

private struct SemanticVersion: Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    static func parse(_ raw: String) -> SemanticVersion {
        let numbers = raw
            .split { !$0.isNumber }
            .prefix(3)
            .compactMap { Int($0) }
        return SemanticVersion(
            major: numbers.indices.contains(0) ? numbers[0] : 0,
            minor: numbers.indices.contains(1) ? numbers[1] : 0,
            patch: numbers.indices.contains(2) ? numbers[2] : 0
        )
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
