import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayJSONLSessionClientAttachesSendsPromptAndFeedsSessionStore() async throws {
    let transport = RecordingRelayJSONLTransport()
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try await client.sendPrompt("hello relay", writeID: "write-1")

    #expect(await transport.sentLinesSnapshot() == [
        #"{"clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1","type":"attach"}"#,
        #"{"clientID":"iphone-a","sessionID":"session-1","text":"hello relay","threadID":"thread-1","type":"prompt","writeID":"write-1"}"#,
    ])
    #expect(store.visibleItems == [.userMessage("hello relay")])

    try await transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
        clientID: "iphone-a"
    ))
    try await transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "reply"),
        clientID: "iphone-a"
    ))
    await waitUntil {
        store.status == .running && store.visibleItems == [.userMessage("hello relay"), .assistantMessage("reply")]
    }

    #expect(store.status == .running)
    #expect(store.visibleItems == [.userMessage("hello relay"), .assistantMessage("reply")])
}

@Test func relayJSONLSessionClientIncludesThreadCWDWhenAttaching() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        cwd: "/Users/chenm/Projects/codex-port",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()

    let attach = try #require(await transport.firstSentJSONObject())
    #expect(attach["type"] as? String == "attach")
    #expect(attach["clientID"] as? String == "iphone-a")
    #expect(attach["sessionID"] as? String == "session-1")
    #expect(attach["threadID"] as? String == "thread-1")
    #expect(attach["turnID"] as? String == "turn-1")
    #expect(attach["cwd"] as? String == "/Users/chenm/Projects/codex-port")
}

@Test func relayJSONLSessionClientReadsRemoteFileContentOverJSONL() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    async let result = client.readRemoteFile(
        path: "/Users/chenm/Desktop/screen.png",
        maxBytes: 10,
        requestID: "file-1",
        timeout: .milliseconds(300)
    )
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""type":"readFile""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeFileContent(
        RelayRemoteFileContent(
            requestID: "file-1",
            path: "/Users/chenm/Desktop/screen.png",
            contentType: "image/png",
            byteCount: 4,
            dataBase64: "iVBORw=="
        ),
        clientID: "iphone-a"
    ))

    #expect(try await result == .success(RemoteFileContent(
        path: "/Users/chenm/Desktop/screen.png",
        contentType: "image/png",
        byteCount: 4,
        data: Data(base64Encoded: "iVBORw==") ?? Data()
    )))
    #expect(await transport.sentLinesSnapshot().contains(
        #"{"clientID":"iphone-a","maxBytes":10,"path":"\/Users\/chenm\/Desktop\/screen.png","requestID":"file-1","type":"readFile"}"#
    ))
}

@Test func relayJSONLSessionClientSurfacesAbortedSendWithoutAppendingOptimisticPrompt() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    await transport.failNextSendWith(POSIXError(.ECONNABORTED))
    var capturedError: Error?
    do {
        try await client.sendPrompt("hello after reconnect", writeID: "write-retry")
    } catch {
        capturedError = error
    }

    #expect((capturedError as? POSIXError)?.code == .ECONNABORTED)
    #expect(await transport.sentLinesSnapshot() == [
        #"{"clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1","type":"attach"}"#,
    ])
    #expect(store.visibleItems.isEmpty)
}

@Test func relayJSONLSessionClientWaitsForPromptWriteAcceptance() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    async let status = client.sendPromptAndWaitForAcceptance(
        "hello accepted relay",
        writeID: "write-accepted",
        timeout: .milliseconds(300)
    )
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""writeID":"write-accepted""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .writeStatusChanged(writeID: "write-accepted", status: .queued),
        clientID: "iphone-a"
    ))

    #expect(try await status == .queued)
    #expect(store.visibleItems == [.userMessage("hello accepted relay")])
}

@Test func relayJSONLSessionClientUploadsPendingImageBeforeSendingRelayPrompt() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )
    var composer = InputComposer(modelDisplay: "5.5")
    composer.text = "看这张图"
    let pendingImage = PendingAttachment(
        name: "photo.png",
        kind: .image(detail: "high"),
        data: Data([0x89, 0x50, 0x4E, 0x47]),
        localCachePath: "/tmp/ios-photo.png"
    )

    try await client.attach()
    async let status = client.send(
        composer: composer,
        pendingAttachments: [pendingImage],
        remoteRoot: "~/.codex-port/attachments",
        writeID: "write-photo",
        timeout: .milliseconds(500)
    )
    let createDirectoryLine = try await transport.waitForSentLine(containing: #""type":"createDirectory""#)
    let createDirectory = try #require(jsonObject(from: createDirectoryLine))
    let directoryPath = try #require(createDirectory["path"] as? String)
    #expect(directoryPath.hasPrefix("~/.codex-port/attachments/thread-1/"))
    try transport.emit(RelayEndpointJSONLCodec.encodeFileOperationResult(
        operation: "createDirectory",
        requestID: try #require(createDirectory["requestID"] as? String),
        path: directoryPath,
        clientID: "iphone-a"
    ))

    let writeFileLine = try await transport.waitForSentLine(containing: #""type":"writeFile""#)
    let writeFile = try #require(jsonObject(from: writeFileLine))
    let uploadedPath = try #require(writeFile["path"] as? String)
    #expect(uploadedPath.hasPrefix(directoryPath))
    #expect(writeFile["dataBase64"] as? String == pendingImage.data.base64EncodedString())
    try transport.emit(RelayEndpointJSONLCodec.encodeFileOperationResult(
        operation: "writeFile",
        requestID: try #require(writeFile["requestID"] as? String),
        path: uploadedPath,
        clientID: "iphone-a"
    ))

    let promptLine = try await transport.waitForSentLine(containing: #""writeID":"write-photo""#)
    let prompt = try #require(jsonObject(from: promptLine))
    let attachments = try #require(prompt["attachments"] as? [[String: Any]])
    #expect(prompt["text"] as? String == "看这张图")
    #expect(attachments.count == 1)
    #expect(attachments.first?["type"] as? String == "localImage")
    #expect(attachments.first?["path"] as? String == uploadedPath)
    #expect(attachments.first?["detail"] as? String == "high")
    try transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .writeStatusChanged(writeID: "write-photo", status: .queued),
        clientID: "iphone-a"
    ))

    #expect(try await status == .queued)
    #expect(store.visibleItems == [
        .structuredUserMessage(StructuredUserMessage(
            body: "看这张图",
            attachments: [
                MessageAttachment(
                    id: "photo.png",
                    kind: .image(contentType: nil, detail: "high"),
                    displayName: "photo.png",
                    source: .localCache(path: "/tmp/ios-photo.png")
                ),
            ]
        )),
    ])
}

@Test func relayJSONLSessionClientShowsThinkingRowAfterPromptWriteQueued() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    async let status = client.sendPromptAndWaitForAcceptance(
        "hello working relay",
        writeID: "write-working",
        timeout: .milliseconds(300)
    )
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""writeID":"write-working""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .writeStatusChanged(writeID: "write-working", status: .queued),
        clientID: "iphone-a"
    ))

    #expect(try await status == .queued)
    await waitUntil {
        store.visibleItems == [.userMessage("hello working relay")]
            && store.status == .running
    }

    let rows = TranscriptPresentation.rows(for: store.visibleItems, status: store.status)
    #expect(rows.map(\.kind) == [.userBubble, .thinking])
    #expect(rows.last?.body == "正在思考...")
}

@Test func relayJSONLSessionClientSurfacesFailedWriteStatusFromHostAgent() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )
    let reason = "Relay session is not running."

    try await client.attach()
    async let status = client.sendPromptAndWaitForAcceptance(
        "hello failed relay",
        writeID: "write-failed",
        timeout: .milliseconds(300)
    )
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""writeID":"write-failed""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeWriteStatus(
        .failed(reason: reason),
        clientID: "iphone-a",
        sessionID: "session-1",
        writeID: "write-failed"
    ))

    let capturedError: Error?
    do {
        _ = try await status
        capturedError = nil
    } catch {
        capturedError = error
    }
    #expect(capturedError as? RelayJSONLSessionClientError == .writeFailed(reason))
    await waitUntil {
        store.status == .failed(reason)
    }
    #expect(store.status == .failed(reason))
    #expect(store.visibleItems.isEmpty)
}

@Test func relayJSONLSessionClientManagerPreservesOptimisticPromptWhenReattachHistoryArrivesAfterRetry() async throws {
    let firstTransport = RecordingRelayJSONLTransport()
    let secondTransport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let factory = RelaySessionClientFactoryHarness(transports: [firstTransport, secondTransport])
    let manager = RelayJSONLSessionClientManager(sessionStore: store) { sessionStore in
        factory.makeClient(sessionStore: sessionStore)
    }

    _ = try await manager.attach()
    await firstTransport.failNextSendWith(POSIXError(.ECONNABORTED))
    try await manager.sendPrompt("hello after reconnect", writeID: "write-retry")
    try secondTransport.emit(RelayEndpointJSONLCodec.encodeThreadHistoryPage(
        RelayThreadHistoryPage(
            requestID: "initial",
            threadID: "thread-1",
            items: [
                .userMessage("older question"),
                .assistantMessage("older answer"),
            ],
            status: .running,
            nextCursor: nil
        ),
        clientID: "iphone-a"
    ))
    await waitUntil {
        store.visibleItems.contains(.userMessage("older question"))
    }

    #expect(factory.clientCount == 2)
    #expect(store.visibleItems == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
        .userMessage("hello after reconnect"),
    ])
}

@Test func relayJSONLSessionClientManagerRecreatesClientAfterAbortedSend() async throws {
    let firstTransport = RecordingRelayJSONLTransport()
    let secondTransport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let factory = RelaySessionClientFactoryHarness(transports: [firstTransport, secondTransport])
    let manager = RelayJSONLSessionClientManager(sessionStore: store) { sessionStore in
        factory.makeClient(sessionStore: sessionStore)
    }

    _ = try await manager.attach()
    await firstTransport.failNextSendWith(POSIXError(.ECONNABORTED))
    try await manager.sendPrompt("hello recreated client", writeID: "write-retry")

    #expect(factory.clientCount == 2)
    #expect(await firstTransport.sentLinesSnapshot() == [
        #"{"clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1","type":"attach"}"#,
    ])
    #expect(await secondTransport.sentLinesSnapshot() == [
        #"{"clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1","type":"attach"}"#,
        #"{"clientID":"iphone-a","sessionID":"session-1","text":"hello recreated client","threadID":"thread-1","type":"prompt","writeID":"write-retry"}"#,
    ])
    #expect(store.visibleItems == [.userMessage("hello recreated client")])
}

@Test func relayJSONLSessionClientIgnoresEventsForOtherClients() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try await transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "other client event"),
        clientID: "iphone-b"
    ))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.visibleItems.isEmpty)
}

@Test func relayJSONLSessionClientPublishesWriteStatusUpdatesForItsClientOnly() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try transport.emit(RelayEndpointJSONLCodec.encodeWriteStatus(
        .handled,
        clientID: "iphone-b",
        sessionID: "session-1",
        writeID: "other-write"
    ))
    try transport.emit(RelayEndpointJSONLCodec.encodeWriteStatus(
        .handled,
        clientID: "iphone-a",
        sessionID: "session-1",
        writeID: "write-1"
    ))
    await waitUntil {
        client.latestWriteStatus?.writeID == "write-1"
    }

    #expect(client.latestWriteStatus == RelayJSONLSessionClient.WriteStatusUpdate(
        sessionID: "session-1",
        writeID: "write-1",
        status: .handled
    ))
}

@Test func relayJSONLSessionClientPublishesFanOutWriteStatusChangedEvents() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .writeStatusChanged(writeID: "interrupt-1", status: .handled),
        clientID: "iphone-a"
    ))
    await waitUntil {
        client.latestWriteStatus?.writeID == "interrupt-1"
    }

    #expect(client.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-1", status: .handled))
}

@Test func relayJSONLSessionClientAppliesTurnFailureReasonFromHostAgent() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: transport,
        sessionStore: store
    )
    let reason = "Codex CLI exec failed during prompt execution with exit code 1. stderr: not authenticated"

    try await client.attach()
    try transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .turnFailed(turnID: "turn-1", reason: reason),
        clientID: "iphone-a"
    ))
    await waitUntil {
        store.status == .failed(reason)
    }

    #expect(store.status == .failed(reason))
}

@Test func relayJSONLSessionClientLoadsExistingThreadHistoryOnAttach() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "thread-1",
        threadID: "thread-1",
        turnID: "thread-1-turn",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try await transport.emit(RelayEndpointJSONLCodec.encodeThreadHistoryPage(
        RelayThreadHistoryPage(
            requestID: "initial",
            threadID: "thread-1",
            items: [
                RelayThreadHistoryItem.userMessage("桌面端已有问题"),
                RelayThreadHistoryItem.assistantMessage("桌面端已有回答"),
            ],
            status: RelayThreadRunStatus.completed,
            nextCursor: nil
        ),
        clientID: "iphone-a"
    ))
    await waitUntil {
        store.visibleItems == [
            .userMessage("桌面端已有问题"),
            .assistantMessage("桌面端已有回答"),
        ]
    }

    #expect(store.status == .completed)
}

@Test func relayJSONLSessionClientRequestsEarlierHistoryPageAndPrependsItWithoutDroppingLiveItems() async throws {
    let transport = RecordingRelayJSONLTransport()
    let store = SessionStore(protocolClient: FakeCodexProtocol(), initialVisibleItemLimit: 10)
    let client = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "thread-1",
        threadID: "thread-1",
        turnID: "thread-1-turn",
        transport: transport,
        sessionStore: store
    )

    try await client.attach()
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadHistoryPage(
        RelayThreadHistoryPage(
            requestID: "initial",
            threadID: "thread-1",
            items: [
                .userMessage("recent question"),
                .assistantMessage("recent answer"),
            ],
            status: .completed,
            nextCursor: "older-cursor-1"
        ),
        clientID: "iphone-a"
    ))
    try transport.emit(RelayEndpointJSONLCodec.encodeEvent(
        .assistantTextDelta(turnID: "live-turn", itemID: "live-assistant", text: "live delta"),
        clientID: "iphone-a"
    ))
    await waitUntil {
        store.visibleItems == [
            .userMessage("recent question"),
            .assistantMessage("recent answer"),
            .assistantMessage("live delta"),
        ]
    }

    async let page: RelayThreadHistoryPage = client.loadEarlierHistory(
        cursor: "older-cursor-1",
        limit: 10,
        requestID: "history-request-1"
    )
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""type":"loadHistory""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadHistoryPage(
        RelayThreadHistoryPage(
            requestID: "history-request-1",
            threadID: "thread-1",
            items: [
                .userMessage("older question"),
                .assistantMessage("older answer"),
            ],
            status: .completed,
            nextCursor: nil
        ),
        clientID: "iphone-a"
    ))

    #expect(try await page.items == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
    ])
    await waitUntil {
        store.visibleItems == [
            .userMessage("older question"),
            .assistantMessage("older answer"),
            .userMessage("recent question"),
            .assistantMessage("recent answer"),
            .assistantMessage("live delta"),
        ]
    }
    #expect(await transport.sentLinesSnapshot().contains(
        #"{"clientID":"iphone-a","cursor":"older-cursor-1","limit":10,"requestID":"history-request-1","threadID":"thread-1","type":"loadHistory"}"#
    ))
}

@Test func relayJSONLThreadListClientRequestsAndReceivesRealThreadSummaries() async throws {
    let transport = RecordingRelayJSONLTransport()
    let client = RelayJSONLThreadListClient(
        clientID: "iphone-a",
        transport: transport,
        timeout: .milliseconds(300)
    )
    let threads = [
        RelayThreadSummarySnapshot(
            id: "thread-1",
            cwd: "/Users/chenm/Projects/codex-port",
            updatedAtUnixTime: 1_780_991_312,
            preview: "Relay thread",
            gitRepository: "git@github.com:zhxsinc/codex-port.git",
            gitBranch: "main",
            status: "completed"
        ),
    ]

    async let result = client.listThreads(limit: 20, requestID: "request-1")
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().first?.contains(#""type":"listThreads""#)) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        threads,
        clientID: "iphone-a",
        requestID: "request-1"
    ))

    #expect(try await result == threads)
    #expect(await transport.sentLinesSnapshot() == [
        #"{"clientID":"iphone-a","limit":20,"requestID":"request-1","type":"listThreads"}"#,
    ])
}

@Test func relayJSONLThreadListClientReportsConnectionProgressStages() async throws {
    let transport = RecordingRelayJSONLTransport()
    let recorder = RelayThreadListProgressRecorder()
    let client = RelayJSONLThreadListClient(
        clientID: "iphone-a",
        transport: transport,
        timeout: .milliseconds(300),
        progressObserver: { event in
            await recorder.record(event)
        }
    )

    async let result = client.listThreads(limit: 20, requestID: "request-1")
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().first?.contains(#""type":"listThreads""#)) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        [threadSnapshot(1)],
        clientID: "iphone-a",
        requestID: "request-1"
    ))

    #expect(try await result.map(\.id) == ["thread-1"])
    #expect(await recorder.snapshot() == [
        .requestingPage(requestID: "request-1", limit: 20, cursor: nil),
        .receivedPage(requestID: "request-1", count: 1, nextCursor: nil),
    ])
}

@Test func relayJSONLThreadListClientDefaultsToOneHundredRecentThreads() async throws {
    let transport = RecordingRelayJSONLTransport()
    let client = RelayJSONLThreadListClient(
        clientID: "iphone-a",
        transport: transport,
        timeout: .milliseconds(300)
    )

    async let result = client.listThreads(limit: 45, requestID: "request-default")
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().first?.contains(#""type":"listThreads""#)) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        (0..<20).map(threadSnapshot),
        clientID: "iphone-a",
        requestID: "request-default",
        nextCursor: "cursor-20"
    ))
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""cursor":"cursor-20""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        (20..<40).map(threadSnapshot),
        clientID: "iphone-a",
        requestID: "request-default-20",
        nextCursor: "cursor-40"
    ))
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""cursor":"cursor-40""#) }) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        (40..<45).map(threadSnapshot),
        clientID: "iphone-a",
        requestID: "request-default-40",
        nextCursor: nil
    ))

    #expect(try await result.map(\.id) == (0..<45).map { "thread-\($0)" })
    #expect(try await transport.sentLinesSnapshot() == [
        #"{"clientID":"iphone-a","limit":20,"requestID":"request-default","type":"listThreads"}"#,
        #"{"clientID":"iphone-a","cursor":"cursor-20","limit":20,"requestID":"request-default-20","type":"listThreads"}"#,
        #"{"clientID":"iphone-a","cursor":"cursor-40","limit":5,"requestID":"request-default-40","type":"listThreads"}"#,
    ])
}

@Test func relayJSONLThreadListClientReturnsLoadedPagesWhenLaterPageTimesOut() async throws {
    let transport = RecordingRelayJSONLTransport()
    let client = RelayJSONLThreadListClient(
        clientID: "iphone-a",
        transport: transport,
        timeout: .milliseconds(30)
    )

    async let result = client.listThreads(limit: 40, requestID: "request-partial")
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().first?.contains(#""type":"listThreads""#)) == true
    }
    try transport.emit(RelayEndpointJSONLCodec.encodeThreadList(
        (0..<20).map(threadSnapshot),
        clientID: "iphone-a",
        requestID: "request-partial",
        nextCursor: "cursor-20"
    ))
    await waitUntil {
        (try? transport.sentLinesSyncSnapshot().contains { $0.contains(#""cursor":"cursor-20""#) }) == true
    }

    #expect(try await result.map(\.id) == (0..<20).map { "thread-\($0)" })
}

private func threadSnapshot(_ index: Int) -> RelayThreadSummarySnapshot {
    RelayThreadSummarySnapshot(
        id: "thread-\(index)",
        cwd: "/repo",
        updatedAtUnixTime: TimeInterval(index),
        preview: "Thread \(index)",
        gitRepository: nil,
        gitBranch: nil,
        status: "completed"
    )
}

private final class RecordingRelayJSONLTransport: RelayJSONLTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentLines: [String] = []
    private var nextSendError: Error?
    private var continuation: AsyncStream<String>.Continuation?
    let incomingLines: AsyncStream<String>

    init() {
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.incomingLines = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func sendLine(_ line: String) async throws {
        let error = lock.withLock {
            nextSendError.map { error in
                nextSendError = nil
                return error
            }
        }
        if let error {
            throw error
        }
        lock.withLock {
            sentLines.append(line)
        }
    }

    func failNextSendWith(_ error: Error) async {
        lock.withLock {
            nextSendError = error
        }
    }

    func emit(_ line: String) {
        lock.withLock {
            continuation
        }?.yield(line)
    }

    func sentLinesSnapshot() async -> [String] {
        lock.withLock {
            sentLines
        }
    }

    func sentLinesSyncSnapshot() throws -> [String] {
        lock.withLock {
            sentLines
        }
    }

    func waitForSentLine(containing needle: String, timeout: Duration = .milliseconds(300)) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let line = lock.withLock({ sentLines.first(where: { $0.contains(needle) }) }) {
                return line
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RelayJSONLSessionClientError.timedOut
    }

    func firstSentJSONObject() async throws -> [String: Any]? {
        guard let first = await sentLinesSnapshot().first,
              let data = first.data(using: .utf8) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private func jsonObject(from line: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
}

private final class RelaySessionClientFactoryHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let transports: [RecordingRelayJSONLTransport]
    private var index = 0

    init(transports: [RecordingRelayJSONLTransport]) {
        self.transports = transports
    }

    var clientCount: Int {
        lock.withLock {
            index
        }
    }

    func makeClient(sessionStore: SessionStore) -> RelayJSONLSessionClient? {
        let transport = lock.withLock {
            guard transports.indices.contains(index) else { return nil as RecordingRelayJSONLTransport? }
            let transport = transports[index]
            index += 1
            return transport
        }
        guard let transport else { return nil }
        return RelayJSONLSessionClient(
            clientID: "iphone-a",
            sessionID: "session-1",
            threadID: "thread-1",
            turnID: "turn-1",
            transport: transport,
            sessionStore: sessionStore
        )
    }
}

private actor RelayThreadListProgressRecorder {
    private var events: [RelayThreadListProgressEvent] = []

    func record(_ event: RelayThreadListProgressEvent) {
        events.append(event)
    }

    func snapshot() -> [RelayThreadListProgressEvent] {
        events
    }
}

private func waitUntil(
    timeout: Duration = .milliseconds(200),
    condition: @escaping @Sendable () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
