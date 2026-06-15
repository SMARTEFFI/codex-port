# Issue #41 三端 gated verification 报告

日期：2026-06-08

## 结论

Pass，#41 可以关闭。

2026-06-14 #80 correction:

本报告中的 Mac Codex Desktop live-sync 判定基于当时的用户外部观察。#80 后续 HITL 已修正该假设：Codex TUI 可以被 compatible producer 实时更新；Codex Desktop 打开同一 thread 时不会实时更新，退出重进后才通过 persisted history 看到新 turn。因此本报告仍可作为 #41 当时 local WebSocket / 双 iOS simulator / `codex-exec-json` fan-out 的历史验证记录，但不再作为 Desktop live-sync gate 证据。当前 live-sync gate 以 Codex TUI + iPhone 为准。

本轮把 #41 的最后失败面从“真实 `codex-exec-json` WebSocket backend 只完成 101 upgrade，但 business event 没有回到 iOS UI”推进到可验证通过：

- `codexport-host-agent --local-relay-websocket` 在非交互 shell 中不再依赖 stdin 保活；stdin EOF 后仍常驻，直到 SIGINT/SIGTERM。
- `RelayEndpointJSONLCodec` 会把 `RelayWriteStatus.failed(reason:)` 的 reason 在线路上 round-trip，端侧不再只能看到空 failed。
- `RelayWebSocketLineStreamServer` 会等待 upgraded connection tasks 收尾后再 shutdown event loop，避免测试中出现 SwiftNIO shutdown 后调度警告。
- 真实 `CODEXPORT_HOST_AGENT_BACKEND=codex-exec-json` + 本地 WebSocket Host Agent runtime 已完成双 iOS simulator 双向 smoke：
  - iPhoneA 发起后，iPhoneA 和 iPhoneB 均显示真实 `codex exec --json` assistant output。
  - iPhoneB 发起后，iPhoneB 和 iPhoneA 均显示真实 `codex exec --json` assistant output。
  - 短 timeout 场景下，iPhoneA 和 iPhoneB 均显示 `Codex CLI exec timed out.` failed status。
- WebSocket integration tests 覆盖真实 URLSession WebSocket client -> SwiftNIO listener -> gateway -> Host Agent local service -> iOS `SessionStore` 的 success fan-out、timeout failed fan-out 和 interrupt handled fan-out。
- Mac Codex Desktop 同步方向曾采用用户提供的真实外部实验作为证据。2026-06-14 #80 已修正该解释：Desktop open-session live update 不作为 gate；当前只保留这条历史观察，新的 live-sync gate 以 Codex TUI 为准。

当前通过范围是 #41 要求的 AFK/local gated verification：Mac 上运行 Host Agent local WebSocket path，两个真实 iOS simulator instances 连接同一 Host Agent session，真实 `codex exec --json` backend 的 output/failure/handled 状态可跨 iOS 端同步。公网 Relay deployment、Host Agent outbound Relay connection、E2EE stream handshake 和独立 Mac Desktop UI 截图仍属于后续 production hardening，不作为 #41 关闭条件。

## 自动化步骤与证据

### 1. Focused TDD 回归

命令：

```sh
swift test --filter 'RelayEndpointJSONLCodec|relayWebSocketTransportPropagatesCodexExecTimeoutFailureToIOSStore|relayWebSocketTransportFansOutCodexExecSuccessAcrossTwoIOSStores|relayWebSocketTransportFansOutCodexExecInterruptHandledAcrossTwoIOSStores|localRelayWebSocketExecutableStaysAliveWhenStandardInputCloses'
```

结果：

```text
7 tests passed
```

覆盖：

- failed write status reason round-trip。
- `codex-exec-json` timeout 通过 WebSocket fan-out 到 iOS `SessionStore` 和 transcript failed row。
- 两个真实 WebSocket clients 连接同一个 Host Agent local service，iPhoneB 发起的 successful `codex-exec-json` output fan-out 到 iPhoneA 和 iPhoneB。
- interrupt handled status 通过 WebSocket fan-out 到两个 iOS stores。
- `codexport-host-agent --local-relay-websocket` 在 stdin 为 `/dev/null` 时仍保持运行。

### 2. 全量测试与构建

命令：

```sh
swift test
swift build --product codexport-host-agent
xcodebuild -quiet -project CodexPort.xcodeproj -scheme CodexPort -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/DerivedData-CodexPort-Issue41-Final build
```

结果：

```text
swift test: 184 tests passed
swift build --product codexport-host-agent: passed
iOS simulator build: passed
```

### 3. 真实 backend WebSocket timeout smoke

Host Agent 启动摘要：

```sh
CODEXPORT_HOST_AGENT_BACKEND=codex-exec-json
CODEXPORT_HOST_AGENT_COMMAND=/Users/chenm/.local/bin/codex
CODEXPORT_CODEX_EXEC_ARGUMENTS_JSON='["--skip-git-repo-check","--dangerously-bypass-approvals-and-sandbox","--json"]'
CODEXPORT_CODEX_EXEC_RESUME_ARGUMENTS_JSON='["--skip-git-repo-check","--dangerously-bypass-approvals-and-sandbox","--json"]'
CODEXPORT_CODEX_EXEC_TIMEOUT_SECONDS=6
CODEXPORT_RELAY_DEVICES_JSON='[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"iPhone A"},{"id":"BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF","name":"iPhone B"}]'
.build/debug/codexport-host-agent --local-relay-websocket --port 0
```

结果摘要：

- Host Agent 输出本地 `ws://127.0.0.1:<port>/v0/streams` endpoint 和两条 non-secret Pairing Record。
- iPhoneA 通过 launch seed/autoconnect/autoprompt 发送 redacted test payload。
- iPhoneA 截图显示 user bubble 和 `会话失败：Codex CLI exec timed out.`。
- iPhoneB 同连同一 Host Agent session，截图显示同一个 failed status。
- 清理后无遗留 `codex exec`、`codexport-host-agent --local-relay` 或 `CodexPort.app` 进程。

### 4. 真实 backend WebSocket A -> B smoke

Host Agent 使用真实 `codex-exec-json` backend，timeout 60 秒。iPhoneB 先作为观察端连接同一 endpoint，iPhoneA 再通过 launch autoprompt 发起 redacted request。

结果摘要：

- iPhoneA 显示本端 user bubble 和真实 `codex exec --json` assistant output。
- iPhoneB 显示同一条真实 assistant output。
- `pgrep` 在 25 秒后只看到 Host Agent 和两个 app 进程，无残留 `codex exec` 子进程。
- redacted 截图：
  - `/tmp/issue41-codexexec-websocket-atoa-iphone-a-redacted.png`
  - `/tmp/issue41-codexexec-websocket-atoa-iphone-b-redacted.png`

### 5. 真实 backend WebSocket B -> A smoke

Host Agent 使用新的本地 endpoint 和真实 `codex-exec-json` backend，timeout 60 秒。iPhoneA 先作为观察端连接并确认停在 Relay session 页，iPhoneB 再通过 launch autoprompt 发起 redacted request。

结果摘要：

- iPhoneB 显示本端 user bubble 和真实 `codex exec --json` assistant output。
- iPhoneA 显示同一条真实 assistant output。
- 清理后无遗留 Host Agent、`codex exec` 或 simulator app 进程。
- redacted 截图：
  - `/tmp/issue41-codexexec-websocket-btoa-iphone-a-redacted.png`
  - `/tmp/issue41-codexexec-websocket-btoa-iphone-b-redacted.png`

### 6. Mac Desktop/CLI 同步方向

证据来源：

- 用户提供的真实外部实验：会话 `019ea4d7-6c12-7132-8fad-4cd2028309ba`，另一台 iMac 通过 SSH 登录本机运行真实 `codex` CLI，消息和本机 Mac Codex Desktop 打开的同一会话同步显示。#80 后续 HITL 已修正：Desktop open-session live update 不作为 gate。
- `docs/research/codex-app-control-plane.md` 已记录该实验，并在 #80 correction 后把 `Codex CLI Live Adapter` 收窄为 Codex TUI live-sync 候选入口。

判定：

- #41 的 Mac Desktop 侧同步判定是历史判定，已被 #80 superseded。
- 当前工具环境仍没有可直接操控或截图 Mac Codex Desktop UI 的桌面控制能力，因此本报告不伪造 Desktop UI 截图。

## Acceptance Criteria 状态

| Criteria | 状态 | 说明 |
| --- | --- | --- |
| 验证环境包含 Mac Codex Desktop、两个 iOS client instances 和运行中的 Host Agent/Relay path | Historical pass; Desktop gate superseded by #80 | Mac 运行真实 `codexport-host-agent --local-relay-websocket`；两个真实 iOS simulator instances 连接同一 Host Agent local WebSocket session；Desktop live-sync 证据不再作为当前 gate。 |
| iPhoneA 发送消息后，iPhoneB 和 Mac Codex Desktop 实时显示 | Historical pass for iPhone fan-out; Desktop gate superseded by #80 | iPhoneA -> Host Agent true `codex-exec-json` WebSocket -> iPhoneB 已截图验证；Desktop 方向不再作为当前 gate。 |
| iPhoneB 发送消息后，iPhoneA 和 Mac Codex Desktop 实时显示 | Historical pass for iPhone fan-out; Desktop gate superseded by #80 | iPhoneB -> Host Agent true `codex-exec-json` WebSocket -> iPhoneA 已截图验证；Desktop 方向不再作为当前 gate。 |
| Mac Codex Desktop 侧产生可观察会话更新后，iPhoneA 和 iPhoneB 实时显示或记录 sync direction 限制 | Superseded by #80 | #80 证明当前 live-sync gate 应为 Codex TUI，而非 Desktop open-session UI。 |
| approval/interrupt 至少验证一种跨设备 handled/interrupted 状态同步 | Pass | `relayWebSocketTransportFansOutCodexExecInterruptHandledAcrossTwoIOSStores` 覆盖真实 WebSocket 双 client interrupt handled fan-out；旧 Host Agent local service integration 也覆盖 interrupt handled。 |
| 验证产物包含自动化步骤、截图或日志摘要、失败重试记录和最终 pass/fail 结论；不得包含 secrets、tokens、prompt 明文或 credential values | Pass | 本报告包含命令、测试结果、redacted screenshot paths、失败重试记录和最终 Pass 结论；未读取 credentials，未包含 token/secret；测试 payload 和截图已 redacted。 |

## 失败重试记录

1. 早期 Host Agent executable 只输出 manifest，无法作为 #41 runtime；已补 `--local-relay-jsonl` 和 `--local-relay-websocket` local runtime。
2. 早期 iOS Relay Host 只是 profile/model；已补 `RelaySessionRouteBuilder`、`RelayWebSocketJSONLTransport`、AFK launch seed/autoconnect/autoprompt 和 `SessionDetailView` Relay route。
3. 早期 WebSocket listener 只覆盖 fixture backend；已补真实 `codex-exec-json` backend timeout/success/interrupt WebSocket integration。
4. 真实 backend 首次 WebSocket smoke 暴露 repeated `item_0` 合并；已改 `SessionStore` 使用 `turnID:itemID` 索引。
5. 真实 backend 后续 smoke 暴露 `codex exec` 子进程可能挂住；已补 `CODEXPORT_CODEX_EXEC_TIMEOUT_SECONDS` 和 timeout failed fan-out。
6. 短 timeout smoke 暴露 failed reason 只停留在 internal state 或空 write status；已补 transcript failed row 和 endpoint JSONL failed reason round-trip。
7. 非 PTY/AFK 启动暴露 `--local-relay-websocket` 因 stdin EOF 退出；已改为等待 SIGINT/SIGTERM，并补 executable lifecycle integration test。
8. Focused WebSocket tests 暴露 SwiftNIO event loop shutdown 后调度警告；已让 `RelayWebSocketLineStreamServer.stop()` 等待 upgraded connection tasks 收尾。
9. B -> A simulator smoke 中第一次抓到 A 在 SpringBoard，不能作为 UI 证据；重跑时先确认 A 停在 Relay session 页，再启动 B 发起，最终 A/B 截图均通过。

## 不含敏感信息说明

本报告未读取、打印、复制或总结 credential files。未包含 API key、SSH credential、Codex token、ChatGPT token、Pairing Token 或 credential values。

截图和文档中的 prompt/test payload 均已 redacted。日志摘要只保留 endpoint shape、状态、测试结果和进程清理结果。

## 后续非 #41 范围

以下仍是后续 production hardening，不阻塞 #41 关闭：

1. 公网 `CodexPort Relay` deployment。
2. Host Agent outbound Relay connection 和 production routing。
3. Endpoint key / E2EE stream handshake。
4. Mac Desktop UI 直接 AFK 操控/截图能力。
5. 更完整的 approval request lifecycle，而不只是 interrupt handled 状态。
