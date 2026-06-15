import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func sessionStoreRendersRelayLiveSessionEventsAndTerminalStates() {
    let protocolClient = FakeCodexProtocol()
    let store = SessionStore(protocolClient: protocolClient)

    store.receive(relayEvent: .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    store.receive(relayEvent: .userMessage(turnID: "turn-1", itemID: "user-1", text: "Desktop prompt"))
    store.receive(relayEvent: .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "Hel"))
    store.receive(relayEvent: .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "lo"))
    store.receive(relayEvent: .commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test\n"))
    store.receive(relayEvent: .fileChange(turnID: "turn-1", itemID: "file-1", path: "README.md", diff: "+hi"))

    #expect(store.status == .running)
    #expect(store.visibleItems == [
        .userMessage("Desktop prompt"),
        .assistantMessage("Hello"),
        .commandOutput("swift test\n"),
        .fileChange(path: "README.md", diff: "+hi"),
    ])
    #expect(TranscriptPresentation.rows(for: store.visibleItems, expandedToolRowIDs: ["2-command", "3-file"], status: store.status) == [
        TranscriptRow(
            id: "0-user",
            kind: .userBubble,
            body: "Desktop prompt",
            copyPayload: "Desktop prompt"
        ),
        TranscriptRow(
            id: "1-assistant",
            kind: .assistantText,
            body: "Hello",
            blocks: [.text("Hello")],
            copyPayload: "Hello"
        ),
        TranscriptRow(
            id: "2-command",
            kind: .toolOutput,
            body: "swift test\n",
            title: "运行命令",
            summary: "swift test",
            systemImage: "terminal",
            isCollapsed: false,
            blocks: [.code(language: .shell, text: "swift test\n")],
            copyPayload: "swift test\n"
        ),
        TranscriptRow(
            id: "3-file",
            kind: .toolOutput,
            body: "+hi",
            title: "修改文件",
            summary: "README.md",
            systemImage: "doc.text",
            isCollapsed: false,
            diffLines: [.init(kind: .added, text: "+hi")],
            copyPayload: "+hi"
        ),
        TranscriptRow(
            id: "thinking",
            kind: .thinking,
            body: "正在工作...",
            copyPayload: "正在工作..."
        ),
    ])

    store.receive(relayEvent: .turnCompleted(turnID: "turn-1"))
    #expect(store.status == .completed)

    store.receive(relayEvent: .sessionStarted(sessionID: "session-2", threadID: "thread-1", turnID: "turn-2"))
    store.receive(relayEvent: .turnFailed(turnID: "turn-2", reason: "adapter failed"))
    #expect(store.status == .failed("adapter failed"))

    store.receive(relayEvent: .streamClosed(sessionID: "session-2", threadID: "thread-1", errorCode: "relay.closed"))
    #expect(store.status == .failed("adapter failed"))
}

@Test func sessionStoreDeduplicatesOptimisticRelayUserMessageEcho() {
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    store.openNew(threadID: "thread-1")

    store.appendOptimisticUserMessage("Hi from iPhone")
    store.receive(relayEvent: .userMessage(turnID: "turn-1", itemID: "user-echo", text: "Hi from iPhone"))

    #expect(store.visibleItems == [.userMessage("Hi from iPhone")])
}

@Test func sessionStoreKeepsRelayAssistantItemsSeparateAcrossTurnsWhenItemIDsRepeat() {
    let store = SessionStore(protocolClient: FakeCodexProtocol())
    store.openNew(threadID: "thread-1")

    store.receive(relayEvent: .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"))
    store.receive(relayEvent: .assistantTextDelta(turnID: "turn-1", itemID: "item_0", text: "first"))
    store.receive(relayEvent: .turnCompleted(turnID: "turn-1"))
    store.receive(relayEvent: .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-2"))
    store.receive(relayEvent: .assistantTextDelta(turnID: "turn-2", itemID: "item_0", text: "second"))
    store.receive(relayEvent: .turnCompleted(turnID: "turn-2"))

    #expect(store.visibleItems == [
        .assistantMessage("first"),
        .assistantMessage("second"),
    ])
}
