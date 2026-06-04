# ADR 0001: SSH driver dependency

## Status

Accepted and implemented for the MVP baseline.

## Context

The iOS client must connect to Mac/VPS/Linux hosts over SSH, run `codex app-server --listen stdio://`, and expose stdin/stdout as the transport for app-server JSON-RPC. The app intentionally avoids `daemon start`, `daemon restart`, `daemon stop`, and `app-server proxy` for this connection path so a normal connect attempt does not mutate or depend on the shared app-server daemon/control socket state. The code keeps a tested `SSHDriver` boundary, fake driver, and a production SwiftNIO-backed implementation.

## Decision

Use Apple `swift-nio-ssh` as the primary production SSH implementation behind the existing `SSHDriver` interface.

The package products are:

- `NIOSSH` from `https://github.com/apple/swift-nio-ssh.git`
- `NIOCore` from `https://github.com/apple/swift-nio.git`
- `NIOPosix` from `https://github.com/apple/swift-nio.git`
- `Crypto` from `https://github.com/apple/swift-crypto.git`

The driver should execute commands over an SSH session channel without PTY, route `.channel` data to stdout, route `.stdErr` data to stderr/diagnostics, and write stdin as `SSHChannelData(type: .channel, ...)`.

The production client uses `ClientBootstrap` from `NIOPosix`. `NIOTSConnectionBootstrap` was tested against OpenSSH 9.9 and closed the transport before the host key validation callback, which prevented first-connect trust prompts from appearing.

## Consequences

- The project keeps a deep `SSHDriver` interface while the SwiftNIO-specific code stays isolated in `NIOSSHDriver.swift`.
- JSON-RPC transport must not assume one stdout read equals one JSON message. `JSONRPCFramer` now handles newline-delimited split/coalesced messages.
- Host key trust must persist across launches. `FileKnownHostStore` and `PersistentKnownHostVerifier` now cover that requirement.
- Password auth and unencrypted OpenSSH Ed25519 private key auth are supported for the MVP. Encrypted keys and broader key formats remain future work.

## Notes

SwiftPM dependency resolution succeeded after the earlier local cache/network instability. `swift test` and the iOS Simulator build now include the production SSH driver dependencies.
