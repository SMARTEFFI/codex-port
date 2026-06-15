import CodexPortCore
import Foundation
import UIKit

struct PickedAttachmentHandler {
    func cameraImage(_ image: UIImage) -> PendingAttachment? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let name = "camera-\(UUID().uuidString).jpg"
        return PendingAttachment(
            name: name,
            kind: .image(detail: "high"),
            data: data,
            localCachePath: Self.cacheImage(data: data, suggestedName: name)
        )
    }

    func file(url: URL) throws -> PendingAttachment {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return PendingAttachment(name: url.lastPathComponent, kind: .file, data: try Data(contentsOf: url))
    }

    static func pickedImage(name: String, data: Data) -> PendingAttachment {
        PendingAttachment(
            name: name,
            kind: .image(detail: "high"),
            data: data,
            localCachePath: cacheImage(data: data, suggestedName: name)
        )
    }

    private static func cacheImage(data: Data, suggestedName: String) -> String? {
        do {
            let directory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("MessageImageAttachments", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(suggestedName)
            try data.write(to: url, options: [.atomic])
            return url.path
        } catch {
            return nil
        }
    }
}
