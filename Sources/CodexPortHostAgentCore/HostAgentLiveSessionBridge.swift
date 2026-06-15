import Foundation
import CodexPortShared

public final class HostAgentLiveSessionBridge<Adapter: HostAgentRelayWriteHandling>: @unchecked Sendable {
    private let adapter: Adapter
    private let queue: HostAgentSerializedWriteQueue<Adapter>
    private let replayLimit: Int
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RelayLiveSessionEvent>.Continuation] = [:]
    private var replayEvents: [RelayLiveSessionEvent] = []
    private var eventPumpTask: Task<Void, Never>?
    private var stopHandler: (() -> Void)?

    public init(adapter: Adapter, replayLimit: Int = 200, stopHandler: (() -> Void)? = nil) {
        self.adapter = adapter
        self.queue = HostAgentSerializedWriteQueue(adapter: adapter)
        self.replayLimit = replayLimit
        self.stopHandler = stopHandler
    }

    public convenience init(adapter: HostAgentProcessLiveAdapter) where Adapter == HostAgentProcessLiveAdapter {
        self.init(adapter: adapter, stopHandler: { adapter.stop() })
    }

    public convenience init(adapter: HostAgentCodexExecJSONAdapter) where Adapter == HostAgentCodexExecJSONAdapter {
        self.init(adapter: adapter, stopHandler: { adapter.stop() })
    }

    public convenience init(adapter: HostAgentCodexCLILiveAdapter) where Adapter == HostAgentCodexCLILiveAdapter {
        self.init(adapter: adapter, stopHandler: { adapter.stop() })
    }

    public convenience init(adapter: AnyHostAgentLiveSessionAdapter) where Adapter == AnyHostAgentLiveSessionAdapter {
        self.init(adapter: adapter, stopHandler: { adapter.stop() })
    }

    public func subscribe() -> AsyncStream<RelayLiveSessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let replayEvents = lock.withLock {
                continuations[id] = continuation
                return self.replayEvents
            }
            for event in replayEvents {
                continuation.yield(event)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuations[id] = nil
                }
            }
        }
    }

    public func start() throws where Adapter: HostAgentLiveSessionAdapter {
        let adapterEvents = adapter.events()
        eventPumpTask = Task { [weak self] in
            for await event in adapterEvents {
                self?.broadcast(event)
            }
            self?.finish()
        }
        try adapter.start()
    }

    public func enqueue(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        await queue.enqueue(write) { [weak self] status in
            self?.broadcast(.writeStatusChanged(writeID: write.writeID, status: status))
        }
    }

    public func stop() {
        stopHandler?()
        eventPumpTask?.cancel()
        finish()
    }

    private func broadcast(_ event: RelayLiveSessionEvent) {
        let continuations = lock.withLock {
            replayEvents.append(event)
            if replayEvents.count > replayLimit {
                replayEvents.removeFirst(replayEvents.count - replayLimit)
            }
            return Array(self.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func finish() {
        let continuations = lock.withLock {
            let continuations = Array(self.continuations.values)
            self.continuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
