import Foundation
import CodexPortShared

public enum FakeCodexCLILiveAdapterStep: Equatable, Sendable {
    case assistantTextChunk(itemID: String, text: String)
    case commandOutputChunk(itemID: String, text: String)
    case fileChange(itemID: String, path: String, diff: String)
    case approvalRequested(requestID: String, summary: String)
    case turnCompleted
    case turnFailed(reason: String)
}

public final class FakeCodexCLILiveAdapter: @unchecked Sendable {
    private let script: [FakeCodexCLILiveAdapterStep]
    public private(set) var receivedWrites: [RelayLiveSessionWrite] = []
    private var failingWriteIDs: [String: String] = [:]
    private var delayedWriteIDs: Set<String> = []

    public init(script: [FakeCodexCLILiveAdapterStep]) {
        self.script = script
    }

    public func events(threadID: String, turnID: String, sessionID: String) async throws -> [RelayLiveSessionEvent] {
        var events: [RelayLiveSessionEvent] = [
            .sessionStarted(sessionID: sessionID, threadID: threadID, turnID: turnID)
        ]
        for step in script {
            switch step {
            case let .assistantTextChunk(itemID, text):
                events.append(.assistantTextDelta(turnID: turnID, itemID: itemID, text: text))
            case let .commandOutputChunk(itemID, text):
                events.append(.commandOutputDelta(turnID: turnID, itemID: itemID, text: text))
            case let .fileChange(itemID, path, diff):
                events.append(.fileChange(turnID: turnID, itemID: itemID, path: path, diff: diff))
            case let .approvalRequested(requestID, summary):
                events.append(.approvalRequested(turnID: turnID, requestID: requestID, summary: summary))
            case .turnCompleted:
                events.append(.turnCompleted(turnID: turnID))
            case let .turnFailed(reason):
                events.append(.turnFailed(turnID: turnID, reason: reason))
            }
        }
        return events
    }

    public func failWrites(withIDs writeIDs: [String], reason: String) {
        for writeID in writeIDs {
            failingWriteIDs[writeID] = reason
        }
    }

    public func delayWrites(withIDs writeIDs: [String]) {
        delayedWriteIDs.formUnion(writeIDs)
    }

    public func handle(_ write: RelayLiveSessionWrite) async -> RelayWriteStatus {
        if delayedWriteIDs.contains(write.writeID) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        receivedWrites.append(write)
        if let reason = failingWriteIDs[write.writeID] {
            return .failed(reason: reason)
        }
        return .handled
    }
}

public final class FakeRelayLiveSessionClient: @unchecked Sendable {
    public let sessionID: String
    public let threadID: String
    public let turnID: String
    public let streamID: UUID
    public private(set) var events: [RelayLiveSessionEvent] = []

    private let stream: FakeRelayStream
    private let adapter: FakeCodexCLILiveAdapter

    fileprivate init(
        sessionID: String,
        threadID: String,
        turnID: String,
        stream: FakeRelayStream,
        adapter: FakeCodexCLILiveAdapter
    ) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.streamID = stream.id
        self.stream = stream
        self.adapter = adapter
    }

    public func runAdapterScript() async throws {
        let adapterEvents = try await adapter.events(threadID: threadID, turnID: turnID, sessionID: sessionID)
        for event in adapterEvents {
            receive(event)
        }
    }

    public func close(errorCode: String?) {
        stream.close(errorCode: errorCode)
        events.append(.streamClosed(sessionID: sessionID, threadID: threadID, errorCode: errorCode))
    }

    public func receiveWriteStatus(writeID: String, status: RelayWriteStatus) {
        receive(.writeStatusChanged(writeID: writeID, status: status))
    }

    public func receiveSessionEvent(_ event: RelayLiveSessionEvent) {
        receive(event)
    }

    public func clearEvents() {
        events.removeAll()
    }

    private func receive(_ event: RelayLiveSessionEvent) {
        stream.sendHostToDevice(event.sealedPayloadForRelayTelemetry)
        events.append(event)
    }
}

public final class FakeRelayLiveSessionHub: @unchecked Sendable {
    public private(set) var handledApprovalRequestIDs: [String] = []

    private let threadID: String
    private let turnID: String
    private let adapter: FakeCodexCLILiveAdapter
    private let title: String
    private var clientsBySessionID: [String: FakeRelayLiveSessionClient] = [:]
    private var visibleEvents: [RelayLiveSessionEvent] = []

    public init(threadID: String, turnID: String, adapter: FakeCodexCLILiveAdapter, title: String = "") {
        self.threadID = threadID
        self.turnID = turnID
        self.adapter = adapter
        self.title = title
    }

    public func attach(_ client: FakeRelayLiveSessionClient) {
        clientsBySessionID[client.sessionID] = client
        client.receiveSessionEvent(.sessionStarted(sessionID: client.sessionID, threadID: threadID, turnID: turnID))
        for event in visibleEvents {
            client.receiveSessionEvent(event)
        }
    }

    public func detach(_ client: FakeRelayLiveSessionClient) {
        clientsBySessionID[client.sessionID] = nil
    }

    public func enqueue(_ write: RelayLiveSessionWrite, from client: FakeRelayLiveSessionClient) async -> RelayWriteStatus {
        emit(.writeStatusChanged(writeID: write.writeID, status: .queued))
        emit(.writeStatusChanged(writeID: write.writeID, status: .running))

        let status = await adapter.handle(write)
        let generatedEvents = eventsGeneratedByAdapter(for: write, status: status)
        for event in generatedEvents {
            emit(event)
        }

        if status == .handled, case let .approval(_, requestID, _) = write, !handledApprovalRequestIDs.contains(requestID) {
            handledApprovalRequestIDs.append(requestID)
        }
        emit(.writeStatusChanged(writeID: write.writeID, status: status))

        return status
    }

    public func emitSessionEvent(_ event: RelayLiveSessionEvent) {
        emit(event)
    }

    public func recoveredSnapshot(sessionID: String) -> RelayRecoveredSessionSnapshot {
        RelayRecoveredSessionSnapshot(
            sessionID: sessionID,
            threadID: threadID,
            title: title,
            state: recoveredState,
            recentEvents: visibleEvents,
            pendingApprovals: pendingApprovals
        )
    }

    private var attachedClients: [FakeRelayLiveSessionClient] {
        clientsBySessionID
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    private func eventsGeneratedByAdapter(for write: RelayLiveSessionWrite, status: RelayWriteStatus) -> [RelayLiveSessionEvent] {
        guard status == .handled else { return [] }
        switch write {
        case let .prompt(writeID, _, text, _):
            return [
                .assistantTextDelta(turnID: turnID, itemID: "\(writeID)-assistant", text: "reply to \(text)"),
                .turnCompleted(turnID: turnID),
            ]
        case .interrupt:
            return [
                .turnCompleted(turnID: turnID)
            ]
        case .approval:
            return []
        }
    }

    private var recoveredState: RelayRecoveredSessionState {
        for event in visibleEvents.reversed() {
            switch event {
            case let .turnFailed(_, reason):
                return .failed(reason)
            case .turnCompleted:
                return .completed
            case .sessionStarted, .threadHistoryLoaded, .userMessage, .assistantTextDelta, .commandOutputDelta, .fileChange, .approvalRequested, .writeStatusChanged, .streamClosed:
                continue
            }
        }
        return .running(turnID: turnID)
    }

    private var pendingApprovals: [RelayPendingApproval] {
        let handledApprovalRequestIDs = Set(handledApprovalRequestIDs)
        return visibleEvents.compactMap { event in
            guard case let .approvalRequested(_, requestID, summary) = event else { return nil }
            guard !handledApprovalRequestIDs.contains(requestID) else { return nil }
            return RelayPendingApproval(requestID: requestID, summary: summary)
        }
    }

    private func emit(_ event: RelayLiveSessionEvent) {
        visibleEvents.append(event)
        for client in attachedClients {
            client.receiveSessionEvent(event)
        }
    }
}

public actor FakeHostAgentRelayWriteQueue {
    private let adapter: FakeCodexCLILiveAdapter
    private var tailTask: Task<RelayWriteStatus, Never>?

    public init(adapter: FakeCodexCLILiveAdapter) {
        self.adapter = adapter
    }

    public func enqueue(
        _ write: RelayLiveSessionWrite,
        from _: FakeRelayLiveSessionClient,
        broadcastTo clients: [FakeRelayLiveSessionClient]
    ) async -> RelayWriteStatus {
        let previousTask = tailTask
        let adapter = self.adapter
        let task = Task { @Sendable in
            if let previousTask {
                _ = await previousTask.value
            }
            Self.broadcast(writeID: write.writeID, status: .queued, to: clients)
            Self.broadcast(writeID: write.writeID, status: .running, to: clients)
            let terminalStatus = await adapter.handle(write)
            Self.broadcast(writeID: write.writeID, status: terminalStatus, to: clients)
            return terminalStatus
        }
        tailTask = task
        return await task.value
    }

    private static func broadcast(writeID: String, status: RelayWriteStatus, to clients: [FakeRelayLiveSessionClient]) {
        for client in clients {
            client.receiveWriteStatus(writeID: writeID, status: status)
        }
    }
}

public extension FakeRelay {
    func openLiveSession(
        from attachment: FakeRelayAttachment,
        threadID: String,
        turnID: String,
        adapter: FakeCodexCLILiveAdapter
    ) throws -> FakeRelayLiveSessionClient {
        let stream = try openStream(from: attachment, metadata: [
            "purpose": "codex-live-session",
            "threadID": threadID,
            "turnID": turnID,
        ])
        return FakeRelayLiveSessionClient(
            sessionID: UUID().uuidString,
            threadID: threadID,
            turnID: turnID,
            stream: stream,
            adapter: adapter
        )
    }
}
