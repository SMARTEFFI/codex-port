import Foundation
import Testing
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func relayP2PWebRTCSignalingPayloadCodecRoundTripsSessionDescriptionAndICECandidate() throws {
    let offer = WebRTCSessionDescriptionPayload(
        type: .offer,
        sdp: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
    )
    let candidate = WebRTCICECandidatePayload(
        sdp: "candidate:1 1 udp 2122260223 192.0.2.10 54545 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )

    let encodedOffer = try RelayP2PWebRTCSignalingPayloadCodec.encode(offer)
    let encodedCandidate = try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)

    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(encodedOffer) == offer)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(encodedCandidate) == candidate)
}

@Test func webRTCRuntimeConfigurationCarriesSTUNAndTURNServersWithoutPayloadSecretsInDescription() {
    let configuration = WebRTCRuntimeConfiguration(iceServers: [
        WebRTCICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
        WebRTCICEServerConfiguration(
            urls: ["turn:turn.example.test:3478?transport=udp"],
            username: "turn-user",
            credential: "turn-secret"
        ),
    ])

    #expect(configuration.dataChannelLabel == "codexport-client-host")
    #expect(configuration.iceServers[0].urls == ["stun:stun.example.test:3478"])
    #expect(configuration.iceServers[1].username == "turn-user")
    #expect(configuration.iceServers[1].credential == "turn-secret")
    #expect(!String(describing: configuration).contains("turn-secret"))
    #expect(String(describing: configuration).contains("<redacted>"))
}

@Test func webRTCRuntimeConfigurationEnvironmentParsesJSONWithoutLoggingSecrets() throws {
    let configuration = try WebRTCRuntimeConfigurationEnvironment.make(environment: [
        "CODEXPORT_WEBRTC_ICE_SERVERS_JSON": #"""
        [
          {"urls":["stun:stun.example.test:3478"]},
          {"urls":["turn:turn.example.test:3478?transport=udp"],"username":"turn-user","credential":"turn-secret"}
        ]
        """#,
        "CODEXPORT_WEBRTC_DATA_CHANNEL_LABEL": "codexport-test-channel",
    ])

    #expect(configuration.dataChannelLabel == "codexport-test-channel")
    #expect(configuration.iceServers == [
        WebRTCICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
        WebRTCICEServerConfiguration(
            urls: ["turn:turn.example.test:3478?transport=udp"],
            username: "turn-user",
            credential: "turn-secret"
        ),
    ])
    #expect(!String(describing: configuration).contains("turn-secret"))
}

@Test func webRTCRuntimeConfigurationEnvironmentParsesURLLists() throws {
    let configuration = try WebRTCRuntimeConfigurationEnvironment.make(environment: [
        "CODEXPORT_WEBRTC_STUN_URLS": "stun:one.example.test:3478, stun:two.example.test:3478",
        "CODEXPORT_WEBRTC_TURN_URLS": "turn:turn.example.test:3478?transport=udp turn:turn.example.test:3478?transport=tcp",
        "CODEXPORT_WEBRTC_TURN_USERNAME": "turn-user",
        "CODEXPORT_WEBRTC_TURN_CREDENTIAL": "turn-secret",
    ])

    #expect(configuration.iceServers == [
        WebRTCICEServerConfiguration(urls: [
            "stun:one.example.test:3478",
            "stun:two.example.test:3478",
        ]),
        WebRTCICEServerConfiguration(
            urls: [
                "turn:turn.example.test:3478?transport=udp",
                "turn:turn.example.test:3478?transport=tcp",
            ],
            username: "turn-user",
            credential: "turn-secret"
        ),
    ])
}

@Test func webRTCRuntimeConfigurationEnvironmentRejectsInvalidJSON() throws {
    #expect(throws: WebRTCRuntimeConfigurationEnvironmentError.invalidICEJSON) {
        _ = try WebRTCRuntimeConfigurationEnvironment.make(environment: [
            "CODEXPORT_WEBRTC_ICE_SERVERS_JSON": "not-json",
        ])
    }
}

@Test func unavailableWebRTCPlatformRuntimeFailsBeforeProductRoutePretendsToBeP2P() async throws {
    let runtime = UnavailableWebRTCPlatformDataChannelRuntime()
    let session = RelayP2POpenSessionResponse(
        sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        pairingRecordID: "pairing-record",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    await #expect(throws: WebRTCPlatformRuntimeError.runtimeUnavailable(
        "Real WebRTC SDK runtime is not linked. Link a platform WebRTC implementation before enabling P2P route selection."
    )) {
        _ = try await runtime.openDataChannel(
            session: session,
            configuration: WebRTCRuntimeConfiguration(iceServers: [])
        )
    }
}

@Test func defaultWebRTCPlatformRuntimeUsesUnavailableGuardWhenSDKIsNotLinked() async throws {
    let runtime = DefaultWebRTCPlatformDataChannelRuntime.makeOpeningRuntime()
    let session = RelayP2POpenSessionResponse(
        sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        pairingRecordID: "pairing-record",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )

    await #expect(throws: WebRTCPlatformRuntimeError.runtimeUnavailable(
        "Real WebRTC SDK runtime is not linked. Link a platform WebRTC implementation before enabling P2P route selection."
    )) {
        _ = try await runtime.openDataChannel(
            session: session,
            configuration: WebRTCRuntimeConfiguration(iceServers: [])
        )
    }
}
