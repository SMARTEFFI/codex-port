# PRD: Relay Host 可进入态、Pairing QR、结构化会话内容与图片预览

## Problem Statement

用户已经可以通过 `Direct SSH Connection` 和 `Relay Connection` 进入 CodexPort，但当前下一阶段体验存在几个断点。

`Direct SSH Connection` 与 `Relay Connection` 的边界容易被混淆：Direct SSH 是稳定的 SSH + stdio app-server baseline，不应被拉入 P2P 或 realtime sync 改造；实时多端同步、HostAgent、WebRTC/TURN 和 `Client-Host Session Protocol` 都属于 Relay 方向。

`Relay Host` 列表当前把 HostAgent presence 直接显示成“在线”。这会误导用户：presence 可达只代表 signaling 层可达，不代表 DataChannel、Host protocol 和 thread list 已经 ready。用户点击“在线”后看到的是连接日志和读取会话列表的过程，而不是直接进入可用的会话列表。

Pairing QR 体验也不顺：扫码按钮在表单里的位置不够清晰，且 scanner 当前需要用户点一下 QR 识别结果才会填入配对码。用户预期是扫到合法 Pairing QR 后自动填入，但仍由用户点击保存时才真正 consume 一次性 `Pairing Token`。

会话内容页当前把用户消息当成纯文本处理。`$ mention` 只能表现为普通文本，图片附件在发送前是结构化附件，发出和恢复历史后则退化成 markdown/path 或文本。这导致三个问题：skill mention 无法稳定渲染和存储，图片无法直接预览，点击图片后的全屏预览/左右切换/保存相册也缺少可靠 source of truth。

图片 path 还可能来自桌面端本地路径，例如 Mac 上的图片文件。iOS 不能假设 path 是本机缓存，也不能任意解析 assistant markdown 并读取远端文件；需要明确的结构化附件和远端图片读取边界。

## Solution

本迭代把 `Relay Connection` 的用户可见状态、配对入口和会话内容模型提升到可交给 AFK agent 实现的规格。

`Direct SSH Connection` 保持现有 baseline：iOS 通过 SSH 连接用户自己的 Mac/VPS/Linux host，并启动独立 app-server stdio transport。它不是 `P2P-first Remote Connection`，也不承诺 `Real-time Multi-Device Sync`。

`Relay Host` 列表改用用户可见的 `Relay Host Readiness`。HostAgent presence 仍保留为技术状态，但列表里的“在线”只在用户已经可以进入会话列表时显示。读取会话列表时显示 loading/readiness 状态，失败时显示可操作错误，不再用日志抽屉作为 Relay 正常连接流程。

Pairing QR 表单把扫码按钮放在 `配对` section 标题下方的主入口位置。scanner 识别到合法 `codexport://pair?token=...` 或短码后自动填入 `pairingMaterial` 并关闭 scanner；保存按钮才发起 pairing consume。

会话内容页引入 `Structured User Message`：用户消息结构化保存正文、`Skill Mention` 和 `Message Attachment`。UI/本地状态以结构化模型为准；发送到 Codex protocol 时再映射为当前支持的 text input 和 `TurnAttachment`。

`Skill Mention` 第一版采用官方 Codex 风格的附件胶囊，而不是可编辑 inline rich text。用户输入 `$tri` 时出现 suggestion，选择后从输入框移除 `$tri`，在 composer chip strip 显示 `Triage ×`。发送后 transcript 用户气泡顶部也显示 skill chip，正文只显示用户实际输入。

图片附件第一版以结构化 `Message Attachment` 为 source of truth。图片 source 可以是 iPhone 本地缓存，也可以是远端 host path。iOS 有本地 data 时直接预览；只有远端 host path 时显示占位，用户打开或图片进入视口时通过 HostAgent/remote file boundary 拉取、缓存，再用于缩略图、全屏 gallery 和保存相册。

## User Stories

1. As a CodexPort iOS 用户, I want `Direct SSH Connection` 保持稳定的 SSH baseline, so that 现有直连工作流不会被 Relay/P2P 改造影响。
2. As a CodexPort iOS 用户, I want Relay 的实时能力只进入 `Relay Connection`, so that 我能清楚知道哪些 Host 支持 HostAgent、多端同步和 P2P。
3. As a CodexPort iOS 用户, I want Host 列表中的“在线”代表会话列表已经可进入, so that 我点击后直接看到工作区和会话。
4. As a CodexPort iOS 用户, I want HostAgent presence 和用户可进入态不要混在一起, so that 我不会把 signaling 可达误认为会话 ready。
5. As a CodexPort iOS 用户, I want Relay Host 读取会话列表时显示 loading 状态, so that 我知道它正在建立 DataChannel 或等待 HostAgent 返回 threads。
6. As a CodexPort iOS 用户, I want Relay Host 读取会话失败时看到简洁错误, so that 我能知道是 HostAgent、Pairing、version、transport 还是 thread list timeout。
7. As a CodexPort iOS 用户, I want Relay 正常连接流程不弹出日志抽屉, so that Host 列表体验更像普通 app 而不是调试工具。
8. As a CodexPort iOS 用户, I want Direct SSH 仍保留连接日志和 host key 确认流程, so that SSH 诊断和首次 trust 仍然清晰。
9. As a CodexPort iOS 用户, I want Relay Host row 在不可进入时不可误点进入空列表, so that 我不会被带到失败的 workspace 页面。
10. As a CodexPort iOS 用户, I want Relay Host ready 后缓存会话列表首屏, so that 返回 Host 列表再进入时不需要重复等待。
11. As a CodexPort iOS 用户, I want 前台恢复时 Relay Host 可以刷新 readiness, so that Mac 睡眠、网络切换或 HostAgent 重启后状态会更新。
12. As a CodexPort iOS 用户, I want Relay Host loading 状态显示具体阶段, so that 我知道是在 signaling、DataChannel、Host protocol 还是读取 thread list。
13. As a CodexPort iOS 用户, I want Pairing QR 按钮放在配对区域最显眼位置, so that 我知道应该扫码而不是手动输入长 token。
14. As a CodexPort iOS 用户, I want 扫到 Pairing QR 后自动填入配对内容, so that 我不需要点识别框。
15. As a CodexPort iOS 用户, I want 扫码后不自动 consume Pairing Token, so that 我仍可确认 Host 名称、设备名称、codexPath 和 defaultDirectory。
16. As a CodexPort iOS 用户, I want scanner 自动关闭并回到表单, so that 我可以马上检查已填内容。
17. As a CodexPort iOS 用户, I want 无效 QR 不覆盖已有配对码, so that 误扫不会破坏表单。
18. As a CodexPort iOS 用户, I want DataScanner 不可用时仍可手动输入短码, so that 老设备或权限受限设备仍能配对。
19. As a CodexPort iOS 用户, I want `$` 输入后看到 skill suggestions, so that 我可以快速选择 agent skill。
20. As a CodexPort iOS 用户, I want 选择 `triage` 后看到 `Triage` 胶囊, so that skill mention 视觉上不再只是普通 `$triage` 文本。
21. As a CodexPort iOS 用户, I want 删除 skill chip, so that 我可以撤销误选的 skill。
22. As a CodexPort iOS 用户, I want skill chip 不占用输入框正文, so that 我的 prompt 文本保持可读。
23. As a CodexPort iOS 用户, I want 发送后的用户气泡显示 skill chip, so that 我能回看本轮用了哪个 skill。
24. As a CodexPort iOS 用户, I want 内部保留 skill identifier/display name, so that 后续 protocol adapter 可以稳定生成 Codex 需要的 mention 格式。
25. As a CodexPort iOS 用户, I want 普通 `$` 文本不被误当成 skill, so that shell/env 文本可以正常输入。
26. As a CodexPort iOS 用户, I want skill suggestion 能处理部分输入, so that `$tri` 可以匹配 `triage`。
27. As a CodexPort iOS 用户, I want skill mention 和图片附件可以同时存在, so that 我可以带着截图让特定 skill 工作。
28. As a CodexPort iOS 用户, I want 用户消息不再只是纯文本, so that mention 和附件可以在历史中稳定恢复。
29. As a CodexPort iOS 用户, I want 发送图片后在 transcript 里看到缩略图, so that 我能确认自己发送了哪张图。
30. As a CodexPort iOS 用户, I want 点击图片后进入全屏预览, so that 我能检查图片细节。
31. As a CodexPort iOS 用户, I want 全屏预览左右滑动切换上/下一张, so that 多图消息可以快速查看。
32. As a CodexPort iOS 用户, I want 全屏预览里有保存按钮, so that 我可以把图片保存到手机相册。
33. As a CodexPort iOS 用户, I want 保存相册时看到成功或失败反馈, so that 我知道系统权限是否允许。
34. As a CodexPort iOS 用户, I want app 声明保存相册权限用途, so that iOS 权限提示清晰。
35. As a CodexPort iOS 用户, I want 本地已缓存图片离线也能预览, so that 不必每次都访问 Mac。
36. As a CodexPort iOS 用户, I want 远端 host path 图片可以按需拉取, so that 桌面端本地图片也能在 iPhone 上预览。
37. As a CodexPort iOS 用户, I want 远端图片拉取失败时看到不可用占位, so that app 不会空白或崩溃。
38. As a CodexPort iOS 用户, I want 远端图片拉取有大小限制, so that 误读大文件不会卡住 app。
39. As a CodexPort iOS 用户, I want 只有图片类型会被当成图片预览, so that 任意远端文件 path 不会被误读。
40. As a CodexPort iOS 用户, I want markdown image 只作为兼容输入, so that 旧历史可尽量显示但新模型不依赖 markdown。
41. As a CodexPort iOS 用户, I want assistant markdown 里的任意 path 不会自动读取, so that app 不会意外读取敏感或巨大文件。
42. As a CodexPort iOS 用户, I want 远端 path 来源在 UI 中可区分, so that 我知道图片来自本机缓存还是 Mac。
43. As a CodexPort iOS 用户, I want 多设备 Relay session 中图片附件仍能显示, so that iPhoneA 发送的图片 iPhoneB 也有可恢复路径。
44. As a CodexPort iOS 用户, I want 图片缓存不暴露到 Relay 服务端, so that Relay 仍不保存 prompt/附件明文。
45. As a CodexPort iOS 用户, I want 图片预览遵循当前 Pairing 授权, so that revoked device 无法继续通过 HostAgent 拉图。
46. As a CodexPort iOS 用户, I want attachment preview 不影响 Codex turn/start payload 兼容性, so that 远端 Codex 仍收到当前支持的 image/file input。
47. As a developer, I want `Structured User Message` 有独立模型, so that UI、storage 和 protocol adapter 不再互相绑死。
48. As a developer, I want `Skill Mention` 有稳定 identifier, so that 文本展示变化不会破坏发送语义。
49. As a developer, I want `Message Attachment` source 显式建模, so that local cache、remote host path 和 unavailable 可以分开处理。
50. As a developer, I want 图片读取通过明确 file content boundary, so that 不需要在 UI 中拼接 remote fs 细节。
51. As a developer, I want tests 覆盖 readiness、QR、mention、attachment 和 gallery 外部行为, so that 后续 agent 可以安全拆分实现。
52. As a product owner, I want 这些 UX 改进按 vertical slices 实现, so that 每个 PR 都能独立验证并减少回归面。

## Implementation Decisions

- `Direct SSH Connection` 不升级成 P2P，也不承诺 `Real-time Multi-Device Sync`。本 PRD 的实时性和 readiness 工作只适用于 `Relay Connection`。
- 保留 `RelayHostPresence` 作为 signaling/HostAgent 可达的技术状态，不把它直接映射为 Host 列表的“在线”。
- 引入用户可见的 `Relay Host Readiness`。只有 DataChannel/Host protocol 可用且 thread list 首屏加载完成后，Host 列表才显示“在线”。
- Relay Host 正常连接不再使用日志抽屉作为主体验。连接过程应通过 row/loading/inline 状态表达；错误通过可操作 row state 或 alert 表达。
- `ConnectionLogSheet` 可以继续服务 `Direct SSH Connection` 的 SSH preflight、host key trust 和诊断流程。
- Relay Host readiness 应覆盖至少四类用户状态：读取中、在线、离线、连接失败/需要处理。
- Relay thread list 加载成功后应更新 workspace/session projection，并允许点击 Host row 直接进入 workspace list。
- Pairing QR scanner 识别合法 payload 后自动填入 pairing material 并关闭 scanner。
- Pairing QR scanner 不自动 consume token；只有用户点击保存时才执行 pairing consume。
- Pairing form 的扫码按钮应作为 `配对` section 的主入口，而不是埋在输入框之后。
- Scanner 应从识别事件自动读取 QR payload，而不是只响应用户 tap。
- 用户消息模型升级为 `Structured User Message`，包含正文、`Skill Mention` 和 `Message Attachment`。
- 发送到 Codex protocol 时，`Structured User Message` 由 adapter 映射为当前支持的 text input 和 `TurnAttachment`。UI/本地状态不能依赖 markdown 作为 source of truth。
- `Skill Mention` 第一版采用附件胶囊式 UI，不实现可编辑 inline rich text token。
- 选择 skill 后，从输入文本中移除 `$query`，在 chip strip 中显示 skill chip，并保留 skill identifier/display name。
- Transcript 用户气泡应渲染 skill chips 和附件 previews；正文只显示用户实际输入文本。
- 普通 `$` 文本只有在用户从 suggestion 中选择后才成为 `Skill Mention`。
- `Message Attachment` 应显式区分 local cache、remote host path 和 unavailable source。
- 图片预览以结构化 `Message Attachment` 为准；markdown image 只用于兼容旧历史，不能作为长期模型。
- 远端 host path 可能是 Mac/desktop 本地路径。iOS 应通过 HostAgent/remote file content boundary 按需拉取图片 bytes，并缓存到 iPhone app container。
- 远端图片读取必须限制文件类型和大小。第一版只支持常见图片类型，超过大小上限或类型不明时显示不可用。
- 不自动读取 assistant markdown 中的任意 path。只有结构化 attachment 或用户明确触发的兼容解析才进入远端图片读取流程。
- 全屏 gallery 使用结构化图片附件数组作为数据源，支持左右切换和保存当前图片到 Photos。
- 保存相册需要补充只写相册用途说明，并对权限/失败给出用户可见反馈。
- Relay 服务端仍不保存、不解析图片内容。图片内容读取通过已授权的 client-host path 完成。

## Testing Decisions

- 测试只覆盖外部行为和用户可见状态，不断言私有函数调用顺序。
- `HostProfileRowPresentation` / Host list view-state tests 应覆盖 Relay presence online 但 readiness 未完成时不显示“在线”，readiness 完成后才显示“在线”。
- App connection state tests 应覆盖 Relay thread list loading、success、timeout、transport unavailable、version/pairing failure 到 readiness 状态的映射。
- Workspace navigation tests 应覆盖 Relay Host ready 后点击直接进入 workspace，未 ready 时不进入空 workspace。
- Direct SSH regression tests 应确认 SSH 连接日志、host key confirmation 和 diagnostics sheet 仍然保留。
- Pairing form view-state tests 应覆盖扫码按钮位置、scanner unsupported fallback、自动填入、无效 QR 不覆盖已有值、保存时才 consume token。
- Scanner wrapper tests 应通过 delegate/coordinator seam 覆盖 recognized QR 自动触发 onMaterial，不依赖 tap。
- `Structured User Message` model tests 应覆盖纯文本、单 skill、多 skill、图片、文件、skill + 图片组合、普通 `$` 文本。
- Composer state tests 应覆盖 `$query` suggestion、选择 skill 后 chip 出现、文本 query 被移除、删除 chip、发送 payload 保留 mention 结构。
- Protocol adapter tests 应覆盖 structured message 降级为现有 text input + `TurnAttachment`，确保不破坏现有 turn/start 与 turn/steer。
- Transcript presentation tests 应覆盖用户气泡渲染 skill chips、图片 thumbnails、正文和 copy payload。
- Attachment source tests 应覆盖 local cache、remote host path、unavailable 三种 source。
- Image fetch boundary tests 应覆盖只允许图片类型、大小限制、远端读取失败、缓存成功、缓存命中不重复读取。
- Gallery view-state tests 应覆盖打开指定图片、左右切换、关闭、保存当前图片、保存失败提示。
- Photos save tests 应覆盖权限描述存在、保存成功 callback、权限失败/系统失败 callback。
- Relay/P2P tests 应覆盖远端图片读取要求 active Pairing/authorized Client-Host path；revoked device 不能继续读取。
- 兼容解析 tests 应覆盖旧 markdown image 可以生成 unavailable/remote-path fallback，但 assistant markdown 任意 path 不会自动读取。

## Out of Scope

- 不把 `Direct SSH Connection` 改造成 P2P。
- 不在本 PRD 中实现完整 `Real-time Multi-Device Sync` 或 #74 HITL close。
- 不重写 Codex protocol 本身；发送层继续兼容当前 text input 和 `TurnAttachment`。
- 不实现可编辑 inline rich-text mention。
- 不做完整 skill marketplace 或 skill 安装管理。
- 不让 Relay 服务保存或解析图片 bytes。
- 不自动读取 assistant markdown 中的任意本地/远端 path。
- 不支持非图片大文件的 inline preview。
- 不承诺旧历史中的所有 markdown image 都能恢复预览。
- 不实现后台持续下载、APNs 图片同步或 iCloud attachment sync。

## Further Notes

- 本 PRD 来自 `grill-with-docs` 会话中已确认的产品边界。
- 已确认术语包括 `Relay Host Presence`、`Relay Host Readiness`、`Structured User Message`、`Skill Mention` 和 `Message Attachment`。
- 建议后续拆成五个 AFK issues：Relay Host readiness、Pairing QR scanner、Structured User Message、Skill Mention chips、Image Attachment Preview。
- 当前代码已经有相近 seams：Host profile presentation、Relay thread list client、input composer、transcript presentation、pending attachment/upload、session store 和 remote file browser。实现应优先复用这些 seams。
