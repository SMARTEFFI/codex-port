# PRD: Codex Port 0.2.x Relay Connection + CodexPort Host Agent

Version: `0.2.x`

> 当前文档保留为历史 `0.2.x` Relay/Host Agent 背景。#80 已修正 Desktop live-sync 假设：新的 canonical gate 是 `Codex CLI Live Adapter + TUI Live Sync`。Codex Desktop 只作为 persisted-history reload viewer，不再作为 live-sync gate。后续 implementation entry 以 #63/#77 amendments 和 `docs/research/codex-cli-live-adapter.md` 为准。

## Problem Statement

用户已经可以通过 `Direct SSH Connection` 在 iPhone 上连接自己的 Mac/VPS/Linux host，并驱动远端 `codex app-server --listen stdio://`。这个路径适合单个 iPhone 直接访问远端 Codex state，但它不是 `Shared Live Session Source`：当官方 Codex TUI 打开同一会话时，手机端通过现有 SSH path 发送的消息不会实时同步到已打开的 TUI view。

用户的下一阶段目标是 `Relay Connection`：多个 iPhone 不必直接暴露或访问 SSH，而是通过 `CodexPort Relay` 连接 Mac 上常驻的 `CodexPort Host Agent`。更重要的是，当 iPhoneA、iPhoneB 和 Mac Codex TUI 同时打开同一会话时，三端都要实时显示同一组 Codex sessions、turn status、assistant output、command output、file changes 和 approval state。Codex Desktop 只作为 persisted-history reload viewer，不作为实时同步 gate。

`Codex App Control Plane Research` 已经确认三件事：

- 当前 `codex app-server --listen stdio://` path 不满足 TUI live sync，不能作为 Relay v2 的 live-sync 基础。
- standalone daemon/control socket 有同一 app-server 多客户端 broadcast 能力，并已通过 #80 证明可驱动已打开 Codex TUI live update。
- #80 也证明 Codex Desktop 打开同一 thread 时不会实时更新；退出重进后可见属于 persisted-history reload。因此 Desktop App UI private schema 不再是 gate，`Codex CLI Live Adapter` 的目标收窄为兼容官方 CLI/TUI live protocol。

同时，当前仓库需要升级为一个合理组织的 multi-product repo：既包含 iOS 客户端，也包含 macOS 上常驻的 `CodexPort Host Agent`。两个项目的工程文件、targets、schemes、resources、entitlements 和 shared modules 必须清晰分离，不能把 macOS 常驻工具混进 iOS app target，也不能让 shared protocol/transport 逻辑散落在 UI 层。

## Solution

在 `0.2.x` 中引入 `Relay Connection` 和 `CodexPort Host Agent`，作为 `Direct SSH Connection` 的同级连接方式，而不是替换现有 SSH path。

用户创建 Host 时必须选择 `Connection Method`：

- `Direct SSH Connection`：保持现有行为，iOS 直接 SSH 到 Mac/VPS/Linux host，并启动独立 `codex app-server --listen stdio://`。
- `Relay Connection`：代表某台 Mac 上某个 macOS 用户身份下运行并配对的 `CodexPort Host Agent`。同一台物理 Mac 如果用户想同时使用 Direct SSH 和 Relay，应创建两个 Host 条目。

`Relay Connection` 的默认 live-sync 方案是 `Codex CLI Live Adapter`：

1. `CodexPort Host Agent` 在 Mac 用户环境中运行兼容官方 CLI/TUI live protocol 的 producer。
2. Host Agent 不为每台 iPhone 启动互相独立的 `codex app-server --listen stdio://`。
3. 多个 iPhone attach 同一个 Relay Host、同一个 Codex thread 时，Host Agent fan-out 同一条 CLI-backed live stream。
4. 来自多个 iPhone 的 prompt、steer、interrupt 和 approval action 必须在 Host Agent 侧 serialized，避免同时写入同一 live session。
5. Mac Codex TUI 的实时同步由兼容官方 CLI/TUI live protocol 的 producer 承担；Codex Desktop 只作为 persisted-history reload viewer。
6. `CodexPort Relay` 只做 pairing、presence、connection routing 和 opaque encrypted stream forwarding，不读取 Codex JSON-RPC 明文、不重建 Codex session state、不保存 ChatGPT/Codex credentials。

仓库组织升级为两个 product projects：

- iOS Client project：保留现有 iPhone-first app，负责 Host Profile、Connection Method、workspace/session UI、input composer、attachments、approval UI、diagnostics 和 foreground recovery。
- macOS Host Agent project：新增常驻 Mac 工具，负责 pairing、Relay 连接、Host online status、CLI live session lifecycle、multi-phone fan-out、serialized input、local diagnostics 和无 secret 日志。

两个 product projects 共享稳定模块：

- shared domain models：Host、Relay Host、Device Identity、Pairing、Connection Method、session metadata 和 diagnostics result。
- shared relay protocol：pairing、presence、attach/detach、stream open/close、stream error、version negotiation 和 opaque byte stream framing。
- shared crypto/auth boundary：endpoint key pair、pairing token 验证、payload encryption/decryption、revoke semantics。
- shared test doubles：fake Relay、fake Host Agent、fake CLI adapter、fake encrypted stream。

如果需要实现 `CodexPort Relay` 服务端，它应和 `0.2.x` contracts 一起在当前 repo 内版本化，但它不是第三个用户面对的 app project；它是 `Relay Connection` 的服务组件。repo 的用户面对 product projects 仍然是 iOS client 和 macOS Host Agent。

## User Stories

1. As a CodexPort iOS 用户, I want 在新建 Host 时选择 `Direct SSH Connection` 或 `Relay Connection`, so that 我可以清楚区分两种连接方式。
2. As a CodexPort iOS 用户, I want 同一台 Mac 可以有一个 Direct SSH Host 和一个 Relay Host, so that 我可以按网络环境选择直连或中继。
3. As a CodexPort iOS 用户, I want `Relay Connection` 作为独立 Host 条目出现, so that 我不需要在同一条 Host Profile 里切换复杂模式。
4. As a CodexPort iOS 用户, I want 创建 Relay Host 时看到 Mac Host Agent 的配对状态, so that 我知道这条 Host 是否可用。
5. As a CodexPort iOS 用户, I want 用 QR code 或短码完成 Pairing, so that 我可以在没有手动复制长密钥的情况下授权 iPhone。
6. As a CodexPort iOS 用户, I want 每台 iPhone 独立 pair 到同一个 Relay Host, so that 我可以单独 revoke 某台设备。
7. As a CodexPort iOS 用户, I want Relay Host 显示 online/offline 状态, so that 我连接前知道 Mac Host Agent 是否在线。
8. As a CodexPort iOS 用户, I want Relay Host 显示最后在线时间, so that 我能判断问题是网络、Mac 睡眠还是 Host Agent 未运行。
9. As a CodexPort iOS 用户, I want Relay Host 连接失败时看到可操作诊断, so that 我知道应检查 Relay、Host Agent、pairing 还是 CLI。
10. As a CodexPort iOS 用户, I want Relay Host 仍然使用 Mac 上已有 Codex CLI/Codex Desktop 登录状态, so that 我不需要把 ChatGPT/Codex secret 复制到 iPhone 或 Relay。
11. As a CodexPort iOS 用户, I want 通过 Relay 打开 Mac 上同一组 Codex sessions, so that 手机看到的会话和 Mac TUI/Codex state 一致。
12. As a CodexPort iOS 用户, I want 通过 Relay 继续 Mac TUI 正在打开的会话, so that 我可以从桌面自然切到手机。
13. As a CodexPort iOS 用户, I want 在 iPhone 发送消息后已打开的 Mac TUI 同步显示, so that 桌面端不会落后。
14. As a CodexPort iOS 用户, I want 在 Mac TUI 发送或更新消息后 iPhone 同步显示, so that 手机端不会落后。
15. As a CodexPort iOS 用户, I want iPhoneA 发送消息后 iPhoneB 实时显示, so that 多台手机连接同一 Mac 时状态一致。
16. As a CodexPort iOS 用户, I want iPhoneB 发送消息后 iPhoneA 实时显示, so that 多设备同步不是单向的。
17. As a CodexPort iOS 用户, I want Mac + iPhoneA + iPhoneB 同时打开同一会话时都看到 running turn 状态, so that 我知道 Codex 是否仍在工作。
18. As a CodexPort iOS 用户, I want assistant output 流式同步到所有已连接设备, so that 我不用等待完整 turn 结束。
19. As a CodexPort iOS 用户, I want command output 流式同步到所有已连接设备, so that 我能看到 Codex 正在运行什么。
20. As a CodexPort iOS 用户, I want file change summaries 和 diffs 同步到所有已连接设备, so that 我可以在任一设备 review。
21. As a CodexPort iOS 用户, I want approval request 同步到所有已连接设备, so that 任一已授权设备都能响应需要人工确认的操作。
22. As a CodexPort iOS 用户, I want 某台设备接受 approval 后其他设备立即看到 approval 已处理, so that 不会重复处理同一个请求。
23. As a CodexPort iOS 用户, I want 多台 iPhone 同时输入时 Host Agent 进行 serialized 写入, so that 同一 CLI live session 不会被并发输入破坏。
24. As a CodexPort iOS 用户, I want 当一个 turn 正在运行时其他设备的发送状态一致, so that UI 不会错误地允许冲突操作。
25. As a CodexPort iOS 用户, I want interrupt 从任一设备发出后同步到所有设备, so that 大家都知道 turn 已停止。
26. As a CodexPort iOS 用户, I want Relay 断线重连后恢复同一会话状态, so that 临时网络问题不会让我失去上下文。
27. As a CodexPort iOS 用户, I want Relay 重连时看到明确状态, so that 我知道是在 reconnect、recovering 还是 failed。
28. As a CodexPort iOS 用户, I want Relay Service 不读取 Codex JSON-RPC 明文, so that 我的 prompt、assistant output、command output 和 diffs 不暴露给中继服务。
29. As a CodexPort iOS 用户, I want Relay 不保存 ChatGPT token、Codex token、SSH password 或 API key, so that Relay 被攻破也不会泄露本机凭据。
30. As a CodexPort iOS 用户, I want Pairing Token 是一次性短时 token, so that 泄露窗口足够小。
31. As a CodexPort iOS 用户, I want 可以从 Mac Host Agent revoke 某台 iPhone, so that 丢失设备后能切断访问。
32. As a CodexPort iOS 用户, I want 可以从 iPhone 删除 Relay Host, so that 本机不再保存该配对入口。
33. As a Mac 用户, I want 安装一个常驻 `CodexPort Host Agent`, so that 我的 Mac 可以主动连出 Relay，不需要开放入站 SSH。
34. As a Mac 用户, I want Host Agent 以当前 macOS 用户身份运行, so that 它访问的是该用户的 Codex CLI、projects、credentials 和 local setup。
35. As a Mac 用户, I want Host Agent 提供 pairing UI, so that 我可以明确授权新 iPhone。
36. As a Mac 用户, I want Host Agent 显示已配对设备列表, so that 我知道哪些设备可以连接。
37. As a Mac 用户, I want Host Agent 显示当前连接的 iPhone 数量, so that 我能判断是否有人正在使用。
38. As a Mac 用户, I want Host Agent 显示当前 active session/thread, so that 我知道 Relay 正在驱动哪个 Codex 会话。
39. As a Mac 用户, I want Host Agent 能在登录后自动启动, so that Relay Host 长期可用。
40. As a Mac 用户, I want Host Agent 能被手动暂停或退出, so that 我能立即关闭远程访问。
41. As a Mac 用户, I want Host Agent 日志不包含 secrets、prompt 明文或 pairing secret, so that 诊断不会泄露敏感内容。
42. As a Mac 用户, I want Host Agent 检查 `codex` CLI 是否存在和版本是否兼容, so that 配对前就能发现本机不可用。
43. As a Mac 用户, I want Host Agent 使用真实 `codex` CLI/TUI live protocol, so that iPhone 和已打开 Codex TUI 能看到同一会话。
44. As a Mac 用户, I want Host Agent 不依赖 Desktop binary patch 或 private renderer IPC, so that 方案更稳健、更可维护。
45. As a Mac 用户, I want Host Agent 不把 standalone daemon/control socket 当默认 live source, so that 不会重复已失败的 Desktop UI probe 路径。
46. As a CodexPort Relay operator, I want Relay 只保存 pairing metadata 和 routing metadata, so that 服务端不承担 Codex state source of truth。
47. As a CodexPort Relay operator, I want Relay 能区分 host identity 和 device identity, so that 多设备配对和 revoke 可以独立管理。
48. As a CodexPort Relay operator, I want Relay 能广播 host online/offline presence, so that iOS UI 可以显示连接状态。
49. As a CodexPort Relay operator, I want Relay 能打开和关闭 opaque streams, so that iOS 和 Host Agent 可以建立端到端连接。
50. As a CodexPort Relay operator, I want Relay 能限制未配对设备 attach, so that 只有授权 iPhone 能连接 Relay Host。
51. As a CodexPort Relay operator, I want Relay 能记录 byte counts、timing 和 error code, so that 可以诊断连接问题但不读取 payload 明文。
52. As a developer, I want 当前 repo 同时包含 iOS Client project 和 macOS Host Agent project, so that 0.2.x 的两个端可以一起演进。
53. As a developer, I want iOS 和 macOS 工程文件分离, so that product-specific resources、entitlements 和 schemes 不互相污染。
54. As a developer, I want shared domain/protocol/crypto modules 被两个 product projects 复用, so that Pairing、Relay protocol 和 diagnostics 不重复实现。
55. As a developer, I want iOS UI 不依赖 macOS UI 类型, so that iOS app 仍能独立构建和测试。
56. As a developer, I want Host Agent 不依赖 iOS SwiftUI app 类型, so that Mac 常驻工具可以独立构建和发布。
57. As a developer, I want shared relay protocol 有版本协商, so that iOS app 和 Host Agent 版本不匹配时能清晰失败。
58. As a developer, I want CI 同时构建 iOS Client、macOS Host Agent 和 shared modules, so that 工程组织问题能尽早暴露。
59. As a developer, I want fake Relay 和 fake CLI adapter 支持自动化测试, so that 普通 CI 不依赖真实 Mac Desktop 或真实 `~/.codex` state。
60. As a developer, I want gated integration test 覆盖 Mac Codex TUI + iPhoneA + iPhoneB, so that `Real-time Multi-Device Sync` 的核心承诺有端到端证据。
61. As a support/debugging user, I want Direct SSH 和 Relay diagnostics 使用同一套可读错误分类, so that 失败报告容易理解。
62. As a product owner, I want `0.2.x` 明确不声称复刻官方 remote connection 直到三端验证通过, so that 产品表述不超过证据。

## Implementation Decisions

- `Relay Connection` 是 `Connection Method` 的同级选项，不是现有 Direct SSH Host Profile 的附加开关。同一台物理 Mac 如果需要两种方式，应创建两个 Host 条目。
- `Relay Host` 代表某台 Mac 上某个 macOS 用户身份下运行并配对的 `CodexPort Host Agent`。它不是整台 Mac 的全局身份，也不是 SSH host 的别名。
- 保留现有 `Direct SSH Connection` behavior。0.2.x 不应破坏现有 `codex app-server --listen stdio://` direct path、Host key trust、CredentialVault、WorkspaceIndex、SessionStore、RemoteFileBrowser、AttachmentUploader 和 ApprovalResponder。
- `Relay Connection` 的默认 live-sync path 使用 `Codex CLI Live Adapter`。Host Agent 基于 `openai/codex` 公开源码、schema 和协议行为实现兼容官方 CLI/TUI live protocol 的 producer，并让已打开 Codex TUI 同步。
- Host Agent 不应为每台 iPhone 启动独立 `codex app-server --listen stdio://`，因为该 path 已被证明不能让已打开 TUI live update。
- standalone daemon/control socket 只保留为 research/diagnostic surface，除非通过兼容 producer 明确接入 TUI live source；不能把 persisted history visibility 当成默认 `Shared Live Session Source`。
- `Codex CLI Live Adapter` 的第一阶段只追官方 CLI/TUI 使用的公开 live protocol/schema；`codex exec --json` / `codex exec resume --json` 不再作为 TUI live-sync 候选，只允许作为 persisted history recovery、fallback 或测试 fixture。
- persisted-history-only 不作为可发布降级方向。如果无法实现稳定 `Shared Live Session Source`，`Relay Connection` / P2P remote sync 应保持 blocked/experimental，不能发布一个需要用户退出重进 TUI 会话才能看到 iOS turn 的体验。
- 当前 Relay/HostAgent live-sync 实现不是兼容性约束。为满足 `Shared Live Session Source` 和 `TUI Live Sync`，可以丢弃或重构现有 `codex-exec-json` backend、local relay bridge、HostAgent live adapter 和相关 P2P/Relay glue code。
- Host Agent 维护 active live session registry。多个 iPhone attach 同一 thread 时，它们共享同一 CLI-backed live stream；Host Agent fan-out output/events，并 serialized input/approval/interrupt writes。
- Host Agent 必须定义输入并发规则。默认策略是单 writer queue：prompt、steer、interrupt、approval action 按到达顺序排队；UI 需要显示 queued/running/handled 状态。
- Relay Service 只处理 Pairing、presence、authorization metadata、stream routing、stream lifecycle 和 connection telemetry。Relay 不解析 Codex JSON-RPC 明文，不读取 prompt、assistant output、command output、diff、approval payload 或 secrets。
- iOS app 和 Host Agent 使用 `Endpoint Key Pair` 表示长期 `Device Identity`。`Pairing Token` 只用于首次交换和确认 public keys，不是长期访问凭据。
- Pairing Token 必须短时、一次性、可撤销。Pairing Record 保存授权 metadata，不包含 Codex/API key、SSH secret、ChatGPT token 或长期 bearer secret。
- Relay stream payload 必须端到端加密。Relay 可以看到 route metadata、connection state、byte counts 和 timing，但不能读取 payload 明文。
- iOS app 的 Relay Host UI 需要覆盖 create/pair/list/connect/reconnect/delete/revoke-visible-state。Mac Host Agent UI 需要覆盖 online/offline、pairing code、paired devices、active connections、CLI diagnostics 和 stop/pause。
- Host Agent 必须以当前 macOS 用户身份运行，使用该用户环境中的 `codex` CLI、Codex state、projects、plugins、credentials 和 local setup。
- Host Agent 需要 CLI compatibility diagnostics：检查 `codex` 是否存在、版本是否满足 0.2.x baseline、是否能打开 CLI live session、是否能观测到 session output/events。
- 0.2.x 的 version negotiation 必须覆盖 iOS app、Host Agent、Relay protocol 和 shared contract version。版本不兼容时，UI 显示明确升级提示，而不是静默失败。
- 仓库组织采用两个 product projects：iOS Client project 和 macOS Host Agent project。两个工程的 project files、schemes、resources、Info metadata、entitlements、signing 配置和 assets 应分开维护。
- shared modules 作为两个 product projects 的共同依赖，承载 domain models、Relay protocol、crypto boundary、diagnostics contracts 和 test doubles。product UI 不能把 shared contracts 复制粘贴到各自 target。
- 如果 Relay Service 实现也放入当前 repo，它应作为服务组件和 shared contract 一起版本化，但不新增第三个用户面对 app project。repo 的用户面对 projects 仍是 iOS Client 和 macOS Host Agent。
- CI/build matrix 必须能分别构建 iOS Client、macOS Host Agent 和 shared modules。任一 product project 的工程文件变更都应被构建验证覆盖。
- 0.2.x 需要更新领域文档和 ADR：明确 `Codex CLI Live Adapter`、Relay Host、Pairing、Endpoint Key Pair、Opaque Relay Stream、多 iPhone fan-out、serialized input、repo 双项目组织和 standalone daemon/control socket 限制。

## Testing Decisions

- 测试优先覆盖外部行为和 user-visible state，不断言私有函数调用顺序。0.2.x 的关键验收不是“调用了某个内部方法”，而是 iOS、Host Agent、Relay 和 Mac Codex TUI 在可观察行为上满足同步、授权和错误恢复要求。
- `Connection Method` seam：用 Host/Profile view model tests 覆盖 Direct SSH 和 Relay Host 是两个独立 Host 条目、同一物理 Mac 可以存在两条 Host、编辑其中一个不会污染另一个。
- Pairing seam：用 fake Relay + fake Host Agent + fake iOS device 测试 Pairing Token 生成、消费、过期、一次性使用、重复使用失败、revoke 后 attach 失败。
- Device identity seam：用 deterministic key test doubles 测试 Endpoint Key Pair 创建、public key exchange、Pairing Record 保存和 device-specific revoke。
- Opaque stream seam：用 in-memory encrypted streams 测试 iOS 到 Host Agent 的 payload 能 round-trip，Relay 只能看到 route metadata、byte counts 和 timing，不能读取明文 payload。
- Relay authorization seam：用 fake Relay 测试未配对 device attach 被拒绝、已配对 device attach 成功、revoked device attach 被拒绝、unknown host attach 被拒绝。
- Presence seam：用 fake Relay 测试 Host Agent online/offline、last seen、multiple iPhone attach count 和 disconnect 状态传播到 iOS UI。
- Host Agent lifecycle seam：用 Host Agent process/service abstraction 的 test double 覆盖 start、stop、pause、resume、login-start enabled/disabled、network reconnect 和 CLI unavailable。
- CLI Live Adapter seam：用 fake CLI adapter 覆盖 session open、output streaming、assistant text chunk、command output chunk、file change event、approval request、turn complete、turn failed 和 interrupt。
- Serialized input seam：用 fake CLI adapter 和多 client harness 测试 iPhoneA/iPhoneB 同时发送 prompt、approval 和 interrupt 时，Host Agent 按队列处理并向所有 clients 广播状态。
- Multi-phone fan-out seam：用 two-client in-memory integration 测试 iPhoneA 输入后 iPhoneB 收到同一 event stream，iPhoneB 输入后 iPhoneA 收到同一 event stream。
- Session recovery seam：用 fake Relay disconnect/reconnect 测试 stream close、reattach、state reload、running turn display 和 clear failure messaging。
- Direct SSH regression seam：保留现有 SSHDriver、JSONRPCClient、CodexProtocolFacade、SessionStore、WorkspaceIndex、RemoteFileBrowser、AttachmentUploader 和 ApprovalResponder tests，确保 0.2.x 不破坏 0.1.x path。
- Repo organization seam：CI 必须有独立 build jobs/schemes 验证 iOS Client、macOS Host Agent 和 shared modules；测试应失败于 product target 互相错误依赖。
- macOS Host Agent UI seam：用 view-state tests 覆盖 pairing code display、paired devices、online/offline、active connection count、CLI diagnostics、pause/quit state 和 no-secret logs。
- iOS Relay UI seam：用 view-state tests 覆盖 Connection Method picker、Relay Host create/pair/connect/reconnect/delete、online/offline badge、pairing failure、revoked host、version mismatch 和 diagnostics。
- Manual/gated end-to-end seam：必须保留一条人工或 gated integration checklist，验证 Mac Codex TUI + iPhoneA + iPhoneB 打开同一 session 后，任一端发送消息，其余端实时显示。这个测试可以依赖真实 Mac 和真实 `codex` CLI/TUI，但不应进入普通 CI。
- Live-source tracer bullet seam：在接入 P2P/WebRTC、Pairing 或 iOS UI 前，先用本机 HostAgent/local harness 验证 `Codex CLI Live Adapter` compatible producer 对同一 thread 的写入能让已经打开的 Codex TUI 实时显示 user message 和 final assistant message。#80 HITL 已确认 Codex Desktop open-session live update 不成立；Desktop 只作为 persisted-history reload 观察，不作为 live-sync gate。tool/file/approval live events 属于第二阶段验收。该 seam 未通过前，不得把 P2P transport 验证通过标记为 `Real-time Multi-Device Sync` 通过。
- Security regression seam：日志测试必须确认 pairing secret、token、ChatGPT/Codex credentials、SSH secrets、prompt 明文、assistant 明文、command output 和 diffs 不进入 Relay logs 或 Host Agent diagnostic export。

## Out of Scope

- 0.2.x 不替换或删除 `Direct SSH Connection`。
- 0.2.x 不把 `codex app-server --listen stdio://` 当作 Relay live-sync 基础。
- 0.2.x 不把 standalone daemon/control socket 直接升级为默认 `Shared Live Session Source`。
- 0.2.x 不把 `codex exec --json` / `codex exec resume --json` 当作 TUI live-sync 基础。
- 0.2.x 不启动或控制真实 interactive `codex` TUI 进程，不解析 TUI 屏幕作为产品实现路径。
- 0.2.x 不依赖 Desktop binary patch、process injection、反编译、private renderer IPC 或私有内存结构。
- 0.2.x 不让 Relay Service 读取、解析、保存或重放 Codex JSON-RPC 明文。
- 0.2.x 不在 Relay 保存 ChatGPT token、Codex token、API key、SSH password、private key 或 pairing secret。
- 0.2.x 不承诺 APNs 后台推送或长时间后台 iOS 保活。
- 0.2.x 不实现 OpenAI secure relay，也不声称复刻官方 remote connection，直到 Mac Codex TUI + iPhoneA + iPhoneB 三端验证通过。
- 0.2.x 不发布 persisted-history-only 的 Relay/P2P remote sync 体验作为 TUI live sync 替代。
- 0.2.x 不做完整 iPadOS 专项优化；iPad 可继续作为 iPhone-first app 的兼容运行目标。
- 0.2.x 不开放模型/provider/service tier 选择器，除非现有 protocol facade 已稳定支持。
- 0.2.x 不实现 ChatGPT 通用聊天、账号体系、GPTs 或插件商店。
- 0.2.x 不要求用户把同一台 Mac 的 Direct SSH 和 Relay 合并为一个 Host 条目。

## Further Notes

- 本 PRD 基于 `CONTEXT.md`、ADR 0001、现有 iOS app/core tests、GitHub Issue #28，以及 `docs/research/codex-app-control-plane.md`。
- `0.2.x` 是 Relay/Host Agent 阶段；它建立在当前 Direct SSH MVP baseline 之上，不回滚 ADR 0001。
- `Codex CLI Live Adapter` 是当前最强证据支持的默认候选路径：#80 已验证 compatible producer 能驱动已打开 Codex TUI 实时显示同一 thread 的 user/assistant turn；产品实现目标是基于公开源码、schema 和协议行为实现兼容 live producer，而不是把真实 TUI 作为被控制的子进程。
- 第一版实现前建议新增 ADR，明确为什么 Relay path 选择 CLI-backed live adapter，而不是 `codex app-server --listen stdio://` 或 standalone daemon/control socket。
- 后续拆 issue 时，建议按 vertical slices 拆分：repo 双项目组织、shared Relay contracts、Pairing、Relay presence、Opaque stream、Host Agent CLI adapter、iOS Relay Host UI、multi-phone fan-out、三端 gated verification。
