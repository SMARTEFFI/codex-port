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
    case invalidDuration(String)
}

public struct RelayServiceConfiguration: Equatable, Sendable {
    public var listenHost: String
    public var listenPort: Int
    public var publicBaseURL: URL
    public var storagePath: String
    public var logLevel: String
    public var tlsMode: RelayServiceTLSMode
    public var turnSharedSecret: String?
    public var stunURLs: [String]
    public var turnURLs: [String]
    public var turnCredentialTTL: Duration
    public var webRTCDataChannelLabel: String

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
        turnSharedSecret = Self.nonEmpty(environment["CODEXPORT_RELAY_TURN_SHARED_SECRET"])
            ?? Self.secretFileValue(environment["CODEXPORT_RELAY_TURN_SHARED_SECRET_FILE"])
        stunURLs = Self.splitURLs(environment["CODEXPORT_RELAY_STUN_URLS"])
        if stunURLs.isEmpty, let host = publicBaseURL.host {
            stunURLs = ["stun:\(host):3478"]
        }
        turnURLs = Self.splitURLs(environment["CODEXPORT_RELAY_TURN_URLS"])
        if turnURLs.isEmpty, let host = publicBaseURL.host {
            turnURLs = [
                "turn:\(host):3478?transport=udp",
                "turn:\(host):3478?transport=tcp",
            ]
        }
        turnCredentialTTL = try Self.parseDuration(
            environment["CODEXPORT_RELAY_TURN_TTL_SECONDS"] ?? "600"
        )
        webRTCDataChannelLabel = Self.nonEmpty(environment["CODEXPORT_RELAY_WEBRTC_DATA_CHANNEL_LABEL"])
            ?? "codexport-client-host"
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

    public func makeICEConfigurationProvider() -> any RelayP2PICEConfigurationProviding {
        guard let turnSharedSecret, !turnURLs.isEmpty else {
            return RelayP2PICEConfigurationProvider.empty
        }
        return CoturnRESTICEConfigurationProvider(
            stunURLs: stunURLs,
            turnURLs: turnURLs,
            sharedSecret: turnSharedSecret,
            ttl: turnCredentialTTL,
            dataChannelLabel: webRTCDataChannelLabel
        )
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

    private static func parseDuration(_ rawValue: String) throws -> Duration {
        guard let seconds = Double(rawValue), seconds > 0 else {
            throw RelayServiceConfigurationError.invalidDuration(rawValue)
        }
        return .milliseconds(Int64(seconds * 1_000))
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

    private static func splitURLs(_ rawValue: String?) -> [String] {
        guard let rawValue else { return [] }
        return rawValue
            .split { character in
                character == "," || character == "\n" || character == " "
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func secretFileValue(_ rawPath: String?) -> String? {
        guard let path = nonEmpty(rawPath),
              let value = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return nil
        }
        return nonEmpty(value)
    }
}
