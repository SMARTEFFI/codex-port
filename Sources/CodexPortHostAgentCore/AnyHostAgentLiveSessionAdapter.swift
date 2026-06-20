import Foundation
import CodexPortShared

public struct AnyHostAgentLiveSessionAdapter: HostAgentLiveSessionAdapter {
    public let description: String
    public let metadata: [String: String]
    private let eventsHandler: @Sendable () -> AsyncStream<RelayLiveSessionEvent>
    private let startHandler: @Sendable () throws -> Void
    private let handleHandler: @Sendable (RelayLiveSessionWrite) async -> RelayWriteStatus
    private let stopHandler: @Sendable () -> Void

    public init<Adapter: HostAgentLiveSessionAdapter>(
        _ adapter: Adapter,
        description: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.description = description ?? String(describing: Adapter.self)
        self.metadata = metadata
        self.eventsHandler = { adapter.events() }
        self.startHandler = { try adapter.start() }
        self.handleHandler = { write in await adapter.handle(write) }
        self.stopHandler = { adapter.stop() }
    }

    public func events() -> AsyncStream<RelayLiveSessionEvent> {
        eventsHandler()
    }

    public func start() throws {
        try startHandler()
    }

    public func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        await handleHandler(write)
    }

    public func stop() {
        stopHandler()
    }
}
