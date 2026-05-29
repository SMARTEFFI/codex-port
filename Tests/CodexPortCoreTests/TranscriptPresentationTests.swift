import Testing
@testable import CodexPortCore

@Test func transcriptPresentationUsesBubblesOnlyForUserMessages() {
    let items: [VisibleItem] = [
        .assistantMessage("我会检查实现。"),
        .userMessage("继续"),
        .commandOutput("swift test\n"),
        .fileChange(path: "README.md", diff: "+done")
    ]

    let rows = TranscriptPresentation.rows(for: items)

    #expect(rows.map(\.kind) == [.assistantText, .userBubble, .toolOutput, .toolOutput])
    #expect(rows[0].usesBubble == false)
    #expect(rows[1].usesBubble == true)
    #expect(rows[2].usesBubble == false)
    #expect(rows[3].title == "修改文件")
    #expect(rows[3].summary == "README.md")
}

@Test func transcriptPresentationCollapsesToolItemsWithSummariesByDefault() {
    let rows = TranscriptPresentation.rows(for: [
        .commandOutput("swift test\nBuild complete\n"),
        .fileChange(path: "README.md", diff: "+done\n")
    ])

    #expect(rows.map(\.kind) == [.toolOutput, .toolOutput])
    #expect(rows[0].isCollapsed == true)
    #expect(rows[0].systemImage == "terminal")
    #expect(rows[0].title == "运行命令")
    #expect(rows[0].summary == "swift test")
    #expect(rows[0].body == "")
    #expect(rows[1].isCollapsed == true)
    #expect(rows[1].systemImage == "doc.text")
    #expect(rows[1].title == "修改文件")
    #expect(rows[1].summary == "README.md")
}

@Test func transcriptPresentationExpandsSelectedToolRowsAndKeepsStableIDsAcrossUpdates() {
    let collapsed = TranscriptPresentation.rows(for: [
        .commandOutput("swift test\nBuild complete\n")
    ])
    let expanded = TranscriptPresentation.rows(
        for: [.commandOutput("swift test\nBuild complete\nAll tests passed\n")],
        expandedToolRowIDs: [collapsed[0].id]
    )

    #expect(expanded[0].id == collapsed[0].id)
    #expect(expanded[0].isCollapsed == false)
    #expect(expanded[0].body == "swift test\nBuild complete\nAll tests passed\n")
    #expect(expanded[0].summary == "swift test")
}

@Test func transcriptPresentationParsesAssistantMarkdownCodeBlocks() {
    let rows = TranscriptPresentation.rows(for: [
        .assistantMessage("""
        先改这里：

        ```swift
        let value = 1
        ```

        然后继续。
        """)
    ])

    #expect(rows[0].blocks == [
        .text("先改这里：\n\n"),
        .code(language: .swift, text: "let value = 1\n"),
        .text("\n然后继续。")
    ])
}

@Test func transcriptPresentationFallsBackForUnknownCodeLanguagesAndClassifiesDiffLines() {
    let codeRows = TranscriptPresentation.rows(for: [
        .assistantMessage("""
        ```brainfuck
        +++.
        ```
        """)
    ])
    let diffRows = TranscriptPresentation.rows(
        for: [.fileChange(path: "README.md", diff: """
         context
        +added
        -removed
        """)],
        expandedToolRowIDs: ["0-file"]
    )

    #expect(codeRows[0].blocks == [.code(language: .plainText, text: "+++.\n")])
    #expect(diffRows[0].diffLines.map(\.kind) == [.context, .added, .removed])
}

@Test func transcriptPresentationShowsThinkingWhenRunningWithoutAssistantOrToolOutput() {
    let rows = TranscriptPresentation.rows(
        for: [.userMessage("继续")],
        status: .running
    )

    #expect(rows.map(\.kind) == [.userBubble, .thinking])
    #expect(rows.last?.body == "正在思考...")
    #expect(rows.last?.usesBubble == false)
}

@Test func transcriptPresentationHidesThinkingAfterFirstAssistantOrToolOutput() {
    let assistantRows = TranscriptPresentation.rows(
        for: [.userMessage("继续"), .assistantMessage("开始处理")],
        status: .running
    )
    let completedRows = TranscriptPresentation.rows(
        for: [.userMessage("继续")],
        status: .completed
    )

    #expect(assistantRows.map(\.kind) == [.userBubble, .assistantText])
    #expect(completedRows.map(\.kind) == [.userBubble])
}
