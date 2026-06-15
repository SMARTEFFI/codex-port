import Foundation
import CodexPortShared

public struct RelayHostLaunchSeed: Equatable, Sendable {
    public var hostAgentID: UUID
    public var displayName: String
    public var userName: String
    public var deviceID: UUID
    public var pairingRecordID: String
    public var endpointURL: URL
    public var defaultDirectory: String

    public init(
        hostAgentID: UUID,
        displayName: String,
        userName: String,
        deviceID: UUID,
        pairingRecordID: String,
        endpointURL: URL,
        defaultDirectory: String
    ) {
        self.hostAgentID = hostAgentID
        self.displayName = displayName
        self.userName = userName
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.endpointURL = endpointURL
        self.defaultDirectory = defaultDirectory
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.init(
            hostAgentID: try Self.uuid("CODEXPORT_IOS_RELAY_HOST_ID", environment: environment),
            displayName: try Self.string("CODEXPORT_IOS_RELAY_HOST_NAME", environment: environment),
            userName: try Self.string("CODEXPORT_IOS_RELAY_HOST_USER", environment: environment),
            deviceID: try Self.uuid("CODEXPORT_IOS_RELAY_DEVICE_ID", environment: environment),
            pairingRecordID: try Self.string("CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID", environment: environment),
            endpointURL: try Self.endpointURL(environment: environment),
            defaultDirectory: environment["CODEXPORT_IOS_RELAY_DEFAULT_DIRECTORY"].flatMap(Self.nilIfEmpty) ?? "~"
        )
    }

    public func hostProfileDraft() -> HostProfileDraft {
        let relayHost = RelayHostDraft(
            hostAgentID: hostAgentID,
            displayName: displayName,
            userName: userName,
            pairingRecordID: pairingRecordID,
            deviceID: deviceID,
            relayEndpointURL: endpointURL,
            presence: .online(activeConnectionCount: 0),
            diagnosticsSummary: "AFK Relay seed ready"
        )
        return HostProfileDraft(
            connectionMethod: .relay(relayHost),
            name: displayName,
            host: endpointURL.host(percentEncoded: false) ?? endpointURL.host() ?? "relay.local",
            port: endpointURL.port ?? Self.defaultPort(for: endpointURL),
            username: userName,
            auth: .none,
            codexPath: "codex",
            startupCommand: "",
            defaultDirectory: defaultDirectory
        )
    }

    private static func string(_ key: String, environment: [String: String]) throws -> String {
        guard let value = nilIfEmpty(environment[key]) else {
            throw RelayHostLaunchSeedError.missingEnvironmentValue(key)
        }
        return value
    }

    private static func uuid(_ key: String, environment: [String: String]) throws -> UUID {
        let value = try string(key, environment: environment)
        guard let uuid = UUID(uuidString: value) else {
            throw RelayHostLaunchSeedError.invalidUUID(key)
        }
        return uuid
    }

    private static func url(_ key: String, environment: [String: String]) throws -> URL {
        let value = try string(key, environment: environment)
        guard let url = URL(string: value), url.scheme != nil, url.host() != nil else {
            throw RelayHostLaunchSeedError.invalidURL(key)
        }
        return url
    }

    private static func endpointURL(environment: [String: String]) throws -> URL {
        guard nilIfEmpty(environment["CODEXPORT_IOS_RELAY_ENDPOINT_URL"]) != nil else {
            return try RelayHostProductionPairingInput(
                pairingMaterial: "seed",
                deviceDisplayName: "seed"
            ).streamEndpointURL
        }
        return try url("CODEXPORT_IOS_RELAY_ENDPOINT_URL", environment: environment)
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func defaultPort(for url: URL) -> Int {
        switch url.scheme {
        case "wss", "https":
            443
        default:
            80
        }
    }
}

public enum RelayHostLaunchSeedError: Error, Equatable, Sendable {
    case missingEnvironmentValue(String)
    case invalidUUID(String)
    case invalidURL(String)
}
