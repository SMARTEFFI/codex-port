import Foundation

public struct RelayHostLaunchAutomationPlan: Equatable, Sendable {
    public var autoconnect: Bool
    public var autoprompt: String?
    public var threadID: String?

    public init(autoconnect: Bool, autoprompt: String?, threadID: String? = nil) {
        self.autoconnect = autoconnect
        self.autoprompt = autoprompt
        self.threadID = threadID
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let prompt = Self.nilIfEmpty(environment["CODEXPORT_IOS_RELAY_AUTOPROMPT"])
        let targetThreadID = Self.nilIfEmpty(environment["CODEXPORT_IOS_RELAY_THREAD_ID"])
        autoconnect = Self.isEnabled(environment["CODEXPORT_IOS_RELAY_AUTOCONNECT"]) || prompt != nil || targetThreadID != nil
        autoprompt = prompt
        threadID = targetThreadID
    }

    public func matches(_ profile: HostProfile, seed: RelayHostLaunchSeed) -> Bool {
        guard case let .relay(host) = profile.connectionMethod else {
            return false
        }
        return host.hostAgentID == seed.hostAgentID
            && host.deviceID == seed.deviceID
            && host.pairingRecordID == seed.pairingRecordID
    }

    private static func isEnabled(_ value: String?) -> Bool {
        switch nilIfEmpty(value)?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
