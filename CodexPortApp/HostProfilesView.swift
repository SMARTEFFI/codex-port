import CodexPortCore
import SwiftUI

struct HostProfilesView: View {
    let profiles: [CodexPortCore.HostProfile]
    let onOpenWorkspaces: (CodexPortCore.HostProfile) -> Void
    let onEditProfile: (CodexPortCore.HostProfile) -> Void
    let onDeleteProfiles: (IndexSet) -> Void
    let onAddProfile: () -> Void
    let onOpenDiagnostics: () -> Void

    var body: some View {
        List {
            Section {
                if profiles.isEmpty {
                    Text("暂无 Host")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                } else {
                    ForEach(profiles) { profile in
                        Button {
                            onOpenWorkspaces(profile)
                        } label: {
                            HostProfileRow(profile: profile)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                                    onDeleteProfiles(IndexSet(integer: index))
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                onEditProfile(profile)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete(perform: onDeleteProfiles)
                }
            } header: {
                Text("主机配置")
            } footer: {
                Text("凭据保存在应用沙盒内的本地加密文件，主机配置保存在本机。")
            }

            Section {
                Button(action: onOpenDiagnostics) {
                    Label("打开诊断", systemImage: "stethoscope")
                }
            } footer: {
                Text("诊断页将用于检查网络、认证、日志与连接状态。")
            }
        }
        .navigationTitle("Host Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAddProfile) {
                    Label("添加", systemImage: "plus")
                }
            }
        }
    }
}

private struct HostProfileRow: View {
    let profile: CodexPortCore.HostProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.name)
                    .font(.headline)

                Spacer()

                Text(profile.knownHostFingerprint == nil ? "待确认" : "已信任")
                    .font(.caption)
                    .foregroundStyle(profile.knownHostFingerprint == nil ? Color.secondary : Color.green)
            }

            Text("\(profile.username)@\(profile.host):\(profile.port)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        HostProfilesView(
            profiles: [
                CodexPortCore.HostProfile(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: "本机开发环境",
                    host: "127.0.0.1",
                    port: 22,
                    username: "chenm",
                    auth: .password(credentialID: "preview"),
                    codexPath: "codex",
                    startupCommand: AppServerStartupCommand(codexPath: "codex").shellCommand,
                    defaultDirectory: "~/Projects",
                    knownHostFingerprint: nil
                )
            ],
            onOpenWorkspaces: { _ in },
            onEditProfile: { _ in },
            onDeleteProfiles: { _ in },
            onAddProfile: {},
            onOpenDiagnostics: {}
        )
    }
}
