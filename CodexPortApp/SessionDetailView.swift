import CodexPortCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let threadID: String
    let protocolClient: CodexProtocolClient?
    let events: AppServerEventSource?
    @State private var composer = InputComposer(modelDisplay: "5.5 超高", capabilities: .appDefault)
    @State private var sessionStore: SessionStore?
    @State private var timeline = SessionTimelineState()
    @State private var errorMessage: String?
    @State private var approvalRequest: ApprovalRequest?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var notificationTask: Task<Void, Never>?
    @State private var serverRequestTask: Task<Void, Never>?
    @State private var scrollAnchor = UUID()
    @State private var viewportHeight: CGFloat = 0
    @State private var expandedToolRowIDs: Set<String> = []
    private let pickedAttachmentHandler = PickedAttachmentHandler()

    init(threadID: String, protocolClient: CodexProtocolClient?, events: AppServerEventSource? = nil) {
        self.threadID = threadID
        self.protocolClient = protocolClient
        self.events = events
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(TranscriptPresentation.rows(
                            for: timeline.items,
                            expandedToolRowIDs: expandedToolRowIDs,
                            status: sessionStore?.status
                        )) { row in
                            SessionItemView(
                                row: row,
                                onToggleTool: {
                                    toggleToolRow(row.id)
                                }
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(scrollAnchor)
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
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TimelineViewportHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .onChange(of: scrollAnchor) { _, anchor in
                    withAnimation(.snappy) {
                        proxy.scrollTo(anchor, anchor: .bottom)
                    }
                }
                .onPreferenceChange(TimelineViewportHeightPreferenceKey.self) { height in
                    viewportHeight = height
                }
                .onPreferenceChange(TimelineBottomYPreferenceKey.self) { bottomY in
                    updatePinnedState(bottomY: bottomY)
                }
            }

            CodexInputBarView(
                composer: $composer,
                onSend: sendPreviewMessage,
                onStop: stopRunningTurn,
                onAttachCamera: {
                    isCameraPresented = true
                },
                onAttachFile: {
                    isFileImporterPresented = true
                }
            )
        }
        .navigationTitle("Codex")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard timeline.items.isEmpty else { return }
            guard let protocolClient else {
                updateTimeline([.assistantMessage("已打开会话 \(threadID)。")], source: .initialLoad)
                return
            }
            let store = SessionStore(protocolClient: protocolClient)
            do {
                try await store.open(threadID: threadID)
                sessionStore = store
                updateTimeline(store.visibleItems, source: .initialLoad)
                listenForSessionEvents(store: store)
                if timeline.items.isEmpty {
                    updateTimeline([.assistantMessage("会话暂无可显示历史。")], source: .initialLoad)
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
        .onDisappear {
            notificationTask?.cancel()
            serverRequestTask?.cancel()
            notificationTask = nil
            serverRequestTask = nil
            if let sessionStore {
                Task {
                    await sessionStore.close()
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
                    pendingAttachments.append(pending)
                    composer.attachments.append(.localImage(path: pending.name, detail: "high"))
                }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result, let pending = try? pickedAttachmentHandler.file(url: url) {
                pendingAttachments.append(pending)
                composer.attachments.append(.remoteFile(path: pending.name))
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let pending = PendingAttachment(name: "photo.jpg", kind: .image(detail: "high"), data: data)
                    pendingAttachments.append(pending)
                    composer.attachments.append(.localImage(path: pending.name, detail: "high"))
                }
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
                    composer.isRunning = sessionStore.status == .running
                } catch {
                    errorMessage = String(describing: error)
                }
            }
        } else {
            var previewItems = timeline.items
            previewItems.append(.assistantMessage(composer.text))
            updateTimeline(previewItems, source: .liveUpdate)
            composer.text = ""
            composer.isRunning = true
        }
    }

    private func stopRunningTurn() {
        guard let sessionStore else {
            composer.isRunning = false
            return
        }
        Task {
            do {
                try await sessionStore.interrupt()
                composer.isRunning = false
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func listenForSessionEvents(store: SessionStore) {
        guard let events else { return }
        notificationTask?.cancel()
        serverRequestTask?.cancel()
        notificationTask = Task {
            while let notification = await events.nextNotification() {
                guard !Task.isCancelled else { return }
                store.receive(notification: notification)
                updateTimeline(store.visibleItems, source: .liveUpdate)
                composer.isRunning = store.status == .running
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

    private func updateTimeline(_ items: [VisibleItem], source: TimelineUpdateSource) {
        let anchor: SessionScrollAnchor
        switch source {
        case .initialLoad:
            anchor = timeline.replaceLoadedItems(items)
        case .liveUpdate:
            anchor = timeline.applyLiveItems(items)
        }
        if anchor == .bottom {
            scrollAnchor = UUID()
        }
    }

    private func updatePinnedState(bottomY: CGFloat) {
        guard viewportHeight > 0, !timeline.items.isEmpty else { return }
        let threshold: CGFloat = 56
        if bottomY <= viewportHeight + threshold {
            timeline.userReturnedToBottom()
        } else {
            timeline.userMovedAwayFromBottom()
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
                errorMessage = String(describing: error)
            }
        }
    }

    private func toggleToolRow(_ id: String) {
        if expandedToolRowIDs.contains(id) {
            expandedToolRowIDs.remove(id)
        } else {
            expandedToolRowIDs.insert(id)
        }
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
    case liveUpdate
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistantText:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                    TranscriptBlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
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
        case .thinking:
            Text(row.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
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
