import Foundation
import Testing
@testable import CodexPortCore

@Test func relayHostLaunchSeedBuildsRelayHostDraftForAFKVerification() throws {
    let seed = try RelayHostLaunchSeed(environment: [
        "CODEXPORT_IOS_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
        "CODEXPORT_IOS_RELAY_HOST_NAME": "Mac Studio Relay",
        "CODEXPORT_IOS_RELAY_HOST_USER": "chenm",
        "CODEXPORT_IOS_RELAY_DEVICE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID": "pairing-record",
        "CODEXPORT_IOS_RELAY_ENDPOINT_URL": "ws://127.0.0.1:7788/v0/streams",
        "CODEXPORT_IOS_RELAY_DEFAULT_DIRECTORY": "~/Projects",
    ])

    let draft = seed.hostProfileDraft()

    #expect(draft.name == "Mac Studio Relay")
    #expect(draft.host == "127.0.0.1")
    #expect(draft.port == 7788)
    #expect(draft.username == "chenm")
    #expect(draft.auth == .none)
    #expect(draft.defaultDirectory == "~/Projects")
    #expect(draft.connectionMethod == .relay(RelayHostDraft(
        hostAgentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio Relay",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        relayEndpointURL: URL(string: "ws://127.0.0.1:7788/v0/streams")!,
        presence: .online(activeConnectionCount: 0),
        diagnosticsSummary: "AFK Relay seed ready"
    )))
}

@Test func relayHostLaunchSeedDefaultsToProductionRelayEndpoint() throws {
    let seed = try RelayHostLaunchSeed(environment: [
        "CODEXPORT_IOS_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
        "CODEXPORT_IOS_RELAY_HOST_NAME": "M5mba",
        "CODEXPORT_IOS_RELAY_HOST_USER": "chenm",
        "CODEXPORT_IOS_RELAY_DEVICE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID": "pairing-record",
    ])

    #expect(seed.endpointURL == URL(string: "wss://codexport.smarteffi.net/v0/streams"))
    #expect(seed.hostProfileDraft().host == "codexport.smarteffi.net")
}
