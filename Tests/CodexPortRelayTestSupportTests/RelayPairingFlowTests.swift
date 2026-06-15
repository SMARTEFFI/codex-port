import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func fakeRelayConsumesPairingTokenOnceAndCreatesDeviceSpecificPairingRecord() throws {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = makeHost()
    let iPhoneA = makeIPhone(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone A")
    let token = PairingToken(
        id: "pairing-token-a",
        hostID: host.identity.id,
        expiresAt: Date(timeIntervalSince1970: 60),
        presentation: .manualCode("123-456")
    )

    _ = try relay.registerHostAgent(host)
    relay.publishPairingToken(token)

    let result = try relay.consumePairingToken(
        token.id,
        device: iPhoneA,
        supportedVersions: [.v0_2_0],
        at: Date(timeIntervalSince1970: 10)
    )

    #expect(result.tokenID == token.id)
    #expect(result.host == host.identity)
    #expect(result.device == iPhoneA.identity)
    #expect(result.negotiatedVersion == .v0_2_0)
    #expect(result.record.id == "pairing-\(host.identity.id.uuidString)-\(iPhoneA.identity.id.uuidString)")
    #expect(result.record.hostID == host.identity.id)
    #expect(result.record.deviceID == iPhoneA.identity.id)
    #expect(result.record.deviceDisplayName == "iPhone A")
    #expect(result.record.isActive)

    let attachment = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    #expect(attachment.device.identity == iPhoneA.identity)

    #expect(throws: RelayPairingError.tokenAlreadyUsed(tokenID: token.id)) {
        _ = try relay.consumePairingToken(
            token.id,
            device: makeIPhone(id: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone B"),
            supportedVersions: [.v0_2_0],
            at: Date(timeIntervalSince1970: 11)
        )
    }
}

@Test func fakeRelayRejectsExpiredUnknownHostAndVersionMismatchedPairingTokens() throws {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = makeHost()
    let iPhoneA = makeIPhone(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone A")
    _ = try relay.registerHostAgent(host)

    relay.publishPairingToken(
        PairingToken(
            id: "expired-token",
            hostID: host.identity.id,
            expiresAt: Date(timeIntervalSince1970: 10),
            presentation: .manualCode("000-000")
        )
    )
    #expect(throws: RelayPairingError.tokenExpired(tokenID: "expired-token", expiredAt: Date(timeIntervalSince1970: 10))) {
        _ = try relay.consumePairingToken(
            "expired-token",
            device: iPhoneA,
            supportedVersions: [.v0_2_0],
            at: Date(timeIntervalSince1970: 10)
        )
    }

    let unknownHostID = UUID(uuidString: "99999999-2222-3333-4444-555555555555")!
    relay.publishPairingToken(
        PairingToken(
            id: "unknown-host-token",
            hostID: unknownHostID,
            expiresAt: Date(timeIntervalSince1970: 30),
            presentation: .manualCode("111-111")
        )
    )
    #expect(throws: RelayPairingError.unknownHost(hostID: unknownHostID)) {
        _ = try relay.consumePairingToken(
            "unknown-host-token",
            device: iPhoneA,
            supportedVersions: [.v0_2_0],
            at: Date(timeIntervalSince1970: 20)
        )
    }

    relay.publishPairingToken(
        PairingToken(
            id: "version-token",
            hostID: host.identity.id,
            expiresAt: Date(timeIntervalSince1970: 30),
            presentation: .manualCode("222-222")
        )
    )
    #expect(throws: RelayPairingError.versionMismatch(
        clientSupported: [RelayProtocolVersion(major: 1, minor: 0, patch: 0)],
        relaySupported: [.v0_2_0]
    )) {
        _ = try relay.consumePairingToken(
            "version-token",
            device: iPhoneA,
            supportedVersions: [RelayProtocolVersion(major: 1, minor: 0, patch: 0)],
            at: Date(timeIntervalSince1970: 20)
        )
    }
}

@Test func fakeRelayRevokesOnePairedDeviceWithoutAffectingOtherDevices() throws {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = makeHost()
    let iPhoneA = makeIPhone(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone A")
    let iPhoneB = makeIPhone(id: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone B")
    _ = try relay.registerHostAgent(host)

    relay.publishPairingToken(PairingToken(id: "token-a", hostID: host.identity.id, expiresAt: Date(timeIntervalSince1970: 60), presentation: .manualCode("111-111")))
    relay.publishPairingToken(PairingToken(id: "token-b", hostID: host.identity.id, expiresAt: Date(timeIntervalSince1970: 60), presentation: .manualCode("222-222")))
    _ = try relay.consumePairingToken("token-a", device: iPhoneA, supportedVersions: [.v0_2_0], at: Date(timeIntervalSince1970: 10))
    _ = try relay.consumePairingToken("token-b", device: iPhoneB, supportedVersions: [.v0_2_0], at: Date(timeIntervalSince1970: 11))

    let revoked = try relay.revoke(deviceID: iPhoneA.identity.id, forHostID: host.identity.id, at: Date(timeIntervalSince1970: 30))

    #expect(revoked.revokedAt == Date(timeIntervalSince1970: 30))
    #expect(revoked.isActive == false)
    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: host.identity.id, deviceID: iPhoneA.identity.id)) {
        _ = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    }
    let iPhoneBAttachment = try relay.attach(device: iPhoneB, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    #expect(iPhoneBAttachment.device.identity == iPhoneB.identity)
}

private func makeHost() -> FakeHostAgentEndpoint {
    FakeHostAgentEndpoint(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
}

private func makeIPhone(id: String, name: String) -> FakeIOSDeviceEndpoint {
    FakeIOSDeviceEndpoint(
        id: UUID(uuidString: id)!,
        displayName: name,
        publicKey: EndpointPublicKey(rawValue: Data("\(name)-public-key".utf8))
    )
}
