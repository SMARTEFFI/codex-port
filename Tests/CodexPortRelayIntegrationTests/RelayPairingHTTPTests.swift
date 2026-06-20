import Foundation
import Testing
@testable import CodexPortRelayCore
@testable import CodexPortShared

@Test func relayGatewayConsumesPublishedPairingTokenOnceForProductionIOSPairing() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    let host = RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    _ = await gateway.registerHost(host)
    try await gateway.publishPairingToken(PairingToken(
        id: "pairing-token-prod",
        hostID: hostID,
        expiresAt: Date(timeIntervalSince1970: 200),
        presentation: .manualCode("123-456")
    ))

    let result = try await gateway.consumePairingToken(
        "123-456",
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        supportedVersions: [.v0_2_0]
    )

    #expect(result.record.id == "pairing-\(hostID.uuidString)-\(deviceID.uuidString)")
    #expect(result.presence == .online(activeConnectionCount: 0))
    await #expect(throws: RelayPairingError.tokenAlreadyUsed(tokenID: "pairing-token-prod")) {
        _ = try await gateway.consumePairingToken(
            "pairing-token-prod",
            device: result.device,
            supportedVersions: [.v0_2_0]
        )
    }
}

@Test func relayGatewayListsPairingRecordsForHostAfterPairing() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    try await gateway.publishPairingToken(PairingToken(
        id: "pairing-token-list",
        hostID: hostID,
        expiresAt: Date(timeIntervalSince1970: 200),
        presentation: .manualCode("123-456")
    ))

    _ = try await gateway.consumePairingToken(
        "123-456",
        device: DeviceIdentity(
            id: deviceID,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        ),
        supportedVersions: [.v0_2_0]
    )

    let records = await gateway.pairingRecords(forHostID: hostID)

    #expect(records == [
        RelayPairedDeviceSummary(
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            pairedAtUnixTime: 100,
            revokedAtUnixTime: nil
        )
    ])
}

@Test func relayGatewayRestoresPairingRecordsForP2PSignalingAfterRestart() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "codexport-relay-state-\(UUID().uuidString)")
    let stateStore = FileRelayAuthenticatedStreamGatewayStateStore(directoryPath: directory.path)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let now = Date(timeIntervalSince1970: 100)
    let host = RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let device = DeviceIdentity(
        id: deviceID,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )
    let firstGateway = RelayAuthenticatedStreamGateway(
        supportedVersions: [.v0_2_0],
        now: { now },
        initialState: try stateStore.load(),
        stateStore: stateStore
    )
    _ = await firstGateway.registerHost(host)
    let pairing = try await firstGateway.authorize(device: device, forHostID: hostID, pairedAt: now)

    let restoredGateway = RelayAuthenticatedStreamGateway(
        supportedVersions: [.v0_2_0],
        now: { Date(timeIntervalSince1970: 200) },
        initialState: try stateStore.load(),
        stateStore: stateStore
    )
    #expect(await restoredGateway.pairingRecords(forHostID: hostID).map(\.pairingRecordID) == [pairing.id])
    #expect(await restoredGateway.p2pPresence(hostID: hostID, deviceID: deviceID).authorization == .hostOffline)

    _ = await restoredGateway.registerHost(host)
    let presence = await restoredGateway.p2pPresence(hostID: hostID, deviceID: deviceID)
    let session = try await restoredGateway.openP2PSession(RelayP2POpenSessionRequest(
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: pairing.id,
        supportedVersions: [.v0_2_0]
    ))

    #expect(presence.authorization == .authorizedToSignal)
    #expect(presence.pairingRecordID == pairing.id)
    #expect(session.pairingRecordID == pairing.id)
}

@Test func relayPublicServiceExposesPairingPublishAndConsumeHTTPEndpoints() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    let publishRequest = RelayPairingPublishRequest(
        tokenID: "pairing-token-http",
        hostID: hostID,
        expiresAtUnixTime: 200,
        manualCode: "123-456",
        hostDisplayName: "Mac Studio",
        hostUserName: "chenm",
        hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
    )
    let publishStatus = try await postJSON(
        publishRequest,
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    ).status
    #expect(publishStatus == 200)

    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "123-456",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )

    #expect(consume.status == 200)
    #expect(consume.body.pairingRecordID == "pairing-\(hostID.uuidString)-\(deviceID.uuidString)")
    #expect(consume.body.hostDisplayName == "Mac Studio")
    #expect(consume.body.activeConnectionCount == 0)

    let secondConsume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "123-456",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume")
    )
    #expect(secondConsume.status == 400)

    await relay.stop()
}

@Test func relayPublicServiceListsPairedDevicesForHostAfterConsume() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    _ = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-list-http",
            hostID: hostID,
            expiresAtUnixTime: 200,
            manualCode: "321-654",
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    )
    _ = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "321-654",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume")
    )

    let response = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "pairings"),
        decode: RelayHostPairingRecordsResponse.self
    )

    #expect(response.status == 200)
    #expect(response.body.devices == [
        RelayPairedDeviceSummary(
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            pairedAtUnixTime: 100,
            revokedAtUnixTime: nil
        )
    ])

    await relay.stop()
}

@Test func relayPublicServiceRevokesPairedDeviceForHost() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    _ = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-revoke-http",
            hostID: hostID,
            expiresAtUnixTime: 200,
            manualCode: "111-222",
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    )
    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "111-222",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )

    let revoke = try await postEmpty(
        to: baseURL
            .appending(path: "v0")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "pairings")
            .appending(path: consume.body.pairingRecordID)
            .appending(path: "revoke")
    )
    let response = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "pairings"),
        decode: RelayHostPairingRecordsResponse.self
    )

    #expect(revoke.status == 200)
    #expect(response.body.devices.first?.revokedAtUnixTime != nil)

    await relay.stop()
}

@Test func relayPublicPairingPublishRegistersHostFromMenuAppRequest() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    let publishStatus = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-menu",
            hostID: hostID,
            expiresAtUnixTime: 200,
            manualCode: "654-321",
            hostDisplayName: "CodexPort Dev Mac",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    ).status

    #expect(publishStatus == 200)

    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "654-321",
            deviceID: deviceID,
            deviceDisplayName: "iPhone 17 Pro",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )

    #expect(consume.status == 200)
    #expect(consume.body.hostDisplayName == "CodexPort Dev Mac")
    #expect(consume.body.hostUserName == "chenm")
    #expect(consume.body.pairingRecordID == "pairing-\(hostID.uuidString)-\(deviceID.uuidString)")

    await relay.stop()
}

@Test func relayPublicServiceExposesP2PSignalingHTTPEndpointsBackedByPairingRecords() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    _ = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-p2p",
            hostID: hostID,
            expiresAtUnixTime: 200,
            manualCode: "222-333",
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    )
    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "222-333",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )
    let presence = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "presence")
            .appending(queryItems: [
                URLQueryItem(name: "deviceID", value: deviceID.uuidString),
            ]),
        decode: RelayP2PPresenceResponse.self
    )
    let open = try await postJSON(
        RelayP2POpenSessionRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: consume.body.pairingRecordID,
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: "open"),
        decode: RelayP2POpenSessionResponse.self
    )
    let offer = RelayP2PSignalingMessageDTO(
        from: .device,
        to: .host,
        kind: .offer,
        payload: "sdp-offer-no-client-host-payload"
    )
    let send = try await postJSON(
        RelayP2PSendMessageRequest(message: offer),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: open.body.sessionID.uuidString)
            .appending(path: "messages")
            .appending(path: "send")
    )
    let hostDrain = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: open.body.sessionID.uuidString)
            .appending(path: "messages")
            .appending(queryItems: [
                URLQueryItem(name: "endpoint", value: "host"),
            ]),
        decode: RelayP2PDrainMessagesResponse.self
    )
    let noStoreDrain = try await getData(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: open.body.sessionID.uuidString)
            .appending(path: "messages")
            .appending(queryItems: [
                URLQueryItem(name: "endpoint", value: "device"),
            ])
    )
    let hostWideDrainAfterSessionDrain = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "messages"),
        decode: RelayP2PDrainHostMessagesResponse.self
    )

    #expect(presence.status == 200)
    #expect(presence.body.presence == .online)
    #expect(presence.body.authorization == .authorizedToSignal)
    #expect(presence.body.pairingRecordID == consume.body.pairingRecordID)
    #expect(open.status == 200)
    #expect(open.body.hostID == hostID)
    #expect(open.body.deviceID == deviceID)
    #expect(open.body.selectedVersion == .v0_2_0)
    #expect(send.status == 200)
    #expect(hostDrain.status == 200)
    #expect(hostDrain.body.messages == [offer])
    #expect(noStoreDrain.status == 200)
    #expect((noStoreDrain.headers["Cache-Control"] as? String) == "no-store")
    #expect((noStoreDrain.headers["Pragma"] as? String) == "no-cache")
    #expect((noStoreDrain.headers["Expires"] as? String) == "0")
    #expect(hostWideDrainAfterSessionDrain.status == 200)
    #expect(hostWideDrainAfterSessionDrain.body.messages.isEmpty)

    await relay.stop()
}

@Test func relayPublicP2PHostMessagesEndpointReturnsSessionMetadataForHostListener() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    _ = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-p2p-host-drain",
            hostID: hostID,
            expiresAtUnixTime: 200,
            manualCode: "777-888",
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    )
    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "777-888",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("device-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )
    let open = try await postJSON(
        RelayP2POpenSessionRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: consume.body.pairingRecordID,
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: "open"),
        decode: RelayP2POpenSessionResponse.self
    )
    let offer = RelayP2PSignalingMessageDTO(
        from: .device,
        to: .host,
        kind: .offer,
        payload: "sdp-offer-for-host-listener"
    )
    _ = try await postJSON(
        RelayP2PSendMessageRequest(message: offer),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: open.body.sessionID.uuidString)
            .appending(path: "messages")
            .appending(path: "send")
    )

    let hostDrain = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "messages"),
        decode: RelayP2PDrainHostMessagesResponse.self
    )
    let secondDrain = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "messages"),
        decode: RelayP2PDrainHostMessagesResponse.self
    )

    #expect(hostDrain.status == 200)
    #expect(hostDrain.body.messages == [
        RelayP2PHostDrainedMessageDTO(session: open.body, message: offer)
    ])
    #expect(secondDrain.status == 200)
    #expect(secondDrain.body.messages.isEmpty)

    await relay.stop()
}

@Test func relayPublicP2PHostPresencePublishRegistersHostForListenerDrain() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    let beforePublish = try await getStatus(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "messages")
    )
    let publish = try await postJSON(
        RelayP2PHostPresencePublishRequest(
            hostID: hostID,
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "presence"),
        decode: RelayP2PHostPresencePublishResponse.self
    )
    let presence = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "presence")
            .appending(queryItems: [
                URLQueryItem(name: "deviceID", value: deviceID.uuidString),
            ]),
        decode: RelayP2PPresenceResponse.self
    )
    let hostDrain = try await getJSON(
        from: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "messages"),
        decode: RelayP2PDrainHostMessagesResponse.self
    )

    #expect(beforePublish == 404)
    #expect(publish.status == 200)
    #expect(publish.body == RelayP2PHostPresencePublishResponse(
        hostID: hostID,
        presence: .online,
        activeConnectionCount: 0
    ))
    #expect(presence.status == 200)
    #expect(presence.body.presence == .online)
    #expect(presence.body.authorization == .signalingReachable)
    #expect(hostDrain.status == 200)
    #expect(hostDrain.body.messages.isEmpty)

    await relay.stop()
}

@Test func relayPublicP2PSignalingRejectsRevokedDeviceBeforeSessionOpen() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    _ = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-p2p-revoke",
            hostID: hostID,
            expiresAtUnixTime: 200,
            manualCode: "333-444",
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    )
    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "333-444",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )
    _ = try await postEmpty(
        to: baseURL
            .appending(path: "v0")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "pairings")
            .appending(path: consume.body.pairingRecordID)
            .appending(path: "revoke")
    )

    let open = try await postJSON(
        RelayP2POpenSessionRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: consume.body.pairingRecordID,
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "sessions")
            .appending(path: "open")
    )

    #expect(open.status == 403)

    await relay.stop()
}

@Test func relayPublicServiceIssuesP2PICEConfigurationOnlyForAuthorizedPairing() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let gateway = RelayAuthenticatedStreamGateway(
        supportedVersions: [.v0_2_0],
        now: { Date(timeIntervalSince1970: 1_000) },
        iceConfigurationProvider: StaticRelayP2PICEConfigurationProvider(
            configuration: WebRTCRuntimeConfiguration(iceServers: [
                WebRTCICEServerConfiguration(urls: ["stun:relay.example.test:3478"]),
                WebRTCICEServerConfiguration(
                    urls: ["turn:relay.example.test:3478?transport=udp"],
                    username: "1600:pairing-record",
                    credential: "short-lived-turn-secret"
                ),
            ]),
            ttl: .seconds(600)
        )
    )
    _ = await gateway.registerHost(RelayHostIdentity(
        id: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    ))
    let relay = RelayPublicWebSocketService(host: "127.0.0.1", port: 0, gateway: gateway)
    let endpoints = try await relay.start()
    let baseURL = URL(string: "http://\(endpoints.streamEndpointURL.host!):\(endpoints.streamEndpointURL.port!)")!

    _ = try await postJSON(
        RelayPairingPublishRequest(
            tokenID: "pairing-token-ice",
            hostID: hostID,
            expiresAtUnixTime: 2_000,
            manualCode: "444-555",
            hostDisplayName: "Mac Studio",
            hostUserName: "chenm",
            hostPublicKeyBase64: Data("host-public-key".utf8).base64EncodedString()
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "publish")
    )
    let consume = try await postJSON(
        RelayPairingConsumeRequest(
            tokenID: "444-555",
            deviceID: deviceID,
            deviceDisplayName: "iPhone A",
            devicePublicKeyBase64: Data("iphone-public-key".utf8).base64EncodedString(),
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL.appending(path: "v0").appending(path: "pairing").appending(path: "consume"),
        decode: RelayPairingConsumeResponse.self
    )

    let ice = try await postJSON(
        RelayP2PICEConfigurationRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: consume.body.pairingRecordID,
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "ice-config"),
        decode: RelayP2PICEConfigurationResponse.self
    )
    _ = try await postEmpty(
        to: baseURL
            .appending(path: "v0")
            .appending(path: "hosts")
            .appending(path: hostID.uuidString)
            .appending(path: "pairings")
            .appending(path: consume.body.pairingRecordID)
            .appending(path: "revoke")
    )
    let revoked = try await postJSON(
        RelayP2PICEConfigurationRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: consume.body.pairingRecordID,
            supportedVersions: [.v0_2_0]
        ),
        to: baseURL
            .appending(path: "v0")
            .appending(path: "p2p")
            .appending(path: "ice-config")
    )

    #expect(ice.status == 200)
    #expect(ice.body.expiresAtUnixTime == 1_600)
    #expect(ice.body.configuration.iceServers[1].username == "1600:pairing-record")
    #expect(ice.body.configuration.iceServers[1].credential == "short-lived-turn-secret")
    #expect(!String(describing: ice.body).contains("short-lived-turn-secret"))
    #expect(revoked.status == 403)

    await relay.stop()
}

private func postJSON<T: Encodable>(_ value: T, to url: URL) async throws -> (status: Int, data: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(value)
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

private func postEmpty(to url: URL) async throws -> (status: Int, data: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

private func postJSON<T: Encodable, U: Decodable>(
    _ value: T,
    to url: URL,
    decode type: U.Type
) async throws -> (status: Int, body: U) {
    let response = try await postJSON(value, to: url)
    return (response.status, try JSONDecoder().decode(U.self, from: response.data))
}

private func getJSON<U: Decodable>(
    from url: URL,
    decode type: U.Type
) async throws -> (status: Int, body: U) {
    let response = try await getData(from: url)
    return (response.status, try JSONDecoder().decode(U.self, from: response.data))
}

private func getData(from url: URL) async throws -> (status: Int, data: Data, headers: [AnyHashable: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let (data, response) = try await URLSession.shared.data(for: request)
    let httpResponse = response as? HTTPURLResponse
    return (httpResponse?.statusCode ?? 0, data, httpResponse?.allHeaderFields ?? [:])
}

private func getStatus(from url: URL) async throws -> Int {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
}
