import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public struct RelayAuthorizedStream: Equatable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var deviceID: UUID
    public var pairingRecordID: String
    public var selectedVersion: RelayProtocolVersion
    public var tags: [String: String]

    public init(
        id: UUID,
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        selectedVersion: RelayProtocolVersion,
        tags: [String: String]
    ) {
        self.id = id
        self.hostID = hostID
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.selectedVersion = selectedVersion
        self.tags = tags
    }

    public var clientID: String {
        pairingRecordID
    }

    public var sessionID: String {
        hostID.uuidString
    }
}

public actor RelayAuthenticatedStreamGateway {
    private struct AuthorizationKey: Hashable {
        var hostID: UUID
        var deviceID: UUID
    }

    private enum P2PEndpoint: Hashable {
        case host(UUID)
        case device(UUID)
    }

    private let supportedVersions: [RelayProtocolVersion]
    private let now: @Sendable () -> Date
    private let iceConfigurationProvider: any RelayP2PICEConfigurationProviding
    private let stateStore: any RelayAuthenticatedStreamGatewayStateStoring
    private var hosts: [UUID: RelayHostIdentity] = [:]
    private var devices: [AuthorizationKey: DeviceIdentity] = [:]
    private var authorizations: [AuthorizationKey: PairingRecord] = [:]
    private var pairingTokens: [String: PairingToken] = [:]
    private var usedPairingTokenIDs: Set<String> = []
    private var streams: [UUID: RelayStreamTelemetry] = [:]
    private var p2pSessions: [UUID: RelayP2POpenSessionResponse] = [:]
    private var p2pInboxes: [P2PEndpoint: [UUID: [RelayP2PSignalingMessageDTO]]] = [:]

    public init(
        supportedVersions: [RelayProtocolVersion],
        now: @escaping @Sendable () -> Date = Date.init,
        iceConfigurationProvider: any RelayP2PICEConfigurationProviding = RelayP2PICEConfigurationProvider.empty,
        initialState: RelayAuthenticatedStreamGatewayState = RelayAuthenticatedStreamGatewayState(),
        stateStore: any RelayAuthenticatedStreamGatewayStateStoring = NoopRelayAuthenticatedStreamGatewayStateStore()
    ) {
        self.supportedVersions = supportedVersions
        self.now = now
        self.iceConfigurationProvider = iceConfigurationProvider
        self.stateStore = stateStore
        let restored = Self.restoredDictionaries(from: initialState)
        self.hosts = restored.hosts
        self.devices = restored.devices
        self.authorizations = restored.authorizations
        self.usedPairingTokenIDs = restored.usedPairingTokenIDs
    }

    @discardableResult
    public func registerHost(_ host: RelayHostIdentity) -> RelayHostPresence {
        hosts[host.id] = host
        persistState()
        return .online(activeConnectionCount: activeConnectionCount(forHostID: host.id))
    }

    public func presence(for hostID: UUID) -> RelayHostPresence {
        guard hosts[hostID] != nil else {
            return .offline()
        }
        return .online(activeConnectionCount: activeConnectionCount(forHostID: hostID))
    }

    public func publishPairingToken(_ token: PairingToken) throws {
        guard hosts[token.hostID] != nil else {
            throw RelayPairingError.unknownHost(hostID: token.hostID)
        }
        pairingTokens[token.id] = token
        let material = token.pairingMaterial
        if material != token.id {
            pairingTokens[material] = token
        }
    }

    public func consumePairingToken(
        _ tokenIDOrManualCode: String,
        device: DeviceIdentity,
        supportedVersions: [RelayProtocolVersion],
        at date: Date? = nil
    ) throws -> RelayPairingResult {
        guard let token = pairingTokens[tokenIDOrManualCode] else {
            throw RelayPairingError.tokenNotFound(tokenID: tokenIDOrManualCode)
        }
        guard !usedPairingTokenIDs.contains(token.id) else {
            throw RelayPairingError.tokenAlreadyUsed(tokenID: token.id)
        }
        let date = date ?? now()
        guard !token.isExpired(at: date) else {
            throw RelayPairingError.tokenExpired(tokenID: token.id, expiredAt: token.expiresAt)
        }
        guard let host = hosts[token.hostID] else {
            throw RelayPairingError.unknownHost(hostID: token.hostID)
        }
        let selectedVersion = try negotiateForPairing(device: device, supportedVersions: supportedVersions)
        usedPairingTokenIDs.insert(token.id)
        let record = try authorize(device: device, forHostID: host.id, pairedAt: date)
        return RelayPairingResult(
            tokenID: token.id,
            host: host,
            device: device,
            record: record,
            negotiatedVersion: selectedVersion,
            presence: presence(for: host.id)
        )
    }

    public func authorize(
        device: DeviceIdentity,
        forHostID hostID: UUID,
        pairedAt: Date
    ) throws -> PairingRecord {
        guard hosts[hostID] != nil else {
            throw RelayProtocolError.hostNotRegistered(hostID: hostID)
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
        persistState()
        return record
    }

    public func revoke(deviceID: UUID, forHostID hostID: UUID, at date: Date) throws -> PairingRecord {
        let key = AuthorizationKey(hostID: hostID, deviceID: deviceID)
        guard let record = authorizations[key] else {
            throw RelayPairingError.pairingRecordNotFound(hostID: hostID, deviceID: deviceID)
        }
        let revoked = record.revoked(at: date)
        authorizations[key] = revoked
        persistState()
        return revoked
    }

    public func pairingRecords(forHostID hostID: UUID) -> [RelayPairedDeviceSummary] {
        authorizations.values
            .filter { $0.hostID == hostID }
            .sorted { left, right in
                if left.pairedAt == right.pairedAt {
                    return left.deviceDisplayName.localizedStandardCompare(right.deviceDisplayName) == .orderedAscending
                }
                return left.pairedAt > right.pairedAt
            }
            .map { record in
                RelayPairedDeviceSummary(
                    pairingRecordID: record.id,
                    deviceID: record.deviceID,
                    deviceDisplayName: record.deviceDisplayName,
                    pairedAtUnixTime: record.pairedAt.timeIntervalSince1970,
                    activeConnectionCount: activeConnectionCount(forHostID: record.hostID, deviceID: record.deviceID),
                    revokedAtUnixTime: record.revokedAt?.timeIntervalSince1970
                )
            }
    }

    public func p2pPresence(hostID: UUID, deviceID: UUID) -> RelayP2PPresenceResponse {
        let presence = presence(for: hostID)
        let presenceStatus: RelayP2PPresenceStatus
        let activeConnectionCount: Int
        switch presence {
        case .offline:
            presenceStatus = .offline
            activeConnectionCount = 0
        case let .online(count):
            presenceStatus = .online
            activeConnectionCount = count
        }

        let key = AuthorizationKey(hostID: hostID, deviceID: deviceID)
        let authorization: RelayP2PAuthorizationStatus
        let pairingRecordID: String?
        if hosts[hostID] == nil {
            authorization = .hostOffline
            pairingRecordID = nil
        } else if let record = authorizations[key], record.isActive, devices[key] != nil {
            authorization = .authorizedToSignal
            pairingRecordID = record.id
        } else {
            authorization = .signalingReachable
            pairingRecordID = nil
        }

        return RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: presenceStatus,
            authorization: authorization,
            pairingRecordID: pairingRecordID,
            activeConnectionCount: activeConnectionCount
        )
    }

    public func openP2PSession(_ request: RelayP2POpenSessionRequest) throws -> RelayP2POpenSessionResponse {
        guard hosts[request.hostID] != nil else {
            throw RelayProtocolError.hostNotRegistered(hostID: request.hostID)
        }
        let key = AuthorizationKey(hostID: request.hostID, deviceID: request.deviceID)
        guard let record = authorizations[key],
              record.isActive,
              record.id == request.pairingRecordID,
              devices[key] != nil
        else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: request.hostID, deviceID: request.deviceID)
        }
        let selectedVersion = try negotiateP2P(supportedVersions: request.supportedVersions)
        let response = RelayP2POpenSessionResponse(
            sessionID: UUID(),
            hostID: request.hostID,
            deviceID: request.deviceID,
            pairingRecordID: request.pairingRecordID,
            selectedVersion: selectedVersion,
            openedAtUnixTime: now().timeIntervalSince1970
        )
        p2pSessions[response.sessionID] = response
        return response
    }

    public func issueP2PICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest
    ) throws -> RelayP2PICEConfigurationResponse {
        guard hosts[request.hostID] != nil else {
            throw RelayProtocolError.hostNotRegistered(hostID: request.hostID)
        }
        let key = AuthorizationKey(hostID: request.hostID, deviceID: request.deviceID)
        guard let record = authorizations[key],
              record.isActive,
              record.id == request.pairingRecordID,
              devices[key] != nil
        else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: request.hostID, deviceID: request.deviceID)
        }
        _ = try negotiateP2P(supportedVersions: request.supportedVersions)
        return try iceConfigurationProvider.issueICEConfiguration(
            for: RelayP2PICEConfigurationContext(
                hostID: request.hostID,
                deviceID: request.deviceID,
                pairingRecordID: request.pairingRecordID,
                issuedAt: now()
            )
        )
    }

    public func sendP2PMessage(sessionID: UUID, message: RelayP2PSignalingMessageDTO) throws {
        let session = try activeP2PSession(sessionID: sessionID)
        guard endpoint(message.from, belongsTo: session),
              endpoint(message.to, belongsTo: session)
        else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: session.hostID, deviceID: session.deviceID)
        }
        let endpoint = p2pEndpoint(message.to, session: session)
        var sessionInbox = p2pInboxes[endpoint, default: [:]]
        var messages = sessionInbox[sessionID, default: []]
        messages.append(message)
        sessionInbox[sessionID] = messages
        p2pInboxes[endpoint] = sessionInbox
    }

    public func drainP2PMessages(
        sessionID: UUID,
        endpoint role: RelayP2PSignalingEndpointRole
    ) throws -> RelayP2PDrainMessagesResponse {
        let session = try activeP2PSession(sessionID: sessionID)
        let endpoint = p2pEndpoint(role, session: session)
        let messages = p2pInboxes[endpoint]?[sessionID] ?? []
        p2pInboxes[endpoint]?[sessionID] = []
        return RelayP2PDrainMessagesResponse(messages: messages)
    }

    public func drainP2PHostMessages(hostID: UUID) throws -> RelayP2PDrainHostMessagesResponse {
        guard hosts[hostID] != nil else {
            throw RelayProtocolError.hostNotRegistered(hostID: hostID)
        }
        let endpoint = P2PEndpoint.host(hostID)
        let sessionInbox = p2pInboxes[endpoint] ?? [:]
        var drainedMessages: [RelayP2PHostDrainedMessageDTO] = []
        var retainedInbox: [UUID: [RelayP2PSignalingMessageDTO]] = [:]

        for (sessionID, messages) in sessionInbox {
            guard !messages.isEmpty else { continue }
            do {
                let session = try activeP2PSession(sessionID: sessionID)
                drainedMessages.append(contentsOf: messages.map { message in
                    RelayP2PHostDrainedMessageDTO(session: session, message: message)
                })
            } catch {
                retainedInbox[sessionID] = messages
            }
        }

        p2pInboxes[endpoint] = retainedInbox
        drainedMessages.sort { left, right in
            if left.session.openedAtUnixTime == right.session.openedAtUnixTime {
                return left.session.sessionID.uuidString < right.session.sessionID.uuidString
            }
            return left.session.openedAtUnixTime < right.session.openedAtUnixTime
        }
        return RelayP2PDrainHostMessagesResponse(messages: drainedMessages)
    }

    public func openWebSocketStream(from request: URLRequest) throws -> RelayAuthorizedStream {
        let openRequest = try RelayStreamOpenRequestWebSocketCodec.decode(from: request)
        return try openStream(openRequest)
    }

    public func openStream(_ request: RelayStreamOpenRequest) throws -> RelayAuthorizedStream {
        guard hosts[request.hostID] != nil else {
            throw RelayProtocolError.hostNotRegistered(hostID: request.hostID)
        }
        let key = AuthorizationKey(hostID: request.hostID, deviceID: request.deviceID)
        guard let record = authorizations[key],
              record.isActive,
              record.id == request.pairingRecordID,
              let device = devices[key]
        else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: request.hostID, deviceID: request.deviceID)
        }
        let selectedVersion = try negotiate(endpoint: device, supportedVersions: request.supportedVersions)
        let streamID = UUID()
        streams[streamID] = RelayStreamTelemetry(
            metadata: RelayStreamMetadata(
                hostID: request.hostID,
                deviceID: request.deviceID,
                route: .deviceToHostAgent,
                tags: request.tags,
                openedAt: now(),
                closedAt: nil,
                errorCode: nil
            ),
            deviceToHostByteCount: 0,
            hostToDeviceByteCount: 0
        )
        return RelayAuthorizedStream(
            id: streamID,
            hostID: request.hostID,
            deviceID: request.deviceID,
            pairingRecordID: request.pairingRecordID,
            selectedVersion: selectedVersion,
            tags: request.tags
        )
    }

    public func recordDeviceToHost(streamID: UUID, byteCount: Int) {
        guard var telemetry = streams[streamID] else { return }
        telemetry.deviceToHostByteCount += byteCount
        streams[streamID] = telemetry
    }

    public func recordHostToDevice(streamID: UUID, byteCount: Int) {
        guard var telemetry = streams[streamID] else { return }
        telemetry.hostToDeviceByteCount += byteCount
        streams[streamID] = telemetry
    }

    public func close(streamID: UUID, errorCode: String?) {
        guard var telemetry = streams[streamID] else { return }
        telemetry.metadata.closedAt = now()
        telemetry.metadata.errorCode = errorCode
        streams[streamID] = telemetry
    }

    public func telemetry(for streamID: UUID) -> RelayStreamTelemetry? {
        streams[streamID]
    }

    public func telemetrySnapshot() -> [UUID: RelayStreamTelemetry] {
        streams
    }

    public func persistedStateSnapshot() -> RelayAuthenticatedStreamGatewayState {
        persistedState()
    }

    private func negotiate(endpoint: DeviceIdentity, supportedVersions: [RelayProtocolVersion]) throws -> RelayProtocolVersion {
        let relaySupported = Set(self.supportedVersions)
        if let selected = supportedVersions.filter({ relaySupported.contains($0) }).max() {
            return selected
        }
        throw RelayProtocolError.incompatibleVersion(
            clientSupported: supportedVersions,
            relaySupported: self.supportedVersions
        )
    }

    private func negotiateForPairing(
        device: DeviceIdentity,
        supportedVersions: [RelayProtocolVersion]
    ) throws -> RelayProtocolVersion {
        do {
            return try negotiate(endpoint: device, supportedVersions: supportedVersions)
        } catch let error as RelayProtocolError {
            if case let .incompatibleVersion(clientSupported, relaySupported) = error {
                throw RelayPairingError.versionMismatch(
                    clientSupported: clientSupported,
                    relaySupported: relaySupported
                )
            }
            throw error
        }
    }

    private func negotiateP2P(supportedVersions clientSupported: [RelayProtocolVersion]) throws -> RelayProtocolVersion {
        let relaySupported = Set(self.supportedVersions)
        if let selected = clientSupported.filter({ relaySupported.contains($0) }).max() {
            return selected
        }
        throw RelayProtocolError.incompatibleVersion(
            clientSupported: clientSupported,
            relaySupported: self.supportedVersions
        )
    }

    private func activeP2PSession(sessionID: UUID) throws -> RelayP2POpenSessionResponse {
        guard let session = p2pSessions[sessionID] else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: UUID(), deviceID: UUID())
        }
        let key = AuthorizationKey(hostID: session.hostID, deviceID: session.deviceID)
        guard let record = authorizations[key],
              record.isActive,
              record.id == session.pairingRecordID,
              devices[key] != nil
        else {
            throw RelayProtocolError.deviceNotAuthorized(hostID: session.hostID, deviceID: session.deviceID)
        }
        return session
    }

    private func endpoint(
        _ role: RelayP2PSignalingEndpointRole,
        belongsTo session: RelayP2POpenSessionResponse
    ) -> Bool {
        switch role {
        case .host, .device:
            true
        }
    }

    private func p2pEndpoint(
        _ role: RelayP2PSignalingEndpointRole,
        session: RelayP2POpenSessionResponse
    ) -> P2PEndpoint {
        switch role {
        case .host:
            .host(session.hostID)
        case .device:
            .device(session.deviceID)
        }
    }

    private func activeConnectionCount(forHostID hostID: UUID) -> Int {
        streams.values.filter { telemetry in
            telemetry.metadata.hostID == hostID && telemetry.metadata.closedAt == nil
        }.count
    }

    private func activeConnectionCount(forHostID hostID: UUID, deviceID: UUID) -> Int {
        streams.values.filter { telemetry in
            telemetry.metadata.hostID == hostID
                && telemetry.metadata.deviceID == deviceID
                && telemetry.metadata.closedAt == nil
        }.count
    }

    private static func pairingRecordID(hostID: UUID, deviceID: UUID) -> String {
        "pairing-\(hostID.uuidString)-\(deviceID.uuidString)"
    }

    private static func restoredDictionaries(
        from state: RelayAuthenticatedStreamGatewayState
    ) -> (
        hosts: [UUID: RelayHostIdentity],
        devices: [AuthorizationKey: DeviceIdentity],
        authorizations: [AuthorizationKey: PairingRecord],
        usedPairingTokenIDs: Set<String>
    ) {
        let hosts: [UUID: RelayHostIdentity] = [:]
        var devices: [AuthorizationKey: DeviceIdentity] = [:]
        var authorizations: [AuthorizationKey: PairingRecord] = [:]
        for storedDevice in state.devices {
            guard let device = storedDevice.deviceIdentity else { continue }
            devices[AuthorizationKey(hostID: storedDevice.hostID, deviceID: device.id)] = device
        }
        for storedPairing in state.pairings {
            let record = storedPairing.pairingRecord
            authorizations[AuthorizationKey(hostID: record.hostID, deviceID: record.deviceID)] = record
        }
        return (hosts, devices, authorizations, Set(state.usedPairingTokenIDs))
    }

    private func persistState() {
        do {
            try stateStore.save(persistedState())
        } catch {
        }
    }

    private func persistedState() -> RelayAuthenticatedStreamGatewayState {
        RelayAuthenticatedStreamGatewayState(
            hosts: hosts.values
                .map(StoredRelayHostIdentity.init)
                .sorted { $0.id.uuidString < $1.id.uuidString },
            devices: devices.map { key, device in
                StoredDeviceIdentity(hostID: key.hostID, device: device)
            }
                .sorted {
                    ($0.hostID.uuidString, $0.id.uuidString) < ($1.hostID.uuidString, $1.id.uuidString)
                },
            pairings: authorizations.values
                .map(StoredPairingRecord.init)
                .sorted { $0.id < $1.id },
            usedPairingTokenIDs: usedPairingTokenIDs.sorted()
        )
    }
}
