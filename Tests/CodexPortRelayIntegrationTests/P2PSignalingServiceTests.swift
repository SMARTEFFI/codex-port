import Foundation
import Testing
@testable import CodexPortRelayCore
@testable import CodexPortShared

@Test func p2pSignalingRoutesOnlyAuthorizedWebRTCMessagesAndDoesNotInspectSessionPayload() async throws {
    let service = P2PSignalingService(supportedVersions: [.v0_2_0], now: {
        Date(timeIntervalSince1970: 100)
    })
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let device = DeviceIdentity(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )

    #expect(await service.presence(for: host.id) == .offline())
    #expect(await service.authorizationState(hostID: host.id, deviceID: device.id) == .hostOffline)
    #expect(await service.registerHost(host) == .online(activeConnectionCount: 0))
    #expect(await service.authorizationState(hostID: host.id, deviceID: device.id) == .signalingReachable)
    let pairing = try await service.authorize(device: device, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 10))
    #expect(await service.authorizationState(hostID: host.id, deviceID: device.id) == .authorizedToSignal(pairingRecordID: pairing.id))

    let session = try await service.openSession(P2PSignalingOpenRequest(
        hostID: host.id,
        deviceID: device.id,
        pairingRecordID: pairing.id,
        supportedVersions: [.v0_2_0]
    ))

    #expect(session.hostID == host.id)
    #expect(session.deviceID == device.id)
    #expect(session.pairingRecordID == pairing.id)
    #expect(session.selectedVersion == .v0_2_0)
    #expect(await service.presence(for: host.id) == .online(activeConnectionCount: 1))

    try await service.send(P2PSignalingMessage(
        sessionID: session.id,
        from: .device(device.id),
        to: .host(host.id),
        kind: .offer,
        payload: "sdp-offer-without-session-json"
    ))
    try await service.send(P2PSignalingMessage(
        sessionID: session.id,
        from: .host(host.id),
        to: .device(device.id),
        kind: .answer,
        payload: "sdp-answer-without-session-json"
    ))
    try await service.send(P2PSignalingMessage(
        sessionID: session.id,
        from: .device(device.id),
        to: .host(host.id),
        kind: .iceCandidate,
        payload: "candidate:1 udp 2122260223 192.0.2.10 54400 typ host"
    ))

    let hostMessages = await service.drainMessages(for: .host(host.id), sessionID: session.id)
    #expect(hostMessages.map(\.kind) == [.offer, .iceCandidate])
    #expect(hostMessages.first?.payload == "sdp-offer-without-session-json")

    let deviceMessages = await service.drainMessages(for: .device(device.id), sessionID: session.id)
    #expect(deviceMessages.map(\.kind) == [.answer])
    #expect(deviceMessages.first?.payload == "sdp-answer-without-session-json")
    #expect(await service.plaintextInspectionLog().isEmpty)

    _ = try await service.revoke(deviceID: device.id, forHostID: host.id, at: Date(timeIntervalSince1970: 120))
    #expect(await service.authorizationState(hostID: host.id, deviceID: device.id) == .signalingReachable)

    await #expect(throws: P2PSignalingError.deviceNotAuthorized(hostID: host.id, deviceID: device.id)) {
        _ = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: device.id,
            pairingRecordID: pairing.id,
            supportedVersions: [.v0_2_0]
        ))
    }
}

@Test func p2pSignalingRejectsUnknownHostUnknownDeviceAndVersionMismatchBeforeSessionOpen() async throws {
    let service = P2PSignalingService(supportedVersions: [.v0_2_0])
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let device = DeviceIdentity(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )

    await #expect(throws: P2PSignalingError.hostNotRegistered(hostID: host.id)) {
        _ = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: device.id,
            pairingRecordID: "pairing-missing",
            supportedVersions: [.v0_2_0]
        ))
    }

    _ = await service.registerHost(host)
    await #expect(throws: P2PSignalingError.deviceNotAuthorized(hostID: host.id, deviceID: device.id)) {
        _ = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: device.id,
            pairingRecordID: "pairing-missing",
            supportedVersions: [.v0_2_0]
        ))
    }

    let pairing = try await service.authorize(device: device, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 10))
    await #expect(throws: P2PSignalingError.incompatibleVersion(
        clientSupported: [RelayProtocolVersion(major: 9, minor: 9, patch: 9)],
        signalingSupported: [.v0_2_0]
    )) {
        _ = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: device.id,
            pairingRecordID: pairing.id,
            supportedVersions: [RelayProtocolVersion(major: 9, minor: 9, patch: 9)]
        ))
    }
}

@Test func p2pSignalingRevokedDeviceCannotUseExistingSessionForNewWebRTCNegotiation() async throws {
    let service = P2PSignalingService(supportedVersions: [.v0_2_0])
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let device = DeviceIdentity(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )

    _ = await service.registerHost(host)
    let pairing = try await service.authorize(device: device, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 10))
    let session = try await service.openSession(P2PSignalingOpenRequest(
        hostID: host.id,
        deviceID: device.id,
        pairingRecordID: pairing.id,
        supportedVersions: [.v0_2_0]
    ))
    _ = try await service.revoke(deviceID: device.id, forHostID: host.id, at: Date(timeIntervalSince1970: 120))

    await #expect(throws: P2PSignalingError.deviceNotAuthorized(hostID: host.id, deviceID: device.id)) {
        try await service.send(P2PSignalingMessage(
            sessionID: session.id,
            from: .device(device.id),
            to: .host(host.id),
            kind: .offer,
            payload: "stale-offer-after-revoke"
        ))
    }
    #expect(await service.drainMessages(for: .host(host.id), sessionID: session.id).isEmpty)

    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: service,
        session: session
    )
    await #expect(throws: WebRTCDataChannelTransportError.signalingFailed("device not authorized")) {
        try await pair.open()
    }
}
