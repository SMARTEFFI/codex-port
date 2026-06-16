import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func codexCLILiveAdapterMapsPublicLiveProducerEventsAndSerializedWrites() async throws {
    let producer = FakeCodexCLILiveProducer()
    let adapter = HostAgentCodexCLILiveAdapter(
        session: CodexCLILiveSessionDescriptor(
            sessionID: "desktop-live-session",
            threadID: "codex-thread-1",
            turnID: "turn-1"
        ),
        producer: producer
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriber = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriber.next() == .sessionStarted(sessionID: "desktop-live-session", threadID: "codex-thread-1", turnID: "turn-1"))
    #expect(await producer.startedSessions() == [
        CodexCLILiveSessionDescriptor(sessionID: "desktop-live-session", threadID: "codex-thread-1", turnID: "turn-1")
    ])

    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "codex-thread-1", text: "Hi9")
    let enqueueTask = Task {
        await bridge.enqueue(write)
    }

    await producer.waitUntilPromptSubmitted()
    await producer.emit(.userMessage(turnID: "turn-1", itemID: "item-user", text: "Hi9"))
    await producer.emit(.assistantTextDelta(turnID: "turn-1", itemID: "item-agent", text: "Hi9 收到。"))
    await producer.emit(.commandOutputDelta(turnID: "turn-1", itemID: "item-tool", text: "tool output"))
    await producer.emit(.approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "needs approval"))
    await producer.completeSubmittedPrompt(.accepted)
    #expect(await enqueueTask.value == .handled)
    await producer.emit(.turnCompleted(turnID: "turn-1"))

    let events = await collectNext(8, from: &subscriber)
    assertEvents(events, contain: [
        .writeStatusChanged(writeID: "write-1", status: .queued),
        .writeStatusChanged(writeID: "write-1", status: .running),
        .userMessage(turnID: "turn-1", itemID: "item-user", text: "Hi9"),
        .assistantTextDelta(turnID: "turn-1", itemID: "item-agent", text: "Hi9 收到。"),
        .commandOutputDelta(turnID: "turn-1", itemID: "item-tool", text: "tool output"),
        .approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "needs approval"),
        .writeStatusChanged(writeID: "write-1", status: .handled),
        .turnCompleted(turnID: "turn-1"),
    ])
    #expect(await producer.submittedPrompts() == [
        CodexCLILivePrompt(writeID: "write-1", threadID: "codex-thread-1", text: "Hi9")
    ])
}

@Test func codexCLILiveAdapterReportsProducerRejectedPromptWithoutLeakingPromptPlaintext() async throws {
    let logger = HostAgentLogRecorder()
    let producer = FakeCodexCLILiveProducer()
    let adapter = HostAgentCodexCLILiveAdapter(
        session: CodexCLILiveSessionDescriptor(
            sessionID: "desktop-live-session",
            threadID: "codex-thread-1",
            turnID: "turn-1"
        ),
        producer: producer,
        logger: logger
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)
    var subscriber = bridge.subscribe().makeAsyncIterator()

    try bridge.start()
    defer {
        bridge.stop()
    }

    #expect(await subscriber.next() == .sessionStarted(sessionID: "desktop-live-session", threadID: "codex-thread-1", turnID: "turn-1"))

    let promptSecret = "PROMPT_SECRET_live_adapter"
    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "codex-thread-1", text: promptSecret)
    let enqueueTask = Task {
        await bridge.enqueue(write)
    }

    await producer.waitUntilPromptSubmitted()
    await producer.completeSubmittedPrompt(.rejected(reason: "live producer unavailable"))
    #expect(await enqueueTask.value == .failed(reason: "live producer unavailable"))
    let events = await collectNext(3, from: &subscriber)
    assertEvents(events, contain: [
        .writeStatusChanged(writeID: "write-1", status: .queued),
        .writeStatusChanged(writeID: "write-1", status: .running),
        .writeStatusChanged(writeID: "write-1", status: .failed(reason: "live producer unavailable")),
    ])
    #expect(!logger.entries.joined(separator: "\n").contains(promptSecret))
}

@Test func codexCLILiveAdapterWaitsForProducerStartBeforeSubmittingPrompt() async throws {
    let producer = FakeCodexCLILiveProducer()
    await producer.holdStart()
    let adapter = HostAgentCodexCLILiveAdapter(
        session: CodexCLILiveSessionDescriptor(
            sessionID: "desktop-live-session",
            threadID: "codex-thread-1",
            turnID: "turn-1"
        ),
        producer: producer
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)

    try bridge.start()
    defer {
        bridge.stop()
    }

    await producer.waitUntilStartEntered()

    let write = RelayLiveSessionWrite.prompt(writeID: "write-1", threadID: "codex-thread-1", text: "Hi while starting")
    let enqueueTask = Task {
        await bridge.enqueue(write)
    }

    try await Task.sleep(for: .milliseconds(50))
    #expect(await producer.submittedPrompts().isEmpty)

    await producer.releaseStart()
    await producer.waitUntilPromptSubmitted()
    await producer.completeSubmittedPrompt(.accepted)
    #expect(await enqueueTask.value == .handled)
    #expect(await producer.submittedPrompts() == [
        CodexCLILivePrompt(writeID: "write-1", threadID: "codex-thread-1", text: "Hi while starting")
    ])
}

@Test func liveSessionBridgeStopsCodexCLILiveAdapterProducer() async throws {
    let producer = FakeCodexCLILiveProducer()
    let adapter = HostAgentCodexCLILiveAdapter(
        session: CodexCLILiveSessionDescriptor(
            sessionID: "desktop-live-session",
            threadID: "codex-thread-1",
            turnID: "turn-1"
        ),
        producer: producer
    )
    let bridge = HostAgentLiveSessionBridge(adapter: adapter)

    try bridge.start()
    bridge.stop()

    await producer.waitUntilStopped()
    #expect(await producer.stopCount() == 1)
}

@Test func appServerControlSocketLiveProducerResumesThreadStartsTurnAndMapsNotifications() async throws {
    let transport = RecordingCodexAppServerControlTransport()
    let producer = CodexAppServerControlSocketLiveProducer(
        transport: transport,
        clientName: "CodexPort HostAgent Test"
    )
    var events = await producer.events().makeAsyncIterator()
    let session = CodexCLILiveSessionDescriptor(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-local"
    )

    try await producer.start(session: session)

    #expect(await events.next() == .sessionOpened(session))
    #expect(await transport.requests.map(\.method) == ["initialize", "thread/resume"])
    #expect(await transport.requests[safe: 0]?.params.object?["clientInfo"]?.object?["name"]?.string == "CodexPort HostAgent Test")
    #expect(await transport.requests[safe: 0]?.params.object?["capabilities"]?.object?["experimentalApi"]?.bool == true)
    #expect(await transport.requests[safe: 1]?.params.object?["threadId"]?.string == "thread-1")

    let promptTask = Task {
        await producer.submitPrompt(CodexCLILivePrompt(writeID: "write-1", threadID: "thread-1", text: "Hi from iPhone"))
    }
    await transport.waitForRequest(method: "turn/start")
    let turnStart = await transport.requests.last
    #expect(turnStart?.method == "turn/start")
    #expect(turnStart?.params.object?["threadId"]?.string == "thread-1")
    let input = try #require(turnStart?.params.object?["input"]?.array)
    #expect(input.first?.object?["type"]?.string == "text")
    #expect(input.first?.object?["text"]?.string == "Hi from iPhone")
    #expect(input.first?.object?["text_elements"]?.array == [])
    #expect(await promptTask.value == .accepted)

    await transport.deliver(ControlJSONRPCNotification(
        method: "turn/started",
        params: .object(["turnId": .string("turn-remote")])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "item/started",
        params: .object([
            "turnId": .string("turn-remote"),
            "item": .object([
                "id": .string("item-user"),
                "type": .string("userMessage"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string("Hi from iPhone"),
                    ]),
                ]),
            ]),
        ])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "item/agentMessage/delta",
        params: .object([
            "turnId": .string("turn-remote"),
            "itemId": .string("item-agent"),
            "delta": .string("收到"),
        ])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "item/started",
        params: .object([
            "turnId": .string("turn-remote"),
            "item": .object([
                "id": .string("item-tool"),
                "type": .string("mcpToolCall"),
                "name": .string("shell"),
            ]),
        ])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "item/completed",
        params: .object([
            "turnId": .string("turn-remote"),
            "item": .object([
                "id": .string("item-tool"),
                "type": .string("mcpToolCall"),
                "result": .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("tool output"),
                        ]),
                    ]),
                ]),
            ]),
        ])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "item/completed",
        params: .object([
            "turnId": .string("turn-remote"),
            "item": .object([
                "id": .string("item-agent"),
                "type": .string("agent_message"),
                "text": .string("收到。"),
            ]),
        ])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "turn/completed",
        params: .object([
            "threadId": .string("thread-1"),
            "turn": .object([
                "id": .string("turn-remote"),
                "status": .string("completed"),
            ]),
        ])
    ))

    let mappedEvents = await collectNext(6, from: &events)
    assertProducerEvents(mappedEvents, contain: [
        .userMessage(turnID: "turn-remote", itemID: "write-1", text: "Hi from iPhone"),
        .assistantTextDelta(turnID: "turn-remote", itemID: "item-agent", text: "收到"),
        .commandOutputDelta(turnID: "turn-remote", itemID: "item-tool", text: "工具调用：shell\n"),
        .commandOutputDelta(turnID: "turn-remote", itemID: "item-tool", text: "tool output"),
        .assistantTextDelta(turnID: "turn-remote", itemID: "item-agent", text: "收到。"),
        .turnCompleted(turnID: "turn-remote"),
    ])
    #expect(mappedEvents.filter { $0 == .userMessage(turnID: "turn-remote", itemID: "write-1", text: "Hi from iPhone") }.count == 1)
}

@Test func appServerControlSocketLiveProducerIncludesLocalImageAttachmentsInTurnStartInput() async throws {
    let transport = RecordingCodexAppServerControlTransport()
    let producer = CodexAppServerControlSocketLiveProducer(transport: transport)

    try await producer.start(session: CodexCLILiveSessionDescriptor(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-local"
    ))
    let promptTask = Task {
        await producer.submitPrompt(CodexCLILivePrompt(
            writeID: "write-photo",
            threadID: "thread-1",
            text: "看这张图",
            attachments: [.localImage(path: "~/.codex-port/attachments/thread-1/123/photo.png", detail: "high")]
        ))
    }
    await transport.waitForRequest(method: "turn/start")

    let turnStart = try #require(await transport.requests.last)
    let input = try #require(turnStart.params.object?["input"]?.array)
    #expect(input.count == 2)
    #expect(input.first?.object?["type"]?.string == "text")
    #expect(input.first?.object?["text"]?.string == "看这张图")
    #expect(input[safe: 1]?.object?["type"]?.string == "localImage")
    #expect(input[safe: 1]?.object?["path"]?.string == "~/.codex-port/attachments/thread-1/123/photo.png")
    #expect(input[safe: 1]?.object?["detail"]?.string == "high")
    #expect(await promptTask.value == .accepted)
}

@Test func appServerControlSocketLiveProducerMapsCommandExecutionStartedToActualCommand() async throws {
    let transport = RecordingCodexAppServerControlTransport()
    let producer = CodexAppServerControlSocketLiveProducer(transport: transport)
    var events = await producer.events().makeAsyncIterator()

    try await producer.start(session: CodexCLILiveSessionDescriptor(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-local"
    ))

    await transport.deliver(ControlJSONRPCNotification(
        method: "item/started",
        params: .object([
            "turnId": .string("turn-remote"),
            "item": .object([
                "id": .string("cmd-1"),
                "type": .string("commandExecution"),
                "command": .string("python3 - <<'PY'"),
            ]),
        ])
    ))
    await transport.deliver(ControlJSONRPCNotification(
        method: "item/completed",
        params: .object([
            "turnId": .string("turn-remote"),
            "item": .object([
                "id": .string("cmd-1"),
                "type": .string("commandExecution"),
                "command": .string("python3 - <<'PY'"),
                "aggregatedOutput": .string("Traceback\n"),
            ]),
        ])
    ))

    let mappedEvents = await collectNext(3, from: &events)
    assertProducerEvents(mappedEvents, contain: [
        .commandOutputDelta(turnID: "turn-remote", itemID: "cmd-1", text: "$ python3 - <<'PY'\n"),
        .commandOutputDelta(turnID: "turn-remote", itemID: "cmd-1", text: "$ python3 - <<'PY'\nTraceback\n"),
    ])
}

@Test func appServerControlSocketLiveProducerRejectsPromptWhenTurnStartFails() async throws {
    let transport = RecordingCodexAppServerControlTransport()
    await transport.setResponse(method: "turn/start", result: .failure("turn rejected"))
    let producer = CodexAppServerControlSocketLiveProducer(transport: transport)

    try await producer.start(session: CodexCLILiveSessionDescriptor(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-local"
    ))

    let result = await producer.submitPrompt(CodexCLILivePrompt(
        writeID: "write-1",
        threadID: "thread-1",
        text: "PROMPT_SECRET_should_not_be_logged"
    ))

    #expect(result == .rejected(reason: "turn rejected"))
}

@Test func appServerControlSocketLiveProducerMapsDesktopUserMessageItemsWithoutPendingPrompt() async throws {
    let transport = RecordingCodexAppServerControlTransport()
    let producer = CodexAppServerControlSocketLiveProducer(transport: transport)
    var events = await producer.events().makeAsyncIterator()
    let session = CodexCLILiveSessionDescriptor(
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-local"
    )

    try await producer.start(session: session)
    #expect(await events.next() == .sessionOpened(session))

    await transport.deliver(ControlJSONRPCNotification(
        method: "item/started",
        params: .object([
            "turnId": .string("turn-from-tui"),
            "item": .object([
                "id": .string("item-user-tui"),
                "type": .string("userMessage"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string("Prompt typed in TUI"),
                    ]),
                ]),
            ]),
        ])
    ))

    #expect(await events.next() == .userMessage(
        turnID: "turn-from-tui",
        itemID: "item-user-tui",
        text: "Prompt typed in TUI"
    ))
}

private actor FakeCodexCLILiveProducer: CodexCLILiveProducing {
    private var continuation: AsyncStream<CodexCLILiveProducerEvent>.Continuation?
    private var sessions: [CodexCLILiveSessionDescriptor] = []
    private var prompts: [CodexCLILivePrompt] = []
    private var promptContinuation: CheckedContinuation<CodexCLILiveProducerWriteResult, Never>?
    private var promptSubmittedContinuation: CheckedContinuation<Void, Never>?
    private var shouldHoldStart = false
    private var startEntered = false
    private var startEnteredContinuation: CheckedContinuation<Void, Never>?
    private var startReleaseContinuation: CheckedContinuation<Void, Never>?
    private var stoppedCount = 0
    private var stoppedContinuation: CheckedContinuation<Void, Never>?

    func events() -> AsyncStream<CodexCLILiveProducerEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func start(session: CodexCLILiveSessionDescriptor) async throws {
        startEntered = true
        startEnteredContinuation?.resume()
        startEnteredContinuation = nil
        if shouldHoldStart {
            await withCheckedContinuation { continuation in
                startReleaseContinuation = continuation
            }
        }
        sessions.append(session)
        continuation?.yield(.sessionOpened(session))
    }

    func submitPrompt(_ prompt: CodexCLILivePrompt) async -> CodexCLILiveProducerWriteResult {
        prompts.append(prompt)
        promptSubmittedContinuation?.resume()
        promptSubmittedContinuation = nil
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
        }
    }

    func stop() async {
        stoppedCount += 1
        stoppedContinuation?.resume()
        stoppedContinuation = nil
        continuation?.finish()
    }

    func emit(_ event: CodexCLILiveProducerEvent) {
        continuation?.yield(event)
    }

    func completeSubmittedPrompt(_ result: CodexCLILiveProducerWriteResult) {
        promptContinuation?.resume(returning: result)
        promptContinuation = nil
    }

    func holdStart() {
        shouldHoldStart = true
    }

    func releaseStart() {
        shouldHoldStart = false
        startReleaseContinuation?.resume()
        startReleaseContinuation = nil
    }

    func waitUntilStartEntered() async {
        if startEntered {
            return
        }
        await withCheckedContinuation { continuation in
            startEnteredContinuation = continuation
        }
    }

    func waitUntilPromptSubmitted() async {
        if !prompts.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            promptSubmittedContinuation = continuation
        }
    }

    func startedSessions() -> [CodexCLILiveSessionDescriptor] {
        sessions
    }

    func submittedPrompts() -> [CodexCLILivePrompt] {
        prompts
    }

    func waitUntilStopped() async {
        if stoppedCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            stoppedContinuation = continuation
        }
    }

    func stopCount() -> Int {
        stoppedCount
    }
}

private actor RecordingCodexAppServerControlTransport: CodexAppServerControlTransporting {
    enum Response: Sendable {
        case success(ControlJSONValue)
        case failure(String)
    }

    private(set) var requests: [CodexAppServerControlRequest] = []
    private var responseByMethod: [String: Response] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var continuation: AsyncStream<ControlJSONRPCNotification>.Continuation?

    func connect() async throws {}

    func notifications() -> AsyncStream<ControlJSONRPCNotification> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func request(method: String, params: ControlJSONValue) async throws -> ControlJSONValue {
        requests.append(CodexAppServerControlRequest(method: method, params: params))
        let waiters = requestWaiters.removeValue(forKey: method) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        switch responseByMethod[method] ?? .success(.object([:])) {
        case let .success(result):
            return result
        case let .failure(reason):
            throw CodexAppServerControlProducerError.requestFailed(reason)
        }
    }

    func close() async {
        continuation?.finish()
    }

    func setResponse(method: String, result: Response) {
        responseByMethod[method] = result
    }

    func deliver(_ notification: ControlJSONRPCNotification) {
        continuation?.yield(notification)
    }

    func waitForRequest(method: String) async {
        if requests.contains(where: { $0.method == method }) {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters[method, default: []].append(continuation)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func assertProducerEvents(
    _ events: [CodexCLILiveProducerEvent],
    contain expected: [CodexCLILiveProducerEvent],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for expectedEvent in expected {
        #expect(events.contains(expectedEvent), "Missing producer event \(expectedEvent) in \(events)", sourceLocation: sourceLocation)
    }
}

private func collectNext<Event: Sendable>(
    _ count: Int,
    from iterator: inout AsyncStream<Event>.Iterator
) async -> [Event] {
    var events: [Event] = []
    for _ in 0..<count {
        if let event = await iterator.next() {
            events.append(event)
        }
    }
    return events
}

private func assertEvents(_ events: [RelayLiveSessionEvent], contain expectedEvents: [RelayLiveSessionEvent]) {
    for expectedEvent in expectedEvents {
        #expect(events.contains(expectedEvent))
    }
}
