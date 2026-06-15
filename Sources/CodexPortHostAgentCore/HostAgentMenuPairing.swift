import Foundation
import CodexPortShared

public enum HostAgentMenuPairingState: Equatable, Sendable {
    case idle
    case ready
    case expired
    case used
    case cancelled
}

public enum HostAgentMenuPairingPresentation: Equatable, Sendable {
    case manualAndQR
}

public struct HostAgentMenuPairingSnapshot: Equatable, Sendable {
    public var state: HostAgentMenuPairingState
    public var tokenID: String?
    public var pairingKey: String?
    public var qrPayload: String?
    public var expiresAt: Date?
    public var hostID: UUID?

    public init(
        state: HostAgentMenuPairingState,
        tokenID: String? = nil,
        pairingKey: String? = nil,
        qrPayload: String? = nil,
        expiresAt: Date? = nil,
        hostID: UUID? = nil
    ) {
        self.state = state
        self.tokenID = tokenID
        self.pairingKey = pairingKey
        self.qrPayload = qrPayload
        self.expiresAt = expiresAt
        self.hostID = hostID
    }

    public static let idle = HostAgentMenuPairingSnapshot(state: .idle)

    public var copyCommandTitle: String {
        "Copy Pairing Key"
    }

    public var refreshCommandTitle: String {
        "Refresh Pairing"
    }

    public var canRefresh: Bool {
        state == .ready
    }

    public var publishRequest: RelayPairingPublishRequest? {
        guard let tokenID, let hostID, let expiresAt else { return nil }
        return RelayPairingPublishRequest(
            tokenID: tokenID,
            hostID: hostID,
            expiresAtUnixTime: expiresAt.timeIntervalSince1970,
            manualCode: pairingKey
        )
    }

    public var accessibilitySummary: String {
        switch state {
        case .idle:
            "New Pairing idle"
        case .ready:
            "New Pairing ready; expires at \(Int(expiresAt?.timeIntervalSince1970 ?? 0))"
        case .expired:
            "New Pairing expired"
        case .used:
            "New Pairing used"
        case .cancelled:
            "New Pairing cancelled"
        }
    }
}

public struct HostAgentMenuPairingCoordinator: Sendable {
    public typealias DateProvider = @Sendable () -> Date
    public typealias TokenIDGenerator = @Sendable () -> String
    public typealias ManualCodeGenerator = @Sendable () -> String

    private let hostID: UUID
    private let now: DateProvider
    private let tokenIDGenerator: TokenIDGenerator
    private let manualCodeGenerator: ManualCodeGenerator
    private var active: HostAgentMenuPairingSnapshot = .idle
    private var generation = 0

    public init(
        hostID: UUID,
        now: @escaping DateProvider = Date.init,
        tokenIDGenerator: @escaping TokenIDGenerator = { "pairing-token-\(UUID().uuidString)" },
        manualCodeGenerator: @escaping ManualCodeGenerator = { String(format: "%03d-%03d", Int.random(in: 0...999), Int.random(in: 0...999)) }
    ) {
        self.hostID = hostID
        self.now = now
        self.tokenIDGenerator = tokenIDGenerator
        self.manualCodeGenerator = manualCodeGenerator
    }

    public var snapshot: HostAgentMenuPairingSnapshot {
        guard active.state == .ready,
              let expiresAt = active.expiresAt,
              now() >= expiresAt
        else {
            return active
        }
        return HostAgentMenuPairingSnapshot(
            state: .expired,
            tokenID: active.tokenID,
            expiresAt: active.expiresAt,
            hostID: active.hostID
        )
    }

    @discardableResult
    public mutating func startNewPairing(
        presentation: HostAgentMenuPairingPresentation,
        timeToLive: TimeInterval = 600
    ) -> HostAgentMenuPairingSnapshot {
        makePairing(presentation: presentation, timeToLive: timeToLive)
    }

    @discardableResult
    public mutating func refreshPairing(
        presentation: HostAgentMenuPairingPresentation,
        timeToLive: TimeInterval = 600
    ) -> HostAgentMenuPairingSnapshot {
        makePairing(presentation: presentation, timeToLive: timeToLive)
    }

    private mutating func makePairing(
        presentation: HostAgentMenuPairingPresentation,
        timeToLive: TimeInterval
    ) -> HostAgentMenuPairingSnapshot {
        generation += 1
        let rawTokenID = tokenIDGenerator()
        let tokenID = generation == 1 ? rawTokenID : "\(rawTokenID)-\(generation)"
        let manualCode = manualCodeGenerator()
        let expiresAt = now().addingTimeInterval(timeToLive)
        let token = PairingToken(
            id: tokenID,
            hostID: hostID,
            expiresAt: expiresAt,
            presentation: .manualCode(manualCode)
        )
        active = HostAgentMenuPairingSnapshot(
            state: .ready,
            tokenID: token.id,
            pairingKey: token.pairingMaterial,
            qrPayload: "codexport://pair?token=\(token.id)",
            expiresAt: expiresAt,
            hostID: hostID
        )
        return active
    }

    public func copyPairingKey() -> String? {
        let current = snapshot
        guard current.state == .ready else { return nil }
        return current.pairingKey
    }

    public mutating func markUsed() {
        active = HostAgentMenuPairingSnapshot(state: .used, tokenID: active.tokenID)
    }

    public mutating func cancel() {
        active = HostAgentMenuPairingSnapshot(state: .cancelled)
    }
}
