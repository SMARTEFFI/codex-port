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

@Test func transcriptPresentationShowsThinkingForLatestRunningUserMessageAfterPriorCompletedOutput() {
    let rows = TranscriptPresentation.rows(
        for: [
            .userMessage("Hi7"),
            .assistantMessage("Hi7 收到。"),
            .userMessage("Hi8"),
        ],
        status: .running
    )

    #expect(rows.map(\.kind) == [.userBubble, .assistantText, .userBubble, .thinking])
    #expect(rows.last?.body == "正在思考...")
}

@Test func transcriptPresentationKeepsEmptyRunningRelayAttachUnrendered() {
    let rows = TranscriptPresentation.rows(
        for: [],
        status: .running
    )

    #expect(rows.isEmpty)
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

@Test func transcriptPresentationKeepsWorkingRowAfterLatestToolOutputWhileRunning() {
    let commandRows = TranscriptPresentation.rows(
        for: [
            .userMessage("跑测试"),
            .commandOutput("swift test\nBuild complete\n"),
        ],
        status: .running
    )
    let fileRows = TranscriptPresentation.rows(
        for: [
            .userMessage("改文件"),
            .fileChange(path: "README.md", diff: "+done\n"),
        ],
        status: .running
    )

    #expect(commandRows.map(\.kind) == [.userBubble, .toolOutput, .thinking])
    #expect(commandRows.last?.body == "正在工作...")
    #expect(fileRows.map(\.kind) == [.userBubble, .toolOutput, .thinking])
    #expect(fileRows.last?.body == "正在工作...")
}

@Test func transcriptPresentationShowsFailedTurnReason() {
    let rows = TranscriptPresentation.rows(
        for: [.userMessage("继续")],
        status: .failed("Codex CLI exec timed out.")
    )

    #expect(rows.map(\.kind) == [.userBubble, .status])
    #expect(rows.last?.body == "会话失败：Codex CLI exec timed out.")
    #expect(rows.last?.usesBubble == false)
}

@Test func transcriptPresentationExposesCopyPayloadForVisibleTranscriptRows() {
    let rows = TranscriptPresentation.rows(
        for: [
            .userMessage("用户问题"),
            .assistantMessage("助手回复"),
            .commandOutput("swift test\npassed\n"),
            .fileChange(path: "README.md", diff: "+added\n-removed\n")
        ],
        expandedToolRowIDs: ["2-command", "3-file"]
    )

    #expect(rows.map(\.copyPayload) == [
        "用户问题",
        "助手回复",
        "swift test\npassed\n",
        "+added\n-removed\n"
    ])
}

@Test func transcriptPresentationRendersStructuredUserMessageSkillChipsWithoutRepeatingDollarText() {
    let rows = TranscriptPresentation.rows(for: [
        .structuredUserMessage(StructuredUserMessage(
            body: "请整理这个 bug",
            mentions: [
                SkillMention(identifier: "triage", displayName: "Triage")
            ]
        ))
    ])

    #expect(rows[0].body == "请整理这个 bug")
    #expect(rows[0].skillChips == [
        TranscriptSkillChip(identifier: "triage", displayName: "Triage")
    ])
    #expect(rows[0].copyPayload == "请整理这个 bug")
}

@Test func transcriptPresentationRendersStructuredUserMessageImageAttachments() {
    let rows = TranscriptPresentation.rows(for: [
        .structuredUserMessage(StructuredUserMessage(
            body: "看这张图",
            attachments: [
                MessageAttachment(
                    id: "image-1",
                    kind: .image(contentType: "image/png", detail: "high"),
                    displayName: "screen.png",
                    source: .localCache(path: "/app/cache/screen.png")
                ),
                MessageAttachment(
                    id: "file-1",
                    kind: .file(contentType: "text/plain"),
                    displayName: "notes.txt",
                    source: .remoteHostPath("/Users/chenm/Desktop/notes.txt")
                )
            ]
        ))
    ])

    #expect(rows[0].imageAttachments == [
        ImageAttachmentGalleryItem(
            id: "image-1",
            displayName: "screen.png",
            availability: .available(localPath: "/app/cache/screen.png")
        )
    ])
}
