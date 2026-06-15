# Codex App control plane research

## Question

是否存在稳定、可授权、可由 CodexPort 接入的 `Shared Live Session Source`，能够同时驱动 Mac 桌面 Codex App 和多个 iPhone 的 `Real-time Multi-Device Sync`？

2026-06-14 #80 correction:

本报告早期把用户外部观察解释为“官方 `codex` CLI/TUI 与 Codex Desktop 可以 open-session live sync”。#80 HITL 已修正该判断：HostAgent-compatible public protocol probe 可以让已打开 Codex TUI 实时显示同一 thread 的 user/assistant turn；Codex Desktop 打开同一 thread 时不会实时更新，退出重进后才通过 persisted history 看到新 turn。当前 `Shared Live Session Source` gate 收窄为 Codex TUI + iPhone live sync。下文关于 “CLI-backed Desktop sync” 的段落均视为历史假设，不再作为 PRD #77、#63 或 #74 的验收依据。

## Sources reviewed

- GitHub Issue #28: `Research: Codex App control plane for real-time multi-device sync`。
- 本仓库领域文档：`CONTEXT.md` 中的 `Direct SSH Connection`、`Relay Connection`、`Real-time Multi-Device Sync`、`Shared Live Session Source`、`Codex App Control Plane Research`、`Relay State Recovery`。
- 本仓库 ADR：`docs/adr/0001-ssh-driver-dependency.md`。
- 本仓库代码：
  - `Sources/CodexPortCore/AppServerSession.swift`
  - `Sources/CodexPortCore/JSONRPCCodec.swift`
- 当前本机 CLI：`codex-cli 0.137.0`。
- 当前本机 CLI help：
  - `codex app-server --help`
  - `codex app-server daemon --help`
  - `codex app-server proxy --help`
  - `codex app-server generate-json-schema --help`
  - `codex app-server generate-ts --help`
- 当前本机生成的 app-server protocol schema/TypeScript：
  - `.scratch/research/app-schema`
  - `.scratch/research/app-ts`
- 当前本机非侵入观测：
  - `ps` 进程树
  - `lsof` open files/socket 观察
  - `find ~/.codex ...` 只列路径，不读取凭据内容
  - `codex app-server daemon version`
  - WebSocket-over-UDS 只读 JSON-RPC request：`remoteControl/status/read`
- 用户补充的外部同步实验（2026-06-08）：
  - 会话 `019ea4d7-6c12-7132-8fad-4cd2028309ba`
  - 另一台 iMac 通过 SSH 登录本机运行 `codex` CLI
  - 该 CLI 会话里的消息在本机 Mac Codex Desktop 打开的同一会话中同步显示
  - 本机 `.codex/sessions/2026/06/08/` 下存在对应 `originator: codex-tui` rollout 记录
- `openai/codex` 官方公开源码，重点查看：
  - `codex-rs/app-server/src/main.rs`
  - `codex-rs/app-server/src/request_processors/remote_control_processor.rs`
  - `codex-rs/app-server-protocol/src/protocol/v2/remote_control.rs`
  - `codex-rs/app-server-daemon/src/lib.rs`
  - `codex-rs/app-server-daemon/src/client.rs`
  - `codex-rs/app-server-daemon/src/remote_control_client.rs`
  - `codex-rs/cli/src/remote_control_cmd.rs`
  - `codex-rs/app-server-transport/src/transport/unix_socket.rs`
  - `codex-rs/app-server-transport/src/transport/remote_control/auth.rs`
  - `codex-rs/app-server-transport/src/transport/remote_control/enroll.rs`
  - `codex-rs/app-server-transport/src/transport/remote_control/protocol.rs`
  - `codex-rs/app-server-transport/src/transport/remote_control/websocket.rs`
  - `codex-rs/app-server/tests/suite/v2/remote_control.rs`
- 官方 OpenAI Codex docs 尝试：
  - `openai-docs` skill 的 Codex manual helper 尝试抓取 `https://developers.openai.com/codex/codex-manual.md`，返回 HTTP 403。
  - Shell 直接访问 `https://developers.openai.com/codex/remote-connections` 和 `https://developers.openai.com/codex/app-server`，返回 Vercel HTTP 403。
  - 因此本报告不把未成功读取的官方网页正文作为结论依据。

## Findings

### 1. 当前 Direct SSH path 确实是独立 stdio app-server

本仓库当前实现和 ADR 一致：Direct SSH path 执行的是独立 `codex app-server --listen stdio://`。

- `Sources/CodexPortCore/AppServerSession.swift` 连接日志写明“打开独立 app-server stdio transport”。
- `Sources/CodexPortCore/JSONRPCCodec.swift` 的 `appServerCommand` 固定为 `codex app-server --listen stdio://`。
- `docs/adr/0001-ssh-driver-dependency.md` 明确说明 MVP path 刻意避开 `daemon start`、`daemon restart`、`daemon stop` 和 `app-server proxy`，以免普通连接修改或依赖共享 app-server daemon/control socket 状态。

这解释了实测现象：手机端通过现有 SSH path 发送消息时，Mac 桌面 Codex App 打开的同一会话不会 live 更新。该 path 不是 `Shared Live Session Source`。

### 2. app-server daemon/control socket 是公开 CLI surface，不是只存在于 Desktop binary 内部

当前 CLI help 暴露了 app-server daemon 和 proxy：

- `codex app-server --help` 显示 `--listen <URL>` 支持 `stdio://`、`unix://`、`unix://PATH`、`ws://IP:PORT`、`off`。
- `codex app-server daemon --help` 暴露 `bootstrap`、`start`、`restart`、`enable-remote-control`、`disable-remote-control`、`stop`、`version`。
- `codex app-server proxy --help` 说明它用于把 stdio bytes 代理到正在运行的 app-server control socket。
- `codex app-server generate-json-schema` 和 `generate-ts` 可生成当前 app-server protocol schema。

本机 `codex app-server daemon version` 返回 daemon 正在运行，socket path 为：

```text
~/.codex/app-server-control/app-server-control.sock
```

该 socket 文件权限为 `srw-------`，也就是仅当前 macOS 用户可访问。公开源码 `codex-rs/app-server-transport/src/transport/unix_socket.rs` 对 control socket 设置 `0600` 权限。

### 3. control socket transport 是 WebSocket-over-Unix-domain-socket

源码显示 control socket 不是普通 newline JSON socket：

- `codex-rs/app-server-transport/src/transport/unix_socket.rs` 在 Unix socket accept 后调用 `tokio_tungstenite::accept_async`。
- `codex-rs/app-server-daemon/src/client.rs` 通过 Unix socket 连接后调用 `client_async("ws://localhost/", stream)` 做 WebSocket upgrade。

因此 `codex app-server proxy` 或直接 socket 接入时，transport framing 需要严格按 app-server 的 WebSocket/JSON-RPC 协议处理。把 newline JSON 直接写入 socket 会失败。

### 4. `remoteControl/*` 是版本化 app-server protocol 的一部分

本机 CLI 生成的 schema/TS 和公开源码一致暴露了 remote-control JSON-RPC 方法：

- `remoteControl/enable`
- `remoteControl/disable`
- `remoteControl/status/read`
- `remoteControl/pairing/start`
- `remoteControl/pairing/status`
- `remoteControl/client/list`
- `remoteControl/client/revoke`
- notification：`remoteControl/status/changed`

关键数据结构包括：

- `RemoteControlStatusReadResponse`：`status`、`serverName`、`installationId`、`environmentId`。
- `RemoteControlPairingStartParams`：`manualCode`。
- `RemoteControlPairingStartResponse`：`pairingCode`、`manualPairingCode`、`environmentId`、`expiresAt`。
- `RemoteControlClient`：`clientId`、`displayName`、`deviceType`、`platform`、`osVersion`、`deviceModel`、`appVersion`、`lastSeenAt`。

公开源码 `codex-rs/app-server/tests/suite/v2/remote_control.rs` 覆盖了 status、enable、pairing、pairing status、client list、client revoke 等行为。

### 5. CLI remote-control command 走 daemon/control socket，而不是独立 stdio session

公开源码 `codex-rs/cli/src/remote_control_cmd.rs` 显示：

- `remote-control start` 会调用 `codex_app_server_daemon::ensure_remote_control_ready()`。
- foreground remote-control 会启动一个 Unix socket app-server，并设置 `AppServerRuntimeOptions { remote_control_enabled: true, ... }`。
- 随后通过 `enable_remote_control_on_socket(...)` 连接 socket，发送 `remoteControl/enable`，并等待 `remoteControl/status/changed`。

`codex-rs/app-server-daemon/src/remote_control_client.rs` 进一步显示 daemon client 会：

1. WebSocket 连接 control socket。
2. 发送 `initialize`，并启用 `experimentalApi` capability。
3. 发送 `initialized` notification。
4. 发送 `remoteControl/enable` request。
5. 等待 `remoteControl/enable` response 或后续 `remoteControl/status/changed` notification。

这说明官方 CLI remote-control path 使用的是 app-server daemon/control socket 的 live control plane。

### 6. remote control 要求 ChatGPT auth，不支持 API key auth

公开源码 `codex-rs/app-server-transport/src/transport/remote_control/auth.rs` 显示：

- remote control 需要 ChatGPT authentication。
- API key auth 不支持 remote control。
- auth 通过 `AuthManager` 和 `SharedAuthProvider` 加载，不需要 CodexPort 自己读取或复制 token。

`codex-rs/app-server-transport/src/transport/remote_control/enroll.rs` 显示 pairing/enrollment 使用官方 backend endpoint 和 bearer auth，由 app-server 自己完成：

- server enroll
- server refresh
- server pair
- pair status

CodexPort 不应读取、打印、缓存或转发这些 auth token。

### 7. remote-control backend protocol 支持多 client/stream，不要求 Relay 解析 JSON-RPC 明文

公开源码 `codex-rs/app-server-transport/src/transport/remote_control/protocol.rs` 和 `websocket.rs` 显示 remote-control transport 内部有：

- `ClientEnvelope`
- `ServerEnvelope`
- `ClientId`
- `StreamId`
- `seq_id`
- `cursor`
- `Ack`
- `ClientMessageChunk`
- `ServerMessageChunk`
- 分段大小限制和重组逻辑

这符合 `Opaque Relay Stream` 的方向：若 CodexPort 接入官方 remote-control transport，应尽量做授权入口和 byte/protocol forwarding，不应在 Relay Service 中解析 turn/item JSON-RPC 明文并重建同步状态。

### 8. Desktop Codex App 与 app-server daemon/control socket 有明显关联，但本次未证明同一个 UI live store

本机非侵入观测到：

- `/Applications/Codex.app/Contents/MacOS/Codex` 正在运行。
- 它有子进程 `/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled`。
- 该 app-server 进程打开了 `~/.codex` 下的 sqlite state/log files 和 session rollout JSONL。
- 本机存在并运行 `~/.codex/app-server-control/app-server-control.sock` daemon。
- 同时也存在多个独立 `codex app-server --listen stdio://` 子进程，用于当前 Codex Desktop 内不同会话/工具执行上下文。

这些证据说明 Desktop App、daemon/control socket、per-session stdio app-server 之间存在共享本地状态和控制面关系，但本次调研没有做 UI 自动化或手机真机实验，不能把“Desktop UI live store 一定由同一个 remote-control connection 驱动”标为已证明。

### 9. Historical: `codex` CLI live path 与 Desktop App 同步假设

2026-06-14 #80 supersedes this section for product gating. 用户补充实验曾改变本报告的产品判断：另一台 iMac 通过 SSH 登录本机后运行 `codex` CLI，消息会同步显示到本机 Mac Codex Desktop 打开的同一会话。#80 后续 HITL 证明 Desktop open-session live update 不成立；Desktop 退出重进后可通过 persisted history 看到更新。

本节现在只作为历史观察记录。当前仍成立的结论是：至少存在一条稳定、用户态、无需 Desktop UI private schema 的 TUI-compatible 同步路径：

- 远端设备通过 SSH 进入 Mac 用户环境。
- 在 Mac 上运行真实 `codex` CLI。
- `codex` CLI 使用官方 Codex 会话/同步机制。
- Compatible producer 可让已打开 Codex TUI 实时看到同一 thread 的 turn。

这条路径和前面失败的 Desktop UI probe 不是同一个命题：

- Desktop UI probe 只证明：外部 client 连接 standalone `~/.codex/app-server-control/app-server-control.sock` 并执行 `thread/name/set`，不会让当前 Desktop UI live 更新。
- #80 HITL 证明：compatible producer 可以和已打开 Codex TUI 同步；Desktop open-session live update 不作为 gate。

因此，不能把 standalone daemon control socket 的失败外推为“没有 Desktop 同步入口”。更准确的结论是：

- `codex app-server --listen stdio://`：当前 Direct SSH path 使用的独立 app-server，不满足 TUI live sync。
- standalone daemon control socket：多客户端 broadcast 成立，#80 进一步证明 compatible producer 可驱动 TUI live update。
- `codex` CLI/TUI public protocol：是 Relay v2 更稳健的候选入口。

## Experiments

### Experiment 1: 当前 Direct SSH path 代码核对

步骤：

1. 阅读 `Sources/CodexPortCore/AppServerSession.swift`。
2. 阅读 `Sources/CodexPortCore/JSONRPCCodec.swift`。
3. 对照 `docs/adr/0001-ssh-driver-dependency.md`。

结果：

- 当前实现执行独立 `codex app-server --listen stdio://`。
- 该 path 按设计避开 daemon/control socket。

结论：

- Direct SSH path 不满足 `Real-time Multi-Device Sync`。

### Experiment 2: CLI help 与 daemon 状态

步骤：

1. 运行 `codex --version`。
2. 运行 `codex app-server --help`。
3. 运行 `codex app-server daemon --help`。
4. 运行 `codex app-server proxy --help`。
5. 运行 `codex app-server daemon version`。

结果：

- CLI 版本：`codex-cli 0.137.0`。
- daemon/control socket/proxy 是公开 CLI surface。
- 本机 daemon 正在运行，CLI 和 app-server 版本均为 `0.137.0`。
- control socket path 为 `~/.codex/app-server-control/app-server-control.sock`。

结论：

- 存在稳定候选入口，且不是 Desktop binary 私有入口。

### Experiment 3: protocol schema/TypeScript 生成

步骤：

```bash
rm -rf .scratch/research/app-schema .scratch/research/app-ts
mkdir -p .scratch/research/app-schema .scratch/research/app-ts
codex app-server generate-json-schema --experimental --out .scratch/research/app-schema
codex app-server generate-ts --experimental --out .scratch/research/app-ts
```

结果：

- 生成 schema/TS 包含 `remoteControl/*` methods 和 `remoteControl/status/changed` notification。
- 生成内容与 `openai/codex` 公开源码一致。

结论：

- remote-control 不是仅靠日志或二进制观测猜测出来的接口；它有当前 CLI 可生成的 protocol contract。

### Experiment 4: `codex app-server proxy` newline JSON 直连尝试

步骤：

1. 通过 `codex app-server proxy` 写入 newline JSON-RPC：
   - `initialize`
   - `initialized`
   - `remoteControl/status/read`

结果：

- proxy 返回 `failed to relay data between stdio and socket` / `Broken pipe`。

结论：

- 此尝试失败。
- 后续源码确认 control socket 是 WebSocket-over-UDS，因此失败原因是 transport/framing 用法不匹配，不能据此判断 remote-control 不可用。

### Experiment 5: WebSocket-over-UDS 只读 `remoteControl/status/read`

步骤：

1. 使用当前用户权限连接 `~/.codex/app-server-control/app-server-control.sock`。
2. 对 Unix socket 执行 WebSocket upgrade。
3. 发送 JSON-RPC `initialize`，capability 设置 `experimentalApi: true`。
4. 发送 `initialized` notification。
5. 发送 `remoteControl/status/read`。
6. 对 `installationId`、`environmentId` 打码后记录 shape。

结果：

```json
{"id":1,"result":{"userAgent":"codex-tui/0.137.0 (... redacted ...)","codexHome":"~/.codex","platformFamily":"unix","platformOs":"macos"}}
{"method":"remoteControl/status/changed","params":{"status":"disabled","serverName":"...","installationId":"<redacted>","environmentId":"<redacted>"}}
{"id":2,"result":{"status":"disabled","serverName":"...","installationId":"<redacted>","environmentId":"<redacted>"}}
```

结论：

- control socket 可由当前 macOS 用户授权边界内的本地 client 连接。
- `remoteControl/status/read` 可用。
- app-server 会主动推送 `remoteControl/status/changed` notification。
- 本次没有调用 `remoteControl/enable` 或 `remoteControl/pairing/start`，避免产生 pairing code 或触发用户账号侧 remote-control 状态变化。

### Experiment 6: 官方 docs 访问尝试

步骤：

1. 运行 `openai-docs` Codex manual helper。
2. Shell 直接访问 OpenAI Codex docs 页面。

结果：

- `https://developers.openai.com/codex/codex-manual.md` 返回 HTTP 403。
- `https://developers.openai.com/codex/remote-connections` 返回 HTTP 403。
- `https://developers.openai.com/codex/app-server` 返回 HTTP 403。

结论：

- 本次无法从当前环境读取官方网页正文。
- 不把这些网页内容作为结论依据。
- 仍然保留它们作为后续人工验证来源。

### Experiment 7: 同一 control socket 上的 A/B 多客户端 live broadcast

步骤：

1. 启动两个独立本地 client：`codex-port-sync-exp-A2` 和 `codex-port-sync-exp-B2`。
2. 两个 client 都连接同一个 `~/.codex/app-server-control/app-server-control.sock`。
3. 两个 client 都执行 WebSocket upgrade、`initialize`、`initialized`。
4. 选择一个已 materialized 且原本有 name 的真实 thread，避免 ephemeral thread 无 rollout 导致第二 client 不能 `thread/resume`。
5. client B 执行 `thread/resume` 订阅该 thread。
6. client A 执行 `thread/name/set`，设置临时 name。
7. 验证 client B 是否实时收到 `thread/name/updated`。
8. client B 执行 `thread/name/set`，设置另一个临时 name。
9. 验证 client A 是否实时收到 `thread/name/updated`。
10. client A 将 thread name 恢复为原始值。

结果：

```json
{
  "ok": true,
  "threadIdPrefix": "019e96ac",
  "originalName": "重建 CONTEXT.md",
  "targetThreadPathPresent": true,
  "bReceivedAUpdate": true,
  "aReceivedBUpdate": true,
  "finalNameRestored": true,
  "observedMethods": {
    "A": ["thread/goal/cleared", "thread/name/updated", "thread/status/changed"],
    "B": ["mcpServer/startupStatus/updated", "thread/goal/cleared", "thread/name/updated", "thread/status/changed", "thread/tokenUsage/updated"]
  }
}
```

副作用：

- 第一次实验曾选中一个原本 `name: null` 的 materialized thread；`thread/name/set` 不接受空 name，`thread/metadata/update` 也不支持清空 name，因此该 thread 被恢复为中性标题 `CodexPort sync experiment restored`，无法通过公开 app-server API 恢复为 `null`。
- 第二次实验改用原本有 name 的 thread，结束时成功恢复原名。

结论：

- 同一个 app-server control socket 上，多客户端 live broadcast 成立。
- `thread/name/set` 产生的 `thread/name/updated` 会实时广播给其他已初始化/订阅 client。
- 这证明“同一 app-server live source 对多个 client 实时同步”的基础能力存在。
- 这还不能证明 Mac Desktop Codex App UI 也订阅同一个 standalone daemon live source。

### Experiment 8: Desktop App UI live probe

步骤：

1. 激活 Mac Desktop Codex App。
2. 确认当前窗口打开的 thread 标题为 `重建 CONTEXT.md`。
3. 通过外部 WebSocket-over-UDS client 连接 `~/.codex/app-server-control/app-server-control.sock`。
4. 对当前打开的同一 thread 执行 `thread/name/set`，设置唯一 probe name：`UI-PROBE-<timestamp>`。
5. 等待约 3 秒，截屏观察 Desktop App 窗口标题和左侧选中 thread 标题。
6. 通过同一 control socket 将标题恢复为 `重建 CONTEXT.md`。
7. 再次截屏确认恢复。

结果：

- 外部 control-socket request 成功返回，随后恢复 request 也成功返回。
- 设置 probe 后的 Desktop 截图中，窗口标题和左侧选中 thread 仍显示 `重建 CONTEXT.md`，没有显示 `UI-PROBE-<timestamp>`。
- 恢复后截图仍显示 `重建 CONTEXT.md`。

结论：

- standalone daemon control socket 的多客户端 live broadcast 与当前 Desktop App UI live store 不是同一个已验证 live source。
- 至少在本机当前 Codex Desktop 会话中，外部 client 对 daemon control socket 的 `thread/name/set` 没有让已打开的 Desktop UI 实时更新。
- Desktop App 与 standalone daemon 共享部分 persisted state，但 persisted state update 不等于 Desktop live UI sync。

### Experiment 9: Historical SSH `codex` CLI 与 Desktop App 同步观察

步骤：

1. 在另一台 iMac 上通过 SSH 登录本机。
2. 在 SSH session 中运行 `codex` CLI。
3. 使用会话 `019ea4d7-6c12-7132-8fad-4cd2028309ba`。
4. 在 CLI 侧发送消息。
5. 观察本机 Mac Codex Desktop 打开的同一会话。
6. 本机侧核对 `.codex/sessions/2026/06/08/` 下存在对应 `originator: codex-tui` rollout 记录。

结果：

- 用户当时观察到：SSH CLI 侧消息和 Mac Codex Desktop 同步显示。#80 后续 HITL 已修正产品解释：Desktop open-session live update 不可靠，Desktop 只作为 persisted-history reload viewer。
- 本机存在对应 CLI rollout 记录，说明该会话来自真实 `codex` TUI/CLI path，而不是 CodexPort 当前 Direct SSH 的独立 `codex app-server --listen stdio://` path。

结论：

- 即使没有 Desktop App UI schema 或私有接口，也可以通过 compatible live producer 接入官方 CLI/TUI 同步机制。
- Relay v2 的主候选方案应从 standalone app-server/control socket 转向 `Codex CLI Live Adapter`。
- 仍需在实现层补做 iPhoneA + iPhoneB + Codex TUI 三端 fan-out/serialized input 验证；“缺 Desktop 私有接口”不再是 blocker。

## Pass/fail against criteria

### 1. 发现入口

Status: **Pass, with entrypoint split**。

发现了三类入口，必须区分使用：

- `codex` CLI/TUI public protocol：已由 #80 HITL 证明 compatible producer 可驱动 Codex TUI live update，优先作为 Relay v2 live adapter 入口。
- `~/.codex/app-server-control/app-server-control.sock`：WebSocket-over-UDS local control plane，可连接、可收 notification、同一 app-server A/B clients 可 broadcast，但未证明是 Desktop UI live source。
- `codex app-server --listen stdio://`：独立 app-server transport，当前 Direct SSH path 使用它，不满足 Desktop live sync。

结论：

- 可行入口不是 Desktop binary 私有接口，而是用户态 `codex` CLI。
- daemon/control socket 可继续作为 research/diagnostic surface，但不应直接升级为默认 Relay v2 live source。

### 2. 授权边界可控

Status: **Pass for CLI-backed local user access; pending product auth UX**。

证据：

- SSH CLI 实验使用本机 macOS 用户环境和真实 `codex` CLI，不要求 CodexPort 读取 Desktop UI 私有状态。
- control socket 权限为 `0600`，仅当前 macOS 用户可访问。
- remote-control auth 由 app-server 的 `AuthManager` 和 `SharedAuthProvider` 处理。
- remote control 明确要求 ChatGPT auth，不支持 API key auth。
- CodexPort 不需要读取、打印、复制或提交 token/cookie/API key。

产品上仍需定义：

- Host Agent 如何向用户解释“使用本机 `codex` CLI / Codex Desktop 已登录的 ChatGPT auth”。
- Host Agent 是通过 SSH session、launchd agent、还是本地 helper process 管理 CLI lifecycle。
- 如果后续仍使用 `remoteControl/enable` / `remoteControl/pairing/start`，何时触发、如何展示 pairing code，且不记录 pairing secret。

### 3. 实时双向同步验证

Status: **Pass for TUI live sync after #80; Desktop live sync superseded**。

已验证通过的部分：

- 两个独立本地 clients 连接同一个 standalone app-server control socket。
- client A 改名，client B 实时收到 `thread/name/updated`。
- client B 改名，client A 实时收到 `thread/name/updated`。
- #80 HITL：外部 compatible producer 经 app-server control socket 对同一 thread 写入后，已打开 Codex TUI 实时显示 user turn、assistant delta/final 和 `turn/completed`。

仍需收窄的部分：

- Mac Desktop Codex App 打开同一个 thread 时，#80 写入没有让 Desktop UI 实时显示；退出重进后才通过 persisted history 可见。
- 因此不能把 Desktop open-session UI 当作 `Shared Live Session Source` 或 live-sync gate。
- Relay 实现仍需自动化验证 TUI -> phone、phoneA -> phoneB、phoneB -> phoneA 的完整 fan-out。

结论：

- app-server 具备多客户端 live sync 能力。
- compatible live producer 满足“无需 Desktop 私有接口即可和 Codex TUI 同步”的关键产品目标，应作为 Relay v2 默认候选。

### 4. 多客户端验证

Status: **Partial pass, product path unblocked**。

通过：

- 两个本地 clients 同连同一个 control socket，可实时互收 `thread/name/updated`。
- 源码显示 remote-control backend protocol 有 `ClientId`、`StreamId`、ack、cursor、分段和 client management，结构上支持多 client/stream。
- #80 证明 compatible producer 可接入 Codex TUI open-session live update。

未通过：

- 未完成 iPhoneA + iPhoneB + Codex TUI 三端真实实验。
- Desktop App UI 在 #80 中未实时反映同一 thread 更新，Desktop 不再作为 live gate。

产品含义：

- 多 iPhone 连接同一台 Mac 时，Host Agent 应优先 multiplex 同一个 CLI-backed live session stream。
- 手机端输入和审批动作必须在 Host Agent 侧 serialized，避免多个 phone 同时向同一 CLI session 写入造成竞态。

### 5. 版本稳定性判断

Status: **Pass for CLI-backed Relay v2 candidate; standalone daemon remains experimental**。

稳定性正向证据：

- `codex` CLI/TUI 是官方公开、用户实际使用的入口；#80 已证明 compatible producer 可以让已打开 Codex TUI 实时更新。
- CLI help 暴露 daemon/proxy/schema generation。
- CLI 可生成 JSON schema 和 TypeScript types。
- remote-control protocol 在 `openai/codex` 官方公开源码中存在。
- tests 覆盖 remote-control status、enable、pairing、client management。
- 本机 CLI 0.137.0 与 daemon app-server 0.137.0 版本一致。

限制：

- `remoteControl/*` 需要 `experimentalApi` capability。
- 官方 docs 页面在当前环境不可读取，不能确认公开文档承诺级别。
- Desktop UI live probe 对 standalone daemon control socket 未通过。

因此：

- CLI-backed path 足以进入 Relay v2 默认候选方案的 PRD/ADR/issue breakdown。
- standalone daemon/control socket 只能进入 experimental/research path，不能被默认当作 Desktop live source。

## Recommendation

2026-06-14 update: 本节中的 “Host Agent 管理真实 `codex` CLI process/PTY” 和 “Desktop live sync gate” 均是历史候选建议，已被 PRD #77 与 #80 HITL 修正。当前 canonical 方案见 `docs/research/codex-cli-live-adapter.md`：HostAgent 实现兼容公开 CLI/TUI live protocol 的 producer，不启动或控制真实 interactive TUI，不解析 TUI screen，也不接入闭源 Desktop private interface。验收目标是已打开 Codex TUI + iPhone live sync。

不要继续把 `Relay Connection` 设计成“Host Agent 启动独立 `codex app-server --listen stdio://` 再由 Relay 转发”的方案。它已经被现有 Direct SSH path 证明无法让已打开 Codex TUI/Desktop 共享同一 live source。

Relay v2 的默认候选方案应改为 `Codex CLI Live Adapter`：

1. Host Agent 在 Mac 用户环境中实现兼容公开 CLI/TUI live protocol 的 producer，而不是启动独立 `codex app-server --listen stdio://`。
2. iOS/Relay 只和 Host Agent 通信；Host Agent 把用户输入、approval action、terminal events 转发给同一个 TUI-compatible live session。
3. 已打开 Codex TUI 的实时同步由 compatible live producer 承担；Codex Desktop 只作为 persisted-history reload viewer，不作为 live gate。
4. 多个 iPhone 连接同一台 Mac、同一会话时，Host Agent 负责 fan-out 同一条 CLI live stream，并 serialized 写入用户输入和审批动作。
5. Relay Service 不解析或重放 Codex turn/item JSON-RPC 明文，只做授权、连接编排和 opaque stream forwarding。

standalone daemon/control socket 继续保留为 research path：

1. 可用于读取 `remoteControl/status/read`、验证 protocol shape、做 same-app-server A/B broadcast 实验。
2. 不直接作为默认 Relay v2 live source。
3. 只有当外部 client 对该 live source 的更新能让已打开 Codex TUI 实时变化，才可重新评估它是否能升级为 `Shared Live Session Source`。

Desktop App private interface path 不作为推荐方案：

1. 不需要 Desktop UI schema、binary patch、process injection 或私有 renderer IPC 才能推进。
2. 官方开源 `codex` CLI/TUI 已经足够作为可验证的同步入口。
3. 后续若分析 Desktop/CLI 同步机制，只能服务于 persisted-history recovery 或用户解释，不作为 Relay v2 的前置 blocker。

Recommendation gate：

- `Codex CLI Live Adapter` 可以进入 Relay v2 PRD/ADR/issue breakdown。
- 第一版实现必须包含 Codex TUI + iPhoneA + iPhoneB 三端验证：任一端发送消息，其余端实时显示。
- standalone daemon/control socket 不作为默认方案的 gate；它的失败只限制 daemon path，不否定 CLI-backed path。

## Do not use

- 不要把 `codex app-server --listen stdio://` 当成 `Relay Connection` 的 live-sync 基础。
- 不要把 standalone daemon control socket 的 Desktop UI probe 失败外推为 `codex` CLI path 不可行。
- 不要把 standalone daemon/control socket 直接当成默认 Relay v2 live source。
- 不要在 Relay Service 中解析或重放 Codex JSON-RPC 明文来伪造多端同步。
- 不要读取、打印、复制、提交或转储 ChatGPT tokens、cookies、API keys、pairing code、remote-control server token。
- 不要依赖 Desktop binary patch、process injection、反编译或私有内存结构。
- 不要把 `codex app-server proxy` 当作普通 newline JSON socket；control socket 是 WebSocket-over-UDS。
- 不要在未完成 Codex TUI + iPhoneA + iPhoneB 端到端验证前，对外宣称 Relay Connection 已复刻官方 remote connection 的完整实时同步体验。
