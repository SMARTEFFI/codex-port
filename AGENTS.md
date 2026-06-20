## Agent skills

### Output language

mattpocock/skills 产出的所有 artifact 默认使用中文。遇到 label、workflow state、命令、template key、文件名、代码标识符或既有 skill 术语时，关键英文词必须保持不变。参见 `docs/agents/output-language.md`。

### Issue tracker

Issues 和 PRDs 使用 GitHub Issues 跟踪，所有操作通过 `gh` CLI 完成。参见 `docs/agents/issue-tracker.md`。

### Triage labels

使用 mattpocock/skills 默认的 triage labels。参见 `docs/agents/triage-labels.md`。

### Domain docs

这是 single-context repo：如果根目录存在 `CONTEXT.md`，以及存在 `docs/adr/`，应读取它们。参见 `docs/agents/domain.md`。

### 真机验证版本一致性

进行真机、TestFlight、local physical-device、production Relay/VPS 或 HostAgent HITL 验证前，必须确认所有参与端都运行当前 workspace 对应的最新 artifact。凡 HostAgent、VPS service、iOS app、shared core、Pairing、P2P/WebRTC、Relay/TURN 配置或相关脚本有修改，都不能复用旧运行实例或旧安装包。

- HostAgent / HostAgent menu / WebRTC sidecar 有修改：必须重新 build、重新安装或替换 artifact，并重启对应 LaunchAgent、menu app、`--p2p-listen` listener 或 sidecar；验证日志必须来自本轮启动。
- VPS Relay / TURN / service 配置有修改：必须重新部署并重启 VPS service，确认 health check、service logs 或 endpoint 行为来自最新部署。
- iOS app / CodexPortCore / Pairing / transport / UI 有修改：必须重新安装到真机，或重新上传并安装最新 TestFlight build；不得用旧真机安装包判断新代码是否生效。
- 只要任一端无法确认已更新到最新版，就先停止真机结论，补做安装、部署或重启；不要声明 HITL pass/fail。
