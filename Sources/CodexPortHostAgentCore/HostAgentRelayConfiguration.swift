import Foundation
import CodexPortShared

public enum HostAgentRelayConfigurationError: Error, Equatable, Sendable {
    case invalidRelayBaseURL(URL)
}

public struct HostAgentRelayConfiguration: Equatable, Sendable {
    public static let productionRelayBaseURL = URL(string: "https://codexport.smarteffi.net")!

    public var relayBaseURL: URL
    public var host: RelayHostIdentity

    public init(relayBaseURL: URL, host: RelayHostIdentity) throws {
        guard let scheme = relayBaseURL.scheme,
              ["http", "https", "ws", "wss"].contains(scheme),
              relayBaseURL.host != nil
        else {
            throw HostAgentRelayConfigurationError.invalidRelayBaseURL(relayBaseURL)
        }
        self.relayBaseURL = relayBaseURL
        self.host = host
    }

    public var hostConnectURL: URL {
        websocketURL(path: "/v0/host/connect")
    }

    public var streamEndpointURL: URL {
        websocketURL(path: "/v0/streams")
    }

    public var pairingPublishURL: URL {
        httpURL(path: "/v0/pairing/publish")
    }

    public var pairingRecordsURL: URL {
        httpURL(path: "/v0/hosts/\(host.id.uuidString)/pairings")
    }

    public func pairingRecordRevokeURL(recordID: String) -> URL {
        httpURL(path: "/v0/hosts/\(host.id.uuidString)/pairings/\(recordID)/revoke")
    }

    public var diagnosticSummary: String {
        "Relay configured: \(relayBaseURL.host ?? relayBaseURL.absoluteString)"
    }

    private func httpURL(path: String) -> URL {
        var components = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false)!
        switch components.scheme {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        default:
            break
        }
        components.path = path
        return components.url!
    }

    private func websocketURL(path: String) -> URL {
        var components = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false)!
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        components.path = path
        return components.url!
    }
}

public enum HostAgentRelayConnectionState: Equatable, Sendable {
    case notConfigured
    case configured(URL)
    case connecting(URL)
    case online(activeConnectionCount: Int)
    case reconnecting(String)
    case failed(String)

    public var presentation: HostAgentStatusPresentation {
        switch self {
        case .notConfigured:
            HostAgentStatusPresentation(
                statusText: "HostAgent Not Paired",
                detail: "Use New Pairing to pair this Mac with an iPhone."
            )
        case let .configured(url):
            HostAgentStatusPresentation(statusText: "Relay Configured", detail: url.host ?? url.absoluteString)
        case let .connecting(url):
            HostAgentStatusPresentation(statusText: "Relay Connecting", detail: url.host ?? url.absoluteString)
        case let .online(activeConnectionCount):
            HostAgentStatusPresentation(
                statusText: "Relay Online",
                detail: "\(activeConnectionCount) connected devices"
            )
        case let .reconnecting(reason):
            HostAgentStatusPresentation(statusText: "Relay Reconnecting", detail: reason)
        case let .failed(reason):
            HostAgentStatusPresentation(statusText: "Relay Failed", detail: reason)
        }
    }
}
