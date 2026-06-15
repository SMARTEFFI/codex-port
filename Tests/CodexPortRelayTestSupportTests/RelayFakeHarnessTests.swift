import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func relayProtocolNegotiatesHighestSharedVersionAndRejectsIncompatibleClients() throws {
    let relay = FakeRelay(supportedVersions: [
        RelayProtocolVersion(major: 0, minor: 1, patch: 0),
        RelayProtocolVersion(major: 0, minor: 2, patch: 0),
    ])
    let iPhone = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
    )

    let negotiated = try relay.negotiate(
        RelayProtocolNegotiationRequest(
            endpoint: iPhone.identity,
            supportedVersions: [
                RelayProtocolVersion(major: 0, minor: 1, patch: 0),
                RelayProtocolVersion(major: 0, minor: 2, patch: 0),
            ]
        )
    )

    #expect(negotiated.selectedVersion == RelayProtocolVersion(major: 0, minor: 2, patch: 0))
    #expect(negotiated.endpointID == iPhone.identity.id)

    #expect(throws: RelayProtocolError.incompatibleVersion(
        clientSupported: [RelayProtocolVersion(major: 1, minor: 0, patch: 0)],
        relaySupported: [
            RelayProtocolVersion(major: 0, minor: 1, patch: 0),
            RelayProtocolVersion(major: 0, minor: 2, patch: 0),
        ]
    )) {
        _ = try relay.negotiate(
            RelayProtocolNegotiationRequest(
                endpoint: iPhone.identity,
                supportedVersions: [RelayProtocolVersion(major: 1, minor: 0, patch: 0)]
            )
        )
    }
}

@Test func fakeRelayRegistersHostPresenceAndAllowsOnlyAuthorizedDeviceAttach() throws {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = FakeHostAgentEndpoint(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let iPhoneA = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
    )

    #expect(try relay.registerHostAgent(host) == .online(activeConnectionCount: 0))
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 0))

    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: host.identity.id, deviceID: iPhoneA.identity.id)) {
        _ = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    }

    let pairing = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 1))
    #expect(pairing.isActive)

    let attachment = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    #expect(attachment.host.identity == host.identity)
    #expect(attachment.device.identity == iPhoneA.identity)
    #expect(attachment.negotiatedVersion == .v0_2_0)
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 1))

    relay.detach(attachment)
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 0))
}

@Test func fakeRelayRecordsOpaqueStreamTelemetryWithoutPayloadAccess() throws {
    var clock = ManualRelayClock(now: Date(timeIntervalSince1970: 10))
    let relay = FakeRelay(supportedVersions: [.v0_2_0], now: { clock.now })
    let host = FakeHostAgentEndpoint(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let iPhoneA = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
    )

    _ = try relay.registerHostAgent(host)
    _ = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: clock.now)
    let attachment = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    let stream = try relay.openStream(from: attachment, metadata: ["purpose": "codex-app-server-proxy"])

    let userPrompt = Data("secret codex user prompt plaintext".utf8)
    let assistantDelta = Data("secret codex assistant delta plaintext".utf8)
    stream.sendDeviceToHost(.sealedForTests(userPrompt))
    stream.sendHostToDevice(.sealedForTests(assistantDelta))
    clock.advance(by: 3)
    stream.close(errorCode: "host.closed")

    let telemetry = try #require(relay.telemetry(for: stream.id))
    #expect(telemetry.metadata.hostID == host.identity.id)
    #expect(telemetry.metadata.deviceID == iPhoneA.identity.id)
    #expect(telemetry.metadata.route == .deviceToHostAgent)
    #expect(telemetry.metadata.tags == ["purpose": "codex-app-server-proxy"])
    #expect(telemetry.metadata.openedAt == Date(timeIntervalSince1970: 10))
    #expect(telemetry.metadata.closedAt == Date(timeIntervalSince1970: 13))
    #expect(telemetry.metadata.errorCode == "host.closed")
    #expect(telemetry.deviceToHostByteCount == userPrompt.count)
    #expect(telemetry.hostToDeviceByteCount == assistantDelta.count)
    #expect(telemetry.duration == 3)
    #expect(relay.plaintextInspectionLog.isEmpty)
    #expect(relay.debugDescription.contains("secret codex user prompt plaintext") == false)
}

@Test func fakeRelayOnlyOpensStreamsForActivePairingRecordRequests() throws {
    let relay = FakeRelay(supportedVersions: [.v0_2_0])
    let host = FakeHostAgentEndpoint(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let iPhoneA = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
    )
    let iPhoneB = FakeIOSDeviceEndpoint(
        id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
        displayName: "iPhone B",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-b-public-key".utf8))
    )

    _ = try relay.registerHostAgent(host)
    let pairing = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 1))
    let validRequest = RelayStreamOpenRequest(
        hostID: host.identity.id,
        deviceID: iPhoneA.identity.id,
        pairingRecordID: pairing.id,
        supportedVersions: [.v0_2_0],
        tags: ["purpose": "host-agent-jsonl"]
    )

    let stream = try relay.openStream(validRequest)
    let telemetry = try #require(relay.telemetry(for: stream.id))
    #expect(telemetry.metadata.hostID == host.identity.id)
    #expect(telemetry.metadata.deviceID == iPhoneA.identity.id)
    #expect(telemetry.metadata.tags == ["purpose": "host-agent-jsonl"])

    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: host.identity.id, deviceID: iPhoneB.identity.id)) {
        _ = try relay.openStream(RelayStreamOpenRequest(
            hostID: host.identity.id,
            deviceID: iPhoneB.identity.id,
            pairingRecordID: "pairing-\(host.identity.id.uuidString)-\(iPhoneB.identity.id.uuidString)",
            supportedVersions: [.v0_2_0],
            tags: [:]
        ))
    }

    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: host.identity.id, deviceID: iPhoneA.identity.id)) {
        _ = try relay.openStream(RelayStreamOpenRequest(
            hostID: host.identity.id,
            deviceID: iPhoneA.identity.id,
            pairingRecordID: "wrong-pairing-record",
            supportedVersions: [.v0_2_0],
            tags: [:]
        ))
    }

    _ = try relay.revoke(deviceID: iPhoneA.identity.id, forHostID: host.identity.id, at: Date(timeIntervalSince1970: 2))
    #expect(throws: RelayProtocolError.deviceNotAuthorized(hostID: host.identity.id, deviceID: iPhoneA.identity.id)) {
        _ = try relay.openStream(validRequest)
    }
}

private struct ManualRelayClock {
    var now: Date

    mutating func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
