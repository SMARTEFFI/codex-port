import Foundation

public enum SSHCredential: Equatable, Sendable {
    case password(String)
    case key(Data)
}

public final class HostCredentialResolver {
    private let vault: CredentialVault

    public init(vault: CredentialVault) {
        self.vault = vault
    }

    public func resolve(_ profile: HostProfile, authorization: CredentialAuthorization) throws -> SSHCredential {
        switch profile.auth {
        case let .password(credentialID):
            return .password(try vault.readSecret(id: credentialID, authorization: authorization))
        case let .key(_, credentialID):
            return .key(Data(try vault.readSecret(id: credentialID, authorization: authorization).utf8))
        }
    }
}

extension HostCredentialResolver: @unchecked Sendable {}

public enum UnknownHostDecision: Equatable, Sendable {
    case confirmUnknownHost
    case rejectUnknownHost
}

public struct PresentedHostKey: Equatable, Sendable {
    public var profileID: UUID
    public var fingerprint: String

    public init(profileID: UUID, fingerprint: String) {
        self.profileID = profileID
        self.fingerprint = fingerprint
    }
}

public enum SSHConnectionError: Error, Equatable {
    case unknownHostRejected(String)
    case hostKeyChanged(expected: String, presented: String)
    case authenticationRejected
    case networkUnreachable(String)
    case remoteCommandFailed(String)
    case timedOut(seconds: Double)
    case connectionClosed(String)
}

public enum SSHConnectionState: Equatable, Sendable {
    case connected
}

public actor AsyncBytesWriter {
    private var chunks: [Data] = []
    private let sink: @Sendable (Data) async throws -> Void

    public init(sink: @escaping @Sendable (Data) async throws -> Void = { _ in }) {
        self.sink = sink
    }

    public func write(_ data: Data) async throws {
        chunks.append(data)
        try await sink(data)
    }

    public var writtenChunks: [Data] {
        chunks
    }

    public func joinedWrittenData() -> Data {
        chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk)
        }
    }
}

public actor AsyncBytesReader {
    private var chunks: [Data]
    private var isFinished: Bool
    private var continuations: [CheckedContinuation<Data?, Never>] = []

    public init(chunks: [Data] = [], isFinished: Bool = true) {
        self.chunks = chunks
        self.isFinished = isFinished
    }

    public func read() async -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if isFinished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    public func feed(_ data: Data) {
        guard !isFinished else { return }
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: data)
        } else {
            chunks.append(data)
        }
    }

    public func finish() {
        isFinished = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: nil)
        }
    }

    public func collectRemaining() async -> Data {
        var output = Data()
        while let chunk = await read() {
            output.append(chunk)
        }
        return output
    }
}

public struct SSHByteStream: Sendable {
    public var stdin: AsyncBytesWriter
    public var stdout: AsyncBytesReader
    public var stderr: AsyncBytesReader

    public init(stdin: AsyncBytesWriter, stdout: AsyncBytesReader, stderr: AsyncBytesReader = AsyncBytesReader()) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct SSHConnectionRequest: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential
    public var expectedHostKeyFingerprint: String
    public var command: String

    public init(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        expectedHostKeyFingerprint: String,
        command: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.expectedHostKeyFingerprint = expectedHostKeyFingerprint
        self.command = command
    }
}

public struct SSHConnection: Sendable {
    public var state: SSHConnectionState
    public var stream: SSHByteStream
}

public struct SSHCommandResult: Equatable, Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int32?

    public init(stdout: Data = Data(), stderr: Data = Data(), exitStatus: Int32? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public protocol SSHDriver: AnyObject, Sendable {
    func presentedHostKeyFingerprint(host: String, port: Int, username: String, credential: SSHCredential) async throws -> String
    func connect(_ request: SSHConnectionRequest) async throws -> SSHByteStream
    func runCommand(_ request: SSHConnectionRequest) async throws -> SSHCommandResult
}

public final class SSHConnectionService {
    private let driver: SSHDriver
    private let knownHosts: KnownHostVerifying
    private let timeoutSeconds: Double

    public init(driver: SSHDriver, knownHosts: KnownHostVerifying, timeoutSeconds: Double = 12) {
        self.driver = driver
        self.knownHosts = knownHosts
        self.timeoutSeconds = timeoutSeconds
    }

    public func presentedHostKey(profile: HostProfile, credential: SSHCredential) async throws -> PresentedHostKey? {
        let fingerprint = try await withTimeout(seconds: timeoutSeconds) {
            try await self.driver.presentedHostKeyFingerprint(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                credential: credential
            )
        }
        switch knownHosts.evaluate(profileID: profile.id, presentedFingerprint: fingerprint) {
        case let .needsUserConfirmation(presented):
            return PresentedHostKey(profileID: profile.id, fingerprint: presented)
        case .trusted:
            return nil
        case let .changed(expected, presented):
            throw SSHConnectionError.hostKeyChanged(expected: expected, presented: presented)
        }
    }

    public func connect(
        profile: HostProfile,
        credential: SSHCredential,
        decision: UnknownHostDecision,
        commandOverride: String? = nil
    ) async throws -> SSHConnection {
        let fingerprint = try await trustedFingerprint(profile: profile, credential: credential, decision: decision)

        do {
            let request = SSHConnectionRequest(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                credential: credential,
                expectedHostKeyFingerprint: fingerprint,
                command: commandOverride ?? profile.startupCommand
            )
            let stream = try await withTimeout(seconds: timeoutSeconds) {
                try await self.driver.connect(request)
            }
            return SSHConnection(state: .connected, stream: stream)
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.remoteCommandFailed(String(describing: error))
        }
    }

    public func runCommand(profile: HostProfile, credential: SSHCredential, decision: UnknownHostDecision, command: String) async throws -> SSHCommandResult {
        let fingerprint = try await trustedFingerprint(profile: profile, credential: credential, decision: decision)
        do {
            let request = SSHConnectionRequest(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                credential: credential,
                expectedHostKeyFingerprint: fingerprint,
                command: command
            )
            return try await withTimeout(seconds: timeoutSeconds) {
                try await self.driver.runCommand(request)
            }
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.remoteCommandFailed(String(describing: error))
        }
    }

    private func trustedFingerprint(profile: HostProfile, credential: SSHCredential, decision: UnknownHostDecision) async throws -> String {
        let fingerprint = try await withTimeout(seconds: timeoutSeconds) {
            try await self.driver.presentedHostKeyFingerprint(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                credential: credential
            )
        }
        switch knownHosts.evaluate(profileID: profile.id, presentedFingerprint: fingerprint) {
        case let .needsUserConfirmation(presented):
            guard decision == .confirmUnknownHost else {
                throw SSHConnectionError.unknownHostRejected(presented)
            }
            try knownHosts.trust(profileID: profile.id, fingerprint: presented)
            return presented
        case .trusted:
            return fingerprint
        case let .changed(expected, presented):
            throw SSHConnectionError.hostKeyChanged(expected: expected, presented: presented)
        }
    }
}

extension SSHConnectionService: @unchecked Sendable {}

private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let operationTask = Task<T, Error> {
        try await operation()
    }
    let timeoutTask = Task<T, Error> {
        try await Task.sleep(for: .seconds(seconds))
        throw SSHConnectionError.timedOut(seconds: seconds)
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = TimeoutResolver<T>(
                continuation: continuation,
                cancelTasks: {
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            )
            Task {
                do {
                    resolver.resume(with: .success(try await operationTask.value))
                } catch {
                    resolver.resume(with: .failure(error))
                }
            }
            Task {
                do {
                    resolver.resume(with: .success(try await timeoutTask.value))
                } catch {
                    resolver.resume(with: .failure(error))
                }
            }
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
    }
}

private final class TimeoutResolver<T: Sendable>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Error>
    private let cancelTasks: @Sendable () -> Void
    private let lock = NSLock()
    private var isResolved = false

    init(continuation: CheckedContinuation<T, Error>, cancelTasks: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.cancelTasks = cancelTasks
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        lock.unlock()

        cancelTasks()
        continuation.resume(with: result)
    }
}
