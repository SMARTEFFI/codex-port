import Foundation
import CodexPortShared
import CodexPortWebRTC

public enum RelayConnectionTransportMode: Equatable, Sendable {
    case legacyWebSocketJSONL
    case p2pWebRTCDataChannel

    public static func parse(environmentValue: String?) -> RelayConnectionTransportMode {
        guard let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return .p2pWebRTCDataChannel
        }
        switch value {
        case "p2p", "p2p-webrtc", "p2p-webrtc-datachannel", "webrtc-datachannel":
            return .p2pWebRTCDataChannel
        case "legacy", "legacy-websocket", "legacy-websocket-jsonl", "websocket-jsonl":
            return .legacyWebSocketJSONL
        default:
            return .p2pWebRTCDataChannel
        }
    }
}

public struct RelayConnectionTransportFactory: Sendable {
    public var mode: RelayConnectionTransportMode
    private let relayBaseURL: URL
    private let webSocketFactory: RelayWebSocketTransportFactory
    private let signalingHTTPClient: any RelayP2PSignalingHTTPClient
    private let dataChannelFactory: (any RelayP2PDataChannelFactory)?
    private let webRTCConfiguration: WebRTCRuntimeConfiguration

    public init(
        mode: RelayConnectionTransportMode = .p2pWebRTCDataChannel,
        relayBaseURL: URL = RelayHostProductionPairingInput.productionRelayBaseURL,
        webSocketFactory: RelayWebSocketTransportFactory = RelayWebSocketTransportFactory(),
        signalingHTTPClient: any RelayP2PSignalingHTTPClient = URLSessionRelayP2PSignalingHTTPClient(),
        dataChannelFactory: (any RelayP2PDataChannelFactory)? = nil,
        webRTCConfiguration: WebRTCRuntimeConfiguration = WebRTCRuntimeConfiguration(iceServers: [])
    ) {
        self.mode = mode
        self.relayBaseURL = relayBaseURL
        self.webSocketFactory = webSocketFactory
        self.signalingHTTPClient = signalingHTTPClient
        self.dataChannelFactory = dataChannelFactory
        self.webRTCConfiguration = webRTCConfiguration
    }

    public func makeTransport(for relayHost: RelayHost) -> RelayJSONLTransport? {
        switch mode {
        case .legacyWebSocketJSONL:
            return webSocketFactory.makeTransport(for: relayHost)
        case .p2pWebRTCDataChannel:
            let signalingClient = RelayP2PSignalingClient(
                relayBaseURL: relayBaseURL,
                httpClient: signalingHTTPClient
            )
            let dataChannelFactory = dataChannelFactory ?? RelayWebRTCDataChannelFactory(
                signalingClient: signalingClient,
                configuration: webRTCConfiguration
            )
            return RelayP2PSessionTransportFactory(
                signalingClient: signalingClient,
                dataChannelFactory: dataChannelFactory
            ).makeDeferredTransport(for: relayHost)
        }
    }
}
