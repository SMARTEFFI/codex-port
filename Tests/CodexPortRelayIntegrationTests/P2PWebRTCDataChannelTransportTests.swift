import Foundation
import Testing
@testable import CodexPortRelayCore
@testable import CodexPortShared

@Test func p2pWebRTCDataChannelTransportEstablishesReliableOrderedEchoPathThroughSignaling() async throws {
    let service = P2PSignalingService(supportedVersions: [.v0_2_0])
    let host = RelayHostIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Mac Studio",
        userName: "chenm",
        publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
    )
    let device = DeviceIdentity(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "iPhone A",
        kind: .iOSClient,
        publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
    )
    _ = await service.registerHost(host)
    let pairing = try await service.authorize(device: device, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 10))
    let session = try await service.openSession(P2PSignalingOpenRequest(
        hostID: host.id,
        deviceID: device.id,
        pairingRecordID: pairing.id,
        supportedVersions: [.v0_2_0]
    ))
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: service,
        session: session
    )
    let clientStates = WebRTCStateRecorder(pair.client.stateUpdates)
    let hostStates = WebRTCStateRecorder(pair.host.stateUpdates)
    await clientStates.start()
    await hostStates.start()

    try await pair.open()

    #expect(pair.client.configuration == .reliableOrdered)
    #expect(pair.host.configuration == .reliableOrdered)
    await waitForP2PDataChannel {
        let clientSnapshot = await clientStates.snapshot()
        let hostSnapshot = await hostStates.snapshot()
        return clientSnapshot == [.iceGathering, .directConnected, .dataChannelOpen]
            && hostSnapshot == [.iceGathering, .directConnected, .dataChannelOpen]
    }

    let echoTask = Task<Data?, Never> {
        for await message in pair.client.incomingMessages {
            return message
        }
        return nil
    }
    let hostEchoTask = Task<Void, Never> {
        for await message in pair.host.incomingMessages {
            try? await pair.host.send(message)
            return
        }
    }

    try await pair.client.send(Data("ping".utf8))

    let echoed = await echoTask.value
    hostEchoTask.cancel()
    #expect(echoed == Data("ping".utf8))
    #expect(await service.plaintextInspectionLog().isEmpty)
}

@Test func p2pWebRTCDataChannelTransportReportsCloseAndFailsSendAfterClose() async throws {
    let context = try await P2PWebRTCTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    let clientStates = WebRTCStateRecorder(pair.client.stateUpdates)
    let hostStates = WebRTCStateRecorder(pair.host.stateUpdates)
    await clientStates.start()
    await hostStates.start()

    try await pair.open()
    pair.client.close()

    await waitForP2PDataChannel {
        let clientSnapshot = await clientStates.snapshot()
        let hostSnapshot = await hostStates.snapshot()
        return clientSnapshot.contains(.dataChannelClosed)
            && hostSnapshot.contains(.dataChannelClosed)
    }
    await #expect(throws: WebRTCDataChannelTransportError.dataChannelClosed) {
        try await pair.client.send(Data("ping-after-close".utf8))
    }
}

@Test func p2pWebRTCDataChannelTransportFailsSendBeforeDataChannelOpen() async throws {
    let context = try await P2PWebRTCTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )

    await #expect(throws: WebRTCDataChannelTransportError.dataChannelNotOpen) {
        try await pair.client.send(Data("ping-before-open".utf8))
    }
}

@Test func p2pWebRTCDataChannelTransportReportsTurnRelayFallbackWithoutPayloadLogging() async throws {
    let context = try await P2PWebRTCTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session,
        icePlan: .directFailsThenTurnSucceeds(reason: "direct candidates timed out")
    )
    let clientStates = WebRTCStateRecorder(pair.client.stateUpdates)
    await clientStates.start()

    try await pair.open()

    await waitForP2PDataChannel {
        await clientStates.snapshot().contains(.turnRelayedConnected)
    }
    try await pair.client.send(Data("sensitive client-host payload".utf8))

    #expect(await clientStates.snapshot().contains(.directFailed(reason: "direct candidates timed out")))
    #expect(await context.service.plaintextInspectionLog().isEmpty)
}

@Test func p2pWebRTCDataChannelTransportReportsTurnFailureAsActionablePathError() async throws {
    let context = try await P2PWebRTCTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session,
        icePlan: .directFailsThenTurnFails(
            directReason: "direct candidates timed out",
            turnReason: "TURN credentials rejected"
        )
    )
    let clientStates = WebRTCStateRecorder(pair.client.stateUpdates)
    await clientStates.start()

    await #expect(throws: WebRTCDataChannelTransportError.iceFailed(reason: "TURN credentials rejected")) {
        try await pair.open()
    }
    await waitForP2PDataChannel {
        await clientStates.snapshot().contains(.turnFailed(reason: "TURN credentials rejected"))
    }
}

private struct P2PWebRTCTestContext: Sendable {
    var service: P2PSignalingService
    var session: P2PSignalingSession

    static func make() async throws -> P2PWebRTCTestContext {
        let service = P2PSignalingService(supportedVersions: [.v0_2_0])
        let host = RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
        let device = DeviceIdentity(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        )
        _ = await service.registerHost(host)
        let pairing = try await service.authorize(device: device, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 10))
        let session = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: device.id,
            pairingRecordID: pairing.id,
            supportedVersions: [.v0_2_0]
        ))
        return P2PWebRTCTestContext(service: service, session: session)
    }
}

private actor WebRTCStateRecorder {
    private let stream: AsyncStream<WebRTCDataChannelConnectionState>
    private var states: [WebRTCDataChannelConnectionState] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<WebRTCDataChannelConnectionState>) {
        self.stream = stream
    }

    func start() {
        task = Task {
            for await state in stream {
                append(state)
            }
        }
    }

    func snapshot() -> [WebRTCDataChannelConnectionState] {
        states
    }

    private func append(_ state: WebRTCDataChannelConnectionState) {
        states.append(state)
    }
}

private func waitForP2PDataChannel(
    timeout: Duration = .milliseconds(500),
    condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
