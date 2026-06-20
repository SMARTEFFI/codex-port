import Foundation

public struct WebRTCSidecarMessage: Codable, Equatable, Sendable {
    public enum MessageType: String, Codable, Sendable {
        case accept
        case restartICE
        case accepted
        case localICE
        case remoteICE
        case dataChannelSend
        case dataChannelMessage
        case dataChannelState
        case error
    }

    public var type: MessageType
    public var sessionID: UUID?
    public var hostID: UUID?
    public var deviceID: UUID?
    public var offer: RelayP2PSignalingMessageDTO?
    public var answer: RelayP2PSignalingMessageDTO?
    public var candidate: RelayP2PSignalingMessageDTO?
    public var iceCandidates: [RelayP2PSignalingMessageDTO]?
    public var iceConfiguration: WebRTCRuntimeConfiguration?
    public var base64: String?
    public var state: String?
    public var reason: String?

    public init(
        type: MessageType,
        sessionID: UUID? = nil,
        hostID: UUID? = nil,
        deviceID: UUID? = nil,
        offer: RelayP2PSignalingMessageDTO? = nil,
        answer: RelayP2PSignalingMessageDTO? = nil,
        candidate: RelayP2PSignalingMessageDTO? = nil,
        iceCandidates: [RelayP2PSignalingMessageDTO]? = nil,
        iceConfiguration: WebRTCRuntimeConfiguration? = nil,
        base64: String? = nil,
        state: String? = nil,
        reason: String? = nil
    ) {
        self.type = type
        self.sessionID = sessionID
        self.hostID = hostID
        self.deviceID = deviceID
        self.offer = offer
        self.answer = answer
        self.candidate = candidate
        self.iceCandidates = iceCandidates
        self.iceConfiguration = iceConfiguration
        self.base64 = base64
        self.state = state
        self.reason = reason
    }
}
