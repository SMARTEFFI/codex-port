import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared
@testable import CodexPortWebRTC

@Test func p2pRecoveryCoordinatorRestartsIceOnCurrentSessionBeforeRebuilding() async throws {
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let relayHost = makeRecoveryRelayHost()
    let initialTransport = RecordingRecoveryDataChannelTransport()
    let restartedTransport = RecordingRecoveryDataChannelTransport()
    let runtime = RecordingP2PRecoveryRuntime(restartResults: [
        .success(P2PConnectionRecoveryTransport(
            dataChannel: restartedTransport,
            path: .direct,
            historyItems: [.assistantMessage("recovered without rebuild")]
        )),
    ])
    let coordinator = P2PConnectionRecoveryCoordinator(
        relayHost: relayHost,
        session: makeRecoverySession(sessionID: sessionID, relayHost: relayHost),
        threadID: "thread-1",
        dataChannel: initialTransport,
        runtime: runtime,
        historyReconciler: StaticP2PHistoryReconciler(items: [.assistantMessage("recovered without rebuild")])
    )

    let result = try await coordinator.recoverAfterNetworkChange()

    #expect(result.state.status == .completed)
    #expect(result.state.nextAction == .none)
    #expect(result.state.sessionID == sessionID.uuidString)
    #expect(result.state.threadID == "thread-1")
    #expect(result.state.pathState.candidatePath == .direct)
    #expect(result.transport.dataChannel as? RecordingRecoveryDataChannelTransport === restartedTransport)
    #expect(await runtime.restartRequests.map(\.session.sessionID) == [sessionID])
    #expect(await runtime.rebuildRequests.isEmpty)
}

@Test func p2pRecoveryCoordinatorRebuildsSameThreadWhenIceRestartFails() async throws {
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let relayHost = makeRecoveryRelayHost()
    let rebuiltTransport = RecordingRecoveryDataChannelTransport()
    let runtime = RecordingP2PRecoveryRuntime(
        restartResults: [.failure(WebRTCDataChannelTransportError.iceFailed(reason: "restart timed out"))],
        rebuildResults: [
            .success(P2PConnectionRecoveryTransport(
                dataChannel: rebuiltTransport,
                path: .relay,
                historyItems: [.assistantMessage("before"), .assistantMessage("during outage")]
            )),
        ]
    )
    let coordinator = P2PConnectionRecoveryCoordinator(
        relayHost: relayHost,
        session: makeRecoverySession(sessionID: sessionID, relayHost: relayHost),
        threadID: "thread-1",
        dataChannel: RecordingRecoveryDataChannelTransport(),
        runtime: runtime,
        historyReconciler: StaticP2PHistoryReconciler(items: [
            .assistantMessage("before"),
            .assistantMessage("during outage"),
        ])
    )

    let result = try await coordinator.recoverAfterNetworkChange()

    #expect(result.state.status == .completed)
    #expect(result.state.sessionID == sessionID.uuidString)
    #expect(result.state.threadID == "thread-1")
    #expect(result.state.pathState.candidatePath == .relay)
    #expect(result.state.loadedHistoryItems == [
        .assistantMessage("before"),
        .assistantMessage("during outage"),
    ])
    #expect(result.transport.dataChannel as? RecordingRecoveryDataChannelTransport === rebuiltTransport)
    #expect(await runtime.restartRequests.map(\.threadID) == ["thread-1"])
    #expect(await runtime.rebuildRequests.map(\.threadID) == ["thread-1"])
}

@Test func p2pRecoveryCoordinatorDirectProbeUpgradesRelaySessionOnlyAfterDirectPathAndPingPongPass() async throws {
    let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let relayHost = makeRecoveryRelayHost()
    let directTransport = RecordingRecoveryDataChannelTransport()
    let runtime = RecordingP2PRecoveryRuntime(directProbeResults: [
        .failure(WebRTCDataChannelTransportError.iceFailed(reason: "selected pair is relay")),
        .success(P2PConnectionRecoveryTransport(
            dataChannel: directTransport,
            path: .direct,
            historyItems: [.assistantMessage("relay history")]
        )),
    ])
    let coordinator = P2PConnectionRecoveryCoordinator(
        relayHost: relayHost,
        session: makeRecoverySession(sessionID: sessionID, relayHost: relayHost),
        threadID: "thread-1",
        dataChannel: RecordingRecoveryDataChannelTransport(),
        runtime: runtime,
        initialPath: .relay,
        historyReconciler: StaticP2PHistoryReconciler(items: [.assistantMessage("relay history")])
    )

    let failedProbe = await coordinator.probeDirectPath()
    #expect(failedProbe.state.directProbeSchedule == .backoff(seconds: 30))
    #expect(failedProbe.state.pathState.candidatePath == .relay)

    let upgraded = await coordinator.retryDirectProbeNow()
    #expect(upgraded.state.status == .completed)
    #expect(upgraded.state.directProbeSchedule == .idle)
    #expect(upgraded.state.pathState.candidatePath == .direct)
    #expect(upgraded.transport?.dataChannel as? RecordingRecoveryDataChannelTransport === directTransport)
    #expect(await runtime.directProbeRequests.map(\.threadID) == ["thread-1", "thread-1"])
}

private func makeRecoveryRelayHost() -> RelayHost {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    return RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-\(hostID.uuidString)-\(deviceID.uuidString)",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "paired"
    )
}

private func makeRecoverySession(sessionID: UUID, relayHost: RelayHost) -> RelayP2POpenSessionResponse {
    RelayP2POpenSessionResponse(
        sessionID: sessionID,
        hostID: relayHost.hostAgentID,
        deviceID: relayHost.deviceID!,
        pairingRecordID: relayHost.pairingRecordID,
        selectedVersion: .v0_2_0,
        openedAtUnixTime: 100
    )
}

private actor RecordingP2PRecoveryRuntime: P2PConnectionRecoveryRuntime {
    var restartResults: [Result<P2PConnectionRecoveryTransport, Error>] = []
    var rebuildResults: [Result<P2PConnectionRecoveryTransport, Error>] = []
    var directProbeResults: [Result<P2PConnectionRecoveryTransport, Error>] = []
    private(set) var restartRequests: [P2PConnectionRecoveryRequest] = []
    private(set) var rebuildRequests: [P2PConnectionRecoveryRequest] = []
    private(set) var directProbeRequests: [P2PConnectionRecoveryRequest] = []

    init(
        restartResults: [Result<P2PConnectionRecoveryTransport, Error>] = [],
        rebuildResults: [Result<P2PConnectionRecoveryTransport, Error>] = [],
        directProbeResults: [Result<P2PConnectionRecoveryTransport, Error>] = []
    ) {
        self.restartResults = restartResults
        self.rebuildResults = rebuildResults
        self.directProbeResults = directProbeResults
    }

    func restartICE(_ request: P2PConnectionRecoveryRequest) async throws -> P2PConnectionRecoveryTransport {
        restartRequests.append(request)
        return try restartResults.removeFirst().get()
    }

    func rebuildPeerConnection(_ request: P2PConnectionRecoveryRequest) async throws -> P2PConnectionRecoveryTransport {
        rebuildRequests.append(request)
        return try rebuildResults.removeFirst().get()
    }

    func probeDirectPath(_ request: P2PConnectionRecoveryRequest) async throws -> P2PConnectionRecoveryTransport {
        directProbeRequests.append(request)
        return try directProbeResults.removeFirst().get()
    }
}

private struct StaticP2PHistoryReconciler: P2PConnectionHistoryReconciling {
    var items: [VisibleItem]

    func reconcile(threadID: String) async throws -> [VisibleItem] {
        items
    }
}

private final class RecordingRecoveryDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages = AsyncStream<Data> { _ in }
    let stateUpdates = AsyncStream<WebRTCDataChannelConnectionState> { continuation in
        continuation.yield(.dataChannelOpen)
    }

    func send(_ message: Data) async throws {}
}
