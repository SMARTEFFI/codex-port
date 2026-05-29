import Foundation
import Testing
@testable import CodexPortCore

@Test func sessionTimelineScrollsToBottomAfterInitialLoadAndPinnedLiveUpdates() {
    var timeline = SessionTimelineState()

    let initialAnchor = timeline.replaceLoadedItems([
        .assistantMessage("旧消息"),
        .assistantMessage("最新消息")
    ])

    #expect(initialAnchor == .bottom)
    #expect(timeline.items == [
        .assistantMessage("旧消息"),
        .assistantMessage("最新消息")
    ])

    let liveAnchor = timeline.applyLiveItems([
        .assistantMessage("旧消息"),
        .assistantMessage("最新消息"),
        .assistantMessage("新增消息")
    ])

    #expect(liveAnchor == .bottom)
}

@Test func sessionTimelinePreservesPositionWhenUserReadsHistory() {
    var timeline = SessionTimelineState(items: [
        .assistantMessage("旧消息")
    ])

    timeline.userMovedAwayFromBottom()
    let liveAnchor = timeline.applyLiveItems([
        .assistantMessage("旧消息"),
        .assistantMessage("后台新增消息")
    ])

    #expect(liveAnchor == .preserve)

    timeline.userReturnedToBottom()
    let pinnedAnchor = timeline.applyLiveItems([
        .assistantMessage("旧消息"),
        .assistantMessage("后台新增消息"),
        .assistantMessage("继续新增")
    ])

    #expect(pinnedAnchor == .bottom)
}
