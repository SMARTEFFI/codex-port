import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func relayP2PSessionTransportFactoryOpensAuthorizedDataChannelTransport() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let signaling = RelayP2PSignalingRecordingHTTPClient(
        presenceResponse: RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: .online,
            authorization: .authorizedToSignal,
            pairingRecordID: relayHost.pairingRecordID,
            activeConnectionCount: 1
        ),
        openResponse: RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        ),
        drainResponse: RelayP2PDrainMessagesResponse(messages: [])
    )
    let dataChannelFactory = RecordingRelayP2PDataChannelFactory(
        transport: LoopbackWebRTCDataChannelTransport()
    )
    let factory = RelayP2PSessionTransportFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signaling
        ),
        dataChannelFactory: dataChannelFactory
    )

    let transport = try await factory.makeTransport(for: relayHost)
    try await transport.sendLine(#"{"type":"ping"}"#)

    #expect(signaling.presenceURL == URL(string: "https://relay.example.test/v0/p2p/hosts/\(hostID.uuidString)/presence?deviceID=\(deviceID.uuidString)")!)
    #expect(signaling.openRequest?.pairingRecordID == relayHost.pairingRecordID)
    #expect(dataChannelFactory.openRequest == RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        )
    ))
    #expect(dataChannelFactory.transport.sentMessages.map { String(decoding: $0, as: UTF8.self) } == [
        #"{"type":"ping"}"# + "\n",
    ])
}

@Test func relayP2PSessionTransportFactoryProvidesDeferredTransportForExistingRouteBuilder() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let signaling = RelayP2PSignalingRecordingHTTPClient(
        presenceResponse: RelayP2PPresenceResponse(
            hostID: hostID,
            deviceID: deviceID,
            presence: .online,
            authorization: .authorizedToSignal,
            pairingRecordID: relayHost.pairingRecordID,
            activeConnectionCount: 1
        ),
        openResponse: RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        ),
        drainResponse: RelayP2PDrainMessagesResponse(messages: [])
    )
    let dataChannelFactory = RecordingRelayP2PDataChannelFactory(
        transport: LoopbackWebRTCDataChannelTransport()
    )
    let factory = RelayP2PSessionTransportFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: signaling
        ),
        dataChannelFactory: dataChannelFactory
    )
    let transport = factory.makeDeferredTransport(for: relayHost)

    #expect(signaling.presenceURL == nil)
    try await transport.sendLine(#"{"type":"listThreads"}"#)

    #expect(signaling.presenceURL != nil)
    #expect(dataChannelFactory.openRequest?.session.sessionID == sessionID)
    #expect(dataChannelFactory.transport.sentMessages.map { String(decoding: $0, as: UTF8.self) } == [
        #"{"type":"listThreads"}"# + "\n",
    ])
}

@Test func relayP2PSessionTransportFactoryRejectsHostWithoutDeviceIdentity() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-without-device",
        deviceID: nil,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let factory = RelayP2PSessionTransportFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: RelayP2PSignalingRecordingHTTPClient(
                presenceResponse: RelayP2PPresenceResponse(
                    hostID: hostID,
                    deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    presence: .online,
                    authorization: .signalingReachable,
                    pairingRecordID: nil,
                    activeConnectionCount: 1
                ),
                openResponse: RelayP2POpenSessionResponse(
                    sessionID: UUID(),
                    hostID: hostID,
                    deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    pairingRecordID: "unused",
                    selectedVersion: .v0_2_0,
                    openedAtUnixTime: 100
                ),
                drainResponse: RelayP2PDrainMessagesResponse(messages: [])
            )
        ),
        dataChannelFactory: RecordingRelayP2PDataChannelFactory(
            transport: LoopbackWebRTCDataChannelTransport()
        )
    )

    await #expect(throws: RelayP2PSessionTransportFactoryError.missingDeviceID) {
        _ = try await factory.makeTransport(for: relayHost)
    }
}

@Test func relayP2PSessionTransportFactoryRejectsUnauthorizedPresence() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let factory = RelayP2PSessionTransportFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: RelayP2PSignalingRecordingHTTPClient(
                presenceResponse: RelayP2PPresenceResponse(
                    hostID: hostID,
                    deviceID: deviceID,
                    presence: .online,
                    authorization: .signalingReachable,
                    pairingRecordID: nil,
                    activeConnectionCount: 1
                ),
                openResponse: RelayP2POpenSessionResponse(
                    sessionID: UUID(),
                    hostID: hostID,
                    deviceID: deviceID,
                    pairingRecordID: relayHost.pairingRecordID,
                    selectedVersion: .v0_2_0,
                    openedAtUnixTime: 100
                ),
                drainResponse: RelayP2PDrainMessagesResponse(messages: [])
            )
        ),
        dataChannelFactory: RecordingRelayP2PDataChannelFactory(
            transport: LoopbackWebRTCDataChannelTransport()
        )
    )

    await #expect(throws: RelayP2PSessionTransportFactoryError.notAuthorizedToSignal(.signalingReachable)) {
        _ = try await factory.makeTransport(for: relayHost)
    }
}

@Test func relayP2PSessionTransportFactoryMapsMissingWebRTCAnswerToStaleHostAgent() async throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let relayHost = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
    let factory = RelayP2PSessionTransportFactory(
        signalingClient: RelayP2PSignalingClient(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            httpClient: RelayP2PSignalingRecordingHTTPClient(
                presenceResponse: RelayP2PPresenceResponse(
                    hostID: hostID,
                    deviceID: deviceID,
                    presence: .online,
                    authorization: .authorizedToSignal,
                    pairingRecordID: relayHost.pairingRecordID,
                    activeConnectionCount: 1
                ),
                openResponse: RelayP2POpenSessionResponse(
                    sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                    hostID: hostID,
                    deviceID: deviceID,
                    pairingRecordID: relayHost.pairingRecordID,
                    selectedVersion: .v0_2_0,
                    openedAtUnixTime: 100
                ),
                drainResponse: RelayP2PDrainMessagesResponse(messages: [])
            )
        ),
        dataChannelFactory: FailingRelayP2PDataChannelFactory(error: WebRTCPlatformRuntimeError.answerTimedOut)
    )

    await #expect(throws: RelayP2PSessionTransportFactoryError.hostAgentDidNotAnswer) {
        _ = try await factory.makeTransport(for: relayHost)
    }
}

private final class RecordingRelayP2PDataChannelFactory: RelayP2PDataChannelFactory, @unchecked Sendable {
    let transport: LoopbackWebRTCDataChannelTransport
    private(set) var openRequest: RelayP2PDataChannelOpenRequest?

    init(transport: LoopbackWebRTCDataChannelTransport) {
        self.transport = transport
    }

    func openDataChannel(_ request: RelayP2PDataChannelOpenRequest) async throws -> any WebRTCDataChannelTransport {
        openRequest = request
        return transport
    }
}

private struct FailingRelayP2PDataChannelFactory: RelayP2PDataChannelFactory {
    var error: Error

    func openDataChannel(_ request: RelayP2PDataChannelOpenRequest) async throws -> any WebRTCDataChannelTransport {
        throw error
    }
}

private final class RelayP2PSignalingRecordingHTTPClient: RelayP2PSignalingHTTPClient, @unchecked Sendable {
    let presenceResponse: RelayP2PPresenceResponse
    let openResponse: RelayP2POpenSessionResponse
    let drainResponse: RelayP2PDrainMessagesResponse
    private(set) var presenceURL: URL?
    private(set) var openURL: URL?
    private(set) var openRequest: RelayP2POpenSessionRequest?
    private(set) var sendURL: URL?
    private(set) var sendRequest: RelayP2PSendMessageRequest?
    private(set) var drainURL: URL?

    init(
        presenceResponse: RelayP2PPresenceResponse,
        openResponse: RelayP2POpenSessionResponse,
        drainResponse: RelayP2PDrainMessagesResponse
    ) {
        self.presenceResponse = presenceResponse
        self.openResponse = openResponse
        self.drainResponse = drainResponse
    }

    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        presenceURL = url
        return presenceResponse
    }

    func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        openRequest = request
        openURL = url
        return openResponse
    }

    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        sendRequest = request
        sendURL = url
    }

    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        drainURL = url
        return drainResponse
    }
}

private final class LoopbackWebRTCDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages: AsyncStream<Data>
    let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private(set) var sentMessages: [Data] = []

    init() {
        var capturedIncoming: AsyncStream<Data>.Continuation?
        var capturedState: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        incomingMessages = AsyncStream { continuation in
            capturedIncoming = continuation
        }
        stateUpdates = AsyncStream { continuation in
            capturedState = continuation
        }
        incomingContinuation = capturedIncoming!
        stateContinuation = capturedState!
    }

    deinit {
        incomingContinuation.finish()
        stateContinuation.finish()
    }

    func send(_ message: Data) async throws {
        sentMessages.append(message)
    }
}
