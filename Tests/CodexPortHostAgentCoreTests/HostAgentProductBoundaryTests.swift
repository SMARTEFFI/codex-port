import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentProductManifestDescribesMacProductWithoutDependingOnIOSUI() {
    let manifest = HostAgentProductManifest.default

    #expect(manifest.productName == "CodexPort Host Agent")
    #expect(manifest.platform == .macOS)
    #expect(manifest.sharedContractVersion == RelayProtocolVersion(major: 0, minor: 2, patch: 0))
    #expect(manifest.dependencies == [.sharedContracts])
}

@Test func sharedRelayContractsDescribeConnectionPairingAndDiagnosticsBoundary() {
    let device = DeviceIdentity(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("ios-public-key".utf8))
    )
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let token = PairingToken(
        id: "pairing-token",
        hostID: host.id,
        expiresAt: Date(timeIntervalSince1970: 100),
        presentation: .manualCode("123-456")
    )
    let record = PairingRecord(
        id: "pairing-record",
        hostID: host.id,
        deviceID: device.id,
        deviceDisplayName: device.displayName,
        pairedAt: Date(timeIntervalSince1970: 1),
        revokedAt: nil
    )

    #expect(ConnectionMethod.directSSH.displayName == "Direct SSH Connection")
    #expect(ConnectionMethod.relay(host).displayName == "Relay Connection")
    #expect(token.isExpired(at: Date(timeIntervalSince1970: 99)) == false)
    #expect(token.isExpired(at: Date(timeIntervalSince1970: 100)) == true)
    #expect(record.isActive)
    #expect(RelayDiagnosticSnapshot(hostPresence: .online(activeConnectionCount: 2)).summary == "Host Agent online (2 clients)")
}
