import Foundation
import CodexPortShared

public struct RelayHostPairingDraftBuilder: Sendable {
    public init() {}

    public func makeHostProfileDraft(
        from result: RelayPairingResult,
        relayEndpointURL: URL? = nil,
        codexPath: String,
        defaultDirectory: String,
        profileName: String? = nil
    ) -> HostProfileDraft {
        let diagnostics = RelayDiagnosticSnapshot(hostPresence: result.presence).summary
        return HostProfileDraft(
            connectionMethod: .relay(
                RelayHostDraft(
                    hostAgentID: result.host.id,
                    displayName: result.host.displayName,
                    userName: result.host.userName,
                    pairingRecordID: result.record.id,
                    deviceID: result.device.id,
                    relayEndpointURL: relayEndpointURL,
                    presence: result.presence,
                    diagnosticsSummary: diagnostics
                )
            ),
            name: Self.profileName(profileName, fallbackHostDisplayName: result.host.displayName),
            host: "relay://\(result.host.id.uuidString.lowercased())",
            port: 443,
            username: result.host.userName,
            auth: .none,
            codexPath: codexPath,
            startupCommand: "",
            defaultDirectory: defaultDirectory
        )
    }

    private static func profileName(_ profileName: String?, fallbackHostDisplayName: String) -> String {
        let trimmed = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "\(fallbackHostDisplayName) Relay" : trimmed
    }
}
