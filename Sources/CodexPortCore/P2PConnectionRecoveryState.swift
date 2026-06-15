import Foundation
import CodexPortShared

public enum P2PConnectionRecoveryStatus: Equatable, Sendable {
    case idle
    case reconnecting(reason: String)
    case replacingStaleConnection
    case completed
    case failed(String)
}

public enum P2PConnectionRecoveryEvent: Equatable, Sendable {
    case foregrounded
    case networkChanged
    case hostAgentWoke(presence: RelayHostPresence, authorization: P2PSignalingAuthorizationState)
    case staleDataChannelClosed(reason: String)
    case replacementStarted
    case webRTC(WebRTCDataChannelConnectionState)
    case hostProtocolReady
    case codexLiveSourceReady
}

public struct P2PConnectionRecoveryState: Equatable, Sendable {
    public private(set) var pathState: RemoteConnectionPathState
    public private(set) var loadedHistoryItems: [VisibleItem]
    public private(set) var status: P2PConnectionRecoveryStatus

    public init(
        pathState: RemoteConnectionPathState,
        loadedHistoryItems: [VisibleItem],
        status: P2PConnectionRecoveryStatus = .idle
    ) {
        self.pathState = pathState
        self.loadedHistoryItems = loadedHistoryItems
        self.status = status
    }

    public mutating func apply(_ event: P2PConnectionRecoveryEvent) {
        switch event {
        case .foregrounded:
            status = .reconnecting(reason: "foregrounded")
        case .networkChanged:
            status = .reconnecting(reason: "network changed")
        case let .hostAgentWoke(presence, authorization):
            pathState = RemoteConnectionPathState.fromPresence(presence, authorization: authorization)
            status = .replacingStaleConnection
        case let .staleDataChannelClosed(reason):
            pathState.apply(.dataChannelClosed)
            status = .reconnecting(reason: reason)
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
            }
        }
    }

    private mutating func resetTransportReadinessForReplacement() {
        pathState.ice = .notStarted
        pathState.dataPath = .notConnected
        pathState.dataChannel = .closed
        pathState.hostProtocol = .notReady
        pathState.codexLiveSource = .notReady()
    }
}
