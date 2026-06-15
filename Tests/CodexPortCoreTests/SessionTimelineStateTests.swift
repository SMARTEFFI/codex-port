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

@Test func sessionTimelinePreservesPositionWhenEarlierHistoryIsPrepended() {
    var timeline = SessionTimelineState(items: [
        .assistantMessage("最新消息")
    ])

    let anchor = timeline.prependHistoryItems([
        .assistantMessage("更早消息"),
        .assistantMessage("最新消息")
    ])

    #expect(anchor == .preserve)
    #expect(timeline.isPinnedToBottom == false)
    #expect(timeline.items == [
        .assistantMessage("更早消息"),
        .assistantMessage("最新消息")
    ])
}

@Test func sessionTimelineReportsPinnedChangesOnlyWhenStateActuallyChanges() {
    var timeline = SessionTimelineState(items: [
        .assistantMessage("进行中的消息")
    ])

    #expect(timeline.userReturnedToBottom() == false)
    #expect(timeline.userMovedAwayFromBottom() == true)
    #expect(timeline.userMovedAwayFromBottom() == false)
    #expect(timeline.userReturnedToBottom() == true)
    #expect(timeline.setPinnedToBottom(true) == false)
}

@Test func sessionTimelineKeepsLastKnownItemsWhenForegroundRefreshIsTransientlyEmpty() {
    var timeline = SessionTimelineState(items: [
        .userMessage("继续"),
        .assistantMessage("已有历史")
    ])

    let anchor = timeline.applyForegroundRefreshItems([])

    #expect(anchor == .preserve)
    #expect(timeline.items == [
        .userMessage("继续"),
        .assistantMessage("已有历史")
    ])

    let refreshedAnchor = timeline.applyForegroundRefreshItems([
        .userMessage("继续"),
        .assistantMessage("已有历史"),
        .assistantMessage("刷新后的新内容")
    ])

    #expect(refreshedAnchor == .bottom)
    #expect(timeline.items == [
        .userMessage("继续"),
        .assistantMessage("已有历史"),
        .assistantMessage("刷新后的新内容")
    ])
}

@Test func sessionTimelineStillAllowsExplicitInitialEmptyState() {
    var timeline = SessionTimelineState(items: [
        .assistantMessage("旧历史")
    ])

    let anchor = timeline.replaceLoadedItems([])

    #expect(anchor == .bottom)
    #expect(timeline.items.isEmpty)
}
