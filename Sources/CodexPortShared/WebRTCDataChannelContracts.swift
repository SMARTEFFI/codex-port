import Foundation

public enum WebRTCDataChannelConfiguration: Equatable, Sendable {
    case reliableOrdered
}

public enum WebRTCDataChannelConnectionState: Equatable, Sendable {
    case iceGathering
    case directConnected
    case directFailed(reason: String)
    case turnRelayedConnected
    case turnFailed(reason: String)
    case dataChannelOpen
    case dataChannelClosed
}

public enum WebRTCDataChannelTransportError: Error, Equatable, Sendable {
    case dataChannelNotOpen
    case dataChannelClosed
    case iceFailed(reason: String)
    case signalingFailed(String)
}

public enum P2PSignalingAuthorizationState: Equatable, Sendable {
    case hostOffline
    case signalingReachable
    case authorizedToSignal(pairingRecordID: String)
}

public protocol WebRTCDataChannelTransport: Sendable {
    var configuration: WebRTCDataChannelConfiguration { get }
    var incomingMessages: AsyncStream<Data> { get }
    var stateUpdates: AsyncStream<WebRTCDataChannelConnectionState> { get }

    func send(_ message: Data) async throws
}
