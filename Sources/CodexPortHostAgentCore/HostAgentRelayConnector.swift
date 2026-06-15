import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol HostAgentRelayWebSocketTask: AnyObject, Sendable {
    var receivedStrings: AsyncStream<String> { get }
    func resume()
    func sendString(_ string: String) async throws
    func sendPing() async throws
    func cancel()
}

public final class HostAgentRelayConnector: @unchecked Sendable {
    public typealias TaskFactory = @Sendable (_ request: URLRequest) -> HostAgentRelayWebSocketTask

    private let host: RelayHostIdentity
    private let endpointURL: URL
    private let service: HostAgentLocalRelayService
    private let makeTask: TaskFactory
    private let reconnectDelay: Duration
    private let heartbeatInterval: Duration
    private let heartbeatTimeout: Duration
    private let lock = NSLock()
    private var task: HostAgentRelayWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var handlerTasks: [Task<Void, Never>] = []
    private var isStopped = false

    public convenience init(
        host: RelayHostIdentity,
        endpointURL: URL,
        service: HostAgentLocalRelayService
    ) {
        self.init(host: host, endpointURL: endpointURL, service: service, reconnectDelay: .seconds(2)) { request in
            URLSessionHostAgentRelayWebSocketTask(request: request)
        }
    }

    public init(
        host: RelayHostIdentity,
        endpointURL: URL,
        service: HostAgentLocalRelayService,
        reconnectDelay: Duration = .seconds(2),
        heartbeatInterval: Duration = .seconds(20),
        heartbeatTimeout: Duration = .seconds(10),
        makeTask: @escaping TaskFactory
    ) {
        self.host = host
        self.endpointURL = endpointURL
        self.service = service
        self.makeTask = makeTask
        self.reconnectDelay = reconnectDelay
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
    }

    deinit {
        stop()
    }

    public func connect() {
        openConnection(markRunning: true)
    }

    private func connectAfterReconnectDelay() {
        openConnection(markRunning: false)
    }

    private func openConnection(markRunning: Bool) {
        lock.withLock {
            if markRunning {
                isStopped = false
            } else {
                guard !isStopped else { return }
            }
            guard task == nil else { return }
            var request = URLRequest(url: endpointURL)
            RelayHostConnectWebSocketCodec.encode(host: host, supportedVersions: [.v0_2_0], into: &request)
            let task = makeTask(request)
            self.task = task
            task.resume()
            let receivedStrings = task.receivedStrings
            receiveTask = Task { [weak self] in
                for await string in receivedStrings {
                    await self?.receive(string, from: task)
                }
                await self?.scheduleReconnectIfNeeded(finishedTask: task)
            }
            heartbeatTask = Task { [weak self] in
                await self?.runHeartbeat(for: task)
            }
        }
    }

    public func stop() {
        let task = lock.withLock {
            isStopped = true
            let task = self.task
            self.task = nil
            receiveTask?.cancel()
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            let handlerTasks = self.handlerTasks
            self.handlerTasks = []
            return (task, handlerTasks)
        }
        for handlerTask in task.1 {
            handlerTask.cancel()
        }
        task.0?.cancel()
    }

    private func receive(_ string: String, from currentTask: HostAgentRelayWebSocketTask) async {
        for line in completedLines(from: string) {
            guard let envelope = try? RelayHostBridgeEnvelope.decode(line) else { continue }
            let handlerTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                try? await service.handleLine(envelope.line) { [weak self] outputLine in
                    do {
                        try await self?.send(RelayHostBridgeEnvelope(
                            streamID: envelope.streamID,
                            clientID: envelope.clientID,
                            line: outputLine
                        ), using: currentTask)
                    } catch {
                        await self?.reconnectAfterFailure(failedTask: currentTask)
                    }
                }
            }
            lock.withLock {
                handlerTasks.append(handlerTask)
            }
        }
    }

    private func scheduleReconnectIfNeeded(finishedTask: HostAgentRelayWebSocketTask) async {
        guard disconnect(finishedTask) != nil else { return }
        scheduleReconnectAfterDelay()
    }

    private func reconnectAfterFailure(failedTask: HostAgentRelayWebSocketTask) async {
        guard let failedTask = disconnect(failedTask) else { return }
        failedTask.cancel()
        scheduleReconnectAfterDelay()
    }

    private func scheduleReconnectAfterDelay() {
        let reconnectDelay = self.reconnectDelay
        Task { [weak self] in
            try? await Task.sleep(for: reconnectDelay)
            guard !Task.isCancelled else { return }
            self?.connectAfterReconnectDelay()
        }
    }

    private func disconnect(_ finishedTask: HostAgentRelayWebSocketTask) -> HostAgentRelayWebSocketTask? {
        lock.withLock {
            guard !isStopped, task === finishedTask else { return nil }
            task = nil
            receiveTask?.cancel()
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            for handlerTask in handlerTasks {
                handlerTask.cancel()
            }
            handlerTasks = []
            return finishedTask
        }
    }

    private func send(_ envelope: RelayHostBridgeEnvelope, using currentTask: HostAgentRelayWebSocketTask) async throws {
        guard lock.withLock({ self.task === currentTask }) else { return }
        try await currentTask.sendString(try RelayHostBridgeEnvelope.encode(envelope) + "\n")
    }

    private func runHeartbeat(for currentTask: HostAgentRelayWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: heartbeatInterval)
            guard !Task.isCancelled else { return }
            do {
                try await ping(currentTask)
            } catch {
                await reconnectAfterFailure(failedTask: currentTask)
                return
            }
        }
    }

    private func ping(_ currentTask: HostAgentRelayWebSocketTask) async throws {
        guard lock.withLock({ self.task === currentTask && !self.isStopped }) else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await currentTask.sendPing()
            }
            group.addTask { [heartbeatTimeout] in
                try await Task.sleep(for: heartbeatTimeout)
                throw HostAgentRelayConnectorError.heartbeatTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func completedLines(from string: String) -> [String] {
        string.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
    }
}

private enum HostAgentRelayConnectorError: Error {
    case heartbeatTimedOut
}

private final class URLSessionHostAgentRelayWebSocketTask: HostAgentRelayWebSocketTask, @unchecked Sendable {
    let receivedStrings: AsyncStream<String>

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncStream<String>.Continuation
    private var receiveTask: Task<Void, Never>?

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        var capturedContinuation: AsyncStream<String>.Continuation?
        receivedStrings = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    deinit {
        cancel()
    }

    func resume() {
        task.resume()
        guard receiveTask == nil else { return }
        receiveTask = Task { [task, continuation] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case let .string(string):
                        continuation.yield(string)
                    case let .data(data):
                        continuation.yield(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        continue
                    }
                } catch {
                    continuation.finish()
                    break
                }
            }
        }
    }

    func sendString(_ string: String) async throws {
        try await task.send(.string(string))
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cancel() {
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }
}
