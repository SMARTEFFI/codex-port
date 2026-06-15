# Issue #42-45 Host Agent menu bar verification

日期：2026-06-08

## 结论

Pass。#42-#45 可以关闭。

本轮实现了 macOS `CodexPort Host Agent` 的菜单栏入口：

- 新增 SwiftPM product / Xcode scheme：`codexport-host-agent-menu`。
- 新增 macOS-only executable target：`CodexPortHostAgentMenuApp`，依赖 `CodexPortHostAgentCore`，不依赖 iOS SwiftUI app types。
- 菜单栏 app 使用 `MenuBarExtra` 显示状态栏图标，菜单内容包含 `Running`、`Recent`、`More` 和 `Quit`。
- `Running` / `Recent` 来自 `HostAgentMenuSnapshot` core view-state，不硬编码在 UI 组件里。
- `Quit` 通过 Host Agent lifecycle controller 置为 offline 后退出 app process。
- 提供 smoke-only environment：
  - `CODEXPORT_HOST_AGENT_MENU_SMOKE=1`
  - `CODEXPORT_HOST_AGENT_MENU_SMOKE_EXIT_AFTER_SECONDS=<seconds>`

## 验证命令与结果

### 1. RED→GREEN focused tests

命令：

```sh
swift test --filter HostAgentLifecycleTests
swift test --filter HostAgentExecutableLifecycleIntegrationTests
```

结果：

```text
HostAgentLifecycleTests: 4 tests passed
HostAgentExecutableLifecycleIntegrationTests: 2 tests passed
```

覆盖：

- lifecycle 状态：Offline、Running、Paused、Reconnecting、Quit。
- menu snapshot 分组：`Running`、`Recent`、`More`、`Quit`。
- empty state：无 running/recent session 时隐藏 `More`，保留 `Quit`。
- executable smoke：`codexport-host-agent-menu` 启动、打印 smoke marker、自动退出。
- 原 `codexport-host-agent --local-relay-websocket` stdin EOF lifecycle 仍通过。

### 2. 全量 SwiftPM tests

命令：

```sh
swift test
```

结果：

```text
187 tests passed
```

### 3. SwiftPM build

命令：

```sh
swift build --product codexport-host-agent-menu
swift build -c release --product codexport-host-agent-menu
swift build -c release --product codexport-host-agent
```

结果：

```text
Build of product 'codexport-host-agent-menu' complete
Build of product 'codexport-host-agent' complete
```

### 4. Xcode scheme build

命令：

```sh
xcodebuild -list -project CodexPort.xcodeproj
xcodebuild -scheme codexport-host-agent-menu -destination 'platform=macOS' build
```

结果：

```text
Schemes include codexport-host-agent-menu
** BUILD SUCCEEDED **
```

### 5. Menu app smoke

命令：

```sh
CODEXPORT_HOST_AGENT_MENU_SMOKE=1 \
CODEXPORT_HOST_AGENT_MENU_SMOKE_EXIT_AFTER_SECONDS=0.5 \
.build/debug/codexport-host-agent-menu
```

结果：

```text
CodexPort Host Agent menu app started
```

进程清理检查：

```sh
pgrep -fl 'codexport-host-agent|codexport-host-agent-menu|CodexPortHostAgentMenuApp' || true
```

结果：无残留 Host Agent / menu app 进程。

## Acceptance Criteria 状态

| Issue | Criteria | 状态 | 证据 |
| --- | --- | --- | --- |
| #42 | 可构建、可运行的菜单栏 app target/product shell | Pass | `codexport-host-agent-menu` SwiftPM product 和 Xcode scheme build 均通过。 |
| #42 | 状态栏图标和菜单包含 `Running`、`Recent`、`Quit` | Pass | `MenuBarExtra("CodexPort Host Agent", systemImage: "terminal")` + menu content；core snapshot tests 覆盖分组。 |
| #42 | `Quit` 退出 process | Pass | lifecycle test + executable smoke 自动退出 + 无残留进程检查。 |
| #43 | `Recent` 0/1/多条、title + project/repo、`More >` | Pass | `HostAgentMenuSnapshot` tests 覆盖 recent list、limit、`showsMoreRecents` 和 `.moreRecent` command；UI 渲染 `More` button。 |
| #44 | `Running` 0/1/多条、title + project/repo | Pass | `HostAgentMenuSnapshot` tests 覆盖 running list；UI row 渲染 title/projectName 并 line-limit/truncate。 |
| #45 | lifecycle/session registry 状态接入 menu UI | Pass | menu app 从 `HostAgentLifecycleController` + `HostAgentMenuSnapshot` 生成 UI state。当前 session source 是 fixture/view-state，符合 #42/#43/#44 第一版要求。 |
| #45 | smoke 步骤和结果 | Pass | 本文件记录 build/test/smoke 命令、输出和无残留进程检查。 |

## 已知限制

- 当前 `codexport-host-agent-menu` 是 SwiftPM/Xcode executable product，不是签名 `.app` bundle 或 launchd/Login Item 安装器。
- 当前 session source 是第一版 fixture/view-state，用于证明 Running/Recent/More/Quit 的端到端 UI shell；后续可把真实 Relay/CLI session registry 替换进同一 `HostAgentMenuSnapshot` 边界。
- 本轮没有读取、打印、复制或总结 credential files。smoke 输出不包含 prompt 明文、tokens、pairing secret 或 credential values。
