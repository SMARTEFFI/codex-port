import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortHostAgentCore
@testable import CodexPortRelayCore
@testable import CodexPortShared

@Test func clientHostSessionProtocolListsThreadsOverDataChannelAndIgnoresInvalidCoalescedFrame() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let thread = RelayThreadSummarySnapshot(
        id: "thread-1",
        cwd: "/Users/chenm/Projects/codex-port",
        updatedAtUnixTime: 1_780_991_312,
        preview: "HostAgent session summary",
        gitRepository: "git@github.com:zhxsinc/codex-port.git",
        gitBranch: "main",
        status: "completed"
    )
    let hostTask = Task {
        for await line in hostTransport.incomingLines {
            guard line.contains(#""type":"listThreads""#) else {
                continue
            }
            let response = try RelayEndpointJSONLCodec.encodeThreadList(
                [thread],
                clientID: "iphone-a",
                requestID: "list-1"
            )
            try await pair.host.send(Data("not-json\n\(response)\n".utf8))
            return
        }
    }
    let client = ClientHostSessionThreadListClient(
        clientID: "iphone-a",
        transport: clientTransport,
        timeout: .milliseconds(500)
    )

    let threads = try await client.listThreads(limit: 1, requestID: "list-1")

    hostTask.cancel()
    #expect(threads == [thread])
}

@Test func clientHostSessionProtocolLoadsHistoryPageOverSplitDataChannelFrame() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let hostTask = Task {
        for await line in hostTransport.incomingLines {
            guard line.contains(#""type":"loadHistory""#) else {
                continue
            }
            let page = RelayThreadHistoryPage(
                requestID: "history-1",
                threadID: "thread-1",
                items: [
                    .userMessage("older question"),
                    .assistantMessage("older answer"),
                ],
                status: .completed,
                nextCursor: nil
            )
            let response = try RelayEndpointJSONLCodec.encodeThreadHistoryPage(page, clientID: "iphone-a") + "\n"
            let midpoint = response.index(response.startIndex, offsetBy: response.count / 2)
            try await pair.host.send(Data(response[..<midpoint].utf8))
            try await pair.host.send(Data(response[midpoint...].utf8))
            return
        }
    }
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )

    let page = try await client.loadEarlierHistory(
        cursor: nil,
        requestID: "history-1",
        timeout: .milliseconds(500)
    )

    hostTask.cancel()
    #expect(page.items == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
    ])
    #expect(store.visibleItems == [
        .userMessage("older question"),
        .assistantMessage("older answer"),
    ])
}

@Test func clientHostSessionProtocolResolvesRemoteHostPathImageThroughDataChannel() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
    let hostTask = Task {
        for await line in hostTransport.incomingLines {
            guard line.contains(#""type":"readFile""#) else {
                continue
            }
            let requestObject = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let requestID = try #require(requestObject?["requestID"] as? String)
            let response = try RelayEndpointJSONLCodec.encodeFileContent(
                RelayRemoteFileContent(
                    requestID: requestID,
                    path: "/Users/chenm/Desktop/screen.png",
                    contentType: "image/png",
                    byteCount: pngBytes.count,
                    dataBase64: pngBytes.base64EncodedString()
                ),
                clientID: "iphone-a"
            )
            try await pair.host.send(Data((response + "\n").utf8))
            return
        }
    }
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )
    let resolver = RemoteImageAttachmentResolver(
        reader: client,
        cache: DataChannelRemoteImageCache(),
        maxBytes: 10
    )

    let resolved = await resolver.resolve(MessageAttachment(
        id: "remote-image-1",
        kind: .image(contentType: "image/png", detail: "high"),
        displayName: "screen.png",
        source: .remoteHostPath("/Users/chenm/Desktop/screen.png")
    ))

    hostTask.cancel()
    #expect(resolved.source == MessageAttachmentSource.localCache(path: "/cache/remote-image-1.png"))
}

@Test func clientHostSessionProtocolSurfacesTransportCloseWhenRequestingThreadList() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    pair.client.close()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let client = ClientHostSessionThreadListClient(
        clientID: "iphone-a",
        transport: clientTransport,
        timeout: .milliseconds(500)
    )

    await #expect(throws: WebRTCDataChannelTransportError.dataChannelClosed) {
        _ = try await client.listThreads(limit: 1, requestID: "list-after-close")
    }
}

@Test func clientHostSessionProtocolStreamsPromptWriteStatusAndAssistantDeltaBeforeCompletion() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let hostTask = Task {
        for await line in hostTransport.incomingLines {
            guard line.contains(#""type":"prompt""#) else {
                continue
            }
            try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeWriteStatus(
                .queued,
                clientID: "iphone-a",
                sessionID: "session-1",
                writeID: "write-1"
            ) + "\n").utf8))
            try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeWriteStatus(
                .running,
                clientID: "iphone-a",
                sessionID: "session-1",
                writeID: "write-1"
            ) + "\n").utf8))
            try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeEvent(
                .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
                clientID: "iphone-a"
            ) + "\n").utf8))
            try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeEvent(
                .assistantTextDelta(turnID: "turn-1", itemID: "assistant-1", text: "streamed before completion"),
                clientID: "iphone-a"
            ) + "\n").utf8))
            return
        }
    }
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )

    try await client.attach()
    let status = try await client.sendPromptAndWaitForAcceptance(
        "hello p2p",
        writeID: "write-1",
        timeout: .milliseconds(500)
    )
    await waitForClientHostSession {
        store.visibleItems.contains(.assistantMessage("streamed before completion"))
    }

    hostTask.cancel()
    #expect(status == .queued)
    #expect(store.visibleItems == [
        .userMessage("hello p2p"),
        .assistantMessage("streamed before completion"),
    ])
    #expect(client.latestWriteStatus == .init(sessionID: "session-1", writeID: "write-1", status: .running))
    #expect(await context.service.plaintextInspectionLog().isEmpty)
}

@Test func clientHostSessionProtocolUploadsLargeAttachmentOverSplitDataChannelFrames() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let hostTask = Task {
        for await line in hostTransport.incomingLines {
            guard let command = try? HostAgentLocalRelayJSONLCodec.decodeCommand(from: line) else {
                continue
            }
            switch command {
            case let .createDirectory(clientID, requestID, path, _):
                try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeFileOperationResult(
                    operation: "createDirectory",
                    requestID: requestID,
                    path: path,
                    clientID: clientID
                ) + "\n").utf8))
            case let .writeFile(clientID, requestID, path, dataBase64):
                #expect(Data(base64Encoded: dataBase64)?.count == 80_000)
                try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeFileOperationResult(
                    operation: "writeFile",
                    requestID: requestID,
                    path: path,
                    clientID: clientID
                ) + "\n").utf8))
            case let .submit(clientID, sessionID, write):
                guard case let .prompt(writeID, _, _, attachments) = write else {
                    continue
                }
                #expect(attachments.count == 1)
                try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeWriteStatus(
                    .queued,
                    clientID: clientID,
                    sessionID: sessionID,
                    writeID: writeID
                ) + "\n").utf8))
                return
            case .listThreads, .loadHistory, .readFile, .attach, .detach, .stop:
                continue
            }
        }
    }
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )
    var composer = InputComposer(modelDisplay: "5.5")
    composer.text = "large attachment"
    let pendingImage = PendingAttachment(
        name: "large-photo.jpg",
        kind: .image(detail: "high"),
        data: Data(repeating: 0xAB, count: 80_000),
        localCachePath: "/tmp/large-photo.jpg"
    )

    try await client.attach()
    let status = try await client.send(
        composer: composer,
        pendingAttachments: [pendingImage],
        remoteRoot: "~/.codex-port/attachments",
        writeID: "write-large-photo",
        timeout: .seconds(2)
    )

    hostTask.cancel()
    #expect(status == .queued)
    #expect(store.visibleItems == [
        .structuredUserMessage(StructuredUserMessage(
            body: "large attachment",
            attachments: [
                MessageAttachment(
                    id: "large-photo.jpg",
                    kind: .image(contentType: nil, detail: "high"),
                    displayName: "large-photo.jpg",
                    source: .localCache(path: "/tmp/large-photo.jpg")
                ),
            ]
        )),
    ])
}

@Test func clientHostSessionProtocolSurfacesActionableFailedWriteReasonOverDataChannel() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let reason = "Codex live source is not connected. Restart Codex Desktop or HostAgent."
    let hostTask = Task {
        for await line in hostTransport.incomingLines {
            guard line.contains(#""type":"prompt""#) else {
                continue
            }
            try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeWriteStatus(
                .failed(reason: reason),
                clientID: "iphone-a",
                sessionID: "session-1",
                writeID: "write-failed"
            ) + "\n").utf8))
            return
        }
    }
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )

    try await client.attach()
    let capturedError: Error?
    do {
        _ = try await client.sendPromptAndWaitForAcceptance(
            "will fail",
            writeID: "write-failed",
            timeout: .milliseconds(500)
        )
        capturedError = nil
    } catch {
        capturedError = error
    }

    hostTask.cancel()
    #expect(capturedError as? ClientHostSessionClientError == .writeFailed(reason))
    #expect(store.status == .failed(reason))
    #expect(client.latestWriteStatus == .init(sessionID: "session-1", writeID: "write-failed", status: .failed(reason: reason)))
}

@Test func clientHostSessionProtocolSurfacesDataChannelInterruptionWhenSendingPrompt() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )
    pair.client.close()

    await #expect(throws: WebRTCDataChannelTransportError.dataChannelClosed) {
        try await client.sendPrompt("prompt after close", writeID: "write-closed")
    }
    #expect(store.visibleItems.isEmpty)
}

@Test func clientHostSessionProtocolMapsCommandFileApprovalAndInterruptControlPathOverDataChannel() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let hostTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.host)
    let hostInbox = HostCommandInbox(hostTransport.incomingLines)
    await hostInbox.start()
    try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeEvent(
        .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
        clientID: "iphone-a"
    ) + "\n").utf8))
    try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeEvent(
        .commandOutputDelta(turnID: "turn-1", itemID: "cmd-1", text: "swift test\n"),
        clientID: "iphone-a"
    ) + "\n").utf8))
    try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeEvent(
        .fileChange(turnID: "turn-1", itemID: "file-1", path: "README.md", diff: "+done"),
        clientID: "iphone-a"
    ) + "\n").utf8))
    try await pair.host.send(Data((try RelayEndpointJSONLCodec.encodeEvent(
        .approvalRequested(turnID: "turn-1", requestID: "approval-1", summary: "Allow file edit"),
        clientID: "iphone-a"
    ) + "\n").utf8))
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )

    try await client.attach()
    await waitForClientHostSession {
        store.visibleItems.contains(.commandOutput("swift test\n"))
            && store.visibleItems.contains(.fileChange(path: "README.md", diff: "+done"))
    }
    try await client.sendApproval(requestID: "approval-1", action: .accept, writeID: "approval-write")
    try await client.interrupt(writeID: "interrupt-write")
    await waitForClientHostSession {
        let commands = await hostInbox.commands()
        return commands.count >= 3
    }

    let commands = await hostInbox.commands()
    #expect(store.visibleItems == [
        .commandOutput("swift test\n"),
        .fileChange(path: "README.md", diff: "+done"),
    ])
    #expect(commands.contains(.submit(
        clientID: "iphone-a",
        sessionID: "session-1",
        write: .approval(writeID: "approval-write", requestID: "approval-1", action: .accept)
    )))
    #expect(commands.contains(.submit(
        clientID: "iphone-a",
        sessionID: "session-1",
        write: .interrupt(writeID: "interrupt-write", threadID: "thread-1", turnID: "turn-1")
    )))
}

@Test func clientHostSessionProtocolSurfacesDataChannelCloseWhenSendingApproval() async throws {
    let context = try await ClientHostSessionP2PTestContext.make()
    let pair = P2PWebRTCDataChannelTransportPair(
        signalingService: context.service,
        session: context.session
    )
    try await pair.open()
    let clientTransport = ClientHostSessionDataChannelTransport(dataChannel: pair.client)
    let store = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let client = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: clientTransport,
        sessionStore: store
    )
    pair.client.close()

    await #expect(throws: WebRTCDataChannelTransportError.dataChannelClosed) {
        try await client.sendApproval(requestID: "approval-1", action: .decline, writeID: "approval-closed")
    }
}

@Test func clientHostSessionProtocolFansOutAcrossTwoIPhonesAndSerializesWritesOverDataChannels() async throws {
    let harness = try await MultiDeviceClientHostSessionHarness.make()
    let host = MultiDeviceHostSessionHub(
        transports: [harness.hostTransportA, harness.hostTransportB],
        clientIDs: ["iphone-a", "iphone-b"],
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1"
    )
    await host.start()
    let storeA = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let storeB = SessionStore(protocolClient: RelaySessionPlaceholderProtocolClient(threadID: "thread-1"))
    let clientA = ClientHostSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: harness.clientTransportA,
        sessionStore: storeA
    )
    let clientB = ClientHostSessionClient(
        clientID: "iphone-b",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: harness.clientTransportB,
        sessionStore: storeB
    )

    try await clientA.attach()
    try await clientB.attach()
    async let promptStatus = clientA.sendPromptAndWaitForAcceptance(
        "from A",
        writeID: "write-a",
        timeout: .milliseconds(500)
    )
    await waitForClientHostSession {
        storeB.visibleItems.contains(.assistantMessage("reply to from A"))
    }
    try await clientB.interrupt(writeID: "interrupt-b")
    await waitForClientHostSession {
        await host.receivedWrites() == [
            .prompt(writeID: "write-a", threadID: "thread-1", text: "from A"),
            .interrupt(writeID: "interrupt-b", threadID: "thread-1", turnID: "turn-1"),
        ]
    }

    #expect(try await promptStatus == .queued)
    #expect(storeA.visibleItems == [
        .userMessage("from A"),
        .assistantMessage("reply to from A"),
    ])
    #expect(storeB.visibleItems == [
        .assistantMessage("reply to from A"),
    ])
    #expect(clientA.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-b", status: .handled))
    #expect(clientB.latestWriteStatus == .init(sessionID: "session-1", writeID: "interrupt-b", status: .handled))
}

private struct ClientHostSessionP2PTestContext: Sendable {
    var service: P2PSignalingService
    var session: P2PSignalingSession

    static func make() async throws -> ClientHostSessionP2PTestContext {
        let service = P2PSignalingService(supportedVersions: [.v0_2_0])
        let host = RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
        let device = DeviceIdentity(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-public-key".utf8))
        )
        _ = await service.registerHost(host)
        let pairing = try await service.authorize(device: device, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 10))
        let session = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: device.id,
            pairingRecordID: pairing.id,
            supportedVersions: [.v0_2_0]
        ))
        return ClientHostSessionP2PTestContext(service: service, session: session)
    }
}

private struct MultiDeviceClientHostSessionHarness: Sendable {
    var clientTransportA: ClientHostSessionDataChannelTransport
    var clientTransportB: ClientHostSessionDataChannelTransport
    var hostTransportA: ClientHostSessionDataChannelTransport
    var hostTransportB: ClientHostSessionDataChannelTransport

    static func make() async throws -> MultiDeviceClientHostSessionHarness {
        let service = P2PSignalingService(supportedVersions: [.v0_2_0])
        let host = RelayHostIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Mac Studio",
            userName: "chenm",
            publicKey: EndpointPublicKey(rawValue: Data("host-public-key".utf8))
        )
        let iPhoneA = DeviceIdentity(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "iPhone A",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-a-public-key".utf8))
        )
        let iPhoneB = DeviceIdentity(
            id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "iPhone B",
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("iphone-b-public-key".utf8))
        )
        _ = await service.registerHost(host)
        let pairingA = try await service.authorize(device: iPhoneA, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 1))
        let pairingB = try await service.authorize(device: iPhoneB, forHostID: host.id, pairedAt: Date(timeIntervalSince1970: 2))
        let sessionA = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: iPhoneA.id,
            pairingRecordID: pairingA.id,
            supportedVersions: [.v0_2_0]
        ))
        let sessionB = try await service.openSession(P2PSignalingOpenRequest(
            hostID: host.id,
            deviceID: iPhoneB.id,
            pairingRecordID: pairingB.id,
            supportedVersions: [.v0_2_0]
        ))
        let pairA = P2PWebRTCDataChannelTransportPair(signalingService: service, session: sessionA)
        let pairB = P2PWebRTCDataChannelTransportPair(signalingService: service, session: sessionB)
        try await pairA.open()
        try await pairB.open()
        return MultiDeviceClientHostSessionHarness(
            clientTransportA: ClientHostSessionDataChannelTransport(dataChannel: pairA.client),
            clientTransportB: ClientHostSessionDataChannelTransport(dataChannel: pairB.client),
            hostTransportA: ClientHostSessionDataChannelTransport(dataChannel: pairA.host),
            hostTransportB: ClientHostSessionDataChannelTransport(dataChannel: pairB.host)
        )
    }
}

private actor MultiDeviceHostSessionHub {
    private let transports: [ClientHostSessionDataChannelTransport]
    private let clientIDs: [String]
    private let sessionID: String
    private let threadID: String
    private let turnID: String
    private var writes: [RelayLiveSessionWrite] = []
    private var tailTask: Task<Void, Never>?

    init(
        transports: [ClientHostSessionDataChannelTransport],
        clientIDs: [String],
        sessionID: String,
        threadID: String,
        turnID: String
    ) {
        self.transports = transports
        self.clientIDs = clientIDs
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
    }

    func start() {
        for transport in transports {
            Task {
                for await line in transport.incomingLines {
                    guard let command = try? HostAgentLocalRelayJSONLCodec.decodeCommand(from: line) else {
                        continue
                    }
                    receive(command)
                }
            }
        }
    }

    func receivedWrites() -> [RelayLiveSessionWrite] {
        writes
    }

    private func receive(_ command: HostAgentLocalRelayJSONLCommand) {
        switch command {
        case let .submit(_, _, write):
            enqueue(write)
        case let .attach(clientID, _):
            Task {
                try? await send(.sessionStarted(sessionID: sessionID, threadID: threadID, turnID: turnID), to: clientID)
            }
        case let .createDirectory(clientID, requestID, path, _):
            Task {
                let line = try? RelayEndpointJSONLCodec.encodeFileOperationResult(
                    operation: "createDirectory",
                    requestID: requestID,
                    path: path,
                    clientID: clientID
                )
                guard let line else { return }
                for transport in transports {
                    try? await transport.sendLine(line)
                }
            }
        case let .writeFile(clientID, requestID, path, _):
            Task {
                let line = try? RelayEndpointJSONLCodec.encodeFileOperationResult(
                    operation: "writeFile",
                    requestID: requestID,
                    path: path,
                    clientID: clientID
                )
                guard let line else { return }
                for transport in transports {
                    try? await transport.sendLine(line)
                }
            }
        case .listThreads, .loadHistory, .readFile, .detach, .stop:
            break
        }
    }

    private func enqueue(_ write: RelayLiveSessionWrite) {
        let previous = tailTask
        let task = Task { [weak self] in
            guard let self else { return }
            if let previous {
                await previous.value
            }
            await append(write)
            await broadcast(.writeStatusChanged(writeID: write.writeID, status: .queued))
            await broadcast(.writeStatusChanged(writeID: write.writeID, status: .running))
            if case let .prompt(writeID, _, text, _) = write {
                await broadcast(.assistantTextDelta(turnID: turnID, itemID: "\(writeID)-assistant", text: "reply to \(text)"))
                await broadcast(.turnCompleted(turnID: turnID))
            } else if case .interrupt = write {
                await broadcast(.turnCompleted(turnID: turnID))
            }
            await broadcast(.writeStatusChanged(writeID: write.writeID, status: .handled))
        }
        tailTask = task
    }

    private func append(_ write: RelayLiveSessionWrite) {
        writes.append(write)
    }

    private func broadcast(_ event: RelayLiveSessionEvent) async {
        for clientID in clientIDs {
            try? await send(event, to: clientID)
        }
    }

    private func send(_ event: RelayLiveSessionEvent, to clientID: String) async throws {
        let line = try RelayEndpointJSONLCodec.encodeEvent(event, clientID: clientID)
        for transport in transports {
            try await transport.sendLine(line)
        }
    }
}

private actor HostCommandInbox {
    private let stream: AsyncStream<String>
    private var receivedCommands: [HostAgentLocalRelayJSONLCommand] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<String>) {
        self.stream = stream
    }

    func start() {
        task = Task {
            for await line in stream {
                guard let command = try? HostAgentLocalRelayJSONLCodec.decodeCommand(from: line) else {
                    continue
                }
                record(command)
            }
        }
    }

    func commands() -> [HostAgentLocalRelayJSONLCommand] {
        receivedCommands
    }

    private func record(_ command: HostAgentLocalRelayJSONLCommand) {
        receivedCommands.append(command)
    }
}

private final class DataChannelRemoteImageCache: RemoteImageCaching {
    func store(_ content: RemoteFileContent, attachmentID: String) async -> Result<String, RemoteImageCacheError> {
        let ext = URL(fileURLWithPath: content.path).pathExtension
        return .success("/cache/\(attachmentID).\(ext.isEmpty ? "img" : ext)")
    }
}

private func waitForClientHostSession(
    timeout: Duration = .milliseconds(500),
    condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
