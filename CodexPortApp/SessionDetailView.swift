import CodexPortCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let threadID: String
    let isNewThread: Bool
    let protocolClient: CodexProtocolClient?
    let events: AppServerEventSource?
    let route: ConnectedSessionRoute?
    let foregroundRefreshSignal: Int
    let relayAutoprompt: String?
    @State private var composer = InputComposer(modelDisplay: "5.5 超高", capabilities: .appDefault)
    @State private var sessionStore: SessionStore?
    @State private var relaySessionClientManager: RelayJSONLSessionClientManager?
    @State private var timeline = SessionTimelineState()
    @State private var errorMessage: String?
    @State private var isLoadingHistory = false
    @State private var approvalRequest: ApprovalRequest?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var notificationTask: Task<Void, Never>?
    @State private var serverRequestTask: Task<Void, Never>?
    @State private var liveTimelineRefreshTask: Task<Void, Never>?
    @State private var syncPollingTask: Task<Void, Never>?
    @State private var relayTimelinePollingTask: Task<Void, Never>?
    @State private var didSendRelayAutoprompt = false
    @State private var isRefreshingCurrentThread = false
    @State private var viewportHeight: CGFloat = 0
    @State private var timelineBottomY: CGFloat = 0
    @State private var expandedToolRowIDs: Set<String> = []
    @State private var isComposerExpanded = false
    @State private var transcriptRows: [TranscriptRow] = []
    @State private var scrollToBottomRequest = 0
    private let pickedAttachmentHandler = PickedAttachmentHandler()
    private let bottomAnchorID = "session-bottom-anchor"
    private let liveTimelineRefreshIntervalNanos: UInt64 = 80_000_000
    private let currentThreadSyncIntervalNanos: UInt64 = 2_000_000_000

    init(
        threadID: String,
        isNewThread: Bool = false,
        protocolClient: CodexProtocolClient?,
        events: AppServerEventSource? = nil,
        route: ConnectedSessionRoute? = nil,
        foregroundRefreshSignal: Int = 0,
        relayAutoprompt: String? = nil
    ) {
        self.threadID = threadID
        self.isNewThread = isNewThread
        self.protocolClient = protocolClient
        self.events = events
        self.route = route
        self.foregroundRefreshSignal = foregroundRefreshSignal
        self.relayAutoprompt = relayAutoprompt
    }

    var body: some View {
        ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let sessionStore, sessionStore.hasEarlierHistory {
                            LoadEarlierHistoryButton(
                                loadedCount: sessionStore.loadedHistoryItemCount,
                                totalCount: sessionStore.totalHistoryItemCount,
                                isTotalCountKnown: sessionStore.isTotalHistoryCountKnown,
                                action: loadEarlierHistory
                            )
                        }

                        ForEach(transcriptRows) { row in
                            SessionItemView(
                                row: row,
                                onToggleTool: {
                                    toggleToolRow(row.id)
                                }
                            )
                        }
                        Color.clear
                            .frame(height: transcriptBottomPadding)
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: TimelineBottomYPreferenceKey.self,
                                        value: proxy.frame(in: .named("sessionTimelineScroll")).maxY
                                    )
                                }
                            }
                    }
                    .padding()
                }
                .coordinateSpace(name: "sessionTimelineScroll")
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    collapseComposer()
                })
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TimelineViewportHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .overlay {
                    if isLoadingHistory, timeline.items.isEmpty {
                        SessionLoadingView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if shouldShowJumpToLatestButton {
                        JumpToLatestButton(action: jumpToLatestMessage)
                            .padding(.bottom, jumpButtonBottomPadding)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: shouldShowJumpToLatestButton)
                .onChange(of: scrollToBottomRequest) { _, _ in
                    withAnimation(.snappy) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onPreferenceChange(TimelineViewportHeightPreferenceKey.self) { height in
                    guard abs(viewportHeight - height) > 0.5 else { return }
                    viewportHeight = height
                    updatePinnedState()
                }
                .onPreferenceChange(TimelineBottomYPreferenceKey.self) { bottomY in
                    guard abs(timelineBottomY - bottomY) > 8 else { return }
                    timelineBottomY = bottomY
                    updatePinnedState()
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CodexInputBarView(
                composer: $composer,
                pendingAttachments: pendingAttachments,
                onSend: sendPreviewMessage,
                onStop: stopRunningTurn,
                onAttachPhoto: {
                    isPhotoPickerPresented = true
                },
                onAttachCamera: {
                    isCameraPresented = true
                },
                onAttachFile: {
                    isFileImporterPresented = true
                },
                onRemoveAttachment: { index in
                    removePendingAttachment(at: index)
                },
                isCompact: isComposerCompact,
                onExpand: expandComposer
            )
        }
        .navigationTitle("Codex")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard timeline.items.isEmpty else { return }
            if let route, route.isRelay {
                guard let context = route.relaySessionContext(threadID: threadID) else {
                    isLoadingHistory = false
                    errorMessage = "Relay 会话尚未在当前 Host 列表中。请返回工作区刷新会话列表后重试。"
                    return
                }
                let store = context.sessionStore
                let manager = context.clientManager
                sessionStore = store
                relaySessionClientManager = manager
                if !store.visibleItems.isEmpty {
                    isLoadingHistory = false
                    updateTimeline(store.visibleItems, source: .initialLoad)
                } else {
                    isLoadingHistory = true
                }
                do {
                    _ = try await manager.attach()
                    startRelayTimelinePolling(store: store)
                    await sendRelayAutopromptIfNeeded(using: manager)
                } catch RelayJSONLSessionClientManagerError.clientUnavailable {
                    isLoadingHistory = false
                    updateTimeline([.assistantMessage("Relay transport 尚未配置，无法连接 Host Agent。")], source: .initialLoad)
                } catch {
                    isLoadingHistory = false
                    errorMessage = sessionErrorMessage(for: error)
                }
                return
            }
            guard let protocolClient = route?.directProtocolClient ?? protocolClient else {
                updateTimeline([.assistantMessage("已打开会话 \(threadID)。")], source: .initialLoad)
                return
            }
            let store = SessionStore(protocolClient: protocolClient)
            do {
                if isNewThread {
                    store.openNew(threadID: threadID)
                } else {
                    isLoadingHistory = true
                    try await store.open(threadID: threadID)
                    isLoadingHistory = false
                }
                sessionStore = store
                updateTimeline(store.visibleItems, source: .initialLoad)
                listenForSessionEvents(store: store, events: route?.directEvents ?? events)
                if !isNewThread {
                    startCurrentThreadSyncPolling(store: store)
                }
                if timeline.items.isEmpty && !isNewThread {
                    updateTimeline([.assistantMessage("会话暂无可显示历史。")], source: .initialLoad)
                }
            } catch {
                isLoadingHistory = false
                errorMessage = sessionErrorMessage(for: error)
            }
        }
        .onDisappear {
            notificationTask?.cancel()
            serverRequestTask?.cancel()
            liveTimelineRefreshTask?.cancel()
            syncPollingTask?.cancel()
            relayTimelinePollingTask?.cancel()
            notificationTask = nil
            serverRequestTask = nil
            liveTimelineRefreshTask = nil
            syncPollingTask = nil
            relayTimelinePollingTask = nil
            relaySessionClientManager = nil
            if let sessionStore {
                if route?.isRelay != true {
                    Task {
                        await sessionStore.close()
                    }
                }
            }
        }
        .sheet(item: approvalBinding) { approval in
            ApprovalRequestView(request: approval.request) { action in
                respond(to: approval.request, action: action)
            }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhoto, matching: .images)
        .sheet(isPresented: $isCameraPresented) {
            CameraCaptureView { image in
                if let pending = pickedAttachmentHandler.cameraImage(image) {
                    appendPendingAttachment(pending)
                }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result, let pending = try? pickedAttachmentHandler.file(url: url) {
                appendPendingAttachment(pending)
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let pending = PendingAttachment(name: nextPhotoName(), kind: .image(detail: "high"), data: data)
                    appendPendingAttachment(pending)
                }
                selectedPhoto = nil
            }
        }
        .onChange(of: foregroundRefreshSignal) { _, _ in
            Task {
                await refreshCurrentThreadFromServer(surfaceError: true)
            }
        }
        .alert("会话失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func sendPreviewMessage() {
        guard composer.canSend else { return }
        if let sessionStore {
            Task {
                do {
                    if let relaySessionClientManager {
                        _ = try await relaySessionClientManager.sendPromptAndWaitForAcceptance(
                            composer.text,
                            timeout: .seconds(12)
                        )
                        updateTimeline(sessionStore.visibleItems, source: .liveUpdate)
                        composer.text = ""
                        composer.attachments.removeAll()
                        pendingAttachments.removeAll()
                        composer.isRunning = true
                        collapseComposer()
                        return
                    }
                    if route?.isRelay == true {
                        errorMessage = "Relay transport 尚未配置，消息未发送。"
                        return
                    }
                    if let protocolClient, !pendingAttachments.isEmpty {
                        let bridge = AttachmentComposerBridge(uploader: AttachmentUploader(
                            protocolClient: protocolClient,
                            remoteRoot: "~/.codex-port/attachments"
                        ))
                        try await sessionStore.send(
                            composer: composer,
                            pendingAttachments: pendingAttachments,
                            attachmentBridge: bridge
                        )
                        pendingAttachments.removeAll()
                    } else {
                        try await sessionStore.send(composer: composer)
                    }
                    updateTimeline(sessionStore.visibleItems, source: .liveUpdate)
                    composer.text = ""
                    composer.attachments.removeAll()
                    pendingAttachments.removeAll()
                    composer.isRunning = sessionStore.status == .running
                    collapseComposer()
                } catch {
                    errorMessage = sessionErrorMessage(for: error)
                }
            }
        } else {
            var previewItems = timeline.items
            previewItems.append(.assistantMessage(composer.text))
            updateTimeline(previewItems, source: .liveUpdate)
            composer.text = ""
            composer.attachments.removeAll()
            pendingAttachments.removeAll()
            composer.isRunning = true
            collapseComposer()
        }
    }

    private func appendPendingAttachment(_ pending: PendingAttachment) {
        expandComposer()
        pendingAttachments.append(pending)
        switch pending.kind {
        case let .image(detail):
            composer.attachments.append(.localImage(path: pending.name, detail: detail))
        case .file:
            composer.attachments.append(.remoteFile(path: pending.name))
        }
    }

    private func removePendingAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        pendingAttachments.remove(at: index)
        if composer.attachments.indices.contains(index) {
            composer.attachments.remove(at: index)
        }
    }

    private func nextPhotoName() -> String {
        let nextIndex = pendingAttachments.filter { attachment in
            if case .image = attachment.kind {
                return true
            }
            return false
        }.count + 1
        return "photo-\(nextIndex).jpg"
    }

    private func stopRunningTurn() {
        guard let sessionStore else {
            composer.isRunning = false
            return
        }
        Task {
            do {
                if let relaySessionClientManager {
                    try await relaySessionClientManager.interrupt()
                    composer.isRunning = false
                    refreshTranscriptRows()
                    return
                }
                try await sessionStore.interrupt()
                composer.isRunning = false
                refreshTranscriptRows()
            } catch {
                errorMessage = sessionErrorMessage(for: error)
            }
        }
    }

    private func loadEarlierHistory() {
        guard let sessionStore, !isNewThread else { return }
        Task {
            do {
                if let relaySessionClientManager, let cursor = sessionStore.earlierHistoryCursor {
                    _ = try await relaySessionClientManager.loadEarlierHistory(cursor: cursor)
                } else {
                    try await sessionStore.loadEarlierHistory()
                }
                updateTimeline(sessionStore.visibleItems, source: .historyPrepend)
            } catch {
                errorMessage = sessionErrorMessage(for: error)
            }
        }
    }

    @MainActor
    private func refreshCurrentThreadFromServer(
        expectedStore: SessionStore? = nil,
        surfaceError: Bool
    ) async {
        guard let sessionStore else { return }
        if let expectedStore, sessionStore !== expectedStore {
            return
        }
        if route?.isRelay == true {
            if timeline.items.isEmpty && !sessionStore.visibleItems.isEmpty {
                updateTimeline(sessionStore.visibleItems, source: .foregroundRefresh)
            }
            composer.isRunning = sessionStore.status == .running
            return
        }
        guard !isRefreshingCurrentThread else { return }
        isRefreshingCurrentThread = true
        let previousItems = sessionStore.visibleItems
        let previousStatus = sessionStore.status
        defer {
            isRefreshingCurrentThread = false
        }
        do {
            try await sessionStore.open(threadID: threadID)
            if previousItems != sessionStore.visibleItems || previousStatus != sessionStore.status {
                updateTimeline(sessionStore.visibleItems, source: .foregroundRefresh)
            }
            composer.isRunning = sessionStore.status == .running
        } catch {
            if surfaceError {
                errorMessage = sessionErrorMessage(for: error)
            }
        }
    }

    private func jumpToLatestMessage() {
        timeline.userReturnedToBottom()
        refreshTranscriptRows()
        scrollToBottomRequest += 1
    }

    private func expandComposer() {
        withAnimation(.snappy) {
            isComposerExpanded = true
        }
    }

    private func collapseComposer() {
        withAnimation(.snappy) {
            isComposerExpanded = false
        }
        dismissKeyboard()
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func listenForSessionEvents(store: SessionStore, events: AppServerEventSource?) {
        guard let events else { return }
        notificationTask?.cancel()
        serverRequestTask?.cancel()
        liveTimelineRefreshTask?.cancel()
        liveTimelineRefreshTask = nil
        notificationTask = Task {
            while let notification = await events.nextNotification() {
                guard !Task.isCancelled else { return }
                store.receive(notification: notification)
                scheduleLiveTimelineRefresh(store: store)
            }
        }
        serverRequestTask = Task {
            while let serverRequest = await events.nextServerRequest() {
                guard !Task.isCancelled else { return }
                if let request = ApprovalRequest(serverRequest: serverRequest) {
                    approvalRequest = request
                }
            }
        }
    }

    @MainActor
    private func startCurrentThreadSyncPolling(store: SessionStore) {
        syncPollingTask?.cancel()
        syncPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: currentThreadSyncIntervalNanos)
                guard !Task.isCancelled else { return }
                await refreshCurrentThreadFromServer(expectedStore: store, surfaceError: false)
            }
        }
    }

    @MainActor
    private func startRelayTimelinePolling(store: SessionStore) {
        relayTimelinePollingTask?.cancel()
        relayTimelinePollingTask = Task {
            var previousItems = store.visibleItems
            var previousStatus = store.status
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: liveTimelineRefreshIntervalNanos)
                guard !Task.isCancelled else { return }
                if store.visibleItems != previousItems || store.status != previousStatus {
                    previousItems = store.visibleItems
                    previousStatus = store.status
                    if !store.visibleItems.isEmpty || store.status != .running {
                        isLoadingHistory = false
                    }
                    updateTimeline(store.visibleItems, source: .liveUpdate)
                    composer.isRunning = store.status == .running
                }
            }
        }
    }

    @MainActor
    private func sendRelayAutopromptIfNeeded(using relayClientManager: RelayJSONLSessionClientManager) async {
        guard !didSendRelayAutoprompt,
              let relayAutoprompt,
              !relayAutoprompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        didSendRelayAutoprompt = true
        do {
            _ = try await relayClientManager.sendPromptAndWaitForAcceptance(
                relayAutoprompt,
                writeID: "afk-autoprompt-\(UUID().uuidString)",
                timeout: .seconds(12)
            )
            isLoadingHistory = false
            updateTimeline(sessionStore?.visibleItems ?? [], source: .liveUpdate)
            composer.isRunning = true
        } catch {
            errorMessage = sessionErrorMessage(for: error)
        }
    }

    private func scheduleLiveTimelineRefresh(store: SessionStore) {
        guard liveTimelineRefreshTask == nil else { return }
        liveTimelineRefreshTask = Task {
            try? await Task.sleep(nanoseconds: liveTimelineRefreshIntervalNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard sessionStore === store else {
                    liveTimelineRefreshTask = nil
                    return
                }
                updateTimeline(store.visibleItems, source: .liveUpdate)
                composer.isRunning = store.status == .running
                liveTimelineRefreshTask = nil
            }
        }
    }

    private func updateTimeline(_ items: [VisibleItem], source: TimelineUpdateSource) {
        let anchor: SessionScrollAnchor
        switch source {
        case .initialLoad:
            anchor = timeline.replaceLoadedItems(items)
        case .historyPrepend:
            anchor = timeline.prependHistoryItems(items)
        case .liveUpdate:
            anchor = timeline.applyLiveItems(items)
        case .foregroundRefresh:
            anchor = timeline.applyForegroundRefreshItems(items)
        }
        refreshTranscriptRows()
        if anchor == .bottom {
            scrollToBottomRequest += 1
        }
    }

    private func updatePinnedState() {
        guard viewportHeight > 0, !timeline.items.isEmpty else { return }
        let threshold: CGFloat = 56
        let bottomDistance = timelineBottomY - viewportHeight
        let didChange: Bool
        if bottomDistance <= threshold {
            didChange = timeline.userReturnedToBottom()
        } else {
            didChange = timeline.userMovedAwayFromBottom()
        }
        if didChange {
            refreshTranscriptRows()
        }
    }

    private func respond(to request: ApprovalRequest, action: ApprovalAction) {
        guard let events else {
            approvalRequest = nil
            return
        }
        Task {
            do {
                let response = request.response(for: action)
                try await events.respond(to: response.id, result: response.result)
                approvalRequest = nil
            } catch {
                errorMessage = sessionErrorMessage(for: error)
            }
        }
    }

    private func toggleToolRow(_ id: String) {
        if expandedToolRowIDs.contains(id) {
            expandedToolRowIDs.remove(id)
        } else {
            expandedToolRowIDs.insert(id)
        }
        refreshTranscriptRows()
    }

    private func refreshTranscriptRows() {
        transcriptRows = TranscriptPresentation.rows(
            for: timeline.items,
            expandedToolRowIDs: expandedToolRowIDs,
            status: sessionStore?.status
        )
    }

    private func sessionErrorMessage(for error: Error) -> String {
        if case let JSONRPCError.requestTimedOut(method, seconds) = error {
            if method == "thread/resume" || method == "thread/turns/list" {
                return "加载会话历史超过 \(Int(seconds)) 秒未响应。请返回后重试，或稍后重新连接 Codex。"
            }
            return "\(method) 请求超过 \(Int(seconds)) 秒未响应。"
        }
        if case let JSONRPCError.remote(_, message) = error {
            if message.localizedCaseInsensitiveContains("no rollout found")
                || message.localizedCaseInsensitiveContains("thread id") {
                return "远端找不到这个会话。请返回工作区刷新列表后重试，或在该项目中新建会话。"
            }
            return "Codex 返回错误：\(message)"
        }
        if RelayJSONLSessionClientManager.shouldRecreateClient(after: error) {
            return "Relay 连接已中断，已自动重连但未完成本次请求。请确认 HostAgent 在线后重试。"
        }
        if let relayError = error as? RelayJSONLSessionClientError {
            switch relayError {
            case .timedOut:
                return "发送后未收到 HostAgent 写入确认。请确认 HostAgent 菜单应用在线，重新进入会话后再试。"
            case let .hostAgentError(reason):
                return "HostAgent 返回错误：\(reason)"
            case let .writeFailed(reason):
                return "HostAgent 未能写入 Codex 会话：\(reason)"
            }
        }
        if error as? RelayJSONLSessionClientManagerError == .clientUnavailable {
            return "Relay transport 尚未配置，无法连接 Host Agent。"
        }
        return String(describing: error)
    }

    private var shouldShowJumpToLatestButton: Bool {
        !timeline.isPinnedToBottom && !timeline.items.isEmpty && !isLoadingHistory
    }

    private var isComposerCompact: Bool {
        !isComposerExpanded
    }

    private var transcriptBottomPadding: CGFloat {
        CGFloat(SessionDetailLayoutMetrics.composerSafeAreaInset(isComposerCompact: isComposerCompact).transcriptBottomSpacer)
    }

    private var jumpButtonBottomPadding: CGFloat {
        CGFloat(SessionDetailLayoutMetrics.composerSafeAreaInset(isComposerCompact: isComposerCompact).jumpToLatestBottomPadding)
    }

    private var approvalBinding: Binding<IdentifiedApprovalRequest?> {
        Binding(
            get: {
                approvalRequest.map(IdentifiedApprovalRequest.init(request:))
            },
            set: { value in
                approvalRequest = value?.request
            }
        )
    }
}

private enum TimelineUpdateSource {
    case initialLoad
    case historyPrepend
    case liveUpdate
    case foregroundRefresh
}

private struct TimelineViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TimelineBottomYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct IdentifiedApprovalRequest: Identifiable {
    let id = UUID()
    let request: ApprovalRequest
}

private struct SessionItemView: View {
    let row: TranscriptRow
    let onToggleTool: () -> Void

    var body: some View {
        switch row.kind {
        case .userBubble:
            HStack {
                Spacer(minLength: 32)
                Text(row.body)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .copyableTranscriptRow(row)
        case .assistantText:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                    TranscriptBlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .copyableTranscriptRow(row)
        case .toolOutput:
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onToggleTool) {
                    HStack(spacing: 8) {
                        Image(systemName: row.systemImage ?? "wrench.and.screwdriver")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title ?? "工具调用")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let summary = row.summary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: row.isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !row.isCollapsed {
                    if !row.diffLines.isEmpty {
                        DiffBlockView(lines: row.diffLines, text: row.body)
                    } else {
                        ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                            TranscriptBlockView(block: block)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .copyableTranscriptRow(row)
        case .thinking:
            Text(row.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .textSelection(.enabled)
                .copyableTranscriptRow(row)
        case .status:
            Text(row.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .textSelection(.enabled)
                .copyableTranscriptRow(row)
        }
    }
}

private extension View {
    func copyableTranscriptRow(_ row: TranscriptRow) -> some View {
        modifier(TranscriptCopyModifier(payload: row.copyPayload))
    }
}

private struct TranscriptCopyModifier: ViewModifier {
    let payload: String?
    @State private var copied = false

    func body(content: Content) -> some View {
        guard let payload, !payload.isEmpty else {
            return AnyView(content)
        }
        return AnyView(content.contextMenu {
            Button {
                UIPasteboard.general.string = payload
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    await MainActor.run {
                        copied = false
                    }
                }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        })
    }
}

private struct LoadEarlierHistoryButton: View {
    let loadedCount: Int
    let totalCount: Int
    let isTotalCountKnown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up.circle")
                Text("加载更早历史")
                Text(progressText)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("加载更早历史")
    }

    private var progressText: String {
        isTotalCountKnown ? "\(loadedCount)/\(totalCount)" : "已加载 \(loadedCount)"
    }
}

private struct SessionLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载近期历史")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 8)
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator).opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("滚动到最新消息")
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptBlock

    var body: some View {
        switch block {
        case let .text(text):
            MarkdownTextBlockView(text: text)
        case let .code(language, text):
            TranscriptCodeBlockView(language: language, text: text)
        }
    }
}

private struct MarkdownTextBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .blank:
                    Color.clear.frame(height: 2)
                case let .paragraph(text):
                    inlineText(for: text)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                case let .listItem(text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        inlineText(for: text)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var lines: [MarkdownTextLine] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { MarkdownTextLine(String($0)) }
    }

    private func inlineText(for text: String) -> Text {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        var output = Text("")
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 2) {
                output = output + Text(part)
            } else {
                output = output + Text(part)
                    .font(.body.monospaced())
                    .foregroundColor(.accentColor)
            }
        }
        return output
    }
}

private enum MarkdownTextLine {
    case blank
    case paragraph(String)
    case listItem(String)

    init(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .blank
        } else if trimmed.hasPrefix("- ") {
            self = .listItem(String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("* ") {
            self = .listItem(String(trimmed.dropFirst(2)))
        } else {
            self = .paragraph(line)
        }
    }
}

private struct TranscriptCodeBlockView: View {
    let language: TranscriptCodeLanguage
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.displayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(text)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copied ? .green : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制代码")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView(.horizontal) {
                Text(highlighted(text, language: language))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await MainActor.run {
                copied = false
            }
        }
    }

    private func highlighted(_ text: String, language: TranscriptCodeLanguage) -> AttributedString {
        var output = AttributedString(text)
        output.foregroundColor = .primary
        switch language {
        case .swift, .typescript, .javascript:
            for keyword in ["let", "var", "func", "struct", "class", "enum", "return", "import", "const", "function", "type", "interface"] {
                color(keyword, in: &output, as: .blue)
            }
        case .shell:
            for keyword in ["git", "swift", "xcodebuild", "cd", "ls", "rg"] {
                color(keyword, in: &output, as: .blue)
            }
        case .json, .markdown, .plainText:
            break
        }
        return output
    }

    private func color(_ token: String, in text: inout AttributedString, as color: Color) {
        var searchStart = text.startIndex
        while let range = text[searchStart...].range(of: token) {
            text[range].foregroundColor = color
            searchStart = range.upperBound
        }
    }
}

private struct DiffBlockView: View {
    let lines: [TranscriptDiffLine]
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DIFF")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(text)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copied ? .green : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制 diff")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.footnote.monospaced())
                            .foregroundStyle(foreground(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
    }

    private func foreground(for kind: TranscriptDiffLineKind) -> Color {
        switch kind {
        case .added:
            return .green
        case .removed:
            return .red
        case .context:
            return .secondary
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await MainActor.run {
                copied = false
            }
        }
    }
}

private extension TranscriptCodeLanguage {
    var displayLabel: String {
        switch self {
        case .swift:
            return "SWIFT"
        case .typescript:
            return "TYPESCRIPT"
        case .javascript:
            return "JAVASCRIPT"
        case .shell:
            return "BASH"
        case .json:
            return "JSON"
        case .markdown:
            return "MARKDOWN"
        case .plainText:
            return "PLAIN TEXT"
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(threadID: "thread-preview", protocolClient: nil)
    }
}
