import Foundation
import CodexPortShared

public enum RelayHostProductionPairingInputError: Error, Equatable, Sendable {
    case invalidRelayEndpoint(String)
    case missingPairingToken
}

public struct RelayPairingScannedMaterial: Equatable, Sendable {
    public var pairingCode: String
    public var hostDisplayName: String?

    public init(pairingCode: String, hostDisplayName: String? = nil) {
        self.pairingCode = pairingCode
        self.hostDisplayName = hostDisplayName
    }

    public static func parse(_ value: String) throws -> RelayPairingScannedMaterial {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.scheme == "codexport",
           url.host == "pair",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryItems = components.queryItems ?? []
            let code = firstNonEmptyQueryValue(named: "code", in: queryItems)
            let token = firstNonEmptyQueryValue(named: "token", in: queryItems)
            guard let pairingCode = code ?? token else {
                throw RelayHostProductionPairingInputError.missingPairingToken
            }
            return RelayPairingScannedMaterial(
                pairingCode: pairingCode,
                hostDisplayName: firstNonEmptyQueryValue(named: "hostName", in: queryItems)
                    ?? firstNonEmptyQueryValue(named: "hostDisplayName", in: queryItems)
            )
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("codexport://") else {
            throw RelayHostProductionPairingInputError.missingPairingToken
        }
        return RelayPairingScannedMaterial(pairingCode: trimmed)
    }

    private static func firstNonEmptyQueryValue(
        named name: String,
        in queryItems: [URLQueryItem]
    ) -> String? {
        queryItems
            .first(where: { $0.name == name })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

public struct RelayHostProductionPairingInput: Equatable, Sendable {
    public static let productionRelayBaseURL = URL(string: "https://codexport.smarteffi.net")!

    public var relayBaseURL: URL
    public var pairingTokenID: String
    public var deviceDisplayName: String

    public init(
        pairingMaterial: String,
        deviceDisplayName: String
    ) throws {
        try self.init(
            relayServerEndpoint: Self.productionRelayBaseURL.absoluteString,
            pairingMaterial: pairingMaterial,
            deviceDisplayName: deviceDisplayName
        )
    }

    public init(
        relayServerEndpoint: String,
        pairingMaterial: String,
        deviceDisplayName: String
    ) throws {
        self.relayBaseURL = try Self.parseRelayBaseURL(relayServerEndpoint)
        self.pairingTokenID = try Self.parsePairingTokenID(pairingMaterial)
        self.deviceDisplayName = deviceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var streamEndpointURL: URL {
        websocketURL(path: "/v0/streams")
    }

    public var pairingConsumeURL: URL {
        relayBaseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume")
    }

    public var safeEndpointSummary: String {
        relayBaseURL.host ?? relayBaseURL.absoluteString
    }

    public func makeHostProfileDraft(
        from result: RelayPairingResult,
        codexPath: String,
        defaultDirectory: String,
        profileName: String? = nil
    ) -> HostProfileDraft {
        RelayHostPairingDraftBuilder().makeHostProfileDraft(
            from: result,
            relayEndpointURL: streamEndpointURL,
            codexPath: codexPath,
            defaultDirectory: defaultDirectory,
            profileName: profileName
        )
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

    private static func parseRelayBaseURL(_ value: String) throws -> URL {
        let rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawValue),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            throw RelayHostProductionPairingInputError.invalidRelayEndpoint(rawValue)
        }
        return url
    }

    private static func parsePairingTokenID(_ value: String) throws -> String {
        try RelayPairingScannedMaterial.parse(value).pairingCode
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
