import Foundation
import Testing
@testable import CodexPortCore

@Test func attachmentUploaderWritesFilesAndBuildsTurnAttachments() async throws {
    let protocolClient = FakeCodexProtocol()
    let uploader = AttachmentUploader(
        protocolClient: protocolClient,
        remoteRoot: "/home/codex/.codex-port/attachments",
        clock: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let attachments = try await uploader.upload([
        PendingAttachment(name: "screen.png", kind: .image(detail: "high"), data: Data([0x01, 0x02])),
        PendingAttachment(name: "notes.txt", kind: .file, data: Data("hello".utf8))
    ], threadID: "thread-1")

    #expect(protocolClient.createdDirectories == [CreatedDirectory(path: "/home/codex/.codex-port/attachments/thread-1/1700000000", recursive: true)])
    #expect(protocolClient.writtenFiles.map(\.path) == [
        "/home/codex/.codex-port/attachments/thread-1/1700000000/screen.png",
        "/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt"
    ])
    #expect(protocolClient.writtenFiles[0].dataBase64 == "AQI=")
    #expect(attachments == [
        .localImage(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/screen.png", detail: "high"),
        .remoteFile(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt")
    ])
}

@Test func attachmentComposerBridgeUploadsPickedCameraAndFileDataIntoComposer() async throws {
    let protocolClient = FakeCodexProtocol()
    let uploader = AttachmentUploader(
        protocolClient: protocolClient,
        remoteRoot: "/home/codex/.codex-port/attachments",
        clock: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    let bridge = AttachmentComposerBridge(uploader: uploader)
    var composer = InputComposer(modelDisplay: "5.5 超高")

    try await bridge.attach(
        [
            PendingAttachment(name: "camera.jpg", kind: .image(detail: "high"), data: Data([0xCA, 0xFE])),
            PendingAttachment(name: "notes.txt", kind: .file, data: Data("notes".utf8))
        ],
        threadID: "thread-1",
        to: &composer
    )

    #expect(composer.attachments == [
        .localImage(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/camera.jpg", detail: "high"),
        .remoteFile(path: "/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt")
    ])
    #expect(protocolClient.writtenFiles.map(\.path).contains("/home/codex/.codex-port/attachments/thread-1/1700000000/notes.txt"))
}

@Test func permissionModesMapToOfficialTurnOverrides() {
    #expect(PermissionMode.remoteDefault.turnOverrides() == [:])
    #expect(PermissionMode.autoReview.turnOverrides()["approvalsReviewer"] == .string("auto_review"))
    #expect(PermissionMode.fullAccess.turnOverrides()["sandboxPolicy"]?.object?["type"] == .string("dangerFullAccess"))
    #expect(PermissionMode.customConfigToml.turnOverrides()["useConfiguredPermissions"] == .bool(true))
}

@Test func approvalWorkflowBuildsResponsesForAllCodexApprovalRequests() {
    let command = ApprovalRequest.command(
        id: .string("cmd"),
        command: ["rm", "-rf", "build"],
        cwd: "/repo",
        reason: "cleanup"
    )
    let file = ApprovalRequest.fileChange(
        id: .string("file"),
        path: "/repo/README.md",
        diff: "+hello"
    )
    let permissions = ApprovalRequest.permissions(
        id: .string("perm"),
        permissions: .object(["sandbox": .string("workspace-write")])
    )

    #expect(command.response(for: .accept).result == .object(["decision": .string("approved")]))
    #expect(file.response(for: .acceptForSession).result == .object(["decision": .string("approved_for_session")]))
    #expect(command.response(for: .decline).result == .object(["decision": .string("denied")]))
    #expect(file.response(for: .cancel).result == .object(["decision": .string("abort")]))
    #expect(permissions.response(for: .acceptForSession).result == .object([
        "permissions": .object(["sandbox": .string("workspace-write")]),
        "scope": .string("session")
    ]))
}

@Test func inputComposerControlsSendStopAndPlanModeState() {
    var composer = InputComposer(modelDisplay: "5.5 超高")

    #expect(composer.canSend == false)
    composer.text = "帮我看这个错误"
    #expect(composer.canSend == true)

    composer.isRunning = true
    #expect(composer.primaryAction == .stop)

    composer.isRunning = false
    composer.togglePlanMode()
    #expect(composer.collaborationMode == .plan)
    #expect(composer.primaryAction == .send)
}

@Test func inputComposerIgnoresUnsupportedPlanAndPermissionModes() {
    var capabilities = ComposerCapabilities.supported
    capabilities.planMode = .unsupported(reason: "远端 Codex app-server 暂不支持 CollaborationMode。")
    capabilities.permissionModes[.fullAccess] = .unsupported(reason: "远端 Codex app-server 暂不支持 danger-full-access override。")
    var composer = InputComposer(modelDisplay: "5.5 超高", capabilities: capabilities)

    composer.togglePlanMode()
    #expect(composer.collaborationMode == .default)

    composer.setPermissionMode(.fullAccess)
    #expect(composer.permissionMode == .remoteDefault)

    composer.setPermissionMode(.autoReview)
    #expect(composer.permissionMode == .autoReview)
}

@Test func inputComposerExposesModelMenuAndReasoningEffortWithoutPretendingUnsupportedSwitches() {
    var composer = InputComposer(modelDisplay: "5.5 超高")

    #expect(composer.modelMenu.primaryTitle == "5.5 超高")
    #expect(composer.modelMenu.modelOptions.map(\.id) == ["gpt-5.5", "gpt-5", "gpt-4.1"])
    #expect(composer.modelMenu.reasoningOptions.map(\.effort) == [.low, .medium, .high, .xhigh])
    #expect(composer.modelMenu.reasoningOptions.first(where: { $0.effort == .xhigh })?.isSelected == true)

    composer.setReasoningEffort(.medium)
    #expect(composer.reasoningEffort == .medium)
    #expect(composer.modelDisplay == "5.5 中")

    var unsupported = ComposerCapabilities.supported
    unsupported.modelSelection = .unsupported(reason: "远端 Codex app-server 暂不支持 model switch。")
    unsupported.reasoningEffort = .unsupported(reason: "远端 Codex app-server 暂不支持 reasoning effort override。")
    var unsupportedComposer = InputComposer(modelDisplay: "5.5 超高", capabilities: unsupported)

    unsupportedComposer.setModel(.gpt5)
    unsupportedComposer.setReasoningEffort(.low)

    #expect(unsupportedComposer.model == .gpt55)
    #expect(unsupportedComposer.reasoningEffort == .xhigh)
    #expect(unsupportedComposer.modelMenu.modelOptions.allSatisfy { $0.isEnabled == false })
    #expect(unsupportedComposer.modelMenu.reasoningOptions.allSatisfy { $0.isEnabled == false })
}
