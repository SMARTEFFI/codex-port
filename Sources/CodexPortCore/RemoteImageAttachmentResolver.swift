import Foundation

public struct RemoteFileContent: Equatable, Sendable {
    public var path: String
    public var contentType: String?
    public var byteCount: Int
    public var data: Data

    public init(path: String, contentType: String?, byteCount: Int, data: Data) {
        self.path = path
        self.contentType = contentType
        self.byteCount = byteCount
        self.data = data
    }
}

public enum RemoteImageReadError: Error, Equatable, Sendable {
    case unauthorized
    case notFound
    case revoked
    case transport(String)
}

public protocol RemoteImageReading: AnyObject {
    func readRemoteFile(path: String, maxBytes: Int) async -> Result<RemoteFileContent, RemoteImageReadError>
}

public enum RemoteImageCacheError: Error, Equatable, Sendable {
    case writeFailed(String)
}

public protocol RemoteImageCaching: AnyObject {
    func store(_ content: RemoteFileContent, attachmentID: String) async -> Result<String, RemoteImageCacheError>
}

public struct RemoteImageAttachmentResolver {
    public var maxBytes: Int
    private let reader: RemoteImageReading
    private let cache: RemoteImageCaching

    public init(reader: RemoteImageReading, cache: RemoteImageCaching, maxBytes: Int) {
        self.reader = reader
        self.cache = cache
        self.maxBytes = maxBytes
    }

    public func resolve(_ attachment: MessageAttachment) async -> MessageAttachment {
        guard case let .image(contentType, _) = attachment.kind else {
            return attachment
        }
        guard case let .remoteHostPath(path) = attachment.source else {
            return attachment
        }
        guard RemoteImageContentPolicy.isSupportedImageContentType(contentType) else {
            return attachment.withSource(.unavailable(reason: "不是支持的图片类型"))
        }

        switch await reader.readRemoteFile(path: path, maxBytes: maxBytes) {
        case let .failure(error):
            return attachment.withSource(.unavailable(reason: error.userMessage))
        case let .success(content):
            guard RemoteImageContentPolicy.isSupportedImageContentType(content.contentType, path: content.path) else {
                return attachment.withSource(.unavailable(reason: "不是支持的图片类型"))
            }
            guard content.byteCount <= maxBytes, content.data.count <= maxBytes else {
                return attachment.withSource(.unavailable(reason: "图片超过大小限制"))
            }
            switch await cache.store(content, attachmentID: attachment.id) {
            case let .success(localPath):
                return attachment.withSource(.localCache(path: localPath))
            case let .failure(error):
                return attachment.withSource(.unavailable(reason: error.userMessage))
            }
        }
    }
}

public enum MarkdownImageCompatibilityParser {
    public static func attachmentCandidates(fromUserMarkdown markdown: String) -> [MessageAttachment] {
        imageTargets(in: markdown).enumerated().compactMap { index, target in
            guard let path = normaliseLocalHostPath(target) else { return nil }
            let displayName = URL(fileURLWithPath: path).lastPathComponent
            return MessageAttachment(
                id: "markdown-image-\(index)",
                kind: .image(contentType: RemoteImageContentPolicy.contentType(forPath: path), detail: nil),
                displayName: displayName.isEmpty ? "图片" : displayName,
                source: .remoteHostPath(path)
            )
        }
    }

    public static func attachmentCandidates(fromAssistantMarkdown _: String) -> [MessageAttachment] {
        []
    }

    public static func displayTextWithoutImageMarkdown(_ markdown: String) -> String {
        var display = ""
        var index = markdown.startIndex
        while let openRange = markdown[index...].range(of: "![") {
            guard let markerRange = markdown[openRange.upperBound...].range(of: "]("),
                  let closeIndex = markdown[markerRange.upperBound...].firstIndex(of: ")")
            else {
                break
            }
            display.append(contentsOf: markdown[index..<openRange.lowerBound])
            index = markdown.index(after: closeIndex)
        }
        display.append(contentsOf: markdown[index...])
        return display
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func imageTargets(in markdown: String) -> [String] {
        var targets: [String] = []
        var index = markdown.startIndex
        while let openRange = markdown[index...].range(of: "![") {
            guard let markerRange = markdown[openRange.upperBound...].range(of: "](") else {
                break
            }
            guard let closeIndex = markdown[markerRange.upperBound...].firstIndex(of: ")") else {
                break
            }
            targets.append(String(markdown[markerRange.upperBound..<closeIndex]))
            index = markdown.index(after: closeIndex)
        }
        return targets
    }

    private static func normaliseLocalHostPath(_ rawTarget: String) -> String? {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("<"), target.hasSuffix(">") {
            target = String(target.dropFirst().dropLast())
        } else if let firstToken = target.split(separator: " ", maxSplits: 1).first {
            target = String(firstToken)
        }
        target = target.removingPercentEncoding ?? target

        if target.lowercased().hasPrefix("file://"),
           let url = URL(string: target) {
            target = url.path
        }

        if target.hasPrefix("/") || target.hasPrefix("~/") || isWindowsAbsolutePath(target) {
            return target
        }
        return nil
    }

    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        guard path.count > 2 else { return false }
        let characters = Array(path)
        return characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/") && characters[0].isLetter
    }
}

private enum RemoteImageContentPolicy {
    static let supportedContentTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
        "image/heic",
        "image/heif"
    ]

    static func isSupportedImageContentType(_ contentType: String?, path: String? = nil) -> Bool {
        if let declaredContentType = contentType {
            return supportedContentTypes.contains(canonicalContentType(declaredContentType))
        }
        if let path {
            return Self.contentType(forPath: path).map { isSupportedImageContentType($0) } ?? false
        }
        return true
    }

    static func contentType(forPath path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        default:
            return nil
        }
    }

    private static func canonicalContentType(_ contentType: String) -> String {
        contentType
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

private extension MessageAttachment {
    func withSource(_ source: MessageAttachmentSource) -> MessageAttachment {
        MessageAttachment(id: id, kind: kind, displayName: displayName, source: source)
    }
}

private extension RemoteImageReadError {
    var userMessage: String {
        switch self {
        case .unauthorized, .revoked:
            return "当前 Pairing 无权读取远端图片"
        case .notFound:
            return "远端图片不存在"
        case let .transport(message):
            return message.isEmpty ? "远端图片读取失败" : message
        }
    }
}

private extension RemoteImageCacheError {
    var userMessage: String {
        switch self {
        case let .writeFailed(message):
            return message.isEmpty ? "图片缓存失败" : message
        }
    }
}
