# Codex Port MVP PRD / 技术方案 / 开发计划

## 背景

用户希望开发一个独立 iOS 版 Codex 客户端，用于通过 SSH 连接 Mac 或 VPS 上已有的 Codex CLI / app-server。核心动机是绕开 ChatGPT iOS App 在中国使用时对 VPN 的依赖，同时继续使用远端机器上的第三方 API 配置和现有 Codex 基建。

本项目不复刻 ChatGPT 通用 App，不实现 OpenAI 账号同步、secure relay、GPTs、普通聊天或插件商店。目标是复刻官方 iOS App 中与 Codex 相关的产品体验，并以 `SSH -> codex app-server daemon start && codex app-server proxy -> JSON-RPC` 作为底层链路。

## 目标

- 提供 iPhone 优先的原生 Codex 客户端。
- 通过 SSH 连接 Mac、VPS 或 Linux host。
- 不新增 Mac/VPS 端自研 daemon；只调用远端已有 Codex CLI。
- 复刻官方 iOS Codex 关键交互：项目/会话列表、输入栏、附件、权限菜单、计划模式、运行/停止、审批流。
- 支持公网 SSH 和内网/Tailscale SSH。
- 第一版以个人自用为主，但数据模型不要写死单机。

## 非目标

- 不实现 OpenAI secure relay。
- 不复刻 ChatGPT 通用聊天、账号体系、GPTs、插件商店。
- 不承诺可靠后台长连接或 APNs 完成推送。
- 不做 iCloud 同步 Host Profile / 凭据。
- 不解析 Codex TUI 输出，不提供 TUI fallback。
- 不自行解析 rollout JSONL 补全历史，只使用官方 app-server 协议返回的数据。

## 兼容性基线

第一版最低兼容 `codex-cli >= 0.133.0`。

低于该版本时提示升级。高于该版本允许尝试连接，但显示“未经验证版本”提示。原因是第一版依赖的 `app-server proxy`、`fs/writeFile`、`fs/createDirectory`、permissions、plan mode 等能力仍有 experimental 风险。

## 核心架构

```text
iOS App
  -> SSH session
  -> remote command:
       codex app-server daemon start && codex app-server proxy
  -> app-server JSON-RPC over stdio
  -> remote Codex app-server
  -> ~/.codex state + project filesystem + third-party API config
```

连接只暴露 SSH，不暴露 app-server WebSocket 或 Unix socket 到公网。

## Host Profile

第一版支持多个 `Host Profile`，用于统一表示 Mac、VPS 或 Linux host。

字段：

- `name`
- `host`
- `port`
- `username`
- `authType`: `password` / `key`
- Keychain 凭据引用
- `codexPath`: 默认 `codex`
- `startupCommand`: 默认 `codex app-server daemon start && codex app-server proxy`
- `defaultDirectory`: 默认远端 home，可连接后探测
- `knownHosts` / host key 指纹状态

必须支持新增、编辑、删除 Host Profile。

## SSH 认证

第一版支持：

- SSH key 登录
- password 登录

password 可以选择保存到 iOS Keychain，并由 Face ID 或设备解锁保护；同时保留“不保存，每次输入”选项。

公网 SSH 场景必须做 host key 校验：首次连接显示指纹确认，后续变化时阻断并警告。

## 远端诊断

第一版包含轻量诊断页，至少检查：

- SSH 连接和认证
- `codex --version`
- `codex app-server daemon start`
- `codex app-server proxy --help`
- `initialize` JSON-RPC 握手
- 当前 `cliVersion` / `appServerVersion`

诊断结果要给出明确错误和下一步建议，避免只显示底层 SSH 失败。

## Workspace / 项目列表

Workspace 主数据源来自 Codex 会话，而不是扫描远端文件系统。

规则：

- 首屏调用 `thread/list`。
- 按 `Thread.cwd` 聚合 workspace。
- 每个 workspace 显示最近更新时间、最近会话标题/preview、会话数、`gitInfo`。
- “按项目分组”视图：workspace 为一级，下面列出该 `cwd` 的会话。
- “按时间顺序”视图：直接按会话 `updatedAt` / `createdAt` 排序。
- `fs/readDirectory` 只用于浏览/选择新的 `cwd` 或空状态补充。

官方依据：

- `Thread` 协议结构包含 `cwd`。
- `thread/list` 支持 `cwd` 精确过滤。
- state DB 对 `(archived, cwd, updated_at/created_at)` 建索引。
- `app-server proxy` 只是 stdio 到 app-server control socket 的传输层，不负责 workspace 发现。

## 空状态和目录浏览

当远端没有任何 Codex 会话时，App 显示空状态，并提供“浏览远端目录并选择工作区”的入口。

目录浏览规则：

- 默认从远端 home 和历史 workspace 起步。
- 不默认展示 `/` 全盘浏览。
- 支持手动输入绝对路径。
- 权限失败时显示错误并允许返回上级。
- 支持创建目录。
- 创建目录支持多级路径，等价 `mkdir -p`。

实现接口：

- `fs/readDirectory`
- `fs/getMetadata`
- `fs/createDirectory`，`recursive: true`

选中目录后，用该目录作为 `thread/start.cwd` 创建第一条会话；创建成功后，该 `cwd` 自动进入 workspace 列表。

## 会话列表和详情

列表页使用 `thread/list` 返回的摘要。

进入会话详情时调用：

```text
thread/read(includeTurns: true)
```

继续已有会话时调用：

```text
thread/resume
turn/start
```

不自行解析 JSONL；接受官方协议历史是 lossy 的限制。

## 输入栏体验

第一版复刻官方 iOS Codex 输入栏的 Codex 相关能力：

- `+` 菜单
- 权限盾牌
- 模型显示
- 麦克风
- 发送按钮
- 运行中停止按钮

运行中监听 `turn/started`、`turn/completed`。点击停止调用 `turn/interrupt`，UI 状态显示“正在停止/已中断”。

模型选择第一版不开放。新建会话和继续会话沿用远端默认 Codex 配置；UI 只显示当前模型信息。后续可基于 `model/list` 和 `modelProvider/capabilities/read` 增加模型选择器。

## `+` 菜单和附件

第一版至少真实支持：

- 相机
- 文件

可以顺手支持照片库，但不是硬性下限。

Documents / Spreadsheets 不做官方 ChatGPT 插件级文档编辑能力；如出现入口，第一版按普通文件附件处理。

附件上传与官方 app-server 协议对齐：

- 使用 `fs/createDirectory` 创建远端目录。
- 使用 `fs/writeFile(path, dataBase64)` 写入远端文件。
- 图片输入使用 `UserInput.localImage { path }`。
- 普通文件上传后，在 prompt 中引用远端路径，或使用后续协议支持的文件输入能力。

远端目录策略由客户端定义，不能声称是官方 iOS 私有实现。推荐：

```text
~/.codex/ios-client/attachments/<thread-id>/<uuid>-filename
```

如果无法可靠确定 `codex_home`，退回：

```text
~/.codex-port/attachments/<thread-id>/<uuid>-filename
```

## 权限菜单

权限菜单必须真实改变 Codex 运行权限，而不是只改变 UI。

截图中的四项映射为：

- `默认权限`：使用远端默认配置，不显式覆盖。
- `自动审核`：启用 Codex 自动审核权限请求，对齐 app-server approval / permissions 能力。
- `完全访问权限`：对应 `danger-full-access` 或等价 permission profile，UI 明确提示风险。
- `自定义 (config.toml)`：不覆盖权限，完全使用远端 `config.toml` 定义。

权限字段存在 experimental 风险，第一版需要按当前 Codex schema 生成客户端类型，并锁定最低兼容版本。

## 审批流

第一版必须支持最小可用审批 UI，否则真实任务会卡住。

至少处理：

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`

UI 展示命令、路径、diff、原因和风险信息，并提供协议支持的操作，例如 `accept`、`acceptForSession`、`decline`、`cancel`。更完整的安全解释、审批历史和审计记录后置。

## 计划模式

第一版必须支持 `计划模式`。

实现原则：

- UI 有“计划模式”入口和状态。
- 打开后，新会话或下一轮 `turn/start` 使用 app-server 支持的 `CollaborationMode` / planning 配置。
- 不通过自定义 prompt 前缀模拟。
- 如果远端 Codex 版本不支持对应模式，UI 禁用并提示当前版本不支持。

## 语音输入

麦克风第一版只做语音转文字输入，不做实时语音对话。

实现方式：

- 使用 iOS 原生 Speech / Dictation。
- 转写文本进入 prompt 输入框。
- 发送仍走 `turn/start`。

不实现 `thread/realtime/start` 音频流。

## 后台和恢复

第一版不承诺可靠后台长连接和完成推送。

支持：

- 远端 Codex 继续运行。
- App 回到前台后通过 `thread/list` / `thread/read` 恢复状态。
- SSH 断线后重连。

不支持：

- 无后端情况下的可靠 APNs 完成通知。
- 长时间后台 SSH 保活。

## 多设备

会话状态来自远端 Codex，因此不同设备连接同一 Host 时可以看到相同会话。

第一版不做 iCloud Host Profile / 凭据同步。Host 配置、password、private key、known_hosts 均保存在本机 Keychain / 本地存储。

## 平台范围

第一版 iPhone 优先。

iPad 可以运行，但不做专项 iPadOS 优化，不承诺 split view、多窗口、键盘快捷键等完整体验。

## MVP 开发切片

### Slice 1: SSH 和诊断

- Host Profile CRUD。
- password / key 登录。
- Keychain 存储。
- host key 校验。
- 远端诊断页。
- 成功执行 `codex app-server daemon start && codex app-server proxy`。
- 完成 `initialize` 握手。

### Slice 2: Thread / Workspace 列表

- 调用 `thread/list`。
- 按时间顺序显示会话。
- 按 `cwd` 聚合 workspace。
- 支持“按项目分组 / 按时间顺序”切换。
- 支持 `cwd` 下会话过滤。

### Slice 3: 会话详情和继续会话

- `thread/read(includeTurns: true)`。
- `thread/resume`。
- `turn/start`。
- 流式渲染 agent message、command output、file change。
- `turn/interrupt` 停止。

### Slice 4: 空状态和目录浏览

- `fs/readDirectory` / `fs/getMetadata`。
- 从 home / 历史 workspace 起步。
- 手动绝对路径。
- `fs/createDirectory(recursive: true)`。
- 选中 `cwd` 后 `thread/start` 新建会话。

### Slice 5: 官方风格输入栏

- `+` 菜单。
- 权限盾牌。
- 模型显示。
- 麦克风语音转文字。
- 发送 / 停止按钮。
- 运行中状态同步。

### Slice 6: 附件

- 相机拍照。
- 文件选择。
- 远端附件目录创建。
- `fs/writeFile` 上传。
- 图片通过 `UserInput.localImage` 发送。
- 普通文件以远端路径引用。

### Slice 7: 权限和审批

- 权限菜单真实映射。
- 处理 command/file/permissions requestApproval。
- 支持 accept / acceptForSession / decline / cancel。
- 显示 diff、命令、路径、风险提示。

### Slice 8: 计划模式和版本兼容

- 支持 `计划模式`。
- 版本检测和兼容提示。
- schema 锁定和客户端类型生成流程。

## 风险

- `app-server` 协议仍有 experimental 字段，升级可能破坏兼容。
- 公网 SSH + password 登录风险较高，必须依赖 Keychain、Face ID、host key 校验和用户侧 SSH 安全配置。
- iOS 后台限制导致长任务通知能力有限。
- 附件目录不是官方公开约定，只能做到协议对齐。
- 官方 iOS UI 的部分私有行为无法从公开源码确认，需要以截图和协议能力近似复刻。

## 已确认决策

- 第一版定位为个人自用 MVP。
- 支持 Tailscale/内网 SSH 和公网 SSH。
- 支持 SSH key 和 password。
- password 可选保存到 Keychain，并由 Face ID/设备解锁保护。
- 只支持 `codex app-server proxy`，不支持 TUI fallback。
- 连接时自动执行 `daemon start && proxy`，不自动 `bootstrap`。
- 支持多个 Host Profile，Mac/VPS 统一建模。
- 项目/工作区列表从会话 `cwd` 聚合。
- 空态支持浏览远端目录、选择 `cwd`、创建目录。
- 创建目录支持多级路径。
- 会话详情使用 `thread/read(includeTurns: true)`。
- 继续会话使用 `thread/resume -> turn/start`。
- 沿用远端默认模型配置，不做模型选择器。
- 复刻范围限定为 Codex 相关功能。
- 相机和文件附件必须真实可用。
- 附件上传协议对齐官方，目录由客户端私有定义。
- 权限菜单真实改变 Codex 运行权限。
- 支持计划模式。
- 麦克风只做语音转文字。
- 支持 `turn/interrupt` 停止当前 turn。
- 不做可靠后台推送，只做前台恢复/重连。
- 不做 iCloud 配置同步。
- iPhone 优先，iPad 兼容但不专项优化。
- 必须支持 Host Profile 新增/编辑/删除。
- 必须包含远端 Codex 轻量诊断页。
- 最低兼容 `codex-cli >= 0.133.0`。
