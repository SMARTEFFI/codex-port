import CodexPortCore
import SwiftUI

struct ApprovalRequestView: View {
    let request: ApprovalRequest
    let onRespond: (ApprovalAction) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("请求") {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }

                Section("风险") {
                    Text(risk)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let diff {
                    Section("Diff") {
                        Text(diff)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("操作") {
                    Button("允许本次") { onRespond(.accept) }
                    Button("本会话允许") { onRespond(.acceptForSession) }
                    Button("拒绝", role: .destructive) { onRespond(.decline) }
                    Button("取消", role: .cancel) { onRespond(.cancel) }
                }
            }
            .navigationTitle("审批请求")
        }
    }

    private var title: String {
        switch request {
        case .command:
            return "命令执行"
        case .fileChange:
            return "文件变更"
        case .permissions:
            return "权限请求"
        }
    }

    private var detail: String {
        switch request {
        case let .command(_, command, cwd, reason):
            return [
                "cwd: \(cwd)",
                "command: \(command.joined(separator: " "))",
                reason.map { "reason: \($0)" }
            ].compactMap { $0 }.joined(separator: "\n")
        case let .fileChange(_, path, _):
            return path
        case let .permissions(_, permissions):
            return String(describing: permissions)
        }
    }

    private var risk: String {
        switch request {
        case .command:
            return "允许后远端 Codex 会在显示的工作目录中执行该命令。请确认命令内容和当前 host 后再批准。"
        case .fileChange:
            return "允许后远端 Codex 会写入或修改显示的文件路径。请先检查 diff。"
        case .permissions:
            return "允许后远端 Codex 会获得请求中显示的权限范围；本会话允许会持续到当前 session 结束。"
        }
    }

    private var diff: String? {
        if case let .fileChange(_, _, diff) = request {
            return diff
        }
        return nil
    }
}

#Preview {
    ApprovalRequestView(
        request: .command(id: .string("approval-1"), command: ["git", "status"], cwd: "/repo", reason: "检查工作区"),
        onRespond: { _ in }
    )
}
