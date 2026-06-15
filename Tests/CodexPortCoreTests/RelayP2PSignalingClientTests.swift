import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayP2PSignalingClientUsesProductionRelayP2PEndpoints() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let httpClient = RelayP2PSignalingRecordingHTTPClient(
        presenceResponse: RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: .online,
            authorization: .authorizedToSignal,
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            activeConnectionCount: 1
        ),
        openResponse: RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        ),
        drainResponse: RelayP2PDrainMessagesResponse(messages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: "sdp-answer"
            )
        ])
    )
    let client = RelayP2PSignalingClient(
        relayBaseURL: URL(string: "https://relay.example.test")!,
        httpClient: httpClient
    )

    let presence = try await client.presence(hostID: hostID, deviceID: deviceID)
    let session = try await client.openSession(
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)"
    )
    try await client.send(
        RelayP2PSignalingMessageDTO(
            from: .device,
            to: .host,
            kind: .offer,
            payload: "sdp-offer"
        ),
        sessionID: sessionID
    )
    let messages = try await client.drainMessages(sessionID: sessionID, endpoint: .device)

    #expect(presence.authorization == .authorizedToSignal)
    #expect(session.sessionID == sessionID)
    #expect(messages == [
        RelayP2PSignalingMessageDTO(
            from: .host,
            to: .device,
            kind: .answer,
            payload: "sdp-answer"
        )
    ])
    #expect(httpClient.presenceURL == URL(string: "https://relay.example.test/v0/p2p/hosts/\(hostID.uuidString)/presence?deviceID=\(deviceID.uuidString)")!)
    #expect(httpClient.openURL == URL(string: "https://relay.example.test/v0/p2p/sessions/open")!)
    #expect(httpClient.openRequest?.pairingRecordID == "pairing-\(hostID.uuidString)-\(deviceID.uuidString)")
    #expect(httpClient.sendURL == URL(string: "https://relay.example.test/v0/p2p/sessions/\(sessionID.uuidString)/messages/send")!)
    #expect(httpClient.sendRequest?.message.kind == .offer)
    #expect(httpClient.drainURL == URL(string: "https://relay.example.test/v0/p2p/sessions/\(sessionID.uuidString)/messages?endpoint=device")!)
}

private final class RelayP2PSignalingRecordingHTTPClient: RelayP2PSignalingHTTPClient, @unchecked Sendable {
    let presenceResponse: RelayP2PPresenceResponse
    let openResponse: RelayP2POpenSessionResponse
    let drainResponse: RelayP2PDrainMessagesResponse
    private(set) var presenceURL: URL?
    private(set) var openURL: URL?
    private(set) var openRequest: RelayP2POpenSessionRequest?
    private(set) var sendURL: URL?
    private(set) var sendRequest: RelayP2PSendMessageRequest?
    private(set) var drainURL: URL?

    init(
        presenceResponse: RelayP2PPresenceResponse,
        openResponse: RelayP2POpenSessionResponse,
        drainResponse: RelayP2PDrainMessagesResponse
    ) {
        self.presenceResponse = presenceResponse
        self.openResponse = openResponse
        self.drainResponse = drainResponse
    }

    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        presenceURL = url
        return presenceResponse
    }

    func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        openRequest = request
        openURL = url
        return openResponse
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        sendRequest = request
        sendURL = url
    }

    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        drainURL = url
        return drainResponse
    }
}
