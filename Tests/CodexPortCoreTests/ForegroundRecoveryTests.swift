import Foundation
import Testing
@testable import CodexPortCore

@Test func foregroundRecoveryRefreshesWorkspaceListAndCurrentThread() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.thread = ThreadDetail(id: "thread-1", turns: [])
    let workspaceStore = WorkspaceListStore(protocolClient: CodexProtocolFacade(transport: RecordingCodexTransport()))
    let sessionStore = SessionStore(protocolClient: protocolClient)
    let recovery = ForegroundRecoveryCoordinator(workspaces: workspaceStore, session: sessionStore)

    try await recovery.recover(currentThreadID: "thread-1")

    #expect(protocolClient.calls == ["thread/resume(initialTurnLimit:10,timeout:30.0)"])
    #expect(recovery.lastRecoveryStatus == .completed)
}
