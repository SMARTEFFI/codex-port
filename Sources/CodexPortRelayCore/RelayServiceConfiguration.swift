import Foundation

public enum RelayServiceTLSMode: String, Equatable, Sendable {
    case reverseProxy = "reverse-proxy"
    case directTLS = "direct-tls"
    case plainHTTP = "plain-http"
}

public enum RelayServiceConfigurationError: Error, Equatable, Sendable {
    case invalidPort(String)
    case missingPublicBaseURL
    case invalidPublicBaseURL(String)
    case invalidTLSMode(String)
}

public struct RelayServiceConfiguration: Equatable, Sendable {
    public var listenHost: String
    public var listenPort: Int
    public var publicBaseURL: URL
    public var storagePath: String
    public var logLevel: String
    public var tlsMode: RelayServiceTLSMode

    public init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        listenHost = Self.argumentValue("--listen-host", in: arguments)
            ?? environment["CODEXPORT_RELAY_LISTEN_HOST"]
            ?? "127.0.0.1"
        listenPort = try Self.parsePort(
            Self.argumentValue("--port", in: arguments)
                ?? environment["CODEXPORT_RELAY_PORT"]
                ?? "8080"
        )
        guard let rawPublicBaseURL = environment["CODEXPORT_RELAY_PUBLIC_BASE_URL"],
              !rawPublicBaseURL.isEmpty
        else {
            throw RelayServiceConfigurationError.missingPublicBaseURL
        }
        guard let publicBaseURL = URL(string: rawPublicBaseURL),
              let scheme = publicBaseURL.scheme,
              ["http", "https"].contains(scheme),
              publicBaseURL.host != nil
        else {
            throw RelayServiceConfigurationError.invalidPublicBaseURL(rawPublicBaseURL)
        }
        self.publicBaseURL = publicBaseURL
        storagePath = environment["CODEXPORT_RELAY_STORAGE_PATH"] ?? "/var/lib/codexport-relay"
        logLevel = environment["CODEXPORT_RELAY_LOG_LEVEL"] ?? "info"
        let rawTLSMode = environment["CODEXPORT_RELAY_TLS_MODE"] ?? RelayServiceTLSMode.reverseProxy.rawValue
        guard let tlsMode = RelayServiceTLSMode(rawValue: rawTLSMode) else {
            throw RelayServiceConfigurationError.invalidTLSMode(rawTLSMode)
        }
        self.tlsMode = tlsMode
    }

    public var streamEndpointURL: URL {
        websocketURL(path: "/v0/streams")
    }

    public var hostConnectURL: URL {
        websocketURL(path: "/v0/host/connect")
    }

    public var pairingConsumeURL: URL {
        publicBaseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume")
    }

    public var healthURL: URL {
        publicBaseURL.appending(path: "healthz")
    }

    private func websocketURL(path: String) -> URL {
        var components = URLComponents(url: publicBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = path
        return components.url!
    }

    private static func parsePort(_ rawValue: String) throws -> Int {
        guard let port = Int(rawValue), (0...65_535).contains(port) else {
            throw RelayServiceConfigurationError.invalidPort(rawValue)
        }
        return port
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }
}
