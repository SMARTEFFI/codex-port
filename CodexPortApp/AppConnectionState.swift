import CodexPortCore
import Foundation

@MainActor
final class AppConnectionState: ObservableObject {
    @Published private(set) var session: AppServerSession?
    @Published private(set) var projects: [WorkspaceProject] = []
    @Published private(set) var projectThreadGroups: [WorkspaceProjectThreadGroup] = []
    @Published private(set) var dayThreadGroups: [WorkspaceDayThreadGroup] = []
    @Published private(set) var recentThreads: [ThreadSummary] = []
    @Published private(set) var remoteBrowserStore: RemoteFileBrowserStore?
    @Published private(set) var pendingHostKeyConfirmation: PendingHostKeyConfirmation?
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionLogTitle = "连接日志"
    @Published private(set) var connectionLogs: [ConnectionLogEntry] = []
    @Published var isConnectionLogPresented = false
    @Published private(set) var diagnosticReport = DiagnosticReport(rows: DiagnosticsView.defaultRows)
    @Published private(set) var isRunningDiagnostics = false
    @Published private(set) var isReloadingWorkspaces = false
    @Published private(set) var startingThreadCWDs: Set<String> = []
    @Published var grouping: WorkspaceGrouping = .byProject
    @Published var errorMessage: String?
    var onHostKeyTrusted: ((PendingHostKeyConfirmation) -> Void)?

    private let credentialVault: CredentialVault
    private let knownHosts: KnownHostVerifying
    private let driver: SSHDriver
    private var workspaceStore: WorkspaceListStore?
    private var pendingProfile: HostProfile?

    init(
        credentialVault: CredentialVault,
        knownHosts: KnownHostVerifying = KnownHostVerifier(),
        driver: SSHDriver = NIOSSHDriver()
    ) {
        self.credentialVault = credentialVault
        self.knownHosts = knownHosts
        self.driver = driver
    }

    func connect(profile: HostProfile) async {
        await connect(profile: profile, unknownHostDecision: .rejectUnknownHost, resetLog: true)
    }

    func confirmPendingHostKeyAndConnect() async {
        guard let pendingProfile, let pendingConfirmation = pendingHostKeyConfirmation else { return }
        onHostKeyTrusted?(pendingConfirmation)
        pendingHostKeyConfirmation = nil
        await connect(profile: pendingProfile, unknownHostDecision: .confirmUnknownHost, resetLog: false)
    }

    func rejectPendingHostKey() {
        appendConnectionLog("已拒绝 Host Key，本次连接已停止。", level: .warning)
        pendingHostKeyConfirmation = nil
        pendingProfile = nil
    }

    private func connect(profile: HostProfile, unknownHostDecision: UnknownHostDecision, resetLog: Bool) async {
        if resetLog {
            connectionLogTitle = "连接 \(profile.name)"
            connectionLogs = []
            isConnectionLogPresented = true
            appendConnectionLog("准备连接 \(profile.username)@\(profile.host):\(profile.port)")
        } else {
            isConnectionLogPresented = true
            appendConnectionLog("已信任 Host Key，继续连接 \(profile.name)。")
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            appendConnectionLog("读取本地加密存储中的 SSH 凭据。")
            let credential = try HostCredentialResolver(vault: credentialVault)
                .resolve(profile, authorization: .granted)

            appendConnectionLog("开始 SSH 连接与 Codex app-server 预检。")
            let appServer = AppServerSessionConnector(
                ssh: SSHConnectionService(driver: driver, knownHosts: knownHosts),
                observer: AppServerConnectionObserver { [weak self] message in
                    await MainActor.run {
                        self?.appendConnectionLog(message)
                    }
                }
            )
            let connected = try await appServer.connect(
                profile: profile,
                credential: credential,
                unknownHostDecision: unknownHostDecision,
                clientName: "Codex Port"
            )
            appendConnectionLog("SSH 和 app-server 已连接。", level: .success)
            session = connected
            pendingHostKeyConfirmation = nil
            pendingProfile = nil

            appendConnectionLog("正在读取 Codex 工作区列表。")
            let store = WorkspaceListStore(
                protocolClient: connected.protocolClient,
                grouping: grouping,
                readStateStore: UserDefaultsWorkspaceReadStateStore(namespace: profile.id.uuidString)
            )
            try await store.reload(limit: 100)
            workspaceStore = store
            publishWorkspaceStoreState()
            remoteBrowserStore = RemoteFileBrowserStore(
                browser: RemoteFileBrowser(
                    protocolClient: connected.protocolClient,
                    homeDirectory: profile.defaultDirectory,
                    historicalWorkspaces: projects.map(\.cwd)
                )
            )
            appendConnectionLog("连接完成，已加载 \(projects.count) 个项目、\(recentThreads.count) 个最近会话。", level: .success)
            isConnectionLogPresented = false
        } catch let SSHConnectionError.unknownHostRejected(fingerprint) {
            pendingProfile = profile
            pendingHostKeyConfirmation = PendingHostKeyConfirmation(profileID: profile.id, profileName: profile.name, fingerprint: fingerprint)
            appendConnectionLog("收到未信任 Host Key：\(fingerprint)", level: .warning)
            appendConnectionLog("请确认这是目标主机后，点击“信任并连接”。")
        } catch {
            let message = connectionErrorMessage(for: error)
            errorMessage = message
            appendConnectionLog("连接失败：\(message)", level: .error)
        }
    }

    func reloadWorkspaces() async {
        guard let workspaceStore else { return }
        guard !isReloadingWorkspaces else { return }
        isReloadingWorkspaces = true
        defer {
            isReloadingWorkspaces = false
        }
        do {
            workspaceStore.grouping = grouping
            try await workspaceStore.reload(limit: 100)
            publishWorkspaceStoreState()
            errorMessage = nil
        } catch {
            errorMessage = workspaceStore.errorMessage ?? String(describing: error)
        }
    }

    func markThreadRead(_ threadID: String) {
        guard let workspaceStore else { return }
        do {
            try workspaceStore.markThreadRead(id: threadID)
            publishWorkspaceStoreState()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func startThread(cwd: String) async -> String? {
        guard let session else { return nil }
        guard !startingThreadCWDs.contains(cwd) else { return nil }
        startingThreadCWDs.insert(cwd)
        defer {
            startingThreadCWDs.remove(cwd)
        }
        do {
            let threadID = try await RemoteFileBrowser(
                protocolClient: session.protocolClient,
                homeDirectory: cwd,
                historicalWorkspaces: projects.map(\.cwd)
            ).startThread(cwd: cwd)
            workspaceStore?.upsertLocalThread(id: threadID, cwd: cwd, preview: "新会话")
            publishWorkspaceStoreState()
            await reloadWorkspaces()
            return threadID
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    func runDiagnostics(profile: HostProfile) async {
        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }
        let runner = ConnectionDiagnosticRunner(
            ssh: SSHConnectionService(driver: driver, knownHosts: knownHosts),
            credentialResolver: HostCredentialResolver(vault: credentialVault)
        )
        diagnosticReport = await runner.run(profile: profile, decision: .rejectUnknownHost)
    }

    private func appendConnectionLog(_ message: String, level: ConnectionLogEntry.Level = .info) {
        connectionLogs.append(ConnectionLogEntry(level: level, message: message))
    }

    private func publishWorkspaceStoreState() {
        guard let workspaceStore else { return }
        projects = workspaceStore.projects
        projectThreadGroups = workspaceStore.projectThreadGroups
        dayThreadGroups = workspaceStore.dayThreadGroups
        recentThreads = workspaceStore.recentThreads
    }

    private func connectionErrorMessage(for error: Error) -> String {
        if let ssh = error as? SSHConnectionError {
            switch ssh {
            case let .timedOut(seconds):
                return "连接或远端命令超过 \(Int(seconds)) 秒未响应。请检查 host、端口、网络、Tailscale/DNS 和远端 SSH 服务。"
            case let .networkUnreachable(message):
                return "无法连接到远端 SSH 服务。请检查 host、端口、网络和防火墙。底层错误：\(message)"
            case .authenticationRejected:
                return "SSH 认证失败。请检查用户名、密码或 SSH key。"
            case let .hostKeyChanged(expected, presented):
                return "Host Key 已变化。已信任：\(expected)，本次收到：\(presented)。"
            case let .unknownHostRejected(fingerprint):
                return "尚未信任远端 Host Key：\(fingerprint)。"
            case let .remoteCommandFailed(message):
                return "远端命令失败：\(message)"
            case let .connectionClosed(message):
                return "SSH 连接提前关闭：\(message)"
            }
        }
        if let preflight = error as? AppServerPreflightError {
            switch preflight {
            case let .unsupportedCodexVersion(version):
                switch version {
                case let .tooOld(required, actual):
                    return "远端 Codex 版本 \(actual) 低于最低要求 \(required)。"
                case let .untestedNewer(raw):
                    return "远端 Codex 版本 \(raw) 高于已验证版本。"
                case .supported:
                    return "远端 Codex 版本检查异常。"
                }
            case let .codexVersionCommandFailed(message):
                if ConnectionDiagnostics.isCodexMissingMessage(message) {
                    return "远端找不到 codex 命令。已尝试常见 CLI 路径；请安装 Codex CLI，或在 Host 配置里把 codexPath 改成绝对路径。底层错误：\(message)"
                }
                return "无法读取远端 Codex 版本：\(message)"
            case let .proxyHelpUnavailable(message):
                return "远端 Codex 不支持 app-server：\(message)"
            case let .daemonStartFailed(message):
                return "远端 daemon start 失败：\(message)"
            }
        }
        if case let JSONRPCError.remote(_, message) = error {
            return "Codex 协议握手失败：\(message)"
        }
        if case let JSONRPCError.requestTimedOut(method, seconds) = error {
            return "Codex 协议请求 \(method) 超过 \(Int(seconds)) 秒未响应。请重试连接；如果持续发生，请检查远端 app-server 是否已卡住或版本不兼容。"
        }
        if case let JSONRPCCodecError.invalidMessage(rawMessage) = error {
            return "Codex app-server 返回了非 JSON-RPC 消息：\(rawMessage)"
        }
        return String(describing: error)
    }
}

struct PendingHostKeyConfirmation: Equatable, Sendable {
    var profileID: UUID
    var profileName: String
    var fingerprint: String
}

struct ConnectionLogEntry: Identifiable, Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    var level: Level
    var message: String
    var createdAt = Date()
}
