import Foundation
import CodexPortShared

public extension RelaySealedPayload {
    static func sealedForTests(_ plaintext: Data) -> RelaySealedPayload {
        RelaySealedPayload(ciphertext: Data(plaintext.reversed()))
    }
}

public struct FakeHostAgentEndpoint: Equatable, Sendable {
    public var identity: RelayHostIdentity

    public init(id: UUID, displayName: String, userName: String, publicKey: EndpointPublicKey) {
        identity = RelayHostIdentity(
            id: id,
            displayName: displayName,
            userName: userName,
            publicKey: publicKey
        )
    }
}

public struct FakeIOSDeviceEndpoint: Equatable, Sendable {
    public var identity: DeviceIdentity

    public init(id: UUID, displayName: String, publicKey: EndpointPublicKey) {
        identity = DeviceIdentity(
            id: id,
            displayName: displayName,
            kind: .iOSClient,
            publicKey: publicKey
        )
    }
}

public struct FakeRelayAttachment: Equatable, Sendable {
    public var id: UUID
    public var host: FakeHostAgentEndpoint
    public var device: FakeIOSDeviceEndpoint
    public var negotiatedVersion: RelayProtocolVersion

    public init(
        id: UUID,
        host: FakeHostAgentEndpoint,
        device: FakeIOSDeviceEndpoint,
        negotiatedVersion: RelayProtocolVersion
    ) {
        self.id = id
        self.host = host
        self.device = device
        self.negotiatedVersion = negotiatedVersion
    }
}

public final class FakeRelay: CustomDebugStringConvertible, @unchecked Sendable {
    public private(set) var plaintextInspectionLog: [String] = []

    private let supportedVersions: [RelayProtocolVersion]
    private let now: () -> Date
    private var hosts: [UUID: FakeHostAgentEndpoint] = [:]
    private var offlineLastSeen: [UUID: Date] = [:]
    private var activeConnectionCounts: [UUID: Int] = [:]
    private var authorizations: [AuthorizationKey: PairingRecord] = [:]
    private var authorizedDevices: [AuthorizationKey: FakeIOSDeviceEndpoint] = [:]
    private var pairingTokens: [String: PairingToken] = [:]
    private var usedPairingTokenIDs: Set<String> = []
    private var streamTelemetry: [UUID: RelayStreamTelemetry] = [:]

    public init(supportedVersions: [RelayProtocolVersion], now: @escaping () -> Date = Date.init) {
        self.supportedVersions = supportedVersions
        self.now = now
    }

    public func negotiate(_ request: RelayProtocolNegotiationRequest) throws -> RelayProtocolNegotiationResult {
        let relaySupported = Set(supportedVersions)
        let selected = request.supportedVersions
            .filter { relaySupported.contains($0) }
            .max()

        guard let selected else {
            throw RelayProtocolError.incompatibleVersion(
                clientSupported: request.supportedVersions,
                relaySupported: supportedVersions
            )
        }

        return RelayProtocolNegotiationResult(endpointID: request.endpoint.id, selectedVersion: selected)
    }

    public func registerHostAgent(_ host: FakeHostAgentEndpoint) throws -> RelayHostPresence {
        hosts[host.identity.id] = host
        offlineLastSeen[host.identity.id] = nil
        activeConnectionCounts[host.identity.id] = activeConnectionCounts[host.identity.id] ?? 0
        return presence(forHostID: host.identity.id)
    }

    public func presence(forHostID hostID: UUID) -> RelayHostPresence {
        guard hosts[hostID] != nil else {
            return .offline(lastSeenAt: offlineLastSeen[hostID])
        }
        return .online(activeConnectionCount: activeConnectionCounts[hostID] ?? 0)
    }

    public func disconnectHostAgent(hostID: UUID, at date: Date) -> RelayHostPresence {
        hosts[hostID] = nil
        activeConnectionCounts[hostID] = 0
        offlineLastSeen[hostID] = date
        return .offline(lastSeenAt: date)
    }

    public func authorize(device: FakeIOSDeviceEndpoint, forHostID hostID: UUID, pairedAt: Date) -> PairingRecord {
        let key = AuthorizationKey(hostID: hostID, deviceID: device.identity.id)
        let record = PairingRecord(
            id: Self.pairingRecordID(hostID: hostID, deviceID: device.identity.id),
            hostID: hostID,
            deviceID: device.identity.id,
            deviceDisplayName: device.identity.displayName,
            pairedAt: pairedAt,
            revokedAt: nil
        )
        authorizations[key] = record
        authorizedDevices[key] = device
        return record
    }

    public func publishPairingToken(_ token: PairingToken) {
        pairingTokens[token.id] = token
    }

    public func consumePairingToken(
        _ tokenID: String,
        device: FakeIOSDeviceEndpoint,
        supportedVersions: [RelayProtocolVersion],
        at date: Date
    ) throws -> RelayPairingResult {
        guard let token = pairingTokens[tokenID] else {
            throw RelayPairingError.tokenNotFound(tokenID: tokenID)
        }
        guard !usedPairingTokenIDs.contains(tokenID) else {
            throw RelayPairingError.tokenAlreadyUsed(tokenID: tokenID)
        }
        guard !token.isExpired(at: date) else {
            throw RelayPairingError.tokenExpired(tokenID: tokenID, expiredAt: token.expiresAt)
        }
        guard let host = hosts[token.hostID] else {
            throw RelayPairingError.unknownHost(hostID: token.hostID)
        }

        let negotiation: RelayProtocolNegotiationResult
        do {
            negotiation = try negotiate(RelayProtocolNegotiationRequest(endpoint: device.identity, supportedVersions: supportedVersions))
        } catch let error as RelayProtocolError {
            if case let .incompatibleVersion(clientSupported, relaySupported) = error {
                throw RelayPairingError.versionMismatch(clientSupported: clientSupported, relaySupported: relaySupported)
            }
            throw error
        }

        usedPairingTokenIDs.insert(tokenID)
        let record = authorize(device: device, forHostID: host.identity.id, pairedAt: date)
        return RelayPairingResult(
            tokenID: tokenID,
            host: host.identity,
            device: device.identity,
            record: record,
            negotiatedVersion: negotiation.selectedVersion,
            presence: presence(forHostID: host.identity.id)
        )
    }

    public func revoke(deviceID: UUID, forHostID hostID: UUID, at date: Date) throws -> PairingRecord {
        let key = AuthorizationKey(hostID: hostID, deviceID: deviceID)
        guard let record = authorizations[key] else {
            throw RelayPairingError.pairingRecordNotFound(hostID: hostID, deviceID: deviceID)
        }
        let revoked = record.revoked(at: date)
        authorizations[key] = revoked
        return revoked
    }

    public func attach(
        device: FakeIOSDeviceEndpoint,
        toHostID hostID: UUID,
        supportedVersions: [RelayProtocolVersion]
    ) throws -> FakeRelayAttachment {
        guard let host = hosts[hostID] else {
            throw RelayProtocolError.hostNotRegistered(hostID: hostID)
        }
        let authorization = AuthorizationKey(hostID: hostID, deviceID: device.identity.id)
        guard authorizations[authorization]?.isActive == true else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: hostID, deviceID: device.identity.id)
        }

        let negotiation = try negotiate(RelayProtocolNegotiationRequest(endpoint: device.identity, supportedVersions: supportedVersions))
        activeConnectionCounts[hostID] = (activeConnectionCounts[hostID] ?? 0) + 1
        return FakeRelayAttachment(
            id: UUID(),
            host: host,
            device: device,
            negotiatedVersion: negotiation.selectedVersion
        )
    }

    public func detach(_ attachment: FakeRelayAttachment) {
        let hostID = attachment.host.identity.id
        activeConnectionCounts[hostID] = max(0, (activeConnectionCounts[hostID] ?? 0) - 1)
    }

    public func openStream(from attachment: FakeRelayAttachment, metadata tags: [String: String]) throws -> FakeRelayStream {
        openAuthorizedStream(
            hostID: attachment.host.identity.id,
            deviceID: attachment.device.identity.id,
            tags: tags
        )
    }

    public func openStream(_ request: RelayStreamOpenRequest) throws -> FakeRelayStream {
        guard hosts[request.hostID] != nil else {
            throw RelayProtocolError.hostNotRegistered(hostID: request.hostID)
        }
        let authorization = AuthorizationKey(hostID: request.hostID, deviceID: request.deviceID)
        guard let record = authorizations[authorization],
              record.isActive,
              record.id == request.pairingRecordID,
              let device = authorizedDevices[authorization]
        else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: request.hostID, deviceID: request.deviceID)
        }
        _ = try negotiate(RelayProtocolNegotiationRequest(
            endpoint: device.identity,
            supportedVersions: request.supportedVersions
        ))
        return openAuthorizedStream(
            hostID: request.hostID,
            deviceID: request.deviceID,
            tags: request.tags
        )
    }

    private func openAuthorizedStream(
        hostID: UUID,
        deviceID: UUID,
        tags: [String: String]
    ) -> FakeRelayStream {
        let streamID = UUID()
        let metadata = RelayStreamMetadata(
            hostID: hostID,
            deviceID: deviceID,
            route: .deviceToHostAgent,
            tags: tags,
            openedAt: now(),
            closedAt: nil,
            errorCode: nil
        )
        streamTelemetry[streamID] = RelayStreamTelemetry(
            metadata: metadata,
            deviceToHostByteCount: 0,
            hostToDeviceByteCount: 0
        )
        return FakeRelayStream(id: streamID, relay: self)
    }

    public func telemetry(for streamID: UUID) -> RelayStreamTelemetry? {
        streamTelemetry[streamID]
    }

    public var debugDescription: String {
        streamTelemetry
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { streamID, telemetry in
                "\(streamID.uuidString): \(telemetry.deviceToHostByteCount)->\(telemetry.hostToDeviceByteCount)"
            }
            .joined(separator: "\n")
    }

    fileprivate func recordDeviceToHost(streamID: UUID, payload: RelaySealedPayload) {
        guard var telemetry = streamTelemetry[streamID] else { return }
        telemetry.deviceToHostByteCount += payload.byteCount
        streamTelemetry[streamID] = telemetry
    }

    fileprivate func recordHostToDevice(streamID: UUID, payload: RelaySealedPayload) {
        guard var telemetry = streamTelemetry[streamID] else { return }
        telemetry.hostToDeviceByteCount += payload.byteCount
        streamTelemetry[streamID] = telemetry
    }

    fileprivate func close(streamID: UUID, errorCode: String?) {
        guard var telemetry = streamTelemetry[streamID] else { return }
        telemetry.metadata.closedAt = now()
        telemetry.metadata.errorCode = errorCode
        streamTelemetry[streamID] = telemetry
    }

    private static func pairingRecordID(hostID: UUID, deviceID: UUID) -> String {
        "pairing-\(hostID.uuidString)-\(deviceID.uuidString)"
    }
}

public final class FakeRelayStream: @unchecked Sendable {
    public let id: UUID

    private let relay: FakeRelay
    private var isClosed = false

    fileprivate init(id: UUID, relay: FakeRelay) {
        self.id = id
        self.relay = relay
    }

    public func sendDeviceToHost(_ payload: RelaySealedPayload) {
        guard !isClosed else { return }
        relay.recordDeviceToHost(streamID: id, payload: payload)
    }

    public func sendHostToDevice(_ payload: RelaySealedPayload) {
        guard !isClosed else { return }
        relay.recordHostToDevice(streamID: id, payload: payload)
    }

    public func close(errorCode: String?) {
        guard !isClosed else { return }
        isClosed = true
        relay.close(streamID: id, errorCode: errorCode)
    }
}

private struct AuthorizationKey: Hashable {
    var hostID: UUID
    var deviceID: UUID
}
