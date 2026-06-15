import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayWriteStatusDrivesComposerDisabledAndRunningStates() {
    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.text = "continue"
    let projection = RelayWriteStatusProjection()

    projection.apply(.writeStatusChanged(writeID: "write-1", status: .queued), to: &composer)
    #expect(composer.primaryAction == .disabled)
    #expect(composer.canSend == false)

    projection.apply(.writeStatusChanged(writeID: "write-1", status: .running), to: &composer)
    #expect(composer.primaryAction == .stop)

    projection.apply(.writeStatusChanged(writeID: "write-1", status: .handled), to: &composer)
    #expect(composer.primaryAction == .disabled)

    composer.text = "retry"
    projection.apply(.writeStatusChanged(writeID: "write-2", status: .failed(reason: "adapter unavailable")), to: &composer)
    #expect(composer.primaryAction == .send)
}

@Test func relayAcceptedPromptSnapshotRendersWorkingTranscriptAfterPriorHistory() {
    let visibleItems: [VisibleItem] = [
        .userMessage("Hi7"),
        .assistantMessage("Hi7 收到。"),
        .userMessage("Hi8"),
    ]
    let rows = TranscriptPresentation.rows(for: visibleItems, status: .running)
    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.text = "Hi8"
    composer.isRunning = false

    let projection = RelayWriteStatusProjection()
    projection.apply(.writeStatusChanged(writeID: "write-hi8", status: .queued), to: &composer)

    #expect(composer.text.isEmpty)
    #expect(composer.primaryAction == .disabled)
    #expect(rows.map(\.kind) == [.userBubble, .assistantText, .userBubble, .thinking])
    #expect(rows.last?.body == "正在思考...")
}
