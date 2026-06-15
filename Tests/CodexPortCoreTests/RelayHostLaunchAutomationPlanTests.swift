import Foundation
import Testing
@testable import CodexPortCore

@Test func relayHostLaunchAutomationPlanEnablesAutoconnectAndAutopromptFromEnvironment() {
    let plan = RelayHostLaunchAutomationPlan(environment: [
        "CODEXPORT_IOS_RELAY_AUTOCONNECT": "1",
        "CODEXPORT_IOS_RELAY_AUTOPROMPT": "issue41 afk prompt",
    ])

    #expect(plan.autoconnect)
    #expect(plan.autoprompt == "issue41 afk prompt")
    #expect(plan.threadID == nil)
}

@Test func relayHostLaunchAutomationPlanTreatsAutopromptAsAutoconnectRequest() {
    let plan = RelayHostLaunchAutomationPlan(environment: [
        "CODEXPORT_IOS_RELAY_AUTOPROMPT": "send immediately",
    ])

    #expect(plan.autoconnect)
    #expect(plan.autoprompt == "send immediately")
}

@Test func relayHostLaunchAutomationPlanCanTargetSpecificThread() {
    let plan = RelayHostLaunchAutomationPlan(environment: [
        "CODEXPORT_IOS_RELAY_THREAD_ID": "019ec4d2-43bc-7150-bd0f-b28161539d66",
    ])

    #expect(plan.autoconnect)
    #expect(plan.autoprompt == nil)
    #expect(plan.threadID == "019ec4d2-43bc-7150-bd0f-b28161539d66")
}

@Test func relayHostLaunchAutomationPlanMatchesOnlySeededRelayHost() throws {
    let seed = try RelayHostLaunchSeed(environment: [
        "CODEXPORT_IOS_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
        "CODEXPORT_IOS_RELAY_HOST_NAME": "Mac Studio Relay",
        "CODEXPORT_IOS_RELAY_HOST_USER": "chenm",
        "CODEXPORT_IOS_RELAY_DEVICE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID": "pairing-record",
        "CODEXPORT_IOS_RELAY_ENDPOINT_URL": "ws://127.0.0.1:7788/v0/streams",
    ])
    let matching = HostProfile(
        id: UUID(),
        connectionMethod: .relay(RelayHost(
            hostAgentID: seed.hostAgentID,
            displayName: seed.displayName,
            userName: seed.userName,
            pairingRecordID: seed.pairingRecordID,
            deviceID: seed.deviceID,
            relayEndpointURL: seed.endpointURL,
            presence: .online(activeConnectionCount: 0),
            diagnosticsSummary: "Ready"
        )),
        name: "Mac Studio Relay",
        host: "127.0.0.1",
        port: 7788,
        username: "chenm",
        auth: .none,
        codexPath: "codex",
        startupCommand: "",
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    var wrongDevice = matching
    wrongDevice.connectionMethod = .relay(RelayHost(
        hostAgentID: seed.hostAgentID,
        displayName: seed.displayName,
        userName: seed.userName,
        pairingRecordID: seed.pairingRecordID,
        deviceID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
        relayEndpointURL: seed.endpointURL,
        presence: .online(activeConnectionCount: 0),
        diagnosticsSummary: "Ready"
    ))
    let plan = RelayHostLaunchAutomationPlan(autoconnect: true, autoprompt: nil)

    #expect(plan.matches(matching, seed: seed))
    #expect(!plan.matches(wrongDevice, seed: seed))
}
