## Problem Statement

用户想在 iPhone 上直接使用 Codex，但官方 ChatGPT iOS App 在中国需要先连 VPN 才能打开；与此同时，Codex 连接桌面或远端 host 的 SSH 场景又可能需要关闭 VPN，实际使用流程很繁琐。

用户已经在桌面端使用 Codex CLI / app-server，并且远端 Codex 通过第三方 API 配置工作，不依赖官方 ChatGPT 订阅通道。因此用户需要一个独立的 iOS Codex 客户端：它不复刻 ChatGPT 通用 App，不依赖 OpenAI secure relay，而是通过 SSH 直接连接 Mac 或 VPS 上已有的 Codex 基建，让手机端能够查看 workspace、继续会话、发起新 turn、处理审批、上传相机/文件附件，并尽量复刻官方 iOS App 中 Codex 相关的操作体验。

这个产品的关键问题不是“在手机上跑一个 SSH 终端”，而是“用 iOS 原生界面驱动远端 `codex app-server proxy` 的结构化 JSON-RPC 协议”。如果退回 TUI 解析，体验会脆弱且难以维护；如果自建 Mac/VPS daemon，又违背用户“不新增 Mac 端工具、尽量利用现有 Codex CLI / app-server 基建”的原则。

## Solution

构建一个 iPhone 优先的原生 iOS App，通过 SSH 登录用户配置的 Mac、VPS 或 Linux host，并在远端执行：

```text
codex app-server daemon start && codex app-server proxy
```

iOS App 在 SSH stdio channel 上与远端 Codex app-server 进行 JSON-RPC 通信。远端继续使用现有 `~/.codex` state、项目文件系统、Codex CLI 配置和第三方 API key；手机端只负责连接、展示、输入和审批。

第一版直接复刻官方 iOS App 的 Codex 相关功能范围，包括 Host Profile 管理、SSH 认证、轻量远端诊断、workspace / 项目列表、会话详情、官方风格输入栏、相机/文件附件、权限菜单、审批流、计划模式、前台恢复和重连。

第一版最低兼容 `codex-cli >= 0.133.0`。低于该版本提示升级；高于该版本允许尝试连接，但提示未经验证。

## User Stories

1. As a Codex mobile user, I want to connect my iPhone directly to my Mac over SSH, so that I can use Codex without opening ChatGPT iOS App.
2. As a Codex mobile user, I want to connect to a public VPS over SSH, so that I can use Codex on remote machines that are already reachable from the internet.
3. As a Codex mobile user, I want to use Tailscale or LAN SSH when available, so that I can avoid exposing local machines to the public internet.
4. As a Codex mobile user, I want to create multiple Host Profile entries, so that I can switch between my Mac, VPS, and other Linux hosts.
5. As a Codex mobile user, I want to edit a Host Profile, so that I can update host, port, username, auth method, or Codex command path.
6. As a Codex mobile user, I want to delete a Host Profile, so that stale remote targets do not remain in the app.
7. As a Codex mobile user, I want to log in with SSH password, so that the app works like the official iOS Codex connection flow.
8. As a Codex mobile user, I want to log in with SSH key, so that I can use a stronger and more automation-friendly authentication method.
9. As a Codex mobile user, I want saved passwords to live in Keychain, so that credentials are not stored in plaintext.
10. As a Codex mobile user, I want saved credentials protected by Face ID or device unlock, so that casual device access does not expose remote SSH access.
11. As a Codex mobile user, I want host key fingerprint confirmation on first connection, so that I can avoid connecting to an impersonated host.
12. As a Codex mobile user, I want the app to warn me if a host key changes, so that I can stop a potentially unsafe connection.
13. As a Codex mobile user, I want a connection diagnostics screen, so that I can understand whether failure is caused by SSH, PATH, Codex version, daemon startup, or protocol handshake.
14. As a Codex mobile user, I want the app to check `codex --version`, so that I know whether the remote host is compatible.
15. As a Codex mobile user, I want the app to check `codex app-server proxy --help`, so that unsupported remote Codex versions fail clearly.
16. As a Codex mobile user, I want the app to automatically run `codex app-server daemon start`, so that I do not need to manually prepare the remote app-server before every connection.
17. As a Codex mobile user, I want the app to connect through `codex app-server proxy`, so that it uses structured app-server protocol instead of fragile terminal rendering.
18. As a Codex mobile user, I want the app to avoid exposing app-server ports, so that SSH remains the only network entry point.
19. As a Codex mobile user, I want to see my Codex workspaces grouped by project, so that I can resume work from the project context I care about.
20. As a Codex mobile user, I want to switch to a time-ordered session list, so that I can quickly find the most recent conversation regardless of project.
21. As a Codex mobile user, I want workspace grouping to come from `Thread.cwd`, so that the app reflects the same session state Codex already records.
22. As a Codex mobile user, I want each workspace to show recent activity, so that I can decide which project to open.
23. As a Codex mobile user, I want each workspace to show recent preview text, so that I can recognize what I was doing.
24. As a Codex mobile user, I want each workspace to show session count, so that I can understand how active that workspace is.
25. As a Codex mobile user, I want each workspace to show `gitInfo` when available, so that I can recognize branch and repository context.
26. As a Codex mobile user, I want an empty-state directory browser on new hosts, so that I can create the first Codex session even when no history exists.
27. As a Codex mobile user, I want the directory browser to start from remote home, so that I do not need to scan the entire filesystem.
28. As a Codex mobile user, I want to manually enter an absolute path, so that advanced VPS layouts are still reachable.
29. As a Codex mobile user, I want to create a remote directory from the app, so that I can start a new workspace without leaving iOS.
30. As a Codex mobile user, I want directory creation to support recursive creation, so that paths like `~/Projects/new-app` work in one operation.
31. As a Codex mobile user, I want to select a `cwd` and start a new Codex thread there, so that new workspaces become part of the normal Codex session list.
32. As a Codex mobile user, I want to open an existing session and see its prior turns, so that I do not continue blindly.
33. As a Codex mobile user, I want session details to use `thread/read(includeTurns: true)`, so that the app follows official persisted history behavior.
34. As a Codex mobile user, I want to continue an existing session with `thread/resume`, so that Codex restores the right runtime settings before a new turn starts.
35. As a Codex mobile user, I want to send a new prompt with `turn/start`, so that I can keep working from iPhone.
36. As a Codex mobile user, I want streamed assistant messages, so that I can see progress while Codex responds.
37. As a Codex mobile user, I want streamed command output, so that I can understand what Codex is running remotely.
38. As a Codex mobile user, I want file change summaries and diffs, so that I can review edits from the phone.
39. As a Codex mobile user, I want a stop button while a turn is running, so that I can interrupt accidental or long-running work.
40. As a Codex mobile user, I want interruption to call `turn/interrupt`, so that remote Codex receives a real cancellation request.
41. As a Codex mobile user, I want the input bar to look and behave like official iOS Codex, so that the experience feels familiar.
42. As a Codex mobile user, I want a `+` menu, so that planning mode, camera, files, and attachment actions are discoverable.
43. As a Codex mobile user, I want the permission shield menu, so that I can choose the risk level before sending work.
44. As a Codex mobile user, I want the model display in the input bar, so that I know what remote Codex is using even if I cannot change it in v1.
45. As a Codex mobile user, I want the microphone to perform speech-to-text, so that I can dictate prompts on mobile.
46. As a Codex mobile user, I want speech input to fill the prompt box, so that I can edit it before sending.
47. As a Codex mobile user, I want camera capture to attach an image to a Codex turn, so that I can ask Codex about screenshots, errors, or physical context.
48. As a Codex mobile user, I want file picking to upload files to the remote host, so that Codex can inspect them in the remote environment.
49. As a Codex mobile user, I want uploaded images to be sent as `UserInput.localImage`, so that Codex can process them as image input.
50. As a Codex mobile user, I want uploaded files to be referenced by remote path, so that Codex can read or manipulate them on the host.
51. As a Codex mobile user, I want attachment files placed in a client-owned remote directory, so that uploads do not pollute project directories.
52. As a Codex mobile user, I want attachment upload to use `fs/writeFile`, so that it stays aligned with app-server protocol.
53. As a Codex mobile user, I want `Documents` and `Spreadsheets` entries treated as ordinary files in v1, so that the UI remains familiar without pretending to support full plugin workflows.
54. As a Codex mobile user, I want a permission mode for remote defaults, so that I can rely on the host's existing Codex configuration.
55. As a Codex mobile user, I want a permission mode for automatic review, so that Codex can auto-review permission requests where supported.
56. As a Codex mobile user, I want a permission mode for full access, so that I can intentionally allow high-trust tasks on my own machines.
57. As a Codex mobile user, I want full access to show clear risk language, so that I do not enable it accidentally.
58. As a Codex mobile user, I want a custom `config.toml` option, so that remote Codex can use its own configured permission profile.
59. As a Codex mobile user, I want command execution approvals, so that unsafe or sensitive commands do not run without my consent.
60. As a Codex mobile user, I want file change approvals, so that edits are reviewable before acceptance where required.
61. As a Codex mobile user, I want permissions request approvals, so that escalations can be handled without leaving the mobile app.
62. As a Codex mobile user, I want approval actions like `accept`, `acceptForSession`, `decline`, and `cancel`, so that I can respond using protocol-supported choices.
63. As a Codex mobile user, I want plan mode, so that Codex can reason in planning workflow before implementation.
64. As a Codex mobile user, I want plan mode implemented through official protocol settings, so that the app does not rely on brittle prompt prefixes.
65. As a Codex mobile user, I want unsupported plan mode to be disabled with explanation, so that protocol/version limitations are clear.
66. As a Codex mobile user, I want the app to reconnect after foregrounding, so that I can return to a long-running session.
67. As a Codex mobile user, I want remote Codex state to be the source of truth, so that iPhone and iPad see the same conversations when they connect to the same host.
68. As a Codex mobile user, I want Host Profile config to remain local in v1, so that SSH secrets are not synced before a proper security model exists.
69. As a Codex mobile user, I want the app to work on iPhone first, so that the primary mobile pain point is solved quickly.
70. As a Codex mobile user, I want the app to run on iPad without special optimization, so that it remains usable on larger screens while iPhone remains the priority.

## Implementation Decisions

- 构建 `Host Profile` module，封装 host、port、username、auth type、Codex path、startup command、default directory、known host fingerprint 和 Keychain reference。它应该提供简单稳定的 CRUD interface，内部隐藏凭据存储和 host key 状态细节。
- 构建 SSH connection module，负责 password/key 认证、host key verification、远端命令启动、stdin/stdout byte stream 暴露和断线状态。该 module 的外部 interface 应只暴露连接生命周期和双向 byte stream，不让 UI 直接处理底层 SSH 细节。
- 构建 App Server JSON-RPC client module，运行在 SSH stream 之上，负责 request id、response matching、server notification、server request 和初始化握手。它是一个 deep module，因为它把协议同步、异步事件、错误映射封装在稳定 interface 后面。
- 构建 Codex protocol facade module，对 UI 暴露高层操作：`initialize`、`thread/list`、`thread/read`、`thread/resume`、`thread/start`、`turn/start`、`turn/interrupt`、`fs/readDirectory`、`fs/getMetadata`、`fs/createDirectory`、`fs/writeFile`、审批响应。UI 不直接拼 JSON-RPC payload。
- 构建 Workspace index module，从 `thread/list` 的 `Thread.cwd` 聚合 workspace，并支持“按项目分组”和“按时间顺序”两种 projection。它不扫描全盘文件系统；文件系统浏览只作为空状态和选择新 `cwd` 的辅助。
- 构建 Remote file browser module，封装远端目录读取、metadata 读取、绝对路径跳转、错误显示和 recursive create directory。默认入口是远端 home 和历史 workspace，不默认从 `/` 全盘浏览。
- 构建 Session store/view model module，管理 thread list pagination、session detail loading、`thread/resume -> turn/start` 生命周期、streamed item 合并、running/interrupting/completed 状态。
- 构建 Attachment upload module，负责相机/文件数据进入 App 后通过 `fs/createDirectory` / `fs/writeFile` 写入远端客户端私有目录，并为图片生成 `UserInput.localImage`，为普通文件生成远端路径引用。远端目录是客户端实现细节，不声称对齐官方 iOS 私有目录。
- 构建 Permission mode module，将 UI 中的 `默认权限`、`自动审核`、`完全访问权限`、`自定义 (config.toml)` 映射到当前 Codex app-server 支持的 permissions / approval 配置。权限字段存在 experimental 风险，因此该 module 需要集中处理版本兼容和降级提示。
- 构建 Approval workflow module，处理 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`、`item/permissions/requestApproval`，并向 UI 提供命令、路径、diff、原因、风险和可选 action。
- 构建 Diagnostics module，顺序检查 SSH、`codex --version`、`codex app-server daemon start`、`codex app-server proxy --help`、`initialize` handshake、`cliVersion` / `appServerVersion`，并把失败归类为可操作的用户提示。
- 构建 Input composer module，封装官方风格输入栏状态：文本、附件、权限模式、计划模式、模型显示、语音转文字、send/stop button state。
- 第一版不开放模型选择器。新建和继续会话沿用远端默认 Codex 配置，UI 只显示当前模型信息。后续可基于 `model/list` 和 `modelProvider/capabilities/read` 增加高级设置。
- 第一版支持 `计划模式`，但必须通过官方协议能力实现，不用 prompt 前缀模拟。如果远端版本不支持，则禁用 UI 并提示升级或不支持。
- 第一版不提供 TUI fallback。如果 `codex app-server proxy` 不存在或无法握手，诊断页提示升级远端 Codex CLI。
- 第一版不做可靠后台推送。App 回到前台后通过 `thread/list` / `thread/read` 恢复状态。
- 第一版不做 iCloud 同步 Host Profile / 凭据。会话同步来自远端 Codex state；Host 配置和凭据保存在本机。
- 第一版最低兼容 `codex-cli >= 0.133.0`，高版本允许尝试但提示未经验证。

## Testing Decisions

- 测试应覆盖外部行为，而不是实现细节。重点断言输入事件、协议响应、远端错误、断线重连和 UI-visible state 的结果，不断言内部私有函数调用顺序。
- SSH connection module 需要用 fake SSH server 或 protocol-level test double 测试认证成功、认证失败、host key 首次确认、host key 变化阻断、远端命令启动失败、stdio 断开。
- JSON-RPC client module 需要用 in-memory byte stream 测试 request/response matching、notification dispatch、server request dispatch、invalid JSON、unknown id、connection close。
- Codex protocol facade module 需要用 fake JSON-RPC transport 测试每个高层方法生成的 method/params，以及错误映射是否稳定。
- Workspace index module 需要纯单元测试：从多条 `Thread` 输入聚合 workspace、排序、按 `cwd` 过滤、处理 missing `gitInfo`、处理相同时间戳、处理空列表。
- Remote file browser module 需要用 fake Codex protocol facade 测试 home 起步、手动绝对路径、permission denied、recursive directory creation、metadata 区分文件/目录。
- Session store/view model module 需要测试 `thread/read(includeTurns: true)`、`thread/resume -> turn/start` 顺序、streamed delta 合并、`turn/interrupt` 状态转换、turn failure 显示。
- Attachment upload module 需要测试相机图片写入远端路径、普通文件写入远端路径、base64 编码、目录创建失败、文件写入失败、图片生成 `UserInput.localImage`。
- Permission mode module 需要测试四种 UI 权限模式到协议参数的映射，并测试版本不支持时的禁用/错误提示。
- Approval workflow module 需要测试 command/file/permissions 三类 requestApproval 显示内容和 action response。
- Diagnostics module 需要端到端 fake 流程测试：SSH 失败、Codex 缺失、版本过低、daemon 启动失败、proxy 不支持、initialize 失败、全部通过。
- Input composer module 需要 UI state 测试：空输入禁用发送、运行中显示停止、附件存在时允许发送、语音转文字写入输入框、计划模式开关状态。
- 第一版如果建立 SwiftUI 项目，应增加关键 UI snapshot 或 view-state tests，覆盖 workspace 切换、输入栏菜单、权限菜单、审批弹层、诊断错误状态。
- 对真实远端 Codex 的集成测试应作为手动或 gated 测试，不应依赖开发者本机 `~/.codex` 状态在普通 CI 中稳定存在。

## Out of Scope

- 不实现 OpenAI secure relay。
- 不复刻 ChatGPT 通用聊天、账号体系、GPTs、插件商店。
- 不暴露 app-server WebSocket 或 Unix socket 到公网。
- 不新增 Mac/VPS 端自研 daemon。
- 不解析 Codex TUI，不支持 TUI fallback。
- 不自行解析 rollout JSONL 补全历史。
- 不承诺无后端情况下的 APNs 完成推送。
- 不做长时间后台 SSH 保活。
- 不做 iCloud Host Profile / 凭据同步。
- 不做官方 ChatGPT Documents / Spreadsheets 插件级编辑能力；第一版只按普通文件处理。
- 不做完整 iPadOS 优化；iPad 可运行但 iPhone 优先。
- 不开放模型/provider/service tier 选择器。
- 不支持 `thread/realtime/start` 实时语音对话；麦克风只做语音转文字。

## Further Notes

- 当前本地项目目录还不是 git repo，且 `gh auth status` 显示 GitHub token 已失效。因此本 PRD 已先写成本地文档，暂未能发布到 GitHub Issues。
- 计划发布到 GitHub Issue 时，应使用标题：`PRD: Codex Port MVP`。
- 发布时应应用 `ready-for-agent` label。
- 当前已有更早的合并版文档，包含 PRD / 技术方案 / MVP 开发切片；本文件是按 `to-prd` 模板整理后的 issue-ready PRD。
- 后续拆 issue 时，建议按 deep module 和 MVP slice 拆分，避免把整个 iOS App 作为一个不可并行的大任务。
