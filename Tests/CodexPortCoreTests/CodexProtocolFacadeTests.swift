import Foundation
import Testing
@testable import CodexPortCore

@Test func facadeUsesOfficialCodexAppServerMethodNames() async throws {
    let transport = RecordingCodexTransport()
    let facade = CodexProtocolFacade(transport: transport)

    _ = try await facade.initialize(clientName: "Codex Port", suppressNotifications: ["thread/started"])
    _ = try await facade.listThreads(limit: 20)
    _ = try await facade.readThread(id: "thread-1", includeTurns: true)
    _ = try await facade.resumeThread(id: "thread-1")
    _ = try await facade.startThread(cwd: "/repo")
    _ = try await facade.steerTurn(threadID: "thread-1", turnID: "turn-running", prompt: "补充", attachments: [])
    _ = try await facade.interruptTurn(threadID: "thread-1", turnID: "turn-1")
    _ = try await facade.unsubscribeThread(id: "thread-1")
    _ = try await facade.readDirectory(path: "/repo")
    _ = try await facade.getMetadata(path: "/repo/file.txt")
    _ = try await facade.createDirectory(path: "/repo/new", recursive: true)
    _ = try await facade.writeFile(path: "/repo/file.txt", dataBase64: "SGk=")

    #expect(transport.methods == [
        "initialize",
        "thread/list",
        "thread/read",
        "thread/resume",
        "thread/start",
        "turn/steer",
        "turn/interrupt",
        "thread/unsubscribe",
        "fs/readDirectory",
        "fs/getMetadata",
        "fs/createDirectory",
        "fs/writeFile"
    ])
    let initializeParams = try #require(transport.requests.first?.params.object)
    #expect(initializeParams["clientInfo"]?.object?["name"] == .string("Codex Port"))
    #expect(initializeParams["clientInfo"]?.object?["title"] == .null)
    #expect(initializeParams["clientInfo"]?.object?["version"] == .string(CodexProtocolFacade.clientVersion))
    #expect(initializeParams["capabilities"]?.object?["experimentalApi"] == .bool(true))
    #expect(initializeParams["capabilities"]?.object?["requestAttestation"] == .bool(false))
    #expect(initializeParams["capabilities"]?.object?["optOutNotificationMethods"] == .array([.string("thread/started")]))
}

@Test func turnSteerCarriesExpectedTurnAndInputInOfficialShape() async throws {
    let transport = RecordingCodexTransport()
    let facade = CodexProtocolFacade(transport: transport)

    _ = try await facade.steerTurn(
        threadID: "thread-1",
        turnID: "turn-running",
        prompt: "补充上下文",
        attachments: [.remoteFile(path: "/tmp/notes.txt")]
    )

    #expect(transport.methods == ["turn/steer"])
    let params = try #require(transport.requests.first?.params.object)
    #expect(params["threadId"] == .string("thread-1"))
    #expect(params["expectedTurnId"] == .string("turn-running"))
    #expect(params["input"]?.array == [
        .object([
            "type": .string("text"),
            "text": .string("补充上下文"),
            "text_elements": .array([])
        ]),
        .object([
            "type": .string("text"),
            "text": .string("Uploaded file: /tmp/notes.txt"),
            "text_elements": .array([])
        ])
    ])
}

@Test func turnStartCarriesTextLocalImagesFilesPermissionsAndPlanModeInOfficialShape() async throws {
    let transport = RecordingCodexTransport()
    let facade = CodexProtocolFacade(transport: transport)

    _ = try await facade.startTurn(
        threadID: "thread-1",
        prompt: "解释这张图并读取上传文件",
        attachments: [
            .localImage(path: "/remote/attachments/screen.png", detail: "high"),
            .remoteFile(path: "/remote/attachments/log.txt")
        ],
        permissionMode: .fullAccess,
        collaborationMode: .plan
    )

    #expect(transport.methods == ["turn/start"])
    let params = try #require(transport.requests.first?.params.object)
    #expect(params["threadId"] == .string("thread-1"))
    #expect(params["collaborationMode"]?.object?["mode"] == .string("plan"))
    #expect(params["sandboxPolicy"]?.object?["type"] == .string("dangerFullAccess"))

    let input = try #require(params["input"]?.array)
    #expect(input.contains(.object([
        "type": .string("text"),
        "text": .string("解释这张图并读取上传文件"),
        "text_elements": .array([])
    ])))
    #expect(input.contains(.object(["type": .string("localImage"), "path": .string("/remote/attachments/screen.png"), "detail": .string("high")])))
    #expect(input.contains(.object([
        "type": .string("text"),
        "text": .string("Uploaded file: /remote/attachments/log.txt"),
        "text_elements": .array([])
    ])))
}
