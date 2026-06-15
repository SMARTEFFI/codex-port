# ADR 0003: P2P-first remote connection

## Status

已接受。

## Context

`0.2.x` 的 production Relay/VPS path 已实现为 `Relay-mediated JSONL Bridge`：iOS stream 和 HostAgent bridge 都连接到 VPS Relay，由 Relay 按 stream route 转发 JSONL bridge lines。#55 和 #61 的真实测试暴露了两个问题：HostAgent/Relay 长连接和恢复状态不够可观测，且当前 `codex exec resume --json` adapter 不是稳定的实时事件回流源。与此同时，`Relay-mediated JSONL Bridge` 还没有达到 `Opaque Relay Stream` 的安全语义，因为 Relay 仍能看到 bridge envelope 和 application line。

## Decision

废弃当前 `Relay-mediated JSONL Bridge` 作为后续 production 远程传输方向，改为 `P2P-first Remote Connection`。

iOS app 与 `CodexPort Host Agent` 优先通过 `WebRTC DataChannel Transport` 直连通信。VPS 保留为 `P2P Signaling Service`：保存 `Pairing Record`、处理 device revoke、发布 presence，并在授权的 iOS device 与 HostAgent 之间转发 WebRTC offer/answer/ICE candidate。直连失败时允许 `TURN relay fallback`，但 TURN server 只承载 WebRTC 加密传输字节，不解析 `Client-Host Session Protocol`，不保存 Codex session state，也不承担 JSONL route。

`P2P-first Remote Connection` 复用 `CodexPort Host Agent`、`Device Identity`、`Pairing`、`Relay Host` 入口、Mac 侧 Codex live source 选择和 iOS foreground recovery 概念。当前 JSONL session/list/history/prompt/status/fan-out 语义可作为 `Client-Host Session Protocol` 继续复用，但不能再被描述为 Relay/VPS transport 本身。

第一版安全边界依赖 WebRTC transport encryption、pairing 授权和 endpoint identity 校验；暂不叠加第二层 application encryption。后续如果 threat model 提升，再通过新 ADR 决策。

## Consequences

- #29 不应再以补强当前 VPS JSONL 中转为主线；后续 issue 应围绕 P2P signaling、WebRTC DataChannel、TURN fallback、connection path diagnostics 和 HostAgent live source 分层拆分。
- #55 仍然有价值，但它修的是 Mac 侧 Codex live source 和 event 回流，不应被视为当前 Relay-mediated transport 的长期投资依据。
- #61 的教训必须进入新方案：iOS、HostAgent UI 和 diagnostics 必须暴露 `Remote Connection Path State`，至少区分 signaling、ICE、direct、TURN-relayed、DataChannel、Host protocol 和 Codex live source 阶段。
- ADR 0002 的 repo 双产品组织和 HostAgent/Pairing 边界仍然有效；被废弃的是 production 数据传输路径，不是 HostAgent 产品边界。
