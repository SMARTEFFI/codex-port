import Foundation
import CodexPortShared

public enum WebRTCRuntimeConfigurationEnvironment {
    public static func make(
        environment: [String: String],
        defaultDataChannelLabel: String = "codexport-client-host"
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
        if !turnURLs.isEmpty {
            servers.append(WebRTCICEServerConfiguration(
                urls: turnURLs,
                username: nonEmpty(environment["CODEXPORT_WEBRTC_TURN_USERNAME"]),
                credential: nonEmpty(environment["CODEXPORT_WEBRTC_TURN_CREDENTIAL"])
            ))
        }
        return WebRTCRuntimeConfiguration(iceServers: servers, dataChannelLabel: label)
    }

    public static func makeOrDefault(
        environment: [String: String],
        defaultDataChannelLabel: String = "codexport-client-host"
    ) -> WebRTCRuntimeConfiguration {
        (try? make(
            environment: environment,
            defaultDataChannelLabel: defaultDataChannelLabel
        )) ?? WebRTCRuntimeConfiguration(iceServers: [], dataChannelLabel: defaultDataChannelLabel)
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
}

public enum WebRTCRuntimeConfigurationEnvironmentError: Error, Equatable, Sendable {
    case invalidICEJSON
}
