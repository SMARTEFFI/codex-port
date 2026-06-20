import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentMenuPairingCoordinatorGeneratesQRAndCopyablePairingKey() {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var coordinator = HostAgentMenuPairingCoordinator(
        hostID: hostID,
        now: { Date(timeIntervalSince1970: 1_000) },
        tokenIDGenerator: { "pairing-token-menu" },
        manualCodeGenerator: { "123-456" }
    )

    #expect(coordinator.snapshot.state == .idle)
    let first = coordinator.startNewPairing(presentation: .manualAndQR)

    #expect(first.state == .ready)
    #expect(first.pairingKey == "123-456")
    #expect(first.qrPayload == "codexport://pair?token=pairing-token-menu&code=123-456")
    #expect(first.expiresAt == Date(timeIntervalSince1970: 1_600))
    #expect(first.publishRequest == RelayPairingPublishRequest(
        tokenID: "pairing-token-menu",
        hostID: hostID,
        expiresAtUnixTime: 1_600,
        manualCode: "123-456"
    ))
    #expect(first.copyCommandTitle == "Copy Pairing Key")
    #expect(first.refreshCommandTitle == "Refresh Pairing")
    #expect(first.canRefresh)
    #expect(first.accessibilitySummary == "New Pairing ready; expires at 1600")
    #expect(coordinator.copyPairingKey() == "123-456")

    let second = coordinator.startNewPairing(presentation: .manualAndQR)
    #expect(second.tokenID != first.tokenID)
    #expect(second.state == .ready)
}

@Test func hostAgentMenuPairingCoordinatorRefreshesCurrentPairingTokenAndCopiesLatestKey() {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let clock = HostAgentMenuPairingTestClock(Date(timeIntervalSince1970: 1_000))
    let tokenIDs = HostAgentMenuPairingSequence(["pairing-token-first", "pairing-token-refresh"])
    let manualCodes = HostAgentMenuPairingSequence(["123-456", "789-012"])
    var coordinator = HostAgentMenuPairingCoordinator(
        hostID: hostID,
        now: { clock.now },
        tokenIDGenerator: { tokenIDs.next() ?? "unexpected-token" },
        manualCodeGenerator: { manualCodes.next() ?? "000-000" }
    )

    let first = coordinator.startNewPairing(presentation: .manualAndQR)
    clock.now = Date(timeIntervalSince1970: 1_100)

    let refreshed = coordinator.refreshPairing(presentation: .manualAndQR)

    #expect(refreshed.state == .ready)
    #expect(refreshed.tokenID == "pairing-token-refresh-2")
    #expect(refreshed.tokenID != first.tokenID)
    #expect(refreshed.pairingKey == "789-012")
    #expect(refreshed.qrPayload == "codexport://pair?token=pairing-token-refresh-2&code=789-012")
    #expect(refreshed.expiresAt == Date(timeIntervalSince1970: 1_700))
    #expect(coordinator.copyPairingKey() == "789-012")
}

@Test func hostAgentMenuPairingCoordinatorIncludesHostNameInQRPayload() {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var coordinator = HostAgentMenuPairingCoordinator(
        hostID: hostID,
        hostDisplayName: "Mac Studio",
        now: { Date(timeIntervalSince1970: 1_000) },
        tokenIDGenerator: { "pairing-token-menu" },
        manualCodeGenerator: { "123-456" }
    )

    let snapshot = coordinator.startNewPairing(presentation: .manualAndQR)

    #expect(snapshot.qrPayload == "codexport://pair?token=pairing-token-menu&code=123-456&hostName=Mac%20Studio")
}

@Test func hostAgentMenuPairingCoordinatorMarksExpiredAndCancelledStates() {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let clock = HostAgentMenuPairingTestClock(Date(timeIntervalSince1970: 1_000))
    var coordinator = HostAgentMenuPairingCoordinator(
        hostID: hostID,
        now: { clock.now },
        tokenIDGenerator: { "pairing-token-expiring" },
        manualCodeGenerator: { "654-321" }
    )

    _ = coordinator.startNewPairing(presentation: .manualAndQR)
    clock.now = Date(timeIntervalSince1970: 1_601)

    #expect(coordinator.snapshot.state == .expired)
    #expect(coordinator.copyPairingKey() == nil)

    coordinator.cancel()
    #expect(coordinator.snapshot.state == .cancelled)
    #expect(coordinator.snapshot.pairingKey == nil)
    #expect(coordinator.snapshot.qrPayload == nil)
    #expect(coordinator.snapshot.canRefresh == false)
}

@Test func hostAgentMenuSnapshotIncludesNewPairingCommandBeforeQuit() {
    let snapshot = HostAgentMenuSnapshot(
        lifecycle: HostAgentLifecycleController(status: .running).snapshot,
        pairedDevices: [],
        pairing: .idle
    )

    #expect(snapshot.availableCommands == [.newPairing, .quit])
    #expect(snapshot.pairing.state == .idle)
}

private final class HostAgentMenuPairingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ date: Date) {
        storage = date
    }

    var now: Date {
        get {
            lock.withLock { storage }
        }
        set {
            lock.withLock { storage = newValue }
        }
    }
}

private final class HostAgentMenuPairingSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        lock.withLock {
            guard !values.isEmpty else { return nil }
            return values.removeFirst()
        }
    }
}
