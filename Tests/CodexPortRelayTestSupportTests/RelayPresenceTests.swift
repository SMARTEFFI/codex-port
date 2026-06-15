import Foundation
import Testing
@testable import CodexPortRelayTestSupport
@testable import CodexPortShared

@Test func fakeRelayPropagatesPresenceAcrossDisconnectReconnectAndMultipleAttachments() throws {
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
        id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone B",
        publicKey: EndpointPublicKey(rawValue: Data("iphone-b-public-key".utf8))
    )

    #expect(try relay.registerHostAgent(host) == .online(activeConnectionCount: 0))
    _ = relay.authorize(device: iPhoneA, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 1))
    _ = relay.authorize(device: iPhoneB, forHostID: host.identity.id, pairedAt: Date(timeIntervalSince1970: 2))

    let attachmentA = try relay.attach(device: iPhoneA, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 1))

    let attachmentB = try relay.attach(device: iPhoneB, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 2))

    relay.detach(attachmentA)
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 1))

    let offline = relay.disconnectHostAgent(hostID: host.identity.id, at: Date(timeIntervalSince1970: 100))
    #expect(offline == .offline(lastSeenAt: Date(timeIntervalSince1970: 100)))
    #expect(relay.presence(forHostID: host.identity.id) == .offline(lastSeenAt: Date(timeIntervalSince1970: 100)))

    #expect(try relay.registerHostAgent(host) == .online(activeConnectionCount: 0))
    let reattached = try relay.attach(device: iPhoneB, toHostID: host.identity.id, supportedVersions: [.v0_2_0])
    #expect(reattached.device.identity == attachmentB.device.identity)
    #expect(relay.presence(forHostID: host.identity.id) == .online(activeConnectionCount: 1))
}
