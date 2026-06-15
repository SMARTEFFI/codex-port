import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func hostAgentWebRTCDataChannelAcceptorDecodesOfferAndReturnsAnswerICEAndDataChannel() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let session = RelayP2POpenSessionResponse(
        sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let offer = WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nremote-offer")
    let answer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nlocal-answer")
    let localCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:host 1 udp 2122260223 192.0.2.11 54546 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let dataChannel = HostAgentRecordingWebRTCDataChannelTransport()
    let runtime = HostAgentRecordingWebRTCAcceptingRuntime(
        result: WebRTCPlatformDataChannelAcceptResult(
            answer: answer,
            localICECandidates: [localCandidate],
            dataChannel: dataChannel
        )
    )
    let acceptor = HostAgentWebRTCDataChannelAcceptor(
        configuration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["turn:turn.example.test:3478?transport=udp"], username: "u", credential: "p"),
        ]),
        runtime: runtime
    )

    let response = try await acceptor.accept(HostAgentP2PAcceptRequest(
        session: session,
        offer: RelayP2PSignalingMessageDTO(
            from: .device,
            to: .host,
            kind: .offer,
            payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(offer)
        )
    ))

    #expect(await runtime.acceptedOffers == [offer])
    #expect(response.dataChannel as? HostAgentRecordingWebRTCDataChannelTransport === dataChannel)
    #expect(response.answer.kind == .answer)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(response.answer.payload) == answer)
    #expect(response.iceCandidates.count == 1)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(response.iceCandidates[0].payload) == localCandidate)
}

@Test func hostAgentWebRTCDataChannelAcceptorRejectsInvalidOfferPayload() async throws {
    let acceptor = HostAgentWebRTCDataChannelAcceptor(
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: HostAgentRecordingWebRTCAcceptingRuntime(
            result: WebRTCPlatformDataChannelAcceptResult(
                answer: WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nlocal-answer"),
                localICECandidates: [],
                dataChannel: HostAgentRecordingWebRTCDataChannelTransport()
            )
        )
    )
    let session = RelayP2POpenSessionResponse(
        sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        pairingRecordID: "pairing-record",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )

    await #expect(throws: WebRTCPlatformRuntimeError.invalidOfferPayload) {
        _ = try await acceptor.accept(HostAgentP2PAcceptRequest(
            session: session,
            offer: RelayP2PSignalingMessageDTO(
                from: .device,
                to: .host,
                kind: .offer,
                payload: "not-json"
            )
        ))
    }
}

private actor HostAgentRecordingWebRTCAcceptingRuntime: WebRTCPlatformDataChannelAccepting {
    private let result: WebRTCPlatformDataChannelAcceptResult
    private(set) var acceptedOffers: [WebRTCSessionDescriptionPayload] = []
    private(set) var addedCandidates: [WebRTCICECandidatePayload] = []

    init(result: WebRTCPlatformDataChannelAcceptResult) {
        self.result = result
    }

    func acceptDataChannel(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelAcceptResult {
        acceptedOffers.append(offer)
        return result
    }

    func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        addedCandidates.append(candidate)
    }
}

private final class HostAgentRecordingWebRTCDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages = AsyncStream<Data> { _ in }
    let stateUpdates = AsyncStream<WebRTCDataChannelConnectionState> { _ in }

    func send(_ message: Data) async throws {}
}
