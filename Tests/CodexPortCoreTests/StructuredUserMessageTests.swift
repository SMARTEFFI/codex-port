import Testing
@testable import CodexPortCore

@Test func structuredUserMessageBuildsProtocolPayloadWithoutMarkdownSourceOfTruth() {
    let message = StructuredUserMessage(
        body: "分析这些附件",
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
            ),
        ]
    )

    #expect(message.protocolPrompt == "分析这些附件")
    #expect(message.protocolAttachments == [
        .localImage(path: "/app/cache/screen.png", detail: "high"),
        .remoteFile(path: "/Users/chenm/Desktop/notes.txt")
    ])
}

@Test func structuredUserMessageKeepsUnavailableAttachmentOutOfProtocolPayload() {
    let message = StructuredUserMessage(
        body: "看看图片",
        attachments: [
            MessageAttachment(
                id: "image-1",
                kind: .image(contentType: "image/png", detail: nil),
                displayName: "screen.png",
                source: .unavailable(reason: "local cache missing")
            )
        ]
    )

    #expect(message.protocolPrompt == "看看图片")
    #expect(message.protocolAttachments.isEmpty)
}

@Test func structuredUserMessageMapsSelectedSkillMentionsIntoCompatiblePrompt() {
    let message = StructuredUserMessage(
        body: "请整理这个 bug",
        mentions: [
            SkillMention(identifier: "triage", displayName: "Triage")
        ]
    )

    #expect(message.protocolPrompt == "$triage 请整理这个 bug")
}

@Test func inputComposerSuggestsSelectsAndRemovesSkillMentionChips() {
    let catalog = SkillCatalog(skills: [
        SkillMention(identifier: "triage", displayName: "Triage"),
        SkillMention(identifier: "to-prd", displayName: "To PRD"),
    ])
    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.text = "$tri 请整理"

    #expect(composer.skillSuggestions(in: catalog).map(\.identifier) == ["triage"])

    composer.selectSkillMention(catalog.skills[0])

    #expect(composer.text == "请整理")
    #expect(composer.canSend == true)
    #expect(composer.message.mentions == [
        SkillMention(identifier: "triage", displayName: "Triage")
    ])

    composer.removeSkillMention(id: "triage")
    #expect(composer.message.mentions.isEmpty)
}

@Test func inputComposerCanSendSelectedSkillMentionWithoutBodyText() {
    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.message.mentions = [
        SkillMention(identifier: "triage", displayName: "Triage")
    ]

    #expect(composer.canSend == true)
    #expect(composer.primaryAction == .send)
}

@Test func inputComposerDoesNotTreatPlainDollarTextAsSkillMentionUntilSelected() {
    let catalog = SkillCatalog(skills: [
        SkillMention(identifier: "triage", displayName: "Triage"),
    ])
    var composer = InputComposer(modelDisplay: "5.5 超高")
    composer.text = "echo $PATH && $nope"

    #expect(composer.skillSuggestions(in: catalog).isEmpty)
    #expect(composer.message.mentions.isEmpty)
}
