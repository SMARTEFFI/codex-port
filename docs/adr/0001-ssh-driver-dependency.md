# ADR 0001: SSH driver 依赖

## Status

已接受，并已在 MVP baseline 中实现。

## Context

iOS client 必须通过 SSH 连接 Mac/VPS/Linux hosts，运行 `codex app-server --listen stdio://`，并把 stdin/stdout 暴露为 app-server JSON-RPC 的 transport。此连接路径刻意避开 `daemon start`、`daemon restart`、`daemon stop` 和 `app-server proxy`，这样一次普通连接尝试不会修改或依赖共享的 app-server daemon/control socket 状态。代码保留了经过测试的 `SSHDriver` 边界、fake driver，以及基于 SwiftNIO 的 production implementation。

## Decision

在现有 `SSHDriver` interface 后面，使用 Apple `swift-nio-ssh` 作为主要 production SSH implementation。

package products 如下：

- `NIOSSH` 来自 `https://github.com/apple/swift-nio-ssh.git`
- `NIOCore` 来自 `https://github.com/apple/swift-nio.git`
- `NIOPosix` 来自 `https://github.com/apple/swift-nio.git`
- `Crypto` 来自 `https://github.com/apple/swift-crypto.git`

driver 应通过不带 PTY 的 SSH session channel 执行命令，将 `.channel` data 路由到 stdout，将 `.stdErr` data 路由到 stderr/diagnostics，并以 `SSHChannelData(type: .channel, ...)` 写入 stdin。

production client 使用 `NIOPosix` 的 `ClientBootstrap`。`NIOTSConnectionBootstrap` 曾用 OpenSSH 9.9 测试，但它会在 host key validation callback 之前关闭 transport，导致首次连接的信任确认无法出现。

## Consequences

- 项目保留 deep `SSHDriver` interface，SwiftNIO-specific code 隔离在 `NIOSSHDriver.swift`。
- JSON-RPC transport 不能假设一次 stdout read 就等于一条 JSON message。`JSONRPCFramer` 现在处理 newline-delimited 的 split/coalesced messages。
- Host key trust 必须跨启动持久化。`FileKnownHostStore` 和 `PersistentKnownHostVerifier` 已覆盖该要求。
- MVP 支持 password auth 和未加密的 OpenSSH Ed25519 private key auth。Encrypted keys 和更广泛的 key formats 作为后续工作。

## Notes

早前本地 cache/network 不稳定之后，SwiftPM dependency resolution 已成功。`swift test` 和 iOS Simulator build 现在都包含 production SSH driver dependencies。
