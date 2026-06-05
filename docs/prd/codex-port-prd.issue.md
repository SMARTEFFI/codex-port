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

1. 作为 Codex 移动端用户，我想通过 SSH 将 iPhone 直接连接到我的 Mac，以便不用打开 ChatGPT iOS App 就能使用 Codex。
2. 作为 Codex 移动端用户，我想通过 SSH 连接公网 VPS，以便在已经能从互联网访问的远端机器上使用 Codex。
3. 作为 Codex 移动端用户，我想在可用时使用 Tailscale 或 LAN SSH，以便避免把本地机器暴露到公网。
4. 作为 Codex 移动端用户，我想创建多个 Host Profile，以便在 Mac、VPS 和其他 Linux hosts 之间切换。
5. 作为 Codex 移动端用户，我想编辑 Host Profile，以便更新 host、port、username、auth method 或 Codex command path。
6. 作为 Codex 移动端用户，我想删除 Host Profile，以便 app 中不保留过期的远端目标。
7. 作为 Codex 移动端用户，我想用 SSH password 登录，以便 app 像官方 iOS Codex 连接流程一样工作。
8. 作为 Codex 移动端用户，我想用 SSH key 登录，以便使用更强、更适合自动化的认证方式。
9. 作为 Codex 移动端用户，我想把已保存 password 放在 Keychain 中，以便凭据不会以明文存储。
10. 作为 Codex 移动端用户，我想用 Face ID 或设备解锁保护已保存凭据，以便普通设备访问不会暴露远端 SSH 权限。
11. 作为 Codex 移动端用户，我想在首次连接时确认 host key fingerprint，以便避免连接到被冒充的 host。
12. 作为 Codex 移动端用户，我想在 host key 变化时收到警告，以便阻止潜在不安全连接。
13. 作为 Codex 移动端用户，我想使用连接诊断页，以便判断失败来自 SSH、PATH、Codex version、daemon startup 还是 protocol handshake。
14. 作为 Codex 移动端用户，我想让 app 检查 `codex --version`，以便知道 remote host 是否兼容。
15. 作为 Codex 移动端用户，我想让 app 检查 `codex app-server proxy --help`，以便不受支持的 remote Codex versions 能清晰失败。
16. 作为 Codex 移动端用户，我想让 app 自动运行 `codex app-server daemon start`，以便每次连接前不需要手动准备 remote app-server。
17. 作为 Codex 移动端用户，我想让 app 通过 `codex app-server proxy` 连接，以便使用结构化 app-server protocol，而不是脆弱的 terminal rendering。
18. 作为 Codex 移动端用户，我想避免暴露 app-server ports，以便 SSH 仍是唯一网络入口。
19. 作为 Codex 移动端用户，我想按项目查看分组后的 Codex workspaces，以便从关心的 project context 恢复工作。
20. 作为 Codex 移动端用户，我想切换到按时间排序的会话列表，以便不考虑项目也能快速找到最近对话。
21. 作为 Codex 移动端用户，我想让 workspace grouping 来自 `Thread.cwd`，以便 app 反映 Codex 已记录的同一份 session state。
22. 作为 Codex 移动端用户，我想让每个 workspace 显示最近活动，以便判断要打开哪个项目。
23. 作为 Codex 移动端用户，我想让每个 workspace 显示最近 preview text，以便识别之前在做什么。
24. 作为 Codex 移动端用户，我想让每个 workspace 显示 session count，以便了解该 workspace 的活跃程度。
25. 作为 Codex 移动端用户，我想在可用时显示每个 workspace 的 `gitInfo`，以便识别 branch 和 repository context。
26. 作为 Codex 移动端用户，我想在新 host 上看到 empty-state directory browser，以便即使没有历史也能创建第一条 Codex session。
27. 作为 Codex 移动端用户，我想让 directory browser 从 remote home 开始，以便不需要扫描整个 filesystem。
28. 作为 Codex 移动端用户，我想手动输入 absolute path，以便高级 VPS 布局仍可访问。
29. 作为 Codex 移动端用户，我想从 app 创建 remote directory，以便不用离开 iOS 就能开始新的 workspace。
30. 作为 Codex 移动端用户，我想让目录创建支持 recursive creation，以便 `~/Projects/new-app` 这类路径可以一次完成。
31. 作为 Codex 移动端用户，我想选择一个 `cwd` 并在那里启动新的 Codex thread，以便新 workspaces 进入正常 Codex session list。
32. 作为 Codex 移动端用户，我想打开已有 session 并看到 prior turns，以便不是盲目继续。
33. 作为 Codex 移动端用户，我想让 session details 使用 `thread/read(includeTurns: true)`，以便 app 遵循官方 persisted history behavior。
34. 作为 Codex 移动端用户，我想用 `thread/resume` 继续已有 session，以便 Codex 在开始新 turn 前恢复正确 runtime settings。
35. 作为 Codex 移动端用户，我想用 `turn/start` 发送新 prompt，以便从 iPhone 继续工作。
36. 作为 Codex 移动端用户，我想看到 streamed assistant messages，以便在 Codex 回复时看到进度。
37. 作为 Codex 移动端用户，我想看到 streamed command output，以便理解 Codex 正在远端运行什么。
38. 作为 Codex 移动端用户，我想看到 file change summaries 和 diffs，以便在手机上 review edits。
39. 作为 Codex 移动端用户，我想在 turn running 时看到 stop button，以便中断误触或长时间运行的工作。
40. 作为 Codex 移动端用户，我想让中断调用 `turn/interrupt`，以便 remote Codex 收到真实 cancellation request。
41. 作为 Codex 移动端用户，我想让 input bar 外观和行为接近官方 iOS Codex，以便体验熟悉。
42. 作为 Codex 移动端用户，我想有一个 `+` menu，以便 planning mode、camera、files 和 attachment actions 可被发现。
43. 作为 Codex 移动端用户，我想使用 permission shield menu，以便发送任务前选择风险级别。
44. 作为 Codex 移动端用户，我想在 input bar 中看到 model display，以便即使 v1 不能修改，也知道 remote Codex 正在使用什么。
45. 作为 Codex 移动端用户，我想让 microphone 执行 speech-to-text，以便在移动端口述 prompts。
46. 作为 Codex 移动端用户，我想让 speech input 填入 prompt box，以便发送前还能编辑。
47. 作为 Codex 移动端用户，我想用 camera capture 给 Codex turn 附加 image，以便向 Codex 询问 screenshots、errors 或现实环境信息。
48. 作为 Codex 移动端用户，我想用 file picking 上传文件到 remote host，以便 Codex 能在远端环境检查它们。
49. 作为 Codex 移动端用户，我想把 uploaded images 作为 `UserInput.localImage` 发送，以便 Codex 能按 image input 处理。
50. 作为 Codex 移动端用户，我想用 remote path 引用 uploaded files，以便 Codex 能在 host 上读取或操作它们。
51. 作为 Codex 移动端用户，我想把 attachment files 放在 client-owned remote directory 中，以便 uploads 不污染 project directories。
52. 作为 Codex 移动端用户，我想让 attachment upload 使用 `fs/writeFile`，以便与 app-server protocol 对齐。
53. 作为 Codex 移动端用户，我想在 v1 中把 `Documents` 和 `Spreadsheets` entries 当作普通文件处理，以便 UI 熟悉但不假装支持完整 plugin workflows。
54. 作为 Codex 移动端用户，我想使用 remote defaults 的 permission mode，以便依赖 host 现有 Codex configuration。
55. 作为 Codex 移动端用户，我想使用 automatic review 的 permission mode，以便在支持时让 Codex 自动 review permission requests。
56. 作为 Codex 移动端用户，我想使用 full access 的 permission mode，以便在自己的机器上有意允许高信任任务。
57. 作为 Codex 移动端用户，我想让 full access 显示清晰风险文案，以便不会误启用。
58. 作为 Codex 移动端用户，我想使用自定义 `config.toml` option，以便 remote Codex 使用自己的 configured permission profile。
59. 作为 Codex 移动端用户，我想处理 command execution approvals，以便不经同意不会运行不安全或敏感命令。
60. 作为 Codex 移动端用户，我想处理 file change approvals，以便在需要时先 review edits 再接受。
61. 作为 Codex 移动端用户，我想处理 permissions request approvals，以便不用离开 mobile app 也能处理 escalation。
62. 作为 Codex 移动端用户，我想使用 `accept`、`acceptForSession`、`decline` 和 `cancel` 等 approval actions，以便用 protocol-supported choices 响应。
63. 作为 Codex 移动端用户，我想使用 plan mode，以便 Codex 在 implementation 前按 planning workflow 推理。
64. 作为 Codex 移动端用户，我想通过官方 protocol settings 实现 plan mode，以便 app 不依赖脆弱的 prompt prefixes。
65. 作为 Codex 移动端用户，我想在 plan mode 不受支持时看到 disabled 状态和说明，以便 protocol/version 限制清晰。
66. 作为 Codex 移动端用户，我想让 app 前台恢复后重新连接，以便回到 long-running session。
67. 作为 Codex 移动端用户，我想以 remote Codex state 为 source of truth，以便 iPhone 和 iPad 连接同一 host 时看到相同 conversations。
68. 作为 Codex 移动端用户，我想让 Host Profile config 在 v1 保持本地，以便在形成适当 security model 前不同步 SSH secrets。
69. 作为 Codex 移动端用户，我想让 app 优先服务 iPhone，以便快速解决主要 mobile pain point。
70. 作为 Codex 移动端用户，我想让 app 在 iPad 上无需专项优化也能运行，以便在大屏可用，同时保持 iPhone 优先。

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
