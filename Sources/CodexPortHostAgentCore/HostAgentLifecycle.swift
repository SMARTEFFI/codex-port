import Foundation

public enum HostAgentStatus: Equatable, Sendable {
    case offline
    case running
    case paused
    case reconnecting(reason: String)
}

public enum HostAgentAction: Equatable, Sendable {
    case start
    case pause
    case resume
    case quit
}

public struct HostAgentStatusPresentation: Equatable, Sendable {
    public var statusText: String
    public var detail: String

    public init(statusText: String, detail: String = "") {
        self.statusText = statusText
        self.detail = detail
    }
}

public struct HostAgentLifecycleSnapshot: Equatable, Sendable {
    public var status: HostAgentStatus
    public var availableActions: [HostAgentAction]
    public var presentation: HostAgentStatusPresentation

    public init(status: HostAgentStatus, availableActions: [HostAgentAction], presentation: HostAgentStatusPresentation) {
        self.status = status
        self.availableActions = availableActions
        self.presentation = presentation
    }
}

public enum HostAgentMenuCommand: Equatable, Sendable {
    case newPairing
    case quit
}

public enum HostAgentMenuPairedDeviceStatus: Equatable, Sendable {
    case connected(activeConnectionCount: Int)
    case paired
    case revoked
}

public enum HostAgentMenuPairedDeviceManagement: Equatable, Sendable {
    case revoke(pairingRecordID: String)
    case revoked
}

public struct HostAgentMenuPairedDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var status: HostAgentMenuPairedDeviceStatus
    public var pairedAt: Date
    public var lastActiveAt: Date?
    public var management: HostAgentMenuPairedDeviceManagement

    public init(
        id: String,
        displayName: String,
        status: HostAgentMenuPairedDeviceStatus,
        pairedAt: Date,
        lastActiveAt: Date?,
        management: HostAgentMenuPairedDeviceManagement
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.pairedAt = pairedAt
        self.lastActiveAt = lastActiveAt
        self.management = management
    }

    public var statusText: String {
        switch status {
        case let .connected(activeConnectionCount):
            "Connected · \(activeConnectionCount) active"
        case .paired:
            "Paired"
        case .revoked:
            "Revoked"
        }
    }

    public var managementTitle: String {
        switch management {
        case .revoke:
            "Revoke"
        case .revoked:
            "Revoked"
        }
    }

    public var isManagementEnabled: Bool {
        switch management {
        case .revoke:
            true
        case .revoked:
            false
        }
    }
}

public struct HostAgentMenuSnapshot: Equatable, Sendable {
    public var statusText: String
    public var deviceSectionTitle: String
    public var emptyDeviceListText: String
    public var pairedDevices: [HostAgentMenuPairedDevice]
    public var availableCommands: [HostAgentMenuCommand]
    public var pairing: HostAgentMenuPairingSnapshot

    public init(
        lifecycle: HostAgentLifecycleSnapshot,
        pairedDevices: [HostAgentMenuPairedDevice],
        pairing: HostAgentMenuPairingSnapshot = .idle
    ) {
        self.statusText = lifecycle.presentation.statusText
        self.deviceSectionTitle = "Paired Devices"
        self.emptyDeviceListText = "尚无已配对设备"
        self.pairedDevices = pairedDevices.sortedByMostRelevantDevice()
        self.availableCommands = [.newPairing, .quit]
        self.pairing = pairing
    }
}

public struct HostAgentLoginItemPlaceholder: Equatable, Sendable {
    public var title: String
    public var isImplemented: Bool
    public var detail: String

    public init(title: String, isImplemented: Bool, detail: String) {
        self.title = title
        self.isImplemented = isImplemented
        self.detail = detail
    }
}

private extension Array where Element == HostAgentMenuPairedDevice {
    func sortedByMostRelevantDevice() -> [HostAgentMenuPairedDevice] {
        sorted { left, right in
            let leftDate = left.lastActiveAt ?? left.pairedAt
            let rightDate = right.lastActiveAt ?? right.pairedAt
            if leftDate == rightDate {
                return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
            }
            return leftDate > rightDate
        }
    }
}

public struct HostAgentLifecycleController: Sendable {
    private var status: HostAgentStatus

    public init(status: HostAgentStatus = .offline) {
        self.status = status
    }

    public var snapshot: HostAgentLifecycleSnapshot {
        HostAgentLifecycleSnapshot(
            status: status,
            availableActions: availableActions(for: status),
            presentation: presentation(for: status)
        )
    }

    public var loginItemPlaceholder: HostAgentLoginItemPlaceholder {
        HostAgentLoginItemPlaceholder(
            title: "Launch at Login",
            isImplemented: false,
            detail: "Login item registration will be wired in the macOS app target."
        )
    }

    public mutating func start() {
        status = .running
    }

    public mutating func pause() {
        status = .paused
    }

    public mutating func resume() {
        status = .running
    }

    public mutating func markNetworkReconnectPending(reason: String) {
        status = .reconnecting(reason: reason)
    }

    public mutating func quit() {
        status = .offline
    }

    private func availableActions(for status: HostAgentStatus) -> [HostAgentAction] {
        switch status {
        case .offline:
            [.start, .quit]
        case .running:
            [.pause, .quit]
        case .paused:
            [.resume, .quit]
        case .reconnecting:
            [.pause, .quit]
        }
    }

    private func presentation(for status: HostAgentStatus) -> HostAgentStatusPresentation {
        switch status {
        case .offline:
            HostAgentStatusPresentation(statusText: "Offline")
        case .running:
            HostAgentStatusPresentation(statusText: "Running")
        case .paused:
            HostAgentStatusPresentation(statusText: "Paused")
        case let .reconnecting(reason):
            HostAgentStatusPresentation(statusText: "Reconnecting", detail: reason)
        }
    }
}
