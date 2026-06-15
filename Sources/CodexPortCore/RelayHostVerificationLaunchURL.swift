import Foundation

public struct RelayHostVerificationLaunchURL: Equatable, Sendable {
    public var seed: RelayHostLaunchSeed
    public var plan: RelayHostLaunchAutomationPlan

    public init(seed: RelayHostLaunchSeed, plan: RelayHostLaunchAutomationPlan) {
        self.seed = seed
        self.plan = plan
    }

    public init(url: URL) throws {
        guard url.scheme == "codexport", url.host == "verify" else {
            throw RelayHostVerificationLaunchURLError.unsupportedURL
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RelayHostVerificationLaunchURLError.unsupportedURL
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }
        var environment = [
            "CODEXPORT_IOS_RELAY_HOST_ID": try Self.value("hostID", in: query),
            "CODEXPORT_IOS_RELAY_HOST_NAME": query["hostName"] ?? "CodexPort Host",
            "CODEXPORT_IOS_RELAY_HOST_USER": query["hostUser"] ?? "codex",
            "CODEXPORT_IOS_RELAY_DEVICE_ID": try Self.value("deviceID", in: query),
            "CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID": try Self.value("pairingRecordID", in: query),
            "CODEXPORT_IOS_RELAY_DEFAULT_DIRECTORY": query["defaultDirectory"] ?? "~",
        ]
        if let endpointURL = query["endpointURL"] {
            environment["CODEXPORT_IOS_RELAY_ENDPOINT_URL"] = endpointURL
        }
        let seed = try RelayHostLaunchSeed(environment: environment)
        let plan = RelayHostLaunchAutomationPlan(
            autoconnect: true,
            autoprompt: query["autoprompt"],
            threadID: query["threadID"]
        )
        self.init(seed: seed, plan: plan)
    }

    private static func value(_ key: String, in query: [String: String]) throws -> String {
        guard let value = query[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw RelayHostVerificationLaunchURLError.missingQueryItem(key)
        }
        return value
    }
}

public enum RelayHostVerificationLaunchURLError: Error, Equatable, Sendable {
    case unsupportedURL
    case missingQueryItem(String)
}
