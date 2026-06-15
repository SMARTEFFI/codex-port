import Foundation
import Testing
@testable import CodexPortHostAgentCore

@Test func hostAgentLifecycleStartPauseResumeQuitAndReconnectPlaceholder() {
    var agent = HostAgentLifecycleController()

    #expect(agent.snapshot.status == .offline)
    #expect(agent.snapshot.availableActions == [.start, .quit])

    agent.start()
    #expect(agent.snapshot.status == .running)
    #expect(agent.snapshot.presentation.statusText == "Running")
    #expect(agent.snapshot.availableActions == [.pause, .quit])

    agent.pause()
    #expect(agent.snapshot.status == .paused)
    #expect(agent.snapshot.presentation.statusText == "Paused")
    #expect(agent.snapshot.availableActions == [.resume, .quit])

    agent.resume()
    #expect(agent.snapshot.status == .running)

    agent.markNetworkReconnectPending(reason: "Relay unavailable")
    #expect(agent.snapshot.status == .reconnecting(reason: "Relay unavailable"))
    #expect(agent.snapshot.presentation.statusText == "Reconnecting")
    #expect(agent.snapshot.presentation.detail == "Relay unavailable")

    agent.quit()
    #expect(agent.snapshot.status == .offline)
    #expect(agent.snapshot.availableActions == [.start, .quit])
}

@Test func hostAgentLifecycleAdvertisesLoginItemPlaceholder() {
    let agent = HostAgentLifecycleController()

    #expect(agent.loginItemPlaceholder.title == "Launch at Login")
    #expect(agent.loginItemPlaceholder.isImplemented == false)
    #expect(agent.loginItemPlaceholder.detail == "Login item registration will be wired in the macOS app target.")
}

@Test func hostAgentMenuSnapshotPresentsPairedDevicesInsteadOfSessions() {
    let snapshot = HostAgentMenuSnapshot(
        lifecycle: HostAgentLifecycleController(status: .running).snapshot,
        pairedDevices: [
            HostAgentMenuPairedDevice(
                id: "pairing-record-iphone-a",
                displayName: "iPhone A",
                status: .connected(activeConnectionCount: 1),
                pairedAt: Date(timeIntervalSince1970: 20),
                lastActiveAt: Date(timeIntervalSince1970: 30),
                management: .revoke(pairingRecordID: "pairing-record-iphone-a")
            ),
            HostAgentMenuPairedDevice(
                id: "pairing-record-iphone-b",
                displayName: "iPhone B",
                status: .paired,
                pairedAt: Date(timeIntervalSince1970: 10),
                lastActiveAt: nil,
                management: .revoke(pairingRecordID: "pairing-record-iphone-b")
            ),
        ]
    )

    #expect(snapshot.statusText == "Running")
    #expect(snapshot.deviceSectionTitle == "Paired Devices")
    #expect(snapshot.pairedDevices.map(\.displayName) == ["iPhone A", "iPhone B"])
    #expect(snapshot.pairedDevices.map(\.statusText) == ["Connected · 1 active", "Paired"])
    #expect(snapshot.pairedDevices.map(\.managementTitle) == ["Revoke", "Revoke"])
    #expect(snapshot.availableCommands == [.newPairing, .quit])
}

@Test func hostAgentMenuSnapshotShowsPairedDeviceEmptyState() {
    let snapshot = HostAgentMenuSnapshot(
        lifecycle: HostAgentLifecycleController(status: .offline).snapshot,
        pairedDevices: []
    )

    #expect(snapshot.statusText == "Offline")
    #expect(snapshot.pairedDevices.isEmpty)
    #expect(snapshot.emptyDeviceListText == "尚无已配对设备")
    #expect(snapshot.availableCommands == [.newPairing, .quit])
}

@Test func hostAgentMenuSnapshotPresentsSinglePairedDeviceWithDisabledRevokeManagement() {
    let snapshot = HostAgentMenuSnapshot(
        lifecycle: HostAgentLifecycleController(status: .running).snapshot,
        pairedDevices: [
            HostAgentMenuPairedDevice(
                id: "pairing-record-iphone-solo",
                displayName: "iPhone Solo",
                status: .paired,
                pairedAt: Date(timeIntervalSince1970: 20),
                lastActiveAt: Date(timeIntervalSince1970: 25),
                management: .revoke(pairingRecordID: "pairing-record-iphone-solo")
            ),
        ]
    )

    #expect(snapshot.pairedDevices.count == 1)
    #expect(snapshot.pairedDevices[0].displayName == "iPhone Solo")
    #expect(snapshot.pairedDevices[0].statusText == "Paired")
    #expect(snapshot.pairedDevices[0].managementTitle == "Revoke")
    #expect(snapshot.pairedDevices[0].isManagementEnabled)
}
