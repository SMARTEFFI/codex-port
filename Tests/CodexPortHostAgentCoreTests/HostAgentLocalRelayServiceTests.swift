import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentLocalRelayServiceRespondsWithRealThreadListSnapshots() async throws {
    let threads = [
        RelayThreadSummarySnapshot(
            id: "thread-1",
            cwd: "/Users/chenm/Projects/codex-port",
            updatedAtUnixTime: 1_780_991_312,
            preview: "CodexPort Relay work",
            gitRepository: "git@github.com:zhxsinc/codex-port.git",
            gitBranch: "main",
            status: "completed"
        ),
    ]
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadListProvider: StubHostAgentThreadListProvider(threads: threads)
    )

    let output = try await service.runScriptedSession(inputLines: [
        #"{"type":"listThreads","clientID":"iphone-a","requestID":"request-1","limit":20}"#,
    ])

    #expect(output.count == 1)
    #expect(try RelayEndpointJSONLCodec.decodeLine(output[0]) == .threadList(
        clientID: "iphone-a",
        requestID: "request-1",
        threads: threads,
        nextCursor: nil
    ))
}

@Test func hostAgentLocalRelayServiceRunsJSONLAttachAndPromptWithoutEchoingPromptText() async throws {
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in
            HostAgentProcessCommand(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    printf 'codex:assistant:ready\\n'
                    while IFS= read -r line; do
                      printf 'codex:assistant:%s\\n' "$line"
                    done
                    """,
                ]
            )
        }
    )
    let input = [
        #"{"type":"attach","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1"}"#,
        #"{"type":"prompt","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","writeID":"write-1","text":"secret text from iphone"}"#,
    ]

    let output = try await service.runScriptedSession(inputLines: input, settleDelay: .milliseconds(50))
    let decoded = try output.map(RelayEndpointJSONLCodec.decodeLine)

    #expect(output.contains { $0.contains(#""event":"sessionStarted""#) })
    #expect(decoded.contains { $0 == .event(clientID: "iphone-a", .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "ready")) })
    #expect(output.contains { $0.contains(#""type":"writeStatus""#) && $0.contains(#""status":"handled""#) })
    #expect(output.contains { $0.contains(#""event":"writeStatusChanged""#) && $0.contains(#""status":"handled""#) })
    #expect(decoded.contains { $0 == .event(clientID: "iphone-a", .assistantTextDelta(turnID: "turn-1", itemID: "process-assistant", text: "secret text from iphone")) })
    #expect(decoded.map(\.telemetryDescription).allSatisfy { !$0.contains("secret text from iphone") })
}

@Test func hostAgentLocalRelayServiceSendsExistingThreadHistoryBeforeLiveAttachEvents() async throws {
    let history = RelayThreadHistorySnapshot(
        threadID: "thread-1",
        items: [
            .userMessage("桌面端已有问题"),
            .assistantMessage("桌面端已有回答"),
        ],
        status: .completed
    )
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in
            HostAgentProcessCommand(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf 'codex:assistant:live ready\\n'; sleep 0.05"]
            )
        },
        threadListProvider: StubHostAgentThreadListProvider(threads: []),
        threadHistoryProvider: StubHostAgentThreadHistoryProvider(history: history)
    )

    let output = try await service.runScriptedSession(inputLines: [
        #"{"type":"attach","clientID":"iphone-a","sessionID":"thread-1","threadID":"thread-1","turnID":"thread-1-turn"}"#,
    ], settleDelay: .milliseconds(80))
    let decoded = try output.map(RelayEndpointJSONLCodec.decodeLine)

    #expect(decoded.contains { $0 == .threadHistoryPage(clientID: "iphone-a", RelayThreadHistoryPage(
        requestID: "initial",
        threadID: "thread-1",
        items: history.items,
        status: .completed,
        nextCursor: nil
    )) })
    #expect(decoded.contains { $0 == .event(clientID: "iphone-a", .assistantTextDelta(turnID: "thread-1-turn", itemID: "process-assistant", text: "live ready")) })
}

@Test func hostAgentLocalRelayServiceRespondsWithCursorThreadHistoryPages() async throws {
    let provider = RecordingHostAgentThreadHistoryProvider(pages: [
        RelayThreadHistoryPage(
            requestID: "provider-placeholder",
            threadID: "thread-1",
            items: [
                .userMessage("older question"),
                .assistantMessage("older answer"),
            ],
            status: .completed,
            nextCursor: "older-cursor-2"
        ),
    ])
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") },
        threadHistoryProvider: provider
    )

    let output = try await service.runScriptedSession(inputLines: [
        #"{"type":"loadHistory","clientID":"iphone-a","requestID":"history-request-1","threadID":"thread-1","limit":10,"cursor":"older-cursor-1"}"#,
    ])
    let decoded = try output.map(RelayEndpointJSONLCodec.decodeLine)

    #expect(provider.requests == [
        .init(threadID: "thread-1", limit: 10, cursor: "older-cursor-1")
    ])
    #expect(decoded == [
        .threadHistoryPage(clientID: "iphone-a", RelayThreadHistoryPage(
            requestID: "history-request-1",
            threadID: "thread-1",
            items: [
                .userMessage("older question"),
                .assistantMessage("older answer"),
            ],
            status: .completed,
            nextCursor: "older-cursor-2"
        ))
    ])
}

@Test func hostAgentLocalRelayServiceReadsAuthorizedLocalFileBytes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexport-host-agent-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("screen.png")
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    try data.write(to: fileURL)
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
    )

    let output = try await service.runScriptedSession(inputLines: [
        #"{"type":"readFile","clientID":"iphone-a","requestID":"file-1","path":"\#(fileURL.path)","maxBytes":10}"#,
    ])
    let decoded = try output.map(RelayEndpointJSONLCodec.decodeLine)

    #expect(decoded == [
        .fileContent(clientID: "iphone-a", RelayRemoteFileContent(
            requestID: "file-1",
            path: fileURL.path,
            contentType: "image/png",
            byteCount: data.count,
            dataBase64: data.base64EncodedString()
        ))
    ])
}

@Test func hostAgentLocalRelayServiceWritesUploadedAttachmentBytes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexport-host-agent-upload-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("photo.png")
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in HostAgentProcessCommand(executablePath: "/bin/false") }
    )

    let output = try await service.runScriptedSession(inputLines: [
        #"{"type":"createDirectory","clientID":"iphone-a","requestID":"mkdir-1","path":"\#(directory.path)","recursive":true}"#,
        #"{"type":"writeFile","clientID":"iphone-a","requestID":"write-1","path":"\#(fileURL.path)","dataBase64":"\#(data.base64EncodedString())"}"#,
    ])
    let decoded = try output.map(RelayEndpointJSONLCodec.decodeLine)

    #expect(try Data(contentsOf: fileURL) == data)
    #expect(decoded == [
        .fileOperationResult(clientID: "iphone-a", operation: "createDirectory", requestID: "mkdir-1", path: directory.path),
        .fileOperationResult(clientID: "iphone-a", operation: "writeFile", requestID: "write-1", path: fileURL.path),
    ])
}

@Test func hostAgentLocalRelayServiceDoesNotBlockAttachWhenHistoryProviderHangs() async throws {
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in
            HostAgentProcessCommand(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf 'codex:assistant:live ready\\n'; sleep 0.05"]
            )
        },
        threadListProvider: StubHostAgentThreadListProvider(threads: []),
        threadHistoryProvider: HangingHostAgentThreadHistoryProvider()
    )
    let output = HostAgentLocalRelayOutputBuffer()

    let attachTask = Task {
        try await service.handleLine(
            #"{"type":"attach","clientID":"iphone-a","sessionID":"thread-1","threadID":"thread-1","turnID":"thread-1-turn"}"#
        ) { line in
            await output.append(line)
        }
    }
    try await Task.sleep(for: .milliseconds(200))
    attachTask.cancel()
    await service.stopAll()
    let decoded = try await output.snapshot().map(RelayEndpointJSONLCodec.decodeLine)

    #expect(decoded.contains { $0 == .event(clientID: "iphone-a", .sessionStarted(sessionID: "thread-1", threadID: "thread-1", turnID: "thread-1-turn")) })
    #expect(decoded.contains { $0 == .event(clientID: "iphone-a", .assistantTextDelta(turnID: "thread-1-turn", itemID: "process-assistant", text: "live ready")) })
}

@Test func hostAgentCodexAppServerThreadHistoryProviderRequestsExperimentalResumeHistory() throws {
    let params = HostAgentCodexAppServerThreadListProvider.initializeParams()
    let capabilities = try #require(params["capabilities"] as? [String: Any])

    #expect(capabilities["experimentalApi"] as? Bool == true)
}

@Test func hostAgentCodexAppServerThreadHistoryProviderRequestsTenRecentTurns() async throws {
    let transport = CapturingHostAgentJSONRPCTransport()
    _ = try await HostAgentCodexAppServerThreadListProvider.loadHistorySnapshot(
        threadID: "thread-1",
        transport: transport,
        timeout: .seconds(1)
    )

    let resumeRequest = try #require(transport.requests.first { $0.method == "thread/resume" })
    let initialTurnsPage = try #require(resumeRequest.params["initialTurnsPage"] as? [String: Any])
    #expect(initialTurnsPage["limit"] as? Int == 10)
    #expect(initialTurnsPage["sortDirection"] as? String == "desc")
    #expect(initialTurnsPage["itemsView"] as? String == "full")
    #expect(resumeRequest.params["excludeTurns"] as? Bool == true)
}

@Test func hostAgentCodexAppServerThreadHistoryProviderMapsOfficialHistoryItems() throws {
    let snapshot = HostAgentCodexAppServerThreadListProvider.historySnapshot(
        from: [
            "result": [
                "initialTurnsPage": [
                    "data": [
                        [
                            "status": "completed",
                            "items": [
                                [
                                    "type": "userMessage",
                                    "content": [
                                        ["type": "text", "text": "用户问题"],
                                    ],
                                ],
                                [
                                    "type": "agentMessage",
                                    "text": "助手回答",
                                ],
                                [
                                    "type": "mcpToolCall",
                                    "result": [
                                        "content": [
                                            ["type": "text", "text": "工具输出"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
        fallbackThreadID: "thread-1"
    )

    #expect(snapshot.items == [
        .userMessage("用户问题"),
        .assistantMessage("助手回答"),
        .commandOutput("工具输出"),
    ])
}

@Test func hostAgentCodexAppServerThreadHistoryProviderCapsLargeCommandHistoryPayloads() throws {
    let largeOutput = String(repeating: "x", count: 30_000)
    let snapshot = HostAgentCodexAppServerThreadListProvider.historySnapshot(
        from: [
            "result": [
                "initialTurnsPage": [
                    "data": [
                        [
                            "status": "completed",
                            "items": [
                                [
                                    "type": "userMessage",
                                    "content": [
                                        ["type": "text", "text": "用户问题"],
                                    ],
                                ],
                                [
                                    "type": "mcpToolCall",
                                    "result": [
                                        "content": [
                                            ["type": "text", "text": largeOutput],
                                        ],
                                    ],
                                ],
                                [
                                    "type": "agentMessage",
                                    "text": "助手回答",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
        fallbackThreadID: "thread-1"
    )

    #expect(snapshot.items.count == 3)
    guard case let .commandOutput(commandOutput) = snapshot.items[1] else {
        Issue.record("Expected command output history item")
        return
    }
    #expect(commandOutput.utf8.count < 512)
    #expect(commandOutput.contains("output truncated"))
    #expect(snapshot.items.first == .userMessage("用户问题"))
    #expect(snapshot.items.last == .assistantMessage("助手回答"))
}

@Test func hostAgentCodexAppServerThreadHistoryProviderKeepsEncodedHistoryUnderRelayFrameBudget() throws {
    let noisyHistory = (0..<80).flatMap { index -> [[String: Any]] in
        [
            [
                "type": "userMessage",
                "text": "用户消息 \(index)",
            ],
            [
                "type": "mcpToolCall",
                "result": [
                    "content": [
                        ["type": "text", "text": String(repeating: "tool-output-\(index)", count: 1_000)],
                    ],
                ],
            ],
            [
                "type": "agentMessage",
                "text": "助手回答 \(index)",
            ],
        ]
    }
    let snapshot = HostAgentCodexAppServerThreadListProvider.historySnapshot(
        from: [
            "result": [
                "initialTurnsPage": [
                    "data": [
                        [
                            "status": "completed",
                            "items": noisyHistory,
                        ],
                    ],
                ],
            ],
        ],
        fallbackThreadID: "thread-1"
    )
    let line = try RelayEndpointJSONLCodec.encodeEvent(
        .threadHistoryLoaded(threadID: snapshot.threadID, items: snapshot.items, status: snapshot.status),
        clientID: "iphone-a"
    )

    #expect(line.utf8.count <= 48 * 1024)
    #expect(snapshot.items.contains(.userMessage("用户消息 79")))
    #expect(snapshot.items.contains(.assistantMessage("助手回答 79")))
}

@Test func hostAgentLocalRelayServiceCleanStopDoesNotReportTurnFailed() async throws {
    let service = HostAgentLocalRelayService(
        commandFactory: { _ in
            HostAgentProcessCommand(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    printf 'codex:assistant:ready\\n'
                    while IFS= read -r line; do
                      printf 'codex:assistant:%s\\n' "$line"
                    done
                    """,
                ]
            )
        }
    )
    let input = [
        #"{"type":"attach","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1"}"#,
        #"{"type":"prompt","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","writeID":"write-1","text":"shutdown check"}"#,
    ]

    let output = try await service.runScriptedSession(inputLines: input, settleDelay: .milliseconds(50))

    #expect(!output.contains { $0.contains(#""event":"turnFailed""#) })
}

@Test func hostAgentLocalRelayServiceCanUseCodexCLILiveControlSocketProducer() async throws {
    let transport = RecordingHostAgentControlTransport()
    let service = HostAgentLocalRelayService(
        adapterFactory: { request in
            AnyHostAgentLiveSessionAdapter(
                HostAgentCodexCLILiveAdapter(
                    session: CodexCLILiveSessionDescriptor(
                        sessionID: request.sessionID,
                        threadID: request.threadID,
                        turnID: request.turnID
                    ),
                    producer: CodexAppServerControlSocketLiveProducer(transport: transport)
                ),
                description: "Codex CLI live adapter"
            )
        },
        threadHistoryProvider: StubHostAgentThreadHistoryProvider(history: RelayThreadHistorySnapshot(
            threadID: "thread-1",
            items: [],
            status: .completed
        ))
    )
    let output = HostAgentLocalRelayOutputBuffer()

    try await service.handleLine(
        #"{"type":"attach","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1"}"#
    ) { line in
        await output.append(line)
    }
    let promptTask = Task {
        try await service.handleLine(
            #"{"type":"prompt","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","writeID":"write-1","text":"live prompt"}"#
        ) { line in
            await output.append(line)
        }
    }
    await transport.waitForRequest(method: "turn/start")
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
                        "text": .string("live prompt"),
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
        method: "turn/completed",
        params: .object(["turnId": .string("turn-remote")])
    ))
    try await promptTask.value
    try await Task.sleep(for: .milliseconds(25))
    await service.stopAll()

    let lines = await output.snapshot()
    #expect(await transport.requests.map(\.method) == ["initialize", "thread/resume", "turn/start"])
    let turnStartParams = try #require(await transport.requests.last?.params.object)
    #expect(turnStartParams["threadId"]?.string == "thread-1")
    let input = try #require(turnStartParams["input"]?.array)
    #expect(input.first?.object?["text"]?.string == "live prompt")
    #expect(lines.contains { $0.contains(#""event":"sessionStarted""#) })
    #expect(lines.contains { $0.contains(#""type":"writeStatus""#) && $0.contains(#""status":"handled""#) })
    #expect(lines.contains { $0.contains(#""event":"writeStatusChanged""#) && $0.contains(#""status":"queued""#) })
    #expect(lines.contains { $0.contains(#""event":"writeStatusChanged""#) && $0.contains(#""status":"running""#) })
    #expect(lines.contains { $0.contains(#""event":"writeStatusChanged""#) && $0.contains(#""status":"handled""#) })
    #expect(lines.contains { $0.contains(#""event":"userMessage""#) && $0.contains(#""text":"live prompt""#) })
    #expect(lines.contains { $0.contains(#""event":"assistantTextDelta""#) && $0.contains(#""turnID":"turn-remote""#) })
    #expect(lines.contains { $0.contains(#""event":"turnCompleted""#) && $0.contains(#""turnID":"turn-remote""#) })
}

private struct StubHostAgentThreadListProvider: HostAgentThreadListProviding {
    var threads: [RelayThreadSummarySnapshot]

    func listThreads(limit: Int, cursor: String?) async throws -> RelayThreadListResponse {
        RelayThreadListResponse(threads: Array(threads.prefix(limit)))
    }
}

private actor RecordingHostAgentControlTransport: CodexAppServerControlTransporting {
    private(set) var requests: [CodexAppServerControlRequest] = []
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
        return .object([:])
    }

    func close() async {
        continuation?.finish()
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

private struct StubHostAgentThreadHistoryProvider: HostAgentThreadHistoryProviding {
    var history: RelayThreadHistorySnapshot

    func history(threadID: String) async throws -> RelayThreadHistorySnapshot {
        history
    }
}

private struct HangingHostAgentThreadHistoryProvider: HostAgentThreadHistoryProviding {
    func history(threadID: String) async throws -> RelayThreadHistorySnapshot {
        try await Task.sleep(for: .seconds(60))
        return RelayThreadHistorySnapshot(threadID: threadID, items: [], status: .completed)
    }
}

private final class RecordingHostAgentThreadHistoryProvider: HostAgentThreadHistoryProviding, @unchecked Sendable {
    struct Request: Equatable {
        var threadID: String
        var limit: Int
        var cursor: String?
    }

    private var pages: [RelayThreadHistoryPage]
    private(set) var requests: [Request] = []

    init(pages: [RelayThreadHistoryPage]) {
        self.pages = pages
    }

    func history(threadID: String) async throws -> RelayThreadHistorySnapshot {
        RelayThreadHistorySnapshot(threadID: threadID, items: [], status: .completed)
    }

    func historyPage(threadID: String, limit: Int, cursor: String?) async throws -> RelayThreadHistoryPage {
        requests.append(Request(threadID: threadID, limit: limit, cursor: cursor))
        var page = pages.removeFirst()
        page.threadID = threadID
        return page
    }
}

private final class CapturingHostAgentJSONRPCTransport: HostAgentAppServerJSONRPCTransporting, @unchecked Sendable {
    struct Request {
        var id: Int
        var method: String
        var params: [String: Any]
    }

    private(set) var requests: [Request] = []

    func sendNotification(method: String, params: [String: Any]) throws {}

    func request(id: Int, method: String, params: [String: Any], timeout: Duration) async throws -> [String: Any] {
        requests.append(Request(id: id, method: method, params: params))
        switch method {
        case "thread/resume":
            return [
                "result": [
                    "thread": ["id": params["threadId"] as? String ?? ""],
                    "initialTurnsPage": ["data": []],
                ],
            ]
        default:
            return ["result": [:]]
        }
    }
}
