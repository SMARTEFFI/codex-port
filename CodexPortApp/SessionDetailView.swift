import CodexPortCore
import Photos
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
    @State private var imageGallery: ImageAttachmentGalleryState?
    @State private var resolvedImageAttachmentSources: [String: MessageAttachmentSource] = [:]
    @State private var resolvingImageAttachmentKeys: Set<String> = []
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
                                onOpenImage: { imageID in
                                    openImageGallery(row: row, imageID: imageID)
                                },
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
                skillCatalog: .codexDefaults,
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
                    let pending = PickedAttachmentHandler.pickedImage(name: nextPhotoName(), data: data)
                    appendPendingAttachment(pending)
                }
                selectedPhoto = nil
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { imageGallery != nil },
            set: { if !$0 { imageGallery = nil } }
        )) {
            if let gallery = imageGallery {
                ImageAttachmentGalleryView(
                    gallery: gallery,
                    saver: UIKitPhotoSaver(),
                    onUpdate: { imageGallery = $0 },
                    onDismiss: { imageGallery = nil }
                )
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
                        _ = try await relaySessionClientManager.send(
                            composer: composer,
                            pendingAttachments: pendingAttachments,
                            timeout: .seconds(12)
                        )
                        updateTimeline(sessionStore.visibleItems, source: .liveUpdate)
                        composer.text = ""
                        composer.attachments.removeAll()
                        composer.message = StructuredUserMessage(body: "")
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
                    composer.message = StructuredUserMessage(body: "")
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
            composer.message = StructuredUserMessage(body: "")
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

    private func openImageGallery(row: TranscriptRow, imageID: String) {
        imageGallery = ImageAttachmentGalleryState(
            items: row.imageAttachments,
            opening: imageID
        )
        resolveRemoteGalleryImageIfNeeded(row: row, imageID: imageID)
    }

    private func resolveRemoteGalleryImageIfNeeded(row: TranscriptRow, imageID: String) {
        guard
            let item = row.imageAttachments.first(where: { $0.id == imageID }),
            case let .remote(path) = item.availability,
            let relaySessionClientManager
        else {
            return
        }
        resolveRemoteGalleryImage(
            rowID: row.id,
            item: item,
            path: path,
            using: relaySessionClientManager,
            updateGallery: true
        )
    }

    private func refreshTranscriptRows() {
        let rows = TranscriptPresentation.rows(
            for: timeline.items,
            expandedToolRowIDs: expandedToolRowIDs,
            status: sessionStore?.status
        )
        transcriptRows = rows.map(applyingResolvedImageSources)
        prefetchVisibleRemoteImages(in: transcriptRows)
    }

    private func applyingResolvedImageSources(to row: TranscriptRow) -> TranscriptRow {
        guard !row.imageAttachments.isEmpty else { return row }
        var row = row
        row.imageAttachments = row.imageAttachments.map { item in
            guard let source = resolvedImageAttachmentSources[resolvedImageKey(rowID: row.id, imageID: item.id)] else { return item }
            var next = item
            switch source {
            case let .localCache(path):
                next.availability = .available(localPath: path)
            case let .remoteHostPath(path):
                next.availability = .remote(path: path)
            case let .unavailable(reason):
                next.availability = .unavailable(reason)
            }
            return next
        }
        return row
    }

    private func prefetchVisibleRemoteImages(in rows: [TranscriptRow]) {
        guard let relaySessionClientManager else { return }
        for row in rows {
            for item in row.imageAttachments {
                guard case let .remote(path) = item.availability else { continue }
                resolveRemoteGalleryImage(
                    rowID: row.id,
                    item: item,
                    path: path,
                    using: relaySessionClientManager,
                    updateGallery: false
                )
            }
        }
    }

    private func resolvedImageKey(rowID: String, imageID: String) -> String {
        "\(rowID):\(imageID)"
    }

    private func resolveRemoteGalleryImage(
        rowID: String,
        item: ImageAttachmentGalleryItem,
        path: String,
        using relaySessionClientManager: RelayJSONLSessionClientManager,
        updateGallery: Bool
    ) {
        let key = resolvedImageKey(rowID: rowID, imageID: item.id)
        guard !resolvingImageAttachmentKeys.contains(key) else { return }
        resolvingImageAttachmentKeys.insert(key)
        let attachment = MessageAttachment(
            id: item.id,
            kind: .image(contentType: nil, detail: "high"),
            displayName: item.displayName,
            source: .remoteHostPath(path)
        )
        Task {
            let resolver = RemoteImageAttachmentResolver(
                reader: relaySessionClientManager,
                cache: AppRemoteImageCache(),
                maxBytes: 8_000_000
            )
            let resolvedAttachment = await resolver.resolve(attachment)
            guard let resolvedItem = ImageAttachmentGalleryItem(attachment: resolvedAttachment) else {
                return
            }
            await MainActor.run {
                resolvingImageAttachmentKeys.remove(key)
                resolvedImageAttachmentSources[key] = resolvedAttachment.source
                if updateGallery, var gallery = imageGallery {
                    gallery.replaceItem(resolvedItem)
                    imageGallery = gallery
                }
                refreshTranscriptRows()
            }
        }
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
    let onOpenImage: (String) -> Void
    let onToggleTool: () -> Void

    var body: some View {
        switch row.kind {
        case .userBubble:
            HStack {
                Spacer(minLength: 32)
                UserMessageBubble(row: row, onOpenImage: onOpenImage)
            }
            .copyableTranscriptRow(row)
        case .assistantText:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(linkedBlocks(for: row).enumerated()), id: \.offset) { _, block in
                    TranscriptBlockView(
                        block: block.block,
                        links: block.links,
                        onOpenLink: { link in
                            openTranscriptLink(link)
                        }
                    )
                }
                TranscriptImageAttachmentStrip(row: row, onOpenImage: onOpenImage)
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
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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

    private func openTranscriptLink(_ link: TranscriptLink) {
        if let imageAttachmentID = link.imageAttachmentID {
            onOpenImage(imageAttachmentID)
        }
    }

    private func linkedBlocks(for row: TranscriptRow) -> [(block: TranscriptBlock, links: [TranscriptLink])] {
        var remainingLinks = row.links
        return row.blocks.map { block in
            guard case let .text(text) = block, !remainingLinks.isEmpty else {
                return (block, [])
            }
            var linksInBlock: [TranscriptLink] = []
            var stillRemaining: [TranscriptLink] = []
            for link in remainingLinks {
                if text.contains(link.displayText) {
                    linksInBlock.append(link)
                } else {
                    stillRemaining.append(link)
                }
            }
            remainingLinks = stillRemaining
            return (block, linksInBlock)
        }
    }
}

private struct UserMessageBubble: View {
    let row: TranscriptRow
    let onOpenImage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !row.skillChips.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(row.skillChips, id: \.identifier) { chip in
                        TranscriptSkillChipView(chip: chip)
                    }
                }
            }

            if !row.body.isEmpty {
                Text(row.body)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }

            TranscriptImageAttachmentStrip(row: row, onOpenImage: onOpenImage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TranscriptImageAttachmentStrip: View {
    let row: TranscriptRow
    let onOpenImage: (String) -> Void

    var body: some View {
        if !row.imageAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(row.imageAttachments) { attachment in
                        TranscriptImageThumbnail(item: attachment) {
                            onOpenImage(attachment.id)
                        }
                    }
                }
            }
        }
    }
}

private struct TranscriptSkillChipView: View {
    let chip: TranscriptSkillChip

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.caption.weight(.semibold))
            Text(chip.displayName)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(.systemBackground).opacity(0.75))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }
}

private struct TranscriptImageThumbnail: View {
    let item: ImageAttachmentGalleryItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            thumbnail
                .frame(width: 104, height: 104)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(item.displayName)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.availability {
        case let .available(localPath):
            if let image = UIImage(contentsOfFile: localPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                unavailableView("图片不可用")
            }
        case .remote:
            unavailableView("待拉取")
        case let .unavailable(reason):
            unavailableView(reason)
        }
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title3)
            Text(reason)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
    }
}

private struct ImageAttachmentGalleryView: View {
    var gallery: ImageAttachmentGalleryState
    let saver: PhotoSaving
    let onUpdate: (ImageAttachmentGalleryState) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let item = gallery.currentItem {
                GalleryImageContent(item: item)
                    .padding(.horizontal, 18)
            }

            VStack {
                HStack(spacing: 12) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 42, height: 42)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("关闭")

                    Spacer()

                    Button {
                        Task {
                            var nextGallery = gallery
                            await nextGallery.saveCurrentImage(using: saver)
                            await MainActor.run {
                                onUpdate(nextGallery)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.headline)
                            .frame(width: 42, height: 42)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("保存图片")
                }
                .foregroundStyle(.white)
                .padding()

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        var nextGallery = gallery
                        nextGallery.movePrevious()
                        onUpdate(nextGallery)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 48, height: 48)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .disabled(gallery.currentIndex == 0)

                    Text(gallery.currentItem?.displayName ?? "图片")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)

                    Button {
                        var nextGallery = gallery
                        nextGallery.moveNext()
                        onUpdate(nextGallery)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 48, height: 48)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .disabled(gallery.currentIndex >= gallery.items.count - 1)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .alert(
            gallery.saveFeedback?.title ?? "保存图片",
            isPresented: Binding(
                get: { gallery.saveFeedback != nil },
                set: { isPresented in
                    if !isPresented {
                        var nextGallery = gallery
                        nextGallery.clearSaveFeedback()
                        onUpdate(nextGallery)
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(gallery.saveFeedback?.message ?? "")
        }
    }
}

private struct GalleryImageContent: View {
    let item: ImageAttachmentGalleryItem

    var body: some View {
        switch item.availability {
        case let .available(localPath):
            if let image = UIImage(contentsOfFile: localPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GalleryPlaceholder(systemImage: "photo", message: "图片不可用")
            }
        case .remote:
            GalleryPlaceholder(systemImage: "icloud.and.arrow.down", message: "远端图片待拉取")
        case let .unavailable(reason):
            GalleryPlaceholder(systemImage: "exclamationmark.triangle", message: reason)
        }
    }
}

private struct GalleryPlaceholder: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.78))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class UIKitPhotoSaver: PhotoSaving {
    func saveImage(atLocalPath path: String) async -> Result<Void, PhotoSaveError> {
        guard let image = UIImage(contentsOfFile: path) else {
            return .failure(.systemFailure("图片不可用"))
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .failure(.permissionDenied)
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return .success(())
        } catch {
            return .failure(.systemFailure("保存图片失败"))
        }
    }
}

private final class AppRemoteImageCache: RemoteImageCaching {
    func store(_ content: RemoteFileContent, attachmentID: String) async -> Result<String, RemoteImageCacheError> {
        do {
            let directory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("RemoteImageAttachments", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let extensionName = URL(fileURLWithPath: content.path).pathExtension
            let fileName = extensionName.isEmpty ? attachmentID : "\(attachmentID).\(extensionName)"
            let fileURL = directory.appendingPathComponent(fileName)
            try content.data.write(to: fileURL, options: [.atomic])
            return .success(fileURL.path)
        } catch {
            return .failure(.writeFailed("图片缓存失败"))
        }
    }
}

private extension ImageAttachmentSaveFeedback {
    var title: String {
        switch self {
        case .success:
            return "保存成功"
        case .failure:
            return "保存失败"
        }
    }

    var message: String {
        switch self {
        case let .success(message), let .failure(message):
            return message
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
    var links: [TranscriptLink] = []
    var onOpenLink: ((TranscriptLink) -> Void)?

    var body: some View {
        switch block {
        case let .text(text):
            MarkdownTextBlockView(text: text, links: links, onOpenLink: onOpenLink)
        case let .code(language, text):
            TranscriptCodeBlockView(language: language, text: text)
        }
    }
}

private struct MarkdownTextBlockView: View {
    let text: String
    var links: [TranscriptLink] = []
    var onOpenLink: ((TranscriptLink) -> Void)?

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
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "codexport-image",
                  let link = links.first(where: { $0.id == url.host() })
            else {
                return .systemAction
            }
            onOpenLink?(link)
            return .handled
        })
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
                output = output + Text(linkedText(part))
            } else {
                output = output + Text(part)
                    .font(.body.monospaced())
                    .foregroundColor(.accentColor)
            }
        }
        return output
    }

    private func linkedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !links.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        for link in links {
            guard let range = attributed[searchStart...].range(of: link.displayText) else {
                continue
            }
            attributed[range].foregroundColor = .blue
            attributed[range].underlineStyle = .single
            attributed[range].link = link.imageAttachmentID == nil
                ? externalURL(for: link.target)
                : URL(string: "codexport-image://\(link.id)")
            searchStart = range.upperBound
        }
        return attributed
    }

    private func externalURL(for target: String) -> URL? {
        if let url = URL(string: target), url.scheme != nil {
            return url
        }
        if target.hasPrefix("/") || target.hasPrefix("~/") {
            let path = target.hasPrefix("~/")
                ? NSString(string: target).expandingTildeInPath
                : target
            return URL(fileURLWithPath: path)
        }
        return nil
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
            return "Shell"
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
