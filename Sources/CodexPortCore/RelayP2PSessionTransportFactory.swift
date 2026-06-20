import Foundation
import CodexPortShared
import CodexPortWebRTC

public struct RelayP2PDataChannelOpenRequest: Equatable, Sendable {
    public var relayHost: RelayHost
    public var session: RelayP2POpenSessionResponse
    public var iceConfiguration: WebRTCRuntimeConfiguration

    public init(
        relayHost: RelayHost,
        session: RelayP2POpenSessionResponse,
        iceConfiguration: WebRTCRuntimeConfiguration = WebRTCRuntimeConfiguration(iceServers: [])
    ) {
        self.relayHost = relayHost
        self.session = session
        self.iceConfiguration = iceConfiguration
    }
}

public protocol RelayP2PDataChannelFactory: Sendable {
    func openDataChannel(_ request: RelayP2PDataChannelOpenRequest) async throws -> any WebRTCDataChannelTransport
}

public struct RelayP2PSessionTransportFactory: Sendable {
    private let signalingClient: RelayP2PSignalingClient
    private let dataChannelFactory: any RelayP2PDataChannelFactory

    public init(
        signalingClient: RelayP2PSignalingClient,
        dataChannelFactory: any RelayP2PDataChannelFactory
    ) {
        self.signalingClient = signalingClient
        self.dataChannelFactory = dataChannelFactory
    }

    public func makeTransport(for relayHost: RelayHost) async throws -> RelayJSONLTransport {
        guard let deviceID = relayHost.deviceID else {
            throw RelayP2PSessionTransportFactoryError.missingDeviceID
        }
        let presence = try await signalingClient.presence(hostID: relayHost.hostAgentID, deviceID: deviceID)
        guard presence.authorization == .authorizedToSignal else {
            throw RelayP2PSessionTransportFactoryError.notAuthorizedToSignal(presence.authorization)
        }
        guard presence.pairingRecordID == relayHost.pairingRecordID else {
            throw RelayP2PSessionTransportFactoryError.pairingRecordMismatch(
                expected: relayHost.pairingRecordID,
                actual: presence.pairingRecordID
            )
        }
        let session = try await signalingClient.openSession(
            hostID: relayHost.hostAgentID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID
        )
        let iceConfiguration = try await signalingClient.iceConfiguration(
            hostID: relayHost.hostAgentID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID
        ).configuration
        let dataChannel: any WebRTCDataChannelTransport
        do {
            dataChannel = try await dataChannelFactory.openDataChannel(RelayP2PDataChannelOpenRequest(
                relayHost: relayHost,
                session: session,
                iceConfiguration: iceConfiguration
            ))
        } catch WebRTCPlatformRuntimeError.answerTimedOut {
            throw RelayP2PSessionTransportFactoryError.hostAgentDidNotAnswer
        }
        if let recoveryRuntime = dataChannelFactory as? P2PConnectionRecoveryRuntime {
            return RelayP2PRecoveringDataChannelTransport(
                relayHost: relayHost,
                session: session,
                dataChannel: dataChannel,
                runtime: recoveryRuntime
            )
        }
        return ClientHostSessionDataChannelTransport(dataChannel: dataChannel)
    }

    public func makeDeferredTransport(for relayHost: RelayHost) -> RelayJSONLTransport {
        RelayDeferredJSONLTransport { [self] in
            try await makeTransport(for: relayHost)
        }
    }
}

public enum RelayP2PSessionTransportFactoryError: Error, Equatable, Sendable {
    case missingDeviceID
    case notAuthorizedToSignal(RelayP2PAuthorizationStatus)
    case pairingRecordMismatch(expected: String, actual: String?)
    case hostAgentDidNotAnswer
}
