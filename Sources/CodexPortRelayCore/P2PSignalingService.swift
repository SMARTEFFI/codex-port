import Foundation
import CodexPortShared

public enum P2PSignalingEndpoint: Equatable, Hashable, Sendable {
    case host(UUID)
    case device(UUID)
}

public enum P2PSignalingMessageKind: Equatable, Sendable {
    case offer
    case answer
    case iceCandidate
}

public struct P2PSignalingMessage: Equatable, Sendable {
    public var sessionID: UUID
    public var from: P2PSignalingEndpoint
    public var to: P2PSignalingEndpoint
    public var kind: P2PSignalingMessageKind
    public var payload: String

    public init(
        sessionID: UUID,
        from: P2PSignalingEndpoint,
        to: P2PSignalingEndpoint,
        kind: P2PSignalingMessageKind,
        payload: String
    ) {
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.kind = kind
        self.payload = payload
    }
}

public struct P2PSignalingOpenRequest: Equatable, Sendable {
    public var hostID: UUID
    public var deviceID: UUID
    public var pairingRecordID: String
    public var supportedVersions: [RelayProtocolVersion]

    public init(
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        supportedVersions: [RelayProtocolVersion]
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.supportedVersions = supportedVersions
    }
}

public struct P2PSignalingSession: Equatable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var deviceID: UUID
    public var pairingRecordID: String
    public var selectedVersion: RelayProtocolVersion
    public var openedAt: Date

    public init(
        id: UUID,
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        selectedVersion: RelayProtocolVersion,
        openedAt: Date
    ) {
        self.id = id
        self.hostID = hostID
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.selectedVersion = selectedVersion
        self.openedAt = openedAt
    }
}

public enum P2PSignalingError: Error, Equatable, Sendable {
    case hostNotRegistered(hostID: UUID)
    case deviceNotAuthorized(hostID: UUID, deviceID: UUID)
    case incompatibleVersion(clientSupported: [RelayProtocolVersion], signalingSupported: [RelayProtocolVersion])
    case sessionNotFound(sessionID: UUID)
    case endpointNotInSession(endpoint: P2PSignalingEndpoint, sessionID: UUID)
}

public actor P2PSignalingService {
    private struct AuthorizationKey: Hashable {
        var hostID: UUID
        var deviceID: UUID
    }

    private let supportedVersions: [RelayProtocolVersion]
    private let now: @Sendable () -> Date
    private var hosts: [UUID: RelayHostIdentity] = [:]
    private var devices: [AuthorizationKey: DeviceIdentity] = [:]
    private var authorizations: [AuthorizationKey: PairingRecord] = [:]
    private var sessions: [UUID: P2PSignalingSession] = [:]
    private var inboxes: [P2PSignalingEndpoint: [UUID: [P2PSignalingMessage]]] = [:]

    public init(
        supportedVersions: [RelayProtocolVersion],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.supportedVersions = supportedVersions
        self.now = now
    }

    @discardableResult
    public func registerHost(_ host: RelayHostIdentity) -> RelayHostPresence {
        hosts[host.id] = host
        return presence(for: host.id)
    }

    public func presence(for hostID: UUID) -> RelayHostPresence {
        guard hosts[hostID] != nil else {
            return .offline()
        }
        return .online(activeConnectionCount: activeSessionCount(forHostID: hostID))
    }

    public func authorizationState(
        hostID: UUID,
        deviceID: UUID
    ) -> P2PSignalingAuthorizationState {
        guard hosts[hostID] != nil else {
            return .hostOffline
        }

        let key = AuthorizationKey(hostID: hostID, deviceID: deviceID)
        guard let record = authorizations[key],
              record.isActive,
              devices[key] != nil
        else {
            return .signalingReachable
        }

        return .authorizedToSignal(pairingRecordID: record.id)
    }

    public func authorize(
        device: DeviceIdentity,
        forHostID hostID: UUID,
        pairedAt: Date
    ) throws -> PairingRecord {
        guard hosts[hostID] != nil else {
            throw P2PSignalingError.hostNotRegistered(hostID: hostID)
        }
        let key = AuthorizationKey(hostID: hostID, deviceID: device.id)
        let record = PairingRecord(
            id: Self.pairingRecordID(hostID: hostID, deviceID: device.id),
            hostID: hostID,
            deviceID: device.id,
            deviceDisplayName: device.displayName,
            pairedAt: pairedAt,
            revokedAt: nil
        )
        devices[key] = device
        authorizations[key] = record
        return record
    }

    public func revoke(deviceID: UUID, forHostID hostID: UUID, at date: Date) throws -> PairingRecord {
        let key = AuthorizationKey(hostID: hostID, deviceID: deviceID)
        guard let record = authorizations[key] else {
            throw P2PSignalingError.deviceNotAuthorized(hostID: hostID, deviceID: deviceID)
        }
        let revoked = record.revoked(at: date)
        authorizations[key] = revoked
        return revoked
    }

    public func openSession(_ request: P2PSignalingOpenRequest) throws -> P2PSignalingSession {
        guard hosts[request.hostID] != nil else {
            throw P2PSignalingError.hostNotRegistered(hostID: request.hostID)
        }

        let key = AuthorizationKey(hostID: request.hostID, deviceID: request.deviceID)
        guard let record = authorizations[key],
              record.isActive,
              record.id == request.pairingRecordID,
              devices[key] != nil
        else {
            throw P2PSignalingError.deviceNotAuthorized(hostID: request.hostID, deviceID: request.deviceID)
        }

        let selectedVersion = try negotiate(supportedVersions: request.supportedVersions)
        let session = P2PSignalingSession(
            id: UUID(),
            hostID: request.hostID,
            deviceID: request.deviceID,
            pairingRecordID: request.pairingRecordID,
            selectedVersion: selectedVersion,
            openedAt: now()
        )
        sessions[session.id] = session
        return session
    }

    public func send(_ message: P2PSignalingMessage) throws {
        guard let session = sessions[message.sessionID] else {
            throw P2PSignalingError.sessionNotFound(sessionID: message.sessionID)
        }
        try requireActiveAuthorization(for: session)
        guard Self.endpoint(message.from, belongsTo: session),
              Self.endpoint(message.to, belongsTo: session)
        else {
            throw P2PSignalingError.endpointNotInSession(endpoint: message.from, sessionID: message.sessionID)
        }

        var sessionInbox = inboxes[message.to, default: [:]]
        var messages = sessionInbox[message.sessionID, default: []]
        messages.append(message)
        sessionInbox[message.sessionID] = messages
        inboxes[message.to] = sessionInbox
    }

    public func drainMessages(
        for endpoint: P2PSignalingEndpoint,
        sessionID: UUID
    ) -> [P2PSignalingMessage] {
        let messages = inboxes[endpoint]?[sessionID] ?? []
        inboxes[endpoint]?[sessionID] = []
        return messages
    }

    public func plaintextInspectionLog() -> [String] {
        []
    }

    private func negotiate(supportedVersions clientSupported: [RelayProtocolVersion]) throws -> RelayProtocolVersion {
        let signalingSupported = Set(supportedVersions)
        if let selected = clientSupported.filter({ signalingSupported.contains($0) }).max() {
            return selected
        }
        throw P2PSignalingError.incompatibleVersion(
            clientSupported: clientSupported,
            signalingSupported: supportedVersions
        )
    }

    private func activeSessionCount(forHostID hostID: UUID) -> Int {
        sessions.values.filter { $0.hostID == hostID }.count
    }

    private func requireActiveAuthorization(for session: P2PSignalingSession) throws {
        let key = AuthorizationKey(hostID: session.hostID, deviceID: session.deviceID)
        guard let record = authorizations[key],
              record.isActive,
              record.id == session.pairingRecordID,
              devices[key] != nil
        else {
            throw P2PSignalingError.deviceNotAuthorized(hostID: session.hostID, deviceID: session.deviceID)
        }
    }

    private static func endpoint(_ endpoint: P2PSignalingEndpoint, belongsTo session: P2PSignalingSession) -> Bool {
        switch endpoint {
        case let .host(hostID):
            hostID == session.hostID
        case let .device(deviceID):
            deviceID == session.deviceID
        }
    }

    private static func pairingRecordID(hostID: UUID, deviceID: UUID) -> String {
        "pairing-\(hostID.uuidString)-\(deviceID.uuidString)"
    }
}
