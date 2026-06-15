import Foundation
import CodexPortShared

public enum RelayHostProductionPairingInputError: Error, Equatable, Sendable {
    case invalidRelayEndpoint(String)
    case missingPairingToken
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.scheme == "codexport",
           url.host == "pair",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
           !token.isEmpty {
            return token
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("codexport://") else {
            throw RelayHostProductionPairingInputError.missingPairingToken
        }
        return trimmed
    }
}
