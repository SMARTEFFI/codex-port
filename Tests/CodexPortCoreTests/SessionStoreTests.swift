import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func sessionStoreReadsResumesAndStartsTextTurnInOrder() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [
        Turn(id: "turn-old", status: .completed, items: [.assistantMessage("之前的回复")])
    ])

    let store = SessionStore(protocolClient: protocolClient)
    try await store.open(threadID: "thread-1")
    try await store.send(prompt: "继续")

    #expect(store.thread?.turns.first?.items == [.assistantMessage("之前的回复")])
    #expect(protocolClient.calls == [
        "thread/resume(initialTurnLimit:10,timeout:30.0)",
        "turn/start"
    ])
    #expect(store.runningTurnID == "turn-started")
}

@Test func sessionStoreParsesThreadReadResponseIntoVisibleHistory() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/resume"] = .object([
        "thread": .object([
            "id": .string("thread-1"),
            "turns": .array([
                .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "type": .string("assistantMessage"),
                            "text": .string("之前的回复")
                        ]),
                        .object([
                            "type": .string("commandOutput"),
                            "text": .string("git status\n")
                        ]),
                        .object([
                            "type": .string("fileChange"),
                            "path": .string("README.md"),
                            "diff": .string("+hi")
                        ])
                    ])
                ])
            ])
        ])
    ])
    let store = SessionStore(protocolClient: CodexProtocolFacade(transport: transport))

    try await store.open(threadID: "thread-1")

    #expect(store.thread == ThreadDetail(id: "thread-1", turns: [
        Turn(id: "turn-1", status: .completed, items: [
            .assistantMessage("之前的回复"),
            .commandOutput("git status\n"),
            .fileChange(path: "README.md", diff: "+hi")
        ])
    ]))
    #expect(store.visibleItems == [
        .assistantMessage("之前的回复"),
        .commandOutput("git status\n"),
        .fileChange(path: "README.md", diff: "+hi")
    ])
}

@Test func sessionStoreParsesOfficialThreadItemsIncludingUserMessages() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/resume"] = .object([
        "thread": .object([
            "id": .string("thread-1"),
            "turns": .array([
                .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "type": .string("userMessage"),
                            "id": .string("user-1"),
                            "content": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string("请继续修复同步问题"),
                                    "text_elements": .array([])
                                ])
                            ])
                        ]),
                        .object([
                            "type": .string("agentMessage"),
                            "id": .string("agent-1"),
                            "text": .string("我会检查事件流。")
                        ]),
                        .object([
                            "type": .string("commandExecution"),
                            "id": .string("cmd-1"),
                            "command": .string("swift test"),
                            "aggregatedOutput": .string("Test run passed\n")
                        ]),
                        .object([
                            "type": .string("fileChange"),
                            "id": .string("file-1"),
                            "changes": .array([
                                .object([
                                    "path": .string("Sources/CodexPortCore/SessionStore.swift"),
                                    "kind": .string("update"),
                                    "diff": .string("+ parse official items")
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
    ])
    let store = SessionStore(protocolClient: CodexProtocolFacade(transport: transport))

    try await store.open(threadID: "thread-1")

    #expect(store.visibleItems == [
        .userMessage("请继续修复同步问题"),
        .assistantMessage("我会检查事件流。"),
        .commandOutput("$ swift test\nTest run passed\n"),
        .fileChange(path: "Sources/CodexPortCore/SessionStore.swift", diff: "+ parse official items")
    ])
}

@Test func sessionStoreOpensThreadWithServerPagedRecentHistoryAndLoadsEarlierTurnsOnDemand() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.resumeThreadResponse = .object([
        "thread": .object([
            "id": .string("thread-1"),
            "turns": .array([])
        ]),
        "initialTurnsPage": .object([
            "data": .array([
                turnJSON(index: 7),
                turnJSON(index: 6),
                turnJSON(index: 5)
            ]),
            "nextCursor": .string("older-turns")
        ])
    ])
    protocolClient.pagedTurnResponses = [
        .object([
            "data": .array([
                turnJSON(index: 4),
                turnJSON(index: 3)
            ]),
            "nextCursor": .null
        ])
    ]
    let store = SessionStore(protocolClient: protocolClient, initialVisibleItemLimit: 3, initialTurnPageSize: 3, historyTurnPageSize: 2)

    try await store.open(threadID: "thread-1")

    #expect(protocolClient.calls == ["thread/resume(initialTurnLimit:3,timeout:30.0)"])
    #expect(store.loadedTurnCount == 3)
    #expect(store.totalHistoryItemCount == 6)
    #expect(store.loadedHistoryItemCount == 6)
    #expect(store.hasEarlierHistory == true)
    #expect(store.visibleItems == [
        .userMessage("user 5"),
        .assistantMessage("assistant 5"),
        .userMessage("user 6"),
        .assistantMessage("assistant 6"),
        .userMessage("user 7"),
        .assistantMessage("assistant 7")
    ])

    try await store.loadEarlierHistory()

    #expect(protocolClient.calls == [
        "thread/resume(initialTurnLimit:3,timeout:30.0)",
        "thread/turns/list(cursor:older-turns,limit:2,sort:desc,items:full,timeout:30.0)"
    ])
    #expect(store.loadedTurnCount == 5)
    #expect(store.hasEarlierHistory == false)
    #expect(store.visibleItems == [
        .userMessage("user 3"),
        .assistantMessage("assistant 3"),
        .userMessage("user 4"),
        .assistantMessage("assistant 4"),
        .userMessage("user 5"),
        .assistantMessage("assistant 5"),
        .userMessage("user 6"),
        .assistantMessage("assistant 6"),
        .userMessage("user 7"),
        .assistantMessage("assistant 7")
    ])
}

@Test func sessionStoreTimesOutWhenPagedRecentHistoryNeverReturns() async throws {
    let transport = InMemoryJSONRPCTransport()
    let client = JSONRPCClient(transport: transport)
    let protocolClient = CodexProtocolFacade(transport: JSONRPCClientCodexTransport(client: client))
    let store = SessionStore(
        protocolClient: protocolClient,
        initialVisibleItemLimit: 3,
        historyRequestTimeoutSeconds: 0.05
    )

    let openTask = Task {
        try await store.open(threadID: "thread-1")
    }

    let outbound = try await transport.nextOutbound()
    #expect(outbound.method == "thread/resume")
    #expect(outbound.params.object?["threadId"] == .string("thread-1"))
    #expect(outbound.params.object?["excludeTurns"] == .bool(true))

    await #expect(throws: JSONRPCError.requestTimedOut(method: "thread/resume", seconds: 0.05)) {
        try await openTask.value
    }
    #expect(store.visibleItems.isEmpty)
}

@Test func sessionStoreFallsBackToClientWindowWhenServerRejectsPagedResume() async throws {
    let protocolClient = LegacyResumeOnlyCodexProtocol()
    protocolClient.thread = ThreadDetail(
        id: "thread-1",
        turns: (0..<8).map { index in
            Turn(id: "turn-\(index)", status: .completed, items: [
                .userMessage("user \(index)"),
                .assistantMessage("assistant \(index)")
            ])
        }
    )
    let store = SessionStore(
        protocolClient: protocolClient,
        initialVisibleItemLimit: 5,
        initialTurnPageSize: 5,
        historyTurnPageSize: 4,
        legacyHistoryItemPageSize: 4
    )

    try await store.open(threadID: "thread-1")

    #expect(protocolClient.calls == [
        "thread/resume(initialTurnLimit:5,timeout:30.0)",
        "thread/resume"
    ])
    #expect(store.totalHistoryItemCount == 16)
    #expect(store.loadedHistoryItemCount == 5)
    #expect(store.hasEarlierHistory == true)
    #expect(store.visibleItems == [
        .assistantMessage("assistant 5"),
        .userMessage("user 6"),
        .assistantMessage("assistant 6"),
        .userMessage("user 7"),
        .assistantMessage("assistant 7")
    ])

    try await store.loadEarlierHistory()

    #expect(store.loadedHistoryItemCount == 9)
    #expect(store.visibleItems == [
        .assistantMessage("assistant 3"),
        .userMessage("user 4"),
        .assistantMessage("assistant 4"),
        .userMessage("user 5"),
        .assistantMessage("assistant 5"),
        .userMessage("user 6"),
        .assistantMessage("assistant 6"),
        .userMessage("user 7"),
        .assistantMessage("assistant 7")
    ])
}

@Test func sessionStoreWindowsRelayHistoryLoadedItemsAndLoadsEarlierFromLocalCache() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(
        protocolClient: protocolClient,
        initialVisibleItemLimit: 6,
        legacyHistoryItemPageSize: 4
    )
    let relayItems = (0..<12).map { index in
        RelayThreadHistoryItem.assistantMessage("relay item \(index)")
    }

    store.receive(relayEvent: .threadHistoryLoaded(threadID: "thread-1", items: relayItems, status: .completed))

    #expect(store.totalHistoryItemCount == 12)
    #expect(store.loadedHistoryItemCount == 6)
    #expect(store.hasEarlierHistory == true)
    #expect(store.visibleItems == (6..<12).map { .assistantMessage("relay item \($0)") })

    try await store.loadEarlierHistory()

    #expect(store.loadedHistoryItemCount == 10)
    #expect(store.hasEarlierHistory == true)
    #expect(store.visibleItems == (2..<12).map { .assistantMessage("relay item \($0)") })
}

@Test func sessionStorePrependsRelayHistoryPagesWithoutDuplicatingOverlappingItems() async throws {
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    store.receive(relayHistoryPage: RelayThreadHistoryPage(
        requestID: "initial",
        threadID: "thread-1",
        items: [
            .userMessage("recent question"),
            .assistantMessage("recent answer"),
        ],
        status: .completed,
        nextCursor: "older-cursor-1"
    ))
    store.receive(relayEvent: .assistantTextDelta(
        turnID: "live-turn",
        itemID: "live-assistant",
        text: "live delta"
    ))

    store.receive(relayHistoryPage: RelayThreadHistoryPage(
        requestID: "history-request-1",
        threadID: "thread-1",
        items: [
            .userMessage("older question"),
            .assistantMessage("older answer"),
            .userMessage("recent question"),
            .assistantMessage("recent answer"),
        ],
        status: .completed,
        nextCursor: nil
    ))

    #expect(store.visibleItems == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
        .userMessage("recent question"),
        .assistantMessage("recent answer"),
        .assistantMessage("live delta"),
    ])
    #expect(store.hasEarlierHistory == false)
}

@Test func sessionStoreSendsComposerAttachmentsPermissionAndPlanMode() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)
    try await store.open(threadID: "thread-1")

    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.text = "分析截图"
    composer.attachments = [.localImage(path: "/remote/screen.png", detail: "high")]
    composer.permissionMode = .autoReview
    composer.collaborationMode = .plan

    try await store.send(composer: composer)

    #expect(protocolClient.lastTurnStart == TurnStartRecord(
        threadID: "thread-1",
        prompt: "分析截图",
        attachments: [.localImage(path: "/remote/screen.png", detail: "high")],
        model: .gpt55,
        reasoningEffort: .xhigh,
        permissionMode: .autoReview,
        collaborationMode: .plan
    ))
}

@Test func sessionStoreSendsStructuredUserMessageThroughExistingTurnAttachmentProtocol() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)
    try await store.open(threadID: "thread-1")

    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.message = StructuredUserMessage(
        body: "分析图片",
        attachments: [
            MessageAttachment(
                id: "image-1",
                kind: .image(contentType: "image/png", detail: "high"),
                displayName: "screen.png",
                source: .localCache(path: "/app/cache/screen.png")
            )
        ]
    )

    try await store.send(composer: composer)

    #expect(protocolClient.lastTurnStart?.prompt == "分析图片")
    #expect(protocolClient.lastTurnStart?.attachments == [
        .localImage(path: "/app/cache/screen.png", detail: "high")
    ])
    #expect(store.visibleItems == [.structuredUserMessage(composer.message)])
}


@Test func sessionStoreOpensNewThreadWithoutResumingHistory() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)

    store.openNew(threadID: "thread-new")
    try await store.send(prompt: "开始规划")

    #expect(protocolClient.calls == ["turn/start"])
    #expect(protocolClient.lastTurnStart?.threadID == "thread-new")
    #expect(protocolClient.lastTurnStart?.model == .gpt55)
    #expect(store.thread == ThreadDetail(id: "thread-new", turns: []))
    #expect(store.visibleItems == [.userMessage("开始规划")])
}

@Test func sessionStoreResumesRunningThreadAndSteersInsteadOfStartingParallelTurn() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [
        Turn(id: "turn-running", status: .running, items: [
            .userMessage("iMac 上的运行中消息")
        ])
    ])
    let store = SessionStore(protocolClient: protocolClient)

    try await store.open(threadID: "thread-1")
    try await store.send(prompt: "手机补充上下文")

    #expect(protocolClient.calls == [
        "thread/resume(initialTurnLimit:10,timeout:30.0)",
        "turn/steer"
    ])
    #expect(protocolClient.lastTurnSteer == TurnSteerRecord(
        threadID: "thread-1",
        turnID: "turn-running",
        prompt: "手机补充上下文",
        attachments: []
    ))
    #expect(protocolClient.lastTurnStart == nil)
    #expect(store.visibleItems == [
        .userMessage("iMac 上的运行中消息"),
        .userMessage("手机补充上下文")
    ])
}

@Test func sessionStoreTracksOfficialTurnStartResponseAndOnlyAppendsAfterSuccess() async throws {
    let transport = RecordingCodexTransport()
    transport.stubbedResponses["thread/resume"] = .object([
        "thread": .object([
            "id": .string("thread-1"),
            "turns": .array([])
        ])
    ])
    transport.stubbedResponses["turn/start"] = .object([
        "turn": .object([
            "id": .string("turn-official"),
            "items": .array([]),
            "status": .string("inProgress")
        ])
    ])
    let store = SessionStore(protocolClient: CodexProtocolFacade(transport: transport))

    try await store.open(threadID: "thread-1")
    try await store.send(prompt: "继续")

    #expect(store.runningTurnID == "turn-official")
    #expect(store.visibleItems == [.userMessage("继续")])

    let failingTransport = RecordingCodexTransport()
    failingTransport.stubbedResponses["thread/resume"] = .object([
        "thread": .object([
            "id": .string("thread-1"),
            "turns": .array([])
        ])
    ])
    let failingStore = SessionStore(protocolClient: CodexProtocolFacade(transport: failingTransport))

    try await failingStore.open(threadID: "thread-1")
    failingTransport.error = JSONRPCError.remote(code: -32602, message: "Invalid params")
    await #expect(throws: JSONRPCError.remote(code: -32602, message: "Invalid params")) {
        try await failingStore.send(prompt: "不会假发送")
    }
    #expect(failingStore.visibleItems.isEmpty)
}

@Test func sessionStoreUploadsPendingAttachmentsBeforeStartingTurn() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)
    try await store.open(threadID: "thread-1")

    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.text = "分析这些附件"
    composer.attachments = [
        .localImage(path: "camera.jpg", detail: "high"),
        .remoteFile(path: "notes.txt")
    ]
    let bridge = AttachmentComposerBridge(uploader: AttachmentUploader(
        protocolClient: protocolClient,
        remoteRoot: "/home/codex/.codex-port/attachments",
        clock: { Date(timeIntervalSince1970: 1_700_000_000) }
    ))

    try await store.send(
        composer: composer,
        pendingAttachments: [
            PendingAttachment(name: "camera.jpg", kind: .image(detail: "high"), data: Data([0xCA, 0xFE]), localCachePath: "/app/cache/camera.jpg"),
            PendingAttachment(name: "notes.txt", kind: .file, data: Data("notes".utf8))
        ],
        attachmentBridge: bridge
    )

    #expect(protocolClient.calls == [
        "thread/resume(initialTurnLimit:10,timeout:30.0)",
        "fs/createDirectory",
        "fs/writeFile",
        "fs/writeFile",
        "turn/start"
    ])
    #expect(protocolClient.lastTurnStart?.attachments == [
        .localImage(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/camera.jpg", detail: "high"),
        .remoteFile(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt")
    ])
    #expect(store.visibleItems.last == .structuredUserMessage(StructuredUserMessage(
        body: "分析这些附件",
        attachments: [
            MessageAttachment(
                id: "camera.jpg",
                kind: .image(contentType: nil, detail: "high"),
                displayName: "camera.jpg",
                source: .localCache(path: "/app/cache/camera.jpg")
            ),
            MessageAttachment(
                id: "notes.txt",
                kind: .file(contentType: nil),
                displayName: "notes.txt",
                source: .remoteHostPath("/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt")
            )
        ]
    )))
}

@Test func sessionStoreMapsHistoryMarkdownImagesToStructuredUserMessageAttachments() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)
    store.openNew(threadID: "thread-1")
    let imagePath = "~/.codex-port/attachments/thread-1/1700000000/photo-1.jpg"

    store.receive(relayHistoryPage: RelayThreadHistoryPage(
        requestID: "initial",
        threadID: "thread-1",
        items: [
            .userMessage("请看这张图\n![photo](\(imagePath))")
        ],
        status: .completed,
        nextCursor: nil
    ))

    let expected = StructuredUserMessage(
        body: "请看这张图",
        attachments: [
            MessageAttachment(
                id: "markdown-image-0",
                kind: .image(contentType: "image/jpeg", detail: nil),
                displayName: "photo-1.jpg",
                source: .remoteHostPath(imagePath)
            )
        ]
    )
    #expect(store.visibleItems == [.structuredUserMessage(expected)])

    let rows = TranscriptPresentation.rows(for: store.visibleItems)
    #expect(rows.first?.body == "请看这张图")
    #expect(rows.first?.imageAttachments == [
        ImageAttachmentGalleryItem(
            id: "markdown-image-0",
            displayName: "photo-1.jpg",
            availability: .remote(path: imagePath)
        )
    ])
}

@Test func sessionStoreMapsStructuredHistoryImagePathsToUserMessageAttachments() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)
    store.openNew(threadID: "thread-1")
    let firstImagePath = "/var/folders/d4/T/codex-clipboard-a.png"
    let secondImagePath = "/var/folders/d4/T/codex-clipboard-b.jpg"

    store.receive(relayHistoryPage: RelayThreadHistoryPage(
        requestID: "initial",
        threadID: "thread-1",
        items: [
            .structuredUserMessage(
                text: "[Image #1] [Image #2]  基于这2个方向继续深化",
                imagePaths: [firstImagePath, secondImagePath]
            )
        ],
        status: .completed,
        nextCursor: nil
    ))

    let expected = StructuredUserMessage(
        body: "基于这2个方向继续深化",
        attachments: [
            MessageAttachment(
                id: "history-image-0",
                kind: .image(contentType: "image/png", detail: nil),
                displayName: "codex-clipboard-a.png",
                source: .remoteHostPath(firstImagePath)
            ),
            MessageAttachment(
                id: "history-image-1",
                kind: .image(contentType: "image/jpeg", detail: nil),
                displayName: "codex-clipboard-b.jpg",
                source: .remoteHostPath(secondImagePath)
            ),
        ]
    )
    #expect(store.visibleItems == [.structuredUserMessage(expected)])

    let rows = TranscriptPresentation.rows(for: store.visibleItems)
    #expect(rows.first?.body == "基于这2个方向继续深化")
    #expect(rows.first?.imageAttachments == [
        ImageAttachmentGalleryItem(
            id: "history-image-0",
            displayName: "codex-clipboard-a.png",
            availability: .remote(path: firstImagePath)
        ),
        ImageAttachmentGalleryItem(
            id: "history-image-1",
            displayName: "codex-clipboard-b.jpg",
            availability: .remote(path: secondImagePath)
        ),
    ])
}

@Test func sessionStoreMergesStreamedEventsAndInterruptsRunningTurn() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)
    store.receive(.turnStarted(threadID: "thread-1", turnID: "turn-1"))
    store.receive(.agentMessageDelta(turnID: "turn-1", itemID: "msg-1", delta: "Hel"))
    store.receive(.agentMessageDelta(turnID: "turn-1", itemID: "msg-1", delta: "lo"))
    store.receive(.commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", delta: "ls\n"))
    store.receive(.fileChangeDelta(turnID: "turn-1", itemID: "file-1", path: "README.md", diff: "+hi"))

    #expect(store.visibleItems == [
        .assistantMessage("Hello"),
        .commandOutput("ls\n"),
        .fileChange(path: "README.md", diff: "+hi")
    ])

    try await store.interrupt()
    #expect(protocolClient.interrupted == InterruptRequest(threadID: "thread-1", turnID: "turn-1"))
    #expect(store.status == .interrupting)

    store.receive(.turnCompleted(turnID: "turn-1"))
    #expect(store.status == .completed)
}

@Test func sessionStoreMergesOfficialAppServerNotifications() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)

    store.receive(notification: JSONRPCNotification(
        method: "turn/started",
        params: .object([
            "threadId": .string("thread-1"),
            "turn": .object([
                "id": .string("turn-1"),
                "items": .array([]),
                "status": .string("inProgress")
            ])
        ])
    ))
    store.receive(notification: JSONRPCNotification(
        method: "item/agentMessage/delta",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("agent-1"),
            "delta": .string("Hel")
        ])
    ))
    store.receive(notification: JSONRPCNotification(
        method: "item/commandExecution/outputDelta",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("cmd-1"),
            "delta": .string("swift test\n")
        ])
    ))
    store.receive(notification: JSONRPCNotification(
        method: "item/fileChange/patchUpdated",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("file-1"),
            "changes": .array([
                .object([
                    "path": .string("README.md"),
                    "kind": .string("update"),
                    "diff": .string("+hello")
                ])
            ])
        ])
    ))
    store.receive(notification: JSONRPCNotification(
        method: "turn/completed",
        params: .object([
            "threadId": .string("thread-1"),
            "turn": .object([
                "id": .string("turn-1"),
                "items": .array([]),
                "status": .string("completed")
            ])
        ])
    ))

    #expect(store.runningThreadID == "thread-1")
    #expect(store.runningTurnID == nil)
    #expect(store.status == .completed)
    #expect(store.visibleItems == [
        .assistantMessage("Hel"),
        .commandOutput("swift test\n"),
        .fileChange(path: "README.md", diff: "+hello")
    ])
}

@Test func sessionStoreMergesTurnStartedItemsFromAnotherClient() async throws {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)

    store.receive(notification: JSONRPCNotification(
        method: "turn/started",
        params: .object([
            "threadId": .string("thread-1"),
            "turn": .object([
                "id": .string("turn-remote"),
                "status": .string("inProgress"),
                "items": .array([
                    .object([
                        "type": .string("userMessage"),
                        "id": .string("remote-user-1"),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("电脑上发送的消息"),
                                "text_elements": .array([])
                            ])
                        ])
                    ])
                ])
            ])
        ])
    ))

    #expect(store.runningThreadID == "thread-1")
    #expect(store.runningTurnID == "turn-remote")
    #expect(store.status == .running)
    #expect(store.visibleItems == [
        .userMessage("电脑上发送的消息")
    ])
}

@Test func sessionStoreMergesItemStartedAndThreadStatusNotificationsFromAnotherClient() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)
    try await store.open(threadID: "thread-1")

    store.receive(notification: JSONRPCNotification(
        method: "thread/status/changed",
        params: .object([
            "threadId": .string("thread-1"),
            "status": .object(["type": .string("active"), "activeFlags": .array([])])
        ])
    ))
    store.receive(notification: JSONRPCNotification(
        method: "item/started",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-remote"),
            "startedAtMs": .number(1),
            "item": .object([
                "type": .string("userMessage"),
                "id": .string("remote-user-1"),
                "clientId": .null,
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("桌面端刚发送的消息"),
                        "text_elements": .array([])
                    ])
                ])
            ])
        ])
    ))
    store.receive(notification: JSONRPCNotification(
        method: "thread/status/changed",
        params: .object([
            "threadId": .string("thread-1"),
            "status": .object(["type": .string("idle")])
        ])
    ))

    #expect(store.visibleItems == [.userMessage("桌面端刚发送的消息")])
    #expect(store.status == .completed)
    #expect(store.runningTurnID == nil)
}

@Test func sessionStoreIgnoresNotificationsForOtherThreads() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)
    try await store.open(threadID: "thread-1")

    store.receive(notification: JSONRPCNotification(
        method: "item/completed",
        params: .object([
            "threadId": .string("thread-2"),
            "turnId": .string("turn-other"),
            "item": .object([
                "type": .string("agentMessage"),
                "id": .string("agent-other"),
                "text": .string("别的会话消息")
            ])
        ])
    ))

    #expect(store.visibleItems.isEmpty)
}

@Test func sessionStoreMergesOfficialCompletedUserItemsWithoutDuplicatingOptimisticMessages() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)

    try await store.open(threadID: "thread-1")
    store.receive(notification: JSONRPCNotification(
        method: "item/completed",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-remote"),
            "item": .object([
                "type": .string("userMessage"),
                "id": .string("remote-user-1"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("iMac 上发送的消息"),
                        "text_elements": .array([])
                    ])
                ])
            ])
        ])
    ))
    #expect(store.visibleItems == [.userMessage("iMac 上发送的消息")])

    try await store.send(prompt: "手机上发送的消息")
    store.receive(notification: JSONRPCNotification(
        method: "item/completed",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-started"),
            "item": .object([
                "type": .string("userMessage"),
                "id": .string("local-user-1"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("手机上发送的消息"),
                        "text_elements": .array([])
                    ])
                ])
            ])
        ])
    ))
    #expect(store.visibleItems == [
        .userMessage("iMac 上发送的消息"),
        .userMessage("手机上发送的消息")
    ])
}

@Test func sessionStoreUnsubscribesCurrentThreadOnClose() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let store = SessionStore(protocolClient: protocolClient)

    try await store.open(threadID: "thread-1")
    await store.close()

    #expect(protocolClient.calls == [
        "thread/resume(initialTurnLimit:10,timeout:30.0)",
        "thread/unsubscribe"
    ])
}

private func turnJSON(index: Int) -> JSONValue {
    .object([
        "id": .string("turn-\(index)"),
        "status": .string("completed"),
        "items": .array([
            .object([
                "type": .string("userMessage"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("user \(index)"),
                        "text_elements": .array([])
                    ])
                ])
            ]),
            .object([
                "type": .string("agentMessage"),
                "text": .string("assistant \(index)")
            ])
        ])
    ])
}
