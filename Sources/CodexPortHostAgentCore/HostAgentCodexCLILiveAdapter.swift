import Foundation
import CodexPortShared

public struct CodexCLILiveSessionDescriptor: Equatable, Sendable {
    public var sessionID: String
    public var threadID: String
    public var turnID: String

    public init(sessionID: String, threadID: String, turnID: String) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct CodexCLILivePrompt: Equatable, Sendable {
    public var writeID: String
    public var threadID: String
    public var text: String

    public init(writeID: String, threadID: String, text: String) {
        self.writeID = writeID
        self.threadID = threadID
        self.text = text
    }
}

public enum CodexCLILiveProducerWriteResult: Equatable, Sendable {
    case accepted
    case rejected(reason: String)
}

public enum CodexCLILiveProducerEvent: Equatable, Sendable {
    case sessionOpened(CodexCLILiveSessionDescriptor)
    case userMessage(turnID: String, itemID: String, text: String)
    case assistantTextDelta(turnID: String, itemID: String, text: String)
    case commandOutputDelta(turnID: String, itemID: String, text: String)
    case fileChange(turnID: String, itemID: String, path: String, diff: String)
    case approvalRequested(turnID: String, requestID: String, summary: String)
    case turnCompleted(turnID: String)
    case turnFailed(turnID: String, reason: String)
    case streamClosed(sessionID: String, threadID: String, errorCode: String?)
}

public protocol CodexCLILiveProducing: Sendable {
    func events() async -> AsyncStream<CodexCLILiveProducerEvent>
    func start(session: CodexCLILiveSessionDescriptor) async throws
    func submitPrompt(_ prompt: CodexCLILivePrompt) async -> CodexCLILiveProducerWriteResult
    func stop() async
}

public struct CodexCLILiveEventBridge: Sendable {
    public init() {}

    public func relayEvent(from event: CodexCLILiveProducerEvent) -> RelayLiveSessionEvent {
        switch event {
        case let .sessionOpened(session):
            .sessionStarted(sessionID: session.sessionID, threadID: session.threadID, turnID: session.turnID)
        case let .userMessage(turnID, itemID, text):
            .userMessage(turnID: turnID, itemID: itemID, text: text)
        case let .assistantTextDelta(turnID, itemID, text):
            .assistantTextDelta(turnID: turnID, itemID: itemID, text: text)
        case let .commandOutputDelta(turnID, itemID, text):
            .commandOutputDelta(turnID: turnID, itemID: itemID, text: text)
        case let .fileChange(turnID, itemID, path, diff):
            .fileChange(turnID: turnID, itemID: itemID, path: path, diff: diff)
        case let .approvalRequested(turnID, requestID, summary):
            .approvalRequested(turnID: turnID, requestID: requestID, summary: summary)
        case let .turnCompleted(turnID):
            .turnCompleted(turnID: turnID)
        case let .turnFailed(turnID, reason):
            .turnFailed(turnID: turnID, reason: reason)
        case let .streamClosed(sessionID, threadID, errorCode):
            .streamClosed(sessionID: sessionID, threadID: threadID, errorCode: errorCode)
        }
    }
}

public final class HostAgentCodexCLILiveAdapter: HostAgentLiveSessionAdapter, @unchecked Sendable {
    private enum StartGateOutcome: Sendable {
        case ready
        case failed(String)
    }

    private enum StartState: Sendable {
        case idle
        case starting([CheckedContinuation<StartGateOutcome, Never>])
        case started
        case failed(String)
    }

    private let session: CodexCLILiveSessionDescriptor
    private let producer: CodexCLILiveProducing
    private let bridge: CodexCLILiveEventBridge
    private let logger: HostAgentLogRecorder
    private let lock = NSLock()

    private var started = false
    private var startState: StartState = .idle
    private var eventPumpTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<RelayLiveSessionEvent>.Continuation] = [:]

    public init(
        session: CodexCLILiveSessionDescriptor,
        producer: CodexCLILiveProducing,
        bridge: CodexCLILiveEventBridge = CodexCLILiveEventBridge(),
        logger: HostAgentLogRecorder = HostAgentLogRecorder()
    ) {
        self.session = session
        self.producer = producer
        self.bridge = bridge
        self.logger = logger
    }

    public func events() -> AsyncStream<RelayLiveSessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.eventContinuations[id] = nil
                }
            }
        }
    }

    public func start() throws {
        lock.withLock {
            started = true
            startState = .starting([])
        }
        logger.record("codex cli live adapter starting session=\(session.sessionID) thread=\(session.threadID)")
        eventPumpTask = Task { [weak self, producer, session, bridge, logger] in
            guard let self else { return }
            let producerEvents = await producer.events()
            let pumpTask = Task { [weak self, bridge] in
                for await event in producerEvents {
                    self?.emit(bridge.relayEvent(from: event))
                }
                self?.finishEvents()
            }
            do {
                try await producer.start(session: session)
                logger.record("codex cli live producer started session=\(session.sessionID) thread=\(session.threadID)")
                self.resolveStart(.ready)
            } catch {
                logger.record("codex cli live producer start failed session=\(session.sessionID) reasonBytes=\(String(describing: error).utf8.count)")
                self.resolveStart(.failed("Codex CLI live producer failed to start."))
                self.emit(.turnFailed(turnID: session.turnID, reason: "Codex CLI live producer failed to start."))
            }
            await pumpTask.value
        }
    }

    public func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        guard isStarted else {
            logger.record("codex cli live write failed write=\(write.writeID) reason=not-started")
            return .failed(reason: "Codex CLI live adapter is not running.")
        }

        switch write {
        case let .prompt(writeID, threadID, text):
            switch await waitUntilProducerStarted() {
            case .ready:
                break
            case let .failed(reason):
                logger.record("codex cli live prompt rejected write=\(writeID) reason=start-failed reasonBytes=\(reason.utf8.count)")
                return .failed(reason: reason)
            }
            logger.record("codex cli live prompt write=\(writeID) bytes=\(text.utf8.count)")
            let result = await producer.submitPrompt(CodexCLILivePrompt(writeID: writeID, threadID: threadID, text: text))
            switch result {
            case .accepted:
                return .handled
            case let .rejected(reason):
                logger.record("codex cli live prompt rejected write=\(writeID) reasonBytes=\(reason.utf8.count)")
                return .failed(reason: reason)
            }
        case let .approval(writeID, requestID, action):
            logger.record("codex cli live approval unsupported write=\(writeID) request=\(requestID) action=\(action.wireValue)")
            return .failed(reason: "Codex CLI live adapter approval writes are not implemented yet.")
        case let .interrupt(writeID, _, _):
            logger.record("codex cli live interrupt write=\(writeID)")
            return .handled
        }
    }

    public func stop() {
        let startWaiters = lock.withLock {
            started = false
            return resolveStartLocked(.failed("Codex CLI live adapter stopped before producer start completed."))
        }
        for waiter in startWaiters {
            waiter.resume(returning: .failed("Codex CLI live adapter stopped before producer start completed."))
        }
        eventPumpTask?.cancel()
        Task { [producer] in
            await producer.stop()
        }
        logger.record("codex cli live adapter stopped session=\(session.sessionID)")
        finishEvents()
    }

    private var isStarted: Bool {
        lock.withLock {
            started
        }
    }

    private func waitUntilProducerStarted() async -> StartGateOutcome {
        let current: StartGateOutcome? = lock.withLock {
            switch startState {
            case .idle:
                return .failed("Codex CLI live adapter is not running.")
            case .started:
                return .ready
            case let .failed(reason):
                return .failed(reason)
            case .starting:
                return nil
            }
        }
        if let current {
            return current
        }
        return await withCheckedContinuation { continuation in
            lock.withLock {
                switch startState {
                case .idle:
                    continuation.resume(returning: .failed("Codex CLI live adapter is not running."))
                case .started:
                    continuation.resume(returning: .ready)
                case let .failed(reason):
                    continuation.resume(returning: .failed(reason))
                case var .starting(waiters):
                    waiters.append(continuation)
                    startState = .starting(waiters)
                }
            }
        }
    }

    private func resolveStart(_ result: StartGateOutcome) {
        let waiters = lock.withLock {
            resolveStartLocked(result)
        }
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    @discardableResult
    private func resolveStartLocked(_ result: StartGateOutcome) -> [CheckedContinuation<StartGateOutcome, Never>] {
        let waiters: [CheckedContinuation<StartGateOutcome, Never>]
        switch startState {
        case let .starting(existingWaiters):
            waiters = existingWaiters
        case .idle, .started, .failed:
            waiters = []
        }
        switch result {
        case .ready:
            startState = .started
        case let .failed(reason):
            startState = .failed(reason)
        }
        return waiters
    }

    private func emit(_ event: RelayLiveSessionEvent) {
        let continuations = lock.withLock {
            Array(eventContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func finishEvents() {
        let continuations = lock.withLock {
            let continuations = Array(eventContinuations.values)
            eventContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
