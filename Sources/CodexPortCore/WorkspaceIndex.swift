import Foundation

public struct GitInfo: Equatable, Sendable {
    public var repository: String
    public var branch: String

    public init(repository: String, branch: String) {
        self.repository = repository
        self.branch = branch
    }
}

public struct ThreadSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var cwd: String?
    public var updatedAt: Date
    public var preview: String
    public var gitInfo: GitInfo?
    public var status: ThreadRunStatus
    public var isUnread: Bool
    public var activityIndicator: WorkspaceActivityIndicator
    public var remoteUnread: Bool?

    public init(
        id: String,
        cwd: String?,
        updatedAt: Date,
        preview: String,
        gitInfo: GitInfo?,
        status: ThreadRunStatus = .completed,
        isUnread: Bool = false,
        remoteUnread: Bool? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.preview = preview
        self.gitInfo = gitInfo
        self.status = status
        self.isUnread = isUnread
        self.remoteUnread = remoteUnread
        self.activityIndicator = Self.activityIndicator(status: status, isUnread: isUnread)
    }

    public init?(json: JSONValue) {
        guard let object = json.object,
              let id = object["id"]?.string
        else { return nil }

        self.id = id
        self.cwd = object["cwd"]?.string
        self.updatedAt = ThreadSummary.parseDate(object["updatedAt"] ?? object["updated_at"])
        self.preview = object["preview"]?.string
            ?? object["title"]?.string
            ?? object["lastMessage"]?.string
            ?? ""
        if let git = object["gitInfo"]?.object ?? object["git"]?.object {
            self.gitInfo = GitInfo(
                repository: git["repository"]?.string ?? git["repo"]?.string ?? "",
                branch: git["branch"]?.string ?? ""
            )
        } else {
            self.gitInfo = nil
        }
        self.status = ThreadRunStatus(raw: object["status"]?.string ?? object["state"]?.string)
        self.remoteUnread = ThreadSummary.parseRemoteUnread(from: object)
        self.isUnread = false
        self.activityIndicator = .none
    }

    private static func parseDate(_ value: JSONValue?) -> Date {
        guard let value else { return .distantPast }
        if let timestamp = value.number {
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let raw = value.string else { return .distantPast }
        return ISO8601DateFormatter().date(from: raw) ?? .distantPast
    }

    private static func activityIndicator(status: ThreadRunStatus, isUnread: Bool) -> WorkspaceActivityIndicator {
        if status == .running {
            return .running
        }
        return isUnread ? .unread : .none
    }

    private static func parseRemoteUnread(from object: [String: JSONValue]) -> Bool? {
        for key in ["isUnread", "unread", "hasUnread"] {
            if let value = object[key]?.boolValue {
                return value
            }
        }
        for key in ["isRead", "read"] {
            if let value = object[key]?.boolValue {
                return !value
            }
        }
        return nil
    }

    func applyingReadState(_ readAt: Date?) -> ThreadSummary {
        let unread = status != .running && (remoteUnread ?? (updatedAt > (readAt ?? .distantPast)))
        return ThreadSummary(
            id: id,
            cwd: cwd,
            updatedAt: updatedAt,
            preview: preview,
            gitInfo: gitInfo,
            status: status,
            isUnread: unread,
            remoteUnread: remoteUnread
        )
    }
}

public enum ThreadRunStatus: Equatable, Sendable {
    case running
    case completed

    init(raw: String?) {
        switch raw?.lowercased() {
        case "running", "inprogress", "in_progress":
            self = .running
        default:
            self = .completed
        }
    }
}

public enum WorkspaceActivityIndicator: Equatable, Sendable {
    case none
    case running
    case unread
}

public struct WorkspaceProject: Equatable, Identifiable, Sendable {
    public var id: String { cwd }
    public var cwd: String
    public var sessionCount: Int
    public var latestActivity: Date
    public var latestPreview: String
    public var gitInfo: GitInfo?
    public var activityIndicator: WorkspaceActivityIndicator

    public init(
        cwd: String,
        sessionCount: Int,
        latestActivity: Date,
        latestPreview: String,
        gitInfo: GitInfo?,
        activityIndicator: WorkspaceActivityIndicator = .none
    ) {
        self.cwd = cwd
        self.sessionCount = sessionCount
        self.latestActivity = latestActivity
        self.latestPreview = latestPreview
        self.gitInfo = gitInfo
        self.activityIndicator = activityIndicator
    }
}

public struct WorkspaceProjectThreadGroup: Equatable, Identifiable, Sendable {
    public var id: String { project.id }
    public var project: WorkspaceProject
    public var threads: [ThreadSummary]
    public var hiddenThreadCount: Int

    public init(project: WorkspaceProject, threads: [ThreadSummary], hiddenThreadCount: Int) {
        self.project = project
        self.threads = threads
        self.hiddenThreadCount = hiddenThreadCount
    }
}

public struct WorkspaceDayThreadGroup: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var threads: [ThreadSummary]

    public init(id: String, title: String, threads: [ThreadSummary]) {
        self.id = id
        self.title = title
        self.threads = threads
    }
}

public struct WorkspaceIndex: Sendable {
    private let threads: [ThreadSummary]

    public init(threads: [ThreadSummary]) {
        self.threads = threads
    }

    public func projects() -> [WorkspaceProject] {
        let grouped = Dictionary(grouping: threads.compactMap { thread -> ThreadSummary? in
            thread.cwd == nil ? nil : thread
        }, by: { $0.cwd! })

        return grouped.map { cwd, threads in
            let sorted = threads.sorted(by: sortNewestFirst)
            let latest = sorted[0]
            return WorkspaceProject(
                cwd: cwd,
                sessionCount: threads.count,
                latestActivity: latest.updatedAt,
                latestPreview: latest.preview,
                gitInfo: latest.gitInfo,
                activityIndicator: Self.projectActivityIndicator(for: threads)
            )
        }
        .sorted { left, right in
            if left.latestActivity == right.latestActivity {
                return left.cwd < right.cwd
            }
            return left.latestActivity > right.latestActivity
        }
    }

    public func recentThreads() -> [ThreadSummary] {
        threads.filter { $0.cwd != nil }.sorted(by: sortNewestFirst)
    }

    public func projectThreadGroups(limit: Int = 5) -> [WorkspaceProjectThreadGroup] {
        let recent = recentThreads()
        return projects().map { project in
            let threads = recent.filter { $0.cwd == project.cwd }
            return WorkspaceProjectThreadGroup(
                project: project,
                threads: Array(threads.prefix(limit)),
                hiddenThreadCount: max(threads.count - limit, 0)
            )
        }
    }

    private func sortNewestFirst(_ left: ThreadSummary, _ right: ThreadSummary) -> Bool {
        if left.updatedAt == right.updatedAt {
            return left.id < right.id
        }
        return left.updatedAt > right.updatedAt
    }

    private static func projectActivityIndicator(for threads: [ThreadSummary]) -> WorkspaceActivityIndicator {
        if threads.contains(where: { $0.activityIndicator == .running }) {
            return .running
        }
        if threads.contains(where: { $0.activityIndicator == .unread }) {
            return .unread
        }
        return .none
    }
}

public enum WorkspaceGrouping: Equatable, Sendable {
    case byProject
    case byTime
}

public final class WorkspaceListStore {
    private let protocolClient: CodexProtocolFacade
    private let readStateStore: WorkspaceReadStateStore
    public var grouping: WorkspaceGrouping
    public private(set) var projects: [WorkspaceProject] = []
    public private(set) var projectThreadGroups: [WorkspaceProjectThreadGroup] = []
    public private(set) var dayThreadGroups: [WorkspaceDayThreadGroup] = []
    public private(set) var recentThreads: [ThreadSummary] = []
    public private(set) var errorMessage: String?
    private var readAt: [String: Date]
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        protocolClient: CodexProtocolFacade,
        grouping: WorkspaceGrouping = .byProject,
        readStateStore: WorkspaceReadStateStore = UserDefaultsWorkspaceReadStateStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.protocolClient = protocolClient
        self.grouping = grouping
        self.readStateStore = readStateStore
        self.readAt = (try? readStateStore.loadReadAt()) ?? [:]
        self.now = now
        self.calendar = calendar
    }

    public func reload(limit: Int) async throws {
        let response: JSONValue
        do {
            response = try await protocolClient.listThreads(limit: limit)
        } catch {
            errorMessage = String(describing: error)
            throw error
        }
        readAt = (try? readStateStore.loadReadAt()) ?? readAt
        let remoteThreads = (response.object?["data"]?.array ?? response.object?["threads"]?.array ?? response.object?["items"]?.array ?? [])
            .compactMap(ThreadSummary.init(json:))
        if readAt.isEmpty, !remoteThreads.isEmpty {
            readAt = Dictionary(uniqueKeysWithValues: remoteThreads
                .filter { $0.status != .running }
                .map { ($0.id, $0.updatedAt) })
            try? readStateStore.saveReadAt(readAt)
        }
        let threads = remoteThreads
            .map { $0.applyingReadState(readAt[$0.id]) }
        let index = WorkspaceIndex(threads: threads)
        self.projects = index.projects()
        self.projectThreadGroups = index.projectThreadGroups(limit: 5)
        self.recentThreads = index.recentThreads()
        self.dayThreadGroups = Self.dayThreadGroups(
            for: self.recentThreads,
            now: now(),
            calendar: calendar
        )
        self.errorMessage = nil
    }

    public func markThreadRead(id: String) throws {
        let readTime = recentThreads.first(where: { $0.id == id })?.updatedAt ?? Date()
        readAt[id] = readTime
        try readStateStore.saveReadAt(readAt)
        recentThreads = recentThreads.map { thread in
            thread.id == id ? thread.applyingReadState(readTime) : thread
        }
        let index = WorkspaceIndex(threads: recentThreads)
        projects = index.projects()
        projectThreadGroups = index.projectThreadGroups(limit: 5)
        dayThreadGroups = Self.dayThreadGroups(for: recentThreads, now: now(), calendar: calendar)
    }

    private static func dayThreadGroups(
        for threads: [ThreadSummary],
        now: Date,
        calendar: Calendar
    ) -> [WorkspaceDayThreadGroup] {
        let grouped = Dictionary(grouping: threads) { thread in
            calendar.startOfDay(for: thread.updatedAt)
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"

        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: today) {
                title = "今天"
            } else if let yesterday, calendar.isDate(day, inSameDayAs: yesterday) {
                title = "昨天"
            } else {
                title = formatter.string(from: day)
            }
            return WorkspaceDayThreadGroup(
                id: String(Int(day.timeIntervalSince1970)),
                title: title,
                threads: (grouped[day] ?? []).sorted { left, right in
                    if left.updatedAt == right.updatedAt {
                        return left.id < right.id
                    }
                    return left.updatedAt > right.updatedAt
                }
            )
        }
    }
}

extension WorkspaceListStore: @unchecked Sendable {}

public protocol WorkspaceReadStateStore: AnyObject, Sendable {
    func loadReadAt() throws -> [String: Date]
    func saveReadAt(_ readAt: [String: Date]) throws
}

public final class UserDefaultsWorkspaceReadStateStore: WorkspaceReadStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "workspace.threadReadAt") {
        self.defaults = defaults
        self.key = key
    }

    public init(defaults: UserDefaults = .standard, key: String = "workspace.threadReadAt", namespace: String) {
        self.defaults = defaults
        self.key = namespace.isEmpty ? key : "\(key).\(namespace)"
    }

    public func loadReadAt() throws -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: TimeInterval] else {
            return [:]
        }
        return raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    public func saveReadAt(_ readAt: [String: Date]) throws {
        defaults.set(readAt.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}
