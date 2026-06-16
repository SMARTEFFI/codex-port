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

public enum WebRTCDataChannelJSONLFraming {
    public static let maximumFrameBytes = 16 * 1024

    public static func frames(forLine line: String, maximumFrameBytes: Int = Self.maximumFrameBytes) -> [Data] {
        let data = Data((line + "\n").utf8)
        let cappedFrameBytes = max(1, maximumFrameBytes)
        guard data.count > cappedFrameBytes else {
            return [data]
        }

        var frames: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + cappedFrameBytes, data.count)
            frames.append(data.subdata(in: offset..<end))
            offset = end
        }
        return frames
    }
}
