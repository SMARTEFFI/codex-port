import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentPairingTokenFactoryCreatesShortLivedManualAndQRMaterials() {
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let factory = HostAgentPairingTokenFactory()

    let manual = factory.makeManualToken(
        for: host,
        now: Date(timeIntervalSince1970: 100),
        ttl: 300,
        id: "token-manual",
        manualCode: "123-456"
    )
    let qr = factory.makeQRToken(
        for: host,
        now: Date(timeIntervalSince1970: 200),
        ttl: 120,
        id: "token-qr",
        qrPayload: "codexport://pair?token=token-qr"
    )

    #expect(manual.id == "token-manual")
    #expect(manual.hostID == host.id)
    #expect(manual.expiresAt == Date(timeIntervalSince1970: 400))
    #expect(manual.pairingMaterial == "123-456")
    #expect(manual.isExpired(at: Date(timeIntervalSince1970: 399)) == false)
    #expect(manual.isExpired(at: Date(timeIntervalSince1970: 400)) == true)
    #expect(qr.id == "token-qr")
    #expect(qr.pairingMaterial == "codexport://pair?token=token-qr")
    #expect(qr.expiresAt == Date(timeIntervalSince1970: 320))
}
