import Foundation
import Testing
@testable import CodexPortCore

@Test func workspaceListStoreLoadsThreadsFromProtocolAndTogglesProjectOrRecentGrouping() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-api"),
                "cwd": .string("/repo/api"),
                "updatedAt": .string("2026-05-28T02:00:00Z"),
                "preview": .string("Fix auth"),
                "gitInfo": .object(["repository": .string("api"), "branch": .string("main")])
            ]),
            .object([
                "id": .string("thread-web"),
                "cwd": .string("/repo/web"),
                "updatedAt": .string("2026-05-28T03:00:00Z"),
                "preview": .string("Input bar"),
                "gitInfo": .object(["repository": .string("web"), "branch": .string("ios")])
            ]),
            .object([
                "id": .string("thread-api-newer"),
                "cwd": .string("/repo/api"),
                "updatedAt": .string("2026-05-28T04:00:00Z"),
                "preview": .string("Deploy"),
                "gitInfo": .object(["repository": .string("api"), "branch": .string("release")])
            ])
        ])
    ])
    let store = WorkspaceListStore(protocolClient: CodexProtocolFacade(transport: transport))

    try await store.reload(limit: 50)

    #expect(store.grouping == .byProject)
    #expect(store.projects.map(\.cwd) == ["/repo/api", "/repo/web"])
    #expect(store.projects[0].latestPreview == "Deploy")

    store.grouping = .byTime
    #expect(store.recentThreads.map(\.id) == ["thread-api-newer", "thread-web", "thread-api"])
}

@Test func workspaceListStoreLoadsOfficialThreadListDataField() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "data": .array([
            .object([
                "id": .string("thread-official"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(1_779_978_000),
                "preview": .string("Continue bug fix")
            ])
        ])
    ])
    let store = WorkspaceListStore(protocolClient: CodexProtocolFacade(transport: transport))

    try await store.reload(limit: 50)

    #expect(store.projects.map(\.cwd) == ["/repo/app"])
    #expect(store.recentThreads.map(\.id) == ["thread-official"])
}

@Test func workspaceListStorePublishesLoadingFailuresWithoutClearingLastGoodList() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-web"),
                "cwd": .string("/repo/web"),
                "updatedAt": .string("2026-05-28T03:00:00Z"),
                "preview": .string("Input bar")
            ])
        ])
    ])
    let store = WorkspaceListStore(protocolClient: CodexProtocolFacade(transport: transport))
    try await store.reload(limit: 50)
    transport.error = JSONRPCError.connectionClosed

    await #expect(throws: JSONRPCError.connectionClosed) {
        try await store.reload(limit: 50)
    }

    #expect(store.projects.map(\.cwd) == ["/repo/web"])
    #expect(store.errorMessage == "connectionClosed")
}

@Test func workspaceListStoreTracksUnreadAndRunningDisplayStateAcrossReloads() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-running"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T03:00:00Z"),
                "preview": .string("Implement live sync"),
                "status": .string("inProgress")
            ]),
            .object([
                "id": .string("thread-unread"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T02:00:00Z"),
                "preview": .string("Polish list"),
                "status": .string("completed")
            ])
        ])
    ])
    let readState = InMemoryWorkspaceReadStateStore(readAt: [
        "thread-running": Date(timeIntervalSince1970: 0),
        "thread-unread": ISO8601DateFormatter().date(from: "2026-05-28T01:00:00Z")!
    ])
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: readState
    )

    try await store.reload(limit: 50)

    #expect(store.recentThreads.map(\.id) == ["thread-running", "thread-unread"])
    #expect(store.recentThreads[0].activityIndicator == .running)
    #expect(store.recentThreads[0].isUnread == false)
    #expect(store.recentThreads[1].activityIndicator == .unread)
    #expect(store.recentThreads[1].isUnread == true)
    #expect(store.projects[0].activityIndicator == .running)

    try store.markThreadRead(id: "thread-unread")
    let reloadedReadState = InMemoryWorkspaceReadStateStore(readAt: readState.readAt)
    let reloadedStore = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: reloadedReadState
    )

    try await reloadedStore.reload(limit: 50)

    #expect(reloadedStore.recentThreads[1].activityIndicator == .none)
    #expect(reloadedStore.recentThreads[1].isUnread == false)
}

@Test func workspaceListStoreLimitsProjectGroupsToFiveRecentThreads() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array((0..<7).map { index in
            .object([
                "id": .string("thread-\(index)"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(Double(1_800_000_000 - index)),
                "preview": .string("Message \(index)")
            ])
        })
    ])
    let store = WorkspaceListStore(protocolClient: CodexProtocolFacade(transport: transport))

    try await store.reload(limit: 50)

    let group = try #require(store.projectThreadGroups.first)
    #expect(group.project.cwd == "/repo/app")
    #expect(group.threads.map(\.id) == ["thread-0", "thread-1", "thread-2", "thread-3", "thread-4"])
    #expect(group.hiddenThreadCount == 2)
}

@Test func workspaceListStoreLimitsDayGroupsToFiveRecentThreads() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array((0..<7).map { index in
            .object([
                "id": .string("thread-\(index)"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(Double(1_800_000_000 - index)),
                "preview": .string("Message \(index)")
            ])
        })
    ])
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        now: { Date(timeIntervalSince1970: 1_800_000_100) },
        calendar: Calendar(identifier: .gregorian)
    )

    try await store.reload(limit: 50)

    let group = try #require(store.dayThreadGroups.first)
    #expect(group.threads.map(\.id) == ["thread-0", "thread-1", "thread-2", "thread-3", "thread-4"])
    #expect(group.hiddenThreadCount == 2)
    #expect(group.allThreads.map(\.id) == ["thread-0", "thread-1", "thread-2", "thread-3", "thread-4", "thread-5", "thread-6"])
}

@Test func workspaceListStoreCanOptimisticallyPublishNewLocalThreadBeforeRemoteListCatchesUp() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("existing-thread"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(1_800_000_000),
                "preview": .string("Existing")
            ])
        ])
    ])
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: InMemoryWorkspaceReadStateStore(),
        now: { Date(timeIntervalSince1970: 1_800_000_100) }
    )

    try await store.reload(limit: 50)
    store.upsertLocalThread(id: "new-thread", cwd: "/repo/app", preview: "新会话")

    #expect(store.recentThreads.map(\.id) == ["new-thread", "existing-thread"])
    #expect(store.projects.first?.cwd == "/repo/app")
    #expect(store.projects.first?.sessionCount == 2)
    #expect(store.projectThreadGroups.first?.threads.first?.id == "new-thread")
    #expect(store.dayThreadGroups.first?.threads.first?.id == "new-thread")

    try await store.reload(limit: 50)

    #expect(store.recentThreads.map(\.id) == ["new-thread", "existing-thread"])

    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("new-thread"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(1_800_000_200),
                "preview": .string("Remote caught up")
            ]),
            .object([
                "id": .string("existing-thread"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(1_800_000_000),
                "preview": .string("Existing")
            ])
        ])
    ])

    try await store.reload(limit: 50)

    #expect(store.recentThreads.map(\.id) == ["new-thread", "existing-thread"])
    #expect(store.recentThreads.first?.preview == "Remote caught up")
}

@Test func workspaceListStoreArchivesThreadLocallyAcrossReloads() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-archived"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(1_800_000_100),
                "preview": .string("Archive me")
            ]),
            .object([
                "id": .string("thread-kept"),
                "cwd": .string("/repo/app"),
                "updatedAt": .number(1_800_000_000),
                "preview": .string("Keep me")
            ])
        ])
    ])
    let archiveState = InMemoryWorkspaceArchiveStateStore()
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        archiveStateStore: archiveState
    )
    try await store.reload(limit: 50)

    store.archiveThread(id: "thread-archived")

    #expect(store.recentThreads.map(\.id) == ["thread-kept"])
    #expect(store.projects.first?.sessionCount == 1)
    #expect(store.projectThreadGroups.first?.threads.map(\.id) == ["thread-kept"])
    #expect(store.dayThreadGroups.first?.threads.map(\.id) == ["thread-kept"])

    try await store.reload(limit: 50)

    #expect(store.recentThreads.map(\.id) == ["thread-kept"])
    #expect(store.projects.first?.sessionCount == 1)

    let reloadedStore = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        archiveStateStore: InMemoryWorkspaceArchiveStateStore(ids: archiveState.ids)
    )

    try await reloadedStore.reload(limit: 50)

    #expect(reloadedStore.recentThreads.map(\.id) == ["thread-kept"])
    #expect(reloadedStore.projects.first?.sessionCount == 1)
}

@Test func workspaceListStoreTreatsFirstRemoteLoadAsReadBaselineThenMarksLaterUpdatesUnread() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-existing"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T02:00:00Z"),
                "preview": .string("Existing history")
            ])
        ])
    ])
    let readState = InMemoryWorkspaceReadStateStore()
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: readState
    )

    try await store.reload(limit: 50)

    #expect(store.recentThreads.first?.isUnread == false)
    #expect(readState.readAt["thread-existing"] == ISO8601DateFormatter().date(from: "2026-05-28T02:00:00Z"))

    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-existing"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T03:00:00Z"),
                "preview": .string("New remote activity")
            ])
        ])
    ])

    try await store.reload(limit: 50)

    #expect(store.recentThreads.first?.isUnread == true)
    #expect(store.recentThreads.first?.activityIndicator == .unread)
}

@Test func workspaceListStoreKeepsFirstLoadBaselineScopedPerHostProfile() async throws {
    let suiteName = "WorkspaceReadStateStoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let hostATransport = RecordingCodexTransport()
    hostATransport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-shared"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T10:00:00Z"),
                "preview": .string("Host A history")
            ])
        ])
    ])
    let hostAStore = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: hostATransport),
        readStateStore: UserDefaultsWorkspaceReadStateStore(defaults: defaults, namespace: "host-a")
    )

    try await hostAStore.reload(limit: 50)

    #expect(hostAStore.recentThreads.first?.isUnread == false)

    let hostBTransport = RecordingCodexTransport()
    hostBTransport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("thread-shared"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T11:00:00Z"),
                "preview": .string("Host B history")
            ])
        ])
    ])
    let hostBStore = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: hostBTransport),
        readStateStore: UserDefaultsWorkspaceReadStateStore(defaults: defaults, namespace: "host-b")
    )

    try await hostBStore.reload(limit: 50)

    #expect(hostBStore.recentThreads.first?.isUnread == false)
    #expect(hostBStore.recentThreads.first?.activityIndicator == WorkspaceActivityIndicator.none)
}

@Test func workspaceListStorePrefersRemoteThreadActivityMarkersOverLocalReadState() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("remote-unread"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T02:00:00Z"),
                "preview": .string("Remote unread wins"),
                "status": .string("completed"),
                "isUnread": .bool(true)
            ]),
            .object([
                "id": .string("remote-read"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T03:00:00Z"),
                "preview": .string("Remote read wins"),
                "status": .string("completed"),
                "isUnread": .bool(false)
            ]),
            .object([
                "id": .string("remote-running"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T04:00:00Z"),
                "preview": .string("Running wins over unread"),
                "status": .string("running"),
                "isUnread": .bool(true)
            ])
        ])
    ])
    let readState = InMemoryWorkspaceReadStateStore(readAt: [
        "remote-unread": ISO8601DateFormatter().date(from: "2026-05-28T03:00:00Z")!,
        "remote-read": ISO8601DateFormatter().date(from: "2026-05-28T01:00:00Z")!,
        "remote-running": ISO8601DateFormatter().date(from: "2026-05-28T01:00:00Z")!
    ])
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: readState
    )

    try await store.reload(limit: 50)

    let threadsByID = Dictionary(uniqueKeysWithValues: store.recentThreads.map { ($0.id, $0) })
    #expect(threadsByID["remote-unread"]?.isUnread == true)
    #expect(threadsByID["remote-unread"]?.activityIndicator == .unread)
    #expect(threadsByID["remote-read"]?.isUnread == false)
    #expect(threadsByID["remote-read"]?.activityIndicator == WorkspaceActivityIndicator.none)
    #expect(threadsByID["remote-running"]?.isUnread == false)
    #expect(threadsByID["remote-running"]?.activityIndicator == .running)
    #expect(store.projects.first?.activityIndicator == .running)
}

@Test func workspaceListStoreBaselinesCompletedHistoryWithoutMarkingRunningThreadsRead() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("completed-history"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T02:00:00Z"),
                "preview": .string("Existing completed history"),
                "status": .string("completed")
            ]),
            .object([
                "id": .string("running-task"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T03:00:00Z"),
                "preview": .string("Still running"),
                "status": .string("inProgress")
            ])
        ])
    ])
    let readState = InMemoryWorkspaceReadStateStore()
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: readState
    )

    try await store.reload(limit: 50)

    let threadsByID = Dictionary(uniqueKeysWithValues: store.recentThreads.map { ($0.id, $0) })
    #expect(threadsByID["completed-history"]?.isUnread == false)
    #expect(threadsByID["completed-history"]?.activityIndicator == WorkspaceActivityIndicator.none)
    #expect(threadsByID["running-task"]?.isUnread == false)
    #expect(threadsByID["running-task"]?.activityIndicator == .running)
    #expect(readState.readAt["completed-history"] == ISO8601DateFormatter().date(from: "2026-05-28T02:00:00Z"))
    #expect(readState.readAt["running-task"] == nil)
}

@Test func workspaceListStoreGroupsRecentThreadsByCalendarDay() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/list"] = .object([
        "threads": .array([
            .object([
                "id": .string("today"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-29T02:00:00Z"),
                "preview": .string("Today")
            ]),
            .object([
                "id": .string("yesterday"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-28T02:00:00Z"),
                "preview": .string("Yesterday")
            ]),
            .object([
                "id": .string("older"),
                "cwd": .string("/repo/app"),
                "updatedAt": .string("2026-05-27T02:00:00Z"),
                "preview": .string("Older")
            ])
        ])
    ])
    let store = WorkspaceListStore(
        protocolClient: CodexProtocolFacade(transport: transport),
        readStateStore: InMemoryWorkspaceReadStateStore(),
        now: { ISO8601DateFormatter().date(from: "2026-05-29T12:00:00Z")! },
        calendar: Calendar(identifier: .gregorian)
    )

    try await store.reload(limit: 50)

    #expect(store.dayThreadGroups.map(\.title) == ["今天", "昨天", "5月27日"])
    #expect(store.dayThreadGroups.map { $0.threads.map(\.id) } == [["today"], ["yesterday"], ["older"]])
}

private final class InMemoryWorkspaceReadStateStore: WorkspaceReadStateStore, @unchecked Sendable {
    var readAt: [String: Date]

    init(readAt: [String: Date] = [:]) {
        self.readAt = readAt
    }

    func loadReadAt() throws -> [String: Date] {
        readAt
    }

    func saveReadAt(_ readAt: [String: Date]) throws {
        self.readAt = readAt
    }
}

private final class InMemoryWorkspaceArchiveStateStore: WorkspaceArchiveStateStore, @unchecked Sendable {
    var ids: Set<String>

    init(ids: Set<String> = []) {
        self.ids = ids
    }

    func loadArchivedThreadIDs() throws -> Set<String> {
        ids
    }

    func saveArchivedThreadIDs(_ ids: Set<String>) throws {
        self.ids = ids
    }
}
