import Foundation
import Testing
@testable import CodexPortCore

@Test func remoteFileBrowserStartsFromHomeAndCreatesDirectoriesRecursivelyBeforeStartingThread() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.directoryListings["/home/codex"] = [
        RemoteDirectoryEntry(name: "Projects", path: "/home/codex/Projects", kind: .directory)
    ]
    protocolClient.metadata["/home/codex/Projects/new-app"] = RemoteMetadata(path: "/home/codex/Projects/new-app", kind: .directory)
    protocolClient.startedThreadID = "thread-new"

    let browser = RemoteFileBrowser(protocolClient: protocolClient, homeDirectory: "/home/codex", historicalWorkspaces: ["/repo/existing"])

    #expect(browser.roots() == ["/home/codex", "/repo/existing"])
    #expect(try await browser.readDirectory("/home/codex").first?.name == "Projects")

    try await browser.createDirectory("/home/codex/Projects/new-app", recursive: true)
    let threadID = try await browser.startThread(cwd: "/home/codex/Projects/new-app")

    #expect(threadID == "thread-new")
    #expect(protocolClient.createdDirectories == [CreatedDirectory(path: "/home/codex/Projects/new-app", recursive: true)])
    #expect(protocolClient.startedThreadCWD == "/home/codex/Projects/new-app")
}

@Test func remoteFileBrowserRejectsFilesAsThreadCwd() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.metadata["/repo/file.txt"] = RemoteMetadata(path: "/repo/file.txt", kind: .file)
    let browser = RemoteFileBrowser(protocolClient: protocolClient, homeDirectory: "/home/codex", historicalWorkspaces: [])

    await #expect(throws: RemoteFileBrowserError.notDirectory("/repo/file.txt")) {
        try await browser.startThread(cwd: "/repo/file.txt")
    }
}
