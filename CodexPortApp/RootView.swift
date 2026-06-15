import CodexPortCore
import SwiftUI

struct RootView: View {
    @State private var path = NavigationPath()
    @State private var store: PersistentHostProfileStore?
    @State private var profiles: [CodexPortCore.HostProfile] = []
    @State private var loadError: String?
    @State private var foregroundRefreshSignal = 0
    @State private var launchAutomation: RelayHostLaunchAutomation?
    @State private var didRunLaunchAutomation = false
    @StateObject private var connection: AppConnectionState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _connection = StateObject(wrappedValue: Self.makeConnectionState())
    }

    var body: some View {
        NavigationStack(path: $path) {
            HostProfilesView(
                profiles: profiles,
                onOpenWorkspaces: { profile in
                    Task {
                        markRelayReadiness(.loading(stage: .threadList), for: profile)
                        await connection.connect(profile: profile)
                        syncRelayReadiness(for: profile)
                        if connection.connectedRoute != nil {
                            path.append(AppRoute.workspaces)
                        }
                    }
                },
                onEditProfile: { profile in
                    path.append(AppRoute.editHostProfile(profile.id))
                },
                onDeleteProfiles: { indexSet in
                    deleteProfiles(at: indexSet)
                },
                onAddProfile: {
                    path.append(AppRoute.addHostProfile)
                }
            )
            .task {
                loadProfilesIfNeeded()
                connection.onHostKeyTrusted = { pending in
                    markPendingHostKeyTrusted(pending)
                }
                await runLaunchAutomationIfNeeded()
            }
            .alert("配置加载失败", isPresented: Binding(
                get: { loadError != nil },
                set: { if !$0 { loadError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(loadError ?? "")
            }
            .alert("连接失败", isPresented: Binding(
                get: { connection.errorMessage != nil && !connection.isConnectionLogPresented },
                set: { if !$0 { connection.errorMessage = nil } }
            )) {
                Button("查看日志") {
                    connection.isConnectionLogPresented = true
                }
                Button("好", role: .cancel) {}
            } message: {
                Text(connection.errorMessage ?? "")
            }
            .onChange(of: connection.errorMessage) { _, message in
                if message != nil {
                    connection.isConnectionLogPresented = connection.pendingHostKeyConfirmation != nil
                }
            }
            .sheet(isPresented: $connection.isConnectionLogPresented) {
                ConnectionLogSheet(
                    title: connection.connectionLogTitle,
                    logs: connection.connectionLogs,
                    progressMessage: connection.connectionProgressMessage,
                    isConnecting: connection.isConnecting,
                    pendingHostKeyConfirmation: connection.pendingHostKeyConfirmation,
                    onRejectPendingHostKey: {
                        connection.rejectPendingHostKey()
                    },
                    onConfirmPendingHostKey: {
                        Task {
                            await connection.confirmPendingHostKeyAndConnect()
                            if connection.connectedRoute != nil {
                                path.append(AppRoute.workspaces)
                            }
                        }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(connection.isConnecting || connection.pendingHostKeyConfirmation != nil)
            }
            .navigationDestination(for: AppRoute.self) { route in
                destinationView(for: route)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                foregroundRefreshSignal += 1
                Task {
                    await connection.reloadWorkspaces()
                }
            }
            .onOpenURL { url in
                Task {
                    await handleOpenURL(url)
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for route: AppRoute) -> some View {
        switch route {
        case .addHostProfile:
            AddHostProfileView { draft in
                guard let store else { return }
                let profile = try store.create(draft)
                profiles.append(profile)
            }
        case let .editHostProfile(id):
            editHostProfileDestination(id: id)
        case .workspaces:
            workspaceDestination()
        case .remoteBrowser:
            remoteBrowserDestination()
        case let .session(threadID, isNew):
            SessionDetailView(
                threadID: threadID,
                isNewThread: isNew,
                protocolClient: connection.session?.protocolClient,
                route: connection.connectedRoute,
                foregroundRefreshSignal: foregroundRefreshSignal,
                relayAutoprompt: relayAutoprompt(for: threadID)
            )
        }
    }

    @ViewBuilder
    private func editHostProfileDestination(id: UUID) -> some View {
        if let profile = profiles.first(where: { $0.id == id }) {
            AddHostProfileView(mode: .edit(profile)) { draft in
                guard let store else { return }
                let updated = try store.update(id, with: draft)
                if let index = profiles.firstIndex(where: { $0.id == id }) {
                    profiles[index] = updated
                } else {
                    profiles = store.list()
                }
            }
        } else {
            ContentUnavailableView("Host 不存在", systemImage: "server.rack")
        }
    }

    private func workspaceDestination() -> some View {
        WorkspaceListView(
            grouping: $connection.grouping,
            projects: connection.projects,
            projectThreadGroups: connection.projectThreadGroups,
            dayThreadGroups: connection.dayThreadGroups,
            recentThreads: connection.recentThreads,
            emptyState: connection.connectedRoute?.isRelay == true && !connection.hasLoadedRelayThreadList ? .relayThreadListUnavailable : .directSSH,
            isLoadingWorkspaces: connection.isReloadingWorkspaces,
            startingThreadCWDs: connection.startingThreadCWDs,
            onOpenSession: { thread in
                connection.markThreadRead(thread.id)
                path.append(AppRoute.session(thread.id, isNew: false))
            },
            onStartProjectSession: { project in
                Task {
                    if let threadID = await connection.startThread(cwd: project.cwd) {
                        path.append(AppRoute.session(threadID, isNew: true))
                    }
                }
            },
            onBrowseWorkspace: {
                path.append(AppRoute.remoteBrowser)
            }
        )
        .overlay {
            if connection.isConnecting {
                ProgressView("正在连接 Codex")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .refreshable {
            await connection.reloadWorkspaces()
        }
        .onAppear {
            Task {
                await connection.reloadWorkspaces()
            }
        }
        .task {
            await connection.reloadWorkspaces()
        }
    }

    private func remoteBrowserDestination() -> some View {
        RemoteFileBrowserView(
            store: connection.remoteBrowserStore,
            fallbackPath: "~",
            fallbackEntries: [],
            onSelectWorkspace: { cwd in
                Task {
                    if let threadID = await connection.startThread(cwd: cwd) {
                        path.append(AppRoute.session(threadID, isNew: true))
                    }
                }
            }
        )
    }

    private func loadProfilesIfNeeded() {
        guard store == nil else { return }
        do {
            let documents = try Self.documentsDirectory()
            let repository = FileHostProfileRepository(fileURL: documents.appending(path: "host-profiles.json"))
            let loadedStore = try PersistentHostProfileStore(repository: repository, credentialVault: Self.makeCredentialVault())
            launchAutomation = try Self.seedRelayHostIfRequested(into: loadedStore)
            store = loadedStore
            profiles = loadedStore.list()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func deleteProfiles(at indexSet: IndexSet) {
        guard let store else { return }
        for index in indexSet.sorted(by: >) {
            guard profiles.indices.contains(index) else { continue }
            do {
                try store.delete(profiles[index].id)
                profiles.remove(at: index)
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    private func markPendingHostKeyTrusted(_ pending: PendingHostKeyConfirmation?) {
        guard let pending, let store else { return }
        do {
            let updated = try store.markKnownHostTrusted(id: pending.profileID, fingerprint: pending.fingerprint)
            if let index = profiles.firstIndex(where: { $0.id == pending.profileID }) {
                profiles[index] = updated
            } else {
                profiles = store.list()
            }
        } catch {
            loadError = String(describing: error)
        }
    }

    private func markRelayReadiness(_ readiness: RelayHostReadiness, for profile: CodexPortCore.HostProfile) {
        guard profile.connectionMethod.isRelay, let store else { return }
        do {
            let updated = try store.updateRelayReadiness(id: profile.id, readiness: readiness)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = updated
            } else {
                profiles = store.list()
            }
        } catch {
            loadError = String(describing: error)
        }
    }

    private func syncRelayReadiness(for profile: CodexPortCore.HostProfile) {
        guard profile.connectionMethod.isRelay, let readiness = connection.relayReadiness(for: profile) else {
            profiles = store?.list() ?? profiles
            return
        }
        if connection.connectedRoute != nil {
            markRelayReadiness(readiness, for: profile)
            return
        }
        if let message = connection.errorMessage {
            markRelayReadiness(
                .failed(reason: RelayReadinessFailureClassifier.reason(for: message), message: message),
                for: profile
            )
            return
        }
        markRelayReadiness(readiness, for: profile)
    }

    @MainActor
    private func runLaunchAutomationIfNeeded() async {
        guard !didRunLaunchAutomation, let launchAutomation, launchAutomation.plan.autoconnect else { return }
        guard let profile = profiles.first(where: { launchAutomation.plan.matches($0, seed: launchAutomation.seed) }) else { return }
        didRunLaunchAutomation = true
        markRelayReadiness(.loading(stage: .threadList), for: profile)
        await connection.connect(profile: profile)
        syncRelayReadiness(for: profile)
        guard connection.connectedRoute != nil else { return }
        path.append(AppRoute.workspaces)
        if let threadID = launchAutomationTargetThreadID() {
            path.append(AppRoute.session(threadID, isNew: false))
        }
    }

    private func launchAutomationTargetThreadID() -> String? {
        guard let route = connection.connectedRoute else { return nil }
        if let threadID = launchAutomation?.plan.threadID,
           route.relayThreadSummaries.contains(where: { $0.id == threadID })
        {
            return threadID
        }
        return route.relayThreadSummaries.first?.id
    }

    private func relayAutoprompt(for threadID: String) -> String? {
        guard let launchAutomation,
              launchAutomation.plan.autoconnect,
              connection.connectedRoute?.relayThreadSummaries.contains(where: { $0.id == threadID }) == true
        else {
            return nil
        }
        return launchAutomation.plan.autoprompt
    }

    @MainActor
    private func handleOpenURL(_ url: URL) async {
        do {
            let verificationLaunch = try RelayHostVerificationLaunchURL(url: url)
            connection.useRelayTransportMode(.p2pWebRTCDataChannel)
            try applyLaunchAutomation(verificationLaunch)
            await runLaunchAutomationIfNeeded()
        } catch RelayHostVerificationLaunchURLError.unsupportedURL {
            return
        } catch {
            loadError = String(describing: error)
        }
    }

    private func applyLaunchAutomation(_ verificationLaunch: RelayHostVerificationLaunchURL) throws {
        loadProfilesIfNeeded()
        guard let store else { return }
        try store.seedRelayHostIfNeeded(verificationLaunch.seed)
        launchAutomation = RelayHostLaunchAutomation(
            seed: verificationLaunch.seed,
            plan: verificationLaunch.plan
        )
        didRunLaunchAutomation = false
        profiles = store.list()
    }

    private static func makeConnectionState() -> AppConnectionState {
        let vault = (try? makeCredentialVault()) ?? VolatileCredentialVault()
        do {
            let documents = try documentsDirectory()
            let verifier = try PersistentKnownHostVerifier(
                store: FileKnownHostStore(fileURL: documents.appending(path: "known-hosts.json"))
            )
            return AppConnectionState(credentialVault: vault, knownHosts: verifier)
        } catch {
            return AppConnectionState(credentialVault: vault)
        }
    }

    private static func makeCredentialVault() throws -> CredentialVault {
        try LocalEncryptedCredentialVault(directory: LocalEncryptedCredentialVault.defaultDirectory())
    }

    private static func seedRelayHostIfRequested(into store: PersistentHostProfileStore) throws -> RelayHostLaunchAutomation? {
        let environment = ProcessInfo.processInfo.environment
        guard let seed = try? RelayHostLaunchSeed(environment: environment) else { return nil }
        try store.seedRelayHostIfNeeded(seed)
        return RelayHostLaunchAutomation(
            seed: seed,
            plan: RelayHostLaunchAutomationPlan(environment: environment)
        )
    }

    private static func documentsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}

private struct RelayHostLaunchAutomation {
    var seed: RelayHostLaunchSeed
    var plan: RelayHostLaunchAutomationPlan
}

private enum RelayReadinessFailureClassifier {
    static func reason(for message: String) -> RelayHostReadinessFailureReason {
        let normalized = message.lowercased()
        if normalized.contains("transport") || message.contains("尚未配置") {
            return .transportUnavailable
        }
        if normalized.contains("version") || message.contains("版本") {
            return .incompatibleVersion
        }
        if normalized.contains("pairing") || message.contains("配对") {
            return .pairingInvalid
        }
        if normalized.contains("didnotanswer") || message.contains("未响应 WebRTC") || message.contains("在线状态已过期") {
            return .hostAgentUnavailable
        }
        if normalized.contains("timeout") || message.contains("超时") {
            return .threadListTimeout
        }
        if normalized.contains("hostagent") || message.contains("HostAgent") {
            return .hostAgentUnavailable
        }
        return .unknown
    }
}

private final class VolatileCredentialVault: CredentialVault {
    func saveSecret(_ secret: String, protection: CredentialProtection) throws -> String {
        throw LocalEncryptedCredentialVaultError.invalidKey
    }

    func readSecret(id: String, authorization: CredentialAuthorization) throws -> String {
        throw CredentialVaultError.notFound
    }

    func deleteSecret(id: String) throws {}
}

enum AppRoute: Hashable {
    case addHostProfile
    case editHostProfile(UUID)
    case workspaces
    case remoteBrowser
    case session(String, isNew: Bool)
}

private struct ConnectionLogSheet: View {
    let title: String
    let logs: [ConnectionLogEntry]
    let progressMessage: String
    let isConnecting: Bool
    let pendingHostKeyConfirmation: PendingHostKeyConfirmation?
    let onRejectPendingHostKey: () -> Void
    let onConfirmPendingHostKey: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var waitingSeconds = 0
    private let progressTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logs) { entry in
                            ConnectionLogTerminalLine(entry: entry)
                        }

                        if isConnecting {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Date().formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary)
                                Text("RUN")
                                    .foregroundStyle(.blue)
                                Text(progressText)
                                    .foregroundStyle(.primary)
                            }
                            .font(.system(.footnote, design: .monospaced))
                            .padding(.vertical, 6)
                        }

                        if let pendingHostKeyConfirmation {
                            ConnectionLogHostKeyPrompt(
                                pending: pendingHostKeyConfirmation,
                                onReject: {
                                    onRejectPendingHostKey()
                                    dismiss()
                                },
                                onConfirm: onConfirmPendingHostKey
                            )
                            .padding(.top, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: max(320, geometry.size.height - 32), alignment: .topLeading)
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
            .onReceive(progressTimer) { _ in
                guard isConnecting else {
                    waitingSeconds = 0
                    return
                }
                waitingSeconds += 1
            }
            .onChange(of: progressMessage) { _, _ in
                waitingSeconds = 0
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var progressText: String {
        guard waitingSeconds >= 2 else { return progressMessage }
        return "\(progressMessage) 已等待 \(waitingSeconds) 秒"
    }
}

private struct ConnectionLogHostKeyPrompt: View {
    let pending: PendingHostKeyConfirmation
    let onReject: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认 Host Key")
                .font(.headline)
            Text("首次连接 \(pending.profileName) 时收到 host key fingerprint。确认这是目标主机后再信任。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(pending.fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("拒绝", role: .cancel, action: onReject)
                Spacer()
                Button("信任并连接", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ConnectionLogTerminalLine: View {
    let entry: ConnectionLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.createdAt.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.secondary)
            Text(levelLabel)
                .foregroundStyle(levelColor)
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.vertical, 6)
    }

    private var levelLabel: String {
        switch entry.level {
        case .info:
            return "INFO"
        case .success:
            return " OK "
        case .warning:
            return "WARN"
        case .error:
            return "ERR "
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

#Preview {
    RootView()
}
