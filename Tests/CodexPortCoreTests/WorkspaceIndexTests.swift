import Foundation
import Testing
@testable import CodexPortCore

@Test func workspaceIndexProjectsThreadsByProjectAndByTimeWithoutScanningFilesystem() {
    let threads = [
        ThreadSummary(
            id: "older-api",
            cwd: "/Users/chenm/Projects/api",
            updatedAt: Date(timeIntervalSince1970: 10),
            preview: "Add auth",
            gitInfo: GitInfo(repository: "api", branch: "main")
        ),
        ThreadSummary(
            id: "newer-api",
            cwd: "/Users/chenm/Projects/api",
            updatedAt: Date(timeIntervalSince1970: 30),
            preview: "Fix deploy",
            gitInfo: GitInfo(repository: "api", branch: "release")
        ),
        ThreadSummary(
            id: "web",
            cwd: "/Users/chenm/Projects/web",
            updatedAt: Date(timeIntervalSince1970: 20),
            preview: "Polish input",
            gitInfo: nil
        ),
        ThreadSummary(
            id: "missing-cwd",
            cwd: nil,
            updatedAt: Date(timeIntervalSince1970: 40),
            preview: "Ignore me",
            gitInfo: nil
        )
    ]

    let index = WorkspaceIndex(threads: threads)

    let projects = index.projects()
    #expect(projects.map(\.cwd) == ["/Users/chenm/Projects/api", "/Users/chenm/Projects/web"])
    #expect(projects[0].sessionCount == 2)
    #expect(projects[0].latestPreview == "Fix deploy")
    #expect(projects[0].gitInfo?.branch == "release")

    let recent = index.recentThreads()
    #expect(recent.map(\.id) == ["newer-api", "web", "older-api"])
}

@Test func emptyWorkspaceIndexReturnsEmptyProjections() {
    let index = WorkspaceIndex(threads: [])

    #expect(index.projects().isEmpty)
    #expect(index.recentThreads().isEmpty)
}
