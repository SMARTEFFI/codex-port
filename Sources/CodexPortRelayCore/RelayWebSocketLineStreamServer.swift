import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public final class RelayWebSocketLineStreamServer: @unchecked Sendable {
    public struct LineWriter: Sendable {
        private let send: @Sendable (String) async throws -> Void

        public init(send: @escaping @Sendable (String) async throws -> Void) {
            self.send = send
        }

        public func sendLine(_ line: String) async throws {
            try await send(line)
        }
    }

    public typealias LineHandler = @Sendable (_ stream: RelayAuthorizedStream, _ line: String, _ writer: LineWriter) async throws -> Void

    private enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, HTTPRequestHead)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    private let host: String
    private let port: Int
    private let gateway: RelayAuthenticatedStreamGateway
    private let lineHandler: LineHandler
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var serverChannel: Channel?
    private var acceptTask: Task<Void, Never>?
    private let taskLock = NSLock()
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        host: String = "127.0.0.1",
        port: Int = 0,
        gateway: RelayAuthenticatedStreamGateway,
        lineHandler: @escaping LineHandler
    ) {
        self.host = host
        self.port = port
        self.gateway = gateway
        self.lineHandler = lineHandler
    }

    deinit {
        acceptTask?.cancel()
        try? serverChannel?.close().wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    public func start() async throws -> URL {
        let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(
            group: eventLoopGroup
        )
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                    shouldUpgrade: { _, head in
                        channel.eventLoop.makeSucceededFuture(Self.validateOpenRequest(head))
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
                            try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
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

        let port = try channel.channel.localAddress?.port.requireRelayPort()
        guard let port else {
            throw RelayWebSocketLineStreamServerError.missingLocalPort
        }
        return URL(string: "ws://\(host):\(port)/v0/streams")!
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        try? await serverChannel?.close().get()
        serverChannel = nil
        await waitForConnectionTasksToFinish()
        try? await eventLoopGroup.shutdownGracefully()
    }

    private func trackConnectionTask(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.removeConnectionTask(id)
        }
        taskLock.withLock {
            if !task.isCancelled {
                connectionTasks[id] = task
            }
        }
    }

    private func removeConnectionTask(_ id: UUID) {
        taskLock.withLock {
            connectionTasks[id] = nil
        }
    }

    private func waitForConnectionTasksToFinish() async {
        let tasks = taskLock.withLock {
            let tasks = Array(connectionTasks.values)
            connectionTasks.removeAll()
            return tasks
        }
        for task in tasks {
            _ = await task.result
        }
    }

    private func handleUpgradeResult(_ result: EventLoopFuture<UpgradeResult>) async {
        do {
            switch try await result.get() {
            case let .websocket(channel, head):
                let request = Self.urlRequest(from: head)
                let stream = try await gateway.openWebSocketStream(from: request)
                try await handleWebSocketChannel(channel, stream: stream)
            case let .notUpgraded(channel):
                try await handleHTTPChannel(channel)
            }
        } catch {
        }
    }

    private func handleWebSocketChannel(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        stream: RelayAuthorizedStream
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            let writer = LineWriter { line in
                var buffer = channel.channel.allocator.buffer(capacity: line.utf8.count + 1)
                buffer.writeString(line + "\n")
                try await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
                await self.gateway.recordHostToDevice(streamID: stream.id, byteCount: buffer.readableBytes)
            }

            for try await frame in inbound {
                switch frame.opcode {
                case .text:
                    var data = frame.unmaskedData
                    let text = data.readString(length: data.readableBytes) ?? ""
                    await gateway.recordDeviceToHost(streamID: stream.id, byteCount: text.utf8.count)
                    for line in Self.completedLines(from: text) {
                        try await lineHandler(stream, line, writer)
                    }
                case .connectionClose:
                    await gateway.close(streamID: stream.id, errorCode: nil)
                    var closeData = frame.unmaskedData
                    let closeDataCode = closeData.readSlice(length: 2) ?? ByteBuffer()
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode))
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
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head = part else { continue }
                var headers = HTTPHeaders()
                headers.add(name: "Connection", value: "close")
                headers.add(name: "Content-Length", value: "0")
                let head = HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers)
                try await outbound.write(contentsOf: [.head(head), .end(nil)])
                return
            }
        }
    }

    private static func validateOpenRequest(_ head: HTTPRequestHead) -> HTTPHeaders? {
        do {
            _ = try RelayStreamOpenRequestWebSocketCodec.decode(from: urlRequest(from: head))
            return HTTPHeaders()
        } catch {
            return nil
        }
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
}

public enum RelayWebSocketLineStreamServerError: Error, Equatable, Sendable {
    case missingLocalPort
}

private final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case let .head(head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case let .body(buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case let .end(trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

private extension Optional where Wrapped == Int {
    func requireRelayPort() throws -> Int {
        guard let self else {
            throw RelayWebSocketLineStreamServerError.missingLocalPort
        }
        return self
    }
}
