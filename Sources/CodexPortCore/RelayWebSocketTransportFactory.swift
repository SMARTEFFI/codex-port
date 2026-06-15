import Foundation

public struct RelayWebSocketTransportFactory: Sendable {
    public init() {}

    public func makeTransport(for host: RelayHost) -> RelayJSONLTransport? {
        guard let endpointURL = host.relayEndpointURL, let deviceID = host.deviceID else {
            return nil
        }
        return RelayWebSocketJSONLTransport(
            endpointURL: endpointURL,
            hostAgentID: host.hostAgentID,
            deviceID: deviceID,
            pairingRecordID: host.pairingRecordID
        )
    }
}
