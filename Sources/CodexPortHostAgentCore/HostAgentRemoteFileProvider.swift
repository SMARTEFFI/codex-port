import Foundation
import CodexPortShared

public protocol HostAgentRemoteFileProviding: Sendable {
    func readFile(path: String, maxBytes: Int, requestID: String) async throws -> RelayRemoteFileContent
}

public enum HostAgentRemoteFileProviderError: Error, Equatable, Sendable {
    case notFile(String)
    case oversized(path: String, maxBytes: Int)
    case unreadable(String)
}

public struct HostAgentRemoteFileProvider: HostAgentRemoteFileProviding {
    public init() {}

    public func readFile(path: String, maxBytes: Int, requestID: String) async throws -> RelayRemoteFileContent {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
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
