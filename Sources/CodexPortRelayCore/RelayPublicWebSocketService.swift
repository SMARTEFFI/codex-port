import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public struct RelayPublicServiceEndpoints: Equatable, Sendable {
    public var streamEndpointURL: URL
    public var hostConnectURL: URL

    public init(streamEndpointURL: URL, hostConnectURL: URL) {
        self.streamEndpointURL = streamEndpointURL
        self.hostConnectURL = hostConnectURL
    }
}

public final class RelayPublicWebSocketService: @unchecked Sendable {
    private static let websocketMaxFrameSize = 1 << 20

    private enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, HTTPRequestHead)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    private struct HostConnection: Sendable {
        var connectionID: UUID
        var hostID: UUID
        var send: @Sendable (RelayHostBridgeEnvelope) async throws -> Void
    }

    private let host: String
    private let port: Int
    private let gateway: RelayAuthenticatedStreamGateway
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var serverChannel: Channel?
    private var acceptTask: Task<Void, Never>?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var hostConnections: [UUID: HostConnection] = [:]
    private var streamWriters: [UUID: @Sendable (String) async throws -> Void] = [:]

    public init(host: String = "127.0.0.1", port: Int = 0, gateway: RelayAuthenticatedStreamGateway) {
        self.host = host
        self.port = port
        self.gateway = gateway
    }

    deinit {
        acceptTask?.cancel()
        try? serverChannel?.close().wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    public func start() async throws -> RelayPublicServiceEndpoints {
        let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                        maxFrameSize: Self.websocketMaxFrameSize,
                        shouldUpgrade: { _, head in
                            channel.eventLoop.makeSucceededFuture(Self.validateUpgrade(head))
                        },
                        upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeCompletedFuture {
                                let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel
                                )
                                return .websocket(asyncChannel, head)
                            }
                        }
                    )
                    let configuration = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(RelayPublicHTTPResponsePartHandler())
                                let asyncChannel = try NIOAsyncChannel<
                                    HTTPServerRequestPart,
                                    HTTPPart<HTTPResponseHead, ByteBuffer>
                                >(wrappingChannelSynchronously: channel)
                                return .notUpgraded(asyncChannel)
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: configuration)
                    )
                }
            }

        serverChannel = channel.channel
        acceptTask = Task { [weak self] in
            do {
                try await channel.executeThenClose { inbound in
                    for try await result in inbound {
                        guard let self else { continue }
                        self.trackConnectionTask {
                            await self.handleUpgradeResult(result)
                        }
                    }
                }
            } catch {
            }
        }

        guard let port = channel.channel.localAddress?.port else {
            throw RelayWebSocketLineStreamServerError.missingLocalPort
        }
        return RelayPublicServiceEndpoints(
            streamEndpointURL: URL(string: "ws://\(host):\(port)/v0/streams")!,
            hostConnectURL: URL(string: "ws://\(host):\(port)/v0/host/connect")!
        )
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        try? await serverChannel?.close().get()
        serverChannel = nil
        await waitForConnectionTasksToFinish()
        try? await eventLoopGroup.shutdownGracefully()
    }

    private func handleUpgradeResult(_ result: EventLoopFuture<UpgradeResult>) async {
        do {
            switch try await result.get() {
            case let .websocket(channel, head):
                let request = Self.urlRequest(from: head)
                switch Self.path(from: head) {
                case "/v0/host/connect":
                    try await handleHostConnection(channel, request: request)
                case "/v0/streams":
                    let stream = try await gateway.openWebSocketStream(from: request)
                    try await handleDeviceStream(channel, stream: stream)
                default:
                    try await channel.channel.close().get()
                }
            case let .notUpgraded(channel):
                try await handleHTTPChannel(channel)
            }
        } catch {
        }
    }

    private func handleHostConnection(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        request: URLRequest
    ) async throws {
        let decoded = try RelayHostConnectWebSocketCodec.decode(from: request)
        _ = await gateway.registerHost(decoded.host)
        try await channel.executeThenClose { inbound, outbound in
            let connectionID = setHostConnection(hostID: decoded.host.id, send: { envelope in
                try await Self.write(envelope, to: outbound, allocator: channel.channel.allocator)
            })
            defer {
                removeHostConnection(hostID: decoded.host.id, connectionID: connectionID)
            }
            for try await frame in inbound {
                switch frame.opcode {
                case .text:
                    var data = frame.unmaskedData
                    let text = data.readString(length: data.readableBytes) ?? ""
                    for line in Self.completedLines(from: text) {
                        let envelope = try RelayHostBridgeEnvelope.decode(line)
                        if let writer = streamWriter(for: envelope.streamID) {
                            try await writer(envelope.line)
                            await gateway.recordHostToDevice(streamID: envelope.streamID, byteCount: envelope.line.utf8.count)
                        }
                    }
                case .connectionClose:
                    return
                case .ping:
                    var frameData = frame.data
                    if let maskingKey = frame.maskKey {
                        frameData.webSocketUnmask(maskingKey)
                    }
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frameData))
                default:
                    break
                }
            }
        }
    }

    private func handleDeviceStream(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        stream: RelayAuthorizedStream
    ) async throws {
        guard let hostConnection = hostConnection(for: stream.hostID) else {
            await gateway.close(streamID: stream.id, errorCode: "host-offline")
            try await channel.channel.close().get()
            return
        }

        try await channel.executeThenClose { inbound, outbound in
            setStreamWriter(streamID: stream.id) { line in
                var buffer = channel.channel.allocator.buffer(capacity: line.utf8.count + 1)
                buffer.writeString(line + "\n")
                try await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
            }
            defer {
                removeStreamWriter(streamID: stream.id)
            }

            for try await frame in inbound {
                switch frame.opcode {
                case .text:
                    var data = frame.unmaskedData
                    let text = data.readString(length: data.readableBytes) ?? ""
                    for line in Self.completedLines(from: text) {
                        await gateway.recordDeviceToHost(streamID: stream.id, byteCount: line.utf8.count)
                        try await hostConnection.send(RelayHostBridgeEnvelope(
                            streamID: stream.id,
                            clientID: stream.clientID,
                            line: line
                        ))
                    }
                case .connectionClose:
                    await gateway.close(streamID: stream.id, errorCode: nil)
                    return
                case .ping:
                    var frameData = frame.data
                    if let maskingKey = frame.maskKey {
                        frameData.webSocketUnmask(maskingKey)
                    }
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frameData))
                default:
                    break
                }
            }
        }
        await gateway.close(streamID: stream.id, errorCode: nil)
    }

    private func handleHTTPChannel(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var requestHead: HTTPRequestHead?
        var body = ByteBuffer()
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                switch part {
                case let .head(head):
                    requestHead = head
                case let .body(buffer):
                    body.writeImmutableBuffer(buffer)
                case .end:
                    guard let requestHead else {
                        try await writeHTTP(status: .badRequest, body: Data(), outbound: outbound)
                        return
                    }
                    let response = await handleHTTPRequest(head: requestHead, body: body)
                    try await writeHTTP(status: response.status, body: response.body, outbound: outbound)
                    return
                }
            }
        }
    }

    private func handleHTTPRequest(head: HTTPRequestHead, body: ByteBuffer) async -> (status: HTTPResponseStatus, body: Data) {
        do {
            switch (head.method, Self.path(from: head)) {
            case (.GET, "/healthz"):
                return (.ok, Data())
            case let (.GET, path) where Self.hostPairingsPathHostID(from: path) != nil:
                guard let hostID = Self.hostPairingsPathHostID(from: path) else {
                    return (.badRequest, Data())
                }
                let response = RelayHostPairingRecordsResponse(
                    devices: await gateway.pairingRecords(forHostID: hostID)
                )
                return (.ok, try JSONEncoder().encode(response))
            case let (.POST, path) where Self.hostPairingRevokePath(from: path) != nil:
                guard let route = Self.hostPairingRevokePath(from: path) else {
                    return (.badRequest, Data())
                }
                guard let record = await gateway.pairingRecords(forHostID: route.hostID)
                    .first(where: { $0.pairingRecordID == route.recordID })
                else {
                    return (.notFound, Data())
                }
                _ = try await gateway.revoke(deviceID: record.deviceID, forHostID: route.hostID, at: Date())
                return (.ok, Data())
            case (.POST, "/v0/pairing/publish"):
                var body = body
                let data = Data(body.readBytes(length: body.readableBytes) ?? [])
                let request = try JSONDecoder().decode(RelayPairingPublishRequest.self, from: data)
                if let displayName = request.hostDisplayName,
                   let userName = request.hostUserName,
                   let publicKeyBase64 = request.hostPublicKeyBase64,
                   let publicKey = Data(base64Encoded: publicKeyBase64),
                   !displayName.isEmpty,
                   !userName.isEmpty {
                    _ = await gateway.registerHost(RelayHostIdentity(
                        id: request.hostID,
                        displayName: displayName,
                        userName: userName,
                        publicKey: EndpointPublicKey(rawValue: publicKey)
                    ))
                }
                try await gateway.publishPairingToken(PairingToken(
                    id: request.tokenID,
                    hostID: request.hostID,
                    expiresAt: Date(timeIntervalSince1970: request.expiresAtUnixTime),
                    presentation: .manualCode(request.manualCode ?? request.tokenID)
                ))
                return (.ok, Data())
            case (.POST, "/v0/pairing/consume"):
                var body = body
                let data = Data(body.readBytes(length: body.readableBytes) ?? [])
                let request = try JSONDecoder().decode(RelayPairingConsumeRequest.self, from: data)
                guard let publicKey = Data(base64Encoded: request.devicePublicKeyBase64) else {
                    return (.badRequest, Data())
                }
                let result = try await gateway.consumePairingToken(
                    request.tokenID,
                    device: DeviceIdentity(
                        id: request.deviceID,
                        displayName: request.deviceDisplayName,
                        kind: .iOSClient,
                        publicKey: EndpointPublicKey(rawValue: publicKey)
                    ),
                    supportedVersions: request.supportedVersions
                )
                let activeConnectionCount: Int
                switch result.presence {
                case let .online(count):
                    activeConnectionCount = count
                case .offline:
                    activeConnectionCount = 0
                }
                let response = RelayPairingConsumeResponse(
                    tokenID: result.tokenID,
                    hostID: result.host.id,
                    hostDisplayName: result.host.displayName,
                    hostUserName: result.host.userName,
                    hostPublicKeyBase64: result.host.publicKey.rawValue.base64EncodedString(),
                    deviceID: result.device.id,
                    pairingRecordID: result.record.id,
                    selectedVersion: result.negotiatedVersion,
                    activeConnectionCount: activeConnectionCount
                )
                return (.ok, try JSONEncoder().encode(response))
            case let (.GET, path) where Self.p2pPresencePathHostID(from: path) != nil:
                guard let hostID = Self.p2pPresencePathHostID(from: path),
                      let deviceID = Self.queryValue("deviceID", from: head.uri).flatMap(UUID.init(uuidString:))
                else {
                    return (.badRequest, Data())
                }
                return (.ok, try JSONEncoder().encode(await gateway.p2pPresence(hostID: hostID, deviceID: deviceID)))
            case let (.POST, path) where Self.p2pPresencePathHostID(from: path) != nil:
                guard let hostID = Self.p2pPresencePathHostID(from: path) else {
                    return (.badRequest, Data())
                }
                var body = body
                let data = Data(body.readBytes(length: body.readableBytes) ?? [])
                let request = try JSONDecoder().decode(RelayP2PHostPresencePublishRequest.self, from: data)
                guard request.hostID == hostID,
                      !request.hostDisplayName.isEmpty,
                      !request.hostUserName.isEmpty,
                      let publicKey = Data(base64Encoded: request.hostPublicKeyBase64)
                else {
                    return (.badRequest, Data())
                }
                let presence = await gateway.registerHost(RelayHostIdentity(
                    id: request.hostID,
                    displayName: request.hostDisplayName,
                    userName: request.hostUserName,
                    publicKey: EndpointPublicKey(rawValue: publicKey)
                ))
                let activeConnectionCount: Int
                switch presence {
                case let .online(count):
                    activeConnectionCount = count
                case .offline:
                    activeConnectionCount = 0
                }
                return (.ok, try JSONEncoder().encode(RelayP2PHostPresencePublishResponse(
                    hostID: request.hostID,
                    presence: .online,
                    activeConnectionCount: activeConnectionCount
                )))
            case let (.GET, path) where Self.p2pHostMessagesPathHostID(from: path) != nil:
                guard let hostID = Self.p2pHostMessagesPathHostID(from: path) else {
                    return (.badRequest, Data())
                }
                do {
                    return (.ok, try JSONEncoder().encode(try await gateway.drainP2PHostMessages(hostID: hostID)))
                } catch {
                    return (Self.p2pStatus(for: error), Data())
                }
            case (.POST, "/v0/p2p/sessions/open"):
                var body = body
                let data = Data(body.readBytes(length: body.readableBytes) ?? [])
                let request = try JSONDecoder().decode(RelayP2POpenSessionRequest.self, from: data)
                do {
                    return (.ok, try JSONEncoder().encode(try await gateway.openP2PSession(request)))
                } catch {
                    return (Self.p2pStatus(for: error), Data())
                }
            case let (.POST, path) where Self.p2pSendMessagePathSessionID(from: path) != nil:
                guard let sessionID = Self.p2pSendMessagePathSessionID(from: path) else {
                    return (.badRequest, Data())
                }
                var body = body
                let data = Data(body.readBytes(length: body.readableBytes) ?? [])
                let request = try JSONDecoder().decode(RelayP2PSendMessageRequest.self, from: data)
                do {
                    try await gateway.sendP2PMessage(sessionID: sessionID, message: request.message)
                    return (.ok, Data())
                } catch {
                    return (Self.p2pStatus(for: error), Data())
                }
            case let (.GET, path) where Self.p2pMessagesPathSessionID(from: path) != nil:
                guard let sessionID = Self.p2pMessagesPathSessionID(from: path),
                      let endpoint = Self.queryValue("endpoint", from: head.uri).flatMap(RelayP2PSignalingEndpointRole.init(rawValue:))
                else {
                    return (.badRequest, Data())
                }
                do {
                    return (.ok, try JSONEncoder().encode(try await gateway.drainP2PMessages(
                        sessionID: sessionID,
                        endpoint: endpoint
                    )))
                } catch {
                    return (Self.p2pStatus(for: error), Data())
                }
            default:
                return (.upgradeRequired, Data())
            }
        } catch {
            return (.badRequest, Data())
        }
    }

    private func writeHTTP(
        status: HTTPResponseStatus,
        body: Data,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "\(body.count)")
        if !body.isEmpty {
            headers.add(name: "Content-Type", value: "application/json")
        }
        var buffer = ByteBufferAllocator().buffer(capacity: body.count)
        buffer.writeBytes(body)
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        if !body.isEmpty {
            try await outbound.write(.body(buffer))
        }
        try await outbound.write(.end(nil))
    }

    private func setHostConnection(hostID: UUID, send: @escaping @Sendable (RelayHostBridgeEnvelope) async throws -> Void) -> UUID {
        let connectionID = UUID()
        lock.withLock {
            hostConnections[hostID] = HostConnection(connectionID: connectionID, hostID: hostID, send: send)
        }
        return connectionID
    }

    private func removeHostConnection(hostID: UUID, connectionID: UUID) {
        lock.withLock {
            guard hostConnections[hostID]?.connectionID == connectionID else { return }
            hostConnections[hostID] = nil
        }
    }

    private func hostConnection(for hostID: UUID) -> HostConnection? {
        lock.withLock {
            hostConnections[hostID]
        }
    }

    private func setStreamWriter(streamID: UUID, send: @escaping @Sendable (String) async throws -> Void) {
        lock.withLock {
            streamWriters[streamID] = send
        }
    }

    private func removeStreamWriter(streamID: UUID) {
        lock.withLock {
            streamWriters[streamID] = nil
        }
    }

    private func streamWriter(for streamID: UUID) -> (@Sendable (String) async throws -> Void)? {
        lock.withLock {
            streamWriters[streamID]
        }
    }

    private func trackConnectionTask(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.removeConnectionTask(id)
        }
        lock.withLock {
            connectionTasks[id] = task
        }
    }

    private func removeConnectionTask(_ id: UUID) {
        lock.withLock {
            connectionTasks[id] = nil
        }
    }

    private func waitForConnectionTasksToFinish() async {
        let tasks = lock.withLock {
            let tasks = Array(connectionTasks.values)
            connectionTasks.removeAll()
            return tasks
        }
        for task in tasks {
            _ = await task.result
        }
    }

    private static func validateUpgrade(_ head: HTTPRequestHead) -> HTTPHeaders? {
        let request = urlRequest(from: head)
        do {
            switch path(from: head) {
            case "/v0/host/connect":
                _ = try RelayHostConnectWebSocketCodec.decode(from: request)
            case "/v0/streams":
                _ = try RelayStreamOpenRequestWebSocketCodec.decode(from: request)
            default:
                return nil
            }
            return HTTPHeaders()
        } catch {
            return nil
        }
    }

    private static func path(from head: HTTPRequestHead) -> String {
        URLComponents(string: "ws://relay.local\(head.uri)")?.path ?? head.uri
    }

    private static func hostPairingsPathHostID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4,
              parts[0] == "v0",
              parts[1] == "hosts",
              parts[3] == "pairings"
        else {
            return nil
        }
        return UUID(uuidString: parts[2])
    }

    private static func hostPairingRevokePath(from path: String) -> (hostID: UUID, recordID: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 6,
              parts[0] == "v0",
              parts[1] == "hosts",
              parts[3] == "pairings",
              parts[5] == "revoke",
              let hostID = UUID(uuidString: parts[2])
        else {
            return nil
        }
        return (hostID: hostID, recordID: parts[4])
    }

    private static func p2pPresencePathHostID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 5,
              parts[0] == "v0",
              parts[1] == "p2p",
              parts[2] == "hosts",
              parts[4] == "presence"
        else {
            return nil
        }
        return UUID(uuidString: parts[3])
    }

    private static func p2pHostMessagesPathHostID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 5,
              parts[0] == "v0",
              parts[1] == "p2p",
              parts[2] == "hosts",
              parts[4] == "messages"
        else {
            return nil
        }
        return UUID(uuidString: parts[3])
    }

    private static func p2pSendMessagePathSessionID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 6,
              parts[0] == "v0",
              parts[1] == "p2p",
              parts[2] == "sessions",
              parts[4] == "messages",
              parts[5] == "send"
        else {
            return nil
        }
        return UUID(uuidString: parts[3])
    }

    private static func p2pMessagesPathSessionID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 5,
              parts[0] == "v0",
              parts[1] == "p2p",
              parts[2] == "sessions",
              parts[4] == "messages"
        else {
            return nil
        }
        return UUID(uuidString: parts[3])
    }

    private static func queryValue(_ name: String, from uri: String) -> String? {
        URLComponents(string: "http://relay.local\(uri)")?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private static func p2pStatus(for error: Error) -> HTTPResponseStatus {
        if let relayError = error as? RelayProtocolError {
            switch relayError {
            case .hostNotRegistered:
                return .notFound
            case .deviceNotAuthorized:
                return .forbidden
            case .incompatibleVersion:
                return .conflict
            }
        }
        return .badRequest
    }

    private static func urlRequest(from head: HTTPRequestHead) -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://relay.local\(head.uri)")!)
        for header in head.headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    private static func completedLines(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
    }

    private static func write(
        _ envelope: RelayHostBridgeEnvelope,
        to outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        allocator: ByteBufferAllocator
    ) async throws {
        let line = try RelayHostBridgeEnvelope.encode(envelope)
        var buffer = allocator.buffer(capacity: line.utf8.count + 1)
        buffer.writeString(line + "\n")
        try await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
    }
}

private final class RelayPublicHTTPResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case let .head(head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case let .body(buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end:
            context.write(Self.wrapOutboundOut(.end(nil)), promise: promise)
        }
    }
}
