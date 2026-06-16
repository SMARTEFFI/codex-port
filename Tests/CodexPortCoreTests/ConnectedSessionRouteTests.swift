import Foundation
import Testing
@testable import CodexPortCore

@Test func connectedSessionRouteDistinguishesDirectSSHAndRelaySessions() {
    let protocolClient = FakeCodexProtocol()
    let sessionClientTransport = RecordingRelayJSONLTransportForRoute()
    let direct = ConnectedSessionRoute.directSSH(
        protocolClient: protocolClient,
        events: nil
    )
    let relay = ConnectedSessionRoute.relay(
        hostID: "host-1",
        clientID: "iphone-a",
        threads: [
            ThreadSummary(
                id: "thread-1",
                cwd: "/repo",
                updatedAt: Date(timeIntervalSince1970: 1),
                preview: "Relay thread",
                gitInfo: nil
            )
        ],
        sessionRegistry: RelaySessionContextRegistry(
            allowedThreadIDs: ["thread-1"],
            storeFactory: { threadID in
                SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: threadID))
            },
            clientFactory: { thread, sessionStore in
                RelayJSONLSessionClient(
                    clientID: "iphone-a",
                    sessionID: "session-1",
                    threadID: thread.id,
                    turnID: "turn-1",
                    transport: sessionClientTransport,
                    sessionStore: sessionStore
                )
            }
        )
    )

    #expect(direct.directProtocolClient === protocolClient)
    #expect(direct.relayThreadSummaries.isEmpty)
    #expect(relay.directProtocolClient == nil)
    #expect(relay.relayThreadSummaries.map(\.id) == ["thread-1"])
    #expect(relay.isRelay)
    #expect(direct.canStartProjectSession)
    #expect(relay.canStartProjectSession)
    #expect(relay.relaySessionContext(threadID: "thread-1") != nil)
    #expect(relay.relaySessionContext(threadID: "missing-thread") == nil)
}

private final class RecordingRelayJSONLTransportForRoute: RelayJSONLTransport, @unchecked Sendable {
    let incomingLines = AsyncStream<String> { _ in }

    func sendLine(_ line: String) async throws {}
}
