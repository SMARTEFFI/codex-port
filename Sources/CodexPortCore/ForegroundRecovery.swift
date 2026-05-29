import Foundation

public enum ForegroundRecoveryStatus: Equatable, Sendable {
    case idle
    case recovering
    case completed
    case failed(String)
}

public final class ForegroundRecoveryCoordinator {
    private let workspaces: WorkspaceListStore
    private let session: SessionStore
    public private(set) var lastRecoveryStatus: ForegroundRecoveryStatus = .idle

    public init(workspaces: WorkspaceListStore, session: SessionStore) {
        self.workspaces = workspaces
        self.session = session
    }

    public func recover(currentThreadID: String?) async throws {
        lastRecoveryStatus = .recovering
        do {
            if let currentThreadID {
                try await session.open(threadID: currentThreadID)
            }
            lastRecoveryStatus = .completed
        } catch {
            lastRecoveryStatus = .failed(String(describing: error))
            throw error
        }
    }
}
