import Foundation
import CodexPortShared

public enum WebRTCRuntimeConfigurationEnvironment {
    public static let productionRelayBaseURL = URL(string: "https://codexport.smarteffi.net")!

    public static let defaultICEServers = [
        WebRTCICEServerConfiguration(urls: ["stun:codexport.smarteffi.net:3478"]),
    ]

    public static func make(
        environment: [String: String],
        defaultDataChannelLabel: String = "codexport-client-host",
        relayBaseURL: URL? = nil
    ) throws -> WebRTCRuntimeConfiguration {
        let label = nonEmpty(environment["CODEXPORT_WEBRTC_DATA_CHANNEL_LABEL"]) ?? defaultDataChannelLabel
        if let json = nonEmpty(environment["CODEXPORT_WEBRTC_ICE_SERVERS_JSON"]) {
            return WebRTCRuntimeConfiguration(
                iceServers: try parseICEServersJSON(json),
                dataChannelLabel: label
            )
        }

        var servers: [WebRTCICEServerConfiguration] = []
        let stunURLs = splitURLs(environment["CODEXPORT_WEBRTC_STUN_URLS"])
        if !stunURLs.isEmpty {
            servers.append(WebRTCICEServerConfiguration(urls: stunURLs))
        }
        let turnURLs = splitURLs(environment["CODEXPORT_WEBRTC_TURN_URLS"])
        if !turnURLs.isEmpty,
           let turnUsername = nonEmpty(environment["CODEXPORT_WEBRTC_TURN_USERNAME"]),
           let turnCredential = nonEmpty(environment["CODEXPORT_WEBRTC_TURN_CREDENTIAL"]) {
            servers.append(WebRTCICEServerConfiguration(
                urls: turnURLs,
                username: turnUsername,
                credential: turnCredential
            ))
        }
        if servers.isEmpty {
            servers = defaultICEServers(for: resolvedRelayBaseURL(environment: environment, explicit: relayBaseURL))
        }
        return WebRTCRuntimeConfiguration(iceServers: servers, dataChannelLabel: label)
    }

    public static func makeOrDefault(
        environment: [String: String],
        defaultDataChannelLabel: String = "codexport-client-host",
        relayBaseURL: URL? = nil
    ) -> WebRTCRuntimeConfiguration {
        (try? make(
            environment: environment,
            defaultDataChannelLabel: defaultDataChannelLabel,
            relayBaseURL: relayBaseURL
        )) ?? WebRTCRuntimeConfiguration(
            iceServers: defaultICEServers(for: resolvedRelayBaseURL(environment: environment, explicit: relayBaseURL)),
            dataChannelLabel: defaultDataChannelLabel
        )
    }

    public static func defaultICEServers(for relayBaseURL: URL?) -> [WebRTCICEServerConfiguration] {
        let host = relayBaseURL?.host ?? productionRelayBaseURL.host ?? "codexport.smarteffi.net"
        return [
            WebRTCICEServerConfiguration(urls: ["stun:\(host):3478"]),
        ]
    }

    private static func parseICEServersJSON(_ rawValue: String) throws -> [WebRTCICEServerConfiguration] {
        guard let data = rawValue.data(using: .utf8) else {
            throw WebRTCRuntimeConfigurationEnvironmentError.invalidICEJSON
        }
        do {
            let servers = try JSONDecoder().decode([WebRTCICEServerConfiguration].self, from: data)
            return servers.filter { !$0.urls.isEmpty }
        } catch {
            throw WebRTCRuntimeConfigurationEnvironmentError.invalidICEJSON
        }
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

    private static func resolvedRelayBaseURL(environment: [String: String], explicit: URL?) -> URL? {
        if let explicit {
            return explicit
        }
        if let rawValue = nonEmpty(environment["CODEXPORT_RELAY_BASE_URL"]),
           let url = URL(string: rawValue),
           url.host != nil {
            return url
        }
        return productionRelayBaseURL
    }
}

public enum WebRTCRuntimeConfigurationEnvironmentError: Error, Equatable, Sendable {
    case invalidICEJSON
}
