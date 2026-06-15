import Foundation
import Testing
@testable import CodexPortCore

@Test func relayHostVerificationLaunchURLBuildsSeedAndAutomationPlan() throws {
    let url = URL(string:
        "codexport://verify" +
        "?hostID=11111111-2222-3333-4444-555555555555" +
        "&hostName=Mac%20Studio" +
        "&hostUser=chenm" +
        "&deviceID=CCCCCCCC-DDDD-EEEE-FFFF-000000000001" +
        "&pairingRecordID=pairing-record-a" +
        "&endpointURL=wss%3A%2F%2Frelay.example.test%2Fv0%2Fstreams" +
        "&defaultDirectory=%2FUsers%2Fchenm%2FProjects%2Fcodex-port" +
        "&threadID=019ec4d2-43bc-7150-bd0f-b28161539d66" +
        "&autoprompt=ISSUE74-PHYSICAL-IDLE-TUI-123"
    )!

    let launch = try RelayHostVerificationLaunchURL(url: url)

    #expect(launch.seed.hostAgentID.uuidString == "11111111-2222-3333-4444-555555555555")
    #expect(launch.seed.displayName == "Mac Studio")
    #expect(launch.seed.userName == "chenm")
    #expect(launch.seed.deviceID.uuidString == "CCCCCCCC-DDDD-EEEE-FFFF-000000000001")
    #expect(launch.seed.pairingRecordID == "pairing-record-a")
    #expect(launch.seed.endpointURL == URL(string: "wss://relay.example.test/v0/streams"))
    #expect(launch.seed.defaultDirectory == "/Users/chenm/Projects/codex-port")
    #expect(launch.plan.autoconnect)
    #expect(launch.plan.threadID == "019ec4d2-43bc-7150-bd0f-b28161539d66")
    #expect(launch.plan.autoprompt == "ISSUE74-PHYSICAL-IDLE-TUI-123")
}

@Test func relayHostVerificationLaunchURLDefaultsToProductionEndpoint() throws {
    let url = URL(string:
        "codexport://verify" +
        "?hostID=11111111-2222-3333-4444-555555555555" +
        "&deviceID=CCCCCCCC-DDDD-EEEE-FFFF-000000000001" +
        "&pairingRecordID=pairing-record-a"
    )!

    let launch = try RelayHostVerificationLaunchURL(url: url)

    #expect(launch.seed.endpointURL == URL(string: "wss://codexport.smarteffi.net/v0/streams"))
    #expect(launch.seed.displayName == "CodexPort Host")
    #expect(launch.seed.userName == "codex")
    #expect(launch.seed.defaultDirectory == "~")
    #expect(launch.plan.autoconnect)
}

@Test func relayHostVerificationLaunchURLRejectsUnsupportedURL() {
    #expect(throws: RelayHostVerificationLaunchURLError.unsupportedURL) {
        _ = try RelayHostVerificationLaunchURL(url: URL(string: "https://codexport.smarteffi.net/verify")!)
    }
}

@Test func relayHostVerificationLaunchURLRequiresHostIDDeviceIDAndPairingRecordID() {
    #expect(throws: RelayHostVerificationLaunchURLError.missingQueryItem("deviceID")) {
        _ = try RelayHostVerificationLaunchURL(url: URL(string:
            "codexport://verify" +
            "?hostID=11111111-2222-3333-4444-555555555555" +
            "&pairingRecordID=pairing-record-a"
        )!)
    }
}
