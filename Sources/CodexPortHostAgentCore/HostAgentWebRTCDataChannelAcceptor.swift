import Foundation
import CodexPortShared
import CodexPortWebRTC

public struct HostAgentWebRTCDataChannelAcceptor: HostAgentP2PDataChannelAccepting {
    private let configuration: WebRTCRuntimeConfiguration
    private let runtime: WebRTCPlatformDataChannelAccepting

    public init(
        configuration: WebRTCRuntimeConfiguration,
        runtime: WebRTCPlatformDataChannelAccepting = DefaultWebRTCPlatformDataChannelRuntime.makeAcceptingRuntime()
    ) {
        self.configuration = configuration
        self.runtime = runtime
    }

    public func accept(_ request: HostAgentP2PAcceptRequest) async throws -> HostAgentP2PAcceptResponse {
        let offer: WebRTCSessionDescriptionPayload
        do {
            offer = try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(request.offer.payload)
        } catch {
            throw WebRTCPlatformRuntimeError.invalidOfferPayload
        }
        let accepted = try await runtime.acceptDataChannel(
            offer: offer,
            session: request.session,
            configuration: request.iceConfiguration ?? configuration
        )
        return try Self.response(from: accepted)
    }

    public func restartICE(
        _ request: HostAgentP2PAcceptRequest,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> HostAgentP2PAcceptResponse {
        let offer: WebRTCSessionDescriptionPayload
        do {
            offer = try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(request.offer.payload)
        } catch {
            throw WebRTCPlatformRuntimeError.invalidOfferPayload
        }
        let accepted = try await runtime.restartICE(
            offer: offer,
            session: request.session,
            configuration: request.iceConfiguration ?? configuration,
            dataChannel: dataChannel
        )
        return try Self.response(from: accepted)
    }

    private static func response(from accepted: WebRTCPlatformDataChannelAcceptResult) throws -> HostAgentP2PAcceptResponse {
        HostAgentP2PAcceptResponse(
            answer: RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(accepted.answer)
            ),
            iceCandidates: try accepted.localICECandidates.map { candidate in
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                )
            },
            localICECandidateUpdates: Self.makeLocalICECandidateUpdates(accepted.localICECandidateUpdates),
            dataChannel: accepted.dataChannel
        )
    }

    public func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        let candidate: WebRTCICECandidatePayload
        do {
            candidate = try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(message.payload)
        } catch {
            throw WebRTCPlatformRuntimeError.invalidICECandidatePayload
        }
        try await runtime.addRemoteICECandidate(candidate, to: dataChannel)
    }

    private static func makeLocalICECandidateUpdates(
        _ candidates: AsyncStream<WebRTCICECandidatePayload>
    ) -> AsyncStream<RelayP2PSignalingMessageDTO> {
        AsyncStream { continuation in
            let task = Task {
                for await candidate in candidates {
                    do {
                        continuation.yield(RelayP2PSignalingMessageDTO(
                            from: .host,
                            to: .device,
                            kind: .iceCandidate,
                            payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                        ))
                    } catch {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

public struct HostAgentWebRTCDataChannelAcceptorFactory: HostAgentP2PDataChannelAcceptorFactory {
    private let runtime: WebRTCPlatformDataChannelAccepting

    public init(runtime: WebRTCPlatformDataChannelAccepting = DefaultWebRTCPlatformDataChannelRuntime.makeAcceptingRuntime()) {
        self.runtime = runtime
    }

    public func makeAcceptor(configuration: WebRTCRuntimeConfiguration) -> HostAgentP2PDataChannelAccepting {
        HostAgentWebRTCDataChannelAcceptor(configuration: configuration, runtime: runtime)
    }
}
