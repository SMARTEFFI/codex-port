import Foundation
import CodexPortShared

public actor HostAgentLocalRelayOutputBuffer {
    private var lines: [String] = []

    public init() {}

    public func append(_ line: String) {
        lines.append(line)
    }

    public func snapshot() -> [String] {
        lines
    }
}

public struct HostAgentLocalRelayService: Sendable {
    private let runtime: HostAgentLocalRelayRuntime
    private let threadListProvider: HostAgentThreadListProviding
    private let threadStarter: HostAgentThreadStarting
    private let threadHistoryProvider: HostAgentThreadHistoryProviding
    private let remoteFileProvider: HostAgentRemoteFileProviding
    private let threadHistoryTimeout: Duration

    public init(
        commandFactory: @escaping HostAgentLocalRelayRuntime.CommandFactory,
        threadListProvider: HostAgentThreadListProviding = HostAgentCodexAppServerThreadListProvider(),
        threadStarter: HostAgentThreadStarting = HostAgentCodexAppServerThreadListProvider(),
        threadHistoryProvider: HostAgentThreadHistoryProviding = HostAgentCodexAppServerThreadListProvider(),
        remoteFileProvider: HostAgentRemoteFileProviding = HostAgentRemoteFileProvider(),
        threadHistoryTimeout: Duration = .seconds(8)
    ) {
        self.runtime = HostAgentLocalRelayRuntime(commandFactory: commandFactory)
        self.threadListProvider = threadListProvider
        self.threadStarter = threadStarter
        self.threadHistoryProvider = threadHistoryProvider
        self.remoteFileProvider = remoteFileProvider
        self.threadHistoryTimeout = threadHistoryTimeout
    }

    public init(
        adapterFactory: @escaping HostAgentLocalRelayRuntime.AdapterFactory,
        threadListProvider: HostAgentThreadListProviding = HostAgentCodexAppServerThreadListProvider(),
        threadStarter: HostAgentThreadStarting = HostAgentCodexAppServerThreadListProvider(),
        threadHistoryProvider: HostAgentThreadHistoryProviding = HostAgentCodexAppServerThreadListProvider(),
        remoteFileProvider: HostAgentRemoteFileProviding = HostAgentRemoteFileProvider(),
        threadHistoryTimeout: Duration = .seconds(8)
    ) {
        self.runtime = HostAgentLocalRelayRuntime(adapterFactory: adapterFactory)
        self.threadListProvider = threadListProvider
        self.threadStarter = threadStarter
        self.threadHistoryProvider = threadHistoryProvider
        self.remoteFileProvider = remoteFileProvider
        self.threadHistoryTimeout = threadHistoryTimeout
    }

    public func runScriptedSession(
        inputLines: [String],
        settleDelay: Duration = .milliseconds(25)
    ) async throws -> [String] {
        let buffer = HostAgentLocalRelayOutputBuffer()
        for line in inputLines {
            try await handleLine(line, output: { outputLine in
                await buffer.append(outputLine)
            })
        }
        try? await Task.sleep(for: settleDelay)
        await runtime.stopAll()
        return await buffer.snapshot()
    }

    public func handleLine(
        _ line: String,
        output: @escaping @Sendable (String) async -> Void
    ) async throws {
        let command = try HostAgentLocalRelayJSONLCodec.decodeCommand(from: line)
        switch command {
        case let .listThreads(clientID, requestID, limit, cursor):
            do {
                let response = try await threadListProvider.listThreads(limit: limit, cursor: cursor)
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeThreadList(
                    response.threads,
                    clientID: clientID,
                    requestID: requestID,
                    nextCursor: response.nextCursor
                )
                await output(outputLine)
            } catch {
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error), clientID: clientID)
                await output(outputLine)
            }
        case let .startThread(clientID, requestID, cwd):
            do {
                let thread = try await threadStarter.startThread(cwd: cwd)
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeThreadStarted(
                    thread,
                    clientID: clientID,
                    requestID: requestID
                )
                await output(outputLine)
            } catch {
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error), clientID: clientID)
                await output(outputLine)
            }
        case let .loadHistory(clientID, requestID, threadID, limit, cursor):
            do {
                let response = try await threadHistoryProvider.historyPage(
                    threadID: threadID,
                    limit: limit,
                    cursor: cursor
                )
                let page = RelayThreadHistoryPage(
                    requestID: requestID,
                    threadID: response.threadID,
                    items: response.items,
                    status: response.status,
                    nextCursor: response.nextCursor
                )
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeThreadHistoryPage(page, clientID: clientID)
                await output(outputLine)
            } catch {
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error), clientID: clientID)
                await output(outputLine)
            }
        case let .readFile(clientID, requestID, path, maxBytes):
            do {
                let content = try await remoteFileProvider.readFile(
                    path: path,
                    maxBytes: maxBytes,
                    requestID: requestID
                )
                let outputLine = try RelayEndpointJSONLCodec.encodeFileContent(content, clientID: clientID)
                await output(outputLine)
            } catch {
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error), clientID: clientID)
                await output(outputLine)
            }
        case let .createDirectory(clientID, requestID, path, recursive):
            do {
                try await remoteFileProvider.createDirectory(path: path, recursive: recursive)
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeFileOperationResult(
                    operation: "createDirectory",
                    requestID: requestID,
                    path: path,
                    clientID: clientID
                )
                await output(outputLine)
            } catch {
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error), clientID: clientID)
                await output(outputLine)
            }
        case let .writeFile(clientID, requestID, path, dataBase64):
            do {
                try await remoteFileProvider.writeFile(path: path, dataBase64: dataBase64)
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeFileOperationResult(
                    operation: "writeFile",
                    requestID: requestID,
                    path: path,
                    clientID: clientID
                )
                await output(outputLine)
            } catch {
                let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error), clientID: clientID)
                await output(outputLine)
            }
        case let .attach(clientID, request):
            let stream = try await runtime.attach(clientID: clientID, request: request)
            let threadHistoryProvider = self.threadHistoryProvider
            let threadHistoryTimeout = self.threadHistoryTimeout
            Task {
                guard let history = try? await Self.loadHistory(
                    threadID: request.threadID,
                    provider: threadHistoryProvider,
                    timeout: threadHistoryTimeout
                ) else { return }
                if let outputLine = try? RelayEndpointJSONLCodec.encodeThreadHistoryPage(
                    RelayThreadHistoryPage(
                        requestID: "initial",
                        threadID: history.threadID,
                        items: history.items,
                        status: history.status,
                        nextCursor: history.nextCursor
                    ),
                    clientID: clientID
                ) {
                    await output(outputLine)
                }
            }
            Task {
                for await event in stream {
                    if let outputLine = try? RelayEndpointJSONLCodec.encodeEvent(event, clientID: clientID) {
                        await output(outputLine)
                    }
                }
            }
        case let .submit(clientID, sessionID, write):
            let status = await runtime.submit(write, from: clientID, sessionID: sessionID)
            let outputLine = try RelayEndpointJSONLCodec.encodeWriteStatus(
                status,
                clientID: clientID,
                sessionID: sessionID,
                writeID: write.writeID
            )
            await output(outputLine)
        case let .detach(clientID, sessionID):
            await runtime.detach(clientID: clientID, sessionID: sessionID)
        case let .stop(sessionID):
            await runtime.stop(sessionID: sessionID)
        }
    }

    public func stopAll() async {
        await runtime.stopAll()
    }

    private static func loadHistory(
        threadID: String,
        provider: HostAgentThreadHistoryProviding,
        timeout: Duration
    ) async throws -> RelayThreadHistorySnapshot {
        try await withThrowingTaskGroup(of: RelayThreadHistorySnapshot.self) { group in
            group.addTask {
                try await provider.history(threadID: threadID)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HostAgentThreadListProviderError.timedOut(method: "thread/resume")
            }
            guard let snapshot = try await group.next() else {
                throw HostAgentThreadListProviderError.missingResponse(method: "thread/resume")
            }
            group.cancelAll()
            return snapshot
        }
    }
}
