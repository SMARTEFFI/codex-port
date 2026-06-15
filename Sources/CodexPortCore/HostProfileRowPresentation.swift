import Foundation

public struct HostProfileRowPresentation: Equatable, Sendable {
    public enum StatusKind: Equatable, Sendable {
        case pending
        case trusted
        case online
        case offline
    }

    public var title: String
    public var subtitle: String
    public var statusText: String
    public var statusKind: StatusKind

    public init(title: String, subtitle: String, statusText: String, statusKind: StatusKind) {
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusKind = statusKind
    }

    public init(profile: HostProfile) {
        title = profile.name
        switch profile.connectionMethod {
        case .directSSH:
            subtitle = "\(profile.username)@\(profile.host):\(profile.port)"
            if profile.knownHostFingerprint == nil {
                statusText = "待确认"
                statusKind = .pending
            } else {
                statusText = "已信任"
                statusKind = .trusted
            }
        case let .relay(host):
            subtitle = "Mac: \(profile.name) · \(host.userName)"
            switch host.presence {
            case .online:
                statusText = "在线"
                statusKind = .online
            case let .offline(lastSeenAt):
                if let lastSeenAt {
                    statusText = "离线 · 最后在线 \(Self.utcTimestamp(lastSeenAt))"
                } else {
                    statusText = "离线"
                }
                statusKind = .offline
            }
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
