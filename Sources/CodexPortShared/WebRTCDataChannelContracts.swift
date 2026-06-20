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

public enum WebRTCDataChannelHealthCheckMessage: Equatable, Sendable {
    case ping(nonce: String)
    case pong(nonce: String)
}

public enum WebRTCDataChannelHealthCheck {
    public static let pingType = "codexport.p2p.health.ping"
    public static let pongType = "codexport.p2p.health.pong"

    public static func pingLine(nonce: String) throws -> String {
        try encode(type: pingType, nonce: nonce)
    }

    public static func pongLine(nonce: String) throws -> String {
        try encode(type: pongType, nonce: nonce)
    }

    public static func decodeLine(_ line: String) -> WebRTCDataChannelHealthCheckMessage? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let nonce = object["nonce"] as? String,
              !nonce.isEmpty else {
            return nil
        }
        switch type {
        case pingType:
            return .ping(nonce: nonce)
        case pongType:
            return .pong(nonce: nonce)
        default:
            return nil
        }
    }

    public static func decodeFrame(_ data: Data) -> WebRTCDataChannelHealthCheckMessage? {
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) else {
            return nil
        }
        return decodeLine(line)
    }

    private static func encode(type: String, nonce: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["type": type, "nonce": nonce],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
