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
    public var links: [TranscriptLink]
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
        links: [TranscriptLink] = [],
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
        self.links = links
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

public struct TranscriptLink: Equatable, Identifiable, Sendable {
    public var id: String
    public var displayText: String
    public var target: String
    public var imageAttachmentID: String?

    public init(id: String, displayText: String, target: String, imageAttachmentID: String? = nil) {
        self.id = id
        self.displayText = displayText
        self.target = target
        self.imageAttachmentID = imageAttachmentID
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
                let assistantMarkdown = MarkdownImageCompatibilityParser.assistantPresentation(from: text)
                return TranscriptRow(
                    id: "\(index)-assistant",
                    kind: .assistantText,
                    body: assistantMarkdown.displayText,
                    blocks: MarkdownCodeBlockParser.blocks(in: assistantMarkdown.displayText),
                    links: assistantMarkdown.links,
                    imageAttachments: assistantMarkdown.imageAttachments.compactMap(ImageAttachmentGalleryItem.init(attachment:)),
                    copyPayload: text
                )
            case let .commandOutput(text):
                let id = "\(index)-command"
                let isExpanded = expandedToolRowIDs.contains(id)
                let tool = commandToolPresentation(from: text)
                return TranscriptRow(
                    id: id,
                    kind: .toolOutput,
                    body: isExpanded ? tool.body : "",
                    title: tool.title,
                    summary: nil,
                    systemImage: tool.systemImage,
                    isCollapsed: !isExpanded,
                    blocks: isExpanded ? tool.blocks : [],
                    copyPayload: tool.copyPayload
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

    private static func firstActionLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "---" }
    }

    private static func commandToolPresentation(from text: String) -> CommandToolPresentation {
        let stripped = strippingLeadingToolMarkers(from: text)
        let body = stripped.text
        if let readFile = readFilePresentation(from: body) {
            return readFile
        }
        let latestLabel = stripped.labels.last
        if let command = shellCommandLine(in: body, allowBareFirstLine: latestLabel.map(isCommandExecutionLabel) ?? true) {
            return CommandToolPresentation(
                title: "已运行 \(command)",
                body: body,
                systemImage: "terminal",
                blocks: body.isEmpty ? [] : [.code(language: .shell, text: body)],
                copyPayload: body
            )
        }
        if let label = latestLabel, !label.isEmpty {
            let fallbackTitle = isCommandExecutionLabel(label) ? "已运行命令" : "已调用 \(label)"
            return CommandToolPresentation(
                title: fallbackTitle,
                body: body,
                systemImage: isCommandExecutionLabel(label) ? "terminal" : "wrench.and.screwdriver",
                blocks: body.isEmpty ? [] : [.code(language: .shell, text: body)],
                copyPayload: body.isEmpty ? text : body
            )
        }
        let firstLine = firstActionLine(in: body)
        return CommandToolPresentation(
            title: firstLine.map { "已运行 \($0)" } ?? "已运行命令",
            body: body,
            systemImage: "terminal",
            blocks: body.isEmpty ? [] : [.code(language: .shell, text: body)],
            copyPayload: body
        )
    }

    private static func readFilePresentation(from text: String) -> CommandToolPresentation? {
        let first = firstLineAndRest(in: text)
        if let path = readFilePath(fromMarkerLine: first.line) {
            let body = first.rest
            let language = codeLanguage(forPath: path)
            return CommandToolPresentation(
                title: "已读取 \(path)",
                body: body,
                systemImage: "doc.text",
                blocks: body.isEmpty ? [] : [.code(language: language, text: body)],
                copyPayload: body.isEmpty ? text : body
            )
        }
        guard looksLikeSkillMarkdown(text) else { return nil }
        return CommandToolPresentation(
            title: "已读取 SKILL.md",
            body: text,
            systemImage: "doc.text",
            blocks: [.code(language: .markdown, text: text)],
            copyPayload: text
        )
    }

    private static func readFilePath(fromMarkerLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["读取文件：", "读取文件:", "已读取 "] {
            if trimmed.hasPrefix(prefix) {
                let path = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }

    private static func shellCommandLine(in text: String, allowBareFirstLine: Bool) -> String? {
        guard let line = firstActionLine(in: text) else { return nil }
        if line.hasPrefix("$ ") {
            let command = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        if line.hasPrefix("$") {
            let command = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        guard allowBareFirstLine else { return nil }
        return line
    }

    private static func strippingLeadingToolMarkers(from text: String) -> (text: String, labels: [String]) {
        var remainder = text
        var labels: [String] = []
        while true {
            let first = firstLineAndRest(in: remainder)
            let line = first.line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label = toolInvocationLabel(from: line) else {
                return (remainder, labels)
            }
            labels.append(label)
            remainder = first.rest
        }
    }

    private static func toolInvocationLabel(from line: String) -> String? {
        for prefix in ["开始工具调用：", "开始工具调用:", "工具调用：", "工具调用:"] {
            if line.hasPrefix(prefix) {
                let label = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return label.isEmpty ? nil : label
            }
        }
        return nil
    }

    private static func isCommandExecutionLabel(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "commandexecution" || normalized == "command_execution" || normalized == "exec"
    }

    private static func firstLineAndRest(in text: String) -> (line: String, rest: String) {
        guard let newline = text.firstIndex(where: \.isNewline) else {
            return (text, "")
        }
        let restStart = text.index(after: newline)
        return (String(text[..<newline]), String(text[restStart...]))
    }

    private static func codeLanguage(forPath path: String) -> TranscriptCodeLanguage {
        let ext = ((path as NSString).pathExtension).lowercased()
        switch ext {
        case "swift":
            return .swift
        case "ts", "tsx":
            return .typescript
        case "js", "jsx":
            return .javascript
        case "sh", "bash", "zsh":
            return .shell
        case "json":
            return .json
        case "md", "markdown":
            return .markdown
        default:
            return .plainText
        }
    }

    private static func looksLikeSkillMarkdown(_ text: String) -> Bool {
        let prefix = String(text.prefix(2_000))
        return prefix.hasPrefix("---\n")
            && prefix.contains("\nname:")
            && prefix.contains("\ndescription:")
            && prefix.contains("\n# ")
            && prefix.lowercased().contains("skill")
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
            return "正在回复..."
        }
    }
}

private struct CommandToolPresentation {
    var title: String
    var body: String
    var systemImage: String
    var blocks: [TranscriptBlock]
    var copyPayload: String
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
