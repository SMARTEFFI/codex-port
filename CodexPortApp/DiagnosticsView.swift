import CodexPortCore
import SwiftUI

struct DiagnosticsView: View {
    static let defaultRows = [
        DiagnosticRow(title: "SSH 连接", status: .notRun, message: "尚未运行"),
        DiagnosticRow(title: "Codex 版本", status: .notRun, message: "尚未运行"),
        DiagnosticRow(title: "App Server", status: .notRun, message: "尚未运行"),
        DiagnosticRow(title: "协议握手", status: .notRun, message: "尚未运行"),
    ]

    let report: DiagnosticReport
    let profiles: [HostProfile]
    let isRunning: Bool
    let onRun: (HostProfile) -> Void

    init(
        report: DiagnosticReport = DiagnosticReport(rows: DiagnosticsView.defaultRows),
        profiles: [HostProfile] = [],
        isRunning: Bool = false,
        onRun: @escaping (HostProfile) -> Void = { _ in }
    ) {
        self.report = report
        self.profiles = profiles
        self.isRunning = isRunning
        self.onRun = onRun
    }

    var body: some View {
        List {
            Section("选择 Host") {
                if profiles.isEmpty {
                    Text("暂无 Host")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                } else {
                    ForEach(profiles) { profile in
                        Button {
                            onRun(profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isRunning {
                                    ProgressView()
                                } else {
                                    Image(systemName: "play.circle")
                                }
                            }
                        }
                        .disabled(isRunning)
                    }
                }
            }

            Section("诊断项目") {
                ForEach(report.rows) { row in
                    DiagnosticRowView(row: row)
                }
            }
        }
        .navigationTitle("诊断")
    }
}

private struct DiagnosticRowView: View {
    let row: DiagnosticRow

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                Text(row.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        switch row.status {
        case .passed:
            return "checkmark.circle"
        case .failed:
            return "xmark.octagon"
        case .notRun:
            return "circle"
        }
    }

    private var iconColor: Color {
        switch row.status {
        case .passed:
            return .green
        case .failed:
            return .red
        case .notRun:
            return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView(report: DiagnosticReport(rows: [
            DiagnosticRow(title: "SSH 连接", status: .passed, message: "已连接"),
            DiagnosticRow(title: "Codex 版本", status: .failed, message: "远端版本 0.132.0 低于最低要求 0.133.0。"),
        ]))
    }
}
