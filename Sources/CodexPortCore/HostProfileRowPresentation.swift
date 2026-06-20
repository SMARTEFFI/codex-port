import Foundation

public struct HostProfileRowPresentation: Equatable, Sendable {
    public enum StatusKind: Equatable, Sendable {
        case pending
        case trusted
        case loading
        case online
        case offline
        case failed
    }

    public var title: String
    public var subtitle: String
    public var statusText: String
    public var statusKind: StatusKind
    public var canOpenWorkspaces: Bool

    public init(
        title: String,
        subtitle: String,
        statusText: String,
        statusKind: StatusKind,
        canOpenWorkspaces: Bool? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusKind = statusKind
        self.canOpenWorkspaces = canOpenWorkspaces ?? (statusKind == .trusted || statusKind == .online)
    }

    public init(profile: HostProfile) {
        title = profile.name
        switch profile.connectionMethod {
        case .directSSH:
            subtitle = "\(profile.username)@\(profile.host):\(profile.port)"
            if profile.knownHostFingerprint == nil {
                statusText = "待确认"
                statusKind = .pending
                canOpenWorkspaces = true
            } else {
                statusText = "已信任"
                statusKind = .trusted
                canOpenWorkspaces = true
            }
        case let .relay(host):
            subtitle = "Mac: \(profile.name) · \(host.userName)"
            switch host.readiness {
            case .ready:
                if let connectionPathState = host.connectionPathState {
                    statusText = connectionPathState.iosPathSummary
                    statusKind = Self.statusKind(for: connectionPathState)
                } else {
                    statusText = "在线"
                    statusKind = .online
                }
                canOpenWorkspaces = true
            case let .loading(stage):
                statusText = Self.loadingStatusText(for: stage)
                statusKind = .loading
                canOpenWorkspaces = false
            case let .offline(lastSeenAt):
                if let lastSeenAt {
                    statusText = "离线 · 最后在线 \(Self.utcTimestamp(lastSeenAt))"
                } else {
                    statusText = "离线"
                }
                statusKind = .offline
                canOpenWorkspaces = true
            case let .failed(_, message):
                statusText = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "连接失败" : message
                statusKind = .failed
                canOpenWorkspaces = true
            }
        }
    }

    private static func loadingStatusText(for stage: RelayHostReadinessStage) -> String {
        switch stage {
        case .signaling:
            return "连接 HostAgent..."
        case .dataChannel:
            return "建立 DataChannel..."
        case .hostProtocol:
            return "等待 Host 协议..."
        case .threadList:
            return "读取会话中..."
        }
    }

    private static func statusKind(for pathState: RemoteConnectionPathState) -> StatusKind {
        switch pathState.transportState {
        case .failed:
            .failed
        case .idle:
            .offline
        case .checking, .reconnecting:
            .loading
        case .connected:
            .online
        }
    }

    public static func utcTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
