import Foundation
import CodexPortShared

public struct HostAgentPairingTokenFactory: Sendable {
    public init() {}

    public func makeManualToken(
        for host: RelayHostIdentity,
        now: Date,
        ttl: TimeInterval,
        id: String,
        manualCode: String
    ) -> PairingToken {
        PairingToken(
            id: id,
            hostID: host.id,
            expiresAt: now.addingTimeInterval(ttl),
            presentation: .manualCode(manualCode)
        )
    }

    public func makeQRToken(
        for host: RelayHostIdentity,
        now: Date,
        ttl: TimeInterval,
        id: String,
        qrPayload: String
    ) -> PairingToken {
        PairingToken(
            id: id,
            hostID: host.id,
            expiresAt: now.addingTimeInterval(ttl),
            presentation: .qrPayload(qrPayload)
        )
    }
}
