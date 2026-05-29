import Foundation
import Testing
@testable import CodexPortCore

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
        "thread/resume",
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
        .commandOutput("Test run passed\n"),
        .fileChange(path: "Sources/CodexPortCore/SessionStore.swift", diff: "+ parse official items")
    ])
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
        permissionMode: .autoReview,
        collaborationMode: .plan
    ))
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
        "thread/resume",
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
            PendingAttachment(name: "camera.jpg", kind: .image(detail: "high"), data: Data([0xCA, 0xFE])),
            PendingAttachment(name: "notes.txt", kind: .file, data: Data("notes".utf8))
        ],
        attachmentBridge: bridge
    )

    #expect(protocolClient.calls == [
        "thread/resume",
        "fs/createDirectory",
        "fs/writeFile",
        "fs/writeFile",
        "turn/start"
    ])
    #expect(protocolClient.lastTurnStart?.attachments == [
        .localImage(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/camera.jpg", detail: "high"),
        .remoteFile(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt")
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
        "thread/resume",
        "thread/unsubscribe"
    ])
}
