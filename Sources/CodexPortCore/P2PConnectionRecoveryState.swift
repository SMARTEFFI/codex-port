import Foundation
import CodexPortShared

public enum P2PConnectionRecoveryStatus: Equatable, Sendable {
    case idle
    case reconnecting(reason: String)
    case replacingStaleConnection
    case completed
    case failed(String)
}

public enum P2PConnectionRecoveryAction: Equatable, Sendable {
    case none
    case iceRestart(sessionID: String, threadID: String, preferDirect: Bool)
    case rebuildPeerConnection(sessionID: String, threadID: String)
    case directProbe(sessionID: String, threadID: String)
}

public enum P2PDirectProbeSchedule: Equatable, Sendable {
    case idle
    case readyNow
    case backoff(seconds: Int)
}

public enum P2PConnectionRecoveryEvent: Equatable, Sendable {
    case foregrounded
    case networkChanged
    case hostAgentWoke(presence: RelayHostPresence, authorization: P2PSignalingAuthorizationState)
    case staleDataChannelClosed(reason: String)
    case iceRestartFailed(reason: String)
    case replacementStarted
    case webRTC(WebRTCDataChannelConnectionState)
    case hostProtocolReady
    case codexLiveSourceReady
    case historyReconciled(items: [VisibleItem])
    case relayFallbackActive
    case directProbeFailed(reason: String)
    case directProbeSucceeded
    case manualRetryRequested
}

public struct P2PConnectionRecoveryState: Equatable, Sendable {
    public private(set) var pathState: RemoteConnectionPathState
    public private(set) var loadedHistoryItems: [VisibleItem]
    public private(set) var status: P2PConnectionRecoveryStatus
    public private(set) var sessionID: String
    public private(set) var threadID: String
    public private(set) var nextAction: P2PConnectionRecoveryAction
    public private(set) var directProbeSchedule: P2PDirectProbeSchedule

    public init(
        pathState: RemoteConnectionPathState,
        loadedHistoryItems: [VisibleItem],
        status: P2PConnectionRecoveryStatus = .idle,
        sessionID: String = "",
        threadID: String = "",
        nextAction: P2PConnectionRecoveryAction = .none,
        directProbeSchedule: P2PDirectProbeSchedule = .idle
    ) {
        self.pathState = pathState
        self.loadedHistoryItems = loadedHistoryItems
        self.status = status
        self.sessionID = sessionID
        self.threadID = threadID
        self.nextAction = nextAction
        self.directProbeSchedule = directProbeSchedule
    }

    public mutating func apply(_ event: P2PConnectionRecoveryEvent) {
        switch event {
        case .foregrounded:
            markNeedsICERestart(reason: "foregrounded")
        case .networkChanged:
            markNeedsICERestart(reason: "network changed")
        case let .hostAgentWoke(presence, authorization):
            pathState = RemoteConnectionPathState.fromPresence(presence, authorization: authorization)
            status = .replacingStaleConnection
            nextAction = .rebuildPeerConnection(sessionID: sessionID, threadID: threadID)
        case let .staleDataChannelClosed(reason):
            pathState.apply(.dataChannelClosed)
            markNeedsICERestart(reason: reason)
        case let .iceRestartFailed(reason):
            pathState.markReconnecting(reason: reason)
            status = .replacingStaleConnection
            nextAction = .rebuildPeerConnection(sessionID: sessionID, threadID: threadID)
        case .replacementStarted:
            resetTransportReadinessForReplacement()
            status = .replacingStaleConnection
        case let .webRTC(state):
            pathState.apply(state)
            if case let .turnFailed(reason) = state {
                status = .failed(reason)
            }
        case .hostProtocolReady:
            pathState.markHostProtocolReady()
        case .codexLiveSourceReady:
            pathState.markCodexLiveSourceReady()
            if pathState.dataChannel == .open, pathState.hostProtocol == .ready {
                status = .completed
                nextAction = .none
            }
        case let .historyReconciled(items):
            loadedHistoryItems = Self.deduplicated(items)
        case .relayFallbackActive:
            pathState.markDirectProbeActive(reason: "relay fallback")
            directProbeSchedule = .readyNow
            nextAction = .directProbe(sessionID: sessionID, threadID: threadID)
        case .directProbeFailed:
            pathState.markDirectProbeActive(reason: "direct probe failed")
            directProbeSchedule = .backoff(seconds: 30)
            nextAction = .none
        case .directProbeSucceeded:
            pathState.markUpgradedToDirect()
            directProbeSchedule = .idle
            status = .completed
            nextAction = .none
        case .manualRetryRequested:
            directProbeSchedule = .readyNow
            if pathState.relayFallbackActive {
                nextAction = .directProbe(sessionID: sessionID, threadID: threadID)
            }
        }
    }

    private mutating func markNeedsICERestart(reason: String) {
        pathState.markReconnecting(reason: reason)
        status = .reconnecting(reason: reason)
        nextAction = .iceRestart(sessionID: sessionID, threadID: threadID, preferDirect: true)
    }

    private mutating func resetTransportReadinessForReplacement() {
        pathState.ice = .notStarted
        pathState.dataPath = .notConnected
        pathState.dataChannel = .closed
        pathState.hostProtocol = .notReady
        pathState.codexLiveSource = .notReady()
    }

    private static func deduplicated(_ items: [VisibleItem]) -> [VisibleItem] {
        var result: [VisibleItem] = []
        for item in items {
            if result.last != item {
                result.append(item)
            }
        }
        return result
    }
}
