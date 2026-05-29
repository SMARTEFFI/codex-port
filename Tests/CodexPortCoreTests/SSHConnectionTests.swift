import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import CodexPortCore

@Test func sshConnectionServiceConfirmsUnknownHostKeyThenExposesByteStream() async throws {
    let driver = FakeSSHDriver()
    driver.presentedFingerprint = "SHA256:first"
    driver.stream = SSHByteStream(
        stdin: AsyncBytesWriter(),
        stdout: AsyncBytesReader(chunks: [Data("{}".utf8)])
    )
    let verifier = KnownHostVerifier()
    let service = SSHConnectionService(driver: driver, knownHosts: verifier)
    let profile = HostProfile(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        name: "VPS",
        host: "203.0.113.10",
        port: 22,
        username: "root",
        auth: .password(credentialID: "credential-1"),
        codexPath: "codex",
        startupCommand: "codex app-server daemon start && codex app-server proxy",
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )

    let first = try await service.connect(profile: profile, credential: .password("secret"), decision: .confirmUnknownHost)
    #expect(first.state == .connected)
    #expect(await first.stream.stderr.read() == nil)
    #expect(driver.presentedHostKeyCredentials == [.password("secret")])
    #expect(driver.lastConnection?.host == "203.0.113.10")
    #expect(driver.lastConnection?.command == "codex app-server daemon start && codex app-server proxy")
    #expect(driver.lastConnection?.expectedHostKeyFingerprint == "SHA256:first")

    let second = try await service.connect(profile: profile, credential: .password("secret"), decision: .rejectUnknownHost)
    #expect(second.state == .connected)
    #expect(driver.presentedHostKeyCredentials == [.password("secret"), .password("secret")])
    #expect(driver.lastConnection?.expectedHostKeyFingerprint == "SHA256:first")
}

@Test func sshConnectionServiceBlocksChangedHostKeyAndClassifiesAuthFailure() async {
    let profileID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let profile = HostProfile(
        id: profileID,
        name: "Mac",
        host: "mac.local",
        port: 22,
        username: "chenm",
        auth: .key(label: "id_ed25519", credentialID: "credential-1"),
        codexPath: "codex",
        startupCommand: "codex app-server daemon start && codex app-server proxy",
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )
    let verifier = KnownHostVerifier()
    verifier.trust(profileID: profileID, fingerprint: "SHA256:old")
    let driver = FakeSSHDriver()
    driver.presentedFingerprint = "SHA256:new"
    let service = SSHConnectionService(driver: driver, knownHosts: verifier)

    await #expect(throws: SSHConnectionError.hostKeyChanged(expected: "SHA256:old", presented: "SHA256:new")) {
        try await service.connect(profile: profile, credential: .key(Data("key".utf8)), decision: .confirmUnknownHost)
    }

    driver.presentedFingerprint = "SHA256:old"
    driver.error = .authenticationRejected
    await #expect(throws: SSHConnectionError.authenticationRejected) {
        try await service.connect(profile: profile, credential: .key(Data("key".utf8)), decision: .confirmUnknownHost)
    }
}

@Test func hostCredentialResolverReadsSavedPasswordForSSHConnection() throws {
    let vault = InMemoryCredentialVault()
    let credentialID = try vault.saveSecret("saved-password", protection: .localEncrypted)
    let profile = HostProfile(
        id: UUID(),
        name: "VPS",
        host: "example.com",
        port: 22,
        username: "deploy",
        auth: .password(credentialID: credentialID),
        codexPath: "codex",
        startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
        defaultDirectory: "~",
        knownHostFingerprint: nil
    )

    let resolver = HostCredentialResolver(vault: vault)

    #expect(try resolver.resolve(profile, authorization: .granted) == .password("saved-password"))
    #expect(try resolver.resolve(profile, authorization: .denied) == .password("saved-password"))
}

@Test func niosshDriverUsesOpenSSHSHA256HostKeyFingerprintFormat() throws {
    let line = "ssh-ed25519 AQID test"

    #expect(try NIOSSHDriver.fingerprint(openSSHPublicKeyLine: line) == "SHA256:A5BYxvLAy0ksUzsKTRTvd8wPeKvMztUofYShogEc+4E")
}

@Test func niosshDriverReadsHostKeyFromLocalOpenSSHCompatibleServer() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let hostPrivateKey = Curve25519.Signing.PrivateKey()
    let hostKey = NIOSSHPrivateKey(ed25519Key: hostPrivateKey)
    let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let ssh = NIOSSHHandler(
                    role: .server(
                        .init(
                            hostKeys: [hostKey],
                            userAuthDelegate: AcceptPasswordAuthDelegate(username: "tester", password: "secret")
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                try channel.pipeline.syncOperations.addHandler(ssh)
                try channel.pipeline.syncOperations.addHandler(TestNIOErrorHandler())
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()

    let port = try #require(server.localAddress?.port)
    let expectedLine = String(openSSHPublicKey: hostKey.publicKey)
    let fingerprint = try await NIOSSHDriver().presentedHostKeyFingerprint(
        host: "127.0.0.1",
        port: port,
        username: "tester",
        credential: .password("secret")
    )

    #expect(fingerprint == (try NIOSSHDriver.fingerprint(openSSHPublicKeyLine: expectedLine)))
    try await server.close().get()
    try await group.shutdownGracefullyAsync()
}

@Test func niosshDriverExtractsEd25519SeedFromUnencryptedOpenSSHPrivateKey() throws {
    let privateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACB/ChMf3Hv7X+Hy+r+mj52IDpeA3hK+qY0tPkJQ/lSEDQAAAJidN4fqnTeH
    6gAAAAtzc2gtZWQyNTUxOQAAACB/ChMf3Hv7X+Hy+r+mj52IDpeA3hK+qY0tPkJQ/lSEDQ
    AAAEBGC8BI3ZQ47Z7UqM/ltziItX06rAvXM/IzFgEwcqJqpX8KEx/ce/tf4fL6v6aPnYgO
    l4DeEr6pjS0+QlD+VIQNAAAADmNvZGV4LWlvcy10ZXN0AQIDBAUGBw==
    -----END OPENSSH PRIVATE KEY-----
    """

    #expect(try NIOSSHDriver.ed25519Seed(fromPrivateKeyData: Data(privateKey.utf8)).base64EncodedString() == "RgvASN2UOO2e1KjP5bc4iLV9OqwL1zPyMxYBMHKiaqU=")
}

private final class AcceptPasswordAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username, case let .password(requestPassword) = request.request else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(requestPassword.password == password ? .success : .failure)
    }
}

private final class TestNIOErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private extension EventLoopGroup {
    func shutdownGracefullyAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
