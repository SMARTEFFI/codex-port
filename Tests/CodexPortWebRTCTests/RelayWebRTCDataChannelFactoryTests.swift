import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func relayWebRTCDataChannelFactoryForwardsTrickleICEInBothDirections() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let localCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:local 1 udp 2122260223 192.0.2.10 54545 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let followUpLocalCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:local-follow-up 1 udp 2122260223 192.0.2.12 54547 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let remoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:remote 1 udp 2122260223 192.0.2.11 54546 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let followUpRemoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:remote-follow-up 1 udp 2122260223 192.0.2.13 54548 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessageBatches: [
            [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .answer,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
                ),
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteCandidate)
                ),
            ],
            [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(followUpRemoteCandidate)
                ),
            ],
        ]
    )
    let localICEUpdateStream = AsyncStream<WebRTCICECandidatePayload> { continuation in
        Task {
            try await Task.sleep(for: .milliseconds(10))
            continuation.yield(followUpLocalCandidate)
            continuation.finish()
        }
    }
    let dataChannel = RecordingWebRTCDataChannelTransport()
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [localCandidate],
            localICECandidateUpdates: localICEUpdateStream,
            dataChannel: dataChannel
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
        ]),
        runtime: runtime,
        answerTimeout: .milliseconds(250),
        remoteICEPollingDuration: .milliseconds(250)
    )

    let opened = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: session
    ))
    try await signalingHTTP.waitForSentMessageCount(3)
    try await runtime.waitForAddedCandidateCount(2)
    try await opened.send(Data("keep-alive".utf8))

    #expect(await runtime.openedSessions == [session])
    #expect(await runtime.appliedAnswers == [remoteAnswer])
    #expect(await runtime.addedCandidates == [remoteCandidate, followUpRemoteCandidate])
    #expect(signalingHTTP.sentMessages.map(\.kind) == [.offer, .iceCandidate, .iceCandidate])
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(signalingHTTP.sentMessages[0].payload).type == .offer)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(signalingHTTP.sentMessages[1].payload) == localCandidate)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(signalingHTTP.sentMessages[2].payload) == followUpLocalCandidate)
}

@Test func relayWebRTCDataChannelFactorySendsOfferAndLocalICEThenAppliesRemoteAnswerAndICE() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let localCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:local 1 udp 2122260223 192.0.2.10 54545 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let remoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:remote 1 udp 2122260223 192.0.2.11 54546 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .iceCandidate,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteCandidate)
            ),
        ]
    )
    let dataChannel = RecordingWebRTCDataChannelTransport()
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [localCandidate],
            dataChannel: dataChannel
        )
    )
    let fallbackConfiguration = WebRTCRuntimeConfiguration(iceServers: [
        WebRTCICEServerConfiguration(urls: ["stun:fallback.example.test:3478"]),
    ])
    let relayIssuedConfiguration = WebRTCRuntimeConfiguration(iceServers: [
        WebRTCICEServerConfiguration(urls: ["stun:relay-issued.example.test:3478"]),
        WebRTCICEServerConfiguration(
            urls: ["turn:relay-issued.example.test:3478?transport=udp"],
            username: "1600:pairing-record",
            credential: "short-lived-turn-secret"
        ),
    ])
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: fallbackConfiguration,
        runtime: runtime,
        answerTimeout: .milliseconds(250)
    )

    let opened = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: session,
        iceConfiguration: relayIssuedConfiguration
    ))

    try await opened.send(Data("ping".utf8))
    #expect(dataChannel.sentMessages == [Data("ping".utf8)])
    #expect(await runtime.openedSessions == [session])
    #expect(await runtime.openedConfigurations == [relayIssuedConfiguration])
    #expect(await runtime.appliedAnswers == [remoteAnswer])
    #expect(await runtime.addedCandidates == [remoteCandidate])
    #expect(signalingHTTP.sentMessages.map(\.kind) == [.offer, .iceCandidate])
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(signalingHTTP.sentMessages[0].payload).type == .offer)
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(signalingHTTP.sentMessages[1].payload) == localCandidate)
}

@Test func relayWebRTCDataChannelFactoryWaitsForDataChannelOpenBeforeReturning() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let relayIssuedConfiguration = WebRTCRuntimeConfiguration(iceServers: [
        WebRTCICEServerConfiguration(urls: ["stun:relay-issued.example.test:3478"]),
        WebRTCICEServerConfiguration(
            urls: ["turn:relay-issued.example.test:3478?transport=udp"],
            username: "1600:pairing-record",
            credential: "short-lived-turn-secret"
        ),
    ])
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
        ],
        iceConfigurationResponse: RelayP2PICEConfigurationResponse(
            configuration: relayIssuedConfiguration,
            expiresAtUnixTime: 1_600
        )
    )
    let dataChannel = RecordingWebRTCDataChannelTransport(autoOpen: false)
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [],
            dataChannel: dataChannel
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: runtime,
        answerTimeout: .milliseconds(250),
        dataChannelOpenTimeout: .seconds(1)
    )

    let completion = RelayWebRTCDataChannelOpenCompletionProbe()
    let openTask = Task {
        let transport = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
            relayHost: relayHost,
            session: session
        ))
        await completion.markFinished()
        return transport
    }

    try await signalingHTTP.waitForSentMessageCount(1)
    try await runtime.waitForAppliedAnswerCount(1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await completion.isFinished == false)

    dataChannel.deliverState(.dataChannelOpen)
    let opened = try await openTask.value
    try await opened.send(Data("after-open".utf8))

    #expect(dataChannel.sentMessages == [Data("after-open".utf8)])
}

@Test func relayWebRTCDataChannelFactoryKeepsWaitingAfterDirectFailureWhenTURNCanOpen() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
        ]
    )
    let dataChannel = RecordingWebRTCDataChannelTransport(autoOpen: false)
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [],
            dataChannel: dataChannel
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: runtime,
        answerTimeout: .milliseconds(250),
        dataChannelOpenTimeout: .seconds(1)
    )

    let completion = RelayWebRTCDataChannelOpenCompletionProbe()
    let openTask = Task {
        let transport = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
            relayHost: relayHost,
            session: session
        ))
        await completion.markFinished()
        return transport
    }

    try await signalingHTTP.waitForSentMessageCount(1)
    try await runtime.waitForAppliedAnswerCount(1)
    dataChannel.deliverState(.directFailed(reason: "direct candidates timed out"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(await completion.isFinished == false)

    dataChannel.deliverState(.turnRelayedConnected)
    dataChannel.deliverState(.dataChannelOpen)
    let opened = try await openTask.value
    try await opened.send(Data("after-turn-open".utf8))

    #expect(dataChannel.sentMessages == [Data("after-turn-open".utf8)])
}

@Test func relayWebRTCDataChannelFactoryContinuesApplyingRemoteICEWhileWaitingForDataChannelOpen() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nremote-answer")
    let lateRemoteCandidate = WebRTCICECandidatePayload(
        sdp: "candidate:late-srflx 1 udp 1686052607 203.0.113.10 54546 typ srflx",
        sdpMid: "0",
        sdpMLineIndex: 0
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessageBatches: [
            [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .answer,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
                ),
            ],
            [
                RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(lateRemoteCandidate)
                ),
            ],
        ]
    )
    let dataChannel = RecordingWebRTCDataChannelTransport(autoOpen: false)
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [],
            dataChannel: dataChannel
        ),
        onAddRemoteICECandidate: { _, _ in
            dataChannel.deliverState(.dataChannelOpen)
        }
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
        ]),
        runtime: runtime,
        answerTimeout: .milliseconds(250),
        dataChannelOpenTimeout: .milliseconds(500),
        remoteICEPollingDuration: .milliseconds(500)
    )

    let opened = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: session
    ))
    try await opened.send(Data("after-late-ice".utf8))

    #expect(await runtime.appliedAnswers == [remoteAnswer])
    #expect(await runtime.addedCandidates == [lateRemoteCandidate])
    #expect(dataChannel.sentMessages == [Data("after-late-ice".utf8)])
}

@Test func relayWebRTCDataChannelFactoryTimesOutWhenHostNeverAnswers() async throws {
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
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(remoteMessages: [])
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nlocal-offer"),
            localICECandidates: [],
            dataChannel: RecordingWebRTCDataChannelTransport()
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: runtime,
        answerTimeout: .milliseconds(1)
    )

    await #expect(throws: WebRTCPlatformRuntimeError.answerTimedOut) {
        _ = try await factory.openDataChannel(RelayP2PDataChannelOpenRequest(
            relayHost: relayHost,
            session: session
        ))
    }
}

@Test func relayWebRTCDataChannelFactoryRestartsICEUsingSameSessionSignaling() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let session = RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nrestart-answer")
    let relayIssuedConfiguration = WebRTCRuntimeConfiguration(iceServers: [
        WebRTCICEServerConfiguration(urls: ["stun:relay-issued.example.test:3478"]),
        WebRTCICEServerConfiguration(
            urls: ["turn:relay-issued.example.test:3478?transport=udp"],
            username: "1600:pairing-record",
            credential: "short-lived-turn-secret"
        ),
    ])
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
        ],
        iceConfigurationResponse: RelayP2PICEConfigurationResponse(
            configuration: relayIssuedConfiguration,
            expiresAtUnixTime: 1_600
        )
    )
    let existingDataChannel = RecordingWebRTCDataChannelTransport()
    let restartedDataChannel = RecordingWebRTCDataChannelTransport()
    let restartResult = WebRTCPlatformDataChannelOpenResult(
        offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nrestart-offer"),
        localICECandidates: [
            WebRTCICECandidatePayload(
                sdp: "candidate:restart-local 1 udp 2122260223 192.0.2.10 54545 typ host",
                sdpMid: "0",
                sdpMLineIndex: 0
            ),
        ],
        dataChannel: restartedDataChannel
    )
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nunused-open-offer"),
            localICECandidates: [],
            dataChannel: existingDataChannel
        ),
        restartResult: restartResult,
        healthCheckResult: WebRTCDataChannelHealthCheckResult(
            selectedCandidatePairPath: .direct,
            pingPongSucceeded: true
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: [
            WebRTCICEServerConfiguration(urls: ["stun:fallback.example.test:3478"]),
        ]),
        runtime: runtime,
        answerTimeout: .milliseconds(250)
    )

    let recovered = try await factory.restartICE(P2PConnectionRecoveryRequest(
        relayHost: relayHost,
        session: session,
        threadID: "thread-1",
        dataChannel: existingDataChannel,
        preferDirect: true
    ))

    #expect(recovered.path == .direct)
    #expect(recovered.dataChannel as? RecordingWebRTCDataChannelTransport === restartedDataChannel)
    #expect(await runtime.restartConfigurations == [relayIssuedConfiguration])
    #expect(await runtime.appliedAnswers == [remoteAnswer])
    #expect(signalingHTTP.sentMessages.map(\.kind) == [.offer, .iceCandidate])
    #expect(try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(signalingHTTP.sentMessages[0].payload) == restartResult.offer)
}

@Test func relayWebRTCDataChannelFactoryDirectProbeRejectsRelayCandidatePair() async throws {
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
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: session.pairingRecordID,
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let remoteAnswer = WebRTCSessionDescriptionPayload(type: .answer, sdp: "v=0\r\nprobe-answer")
    let signalingHTTP = RecordingRelayP2PSignalingHTTPClient(
        remoteMessages: [
            RelayP2PSignalingMessageDTO(
                from: .host,
                to: .device,
                kind: .answer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(remoteAnswer)
            ),
        ]
    )
    let runtime = RecordingWebRTCOpeningRuntime(
        result: WebRTCPlatformDataChannelOpenResult(
            offer: WebRTCSessionDescriptionPayload(type: .offer, sdp: "v=0\r\nprobe-offer"),
            localICECandidates: [],
            dataChannel: RecordingWebRTCDataChannelTransport()
        ),
        healthCheckResult: WebRTCDataChannelHealthCheckResult(
            selectedCandidatePairPath: .relay,
            pingPongSucceeded: true
        )
    )
    let factory = RelayWebRTCDataChannelFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signalingHTTP
        ),
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        runtime: runtime,
        answerTimeout: .milliseconds(250)
    )

    await #expect(throws: WebRTCDataChannelTransportError.iceFailed(reason: "direct path probe did not validate a non-relay candidate pair")) {
        _ = try await factory.probeDirectPath(P2PConnectionRecoveryRequest(
            relayHost: relayHost,
            session: session,
            threadID: "thread-1",
            dataChannel: RecordingWebRTCDataChannelTransport(),
            preferDirect: true
        ))
    }
}

private actor RecordingWebRTCOpeningRuntime: WebRTCPlatformDataChannelOpening {
    private let result: WebRTCPlatformDataChannelOpenResult
    private let restartResult: WebRTCPlatformDataChannelOpenResult?
    private let healthCheckResult: WebRTCDataChannelHealthCheckResult
    private let onAddRemoteICECandidate: @Sendable (WebRTCICECandidatePayload, WebRTCDataChannelTransport) async -> Void
    private(set) var openedSessions: [RelayP2POpenSessionResponse] = []
    private(set) var openedConfigurations: [WebRTCRuntimeConfiguration] = []
    private(set) var restartConfigurations: [WebRTCRuntimeConfiguration] = []
    private(set) var appliedAnswers: [WebRTCSessionDescriptionPayload] = []
    private(set) var addedCandidates: [WebRTCICECandidatePayload] = []

    init(
        result: WebRTCPlatformDataChannelOpenResult,
        restartResult: WebRTCPlatformDataChannelOpenResult? = nil,
        healthCheckResult: WebRTCDataChannelHealthCheckResult = WebRTCDataChannelHealthCheckResult(
            selectedCandidatePairPath: .direct,
            pingPongSucceeded: true
        ),
        onAddRemoteICECandidate: @escaping @Sendable (WebRTCICECandidatePayload, WebRTCDataChannelTransport) async -> Void = { _, _ in }
    ) {
        self.result = result
        self.restartResult = restartResult
        self.healthCheckResult = healthCheckResult
        self.onAddRemoteICECandidate = onAddRemoteICECandidate
    }

    func openDataChannel(
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        openedSessions.append(session)
        openedConfigurations.append(configuration)
        return result
    }

    func restartICE(
        on dataChannel: WebRTCDataChannelTransport,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        restartConfigurations.append(configuration)
        return restartResult ?? result
    }

    func checkDirectPath(
        on dataChannel: WebRTCDataChannelTransport,
        requiredPingPongCount: Int
    ) async throws -> WebRTCDataChannelHealthCheckResult {
        healthCheckResult
    }

    func applyRemoteAnswer(
        _ answer: WebRTCSessionDescriptionPayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        appliedAnswers.append(answer)
    }

    func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        addedCandidates.append(candidate)
        await onAddRemoteICECandidate(candidate, dataChannel)
    }

    func waitForAddedCandidateCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while addedCandidates.count < count {
            if ContinuousClock.now >= deadline {
                throw RelayWebRTCDataChannelFactoryTestError.timedOutWaitingForRemoteICE(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForAppliedAnswerCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while appliedAnswers.count < count {
            if ContinuousClock.now >= deadline {
                throw RelayWebRTCDataChannelFactoryTestError.timedOutWaitingForAppliedAnswer(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class RecordingRelayP2PSignalingHTTPClient: RelayP2PSignalingHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var remoteMessageBatches: [[RelayP2PSignalingMessageDTO]]
    private let iceConfigurationResponse: RelayP2PICEConfigurationResponse
    private var recordedSentMessages: [RelayP2PSignalingMessageDTO] = []

    var sentMessages: [RelayP2PSignalingMessageDTO] {
        lock.withLock { recordedSentMessages }
    }

    init(
        remoteMessages: [RelayP2PSignalingMessageDTO],
        iceConfigurationResponse: RelayP2PICEConfigurationResponse = RelayP2PICEConfigurationResponse(
            configuration: WebRTCRuntimeConfiguration(iceServers: []),
            expiresAtUnixTime: 0
        )
    ) {
        remoteMessageBatches = [remoteMessages]
        self.iceConfigurationResponse = iceConfigurationResponse
    }

    init(
        remoteMessageBatches: [[RelayP2PSignalingMessageDTO]],
        iceConfigurationResponse: RelayP2PICEConfigurationResponse = RelayP2PICEConfigurationResponse(
            configuration: WebRTCRuntimeConfiguration(iceServers: []),
            expiresAtUnixTime: 0
        )
    ) {
        self.remoteMessageBatches = remoteMessageBatches
        self.iceConfigurationResponse = iceConfigurationResponse
    }

    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: .online,
            authorization: .authorizedToSignal,
            pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
            activeConnectionCount: 1
        )
    }

    func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        RelayP2POpenSessionResponse(
            sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            hostID: request.hostID,
            deviceID: request.deviceID,
            pairingRecordID: request.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        )
    }

    func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse {
        iceConfigurationResponse
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        lock.withLock {
            recordedSentMessages.append(request.message)
        }
    }

    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        let messages = lock.withLock {
            guard !remoteMessageBatches.isEmpty else {
                return [RelayP2PSignalingMessageDTO]()
            }
            return remoteMessageBatches.removeFirst()
        }
        return RelayP2PDrainMessagesResponse(messages: messages)
    }

    func waitForSentMessageCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while lock.withLock({ recordedSentMessages.count }) < count {
            if ContinuousClock.now >= deadline {
                throw RelayWebRTCDataChannelFactoryTestError.timedOutWaitingForSentMessages(count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class RecordingWebRTCDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    private let lock = NSLock()
    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages = AsyncStream<Data> { _ in }
    let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private var recordedSentMessages: [Data] = []

    init(autoOpen: Bool = true) {
        var capturedContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        stateUpdates = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        stateContinuation = capturedContinuation!
        if autoOpen {
            Task { [stateContinuation] in
                stateContinuation.yield(.dataChannelOpen)
            }
        }
    }

    var sentMessages: [Data] {
        lock.withLock { recordedSentMessages }
    }

    func send(_ message: Data) async throws {
        lock.withLock {
            recordedSentMessages.append(message)
        }
    }

    func deliverState(_ state: WebRTCDataChannelConnectionState) {
        stateContinuation.yield(state)
    }
}

private actor RelayWebRTCDataChannelOpenCompletionProbe {
    private var finished = false

    var isFinished: Bool {
        finished
    }

    func markFinished() {
        finished = true
    }
}

private enum RelayWebRTCDataChannelFactoryTestError: Error, CustomStringConvertible {
    case timedOutWaitingForSentMessages(Int)
    case timedOutWaitingForRemoteICE(Int)
    case timedOutWaitingForAppliedAnswer(Int)

    var description: String {
        switch self {
        case let .timedOutWaitingForSentMessages(count):
            "Timed out waiting for \(count) sent signaling messages"
        case let .timedOutWaitingForRemoteICE(count):
            "Timed out waiting for \(count) remote ICE candidates"
        case let .timedOutWaitingForAppliedAnswer(count):
            "Timed out waiting for \(count) applied WebRTC answers"
        }
    }
}
