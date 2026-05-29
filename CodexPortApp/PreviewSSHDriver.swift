import CodexPortCore
import Foundation

final class PreviewSSHDriver: SSHDriver, @unchecked Sendable {
    private let fingerprint: String
    private let codec = JSONRPCCodec()

    init(fingerprint: String = "SHA256:preview") {
        self.fingerprint = fingerprint
    }

    func presentedHostKeyFingerprint(host: String, port: Int, username: String, credential: SSHCredential) async throws -> String {
        fingerprint
    }

    func connect(_ request: SSHConnectionRequest) async throws -> SSHByteStream {
        let stdout = AsyncBytesReader(chunks: [], isFinished: false)
        let stdin = AsyncBytesWriter { [codec] data in
            guard let raw = String(data: data, encoding: .utf8) else { return }
            for line in raw.split(separator: "\n") {
                guard case let .request(id, method, _) = try? codec.decode(Data(line.utf8)) else { continue }
                let response = JSONRPCOutboundResponse(id: id, result: Self.result(for: method))
                let encoded = try codec.encodeResponse(response)
                var framed = encoded
                framed.append(0x0A)
                await stdout.feed(framed)
            }
        }
        return SSHByteStream(stdin: stdin, stdout: stdout)
    }

    func runCommand(_ request: SSHConnectionRequest) async throws -> SSHCommandResult {
        switch request.command {
        case _ where request.command.contains("--version"):
            return SSHCommandResult(stdout: Data("codex-cli 0.133.0\n".utf8), exitStatus: 0)
        case _ where request.command.contains("app-server --help"):
            return SSHCommandResult(stdout: Data("Usage: codex app-server\n".utf8), exitStatus: 0)
        case _ where request.command.contains("daemon start"):
            return SSHCommandResult(stdout: Data("daemon started\n".utf8), exitStatus: 0)
        default:
            return SSHCommandResult(exitStatus: 0)
        }
    }

    private static func result(for method: String) -> JSONValue {
        switch method {
        case "initialize":
            return .object(["protocolVersion": .string("0.1.0"), "model": .string("5.5 超高")])
        case "thread/list":
            return .object([
                "threads": .array([
                    .object([
                        "id": .string("thread-codex-ios"),
                        "cwd": .string("/Users/chenm/Projects/codex-port"),
                        "updatedAt": .string("2026-05-28T04:00:00Z"),
                        "preview": .string("继续实现 iOS 客户端"),
                        "gitInfo": .object(["repository": .string("codex-port"), "branch": .string("main")])
                    ]),
                    .object([
                        "id": .string("thread-vps"),
                        "cwd": .string("/home/codex/workspace"),
                        "updatedAt": .string("2026-05-28T03:00:00Z"),
                        "preview": .string("检查 VPS 上的 Codex 配置")
                    ])
                ])
            ])
        case "thread/read", "thread/resume":
            return .object([
                "thread": .object([
                    "id": .string("thread-codex-ios"),
                    "turns": .array([
                        .object([
                            "id": .string("turn-1"),
                            "status": .string("completed"),
                            "items": .array([
                                .object(["type": .string("assistantMessage"), "text": .string("已读取远端 Codex 会话历史。")]),
                                .object(["type": .string("commandOutput"), "text": .string("codex app-server --listen stdio://\n")]),
                                .object(["type": .string("fileChange"), "path": .string("Sources/CodexPortCore/SessionStore.swift"), "diff": .string("+ parse thread/resume response")])
                            ])
                        ])
                    ])
                ])
            ])
        case "turn/start":
            return .object(["turnId": .string("turn-preview")])
        case "fs/readDirectory":
            return .object([
                "entries": .array([
                    .object(["name": .string("Projects"), "path": .string("~/Projects"), "kind": .string("directory")]),
                    .object(["name": .string("workspace"), "path": .string("~/workspace"), "kind": .string("directory")]),
                    .object(["name": .string("README.md"), "path": .string("~/README.md"), "kind": .string("file")])
                ])
            ])
        case "fs/createDirectory":
            return .object([:])
        default:
            return .object([:])
        }
    }
}
