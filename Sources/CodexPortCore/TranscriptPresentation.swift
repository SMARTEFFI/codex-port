import Foundation

public enum TranscriptRowKind: Equatable, Sendable {
    case assistantText
    case userBubble
    case toolOutput
    case thinking
    case status
}

public struct TranscriptRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: TranscriptRowKind
    public var body: String
    public var title: String?
    public var summary: String?
    public var systemImage: String?
    public var isCollapsed: Bool
    public var blocks: [TranscriptBlock]
    public var diffLines: [TranscriptDiffLine]
    public var skillChips: [TranscriptSkillChip]
    public var imageAttachments: [ImageAttachmentGalleryItem]
    public var copyPayload: String?

    public var usesBubble: Bool {
        kind == .userBubble
    }

    public init(
        id: String,
        kind: TranscriptRowKind,
        body: String,
        title: String? = nil,
        summary: String? = nil,
        systemImage: String? = nil,
        isCollapsed: Bool = false,
        blocks: [TranscriptBlock] = [],
        diffLines: [TranscriptDiffLine] = [],
        skillChips: [TranscriptSkillChip] = [],
        imageAttachments: [ImageAttachmentGalleryItem] = [],
        copyPayload: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.body = body
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.isCollapsed = isCollapsed
        self.blocks = blocks
        self.diffLines = diffLines
        self.skillChips = skillChips
        self.imageAttachments = imageAttachments
        self.copyPayload = copyPayload
    }
}

public struct TranscriptSkillChip: Equatable, Sendable {
    public var identifier: String
    public var displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

public enum TranscriptPresentation {
    public static func rows(
        for items: [VisibleItem],
        expandedToolRowIDs: Set<String> = [],
        status: TurnStatus? = nil
    ) -> [TranscriptRow] {
        var rows = items.enumerated().map { index, item in
            switch item {
            case let .userMessage(text):
                return TranscriptRow(id: "\(index)-user", kind: .userBubble, body: text, copyPayload: text)
            case let .structuredUserMessage(message):
                return TranscriptRow(
                    id: "\(index)-user",
                    kind: .userBubble,
                    body: message.body,
                    skillChips: message.mentions.map { TranscriptSkillChip(identifier: $0.identifier, displayName: $0.displayName) },
                    imageAttachments: message.attachments.compactMap(ImageAttachmentGalleryItem.init(attachment:)),
                    copyPayload: message.body
                )
            case let .assistantMessage(text):
                return TranscriptRow(
                    id: "\(index)-assistant",
                    kind: .assistantText,
                    body: text,
                    blocks: MarkdownCodeBlockParser.blocks(in: text),
                    copyPayload: text
                )
            case let .commandOutput(text):
                let id = "\(index)-command"
                let isExpanded = expandedToolRowIDs.contains(id)
                return TranscriptRow(
                    id: id,
                    kind: .toolOutput,
                    body: isExpanded ? text : "",
                    title: "运行命令",
                    summary: firstNonEmptyLine(in: text) ?? "命令输出",
                    systemImage: "terminal",
                    isCollapsed: !isExpanded,
                    blocks: isExpanded ? [.code(language: .shell, text: text)] : [],
                    copyPayload: text
                )
            case let .fileChange(path, diff):
                let id = "\(index)-file"
                let isExpanded = expandedToolRowIDs.contains(id)
                return TranscriptRow(
                    id: id,
                    kind: .toolOutput,
                    body: isExpanded ? diff : "",
                    title: "修改文件",
                    summary: path.isEmpty ? firstNonEmptyLine(in: diff) ?? "文件变更" : path,
                    systemImage: "doc.text",
                    isCollapsed: !isExpanded,
                    diffLines: isExpanded ? TranscriptDiffLine.classify(diff) : [],
                    copyPayload: diff
                )
            }
        }
        if let workingBody = workingBody(for: items, status: status) {
            rows.append(TranscriptRow(
                id: "thinking",
                kind: .thinking,
                body: workingBody,
                copyPayload: workingBody
            ))
        }
        if case let .failed(reason) = status {
            let message = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = message.isEmpty ? "会话失败。" : "会话失败：\(message)"
            rows.append(TranscriptRow(
                id: "status-failed",
                kind: .status,
                body: body,
                copyPayload: body
            ))
        }
        return rows
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func workingBody(for items: [VisibleItem], status: TurnStatus?) -> String? {
        guard status == .running else { return nil }
        guard let latestItem = items.last else { return nil }
        switch latestItem {
        case .userMessage, .structuredUserMessage:
            return "正在思考..."
        case .commandOutput, .fileChange:
            return "正在工作..."
        case .assistantMessage:
            return nil
        }
    }
}

public enum TranscriptCodeLanguage: Equatable, Sendable {
    case swift
    case typescript
    case javascript
    case shell
    case json
    case markdown
    case plainText

    init(label: String) {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swift":
            self = .swift
        case "ts", "tsx", "typescript":
            self = .typescript
        case "js", "jsx", "javascript":
            self = .javascript
        case "sh", "bash", "shell", "zsh":
            self = .shell
        case "json":
            self = .json
        case "md", "markdown":
            self = .markdown
        default:
            self = .plainText
        }
    }
}

public enum TranscriptBlock: Equatable, Sendable {
    case text(String)
    case code(language: TranscriptCodeLanguage, text: String)
}

public enum TranscriptDiffLineKind: Equatable, Sendable {
    case added
    case removed
    case context
}

public struct TranscriptDiffLine: Equatable, Sendable {
    public var kind: TranscriptDiffLineKind
    public var text: String

    public init(kind: TranscriptDiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }

    static func classify(_ diff: String) -> [TranscriptDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            if text.hasPrefix("+") {
                return TranscriptDiffLine(kind: .added, text: text)
            }
            if text.hasPrefix("-") {
                return TranscriptDiffLine(kind: .removed, text: text)
            }
            return TranscriptDiffLine(kind: .context, text: text)
        }
    }
}

private enum MarkdownCodeBlockParser {
    static func blocks(in text: String) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var remainder = text[...]
        while let fenceRange = remainder.range(of: "```") {
            let before = String(remainder[..<fenceRange.lowerBound])
            if !before.isEmpty {
                blocks.append(.text(before))
            }
            let afterFence = remainder[fenceRange.upperBound...]
            let lineEnd = afterFence.firstIndex(of: "\n") ?? afterFence.endIndex
            let language = String(afterFence[..<lineEnd])
            let codeStart = lineEnd == afterFence.endIndex ? lineEnd : afterFence.index(after: lineEnd)
            guard let closingRange = afterFence[codeStart...].range(of: "```") else {
                blocks.append(.text(String(remainder[fenceRange.lowerBound...])))
                return normalized(blocks, original: text)
            }
            blocks.append(.code(
                language: TranscriptCodeLanguage(label: language),
                text: String(afterFence[codeStart..<closingRange.lowerBound])
            ))
            let nextStart = afterFence.index(
                closingRange.upperBound,
                offsetBy: afterFence[closingRange.upperBound...].hasPrefix("\n") ? 1 : 0
            )
            remainder = afterFence[nextStart...]
        }
        if !remainder.isEmpty {
            blocks.append(.text(String(remainder)))
        }
        return normalized(blocks, original: text)
    }

    private static func normalized(_ blocks: [TranscriptBlock], original: String) -> [TranscriptBlock] {
        if blocks.isEmpty {
            return [.text(original)]
        }
        return blocks
    }
}
