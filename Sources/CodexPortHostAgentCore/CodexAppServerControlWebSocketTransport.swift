import Foundation
import Darwin

public enum CodexAppServerControlWebSocketTransportError: Error, Equatable, Sendable {
    case socketOpenFailed
    case connectFailed
    case handshakeFailed
    case invalidFrame
    case missingResponse(ControlJSONRPCID)
    case requestFailed(String)
}

public final class CodexAppServerControlWebSocketTransport: CodexAppServerControlTransporting, @unchecked Sendable {
    private final class ResponseWaiter: @unchecked Sendable {
        let id: ControlJSONRPCID
        let continuation: CheckedContinuation<ControlJSONValue, Error>

        init(id: ControlJSONRPCID, continuation: CheckedContinuation<ControlJSONValue, Error>) {
            self.id = id
            self.continuation = continuation
        }
    }

    private let socketPath: String
    private let codec = ControlJSONRPCCodec()
    private let lock = NSLock()

    private var fd: Int32 = -1
    private var connected = false
    private var requestCounter = 0
    private var responseWaiters: [ControlJSONRPCID: ResponseWaiter] = [:]
    private var notificationContinuations: [UUID: AsyncStream<ControlJSONRPCNotification>.Continuation] = [:]
    private var readerTask: Task<Void, Never>?

    public convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.init(socketPath: "\(home)/.codex/app-server-control/app-server-control.sock")
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    public func connect() async throws {
        if lock.withLock({ connected }) {
            return
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CodexAppServerControlWebSocketTransportError.socketOpenFailed
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            Darwin.close(socketFD)
            throw CodexAppServerControlWebSocketTransportError.connectFailed
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, maxPathLength)
            }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(socketFD)
            throw CodexAppServerControlWebSocketTransportError.connectFailed
        }
        fd = socketFD
        try writeRaw(Self.handshakeRequest)
        let handshake = try readUntilHeaderEnd()
        guard handshake.contains(" 101 ") || handshake.contains(" 101\r\n") else {
            throw CodexAppServerControlWebSocketTransportError.handshakeFailed
        }
        lock.withLock {
            connected = true
        }
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func notifications() async -> AsyncStream<ControlJSONRPCNotification> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                notificationContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.notificationContinuations[id] = nil
                }
            }
        }
    }

    public func request(method: String, params: ControlJSONValue) async throws -> ControlJSONValue {
        try await connect()
        let id = nextRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = ResponseWaiter(id: id, continuation: continuation)
            lock.withLock {
                responseWaiters[id] = waiter
            }
            Task { [weak self] in
                do {
                    let data = try self?.codec.encodeRequest(id: id, method: method, params: params) ?? Data()
                    try self?.writeWebSocketTextFrame(data)
                } catch {
                    self?.removeWaiter(id)?.continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        readerTask?.cancel()
        readerTask = nil
        let oldFD = fd
        fd = -1
        if oldFD >= 0 {
            Darwin.close(oldFD)
        }
        lock.withLock {
            connected = false
        }
        let waiters = lock.withLock {
            let waiters = Array(responseWaiters.values)
            responseWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(throwing: CodexAppServerControlWebSocketTransportError.missingResponse(waiter.id))
        }
        finishNotifications()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                guard let payload = try readWebSocketPayload() else {
                    await close()
                    return
                }
                guard let message = try? codec.decode(payload) else {
                    continue
                }
                handle(message)
            } catch {
                await close()
                return
            }
        }
    }

    private func handle(_ message: ControlJSONRPCInboundMessage) {
        switch message {
        case let .response(id, result):
            removeWaiter(id)?.continuation.resume(returning: result)
        case let .error(id, _, message):
            removeWaiter(id)?.continuation.resume(throwing: CodexAppServerControlWebSocketTransportError.requestFailed(message))
        case let .notification(method, params):
            emit(ControlJSONRPCNotification(method: method, params: params))
        case let .request(_, method, params):
            emit(ControlJSONRPCNotification(method: method, params: params))
        }
    }

    private func nextRequestID() -> ControlJSONRPCID {
        lock.withLock {
            requestCounter += 1
            return .number(requestCounter)
        }
    }

    private func removeWaiter(_ id: ControlJSONRPCID) -> ResponseWaiter? {
        lock.withLock {
            responseWaiters.removeValue(forKey: id)
        }
    }

    private func emit(_ notification: ControlJSONRPCNotification) {
        let continuations = lock.withLock {
            Array(notificationContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(notification)
        }
    }

    private func finishNotifications() {
        let continuations = lock.withLock {
            let continuations = Array(notificationContinuations.values)
            notificationContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func readUntilHeaderEnd() throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else {
                throw CodexAppServerControlWebSocketTransportError.handshakeFailed
            }
            data.append(byte)
            if data.suffix(4) == Data([13, 10, 13, 10]) {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func readWebSocketPayload() throws -> Data? {
        let header = try readExact(byteCount: 2)
        guard header.count == 2 else { return nil }
        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        var length = Int(header[1] & 0x7F)
        if length == 126 {
            let extended = try readExact(byteCount: 2)
            length = (Int(extended[0]) << 8) | Int(extended[1])
        } else if length == 127 {
            let extended = try readExact(byteCount: 8)
            length = extended.reduce(0) { ($0 << 8) | Int($1) }
        }
        var maskingKey = Data()
        if masked {
            maskingKey = try readExact(byteCount: 4)
        }
        var payload = try readExact(byteCount: length)
        if masked {
            for index in payload.indices {
                payload[index] ^= maskingKey[index % 4]
            }
        }
        if opcode == 0x8 {
            return nil
        }
        if opcode == 0x9 {
            try writeWebSocketFrame(opcode: 0xA, payload: payload)
            return try readWebSocketPayload()
        }
        guard opcode == 0x1 || opcode == 0x2 else {
            throw CodexAppServerControlWebSocketTransportError.invalidFrame
        }
        return payload
    }

    private func readExact(byteCount: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            var buffer = [UInt8](repeating: 0, count: byteCount - data.count)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                throw CodexAppServerControlWebSocketTransportError.invalidFrame
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func writeWebSocketTextFrame(_ payload: Data) throws {
        try writeWebSocketFrame(opcode: 0x1, payload: payload)
    }

    private func writeWebSocketFrame(opcode: UInt8, payload: Data) throws {
        var frame = Data()
        frame.append(0x80 | opcode)
        let maskKey = Data((0..<4).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        frame.append(maskKey)
        var maskedPayload = payload
        for index in maskedPayload.indices {
            maskedPayload[index] ^= maskKey[index % 4]
        }
        frame.append(maskedPayload)
        try writeRaw(frame)
    }

    private func writeRaw(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                guard count > 0 else {
                    throw CodexAppServerControlWebSocketTransportError.invalidFrame
                }
                written += count
            }
        }
    }

    private static let handshakeRequest = Data(
        """
        GET / HTTP/1.1\r
        Host: localhost\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: Y29kZXhwb3J0LWhvc3RhZ2VudA==\r
        Sec-WebSocket-Version: 13\r
        \r

        """.utf8
    )
}
