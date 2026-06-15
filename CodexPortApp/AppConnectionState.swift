import CodexPortCore
import CodexPortShared
import CodexPortWebRTC
import Foundation

@MainActor
final class AppConnectionState: ObservableObject {
    @Published private(set) var session: AppServerSession?
    @Published private(set) var connectedRoute: ConnectedSessionRoute?
    @Published private(set) var projects: [WorkspaceProject] = []
    @Published private(set) var projectThreadGroups: [WorkspaceProjectThreadGroup] = []
    @Published private(set) var dayThreadGroups: [WorkspaceDayThreadGroup] = []
    @Published private(set) var recentThreads: [ThreadSummary] = []
    @Published private(set) var remoteBrowserStore: RemoteFileBrowserStore?
    @Published private(set) var pendingHostKeyConfirmation: PendingHostKeyConfirmation?
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionLogTitle = "连接日志"
    @Published private(set) var connectionLogs: [ConnectionLogEntry] = []
    @Published private(set) var connectionProgressMessage = "waiting for remote response..."
    @Published var isConnectionLogPresented = false
    @Published private(set) var isReloadingWorkspaces = false
    @Published private(set) var hasLoadedRelayThreadList = false
    @Published private(set) var startingThreadCWDs: Set<String> = []
    @Published var grouping: WorkspaceGrouping = .byProject
    @Published var errorMessage: String?
    var onHostKeyTrusted: ((PendingHostKeyConfirmation) -> Void)?

    private let credentialVault: CredentialVault
    private let knownHosts: KnownHostVerifying
    private let driver: SSHDriver
    private var relayTransportFactory: RelaySessionRouteBuilder.TransportFactory
    private var workspaceStore: WorkspaceListStore?
    private var pendingProfile: HostProfile?
    private var connectedProfileKey: HostProfileConnectionReuseKey?
    private var connectedRelayHost: RelayHost?
    private var connectedRelayDefaultDirectory: String?
    private var connectedRelaySessionRegistry: RelaySessionContextRegistry?
    private var relayWorkspaceReloadTask: Task<Void, Never>?

    init(
        credentialVault: CredentialVault,
        knownHosts: KnownHostVerifying = KnownHostVerifier(),
        driver: SSHDriver = NIOSSHDriver(),
        relayTransportFactory: @escaping RelaySessionRouteBuilder.TransportFactory = AppConnectionState.defaultRelayTransportFactory()
    ) {
        self.credentialVault = credentialVault
        self.knownHosts = knownHosts
        self.driver = driver
        self.relayTransportFactory = relayTransportFactory
    }

    func useRelayTransportMode(
        _ mode: RelayConnectionTransportMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        relayTransportFactory = AppConnectionState.relayTransportFactory(mode: mode, environment: environment)
        connectedRoute = nil
        connectedRelaySessionRegistry?.stopAll()
        connectedRelaySessionRegistry = nil
        connectedProfileKey = nil
        connectedRelayHost = nil
        connectedRelayDefaultDirectory = nil
        hasLoadedRelayThreadList = false
    }

    private static func defaultRelayTransportFactory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RelaySessionRouteBuilder.TransportFactory {
        relayTransportFactory(
            mode: RelayConnectionTransportMode.parse(
                environmentValue: environment["CODEXPORT_IOS_RELAY_TRANSPORT_MODE"]
            ),
            environment: environment
        )
    }

    private static func relayTransportFactory(
        mode: RelayConnectionTransportMode,
        environment: [String: String]
    ) -> RelaySessionRouteBuilder.TransportFactory {
        RelayConnectionTransportFactory(
            mode: mode,
            webRTCConfiguration: WebRTCRuntimeConfigurationEnvironment.makeOrDefault(environment: environment)
        ).makeTransport(for:)
    }

    func connect(profile: HostProfile) async {
        if canReuseConnection(for: profile) {
            isConnectionLogPresented = false
            errorMessage = nil
            return
        }
        clearConnectionStateIfSwitchingHost(to: profile)
        await connect(profile: profile, unknownHostDecision: .rejectUnknownHost, resetLog: true)
    }

    func relayReadiness(for profile: HostProfile) -> RelayHostReadiness? {
        guard case let .relay(relayHost) = profile.connectionMethod else { return nil }
        guard !canReuseConnection(for: profile) else {
            return .ready(loadedThreadCount: recentThreads.count)
        }
        if isConnecting {
            return .loading(stage: .threadList)
        }
        return relayHost.readiness
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
            connectionProgressMessage = "准备连接..."
            if profile.connectionMethod.isRelay {
                isConnectionLogPresented = false
                appendConnectionLog("准备连接已配对的 HostAgent：\(profile.name)")
            } else {
                isConnectionLogPresented = true
                appendConnectionLog("准备连接 \(profile.username)@\(profile.host):\(profile.port)")
            }
        } else {
            isConnectionLogPresented = true
            connectionProgressMessage = "继续连接..."
            appendConnectionLog("已信任 Host Key，继续连接 \(profile.name)。")
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            if case let .relay(relayHost) = profile.connectionMethod {
                try await connectRelay(profile: profile, relayHost: relayHost)
                return
            }

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
            connectedRoute = .directSSH(protocolClient: connected.protocolClient, events: connected.events)
            connectedProfileKey = HostProfileConnectionReuseKey(profile: profile)
            connectedRelayHost = nil
            connectedRelayDefaultDirectory = nil
            connectedRelaySessionRegistry?.stopAll()
            connectedRelaySessionRegistry = nil
            hasLoadedRelayThreadList = false
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
            if profile.connectionMethod.isRelay {
                isConnectionLogPresented = false
            }
        }
    }

    private func connectRelay(profile: HostProfile, relayHost: RelayHost) async throws {
        appendConnectionLog("使用 HostAgent 配对连接，不读取 SSH 凭据。")
        appendConnectionLog("HostAgent：\(profile.name) · \(relayHost.userName)")
        session = nil
        workspaceStore = nil
        remoteBrowserStore = nil
        connectionProgressMessage = "打开 Relay transport..."
        appendConnectionLog("正在打开 Relay transport。")
        guard relayTransportFactory(relayHost) != nil else {
            throw RelayJSONLThreadListClientError.transportUnavailable
        }
        if connectedRelaySessionRegistry == nil {
            connectedRelaySessionRegistry = RelaySessionContextRegistry(
                allowedThreadIDs: [],
                storeFactory: { threadID in
                    SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: threadID))
                },
                clientFactory: { [relayTransportFactory] thread, sessionStore in
                    guard let transport = relayTransportFactory(relayHost) else {
                        return nil
                    }
                    return RelayJSONLSessionClient(
                        clientID: relayHost.pairingRecordID,
                        sessionID: thread.id,
                        threadID: thread.id,
                        turnID: "\(thread.id)-turn",
                        cwd: thread.cwd,
                        transport: transport,
                        sessionStore: sessionStore
                    )
                }
            )
        }
        let profileKey = HostProfileConnectionReuseKey(profile: profile)
        connectionProgressMessage = "等待 HostAgent 返回会话列表..."
        appendConnectionLog("请求 HostAgent 会话列表。")
        let connection: RelayHostWorkspaceConnection
        do {
            connection = try await RelayHostWorkspaceConnector(
                profileDefaultDirectory: profile.defaultDirectory,
                relayHost: relayHost,
                existingRegistry: connectedRelaySessionRegistry,
                makeTransport: relayTransportFactory,
                progressObserver: { [weak self] event in
                    await MainActor.run {
                        self?.recordRelayThreadListProgress(event)
                    }
                }
            ).connect()
        } catch {
            throw error
        }
        connectedRoute = connection.route
        publishRelayThreadSnapshots(
            connection.threadSnapshots,
            profileDefaultDirectory: profile.defaultDirectory,
            relayHost: relayHost
        )
        hasLoadedRelayThreadList = true
        connectedProfileKey = profileKey
        connectedRelayHost = relayHost
        connectedRelayDefaultDirectory = profile.defaultDirectory
        pendingHostKeyConfirmation = nil
        pendingProfile = nil
        appendConnectionLog("连接完成，已加载 \(projects.count) 个项目、\(recentThreads.count) 个最近会话。", level: .success)
        connectionProgressMessage = "连接完成"
        isConnectionLogPresented = false
    }

    private func recordRelayThreadListProgress(_ event: RelayThreadListProgressEvent) {
        switch event {
        case let .requestingPage(requestID, limit, cursor):
            if cursor != nil {
                connectionProgressMessage = "继续读取会话列表..."
                appendConnectionLog("请求 HostAgent 会话列表分页 \(requestID)，limit \(limit)，携带上一页 cursor。")
            } else {
                connectionProgressMessage = "请求 HostAgent 会话列表..."
                appendConnectionLog("请求 HostAgent 会话列表 \(requestID)，limit \(limit)。")
            }
        case let .receivedPage(requestID, count, nextCursor):
            connectionProgressMessage = nextCursor == nil ? "解析 HostAgent 会话列表..." : "继续读取更多会话..."
            let suffix = nextCursor == nil ? "无更多分页" : "还有更多分页"
            appendConnectionLog("收到 HostAgent 会话列表 \(requestID)：\(count) 条，\(suffix)。", level: .success)
        }
    }

    private func canReuseConnection(for profile: HostProfile) -> Bool {
        guard connectedProfileKey == HostProfileConnectionReuseKey(profile: profile), connectedRoute != nil else { return false }
        guard !isConnecting else { return true }
        return true
    }

    private func clearConnectionStateIfSwitchingHost(to profile: HostProfile) {
        let profileKey = HostProfileConnectionReuseKey(profile: profile)
        guard connectedProfileKey != nil, connectedProfileKey != profileKey else { return }
        relayWorkspaceReloadTask?.cancel()
        relayWorkspaceReloadTask = nil
        isReloadingWorkspaces = false
        session = nil
        connectedRoute = nil
        workspaceStore = nil
        remoteBrowserStore = nil
        connectedRelayHost = nil
        connectedRelayDefaultDirectory = nil
        connectedRelaySessionRegistry?.stopAll()
        connectedRelaySessionRegistry = nil
        hasLoadedRelayThreadList = false
        projects = []
        projectThreadGroups = []
        dayThreadGroups = []
        recentThreads = []
        connectedProfileKey = nil
    }

    func reloadWorkspaces() async {
        if connectedRoute?.isRelay == true,
           let connectedProfileKey,
           let connectedRelayHost,
           let connectedRelayDefaultDirectory
        {
            await reloadRelayWorkspaces(
                profileKey: connectedProfileKey,
                profileDefaultDirectory: connectedRelayDefaultDirectory,
                relayHost: connectedRelayHost,
                surfaceError: true
            )
            return
        }
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

    private func startRelayWorkspaceReload(
        profileKey: HostProfileConnectionReuseKey,
        profileDefaultDirectory: String,
        relayHost: RelayHost
    ) {
        relayWorkspaceReloadTask?.cancel()
        guard !isReloadingWorkspaces else { return }
        isReloadingWorkspaces = true
        relayWorkspaceReloadTask = Task { [weak self] in
            await self?.reloadRelayWorkspaces(
                profileKey: profileKey,
                profileDefaultDirectory: profileDefaultDirectory,
                relayHost: relayHost,
                surfaceError: false,
                loadingStateAlreadySet: true
            )
        }
    }

    private func reloadRelayWorkspaces(
        profileKey: HostProfileConnectionReuseKey,
        profileDefaultDirectory: String,
        relayHost: RelayHost,
        surfaceError: Bool,
        loadingStateAlreadySet: Bool = false
    ) async {
        if !loadingStateAlreadySet {
            guard !isReloadingWorkspaces else { return }
            isReloadingWorkspaces = true
        }
        defer {
            if connectedProfileKey == profileKey {
                isReloadingWorkspaces = false
            }
        }
        do {
            guard let listTransport = relayTransportFactory(relayHost) else {
                throw RelayJSONLThreadListClientError.transportUnavailable
            }
            connectionProgressMessage = "等待 HostAgent 返回会话列表..."
            appendConnectionLog("后台请求 HostAgent 会话列表。")
            let threadSnapshots = try await RelayJSONLThreadListClient(
                clientID: relayHost.pairingRecordID,
                transport: listTransport,
                progressObserver: { [weak self] event in
                    await MainActor.run {
                        self?.recordRelayThreadListProgress(event)
                    }
                }
            ).listThreads()
            guard connectedProfileKey == profileKey else { return }
            publishRelayThreadSnapshots(
                threadSnapshots,
                profileDefaultDirectory: profileDefaultDirectory,
                relayHost: relayHost
            )
            hasLoadedRelayThreadList = true
            errorMessage = nil
            connectionProgressMessage = "连接完成"
            appendConnectionLog("HostAgent 会话列表已加载：\(projects.count) 个项目、\(recentThreads.count) 个最近会话。", level: .success)
        } catch {
            guard connectedProfileKey == profileKey else { return }
            let message = connectionErrorMessage(for: error)
            appendConnectionLog("HostAgent 会话列表加载失败：\(message)", level: .warning)
            if surfaceError {
                errorMessage = message
            }
        }
    }

    private func publishRelayThreadSnapshots(
        _ threadSnapshots: [RelayThreadSummarySnapshot],
        profileDefaultDirectory: String,
        relayHost: RelayHost
    ) {
        let route = RelaySessionRouteBuilder.route(
            profileDefaultDirectory: profileDefaultDirectory,
            relayHost: relayHost,
            threadSnapshots: threadSnapshots,
            existingRegistry: connectedRelaySessionRegistry,
            makeTransport: relayTransportFactory
        )
        let summaries = route.relayThreadSummaries
        connectedRoute = route
        let index = WorkspaceIndex(threads: summaries)
        projects = index.projects()
        projectThreadGroups = index.projectThreadGroups(limit: 5)
        dayThreadGroups = AppConnectionState.dayThreadGroups(for: summaries)
        recentThreads = summaries
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

    private static func dayThreadGroups(for threads: [ThreadSummary]) -> [WorkspaceDayThreadGroup] {
        let grouped = Dictionary(grouping: threads) { thread in
            Calendar.current.startOfDay(for: thread.updatedAt)
        }
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if Calendar.current.isDate(day, inSameDayAs: today) {
                title = "今天"
            } else if let yesterday, Calendar.current.isDate(day, inSameDayAs: yesterday) {
                title = "昨天"
            } else {
                title = formatter.string(from: day)
            }
            let sortedThreads = (grouped[day] ?? []).sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.id < right.id
                }
                return left.updatedAt > right.updatedAt
            }
            return WorkspaceDayThreadGroup(
                id: String(Int(day.timeIntervalSince1970)),
                title: title,
                threads: Array(sortedThreads.prefix(5)),
                hiddenThreadCount: max(sortedThreads.count - 5, 0),
                allThreads: sortedThreads
            )
        }
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
            case .missingSSHCredential:
                return "该 Host 没有 SSH 凭据。请确认当前条目是 Direct SSH Host，而不是 HostAgent 配对 Host。"
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
        if let relayList = error as? RelayJSONLThreadListClientError {
            switch relayList {
            case .transportUnavailable:
                return "配对连接入口不可用。请重新配对或检查 Host 配置。"
            case .timedOut:
                return "读取 HostAgent 会话列表超时。请确认 HostAgent 菜单应用在线后重试。"
            case let .hostAgentError(reason):
                if reason.isEmpty {
                    return "HostAgent 读取 Codex 会话列表失败。请确认本机 Codex CLI 可运行。"
                }
                return "HostAgent 读取 Codex 会话列表失败：\(reason)"
            }
        }
        if let p2p = error as? RelayP2PSessionTransportFactoryError {
            switch p2p {
            case .hostAgentDidNotAnswer:
                return "HostAgent 在线状态已过期或未响应 WebRTC 连接。请确认 Mac 端 HostAgent 菜单应用正在运行后重试。"
            case .missingDeviceID:
                return "配对记录缺少设备标识。请重新配对 HostAgent。"
            case .notAuthorizedToSignal:
                return "当前设备未获准连接该 HostAgent。请重新配对。"
            case .pairingRecordMismatch:
                return "HostAgent 配对记录不匹配。请重新配对。"
            }
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
