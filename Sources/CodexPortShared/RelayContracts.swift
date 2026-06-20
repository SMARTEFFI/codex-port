import Foundation

public enum ConnectionMethod: Equatable, Sendable {
    case directSSH
    case relay(RelayHostIdentity)

    public var displayName: String {
        switch self {
        case .directSSH:
            "Direct SSH Connection"
        case .relay:
            "Relay Connection"
        }
    }
}

public struct RelayHostIdentity: Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var userName: String
    public var publicKey: EndpointPublicKey

    public init(id: UUID, displayName: String, userName: String, publicKey: EndpointPublicKey) {
        self.id = id
        self.displayName = displayName
        self.userName = userName
        self.publicKey = publicKey
    }
}

public struct DeviceIdentity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case iOSClient
        case hostAgent
    }

    public var id: UUID
    public var displayName: String
    public var kind: Kind
    public var publicKey: EndpointPublicKey

    public init(id: UUID, displayName: String, kind: Kind, publicKey: EndpointPublicKey) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.publicKey = publicKey
    }
}

public struct EndpointPublicKey: Equatable, Sendable {
    public var rawValue: Data

    public init(rawValue: Data) {
        self.rawValue = rawValue
    }
}

public struct PairingToken: Equatable, Sendable {
    public enum Presentation: Equatable, Sendable {
        case manualCode(String)
        case qrPayload(String)
    }

    public var id: String
    public var hostID: UUID
    public var expiresAt: Date
    public var presentation: Presentation

    public init(id: String, hostID: UUID, expiresAt: Date, presentation: Presentation) {
        self.id = id
        self.hostID = hostID
        self.expiresAt = expiresAt
        self.presentation = presentation
    }

    public func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }

    public var pairingMaterial: String {
        switch presentation {
        case let .manualCode(code):
            code
        case let .qrPayload(payload):
            payload
        }
    }
}

public struct PairingRecord: Equatable, Sendable {
    public var id: String
    public var hostID: UUID
    public var deviceID: UUID
    public var deviceDisplayName: String
    public var pairedAt: Date
    public var revokedAt: Date?

    public init(id: String, hostID: UUID, deviceID: UUID, deviceDisplayName: String, pairedAt: Date, revokedAt: Date?) {
        self.id = id
        self.hostID = hostID
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
    }

    public var isActive: Bool {
        revokedAt == nil
    }

    public func revoked(at date: Date) -> PairingRecord {
        PairingRecord(
            id: id,
            hostID: hostID,
            deviceID: deviceID,
            deviceDisplayName: deviceDisplayName,
            pairedAt: pairedAt,
            revokedAt: date
        )
    }
}

public struct RelayProtocolVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static let v0_2_0 = RelayProtocolVersion(major: 0, minor: 2, patch: 0)

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: RelayProtocolVersion, rhs: RelayProtocolVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum RelayHostPresence: Equatable, Sendable {
    case offline(lastSeenAt: Date? = nil)
    case online(activeConnectionCount: Int)
}

public struct RelayProtocolNegotiationRequest: Equatable, Sendable {
    public var endpoint: DeviceIdentity
    public var supportedVersions: [RelayProtocolVersion]

    public init(endpoint: DeviceIdentity, supportedVersions: [RelayProtocolVersion]) {
        self.endpoint = endpoint
        self.supportedVersions = supportedVersions
    }
}

public struct RelayProtocolNegotiationResult: Equatable, Sendable {
    public var endpointID: UUID
    public var selectedVersion: RelayProtocolVersion

    public init(endpointID: UUID, selectedVersion: RelayProtocolVersion) {
        self.endpointID = endpointID
        self.selectedVersion = selectedVersion
    }
}

public enum RelayProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case incompatibleVersion(clientSupported: [RelayProtocolVersion], relaySupported: [RelayProtocolVersion])
    case hostNotRegistered(hostID: UUID)
    case deviceNotAuthorized(hostID: UUID, deviceID: UUID)

    public var description: String {
        switch self {
        case let .incompatibleVersion(clientSupported, relaySupported):
            "Relay protocol version incompatible. clientSupported=\(clientSupported), relaySupported=\(relaySupported)"
        case let .hostNotRegistered(hostID):
            "Relay Host Agent is not registered: \(hostID)"
        case let .deviceNotAuthorized(hostID, deviceID):
            "Relay device is not authorized. hostID=\(hostID), deviceID=\(deviceID)"
        }
    }
}

public struct RelayPairingResult: Equatable, Sendable {
    public var tokenID: String
    public var host: RelayHostIdentity
    public var device: DeviceIdentity
    public var record: PairingRecord
    public var negotiatedVersion: RelayProtocolVersion
    public var presence: RelayHostPresence

    public init(
        tokenID: String,
        host: RelayHostIdentity,
        device: DeviceIdentity,
        record: PairingRecord,
        negotiatedVersion: RelayProtocolVersion,
        presence: RelayHostPresence
    ) {
        self.tokenID = tokenID
        self.host = host
        self.device = device
        self.record = record
        self.negotiatedVersion = negotiatedVersion
        self.presence = presence
    }
}

public enum RelayPairingError: Error, Equatable, Sendable, CustomStringConvertible {
    case tokenNotFound(tokenID: String)
    case tokenExpired(tokenID: String, expiredAt: Date)
    case tokenAlreadyUsed(tokenID: String)
    case unknownHost(hostID: UUID)
    case versionMismatch(clientSupported: [RelayProtocolVersion], relaySupported: [RelayProtocolVersion])
    case pairingRecordNotFound(hostID: UUID, deviceID: UUID)

    public var description: String {
        switch self {
        case let .tokenNotFound(tokenID):
            "Pairing token not found: \(tokenID)"
        case let .tokenExpired(tokenID, expiredAt):
            "Pairing token expired: \(tokenID) at \(expiredAt)"
        case let .tokenAlreadyUsed(tokenID):
            "Pairing token already used: \(tokenID)"
        case let .unknownHost(hostID):
            "Pairing token references unknown host: \(hostID)"
        case let .versionMismatch(clientSupported, relaySupported):
            "Pairing protocol version mismatch. clientSupported=\(clientSupported), relaySupported=\(relaySupported)"
        case let .pairingRecordNotFound(hostID, deviceID):
            "Pairing record not found. hostID=\(hostID), deviceID=\(deviceID)"
        }
    }
}

public struct RelayPairingConsumeRequest: Codable, Equatable, Sendable {
    public var tokenID: String
    public var deviceID: UUID
    public var deviceDisplayName: String
    public var devicePublicKeyBase64: String
    public var supportedVersions: [RelayProtocolVersion]

    public init(
        tokenID: String,
        deviceID: UUID,
        deviceDisplayName: String,
        devicePublicKeyBase64: String,
        supportedVersions: [RelayProtocolVersion]
    ) {
        self.tokenID = tokenID
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
        self.devicePublicKeyBase64 = devicePublicKeyBase64
        self.supportedVersions = supportedVersions
    }
}

public struct RelayPairingPublishRequest: Codable, Equatable, Sendable {
    public var tokenID: String
    public var hostID: UUID
    public var expiresAtUnixTime: TimeInterval
    public var manualCode: String?
    public var hostDisplayName: String?
    public var hostUserName: String?
    public var hostPublicKeyBase64: String?

    public init(
        tokenID: String,
        hostID: UUID,
        expiresAtUnixTime: TimeInterval,
        manualCode: String? = nil,
        hostDisplayName: String? = nil,
        hostUserName: String? = nil,
        hostPublicKeyBase64: String? = nil
    ) {
        self.tokenID = tokenID
        self.hostID = hostID
        self.expiresAtUnixTime = expiresAtUnixTime
        self.manualCode = manualCode
        self.hostDisplayName = hostDisplayName
        self.hostUserName = hostUserName
        self.hostPublicKeyBase64 = hostPublicKeyBase64
    }
}

public struct RelayPairingConsumeResponse: Codable, Equatable, Sendable {
    public var tokenID: String
    public var hostID: UUID
    public var hostDisplayName: String
    public var hostUserName: String
    public var hostPublicKeyBase64: String
    public var deviceID: UUID
    public var pairingRecordID: String
    public var selectedVersion: RelayProtocolVersion
    public var activeConnectionCount: Int

    public init(
        tokenID: String,
        hostID: UUID,
        hostDisplayName: String,
        hostUserName: String,
        hostPublicKeyBase64: String,
        deviceID: UUID,
        pairingRecordID: String,
        selectedVersion: RelayProtocolVersion,
        activeConnectionCount: Int
    ) {
        self.tokenID = tokenID
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.hostUserName = hostUserName
        self.hostPublicKeyBase64 = hostPublicKeyBase64
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.selectedVersion = selectedVersion
        self.activeConnectionCount = activeConnectionCount
    }
}

public struct RelayPairedDeviceSummary: Codable, Equatable, Sendable {
    public var pairingRecordID: String
    public var deviceID: UUID
    public var deviceDisplayName: String
    public var pairedAtUnixTime: TimeInterval
    public var activeConnectionCount: Int
    public var revokedAtUnixTime: TimeInterval?

    public init(
        pairingRecordID: String,
        deviceID: UUID,
        deviceDisplayName: String,
        pairedAtUnixTime: TimeInterval,
        activeConnectionCount: Int = 0,
        revokedAtUnixTime: TimeInterval?
    ) {
        self.pairingRecordID = pairingRecordID
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
        self.pairedAtUnixTime = pairedAtUnixTime
        self.activeConnectionCount = activeConnectionCount
        self.revokedAtUnixTime = revokedAtUnixTime
    }
}

public struct RelayHostPairingRecordsResponse: Codable, Equatable, Sendable {
    public var devices: [RelayPairedDeviceSummary]

    public init(devices: [RelayPairedDeviceSummary]) {
        self.devices = devices
    }
}

public enum RelayP2PPresenceStatus: String, Codable, Equatable, Sendable {
    case offline
    case online
}

public enum RelayP2PAuthorizationStatus: String, Codable, Equatable, Sendable {
    case hostOffline
    case signalingReachable
    case authorizedToSignal
}

public struct RelayP2PPresenceResponse: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var deviceID: UUID
    public var presence: RelayP2PPresenceStatus
    public var authorization: RelayP2PAuthorizationStatus
    public var pairingRecordID: String?
    public var activeConnectionCount: Int

    public init(
        hostID: UUID,
        deviceID: UUID,
        presence: RelayP2PPresenceStatus,
        authorization: RelayP2PAuthorizationStatus,
        pairingRecordID: String?,
        activeConnectionCount: Int
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.presence = presence
        self.authorization = authorization
        self.pairingRecordID = pairingRecordID
        self.activeConnectionCount = activeConnectionCount
    }
}

public struct RelayP2PHostPresencePublishRequest: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var hostDisplayName: String
    public var hostUserName: String
    public var hostPublicKeyBase64: String

    public init(
        hostID: UUID,
        hostDisplayName: String,
        hostUserName: String,
        hostPublicKeyBase64: String
    ) {
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.hostUserName = hostUserName
        self.hostPublicKeyBase64 = hostPublicKeyBase64
    }
}

public struct RelayP2PHostPresencePublishResponse: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var presence: RelayP2PPresenceStatus
    public var activeConnectionCount: Int

    public init(hostID: UUID, presence: RelayP2PPresenceStatus, activeConnectionCount: Int) {
        self.hostID = hostID
        self.presence = presence
        self.activeConnectionCount = activeConnectionCount
    }
}

public struct RelayP2POpenSessionRequest: Codable, Equatable, Sendable {
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

public struct RelayP2POpenSessionResponse: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var hostID: UUID
    public var deviceID: UUID
    public var pairingRecordID: String
    public var selectedVersion: RelayProtocolVersion
    public var openedAtUnixTime: TimeInterval

    public init(
        sessionID: UUID,
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        selectedVersion: RelayProtocolVersion,
        openedAtUnixTime: TimeInterval
    ) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.selectedVersion = selectedVersion
        self.openedAtUnixTime = openedAtUnixTime
    }
}

public struct RelayP2PICEConfigurationRequest: Codable, Equatable, Sendable {
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

public struct RelayP2PICEConfigurationResponse: Codable, Equatable, Sendable, CustomStringConvertible {
    public var configuration: WebRTCRuntimeConfiguration
    public var expiresAtUnixTime: TimeInterval

    public init(configuration: WebRTCRuntimeConfiguration, expiresAtUnixTime: TimeInterval) {
        self.configuration = configuration
        self.expiresAtUnixTime = expiresAtUnixTime
    }

    public var description: String {
        "RelayP2PICEConfigurationResponse(configuration: \(configuration), expiresAtUnixTime: \(expiresAtUnixTime))"
    }
}

public enum RelayP2PSignalingEndpointRole: String, Codable, Equatable, Sendable {
    case host
    case device
}

public enum RelayP2PSignalingMessageKind: String, Codable, Equatable, Sendable {
    case offer
    case answer
    case iceCandidate
}

public struct RelayP2PSignalingMessageDTO: Codable, Equatable, Sendable {
    public var from: RelayP2PSignalingEndpointRole
    public var to: RelayP2PSignalingEndpointRole
    public var kind: RelayP2PSignalingMessageKind
    public var payload: String

    public init(
        from: RelayP2PSignalingEndpointRole,
        to: RelayP2PSignalingEndpointRole,
        kind: RelayP2PSignalingMessageKind,
        payload: String
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.payload = payload
    }
}

public struct RelayP2PSendMessageRequest: Codable, Equatable, Sendable {
    public var message: RelayP2PSignalingMessageDTO

    public init(message: RelayP2PSignalingMessageDTO) {
        self.message = message
    }
}

public struct RelayP2PDrainMessagesResponse: Codable, Equatable, Sendable {
    public var messages: [RelayP2PSignalingMessageDTO]

    public init(messages: [RelayP2PSignalingMessageDTO]) {
        self.messages = messages
    }
}

public struct RelayP2PHostDrainedMessageDTO: Codable, Equatable, Sendable {
    public var session: RelayP2POpenSessionResponse
    public var message: RelayP2PSignalingMessageDTO

    public init(session: RelayP2POpenSessionResponse, message: RelayP2PSignalingMessageDTO) {
        self.session = session
        self.message = message
    }
}

public struct RelayP2PDrainHostMessagesResponse: Codable, Equatable, Sendable {
    public var messages: [RelayP2PHostDrainedMessageDTO]

    public init(messages: [RelayP2PHostDrainedMessageDTO]) {
        self.messages = messages
    }
}

public struct RelayThreadSummarySnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var cwd: String?
    public var updatedAtUnixTime: TimeInterval
    public var preview: String
    public var gitRepository: String?
    public var gitBranch: String?
    public var status: String

    public init(
        id: String,
        cwd: String?,
        updatedAtUnixTime: TimeInterval,
        preview: String,
        gitRepository: String?,
        gitBranch: String?,
        status: String
    ) {
        self.id = id
        self.cwd = cwd
        self.updatedAtUnixTime = updatedAtUnixTime
        self.preview = preview
        self.gitRepository = gitRepository
        self.gitBranch = gitBranch
        self.status = status
    }
}

public struct RelayThreadListResponse: Codable, Equatable, Sendable {
    public var threads: [RelayThreadSummarySnapshot]
    public var nextCursor: String?

    public init(threads: [RelayThreadSummarySnapshot], nextCursor: String? = nil) {
        self.threads = threads
        self.nextCursor = nextCursor
    }
}

public struct RelayThreadHistorySnapshot: Equatable, Sendable {
    public var threadID: String
    public var items: [RelayThreadHistoryItem]
    public var status: RelayThreadRunStatus
    public var nextCursor: String?

    public init(
        threadID: String,
        items: [RelayThreadHistoryItem],
        status: RelayThreadRunStatus,
        nextCursor: String? = nil
    ) {
        self.threadID = threadID
        self.items = items
        self.status = status
        self.nextCursor = nextCursor
    }
}

public struct RelayThreadHistoryPage: Equatable, Sendable {
    public var requestID: String
    public var threadID: String
    public var items: [RelayThreadHistoryItem]
    public var status: RelayThreadRunStatus
    public var nextCursor: String?

    public init(
        requestID: String,
        threadID: String,
        items: [RelayThreadHistoryItem],
        status: RelayThreadRunStatus,
        nextCursor: String?
    ) {
        self.requestID = requestID
        self.threadID = threadID
        self.items = items
        self.status = status
        self.nextCursor = nextCursor
    }
}

public enum RelayStreamRoute: Equatable, Sendable {
    case deviceToHostAgent
}

public struct RelayStreamOpenRequest: Equatable, Sendable {
    public var hostID: UUID
    public var deviceID: UUID
    public var pairingRecordID: String
    public var supportedVersions: [RelayProtocolVersion]
    public var tags: [String: String]

    public init(
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        supportedVersions: [RelayProtocolVersion],
        tags: [String: String]
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.supportedVersions = supportedVersions
        self.tags = tags
    }
}

public struct RelaySealedPayload: Equatable, Sendable, CustomStringConvertible {
    private var sealedBytes: Data

    public init(ciphertext: Data) {
        sealedBytes = ciphertext
    }

    public var byteCount: Int {
        sealedBytes.count
    }

    public var description: String {
        "RelaySealedPayload(byteCount: \(byteCount))"
    }
}

public struct RelayStreamMetadata: Equatable, Sendable {
    public var hostID: UUID
    public var deviceID: UUID
    public var route: RelayStreamRoute
    public var tags: [String: String]
    public var openedAt: Date
    public var closedAt: Date?
    public var errorCode: String?

    public init(
        hostID: UUID,
        deviceID: UUID,
        route: RelayStreamRoute,
        tags: [String: String],
        openedAt: Date,
        closedAt: Date?,
        errorCode: String?
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.route = route
        self.tags = tags
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.errorCode = errorCode
    }
}

public struct RelayStreamTelemetry: Equatable, Sendable {
    public var metadata: RelayStreamMetadata
    public var deviceToHostByteCount: Int
    public var hostToDeviceByteCount: Int

    public init(metadata: RelayStreamMetadata, deviceToHostByteCount: Int, hostToDeviceByteCount: Int) {
        self.metadata = metadata
        self.deviceToHostByteCount = deviceToHostByteCount
        self.hostToDeviceByteCount = hostToDeviceByteCount
    }

    public var duration: TimeInterval? {
        metadata.closedAt?.timeIntervalSince(metadata.openedAt)
    }
}

public struct RelayDiagnosticSnapshot: Equatable, Sendable {
    public var hostPresence: RelayHostPresence

    public init(hostPresence: RelayHostPresence) {
        self.hostPresence = hostPresence
    }

    public var summary: String {
        switch hostPresence {
        case .offline:
            "Host Agent offline"
        case let .online(count):
            "Host Agent online (\(count) clients)"
        }
    }
}
