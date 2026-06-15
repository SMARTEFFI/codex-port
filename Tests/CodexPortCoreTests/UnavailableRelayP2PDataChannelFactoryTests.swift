import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func unavailableRelayP2PDataChannelFactoryFailsBeforeFakeRuntimeCanEnterProductionPath() async throws {
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
    let request = RelayP2PDataChannelOpenRequest(
        relayHost: relayHost,
        session: RelayP2POpenSessionResponse(
            sessionID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: relayHost.pairingRecordID,
            selectedVersion: .v0_2_0,
            openedAtUnixTime: 100
        )
    )
    let factory = UnavailableRelayP2PDataChannelFactory()

    await #expect(throws: RelayP2PDataChannelRuntimeError.runtimeUnavailable(
        "Real WebRTC DataChannel runtime is not linked. Configure a production RelayP2PDataChannelFactory before enabling P2P route selection."
    )) {
        _ = try await factory.openDataChannel(request)
    }
}

@Test func connectionDiagnosticsReportsUnavailableP2PDataChannelRuntime() async {
    let diagnostics = ConnectionDiagnostics()

    let report = await diagnostics.report(for: RelayP2PDataChannelRuntimeError.runtimeUnavailable("missing WebRTC SDK"))

    #expect(report.rows == [
        DiagnosticRow(title: "WebRTC DataChannel", status: .failed, message: "P2P DataChannel runtime unavailable: missing WebRTC SDK")
    ])
}
