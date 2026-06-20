import Foundation
import Testing
@testable import CodexPortShared
@testable import CodexPortHostAgentCore

@Test func urlSessionHostAgentP2PSignalingHTTPClientDisablesCachingForSignalingRequests() throws {
    let url = try #require(URL(string: "https://relay.example.test/v0/p2p/hosts/11111111-2222-3333-4444-555555555555/messages"))

    let getRequest = URLSessionHostAgentP2PSignalingHTTPClient.makeRequest(url: url, method: "GET")
    let postRequest = URLSessionHostAgentP2PSignalingHTTPClient.makeRequest(url: url, method: "POST")

    #expect(getRequest.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    #expect(getRequest.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(getRequest.value(forHTTPHeaderField: "Pragma") == "no-cache")
    #expect(postRequest.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    #expect(postRequest.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(postRequest.value(forHTTPHeaderField: "Pragma") == "no-cache")
}

@Test func hostAgentP2PSignalingClientFetchesICEConfigurationFromProductionEndpoint() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let httpClient = HostAgentP2PSignalingRecordingHTTPClient(
        iceConfigurationResponse: RelayP2PICEConfigurationResponse(
            configuration: WebRTCRuntimeConfiguration(iceServers: [
                WebRTCICEServerConfiguration(urls: ["stun:relay.example.test:3478"]),
                WebRTCICEServerConfiguration(
                    urls: ["turn:relay.example.test:3478?transport=udp"],
                    username: "1600:pairing-record",
                    credential: "short-lived-turn-secret"
                ),
            ]),
            expiresAtUnixTime: 1_600
        )
    )
    let client = HostAgentP2PSignalingClient(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        httpClient: httpClient
    )

    let response = try await client.iceConfiguration(
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)"
    )

    #expect(response.expiresAtUnixTime == 1_600)
    #expect(response.configuration.iceServers[1].credential == "short-lived-turn-secret")
    #expect(httpClient.iceConfigurationURL == URL(string: "https://relay.example.test/v0/p2p/ice-config")!)
    #expect(httpClient.iceConfigurationRequest?.hostID == hostID)
    #expect(httpClient.iceConfigurationRequest?.deviceID == deviceID)
    #expect(httpClient.iceConfigurationRequest?.pairingRecordID == "pairing-\(hostID.uuidString)-\(deviceID.uuidString)")
}

private final class HostAgentP2PSignalingRecordingHTTPClient: HostAgentP2PSignalingHTTPClient, @unchecked Sendable {
    let iceConfigurationResponse: RelayP2PICEConfigurationResponse
    private(set) var iceConfigurationURL: URL?
    private(set) var iceConfigurationRequest: RelayP2PICEConfigurationRequest?

    init(iceConfigurationResponse: RelayP2PICEConfigurationResponse) {
        self.iceConfigurationResponse = iceConfigurationResponse
    }

    func publishHostPresence(
        _ request: RelayP2PHostPresencePublishRequest,
        at url: URL
    ) async throws -> RelayP2PHostPresencePublishResponse {
        RelayP2PHostPresencePublishResponse(
            hostID: request.hostID,
            presence: .online,
            activeConnectionCount: 0
        )
    }

    func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse {
        iceConfigurationRequest = request
        iceConfigurationURL = url
        return iceConfigurationResponse
    }

    func drainHostMessages(at url: URL) async throws -> RelayP2PDrainHostMessagesResponse {
        RelayP2PDrainHostMessagesResponse(messages: [])
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {}
}
