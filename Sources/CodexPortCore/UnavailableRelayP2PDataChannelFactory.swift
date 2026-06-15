import Foundation
import CodexPortShared

public struct UnavailableRelayP2PDataChannelFactory: RelayP2PDataChannelFactory {
    public init() {}

    public func openDataChannel(_ request: RelayP2PDataChannelOpenRequest) async throws -> any WebRTCDataChannelTransport {
        throw RelayP2PDataChannelRuntimeError.runtimeUnavailable(
            "Real WebRTC DataChannel runtime is not linked. Configure a production RelayP2PDataChannelFactory before enabling P2P route selection."
        )
    }
}

public enum RelayP2PDataChannelRuntimeError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
}
