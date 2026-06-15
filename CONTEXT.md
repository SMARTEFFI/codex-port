# Codex Port Context

本文件记录 `codex-port` 的领域语言、当前架构决策和后续 agent 需要遵守的边界。它以当前代码和 `docs/adr/` 为准；`docs/prd/` 提供产品背景，但其中部分早期连接链路已被 ADR 更新。

## Project summary

`Codex Port` 是一个 iPhone-first 的原生 iOS Codex 客户端。它通过 SSH 连接用户自己的 Mac、VPS 或 Linux host，在远端启动已有 Codex CLI 的 app-server，并用 SwiftUI 界面驱动结构化 JSON-RPC protocol。

核心目标不是实现 SSH terminal，也不是复刻 ChatGPT 通用 App，而是让手机端用原生体验访问远端已有 `~/.codex` state、project filesystem、Codex CLI 配置和第三方 API 设置。

## Current architecture

当前 `0.1.x` Direct SSH baseline 由两个主要区域组成：

- `Sources/CodexPortCore/`：核心 domain、protocol、transport、state 和测试友好的业务边界。
- `CodexPortApp/`：SwiftUI iOS app，负责导航、表单、连接日志、workspace/session UI、附件入口和诊断 UI。

`0.2.x` Relay/Host Agent 阶段把仓库扩展为两个用户面对的 product projects：

- iOS Client project：继续承载 iPhone-first CodexPort app，并通过 shared modules 引用 Relay domain/protocol contracts。
- macOS `CodexPort Host Agent` project：新增 Mac 常驻工具 product，以当前 macOS 用户身份运行，后续负责 Pairing、Relay presence、CLI live session lifecycle、multi-phone fan-out、serialized input 和 no-secret diagnostics。

当前 SwiftPM shared/product 边界：

- `CodexPortCore`：现有 Direct SSH client core，继续服务 iOS Client。
- `CodexPortShared`：`Connection Method`、`Relay Host`、`Device Identity`、`Pairing`、Relay protocol contracts 和 diagnostics contracts。
- `CodexPortHostAgentCore`：Host Agent domain/lifecycle core，依赖 `CodexPortShared`，不依赖 iOS SwiftUI app types。
- `CodexPortRelayCore`：Relay service-side pairing/authenticated stream gateway boundary，依赖 `CodexPortShared` 和 SwiftNIO network primitives，负责 decoding shared stream-open contracts、Pairing Record gate、local WebSocket line stream listener 和 stream telemetry；它不是第三个用户面对 app project，也不能解析 Codex payload 明文。
- `codexport-host-agent`：macOS Host Agent executable，依赖 `CodexPortHostAgentCore` 和 `CodexPortRelayCore`。默认输出 manifest；`--local-relay-jsonl` 启动 stdin/stdout JSONL runtime；`--local-relay-websocket --port <port>` 启动本地 WebSocket relay runtime，用于 AFK/local verification。WebSocket runtime 不依赖 stdin 保活，非交互 shell 中 stdin EOF 后仍会常驻直到 SIGINT/SIGTERM。默认 backend 是 #80 验证过的 `codex-cli-live` / `CodexAppServerControlSocketLiveProducer`，通过 `~/.codex/app-server-control/app-server-control.sock` 的公开 app-server control protocol 写入已打开 Codex TUI live session。显式设置 `CODEXPORT_HOST_AGENT_BACKEND=codex-exec-json` 后，runtime 才会用旧的 `codex exec --json` / `codex exec resume --json` one-shot backend；该 backend 只能作为 persisted-history recovery、fallback 或本地 smoke，不作为 TUI live-sync gate。`CODEXPORT_CODEX_EXEC_TIMEOUT_SECONDS` 可配置真实 `codex exec` 子进程超时，默认 120 秒；超时会终止子进程并 fan-out `turnFailed` / failed write status，failed reason 会通过 endpoint JSONL status/event 传回 iOS。

iOS app 支持仅用于 AFK/local verification 的非 secret Relay Host launch seed：`CODEXPORT_IOS_RELAY_*` environment values 可在启动时创建或复用一条 Relay `Host Profile`，从而让 simulator 直接指向本地 `codexport-host-agent --local-relay-websocket` endpoint。`CODEXPORT_IOS_RELAY_AUTOCONNECT=1` 和 `CODEXPORT_IOS_RELAY_AUTOPROMPT` 只用于 simulator smoke，能自动进入 seeded Relay session 并发送验证 prompt。本地验证已覆盖两个 iOS simulator 同连同一个 Host Agent WebSocket endpoint，并用真实 `codex-exec-json` backend 双向 fan-out assistant output / failed status。该 seed 不包含 credential secret，也不能替代真实 Pairing Token、端到端加密 handshake 或 production Relay deployment。

当前连接链路：

```text
SwiftUI App
  -> HostProfile + local CredentialVault
  -> SSHConnectionService
  -> SSHDriver / NIOSSHDriver
  -> remote command: codex app-server --listen stdio://
  -> JSONRPCByteStreamTransport
  -> JSONRPCClient
  -> CodexProtocolFacade
  -> remote Codex app-server
```

连接前预检会运行 `codex --version` 和 `codex app-server --help`。最低兼容基线是 `codex-cli >= 0.133.0`；更高版本允许尝试，但属于 untested newer。

## Accepted decisions

- ADR 0001 已接受：production SSH implementation 使用 Apple `swift-nio-ssh`，并隔离在 `NIOSSHDriver.swift` 后面。
- ADR 0002 已接受：`0.2.x` Relay/Host Agent work 在当前 repo 内采用 iOS Client + macOS `CodexPort Host Agent` 双产品组织，shared Relay contracts 放在 `CodexPortShared`，默认 live-sync 候选是 `Codex CLI Live Adapter`。
- 当前普通连接必须执行 `codex app-server --listen stdio://`。不要把早期 PRD 中的 `codex app-server daemon start && codex app-server proxy` 当作当前实现目标。
- 连接链路刻意避开 `daemon start`、`daemon restart`、`daemon stop` 和 `app-server proxy`，避免一次普通连接尝试修改或依赖共享 app-server daemon/control socket 状态。
- `Relay Connection` 不得复用独立 `codex app-server --listen stdio://` 作为 live-sync 基础。standalone daemon/control socket 可作为 research/diagnostic surface，但不能默认升级为 `Shared Live Session Source`。
- `Codex CLI Live Adapter` 的主线入口是官方 CLI/TUI 使用的公开 app-server live protocol/schema；standalone daemon/control socket 已通过 #80 证明可驱动已打开 Codex TUI live update；`codex exec --json` / `codex exec resume --json` 不再作为 live-sync 候选，只能作为 persisted history recovery、fallback 或测试 fixture。
- HostAgent production runtime 默认选择 `codex-cli-live` / `CodexAppServerControlSocketLiveProducer`，并通过 `CODEXPORT_CODEX_CONTROL_SOCKET_PATH` 指向 `~/.codex/app-server-control/app-server-control.sock` 或等价 socket。该 backend 发送 schema-compatible `initialize`、`thread/resume` 和 `turn/start` payload，并把 app-server live notifications 映射进 `Client-Host Session Protocol`。`CODEXPORT_HOST_AGENT_BACKEND=process-stdio` 和 `CODEXPORT_HOST_AGENT_BACKEND=codex-exec-json` 仅作为显式 fixture/fallback。
- `Codex CLI Live Adapter` tracer bullet 已在 #80 收窄：HostAgent-compatible producer 对同一 thread 的写入能让已打开 Codex TUI 实时显示 user message、assistant delta 和 final assistant message；Codex Desktop 打开同一 session `019ea4d7-6c12-7132-8fad-4cd2028309ba` 时不会实时更新，只在退出重进后通过 persisted history 可见。从官方 Codex TUI 直接发送消息也不会让已打开 Desktop 实时更新。Desktop 不再作为实时同步 gate。
- `Codex CLI Live Adapter` tracer bullet 的第一阶段最小通过标准改为：已经打开的 Codex TUI 同一 thread 在不退出、不重进的情况下实时显示 HostAgent-compatible producer 写入的 user message 和 final assistant message。tool/file/approval live events 属于第二阶段验收。
- 当前 Relay/HostAgent live-sync 实现不是兼容性约束。为满足 `TUI Live Sync`，可以丢弃或重构现有 `codex-exec-json` backend、local relay bridge、HostAgent live adapter 和相关 P2P/Relay glue code；不要为了保留当前实现而降低 live-sync 验收标准。Direct SSH baseline 仍按 ADR 0001 保护，除非另有明确决策。
- `Codex CLI Live Adapter + TUI Live Sync` 应作为 #63 `P2P-first Remote Connection` 的前置 gate。#63 的 WebRTC/DataChannel work 可以在 TUI live-source tracer bullet 通过后恢复为 canonical implementation entry；Desktop live update 不再阻塞 #63。
- Relay protocol 0.2.x 的版本协商以 `RelayProtocolVersion.v0_2_0` 为当前 shared contract baseline。iOS device、Host Agent 和 Relay 必须协商到双方共同支持的最高版本；没有共同版本时返回明确 `incompatibleVersion`，不能静默降级。
- `RelayStreamOpenRequestWebSocketCodec` 属于 shared contract；iOS WebSocket opener 和 Relay service-side gateway 必须复用同一 decoder/encoder，避免 client 和 server handshake drift。
- 当前 production Relay/VPS 实现是 `Relay-mediated JSONL Bridge`，不是 P2P，也不是已完成端到端加密的 `Opaque Relay Stream`。讨论 #55/#61 或 production smoke 时必须按这个当前实现命名。
- 后续远程连接方向已调整为 `P2P-first Remote Connection`：优先让 iOS app 与 `CodexPort Host Agent` 通过 `WebRTC DataChannel Transport` 直连通信，VPS 只承担 signaling、pairing、presence 和 NAT traversal 协商；直连失败时允许 `TURN relay fallback`。当前 `Relay-mediated JSONL Bridge` 的 production 传输路径可整体废弃，但 `CodexPort Host Agent`、`Device Identity`、`Pairing`、`Relay Host` 入口、Mac 侧 Codex live source 选择和 iOS foreground recovery 概念仍可复用。
- `P2P-first Remote Connection` 必须暴露 `Remote Connection Path State`，让 iOS、HostAgent UI 和 diagnostics 区分 signaling、ICE、direct、TURN-relayed、DataChannel、Host protocol 和 Codex live source 各阶段，而不是只显示“HostAgent online”。
- `P2P-first Remote Connection` 可复用当前 JSONL session/list/history/prompt/status/fan-out 语义，但该应用层边界应命名为 `Client-Host Session Protocol`，不能继续把它描述成 Relay transport 本身。
- `P2P-first Remote Connection` 仍保留 `Pairing Record` 和 device revoke 状态。VPS 负责判断某个 `Device Identity` 是否可向某个 `Relay Host` 发起 signaling，但不保存、不解析 `Client-Host Session Protocol` payload。
- `CodexPort Relay` 现在暴露第一版 production P2P signaling HTTP surface：`/v0/p2p/hosts/{hostID}/presence`、`/v0/p2p/hosts/{hostID}/messages`、`/v0/p2p/sessions/open`、`/v0/p2p/sessions/{sessionID}/messages/send` 和 `/v0/p2p/sessions/{sessionID}/messages`。这些 endpoint 复用 `Pairing Record`、presence、revoke 和 version negotiation gate，只转发 WebRTC offer/answer/ICE candidate signaling，不承载 `Client-Host Session Protocol` payload。Host-wide drain 会返回 session metadata，供 HostAgent listener 在不知道新 sessionID 的情况下接收 device offer。
- iOS/Core 侧已有 `RelayConnectionTransportFactory`、`RelayP2PSessionTransportFactory` 和 `RelayDeferredJSONLTransport` seam：production signaling `presence/openSession` 可被包装成现有 `RelayJSONLTransport`，并穿过 `RelaySessionRouteBuilder` / `RelayJSONLSessionClient` 的 session attach path。产品默认 route 已切到 `p2pWebRTCDataChannel`，以支持真机手工启动和 TestFlight path；`CODEXPORT_IOS_RELAY_TRANSPORT_MODE=legacy` / `legacy-websocket-jsonl` 只作为显式 fallback。当前 `UnavailableRelayP2PDataChannelFactory` 只作为 production guard，防止误把测试 fake runtime 接入产品路径。
- HostAgentCore 侧已有 `HostAgentP2PDataChannelEndpoint` 和 `HostAgentP2PSignalingListener` seams：DataChannel endpoint 直接接收 shared `WebRTC DataChannel Transport` 的 newline-delimited JSONL frames，调用 `HostAgentLocalRelayService`，并把 thread list、history、write status 和 live events 写回同一 DataChannel；signaling listener 轮询 host-wide P2P inbox，接收 offer，调用注入的 `HostAgentP2PDataChannelAccepting`，发送 answer/ICE，并启动 endpoint。HostAgent executable 已有显式 `--p2p-listen` mode，HostAgent menu app 可通过 `CODEXPORT_HOST_AGENT_P2P_LISTEN=1` 启用 listener path；`CODEXPORT_WEBRTC_SIDECAR_PATH` / `CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON` 可选择 `HostAgentWebRTCSidecarAcceptor`，通过 JSONL IPC 把 `accept`、`remoteICE`、`dataChannelSend` 发给 Mac Catalyst WebRTC sidecar，并接收 `accepted`、`localICE`、`dataChannelMessage`、`dataChannelState` 和 `error`。`scripts/build-webrtc-sidecar.sh` 会构建 `.scratch/webrtc-sidecar/codexport-webrtc-sidecar`、复制 `WebRTC.framework`、改写相对 rpath 并 ad-hoc 签名；production Relay invalid-offer smoke 已证明 HostAgent 收到 offer 后进入真实 WebRTC SDK SDP parser，而不是旧 `runtimeUnavailable` guard。未配置 sidecar 时仍使用 `HostAgentWebRTCDataChannelAcceptor` 的 platform SDK runtime/unavailable guard。
- Production simulator smoke 证据分三层：`SIM-P2P-LIVE-060405` 已证明 iPhone simulator 经 production Relay signaling、真实 WebRTC DataChannel、HostAgent sidecar 和 control-socket producer 能把 prompt 写入当前 Codex session；第二个 simulator device 也能通过独立 Pairing Record 连接同一 HostAgent、attach 同一 thread 并接收 history/live event output。随后 `SIM-P2P-LIVE-075304` 通过 idle-thread metadata verifier：两个 simulator P2P sessions attach 到同一 thread，两个 client 都收到 `writeStatusChanged status=handled`、`assistantTextDelta` 和 `turnCompleted`。`SIM-P2P-LIVE-082655` 进一步通过 shared HostAgent start helper、run-id scoping、sender/observer role check、shared handled write id 和 shared live turn id。这个修复依赖两个实现事实：真实 control-socket `turn/completed` notification 的 terminal id 可能位于 nested `turn.id`，HostAgent `--p2p-listen` diagnostics 必须用 unbuffered stdout line write，避免 LaunchAgent log 半行导致 verifier 漏读。该结果仍是 simulator rehearsal，不是 #74 close。后续截图又暴露 TUI->iOS 方向缺口：TUI 本地 prompt 只让 iOS 显示 assistant response，缺少 user bubble；现已新增 `RelayLiveSessionEvent.userMessage(turnID:itemID:text:)`，control-socket producer 会映射 `item/started` / `item/completed` 的 Codex `userMessage` item，iOS `SessionStore` 会渲染并去重 optimistic echo。旧 simulator pass 是旧 gate 下的 ingress rehearsal；当前更强 verifier 需要重新看到所有 attached client 收到同一 turn 的 `userMessage`、`assistantTextDelta` 和 `turnCompleted`。
- `zsh scripts/issue74-list-idle-threads.sh` / `codexport-host-agent --list-idle-threads-json` 可输出 metadata-only idle/completed thread 候选，不输出 prompt 或 assistant preview 文本；用户仍需手动把选中的同一 thread 打开在 Codex TUI 后再运行 idle TUI smoke。`zsh scripts/issue74-start-hostagent-p2p.sh` 是 #74 的 shared HostAgent start path：build 当前 `codexport-host-agent` 和 WebRTC sidecar，生成 `.scratch/launchagents/` run-id-scoped LaunchAgent plist，重启 `--p2p-listen`，检查 production Relay P2P host drain，并输出可 `eval` 的 `CODEXPORT_ISSUE74_RUN_ID` / `CODEXPORT_HOSTAGENT_STDOUT` 等变量。`zsh scripts/issue74-idle-tui-sim-smoke.sh` 和 `zsh scripts/issue74-idle-tui-device-smoke.sh` 现在都复用该 helper，强制使用刚 build 的 HostAgent、当前 sidecar、当前 control socket 和 `CODEXPORT_ISSUE74_RUN_ID`；HostAgent `--p2p-listen` metadata 会输出 `run=<id>`，`zsh scripts/issue74-verify-hostagent-log.sh --run-id <id>` 只接受本轮证据，避免旧 simulator 日志污染真机 gate。verifier 还支持 `--sender-client` / `--observer-client` / `--forbid-text`，要求 sender 发出 prompt、observer 不发 prompt、同一个 write id 被所有 client handled、同一个 live turn id 在所有 client 上都有 `userMessage` / `assistantTextDelta` / `turnCompleted`，并在 HostAgent stdout 出现 marker/prompt sentinel 时失败且不回显 forbidden text。`zsh scripts/issue74-readiness-check.sh` 是只读真机前置检查：检查 local tools、Codex control socket、HostAgent/sidecar artifacts、`xctrace`/`devicectl` 两台物理设备状态、active non-synthetic Relay Pairing Records、以及四个真实 iPhone deeplink env，不启动 HostAgent、不安装 app、不打开 URL、不打印 credential values；`--mode manual` 用于 TestFlight/manual path，local device availability 只作为 warning，`--mode local-device` 用于 `devicectl` 本地安装/启动 path，要求两台本地设备可用。`zsh scripts/issue74-export-real-pairing-env.sh` 可从 Relay active non-synthetic Pairing Records 生成四个真实 iPhone env exports，避免手工抄错 device ID / Pairing Record ID；`--list` 只输出 metadata，`--auto-two` 仅在恰好两个真实 records 时可用。`zsh scripts/issue74-idle-tui-device-smoke.sh` 是本地真机 helper：要求两个 UDID 出现在 `xcrun xctrace list devices` 的 `Devices` 而非 `Devices Offline`/`Simulators`，用 `devicectl` 安装/带 JSON environment 启动两台 iPhone，并复用 metadata-only HostAgent log verifier；默认还要求显式传入两台真实 iPhone 的 Relay device ID 和 Pairing Record ID，只有设置 `CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1` 才允许 dev/simulator synthetic identities，且不能作为 #74 close 证据。`zsh scripts/issue74-manual-testflight-smoke.sh` 是 TestFlight/manual wrapper：不依赖 `devicectl`，先校验真实 iPhoneA/iPhoneB Relay identities，打印 iPhoneB observer 与 iPhoneA sender `codexport://verify?...` deeplink，再通过 shared HostAgent helper 启动 run-id-scoped HostAgent 并等待同一个 sender/observer verifier，同时把 marker 作为 `--forbid-text` no-leak gate。当前本机状态是 `xctrace` 已看到一台 physical `min (26.5)` under `Devices`，但第二台真机仍缺；`devicectl list devices` 可运行且至少一台 iPhone `available (paired)`，但仍不足两台；Relay active Pairing Records 仍只有 simulator/smoke identities，所以不能声明 physical HITL pass。iOS app 也注册 `codexport://verify?...` deeplink；`zsh scripts/issue74-list-pairing-records.sh` 可列出 active Pairing Record metadata；`zsh scripts/issue74-make-verify-deeplinks.sh` 为 TestFlight/manual 真机 run 生成 iPhoneB observer 与 iPhoneA sender URL 时同样要求显式传入两台真实 iPhone 的 device ID 和 Pairing Record ID。URL 只包含 host/device/pairing-record/thread/autoprompt metadata，不包含 Pairing Token、Codex token、prompt history 或 assistant output。TURN/STUN production provisioning、物理 iPhoneA + iPhoneB、以及 human-observed idle already-open Codex TUI live update 仍未完成。
- `CodexPortWebRTC` 已提供第一版 platform runtime seam：`WebRTCRuntimeConfiguration` 承载 STUN/TURN ICE servers，`RelayP2PWebRTCSignalingPayloadCodec` 用 JSON payload 编码 SDP offer/answer 与 ICE candidate，`RelayWebRTCDataChannelFactory` 负责 iOS opener 的 offer/local ICE send、answer/remote ICE drain 与 DataChannel 返回，`HostAgentWebRTCDataChannelAcceptor` 负责 HostAgent decode offer、生成 answer/local ICE 并交给 `HostAgentP2PSignalingListener`。`WebRTCSDKRuntime` 已实现 `RTCPeerConnection` / reliable ordered `RTCDataChannel` adapter，并被限制在 `(os(iOS) || targetEnvironment(macCatalyst)) && canImport(WebRTC)`；`DefaultWebRTCPlatformDataChannelRuntime` 在 iOS/Catalyst 链接 `WebRTC` module 时会启用该 runtime，否则继续返回 `UnavailableWebRTCPlatformDataChannelRuntime`。`Package.swift` / `Package.resolved` 当前 pin `stasel/WebRTC` `148.0.0`，因为 `149.0.0` release artifact checksum 与 upstream manifest 不一致，而 `148.0.0`/`147.0.0` 校验一致。`stasel/WebRTC` `148.0.0` 不能直接作为 native macOS HostAgent runtime：native macOS slice 只有 umbrella `WebRTC.h` public header；scratch probe 补齐完整 Mac Catalyst headers 后仍因 headers 引用 `AVAudioSession`、`UIView`、`UIKit/UIKit.h` 等 iOS-only APIs 而无法在 native macOS 编译。因此 HostAgent 仍需要 macOS-compatible WebRTC runtime、sidecar 或其他 adapter，不能简单放开 `WebRTCSDKRuntime` 的 macOS guard。iOS 和 HostAgent P2P paths 已通过 `CODEXPORT_WEBRTC_ICE_SERVERS_JSON` 或 `CODEXPORT_WEBRTC_STUN_URLS` / `CODEXPORT_WEBRTC_TURN_URLS` / `CODEXPORT_WEBRTC_TURN_USERNAME` / `CODEXPORT_WEBRTC_TURN_CREDENTIAL` 读取运行时 ICE 配置，diagnostic description 会 redact TURN credential。iOS opener 和 HostAgent listener 也已支持持续 trickle ICE forwarding，并能把对端后续 ICE candidate 应用到已建立的 DataChannel runtime。当前 focused regression 通过 81 tests；HostAgent real WebRTC runtime、TURN credential provisioning source 和 TUI + iPhoneA + iPhoneB HITL 仍未完成。
- `P2P-first Remote Connection` 第一版安全边界依赖 `WebRTC DataChannel Transport` 的 transport encryption、pairing 授权和 endpoint identity 校验；暂不叠加第二层 application encryption。后续若 threat model 提升，应通过 ADR 重新决策。
- 目标态 `Opaque Relay Stream` 下，`CodexPort Relay` 只能记录 route metadata、open/close timing、byte counts 和 error code。测试 harness 必须证明 Relay 不保存、不打印、不检查 prompt、assistant output、command output、diff 或 approval payload 明文。
- JSON-RPC transport 是 newline-delimited，但不能假设一次 stdout read 等于一条 JSON message；`JSONRPCFramer` 负责处理 split/coalesced messages。
- `SSHDriver` 是 deep module boundary。SwiftUI、session store 和 protocol facade 不应直接依赖 SwiftNIO 类型。
- Host key trust 必须跨启动持久化。当前用 `FileKnownHostStore` / `PersistentKnownHostVerifier` 按 `HostProfile.id` 保存 trusted fingerprint。
- MVP 支持 password auth 和未加密 OpenSSH Ed25519 private key auth。Encrypted keys 和更广泛 key formats 是后续工作。

## Glossary

Use these terms consistently in issues, PRDs, tests, and code comments.

| Term | Meaning |
| --- | --- |
| `Connection Method` | 新建或编辑 Host 时选择的连接方式。当前支持 `Direct SSH Connection` 和 `Relay Connection` 并存；同一台物理 Mac 如果要用两种连接方式，应是两个 Host 条目。 |
| `Direct SSH Connection` | iOS app 直接通过 SSH 连接用户自己的 Mac/VPS/Linux host 的方式，使用本地 `Host Profile`。它不是 `P2P-first Remote Connection`，也不承诺 `Real-time Multi-Device Sync`；这些能力属于 `Relay Connection` 方向。 |
| `Relay Connection` | iOS app 和远端 Mac 都主动连接到 `CodexPort Relay` 的连接方式。当前 production 实现是 `Relay-mediated JSONL Bridge`；目标态是 `Opaque Relay Stream`。 |
| `P2P-first Remote Connection` | 后续远程连接方向：iOS app 与 `CodexPort Host Agent` 优先通过 `WebRTC DataChannel Transport` 直连通信；VPS 只负责 signaling、pairing、presence 和 NAT traversal 协商，直连失败时允许 `TURN relay fallback`。 |
| `Remote Connection Path State` | `P2P-first Remote Connection` 的可观测连接阶段，至少区分 `signaling reachable`、`ICE gathering`、`direct connected`、`TURN relayed connected`、`datachannel open`、`host protocol ready`、`Codex live source ready` 和 failed reason。 |
| `Client-Host Session Protocol` | iOS app 和 `CodexPort Host Agent` 之间的应用层会话协议，承载 session list、history、prompt、write status、live events 和 fan-out 语义。它可以运行在 `WebRTC DataChannel Transport` 上，不等同于 Relay/VPS transport。 |
| `Real-time Multi-Device Sync` | `Relay Connection` 的目标要求：已打开 Codex TUI 和所有已连接 iPhone 应实时显示同一组 Codex sessions、turn status、assistant output、command output、file changes 和 approval state。Codex Desktop 当前只保证 persisted history reload 后可见，不再作为实时同步 gate。 |
| `Relay State Recovery` | 历史降级概念：Relay 只做到远程可达和 persisted state recovery，但不提供 live updates。当前不再作为可发布产品方向；如果 `Codex App Control Plane Research` 未找到稳定可授权的 `Shared Live Session Source`，相关远程同步能力应保持 blocked/experimental，不能以 persisted-history-only 体验发布。 |
| `Host Profile` | 用户创建的一个可连接 Host 条目。Direct SSH 的 `Host Profile` 包含 `host`、`port`、`username`、`auth`、`codexPath`、`defaultDirectory` 和 `knownHostFingerprint`；Relay 连接应作为同级的另一种 Host 条目。 |
| `Relay Host` | 使用 `Relay Connection` 的 Host 条目，代表某台 Mac 上某个 macOS 用户身份下运行并配对的 `CodexPort Host Agent`。它不是同一条 Direct SSH `Host Profile` 上的附加字段，也不是整台物理 Mac 的全局身份。 |
| `Relay Host Presence` | `CodexPort Host Agent` 在 Relay/P2P signaling 层面的可达状态。Presence 可达不代表用户已经可以进入会话列表。 |
| `Relay Host Readiness` | Host 列表面向用户呈现的就绪状态；只有当 `Relay Host` 已可进入会话列表时，才应显示为“在线”。 |
| `Codex App Host` | 正在运行官方 Codex App 的 Mac/Windows host。官方 remote control 体验以这个 host 为入口，手机连接后应看到该 host 上同一套 projects、threads、credentials、plugins 和 local setup。 |
| `CodexPort Host Agent` | 安装在用户 Mac 上、以某个 macOS 用户身份运行的本地 agent，用于主动连出到 `CodexPort Relay` 并暴露该用户的 CodexPort 可连接能力。 |
| `CodexPort Relay` | 公网可达的 CodexPort 服务，用于设备配对、host 在线状态和连接转发。当前 production 实现路由 `Relay-mediated JSONL Bridge`；目标态只路由 opaque byte stream，不读取 JSON-RPC 明文。 |
| `P2P Signaling Service` | `P2P-first Remote Connection` 中 VPS 保留的服务角色：保存 `Pairing Record`、处理 revoke、发布 presence，并在授权设备和 HostAgent 之间转发 WebRTC offer/answer/ICE candidate。它不保存、不解析 `Client-Host Session Protocol` payload。 |
| `Relay-mediated JSONL Bridge` | 当前 production Relay/VPS 实现：iOS stream 和 HostAgent bridge 都连接到 `CodexPort Relay`，Relay 按 stream route 转发 JSONL bridge lines。它是 VPS 中转方案，不是 P2P，也不是端到端加密的 `Opaque Relay Stream`。 |
| `WebRTC DataChannel Transport` | `P2P-first Remote Connection` 的首选传输：使用 WebRTC ICE/STUN/TURN 建连，并在可靠有序 DataChannel 上承载 CodexPort client-host protocol。 |
| `TURN relay fallback` | `WebRTC DataChannel Transport` 直连失败时允许使用的标准 WebRTC relay path。它可能让加密后的传输字节经过 TURN server，但 TURN server 不解析 CodexPort application protocol，不承担 session state、JSONL route 或业务转发。 |
| `Opaque Relay Stream` | `Relay Connection` 中 iOS app 与 `CodexPort Host Agent` 之间的端到端加密 byte stream。Relay 不依赖 JSON-RPC framing，只能看到路由 metadata、连接状态、byte counts 和 timing。 |
| `Stateless Relay Reconnect` | `Relay Connection` 断线后的第一阶段恢复策略：关闭当前 stream 和对应 app-server stdio session，重连后重新建立 stream，并通过 remote Codex state 恢复 UI；不做 Agent-side stream replay、notification cache 或 disconnected session buffer。 |
| `Shared Live Session Source` | 能同时驱动已打开 Codex TUI 和多个 iPhone 的同一个 live session source。`Relay Connection` 若要满足当前 `Real-time Multi-Device Sync` gate，必须接入这个 source，而不是为每个客户端启动互相独立的 stdio app-server session。 |
| `Codex CLI Live Adapter` | `CodexPort Host Agent` 连接 `Shared Live Session Source` 的候选边界：基于官方 `codex` CLI/TUI 的公开源码、schema 和协议行为实现兼容的 live producer，让 iOS 侧输入进入与官方 Codex TUI 相同的实时同步机制。它不是启动或控制真实 interactive TUI 进程，不解析 TUI 屏幕，也不是逆向闭源 Codex Desktop；Desktop 当前只作为 persisted history viewer，不作为 live gate。 |
| `Codex App Control Plane Research` | 在承诺 `Real-time Multi-Device Sync` 前必须完成的调研验证：确认官方 Codex CLI/TUI host 是否存在稳定、可授权、可由 CodexPort 接入的 local control plane 或 remote endpoint。调研允许分析官方 Codex docs、CLI help 和 `openai/codex` 公开源码；#80 已确认 Codex Desktop open-session UI 不是 live participant，后续不再把 CLI ↔ Desktop live sync 当作 gate。 |
| `Public Source Analysis` | 对 `openai/codex` 等公开源码的分析，不属于逆向。将公开源码中发现的机制映射到 Codex Desktop 时，必须区分公开 protocol/schema 与 Desktop private implementation detail。 |
| `Device Identity` | 某个 iOS app installation 或某个 per-user `CodexPort Host Agent` installation 的长期设备身份，由本地长期非对称 key pair 表示。第一阶段不引入 `CodexPort Account`。 |
| `Endpoint Key Pair` | iOS app installation 或 `CodexPort Host Agent` installation 本地生成并持有的长期非对称 key pair。`Pairing Token` 只用于交换和确认 public keys，不是长期访问凭据。 |
| `Pairing` | 一个 iOS `Device Identity` 与一个 `Relay Host` 之间的授权关系。首次 pairing 由 Mac 端 `CodexPort Host Agent` 生成 token，iPhone 消费 token；多台 iPhone 访问同一个 `Relay Host` 时应分别 pair、分别 revoke。 |
| `Pairing Token` | `CodexPort Host Agent` 为首次 pairing 生成的一次性短时 token，可用 QR code 或短码传给 iPhone。它只用于建立授权关系，不是长期访问凭据。 |
| `Pairing Record` | Relay 保存的配对 metadata，用于判断某个 iOS device public key 是否能 attach 到某个 `Relay Host` public key；不包含 Codex/API key、长期 bearer secret 或 JSON-RPC 明文。 |
| `CredentialVault` | 本地凭据抽象。生产实现是 `LocalEncryptedCredentialVault`；测试使用 in-memory fake。不要在日志、文档或测试失败输出中暴露 secret value。 |
| `KnownHostVerifier` | 判断远端 host key fingerprint 是 trusted、unknown 还是 changed 的边界。 |
| `SSHDriver` | 执行 SSH host key 探测、exec channel、stdin/stdout/stderr stream 和一次性 command 的底层接口。 |
| `NIOSSHDriver` | 基于 `swift-nio-ssh` 的 production `SSHDriver`。SwiftNIO-specific code 应留在此边界内。 |
| `AppServerShellCommand` | 生成远端 shell command 的集中位置，负责 PATH export 和 shell quoting。 |
| `AppServerSession` | 已连接的 SSH stream、`CodexProtocolFacade` 和 app-server event source 的组合。 |
| `JSONRPCClient` | 负责 request id、pending response matching、server notifications 和 server requests 的 JSON-RPC client。 |
| `CodexProtocolFacade` | UI-facing protocol facade，暴露 `initialize`、`thread/list`、`thread/resume`、`thread/start`、`turn/start`、`turn/interrupt`、`fs/*` 和 approval response 等高层操作。 |
| `WorkspaceProject` | 从 `thread/list` 的 `Thread.cwd` 聚合出的 workspace，不来自全盘 filesystem scan。 |
| `SessionStore` | 管理 thread open/resume、paged history、running turn、streamed visible items、steer 和 interrupt 的 session state。 |
| `RemoteFileBrowser` | 只用于空状态、选择新 `cwd`、读取目录、创建目录；不是 workspace discovery 的主数据源。 |
| `PendingAttachment` | 还在本机、未上传到 remote host 的图片或文件。 |
| `TurnAttachment` | 已可传给 Codex turn 的附件，当前包括 `localImage(path:detail:)` 和 `remoteFile(path:)`。 |
| `Structured User Message` | iOS 会话 UI 中的用户消息内容模型，结构化保存正文、`Skill Mention` 和附件；发送到 Codex protocol 时再映射为当前支持的 text input 和 `TurnAttachment`。 |
| `Skill Mention` | 用户在 composer 中选择的 agent skill 引用。它不是普通 `$` 文本；UI 应能稳定渲染为 mention chip，内部应保留 skill identifier/display name。 |
| `Message Attachment` | `Structured User Message` 中的附件引用，可来自 iPhone 本地缓存或远端 host path。图片预览以结构化附件为准；markdown image 只作为兼容输入，不能作为长期 source of truth。 |
| `PermissionMode` | 输入栏权限模式映射：`remoteDefault`、`autoReview`、`fullAccess`、`customConfigToml`。 |
| `CollaborationMode` | turn 的协作模式，当前包括 `default` 和 `plan`。不要用 prompt prefix 模拟 plan mode。 |
| `ApprovalRequest` | app-server 发来的 command、file change 或 permissions approval server request。 |

Avoid these terms unless quoting historical docs:

- `SSH terminal`：本项目不是 terminal renderer。
- `TUI fallback`：MVP 明确不支持。
- `secure relay`：本项目不实现 OpenAI secure relay。
- `daemon start && proxy`：这是早期 PRD 链路，不是当前 accepted implementation。

## Product boundaries

In scope for the MVP:

- 多个 `Host Profile`。
- SSH password 和 SSH key 登录。
- 本地加密凭据保存。
- 首次 host key trust 和 host key changed blocking。
- 连接诊断：SSH、Codex version、app-server availability、JSON-RPC `initialize`。
- `thread/list` 驱动 workspace/session list。
- `thread/resume` / `thread/turns/list` / legacy history fallback 驱动 session detail。
- `turn/start`、`turn/steer`、`turn/interrupt`。
- command output、assistant text、file change diff 的 transcript presentation。
- `fs/readDirectory`、`fs/getMetadata`、`fs/createDirectory`、`fs/writeFile`。
- 相机/文件附件上传到 client-owned remote directory。
- command/file/permissions approval flow。
- plan mode 和 permission modes，只使用 protocol-supported fields。
- 前台恢复时重新加载 workspace/session state。

Out of scope:

- ChatGPT 通用聊天、账号体系、GPTs、插件商店。
- OpenAI secure relay。
- 自研 Mac/VPS daemon。
- app-server port、WebSocket 或 Unix socket 公网暴露。
- Codex TUI parsing。
- 自行解析 rollout JSONL 补全历史。
- 可靠后台长连接、APNs 完成推送或长时间后台 SSH 保活。
- iCloud 同步 Host Profile 或 SSH secrets。
- 完整 iPadOS 优化；iPad 可运行，但产品优先级是 iPhone。
- `thread/realtime/start` 实时语音对话；麦克风只做 speech-to-text。

## Data and state sources

- Remote Codex state 是 session/workspace 的 source of truth。
- Workspace list 来自 `thread/list` 和 `Thread.cwd` 聚合；不要默认扫描远端 filesystem。
- Remote file browser 默认从 `HostProfile.defaultDirectory` 和历史 workspaces 起步；不要默认从 `/` 全盘浏览。
- Host Profile 和 credentials 是本机 state，不做跨设备同步。
- Attachment remote root 是 client-owned implementation detail。推荐路径形态是 `~/.codex-port/attachments/<thread-id>/<timestamp>/<filename>` 或等价 client-owned directory。

## Testing conventions

测试应覆盖外部行为和 UI-visible state，而不是私有函数调用顺序。

Important test boundaries:

- `SSHDriver` 用 fake driver 或 protocol-level doubles 测试认证、host key、command failure、stdio 断开。
- `CodexPortRelayTestSupport` 提供 fake Relay、fake Host Agent endpoint 和 fake iOS device endpoint，用于 pairing、presence、attach/detach、version negotiation 和 opaque stream tests；fake harness 不应成为 iOS app 或 Host Agent production target 的依赖。
- `CodexPortRelayCore` tests 应覆盖 service-side auth/gateway 外部行为：WebSocket open request decoding、active Pairing Record gate、revoked/unknown/incompatible rejection、local WebSocket listener routing、stream telemetry byte counts；不要让它依赖 iOS UI、Host Agent UI 或解析 Codex JSONL 明文。
- `JSONRPCClient` / `JSONRPCCodec` 用 in-memory streams 测试 request/response matching、notifications、server requests、invalid JSON 和 split/coalesced frames。
- `CodexProtocolFacade` 测 method/params mapping 和错误映射。
- `WorkspaceIndex` 纯单元测试 `Thread.cwd` 聚合、排序、missing `gitInfo`、空列表和 read state。
- `SessionStore` 测 open/resume、paged history、streamed delta merge、steer、interrupt 和 failure state。
- iOS AFK/local verification 可通过 `RelayHostLaunchSeed`、`RelayHostLaunchAutomationPlan` 和 `PersistentHostProfileStore.seedRelayHostIfNeeded` 预置 Relay Host profile；测试应覆盖 seed idempotency、`deviceID` / `relayEndpointURL` persistence、编辑 round-trip、autoconnect/autoprompt plan 和双 simulator local WebSocket fan-out，不应把 launch environment 当作生产 pairing 权限来源。
- Host Agent `codex-exec-json` backend 测试应覆盖 initial `codex exec --json`、subsequent `codex exec resume --json`、真实 `thread.started` id 记忆、write-scoped turn/item namespace、JSON-only log filtering、hung process timeout、failed write status reason、WebSocket 双 iOS fan-out、local WebSocket executable stdin EOF lifecycle 和 no-secret diagnostics。真实 Codex CLI/WebSocket smoke 可作为 gated/local evidence；当前 live-sync gate 必须记录已打开 Codex TUI 的实时更新证据。Codex Desktop 只可作为 persisted-history reload 观察，不作为 live-sync gate。
- Relay P2P signaling tests 应覆盖 public HTTP surface、Core client URL/payload contract、active `Pairing Record` gate、revoked device rejection 和 version negotiation failure。通过这些测试只能证明 signaling 可达和授权正确，不能替代真实 WebRTC DataChannel runtime 或 TUI + iPhone HITL。
- P2P route seam tests 应覆盖 `RelayP2PSessionTransportFactory`、`RelayDeferredJSONLTransport`、`RelayWebRTCDataChannelFactory`、`HostAgentWebRTCDataChannelAcceptor` 和 `RelaySessionRouteBuilder`，证明 production signaling + DataChannel factory 的产物能进入现有 `Client-Host Session Protocol` session attach/list/detail path，并覆盖 STUN/TURN 环境配置、TURN credential redaction、offer/answer 后续 trickle ICE 双向转发和 remote ICE application。通过这些测试仍不能替代真实 WebRTC runtime linkage 或物理 iPhone HITL。
- P2P runtime guard tests 应覆盖 `RelayConnectionTransportFactory` 的默认 P2P route、显式 legacy fallback route、`UnavailableRelayP2PDataChannelFactory` failure 和 diagnostics row。任何 production route selection work 都不得依赖 `CodexPortRelayCore/P2PWebRTCDataChannelTransportPair` 这类 fake/in-memory transport。
- HostAgent P2P endpoint tests 应覆盖 `HostAgentP2PDataChannelEndpoint` 对 split/coalesced JSONL frames、thread list、history、prompt write status、live deltas 和 sanitized error 的处理。通过这些测试只能证明 HostAgent application protocol seam 可承载 DataChannel frames，不能替代真实 HostAgent WebRTC runtime/signaling listener 或 TUI + iPhone HITL。
- P2P enablement seam tests 应覆盖 `CODEXPORT_IOS_RELAY_TRANSPORT_MODE` unset/空值默认选择 `p2pWebRTCDataChannel`、显式 legacy 值才回退 `RelayWebSocketJSONLTransport`，以及 HostAgent `--p2p-listen` / `CODEXPORT_HOST_AGENT_P2P_LISTEN=1` 接入 listener guard。通过这些测试仍不能替代真实 WebRTC runtime 或物理 iPhone HITL。
- Transcript presentation 应把 `TurnStatus.failed` 渲染成用户可见的 status row；Relay/backend failure 不能只留在 internal `SessionStore.status` 或 write status 中。
- `RemoteFileBrowser` 测 home 起步、绝对路径跳转、metadata 判断、recursive create directory 和 permission/error display。
- `AttachmentUploader` 测 directory creation、base64 write、image `localImage` 和 file remote path。
- `ApprovalResponder` 测 command/file/permissions request parsing 和 `accept`、`acceptForSession`、`decline`、`cancel` response payload。
- 真实远端 Codex 集成测试应保持 manual 或 gated，不应依赖普通 CI 中的开发者 `~/.codex` state。

## Agent notes

- Human-facing artifacts 默认使用中文；protocol names、Swift type names、file names、labels、commands 和 workflow terms 保持英文原文。
- 需要理解架构时，先读本文件和 `docs/adr/`，再读相关 module。
- 如果 `docs/prd/` 与 `docs/adr/` 或当前代码冲突，以 ADR 和代码为准，并在输出中显式指出冲突。
- 不要打印、grep broadly、复制或总结本机 credentials。检查 credential availability 时只确认 required environment variable names 是否存在。
