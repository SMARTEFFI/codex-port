import Foundation
import CodexPortShared

public enum RemoteSignalingPathState: Equatable, Sendable {
    case offline
    case reachable
    case authorizedToSignal
    case failed(reason: String)
}

public enum RemoteICEPathState: Equatable, Sendable {
    case notStarted
    case gathering
    case failed(reason: String)
}

public enum RemoteDataPathState: Equatable, Sendable {
    case notConnected
    case directConnected
    case turnRelayedConnected
    case failed(reason: String)
}

public enum RemoteDataChannelPathState: Equatable, Sendable {
    case closed
    case open
    case failed(reason: String)
}

public enum RemoteHostProtocolPathState: Equatable, Sendable {
    case notReady
    case ready
    case failed(reason: String)
}

public enum RemoteCodexLiveSourcePathState: Equatable, Sendable {
    case notReady(reason: String? = nil)
    case ready
    case failed(reason: String)
}

public enum RemoteConnectionTransportState: Equatable, Sendable {
    case idle
    case checking
    case connected
    case reconnecting
    case failed
}

public enum RemoteConnectionCandidatePath: Equatable, Sendable {
    case unknown
    case direct
    case relay
}

public struct RemoteConnectionPathState: Equatable, Sendable {
    public var signaling: RemoteSignalingPathState
    public var ice: RemoteICEPathState
    public var dataPath: RemoteDataPathState
    public var dataChannel: RemoteDataChannelPathState
    public var hostProtocol: RemoteHostProtocolPathState
    public var codexLiveSource: RemoteCodexLiveSourcePathState
    public var directProbeActive: Bool
    public var lastReconnectReason: String?
    public var lastPathTransition: String?

    public init(
        signaling: RemoteSignalingPathState,
        ice: RemoteICEPathState,
        dataPath: RemoteDataPathState,
        dataChannel: RemoteDataChannelPathState,
        hostProtocol: RemoteHostProtocolPathState,
        codexLiveSource: RemoteCodexLiveSourcePathState,
        directProbeActive: Bool = false,
        lastReconnectReason: String? = nil,
        lastPathTransition: String? = nil
    ) {
        self.signaling = signaling
        self.ice = ice
        self.dataPath = dataPath
        self.dataChannel = dataChannel
        self.hostProtocol = hostProtocol
        self.codexLiveSource = codexLiveSource
        self.directProbeActive = directProbeActive
        self.lastReconnectReason = lastReconnectReason
        self.lastPathTransition = lastPathTransition
    }

    public static func fromPresence(
        _ presence: RelayHostPresence,
        authorization: P2PSignalingAuthorizationState
    ) -> RemoteConnectionPathState {
        let signaling: RemoteSignalingPathState
        switch (presence, authorization) {
        case (.offline, _), (_, .hostOffline):
            signaling = .offline
        case (_, .authorizedToSignal):
            signaling = .authorizedToSignal
        case (_, .signalingReachable):
            signaling = .reachable
        }

        return RemoteConnectionPathState(
            signaling: signaling,
            ice: .notStarted,
            dataPath: .notConnected,
            dataChannel: .closed,
            hostProtocol: .notReady,
            codexLiveSource: .notReady()
        )
    }

    public mutating func apply(_ state: WebRTCDataChannelConnectionState) {
        switch state {
        case .iceGathering:
            ice = .gathering
        case .directConnected:
            dataPath = .directConnected
            directProbeActive = false
        case let .directFailed(reason):
            dataPath = .failed(reason: "direct failed - \(reason)")
        case .turnRelayedConnected:
            dataPath = .turnRelayedConnected
        case let .turnFailed(reason):
            dataPath = .failed(reason: "TURN failed - \(reason)")
            dataChannel = .closed
            hostProtocol = .notReady
            codexLiveSource = .notReady()
        case .dataChannelOpen:
            dataChannel = .open
        case .dataChannelClosed:
            dataChannel = .closed
            hostProtocol = .notReady
            codexLiveSource = .notReady()
        }
    }

    public mutating func markReconnecting(reason: String) {
        lastReconnectReason = reason
        dataChannel = .closed
        hostProtocol = .notReady
        codexLiveSource = .notReady()
    }

    public mutating func markDirectProbeActive(reason: String? = nil) {
        directProbeActive = true
        if let reason, lastReconnectReason == nil {
            lastReconnectReason = reason
        }
    }

    public mutating func markUpgradedToDirect() {
        dataPath = .directConnected
        dataChannel = .open
        directProbeActive = false
        lastPathTransition = "upgraded to direct"
    }

    public mutating func markHostProtocolReady() {
        hostProtocol = .ready
    }

    public mutating func markCodexLiveSourceReady() {
        codexLiveSource = .ready
    }

    public var iosConnectionLogLines: [String] {
        var lines = [
            "Signaling: \(signaling.logText)",
            "ICE: \(ice.logText)",
            "Path: \(dataPath.logText)",
            "DataChannel: \(dataChannel.logText)",
            "Host protocol: \(hostProtocol.logText)",
            "Codex live source: \(codexLiveSource.logText)",
        ]
        if directProbeActive {
            lines.append("Direct probe: active")
        }
        if let lastReconnectReason {
            lines.append("Last reconnect reason: \(lastReconnectReason)")
        }
        if let lastPathTransition {
            lines.append("Path transition: \(lastPathTransition)")
        }
        return lines
    }

    public var hostAgentMenuItems: [String] {
        var items = [
            "Signaling \(signaling.menuText)",
            "DataChannel \(dataPath.menuText)",
            "Host protocol \(hostProtocol.menuText)",
            "Codex live source \(codexLiveSource.menuText)",
        ]
        if directProbeActive {
            items.append("Direct probe active")
        }
        return items
    }

    public var supportProbeReport: DiagnosticReport {
        DiagnosticReport(rows: [
            DiagnosticRow(title: "Signaling", status: signaling.diagnosticStatus, message: signaling.diagnosticMessage),
            DiagnosticRow(title: "ICE", status: ice.diagnosticStatus, message: ice.diagnosticMessage),
            DiagnosticRow(title: "Connection Path", status: dataPath.diagnosticStatus, message: dataPath.diagnosticMessage),
            DiagnosticRow(title: "DataChannel", status: dataChannel.diagnosticStatus, message: dataChannel.diagnosticMessage),
            DiagnosticRow(title: "Host Protocol", status: hostProtocol.diagnosticStatus, message: hostProtocol.diagnosticMessage),
            DiagnosticRow(title: "Codex Live Source", status: codexLiveSource.diagnosticStatus, message: codexLiveSource.diagnosticMessage),
        ])
    }

    public var transportState: RemoteConnectionTransportState {
        if lastReconnectReason != nil, dataChannel != .open {
            return .reconnecting
        }
        switch dataPath {
        case .directConnected, .turnRelayedConnected:
            return dataChannel == .open ? .connected : .checking
        case .failed:
            return .failed
        case .notConnected:
            return ice == .gathering ? .checking : .idle
        }
    }

    public var candidatePath: RemoteConnectionCandidatePath {
        switch dataPath {
        case .directConnected:
            .direct
        case .turnRelayedConnected:
            .relay
        case .notConnected, .failed:
            .unknown
        }
    }

    public var relayFallbackActive: Bool {
        candidatePath == .relay
    }

    public var iosPathSummary: String {
        switch transportState {
        case .reconnecting:
            return "重连中"
        case .failed:
            return "连接失败"
        case .checking:
            return "连接中"
        case .idle:
            return "未连接"
        case .connected:
            switch candidatePath {
            case .direct:
                return "直连"
            case .relay:
                return directProbeActive ? "中转 · 尝试直连中" : "中转"
            case .unknown:
                return "已连接"
            }
        }
    }
}

private extension RemoteSignalingPathState {
    var logText: String {
        switch self {
        case .offline:
            "offline"
        case .reachable:
            "reachable"
        case .authorizedToSignal:
            "authorized to signal"
        case let .failed(reason):
            "failed - \(reason)"
        }
    }

    var menuText: String {
        switch self {
        case .offline:
            "offline"
        case .reachable:
            "reachable"
        case .authorizedToSignal:
            "authorized to signal"
        case .failed:
            "failed"
        }
    }

    var diagnosticStatus: DiagnosticStatus {
        switch self {
        case .offline, .failed:
            .failed
        case .reachable, .authorizedToSignal:
            .passed
        }
    }

    var diagnosticMessage: String { logText }
}

private extension RemoteICEPathState {
    var logText: String {
        switch self {
        case .notStarted:
            "not started"
        case .gathering:
            "gathering"
        case let .failed(reason):
            "failed - \(reason)"
        }
    }

    var diagnosticStatus: DiagnosticStatus {
        switch self {
        case .notStarted, .gathering:
            .notRun
        case .failed:
            .failed
        }
    }

    var diagnosticMessage: String { logText }
}

private extension RemoteDataPathState {
    var logText: String {
        switch self {
        case .notConnected:
            "not connected"
        case .directConnected:
            "direct connected"
        case .turnRelayedConnected:
            "TURN relayed connected"
        case let .failed(reason):
            "failed - \(reason)"
        }
    }

    var menuText: String {
        switch self {
        case .notConnected:
            "not connected"
        case .directConnected:
            "direct connected"
        case .turnRelayedConnected:
            "TURN relayed connected"
        case .failed:
            "failed"
        }
    }

    var diagnosticStatus: DiagnosticStatus {
        switch self {
        case .notConnected:
            .notRun
        case .directConnected, .turnRelayedConnected:
            .passed
        case .failed:
            .failed
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .notConnected, .directConnected, .turnRelayedConnected:
            logText
        case let .failed(reason):
            reason
        }
    }
}

private extension RemoteDataChannelPathState {
    var logText: String {
        switch self {
        case .closed:
            "closed"
        case .open:
            "open"
        case let .failed(reason):
            "failed - \(reason)"
        }
    }

    var diagnosticStatus: DiagnosticStatus {
        switch self {
        case .closed:
            .notRun
        case .open:
            .passed
        case .failed:
            .failed
        }
    }

    var diagnosticMessage: String { logText }
}

private extension RemoteHostProtocolPathState {
    var logText: String {
        switch self {
        case .notReady:
            "not ready"
        case .ready:
            "ready"
        case let .failed(reason):
            "failed - \(reason)"
        }
    }

    var menuText: String {
        switch self {
        case .notReady:
            "not ready"
        case .ready:
            "ready"
        case .failed:
            "failed"
        }
    }

    var diagnosticStatus: DiagnosticStatus {
        switch self {
        case .notReady:
            .notRun
        case .ready:
            .passed
        case .failed:
            .failed
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .notReady, .ready:
            logText
        case let .failed(reason):
            reason
        }
    }
}

private extension RemoteCodexLiveSourcePathState {
    var logText: String {
        switch self {
        case let .notReady(reason?):
            "not ready - \(reason)"
        case .notReady(nil):
            "not ready"
        case .ready:
            "ready"
        case let .failed(reason):
            "failed - \(reason)"
        }
    }

    var menuText: String {
        switch self {
        case .notReady:
            "not ready"
        case .ready:
            "ready"
        case .failed:
            "failed"
        }
    }

    var diagnosticStatus: DiagnosticStatus {
        switch self {
        case .notReady:
            .failed
        case .ready:
            .passed
        case .failed:
            .failed
        }
    }

    var diagnosticMessage: String {
        switch self {
        case let .notReady(reason?):
            reason
        case .notReady(nil), .ready:
            logText
        case let .failed(reason):
            reason
        }
    }
}
