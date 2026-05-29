#if canImport(Network)
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public final class NIOSSHDriver: SSHDriver, @unchecked Sendable {
    private let group: any EventLoopGroup

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)) {
        self.group = group
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    public func presentedHostKeyFingerprint(host: String, port: Int, username: String, credential: SSHCredential) async throws -> String {
        let serverAuthDelegate = HostKeyDelegate(expectedFingerprint: nil)
        let channel = try await connectTransport(
            host: host,
            port: port,
            username: username,
            credential: credential,
            serverAuthDelegate: serverAuthDelegate
        )
        defer {
            channel.close(promise: nil)
        }
        do {
            return try await serverAuthDelegate.waitForFingerprint()
        } catch {
            throw error
        }
    }

    public func connect(_ request: SSHConnectionRequest) async throws -> SSHByteStream {
        let stdout = AsyncBytesReader(chunks: [], isFinished: false)
        let stderr = AsyncBytesReader(chunks: [], isFinished: false)
        let serverAuthDelegate = HostKeyDelegate(expectedFingerprint: request.expectedHostKeyFingerprint)
        let channel = try await connectTransport(
            host: request.host,
            port: request.port,
            username: request.username,
            credential: request.credential,
            serverAuthDelegate: serverAuthDelegate
        )

        _ = try await serverAuthDelegate.waitForFingerprint()
        let childChannel = try await createExecChannel(
            command: request.command,
            parentChannel: channel,
            stdout: stdout,
            stderr: stderr
        )
        let stdin = AsyncBytesWriter { [writer = NIOChannelWriter(channel: childChannel)] data in
            try await writer.write(data)
        }
        return SSHByteStream(stdin: stdin, stdout: stdout, stderr: stderr)
    }

    public func runCommand(_ request: SSHConnectionRequest) async throws -> SSHCommandResult {
        let stdout = AsyncBytesReader(chunks: [], isFinished: false)
        let stderr = AsyncBytesReader(chunks: [], isFinished: false)
        let exitStatus = ExitStatusRecorder()
        let serverAuthDelegate = HostKeyDelegate(expectedFingerprint: request.expectedHostKeyFingerprint)
        let channel = try await connectTransport(
            host: request.host,
            port: request.port,
            username: request.username,
            credential: request.credential,
            serverAuthDelegate: serverAuthDelegate
        )
        defer {
            channel.close(promise: nil)
        }

        _ = try await serverAuthDelegate.waitForFingerprint()
        let requestAck = ExecRequestAck()
        let childChannel = try await createExecChannel(
            command: request.command,
            parentChannel: channel,
            stdout: stdout,
            stderr: stderr,
            exitStatus: exitStatus,
            requestAck: requestAck
        )
        try await requestAck.wait()
        try await childChannel.closeFuture.get()
        return SSHCommandResult(
            stdout: await stdout.collectRemaining(),
            stderr: await stderr.collectRemaining(),
            exitStatus: await exitStatus.value
        )
    }

    public static func fingerprint(openSSHPublicKeyLine: String) throws -> String {
        let parts = openSSHPublicKeyLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw SSHConnectionError.remoteCommandFailed("Invalid OpenSSH public key")
        }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public static func ed25519Seed(fromPrivateKeyData data: Data) throws -> Data {
        if data.count == 32 {
            return data
        }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("BEGIN OPENSSH PRIVATE KEY")
        else {
            throw SSHConnectionError.authenticationRejected
        }
        let body = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: body) else {
            throw SSHConnectionError.authenticationRejected
        }
        var parser = OpenSSHPrivateKeyParser(blob: blob)
        return try parser.ed25519Seed()
    }

    fileprivate static func fingerprint(for key: NIOSSHPublicKey) throws -> String {
        try fingerprint(openSSHPublicKeyLine: String(openSSHPublicKey: key))
    }

    private func connectTransport(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        serverAuthDelegate: HostKeyDelegate
    ) async throws -> Channel {
        let userAuthDelegate = try UserAuthenticationDelegate(username: username, credential: credential)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(
                            SSHClientConfiguration(
                                userAuthDelegate: userAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(NIOErrorHandler { error in
                        serverAuthDelegate.failIfUnresolved(error)
                    })
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            channel.closeFuture.whenComplete { _ in
                serverAuthDelegate.failIfUnresolved(
                    SSHConnectionError.connectionClosed("SSH transport closed before host key validation completed.")
                )
            }
            return channel
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.networkUnreachable(String(describing: error))
        }
    }

    private func createExecChannel(
        command: String,
        parentChannel: Channel,
        stdout: AsyncBytesReader,
        stderr: AsyncBytesReader,
        exitStatus: ExitStatusRecorder? = nil,
        requestAck: ExecRequestAck? = nil
    ) async throws -> Channel {
        try await parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard case .session = channelType else {
                    return childChannel.eventLoop.makeFailedFuture(SSHConnectionError.remoteCommandFailed("Invalid SSH channel type"))
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    try childChannel.pipeline.syncOperations.addHandler(
                        ExecChannelHandler(
                            command: command,
                            stdout: stdout,
                            stderr: stderr,
                            exitStatus: exitStatus,
                            requestAck: requestAck
                        )
                    )
                    try childChannel.pipeline.syncOperations.addHandler(NIOErrorHandler())
                }
            }
            return promise.futureResult
        }.get()
    }
}

private final class UserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let offer: NIOSSHUserAuthenticationOffer
    private let method: NIOSSHAvailableUserAuthenticationMethods
    private let lock = NSLock()
    private var didOffer = false

    init(username: String, credential: SSHCredential) throws {
        switch credential {
        case let .password(password):
            offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
            method = .password
        case let .key(data):
            let privateKey = try Self.privateKey(from: data)
            offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
            method = .publicKey
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !didOffer, availableMethods.contains(method) else {
            nextChallengePromise.fail(SSHConnectionError.authenticationRejected)
            return
        }
        didOffer = true
        nextChallengePromise.succeed(offer)
    }

    private static func privateKey(from data: Data) throws -> NIOSSHPrivateKey {
        let seed = try NIOSSHDriver.ed25519Seed(fromPrivateKeyData: data)
        return try NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }
}

private struct OpenSSHPrivateKeyParser {
    private var data: Data
    private var index = 0

    init(blob: Data) {
        self.data = blob
    }

    mutating func ed25519Seed() throws -> Data {
        let magic = Data("openssh-key-v1\u{0}".utf8)
        guard readBytes(magic.count) == magic,
              try readString() == Data("none".utf8),
              try readString() == Data("none".utf8)
        else {
            throw SSHConnectionError.authenticationRejected
        }
        _ = try readString()
        guard try readUInt32() == 1 else {
            throw SSHConnectionError.authenticationRejected
        }
        _ = try readString()
        var privateBlock = OpenSSHPrivateKeyParser(blob: try readString())
        let firstCheck = try privateBlock.readUInt32()
        guard firstCheck == (try privateBlock.readUInt32()) else {
            throw SSHConnectionError.authenticationRejected
        }
        guard try privateBlock.readString() == Data("ssh-ed25519".utf8) else {
            throw SSHConnectionError.authenticationRejected
        }
        _ = try privateBlock.readString()
        let privateKey = try privateBlock.readString()
        guard privateKey.count >= 32 else {
            throw SSHConnectionError.authenticationRejected
        }
        return privateKey.prefix(32)
    }

    private mutating func readUInt32() throws -> UInt32 {
        let bytes = try readRequiredBytes(4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private mutating func readString() throws -> Data {
        let length = try Int(readUInt32())
        return try readRequiredBytes(length)
    }

    private mutating func readRequiredBytes(_ length: Int) throws -> Data {
        let bytes = readBytes(length)
        guard bytes.count == length else {
            throw SSHConnectionError.authenticationRejected
        }
        return bytes
    }

    private mutating func readBytes(_ length: Int) -> Data {
        guard length >= 0, index + length <= data.count else {
            index = data.count
            return Data()
        }
        let bytes = data[index..<index + length]
        index += length
        return Data(bytes)
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?

    init(expectedFingerprint: String?) {
        self.expectedFingerprint = expectedFingerprint
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let fingerprint = try NIOSSHDriver.fingerprint(for: hostKey)
            if let expectedFingerprint, expectedFingerprint != fingerprint {
                let error = SSHConnectionError.hostKeyChanged(expected: expectedFingerprint, presented: fingerprint)
                complete(.failure(error))
                validationCompletePromise.fail(error)
                return
            }
            complete(.success(fingerprint))
            validationCompletePromise.succeed(())
        } catch {
            complete(.failure(error))
            validationCompletePromise.fail(error)
        }
    }

    func waitForFingerprint() async throws -> String {
        if let result = currentResult() {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let result = install(continuation) {
                continuation.resume(with: result)
            }
        }
    }

    func failIfUnresolved(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ newResult: Result<String, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(with: newResult)
    }

    private func currentResult() -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func install(_ newContinuation: CheckedContinuation<String, Error>) -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let result {
            return result
        }
        continuation = newContinuation
        return nil
    }
}

private final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stdout: AsyncBytesReader
    private let stderr: AsyncBytesReader
    private let exitStatus: ExitStatusRecorder?
    private let requestAck: ExecRequestAck?

    init(
        command: String,
        stdout: AsyncBytesReader,
        stderr: AsyncBytesReader,
        exitStatus: ExitStatusRecorder?,
        requestAck: ExecRequestAck?
    ) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.requestAck = requestAck
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request).whenFailure { error in
            self.requestAck?.fail(error)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = channelData.data else { return }
        let payload = Data(buffer.readableBytesView)

        switch channelData.type {
        case .channel:
            let stdout = self.stdout
            Task { await stdout.feed(payload) }
        case .stdErr:
            let stderr = self.stderr
            Task { await stderr.feed(payload) }
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            requestAck?.succeed()
            return
        case is ChannelFailureEvent:
            requestAck?.fail(SSHConnectionError.remoteCommandFailed("SSH server rejected exec request: \(command)"))
            context.close(promise: nil)
            return
        default:
            break
        }
        if let event = event as? SSHChannelRequestEvent.ExitStatus {
            let recorder = exitStatus
            Task { await recorder?.record(event.exitStatus) }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestAck?.fail(SSHConnectionError.connectionClosed("SSH exec channel closed before command was accepted: \(command)"))
        finishStreams()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        requestAck?.fail(error)
        finishStreams()
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finishStreams()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    private func finishStreams() {
        let stdout = self.stdout
        let stderr = self.stderr
        Task {
            await stdout.finish()
            await stderr.finish()
        }
    }
}

private actor ExitStatusRecorder {
    private var recorded: Int32?

    func record(_ value: Int) {
        recorded = Int32(value)
    }

    var value: Int32? {
        recorded
    }
}

private final class ExecRequestAck: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        if let result = currentResult() {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let result = install(continuation) {
                continuation.resume(with: result)
            }
        }
    }

    func succeed() {
        complete(.success(()))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ newResult: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(with: newResult)
    }

    private func currentResult() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func install(_ newContinuation: CheckedContinuation<Void, Error>) -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let result {
            return result
        }
        continuation = newContinuation
        return nil
    }
}

private final class NIOChannelWriter: @unchecked Sendable {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }
}

private final class NIOErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}
#endif
