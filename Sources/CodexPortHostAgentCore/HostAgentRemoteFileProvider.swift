import Foundation
import CodexPortShared

public protocol HostAgentRemoteFileProviding: Sendable {
    func readFile(path: String, maxBytes: Int, requestID: String) async throws -> RelayRemoteFileContent
    func createDirectory(path: String, recursive: Bool) async throws
    func writeFile(path: String, dataBase64: String) async throws
}

public enum HostAgentRemoteFileProviderError: Error, Equatable, Sendable {
    case notFile(String)
    case oversized(path: String, maxBytes: Int)
    case unreadable(String)
    case invalidBase64(String)
}

public struct HostAgentRemoteFileProvider: HostAgentRemoteFileProviding {
    public init() {}

    public func readFile(path: String, maxBytes: Int, requestID: String) async throws -> RelayRemoteFileContent {
        let url = Self.fileURL(forPath: path)
        let resolvedPath = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw HostAgentRemoteFileProviderError.notFile(path)
        }
        let cappedBytes = max(1, maxBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let data = try handle.read(upToCount: cappedBytes + 1) ?? Data()
        guard data.count <= cappedBytes else {
            throw HostAgentRemoteFileProviderError.oversized(path: path, maxBytes: cappedBytes)
        }
        return RelayRemoteFileContent(
            requestID: requestID,
            path: path,
            contentType: Self.contentType(forPath: path),
            byteCount: data.count,
            dataBase64: data.base64EncodedString()
        )
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        try FileManager.default.createDirectory(
            at: Self.fileURL(forPath: path),
            withIntermediateDirectories: recursive
        )
    }

    public func writeFile(path: String, dataBase64: String) async throws {
        guard let data = Data(base64Encoded: dataBase64) else {
            throw HostAgentRemoteFileProviderError.invalidBase64(path)
        }
        let url = Self.fileURL(forPath: path)
        try data.write(to: url, options: [.atomic])
    }

    private static func fileURL(forPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func contentType(forPath path: String) -> String? {
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
}
