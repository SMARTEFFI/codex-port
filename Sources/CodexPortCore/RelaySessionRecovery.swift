import Foundation
import CodexPortShared

public enum RelaySessionRecoveryStatus: Equatable, Sendable {
    case idle
    case reconnecting(reason: String)
    case recovering
    case completed
    case failed(String)
}

public struct RelaySessionRecoveryState: Sendable {
    public private(set) var status: RelaySessionRecoveryStatus = .idle

    public init() {}

    public var allowsManualReconnect: Bool {
        switch status {
        case .reconnecting, .failed:
            true
        case .idle, .recovering, .completed:
            false
        }
    }

    public mutating func apply(_ event: RelayLiveSessionEvent) {
        guard case let .streamClosed(_, _, errorCode) = event else { return }
        if let errorCode {
            status = .reconnecting(reason: "Relay stream closed: \(errorCode)")
        } else {
            status = .reconnecting(reason: "Relay stream closed.")
        }
    }

    public mutating func markRecovering() {
        status = .recovering
    }

    public mutating func markCompleted() {
        status = .completed
    }

    public mutating func markFailed(_ reason: String) {
        status = .failed(reason)
    }
}

public protocol RelaySessionRecovering: Sendable {
    func recover(sessionID: String, threadID: String) async throws -> RelayRecoveredSessionSnapshot
}

public final class RelaySessionRecoveryCoordinator: @unchecked Sendable {
    private let source: any RelaySessionRecovering
    private let session: SessionStore
    private let diagnostics: ConnectionDiagnostics
    private let lock = NSLock()
    private var state = RelaySessionRecoveryState()

    public init(
        source: any RelaySessionRecovering,
        session: SessionStore,
        diagnostics: ConnectionDiagnostics = ConnectionDiagnostics()
    ) {
        self.source = source
        self.session = session
        self.diagnostics = diagnostics
    }

    public var status: RelaySessionRecoveryStatus {
        lock.withLock {
            state.status
        }
    }

    public var allowsManualReconnect: Bool {
        lock.withLock {
            state.allowsManualReconnect
        }
    }

    public func recover(sessionID: String, threadID: String) async throws -> RelayRecoveredSessionSnapshot {
        setState { $0.markRecovering() }
        do {
            let snapshot = try await source.recover(sessionID: sessionID, threadID: threadID)
            apply(snapshot)
            setState { $0.markCompleted() }
            return snapshot
        } catch {
            let reason = await failureReason(for: error)
            setState { $0.markFailed(reason) }
            throw error
        }
    }

    private func apply(_ snapshot: RelayRecoveredSessionSnapshot) {
        for event in snapshot.recentEvents {
            session.receive(relayEvent: event)
        }
        switch snapshot.state {
        case let .running(turnID):
            session.receive(relayEvent: .sessionStarted(sessionID: snapshot.sessionID, threadID: snapshot.threadID, turnID: turnID))
        case .completed:
            session.receive(relayEvent: .turnCompleted(turnID: snapshot.threadID))
        case let .failed(reason):
            session.receive(relayEvent: .turnFailed(turnID: snapshot.threadID, reason: reason))
        }
    }

    private func failureReason(for error: Error) async -> String {
        if let relayFailure = error as? RelayDiagnosticFailure {
            return (await diagnostics.report(for: relayFailure)).rows.first?.message ?? String(describing: error)
        }
        if let pairingError = error as? RelayPairingError {
            return (await diagnostics.report(for: pairingError)).rows.first?.message ?? String(describing: error)
        }
        return String(describing: error)
    }

    private func setState(_ update: (inout RelaySessionRecoveryState) -> Void) {
        lock.withLock {
            update(&state)
        }
    }
}
