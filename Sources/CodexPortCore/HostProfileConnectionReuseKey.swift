import Foundation

public struct HostProfileConnectionReuseKey: Equatable, Sendable {
    public var profileID: UUID
    public var method: Method

    public enum Method: Equatable, Sendable {
        case directSSH(host: String, port: Int, username: String, codexPath: String, startupCommand: String)
        case relay(hostAgentID: UUID, pairingRecordID: String, deviceID: UUID?, relayEndpointURL: URL?)
    }

    public init(profile: HostProfile) {
        profileID = profile.id
        switch profile.connectionMethod {
        case .directSSH:
            method = .directSSH(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                codexPath: profile.codexPath,
                startupCommand: profile.startupCommand
            )
        case let .relay(host):
            method = .relay(
                hostAgentID: host.hostAgentID,
                pairingRecordID: host.pairingRecordID,
                deviceID: host.deviceID,
                relayEndpointURL: host.relayEndpointURL
            )
        }
    }
}
