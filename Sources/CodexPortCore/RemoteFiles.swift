import Foundation
import CodexPortShared

public enum RemoteFileKind: Equatable, Sendable {
    case file
    case directory
    case missing
}

public struct RemoteDirectoryEntry: Equatable, Sendable {
    public var name: String
    public var path: String
    public var kind: RemoteFileKind

    public init(name: String, path: String, kind: RemoteFileKind) {
        self.name = name
        self.path = path
        self.kind = kind
    }

    init?(json: JSONValue) {
        guard let object = json.object,
              let name = object["name"]?.string ?? object["fileName"]?.string
        else { return nil }
        self.name = name
        self.path = object["path"]?.string ?? name
        if object["isDirectory"]?.boolValue == true {
            self.kind = .directory
        } else if object["isFile"]?.boolValue == true {
            self.kind = .file
        } else {
            self.kind = RemoteFileKind(raw: object["kind"]?.string ?? object["type"]?.string)
        }
    }

    func resolving(relativeTo directory: String) -> RemoteDirectoryEntry {
        guard path == name else { return self }
        let fullPath: String
        if directory.hasSuffix("/") {
            fullPath = directory + name
        } else {
            fullPath = directory + "/" + name
        }
        return RemoteDirectoryEntry(name: name, path: fullPath, kind: kind)
    }
}

public struct RemoteMetadata: Equatable, Sendable {
    public var path: String
    public var kind: RemoteFileKind

    public init(path: String, kind: RemoteFileKind) {
        self.path = path
        self.kind = kind
    }

    init?(json: JSONValue) {
        guard let object = json.object else { return nil }
        self.path = object["path"]?.string ?? ""
        if object["isDirectory"]?.boolValue == true {
            self.kind = .directory
        } else if object["isFile"]?.boolValue == true {
            self.kind = .file
        } else {
            self.kind = RemoteFileKind(raw: object["kind"]?.string ?? object["type"]?.string)
        }
    }
}

extension RemoteFileKind {
    init(raw: String?) {
        switch raw {
        case "directory", "dir":
            self = .directory
        case "file":
            self = .file
        default:
            self = .missing
        }
    }
}

public protocol RemoteFileWriting: AnyObject, Sendable {
    func createDirectory(path: String, recursive: Bool) async throws
    func writeFile(path: String, dataBase64: String) async throws
}

public protocol CodexProtocolClient: RemoteFileWriting {
    func readThread(id: String, includeTurns: Bool) async throws -> JSONValue
    func resumeThread(id: String) async throws -> JSONValue
    func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue
    func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue
    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String) async throws -> JSONValue
    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String, timeoutSeconds: Double?) async throws -> JSONValue
    func startThread(cwd: String, model: CodexModel) async throws -> String
    func startTurn(threadID: String, prompt: String, attachments: [TurnAttachment], model: CodexModel, reasoningEffort: ReasoningEffort, permissionMode: PermissionMode, collaborationMode: CollaborationMode) async throws -> JSONValue
    func steerTurn(threadID: String, turnID: String, prompt: String, attachments: [TurnAttachment]) async throws -> JSONValue
    func interruptTurn(threadID: String, turnID: String) async throws -> JSONValue
    func unsubscribeThread(id: String) async throws -> JSONValue
    func readDirectory(path: String) async throws -> [RemoteDirectoryEntry]
    func getMetadata(path: String) async throws -> RemoteMetadata
}

public extension CodexProtocolClient {
    func startThread(cwd: String) async throws -> String {
        try await startThread(cwd: cwd, model: .gpt55)
    }

    func resumeThread(id: String, initialTurnLimit: Int) async throws -> JSONValue {
        try await resumeThread(id: id)
    }

    func resumeThread(id: String, initialTurnLimit: Int, timeoutSeconds: Double?) async throws -> JSONValue {
        try await resumeThread(id: id, initialTurnLimit: initialTurnLimit)
    }

    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String) async throws -> JSONValue {
        .object([
            "data": .array([]),
            "nextCursor": .null,
            "backwardsCursor": .null
        ])
    }

    func listThreadTurns(threadID: String, cursor: String?, limit: Int, sortDirection: String, itemsView: String, timeoutSeconds: Double?) async throws -> JSONValue {
        try await listThreadTurns(
            threadID: threadID,
            cursor: cursor,
            limit: limit,
            sortDirection: sortDirection,
            itemsView: itemsView
        )
    }
}

public enum RemoteFileBrowserError: Error, Equatable {
    case notDirectory(String)
}

public final class RemoteFileBrowser: Sendable {
    private let protocolClient: CodexProtocolClient
    private let homeDirectory: String
    private let historicalWorkspaces: [String]

    public init(protocolClient: CodexProtocolClient, homeDirectory: String, historicalWorkspaces: [String]) {
        self.protocolClient = protocolClient
        self.homeDirectory = homeDirectory
        self.historicalWorkspaces = historicalWorkspaces
    }

    public func roots() -> [String] {
        [homeDirectory] + historicalWorkspaces
    }

    public var initialDirectory: String {
        homeDirectory
    }

    public func readDirectory(_ path: String) async throws -> [RemoteDirectoryEntry] {
        try await protocolClient.readDirectory(path: path)
            .map { $0.resolving(relativeTo: path) }
    }

    public func createDirectory(_ path: String, recursive: Bool) async throws {
        try await protocolClient.createDirectory(path: path, recursive: recursive)
    }

    public func startThread(cwd: String) async throws -> String {
        let metadata = try await protocolClient.getMetadata(path: cwd)
        guard metadata.kind == .directory else {
            throw RemoteFileBrowserError.notDirectory(cwd)
        }
        return try await protocolClient.startThread(cwd: cwd)
    }
}

@MainActor
public final class RemoteFileBrowserStore {
    private let browser: RemoteFileBrowser
    public private(set) var currentPath: String = ""
    public private(set) var entries: [RemoteDirectoryEntry] = []
    public private(set) var errorMessage: String?
    public var roots: [String] {
        browser.roots()
    }

    public init(browser: RemoteFileBrowser) {
        self.browser = browser
    }

    public func loadInitialDirectory() async throws {
        try await openDirectory(browser.initialDirectory)
    }

    public func openDirectory(_ path: String) async throws {
        currentPath = path
        do {
            entries = try await browser.readDirectory(path)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            throw error
        }
    }

    public func jumpToPath(_ path: String) async throws {
        try await openDirectory(path)
    }

    public func createDirectory(named name: String) async throws {
        let path = joined(path: currentPath, component: name)
        do {
            try await browser.createDirectory(path, recursive: true)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            throw error
        }
    }

    private func joined(path: String, component: String) -> String {
        guard !path.isEmpty else { return component }
        if path.hasSuffix("/") {
            return path + component
        }
        return path + "/" + component
    }
}

public struct PendingAttachment: Equatable, Sendable {
    public var name: String
    public var kind: PendingAttachmentKind
    public var data: Data
    public var localCachePath: String?

    public init(name: String, kind: PendingAttachmentKind, data: Data, localCachePath: String? = nil) {
        self.name = name
        self.kind = kind
        self.data = data
        self.localCachePath = localCachePath
    }
}

public enum PendingAttachmentKind: Equatable, Sendable {
    case image(detail: String?)
    case file
}

public final class AttachmentUploader {
    private let protocolClient: RemoteFileWriting
    private let remoteRoot: String
    private let clock: () -> Date

    public init(protocolClient: RemoteFileWriting, remoteRoot: String, clock: @escaping () -> Date = Date.init) {
        self.protocolClient = protocolClient
        self.remoteRoot = remoteRoot
        self.clock = clock
    }

    public func upload(_ attachments: [PendingAttachment], threadID: String) async throws -> [TurnAttachment] {
        let timestamp = Int(clock().timeIntervalSince1970)
        let directory = "\(remoteRoot)/\(threadID)/\(timestamp)"
        try await protocolClient.createDirectory(path: directory, recursive: true)

        var uploaded: [TurnAttachment] = []
        for attachment in attachments {
            let path = "\(directory)/\(attachment.name)"
            try await protocolClient.writeFile(path: path, dataBase64: attachment.data.base64EncodedString())
            switch attachment.kind {
            case let .image(detail):
                uploaded.append(.localImage(path: path, detail: detail))
            case .file:
                uploaded.append(.remoteFile(path: path))
            }
        }
        return uploaded
    }
}

public final class AttachmentComposerBridge {
    private let uploader: AttachmentUploader

    public init(uploader: AttachmentUploader) {
        self.uploader = uploader
    }

    public func attach(_ pending: [PendingAttachment], threadID: String, to composer: inout InputComposer) async throws {
        let uploaded = try await uploader.upload(pending, threadID: threadID)
        composer.attachments.append(contentsOf: uploaded)
        composer.message.attachments.append(contentsOf: zip(pending, uploaded).map { pending, uploaded in
            MessageAttachment(
                id: pending.name,
                kind: MessageAttachmentKind(pending.kind),
                displayName: pending.name,
                source: MessageAttachmentSource(pending: pending, uploaded: uploaded)
            )
        })
    }
}

private extension MessageAttachmentKind {
    init(_ pendingKind: PendingAttachmentKind) {
        switch pendingKind {
        case let .image(detail):
            self = .image(contentType: nil, detail: detail)
        case .file:
            self = .file(contentType: nil)
        }
    }
}

private extension MessageAttachmentSource {
    init(pending: PendingAttachment, uploaded: TurnAttachment) {
        switch pending.kind {
        case .image:
            self = .localCache(path: pending.localCachePath ?? pending.name)
        case .file:
            switch uploaded {
            case let .localImage(path, _), let .remoteFile(path):
                self = .remoteHostPath(path)
            }
        }
    }
}
