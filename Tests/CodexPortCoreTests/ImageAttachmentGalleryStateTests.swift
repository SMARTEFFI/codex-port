import Testing
@testable import CodexPortCore

@Test func imageAttachmentGalleryOpensClickedLocalImageAndMovesBetweenImages() {
    let images = [
        MessageAttachment(
            id: "image-1",
            kind: .image(contentType: "image/png", detail: "high"),
            displayName: "one.png",
            source: .localCache(path: "/cache/one.png")
        ),
        MessageAttachment(
            id: "file-1",
            kind: .file(contentType: "text/plain"),
            displayName: "notes.txt",
            source: .localCache(path: "/cache/notes.txt")
        ),
        MessageAttachment(
            id: "image-2",
            kind: .image(contentType: "image/jpeg", detail: "high"),
            displayName: "two.jpg",
            source: .localCache(path: "/cache/two.jpg")
        ),
    ]

    var gallery = ImageAttachmentGalleryState(attachments: images, opening: "image-2")

    #expect(gallery.items.map(\.id) == ["image-1", "image-2"])
    #expect(gallery.currentItem?.id == "image-2")
    gallery.movePrevious()
    #expect(gallery.currentItem?.id == "image-1")
    gallery.moveNext()
    #expect(gallery.currentItem?.id == "image-2")
}

@Test func imageAttachmentGalleryReportsUnavailableWhenLocalCacheMissing() async {
    let attachment = MessageAttachment(
        id: "image-1",
        kind: .image(contentType: "image/png", detail: "high"),
        displayName: "one.png",
        source: .unavailable(reason: "local cache missing")
    )
    var gallery = ImageAttachmentGalleryState(attachments: [attachment], opening: "image-1")
    let saver = RecordingPhotoSaver(result: .failure(.permissionDenied))

    await gallery.saveCurrentImage(using: saver)

    #expect(gallery.currentItem?.availability == .unavailable("local cache missing"))
    #expect(gallery.saveFeedback == .failure("local cache missing"))
    #expect(saver.savedPaths.isEmpty)
}

@Test func imageAttachmentGallerySurfacesPhotoSaveSuccessAndFailure() async {
    let attachment = MessageAttachment(
        id: "image-1",
        kind: .image(contentType: "image/png", detail: "high"),
        displayName: "one.png",
        source: .localCache(path: "/cache/one.png")
    )
    var successGallery = ImageAttachmentGalleryState(attachments: [attachment], opening: "image-1")
    let successSaver = RecordingPhotoSaver(result: .success(()))

    await successGallery.saveCurrentImage(using: successSaver)

    #expect(successSaver.savedPaths == ["/cache/one.png"])
    #expect(successGallery.saveFeedback == .success("已保存到照片"))

    var failureGallery = ImageAttachmentGalleryState(attachments: [attachment], opening: "image-1")
    await failureGallery.saveCurrentImage(using: RecordingPhotoSaver(result: .failure(.systemFailure("Photos unavailable"))))

    #expect(failureGallery.saveFeedback == .failure("Photos unavailable"))
}

private final class RecordingPhotoSaver: PhotoSaving, @unchecked Sendable {
    var savedPaths: [String] = []
    private let result: Result<Void, PhotoSaveError>

    init(result: Result<Void, PhotoSaveError>) {
        self.result = result
    }

    func saveImage(atLocalPath path: String) async -> Result<Void, PhotoSaveError> {
        savedPaths.append(path)
        return result
    }
}
