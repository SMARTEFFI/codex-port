import Foundation
import CodexPortShared

public struct RelayAuthenticatedStreamGatewayState: Codable, Equatable, Sendable {
    public var hosts: [StoredRelayHostIdentity]
    public var devices: [StoredDeviceIdentity]
    public var pairings: [StoredPairingRecord]
    public var usedPairingTokenIDs: [String]

    public init(
        hosts: [StoredRelayHostIdentity] = [],
        devices: [StoredDeviceIdentity] = [],
        pairings: [StoredPairingRecord] = [],
        usedPairingTokenIDs: [String] = []
    ) {
        self.hosts = hosts
        self.devices = devices
        self.pairings = pairings
        self.usedPairingTokenIDs = usedPairingTokenIDs
    }
}

public protocol RelayAuthenticatedStreamGatewayStateStoring: Sendable {
    func load() throws -> RelayAuthenticatedStreamGatewayState
    func save(_ state: RelayAuthenticatedStreamGatewayState) throws
}

public struct NoopRelayAuthenticatedStreamGatewayStateStore: RelayAuthenticatedStreamGatewayStateStoring {
    public init() {}

    public func load() throws -> RelayAuthenticatedStreamGatewayState {
        RelayAuthenticatedStreamGatewayState()
    }

    public func save(_ state: RelayAuthenticatedStreamGatewayState) throws {}
}

public struct FileRelayAuthenticatedStreamGatewayStateStore: RelayAuthenticatedStreamGatewayStateStoring {
    private let directoryURL: URL
    private let fileURL: URL

    public init(directoryPath: String, fileName: String = "relay-state.json") {
        directoryURL = URL(filePath: directoryPath, directoryHint: .isDirectory)
        fileURL = directoryURL.appending(path: fileName, directoryHint: .notDirectory)
    }

    public func load() throws -> RelayAuthenticatedStreamGatewayState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RelayAuthenticatedStreamGatewayState()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RelayAuthenticatedStreamGatewayState.self, from: data)
    }

    public func save(_ state: RelayAuthenticatedStreamGatewayState) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public struct StoredRelayHostIdentity: Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var userName: String
    public var publicKeyBase64: String

    public init(_ host: RelayHostIdentity) {
        id = host.id
        displayName = host.displayName
        userName = host.userName
        publicKeyBase64 = host.publicKey.rawValue.base64EncodedString()
    }

    public var relayHostIdentity: RelayHostIdentity? {
        guard let publicKey = Data(base64Encoded: publicKeyBase64) else {
            return nil
        }
        return RelayHostIdentity(
            id: id,
            displayName: displayName,
            userName: userName,
            publicKey: EndpointPublicKey(rawValue: publicKey)
        )
    }
}

public struct StoredDeviceIdentity: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var id: UUID
    public var displayName: String
    public var kind: String
    public var publicKeyBase64: String

    public init(hostID: UUID, device: DeviceIdentity) {
        self.hostID = hostID
        id = device.id
        displayName = device.displayName
        switch device.kind {
        case .iOSClient:
            kind = "iOSClient"
        case .hostAgent:
            kind = "hostAgent"
        }
        publicKeyBase64 = device.publicKey.rawValue.base64EncodedString()
    }

    public var deviceIdentity: DeviceIdentity? {
        guard let publicKey = Data(base64Encoded: publicKeyBase64) else {
            return nil
        }
        let resolvedKind: DeviceIdentity.Kind
        switch kind {
        case "iOSClient":
            resolvedKind = .iOSClient
        case "hostAgent":
            resolvedKind = .hostAgent
        default:
            return nil
        }
        return DeviceIdentity(
            id: id,
            displayName: displayName,
            kind: resolvedKind,
            publicKey: EndpointPublicKey(rawValue: publicKey)
        )
    }
}

public struct StoredPairingRecord: Codable, Equatable, Sendable {
    public var id: String
    public var hostID: UUID
    public var deviceID: UUID
    public var deviceDisplayName: String
    public var pairedAtUnixTime: TimeInterval
    public var revokedAtUnixTime: TimeInterval?

    public init(_ record: PairingRecord) {
        id = record.id
        hostID = record.hostID
        deviceID = record.deviceID
        deviceDisplayName = record.deviceDisplayName
        pairedAtUnixTime = record.pairedAt.timeIntervalSince1970
        revokedAtUnixTime = record.revokedAt?.timeIntervalSince1970
    }

    public var pairingRecord: PairingRecord {
        PairingRecord(
            id: id,
            hostID: hostID,
            deviceID: deviceID,
            deviceDisplayName: deviceDisplayName,
            pairedAt: Date(timeIntervalSince1970: pairedAtUnixTime),
            revokedAt: revokedAtUnixTime.map(Date.init(timeIntervalSince1970:))
        )
    }
}
