import Foundation

public struct RelayPendingApproval: Equatable, Sendable {
    public var requestID: String
    public var summary: String

    public init(requestID: String, summary: String) {
        self.requestID = requestID
        self.summary = summary
    }
}

public enum RelayRecoveredSessionState: Equatable, Sendable {
    case running(turnID: String)
    case completed
    case failed(String)
}

public struct RelayRecoveredSessionSnapshot: Equatable, Sendable {
    public var sessionID: String
    public var threadID: String
    public var title: String
    public var state: RelayRecoveredSessionState
    public var recentEvents: [RelayLiveSessionEvent]
    public var pendingApprovals: [RelayPendingApproval]

    public init(
        sessionID: String,
        threadID: String,
        title: String,
        state: RelayRecoveredSessionState,
        recentEvents: [RelayLiveSessionEvent],
        pendingApprovals: [RelayPendingApproval]
    ) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.title = title
        self.state = state
        self.recentEvents = recentEvents
        self.pendingApprovals = pendingApprovals
    }
}

public enum RelaySessionRecoveryError: Error, Equatable, Sendable {
    case sessionNotFound(sessionID: String, threadID: String)
}
