import Foundation
import Testing
@testable import CodexPortCore

@Test func remoteImageAttachmentResolverFetchesAllowedImageAndCachesIt() async {
    let reader = RecordingRemoteImageReader(result: .success(RemoteFileContent(
        path: "/Users/chenm/Desktop/screen.png",
        contentType: "image/png",
        byteCount: 4,
        data: Data([0x89, 0x50, 0x4E, 0x47])
    )))
    let cache = InMemoryRemoteImageCache()
    let resolver = RemoteImageAttachmentResolver(reader: reader, cache: cache, maxBytes: 10)
    let attachment = MessageAttachment(
        id: "remote-image",
        kind: .image(contentType: "image/png", detail: "high"),
        displayName: "screen.png",
        source: .remoteHostPath("/Users/chenm/Desktop/screen.png")
    )

    let resolved = await resolver.resolve(attachment)

    #expect(reader.requestedPaths == ["/Users/chenm/Desktop/screen.png"])
    #expect(resolved.source == .localCache(path: "/cache/remote-image.png"))
}

@Test func remoteImageAttachmentResolverRejectsNonImageOversizeAndUnauthorizedReads() async {
    let nonImage = await RemoteImageAttachmentResolver(
        reader: RecordingRemoteImageReader(result: .success(RemoteFileContent(
            path: "/tmp/notes.txt",
            contentType: "text/plain",
            byteCount: 5,
            data: Data("hello".utf8)
        ))),
        cache: InMemoryRemoteImageCache(),
        maxBytes: 10
    ).resolve(remoteImage(path: "/tmp/notes.txt", contentType: "text/plain"))

    let oversized = await RemoteImageAttachmentResolver(
        reader: RecordingRemoteImageReader(result: .success(RemoteFileContent(
            path: "/tmp/large.png",
            contentType: "image/png",
            byteCount: 11,
            data: Data(repeating: 0, count: 11)
        ))),
        cache: InMemoryRemoteImageCache(),
        maxBytes: 10
    ).resolve(remoteImage(path: "/tmp/large.png"))

    let unauthorized = await RemoteImageAttachmentResolver(
        reader: RecordingRemoteImageReader(result: .failure(.unauthorized)),
        cache: InMemoryRemoteImageCache(),
        maxBytes: 10
    ).resolve(remoteImage(path: "/tmp/screen.png"))

    #expect(nonImage.source == .unavailable(reason: "不是支持的图片类型"))
    #expect(oversized.source == .unavailable(reason: "图片超过大小限制"))
    #expect(unauthorized.source == .unavailable(reason: "当前 Pairing 无权读取远端图片"))
}

@Test func markdownCompatibilityLimitsAssistantMarkdownCandidatesToImages() async {
    let reader = RecordingRemoteImageReader(result: .failure(.unauthorized))
    let resolver = RemoteImageAttachmentResolver(reader: reader, cache: InMemoryRemoteImageCache(), maxBytes: 10)

    let candidates = MarkdownImageCompatibilityParser.attachmentCandidates(
        fromUserMarkdown: #"![s](/Users/chenm/Desktop/screen.png)"#
    )
    let assistantImageCandidates = MarkdownImageCompatibilityParser.attachmentCandidates(
        fromAssistantMarkdown: #"![s](/Users/chenm/Desktop/screen.png)"#
    )
    let assistantLinkCandidates = MarkdownImageCompatibilityParser.attachmentCandidates(
        fromAssistantMarkdown: #"[report](/Users/chenm/Desktop/report.html)"#
    )

    _ = await resolver.resolve(candidates[0])

    #expect(candidates.first?.source == .remoteHostPath("/Users/chenm/Desktop/screen.png"))
    #expect(assistantImageCandidates.first?.source == .remoteHostPath("/Users/chenm/Desktop/screen.png"))
    #expect(assistantLinkCandidates.isEmpty)
    #expect(reader.requestedPaths == ["/Users/chenm/Desktop/screen.png"])
}

@Test func markdownCompatibilityRemovesUserImageMarkdownFromDisplayText() {
    let displayText = MarkdownImageCompatibilityParser.displayTextWithoutImageMarkdown(
        "我会看这张图\n![photo](~/.codex-port/attachments/thread/123/photo-1.jpg)\n继续"
    )

    #expect(displayText == "我会看这张图\n继续")
}

private func remoteImage(path: String, contentType: String = "image/png") -> MessageAttachment {
    MessageAttachment(
        id: path,
        kind: .image(contentType: contentType, detail: nil),
        displayName: URL(fileURLWithPath: path).lastPathComponent,
        source: .remoteHostPath(path)
    )
}

private final class RecordingRemoteImageReader: RemoteImageReading {
    var requestedPaths: [String] = []
    private let result: Result<RemoteFileContent, RemoteImageReadError>

    init(result: Result<RemoteFileContent, RemoteImageReadError>) {
        self.result = result
    }

    func readRemoteFile(path: String, maxBytes: Int) async -> Result<RemoteFileContent, RemoteImageReadError> {
        requestedPaths.append(path)
        return result
    }
}

private final class InMemoryRemoteImageCache: RemoteImageCaching {
    func store(_ content: RemoteFileContent, attachmentID: String) async -> Result<String, RemoteImageCacheError> {
        let ext = URL(fileURLWithPath: content.path).pathExtension
        return .success("/cache/\(attachmentID).\(ext.isEmpty ? "img" : ext)")
    }
}
