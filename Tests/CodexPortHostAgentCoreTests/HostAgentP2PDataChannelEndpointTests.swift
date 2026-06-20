import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentP2PDataChannelEndpointRoutesThreadListOverSplitFrame() async throws {
    let thread = RelayThreadSummarySnapshot(
        id: "thread-1",
        cwd: "/Users/chenm/Projects/codex-port",
        updatedAtUnixTime: 1_780_991_312,
        preview: "HostAgent P2P session summary",
        gitRepository: "git@github.com:zhxsinc/codex-port.git",
        gitBranch: "main",
        status: "completed"
    )
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadListProvider: P2PStubHostAgentThreadListProvider(threads: [thread])
    )
    let dataChannel = RecordingHostAgentP2PDataChannelTransport()
    let endpoint = HostAgentP2PDataChannelEndpoint(dataChannel: dataChannel, service: service)
    endpoint.start()

    let command = #"{"type":"listThreads","clientID":"iphone-a","requestID":"list-1","limit":1}"# + "\n"
    let splitIndex = command.index(command.startIndex, offsetBy: command.count / 2)
    await dataChannel.deliver(Data(command[..<splitIndex].utf8))
    await dataChannel.deliver(Data(command[splitIndex...].utf8))

    let line = try await dataChannel.waitForSentLine(containing: #""type":"threadList""#)
    endpoint.stop()

    #expect(try RelayEndpointJSONLCodec.decodeLine(line) == .threadList(
        clientID: "iphone-a",
        requestID: "list-1",
        threads: [thread],
        nextCursor: nil
    ))
}

@Test func hostAgentP2PDataChannelEndpointStreamsPromptStatusAndLiveDeltasOverSameChannel() async throws {
    let producer = ScriptedCodexCLILiveProducer()
    let diagnostics = HostAgentP2PDataChannelEndpointDiagnostics()
    let service = HostAgentLocalRelayService(
        adapterFactory: { request in
            AnyHostAgentLiveSessionAdapter(
                HostAgentCodexCLILiveAdapter(
                    session: CodexCLILiveSessionDescriptor(
                        sessionID: request.sessionID,
                        threadID: request.threadID,
                        turnID: request.turnID
                    ),
                    producer: producer
                ),
                description: "scripted p2p codex cli live adapter"
            )
        },
        threadHistoryProvider: P2PStubHostAgentThreadHistoryProvider(history: RelayThreadHistorySnapshot(
            threadID: "thread-1",
            items: [],
            status: .completed
        ))
    )
    let dataChannel = RecordingHostAgentP2PDataChannelTransport()
    let endpoint = HostAgentP2PDataChannelEndpoint(
        dataChannel: dataChannel,
        service: service,
        onEvent: { event in
            await diagnostics.record(event)
        }
    )
    endpoint.start()

    let attachLine = #"{"type":"attach","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-local"}"#
    let promptLine = #"{"type":"prompt","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","writeID":"write-1","text":"hello live tui"}"#
    await dataChannel.deliver(Data((attachLine + "\n" + promptLine + "\n").utf8))
    await producer.waitForPrompt("hello live tui")
    await producer.emit(.assistantTextDelta(turnID: "turn-remote", itemID: "assistant-1", text: "streamed before completion"))
    await producer.emit(.turnCompleted(turnID: "turn-remote"))

    _ = try await dataChannel.waitForSentLine(containing: #""event":"sessionStarted""#)
    _ = try await dataChannel.waitForSentLine(containing: #""type":"threadHistoryPage""#)
    let writeStatusLine = try await dataChannel.waitForSentLine(containing: #""type":"writeStatus","#)
    _ = try await dataChannel.waitForSentLine(containing: #""event":"writeStatusChanged","status":"queued""#)
    _ = try await dataChannel.waitForSentLine(containing: #""event":"writeStatusChanged","status":"running""#)
    let assistantLine = try await dataChannel.waitForSentLine(containing: #""event":"assistantTextDelta""#)
    let turnCompletedLine = try await dataChannel.waitForSentLine(containing: #""event":"turnCompleted""#)
    let handledEventLine = try await dataChannel.waitForSentLine(containing: #""event":"writeStatusChanged","status":"handled""#)
    endpoint.stop()

    #expect(try RelayEndpointJSONLCodec.decodeLine(assistantLine) == .event(
        clientID: "iphone-a",
        .assistantTextDelta(turnID: "turn-remote", itemID: "assistant-1", text: "streamed before completion")
    ))
    #expect(await producer.prompts == [
        CodexCLILivePrompt(writeID: "write-1", threadID: "thread-1", text: "hello live tui")
    ])
    #expect(await diagnostics.events.contains(.commandReceived(HostAgentLocalRelayCommandDiagnosticSummary(
        type: "prompt",
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        writeID: "write-1",
        inputBytes: promptLine.utf8.count
    ))))
    #expect(await diagnostics.events.contains(.commandOutput(HostAgentLocalRelayOutputDiagnosticSummary(
        type: "writeStatus",
        clientID: "iphone-a",
        sessionID: "session-1",
        writeID: "write-1",
        status: "handled",
        outputBytes: writeStatusLine.utf8.count
    ))))
    #expect(await diagnostics.events.contains(.commandOutput(HostAgentLocalRelayOutputDiagnosticSummary(
        type: "event",
        event: "assistantTextDelta",
        clientID: "iphone-a",
        turnID: "turn-remote",
        itemID: "assistant-1",
        outputBytes: assistantLine.utf8.count
    ))))
    #expect(await diagnostics.events.contains(.commandOutput(HostAgentLocalRelayOutputDiagnosticSummary(
        type: "event",
        event: "turnCompleted",
        clientID: "iphone-a",
        turnID: "turn-remote",
        outputBytes: turnCompletedLine.utf8.count
    ))))
    #expect(await diagnostics.events.contains(.commandOutput(HostAgentLocalRelayOutputDiagnosticSummary(
        type: "event",
        event: "writeStatusChanged",
        clientID: "iphone-a",
        writeID: "write-1",
        status: "handled",
        outputBytes: handledEventLine.utf8.count
    ))))
    let diagnosticLogs = await diagnostics.logDescriptions().joined(separator: "\n")
    #expect(diagnosticLogs.contains("event=assistantTextDelta"))
    #expect(diagnosticLogs.contains("event=turnCompleted"))
    #expect(diagnosticLogs.contains("event=writeStatusChanged"))
    #expect(diagnosticLogs.contains("turn=turn-remote"))
    #expect(diagnosticLogs.contains("item=assistant-1"))
    #expect(diagnosticLogs.contains("write=write-1"))
    #expect(diagnosticLogs.contains("status=handled"))
    #expect(!diagnosticLogs.contains("hello live tui"))
    #expect(!diagnosticLogs.contains("streamed before completion"))
}

@Test func hostAgentP2PDataChannelEndpointReturnsSanitizedErrorForInvalidJSONLCommand() async throws {
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
    )
    let dataChannel = RecordingHostAgentP2PDataChannelTransport()
    let endpoint = HostAgentP2PDataChannelEndpoint(dataChannel: dataChannel, service: service)
    endpoint.start()

    await dataChannel.deliver(Data("not-json\n".utf8))

    let line = try await dataChannel.waitForSentLine(containing: #""type":"error""#)
    endpoint.stop()

    #expect(line.contains(#""reasonBytes":"#))
    #expect(!line.contains("not-json"))
}

@Test func hostAgentP2PDataChannelEndpointRepliesToHealthPingWithoutCommandHandling() async throws {
    let diagnostics = HostAgentP2PDataChannelEndpointDiagnostics()
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
    )
    let dataChannel = RecordingHostAgentP2PDataChannelTransport()
    let endpoint = HostAgentP2PDataChannelEndpoint(
        dataChannel: dataChannel,
        service: service,
        onEvent: { event in
            await diagnostics.record(event)
        }
    )
    endpoint.start()

    await dataChannel.deliver(Data((try WebRTCDataChannelHealthCheck.pingLine(nonce: "probe-1") + "\n").utf8))

    let line = try await dataChannel.waitForSentLine(containing: WebRTCDataChannelHealthCheck.pongType)
    endpoint.stop()

    #expect(WebRTCDataChannelHealthCheck.decodeLine(line) == .pong(nonce: "probe-1"))
    #expect(await diagnostics.events.isEmpty)
}

private struct P2PStubHostAgentThreadListProvider: HostAgentThreadListProviding {
    var threads: [RelayThreadSummarySnapshot]

    func listThreads(limit: Int, cursor: String?) async throws -> RelayThreadListResponse {
        RelayThreadListResponse(threads: Array(threads.prefix(limit)))
    }
}

private struct P2PStubHostAgentThreadHistoryProvider: HostAgentThreadHistoryProviding {
    var history: RelayThreadHistorySnapshot

    func history(threadID: String) async throws -> RelayThreadHistorySnapshot {
        history
    }
}

private actor ScriptedCodexCLILiveProducer: CodexCLILiveProducing {
    private var promptsStorage: [CodexCLILivePrompt] = []
    private var promptWaiters: [(String, CheckedContinuation<Void, Never>)] = []
    private var continuation: AsyncStream<CodexCLILiveProducerEvent>.Continuation?
    private var session: CodexCLILiveSessionDescriptor?

    var prompts: [CodexCLILivePrompt] {
        promptsStorage
    }

    func events() async -> AsyncStream<CodexCLILiveProducerEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func start(session: CodexCLILiveSessionDescriptor) async throws {
        self.session = session
        continuation?.yield(.sessionOpened(session))
    }

    func submitPrompt(_ prompt: CodexCLILivePrompt) async -> CodexCLILiveProducerWriteResult {
        promptsStorage.append(prompt)
        let matchingWaiters = promptWaiters.filter { $0.0 == prompt.text }
        promptWaiters.removeAll { $0.0 == prompt.text }
        for waiter in matchingWaiters {
            waiter.1.resume()
        }
        return .accepted
    }

    func stop() async {
        continuation?.finish()
    }

    func emit(_ event: CodexCLILiveProducerEvent) {
        continuation?.yield(event)
    }

    func waitForPrompt(_ text: String) async {
        if promptsStorage.contains(where: { $0.text == text }) {
            return
        }
        await withCheckedContinuation { continuation in
            promptWaiters.append((text, continuation))
        }
    }
}

private actor HostAgentP2PDataChannelEndpointDiagnostics {
    private var storage: [HostAgentP2PDataChannelEndpointEvent] = []

    var events: [HostAgentP2PDataChannelEndpointEvent] {
        storage
    }

    func record(_ event: HostAgentP2PDataChannelEndpointEvent) {
        storage.append(event)
    }

    func logDescriptions() -> [String] {
        storage.map { event in
            switch event {
            case let .commandReceived(summary):
                return summary.logDescription
            case let .commandOutput(summary):
                return summary.logDescription
            case let .commandFailed(inputBytes, reason):
                return "bytes=\(inputBytes) reasonBytes=\(reason.utf8.count)"
            }
        }
    }
}

private actor RecordingHostAgentP2PDataChannelTransport: WebRTCDataChannelTransport {
    nonisolated let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    nonisolated let incomingMessages: AsyncStream<Data>
    nonisolated let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>

    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private var sentLines: [String] = []
    private var sentBuffer = Data()
    private var lineWaiters: [(String, CheckedContinuation<String, Never>)] = []

    init() {
        var capturedIncoming: AsyncStream<Data>.Continuation?
        var capturedState: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        incomingMessages = AsyncStream { continuation in
            capturedIncoming = continuation
        }
        stateUpdates = AsyncStream { continuation in
            capturedState = continuation
        }
        incomingContinuation = capturedIncoming!
        stateContinuation = capturedState!
    }

    deinit {
        incomingContinuation.finish()
        stateContinuation.finish()
    }

    func send(_ message: Data) async throws {
        sentBuffer.append(message)
        let lines = drainCompleteLines()
        for line in lines {
            sentLines.append(line)
            resumeMatchingWaiters(for: line)
        }
    }

    func deliver(_ message: Data) {
        incomingContinuation.yield(message)
    }

    func waitForSentLine(containing needle: String) async throws -> String {
        if let line = sentLines.first(where: { $0.contains(needle) }) {
            return line
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Task {
                        await self.appendWaiter(needle: needle, continuation: continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw HostAgentP2PDataChannelEndpointTestError.timedOutWaitingForLine(needle)
            }
            guard let line = try await group.next() else {
                throw HostAgentP2PDataChannelEndpointTestError.timedOutWaitingForLine(needle)
            }
            group.cancelAll()
            return line
        }
    }

    private func appendWaiter(needle: String, continuation: CheckedContinuation<String, Never>) {
        if let line = sentLines.first(where: { $0.contains(needle) }) {
            continuation.resume(returning: line)
            return
        }
        lineWaiters.append((needle, continuation))
    }

    private func resumeMatchingWaiters(for line: String) {
        var remaining: [(String, CheckedContinuation<String, Never>)] = []
        for waiter in lineWaiters {
            if line.contains(waiter.0) {
                waiter.1.resume(returning: line)
            } else {
                remaining.append(waiter)
            }
        }
        lineWaiters = remaining
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = sentBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = sentBuffer[..<newlineIndex]
            sentBuffer.removeSubrange(...newlineIndex)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }
}

private enum HostAgentP2PDataChannelEndpointTestError: Error, CustomStringConvertible {
    case timedOutWaitingForLine(String)

    var description: String {
        switch self {
        case let .timedOutWaitingForLine(needle):
            "Timed out waiting for DataChannel line containing \(needle)"
        }
    }
}
