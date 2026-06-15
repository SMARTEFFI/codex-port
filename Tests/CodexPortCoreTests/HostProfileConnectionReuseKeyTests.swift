import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func hostProfileConnectionReuseKeyChangesWhenRelayEndpointChanges() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let hostAgentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let first = relayProfile(id: id, hostAgentID: hostAgentID, endpoint: "wss://relay-a.example.test/v0/streams")
    let second = relayProfile(id: id, hostAgentID: hostAgentID, endpoint: "wss://relay-b.example.test/v0/streams")

    #expect(HostProfileConnectionReuseKey(profile: first) != HostProfileConnectionReuseKey(profile: second))
}

@Test func hostProfileConnectionReuseKeyIgnoresRelayPresenceConnectionCount() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let hostAgentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let first = relayProfile(id: id, hostAgentID: hostAgentID, endpoint: "wss://relay.example.test/v0/streams")
    var second = first
    if case var .relay(host) = second.connectionMethod {
        host.presence = .online(activeConnectionCount: 7)
        second.connectionMethod = .relay(host)
    }

    #expect(HostProfileConnectionReuseKey(profile: first) == HostProfileConnectionReuseKey(profile: second))
}

private func relayProfile(id: UUID, hostAgentID: UUID, endpoint: String) -> HostProfile {
    HostProfile(
        id: id,
        connectionMethod: .relay(
            RelayHost(
                hostAgentID: hostAgentID,
                displayName: "Mac",
                userName: "chenm",
                pairingRecordID: "pairing-1",
                deviceID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
                relayEndpointURL: URL(string: endpoint)!,
                presence: .online(activeConnectionCount: 1),
                diagnosticsSummary: "Ready"
            )
        ),
        name: "Mac Relay",
        host: "relay://\(hostAgentID.uuidString)",
        port: 443,
        username: "chenm",
        auth: .none,
        codexPath: "codex",
        startupCommand: "",
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
}
