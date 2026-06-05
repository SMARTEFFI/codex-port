import CodexPortCore
import SwiftUI

struct WorkspaceListView: View {
    @Binding var grouping: WorkspaceGrouping
    let projects: [WorkspaceProject]
    let projectThreadGroups: [WorkspaceProjectThreadGroup]
    let dayThreadGroups: [WorkspaceDayThreadGroup]
    let recentThreads: [ThreadSummary]
    let startingThreadCWDs: Set<String>
    let onOpenSession: (ThreadSummary) -> Void
    let onStartProjectSession: (WorkspaceProject) -> Void
    let onBrowseWorkspace: () -> Void
    @State private var expandedProjectIDs: Set<String> = []
    @State private var expandedDayGroupIDs: Set<String> = []
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var collapsedDayGroupIDs: Set<String> = []
    @State private var visibleProjectGroupLimit = Self.initialVisibleGroupLimit
    @State private var visibleDayGroupLimit = Self.initialVisibleGroupLimit

    private static let initialVisibleGroupLimit = 5
    private static let groupPageSize = 5

    init(
        grouping: Binding<WorkspaceGrouping>,
        projects: [WorkspaceProject],
        projectThreadGroups: [WorkspaceProjectThreadGroup] = [],
        dayThreadGroups: [WorkspaceDayThreadGroup] = [],
        recentThreads: [ThreadSummary],
        startingThreadCWDs: Set<String> = [],
        onOpenSession: @escaping (ThreadSummary) -> Void,
        onStartProjectSession: @escaping (WorkspaceProject) -> Void,
        onBrowseWorkspace: @escaping () -> Void
    ) {
        self._grouping = grouping
        self.projects = projects
        self.projectThreadGroups = projectThreadGroups
        self.dayThreadGroups = dayThreadGroups
        self.recentThreads = recentThreads
        self.startingThreadCWDs = startingThreadCWDs
        self.onOpenSession = onOpenSession
        self.onStartProjectSession = onStartProjectSession
        self.onBrowseWorkspace = onBrowseWorkspace
    }

    var body: some View {
        List {
            if grouping == .byProject {
                if displayedProjectGroups.isEmpty {
                    emptyWorkspaceSection
                } else {
                    ForEach(visibleProjectGroups) { group in
                        Section {
                            if !isCollapsed(group) {
                                ForEach(threads(for: group)) { thread in
                                    Button {
                                        onOpenSession(thread)
                                    } label: {
                                        RecentThreadRow(thread: thread, showsProjectPath: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if hiddenCount(for: group) > 0 {
                                    Button {
                                        expandedProjectIDs.insert(group.id)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text("另有 \(hiddenCount(for: group)) 个更早会话")
                                            Image(systemName: "chevron.down")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            WorkspaceProjectHeader(
                                project: group.project,
                                isCollapsed: isCollapsed(group),
                                isStartingSession: startingThreadCWDs.contains(group.project.cwd),
                                onToggleCollapse: {
                                    toggleProjectCollapse(group.id)
                                },
                                onStartSession: {
                                    onStartProjectSession(group.project)
                                }
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                    }
                    if hasMoreProjectGroups {
                        WorkspaceGroupPaginationRow(
                            title: "上拉加载更多项目",
                            remainingCount: remainingProjectGroupCount,
                            onLoadMore: loadMoreProjectGroups
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                    }
                }
            } else {
                if recentThreads.isEmpty {
                    emptyWorkspaceSection
                } else {
                    ForEach(visibleDayGroups) { group in
                        Section {
                            if !isCollapsed(group) {
                                ForEach(threads(for: group)) { thread in
                                    Button {
                                        onOpenSession(thread)
                                    } label: {
                                        RecentThreadRow(thread: thread, showsProjectPath: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if hiddenCount(for: group) > 0 {
                                    Button {
                                        expandedDayGroupIDs.insert(group.id)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text("另有 \(hiddenCount(for: group)) 个更早会话")
                                            Image(systemName: "chevron.down")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            WorkspaceGroupHeader(
                                iconName: "calendar",
                                title: group.title,
                                metadata: ["\(group.threads.count) 个会话"],
                                activityIndicator: dayActivityIndicator(for: group),
                                isCollapsed: isCollapsed(group),
                                accessibilityName: "\(group.title) 分组",
                                onToggleCollapse: {
                                    toggleDayGroupCollapse(group.id)
                                }
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                    }
                    if hasMoreDayGroups {
                        WorkspaceGroupPaginationRow(
                            title: "上拉加载更多日期",
                            remainingCount: remainingDayGroupCount,
                            onLoadMore: loadMoreDayGroups
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("工作区")
        .onChange(of: displayedProjectGroups.map(\.id)) {
            visibleProjectGroupLimit = Self.initialVisibleGroupLimit
        }
        .onChange(of: displayedDayGroups.map(\.id)) {
            visibleDayGroupLimit = Self.initialVisibleGroupLimit
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        setGrouping(.byProject)
                    } label: {
                        Label("按项目分组", systemImage: grouping == .byProject ? "checkmark" : "folder")
                    }
                    Button {
                        setGrouping(.byTime)
                    } label: {
                        Label("按时间分组", systemImage: grouping == .byTime ? "checkmark" : "clock")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                }
                .accessibilityLabel("排序方式")
            }
        }
    }

    private var displayedProjectGroups: [WorkspaceProjectThreadGroup] {
        if !projectThreadGroups.isEmpty {
            return projectThreadGroups
        }
        return projects.map { project in
            let threads = recentThreads.filter { $0.cwd == project.cwd }
            return WorkspaceProjectThreadGroup(
                project: project,
                threads: Array(threads.prefix(5)),
                hiddenThreadCount: max(threads.count - 5, 0)
            )
        }
    }

    private var displayedDayGroups: [WorkspaceDayThreadGroup] {
        if !dayThreadGroups.isEmpty {
            return dayThreadGroups
        }
        return [
            WorkspaceDayThreadGroup(id: "recent", title: "最近会话", threads: recentThreads)
        ]
    }

    private var visibleProjectGroups: [WorkspaceProjectThreadGroup] {
        Array(displayedProjectGroups.prefix(visibleProjectGroupLimit))
    }

    private var visibleDayGroups: [WorkspaceDayThreadGroup] {
        Array(displayedDayGroups.prefix(visibleDayGroupLimit))
    }

    private var hasMoreProjectGroups: Bool {
        displayedProjectGroups.count > visibleProjectGroupLimit
    }

    private var hasMoreDayGroups: Bool {
        displayedDayGroups.count > visibleDayGroupLimit
    }

    private var remainingProjectGroupCount: Int {
        max(displayedProjectGroups.count - visibleProjectGroupLimit, 0)
    }

    private var remainingDayGroupCount: Int {
        max(displayedDayGroups.count - visibleDayGroupLimit, 0)
    }

    private func threads(for group: WorkspaceProjectThreadGroup) -> [ThreadSummary] {
        if expandedProjectIDs.contains(group.id) {
            return recentThreads.filter { $0.cwd == group.project.cwd }
        }
        return group.threads
    }

    private func hiddenCount(for group: WorkspaceProjectThreadGroup) -> Int {
        if expandedProjectIDs.contains(group.id) {
            return 0
        }
        return group.hiddenThreadCount
    }

    private func threads(for group: WorkspaceDayThreadGroup) -> [ThreadSummary] {
        if expandedDayGroupIDs.contains(group.id) {
            return group.threads
        }
        return Array(group.threads.prefix(5))
    }

    private func hiddenCount(for group: WorkspaceDayThreadGroup) -> Int {
        if expandedDayGroupIDs.contains(group.id) {
            return 0
        }
        return max(group.threads.count - 5, 0)
    }

    private func isCollapsed(_ group: WorkspaceProjectThreadGroup) -> Bool {
        collapsedProjectIDs.contains(group.id)
    }

    private func toggleProjectCollapse(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedProjectIDs.contains(id) {
                collapsedProjectIDs.remove(id)
            } else {
                collapsedProjectIDs.insert(id)
            }
        }
    }

    private func isCollapsed(_ group: WorkspaceDayThreadGroup) -> Bool {
        collapsedDayGroupIDs.contains(group.id)
    }

    private func toggleDayGroupCollapse(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedDayGroupIDs.contains(id) {
                collapsedDayGroupIDs.remove(id)
            } else {
                collapsedDayGroupIDs.insert(id)
            }
        }
    }

    private func dayActivityIndicator(for group: WorkspaceDayThreadGroup) -> WorkspaceActivityIndicator {
        let indicators = group.threads.map(\.activityIndicator)
        if indicators.contains(.running) {
            return .running
        }
        if indicators.contains(.unread) {
            return .unread
        }
        return .none
    }

    private func setGrouping(_ nextGrouping: WorkspaceGrouping) {
        guard grouping != nextGrouping else { return }
        grouping = nextGrouping
        visibleProjectGroupLimit = Self.initialVisibleGroupLimit
        visibleDayGroupLimit = Self.initialVisibleGroupLimit
    }

    private func loadMoreProjectGroups() {
        guard hasMoreProjectGroups else { return }
        visibleProjectGroupLimit += Self.groupPageSize
    }

    private func loadMoreDayGroups() {
        guard hasMoreDayGroups else { return }
        visibleDayGroupLimit += Self.groupPageSize
    }

    private var emptyWorkspaceSection: some View {
        Section {
            ContentUnavailableView(
                "暂无 Codex 会话",
                systemImage: "folder.badge.plus",
                description: Text("选择远端目录来创建新的工作区。")
            )
            Button(action: onBrowseWorkspace) {
                Label("浏览工作区", systemImage: "folder")
            }
        }
    }
}

private struct WorkspaceProjectHeader: View {
    let project: WorkspaceProject
    let isCollapsed: Bool
    let isStartingSession: Bool
    let onToggleCollapse: () -> Void
    let onStartSession: () -> Void

    var body: some View {
        WorkspaceGroupHeader(
            iconName: "folder",
            title: projectName,
            metadata: [
                "\(project.sessionCount) 个会话",
                project.latestActivity.formatted(.relative(presentation: .numeric))
            ],
            detail: gitDetail,
            activityIndicator: project.activityIndicator,
            isCollapsed: isCollapsed,
            accessibilityName: "\(projectName) 分组",
            onToggleCollapse: onToggleCollapse,
            trailingActionSystemImage: "square.and.pencil",
            trailingActionAccessibilityLabel: "在 \(projectName) 新建会话",
            isTrailingActionInProgress: isStartingSession,
            onTrailingAction: onStartSession
        )
    }

    private var projectName: String {
        URL(fileURLWithPath: project.cwd).lastPathComponent
    }

    private var gitDetail: String? {
        guard let gitInfo = project.gitInfo, !gitInfo.repository.isEmpty else {
            return nil
        }
        return "\(gitInfo.repository) · \(gitInfo.branch)"
    }
}

private struct WorkspaceGroupHeader: View {
    let iconName: String
    let title: String
    let metadata: [String]
    var detail: String?
    let activityIndicator: WorkspaceActivityIndicator
    let isCollapsed: Bool
    let accessibilityName: String
    let onToggleCollapse: () -> Void
    var trailingActionSystemImage: String?
    var trailingActionAccessibilityLabel: String?
    var isTrailingActionInProgress = false
    var onTrailingAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleCollapse) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(isCollapsed ? "已折叠" : "已展开")
            .accessibilityHint(isCollapsed ? "展开会话" : "折叠会话")

            if let trailingActionSystemImage, let onTrailingAction {
                Button(action: onTrailingAction) {
                    Group {
                        if isTrailingActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: trailingActionSystemImage)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isTrailingActionInProgress)
                .accessibilityLabel(trailingActionAccessibilityLabel ?? "新建会话")
                .accessibilityValue(isTrailingActionInProgress ? "正在创建" : "")
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Spacer()
                WorkspaceActivityIndicatorView(indicator: activityIndicator)
            }
            if !metadata.isEmpty {
                HStack(spacing: 8) {
                    ForEach(metadata, id: \.self) { value in
                        Text(value)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .textCase(nil)
    }
}

private struct RecentThreadRow: View {
    let thread: ThreadSummary
    let showsProjectPath: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(thread.preview.isEmpty ? thread.id : thread.preview)
                    .font(.body.weight(thread.isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if showsProjectPath, let cwd = thread.cwd {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(thread.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            WorkspaceActivityIndicatorView(indicator: thread.activityIndicator)
        }
        .padding(.vertical, 10)
    }
}

private struct WorkspaceGroupPaginationRow: View {
    let title: String
    let remainingCount: Int
    let onLoadMore: () -> Void

    var body: some View {
        Button(action: onLoadMore) {
            HStack(spacing: 6) {
                Text("\(title)，剩余 \(remainingCount) 个")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .onAppear(perform: onLoadMore)
    }
}

private struct WorkspaceActivityIndicatorView: View {
    let indicator: WorkspaceActivityIndicator

    var body: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .running:
            ProgressView()
                .controlSize(.small)
        case .unread:
            Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
                .accessibilityLabel("未读")
        }
    }
}

#Preview {
    WorkspaceListPreview()
}

private struct WorkspaceListPreview: View {
    @State private var grouping = WorkspaceGrouping.byProject

    var body: some View {
        NavigationStack {
            WorkspaceListView(
                grouping: $grouping,
                projects: [
                    WorkspaceProject(
                        cwd: "/Users/chenm/Projects/codex-port",
                        sessionCount: 3,
                        latestActivity: Date(),
                        latestPreview: "实现 workspace 切换",
                        gitInfo: GitInfo(repository: "codex-port", branch: "main"),
                        activityIndicator: .running
                    )
                ],
                projectThreadGroups: [],
                dayThreadGroups: [],
                recentThreads: [
                    ThreadSummary(
                        id: "thread-1",
                        cwd: "/Users/chenm/Projects/codex-port",
                        updatedAt: Date(),
                        preview: "实现 workspace 切换",
                        gitInfo: nil,
                        status: .running
                    ),
                    ThreadSummary(
                        id: "thread-2",
                        cwd: "/Users/chenm/Projects/codex-port",
                        updatedAt: Date().addingTimeInterval(-400),
                        preview: "继续修复同步问题",
                        gitInfo: nil,
                        isUnread: true
                    )
                ],
                onOpenSession: { _ in },
                onStartProjectSession: { _ in },
                onBrowseWorkspace: {}
            )
        }
    }
}
