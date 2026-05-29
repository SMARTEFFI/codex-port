import Foundation
import Testing
@testable import CodexPortCore

@MainActor
@Test func remoteFileBrowserStoreLoadsNavigatesAndCreatesDirectory() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.directoryListings["~"] = [
        RemoteDirectoryEntry(name: "Projects", path: "~/Projects", kind: .directory)
    ]
    protocolClient.directoryListings["~/Projects"] = [
        RemoteDirectoryEntry(name: "app", path: "~/Projects/app", kind: .directory)
    ]
    let browser = RemoteFileBrowser(protocolClient: protocolClient, homeDirectory: "~", historicalWorkspaces: ["~/Projects"])
    let store = RemoteFileBrowserStore(browser: browser)

    try await store.loadInitialDirectory()
    #expect(store.currentPath == "~")
    #expect(store.entries.map(\.name) == ["Projects"])

    try await store.openDirectory("~/Projects")
    #expect(store.currentPath == "~/Projects")
    #expect(store.entries.map(\.name) == ["app"])

    try await store.createDirectory(named: "new-app")
    #expect(protocolClient.createdDirectories == [
        CreatedDirectory(path: "~/Projects/new-app", recursive: true)
    ])
}

@MainActor
@Test func remoteFileBrowserStoreJumpsToManuallyEnteredPath() async throws {
    let protocolClient = FakeCodexProtocol()
    protocolClient.directoryListings["/workspace/manual"] = [
        RemoteDirectoryEntry(name: "Sources", path: "/workspace/manual/Sources", kind: .directory),
        RemoteDirectoryEntry(name: "Package.swift", path: "/workspace/manual/Package.swift", kind: .file),
    ]
    let browser = RemoteFileBrowser(protocolClient: protocolClient, homeDirectory: "/home/codex", historicalWorkspaces: [])
    let store = RemoteFileBrowserStore(browser: browser)

    try await store.jumpToPath("/workspace/manual")

    #expect(store.currentPath == "/workspace/manual")
    #expect(store.entries.map(\.name) == ["Sources", "Package.swift"])
}
