import CodexPortCore
import SwiftUI

struct WorkspaceListView: View {
    @Binding var grouping: WorkspaceGrouping
    let projects: [WorkspaceProject]
    let projectThreadGroups: [WorkspaceProjectThreadGroup]
    let dayThreadGroups: [WorkspaceDayThreadGroup]
    let recentThreads: [ThreadSummary]
    let onOpenSession: (ThreadSummary) -> Void
    let onBrowseWorkspace: () -> Void
    let onGroupingChanged: () async -> Void
    @State private var expandedProjectIDs: Set<String> = []

    init(
        grouping: Binding<WorkspaceGrouping>,
        projects: [WorkspaceProject],
        projectThreadGroups: [WorkspaceProjectThreadGroup] = [],
        dayThreadGroups: [WorkspaceDayThreadGroup] = [],
        recentThreads: [ThreadSummary],
        onOpenSession: @escaping (ThreadSummary) -> Void,
        onBrowseWorkspace: @escaping () -> Void,
        onGroupingChanged: @escaping () async -> Void = {}
    ) {
        self._grouping = grouping
        self.projects = projects
        self.projectThreadGroups = projectThreadGroups
        self.dayThreadGroups = dayThreadGroups
        self.recentThreads = recentThreads
        self.onOpenSession = onOpenSession
        self.onBrowseWorkspace = onBrowseWorkspace
        self.onGroupingChanged = onGroupingChanged
    }

    var body: some View {
        List {
            if grouping == .byProject {
                if displayedProjectGroups.isEmpty {
                    emptyWorkspaceSection
                } else {
                    ForEach(displayedProjectGroups) { group in
                        Section {
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
                        } header: {
                            WorkspaceProjectHeader(project: group.project)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                    }
                }
            } else {
                if recentThreads.isEmpty {
                    emptyWorkspaceSection
                } else {
                    ForEach(displayedDayGroups) { group in
                        Section(group.title) {
                            ForEach(group.threads) { thread in
                                Button {
                                    onOpenSession(thread)
                                } label: {
                                    RecentThreadRow(thread: thread, showsProjectPath: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("工作区")
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

    private func setGrouping(_ nextGrouping: WorkspaceGrouping) {
        guard grouping != nextGrouping else { return }
        grouping = nextGrouping
        Task { await onGroupingChanged() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(projectName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                WorkspaceActivityIndicatorView(indicator: project.activityIndicator)
            }
            HStack(spacing: 8) {
                Text("\(project.sessionCount) 个会话")
                Text(project.latestActivity, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let gitInfo = project.gitInfo, !gitInfo.repository.isEmpty {
                Text("\(gitInfo.repository) · \(gitInfo.branch)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var projectName: String {
        URL(fileURLWithPath: project.cwd).lastPathComponent
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
                onBrowseWorkspace: {}
            )
        }
    }
}
