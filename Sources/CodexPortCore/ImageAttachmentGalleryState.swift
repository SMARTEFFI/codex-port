import Foundation

public struct ImageAttachmentGalleryState: Equatable, Sendable {
    public private(set) var items: [ImageAttachmentGalleryItem]
    public private(set) var currentIndex: Int
    public private(set) var saveFeedback: ImageAttachmentSaveFeedback?

    public init(items: [ImageAttachmentGalleryItem], opening attachmentID: String) {
        self.items = items
        self.currentIndex = items.firstIndex(where: { $0.id == attachmentID }) ?? 0
        self.saveFeedback = nil
    }

    public init(attachments: [MessageAttachment], opening attachmentID: String) {
        self.items = attachments.compactMap(ImageAttachmentGalleryItem.init(attachment:))
        self.currentIndex = items.firstIndex(where: { $0.id == attachmentID }) ?? 0
        self.saveFeedback = nil
    }

    public var currentItem: ImageAttachmentGalleryItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public mutating func moveNext() {
        guard !items.isEmpty else { return }
        currentIndex = min(currentIndex + 1, items.count - 1)
    }

    public mutating func movePrevious() {
        guard !items.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
    }

    public mutating func replaceItem(_ item: ImageAttachmentGalleryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        currentIndex = index
    }

    public mutating func saveCurrentImage(using saver: PhotoSaving) async {
        guard let currentItem else {
            saveFeedback = .failure("没有可保存的图片")
            return
        }
        guard case let .available(localPath) = currentItem.availability else {
            saveFeedback = .failure(currentItem.unavailableReason ?? "图片不可用")
            return
        }
        switch await saver.saveImage(atLocalPath: localPath) {
        case .success:
            saveFeedback = .success("已保存到照片")
        case let .failure(error):
            saveFeedback = .failure(error.userMessage)
        }
    }

    public mutating func clearSaveFeedback() {
        saveFeedback = nil
    }
}

public struct ImageAttachmentGalleryItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var availability: ImageAttachmentAvailability

    public init(id: String, displayName: String, availability: ImageAttachmentAvailability) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
    }

    public init?(attachment: MessageAttachment) {
        guard case .image = attachment.kind else { return nil }
        id = attachment.id
        displayName = attachment.displayName
        switch attachment.source {
        case let .localCache(path):
            availability = .available(localPath: path)
        case let .remoteHostPath(path):
            availability = .remote(path: path)
        case let .unavailable(reason):
            availability = .unavailable(reason)
        }
    }

    var unavailableReason: String? {
        if case let .unavailable(reason) = availability {
            return reason
        }
        return nil
    }
}

public enum ImageAttachmentAvailability: Equatable, Sendable {
    case available(localPath: String)
    case remote(path: String)
    case unavailable(String)
}

public enum ImageAttachmentSaveFeedback: Equatable, Sendable {
    case success(String)
    case failure(String)
}

public protocol PhotoSaving: AnyObject, Sendable {
    func saveImage(atLocalPath path: String) async -> Result<Void, PhotoSaveError>
}

public enum PhotoSaveError: Error, Equatable, Sendable {
    case permissionDenied
    case systemFailure(String)

    public var userMessage: String {
        switch self {
        case .permissionDenied:
            return "没有照片保存权限"
        case let .systemFailure(message):
            return message
        }
    }
}
