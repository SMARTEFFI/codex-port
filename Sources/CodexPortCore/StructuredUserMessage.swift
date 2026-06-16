import Foundation
import CodexPortShared

public struct StructuredUserMessage: Equatable, Sendable {
    public var body: String
    public var mentions: [SkillMention]
    public var attachments: [MessageAttachment]

    public init(
        body: String,
        mentions: [SkillMention] = [],
        attachments: [MessageAttachment] = []
    ) {
        self.body = body
        self.mentions = mentions
        self.attachments = attachments
    }

    public var protocolPrompt: String {
        guard !mentions.isEmpty else { return body }
        let mentionPrefix = mentions.map { "$\($0.identifier)" }.joined(separator: " ")
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return mentionPrefix }
        return "\(mentionPrefix) \(trimmedBody)"
    }

    public var protocolAttachments: [TurnAttachment] {
        attachments.compactMap(\.protocolAttachment)
    }
}

public struct SkillMention: Equatable, Sendable {
    public var identifier: String
    public var displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

public struct SkillCatalog: Equatable, Sendable {
    public var skills: [SkillMention]

    public init(skills: [SkillMention]) {
        self.skills = skills
    }

    public static let empty = SkillCatalog(skills: [])
    public static let codexDefaults = SkillCatalog(skills: [
        SkillMention(identifier: "triage", displayName: "Triage"),
        SkillMention(identifier: "to-prd", displayName: "To PRD"),
        SkillMention(identifier: "to-issues", displayName: "To Issues"),
        SkillMention(identifier: "grill-with-docs", displayName: "Grill With Docs"),
        SkillMention(identifier: "tdd", displayName: "TDD"),
        SkillMention(identifier: "diagnose", displayName: "Diagnose"),
        SkillMention(identifier: "browser", displayName: "Browser"),
    ])
}

public struct MessageAttachment: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: MessageAttachmentKind
    public var displayName: String
    public var source: MessageAttachmentSource

    public init(
        id: String,
        kind: MessageAttachmentKind,
        displayName: String,
        source: MessageAttachmentSource
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.source = source
    }

    var protocolAttachment: TurnAttachment? {
        switch (kind, source) {
        case let (.image(_, detail), .localCache(path)):
            return .localImage(path: path, detail: detail)
        case (.image, .remoteHostPath):
            return nil
        case (.file, let .localCache(path)):
            return .remoteFile(path: path)
        case (.file, let .remoteHostPath(path)):
            return .remoteFile(path: path)
        case (_, .unavailable):
            return nil
        }
    }
}

public enum MessageAttachmentKind: Equatable, Sendable {
    case image(contentType: String?, detail: String?)
    case file(contentType: String?)
}

public enum MessageAttachmentSource: Equatable, Sendable {
    case localCache(path: String)
    case remoteHostPath(String)
    case unavailable(reason: String)
}
