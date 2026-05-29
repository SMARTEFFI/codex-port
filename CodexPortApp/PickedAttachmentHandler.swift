import CodexPortCore
import Foundation
import UIKit

struct PickedAttachmentHandler {
    func cameraImage(_ image: UIImage) -> PendingAttachment? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return PendingAttachment(name: "camera.jpg", kind: .image(detail: "high"), data: data)
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
}
