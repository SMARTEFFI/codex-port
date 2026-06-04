import CodexPortCore
import SwiftUI
import UIKit

struct CodexInputBarView: View {
    @Binding var composer: InputComposer
    let pendingAttachments: [PendingAttachment]
    let onSend: () -> Void
    let onStop: () -> Void
    let onAttachPhoto: () -> Void
    let onAttachCamera: () -> Void
    let onAttachFile: () -> Void
    let onRemoveAttachment: (Int) -> Void
    @State private var pendingPermissionMode: PermissionMode?
    @State private var fullAccessConfirmationPresented = false
    @State private var unavailableReason: String?

    var body: some View {
        VStack(spacing: 10) {
            if !pendingAttachments.isEmpty {
                AttachmentPreviewStrip(
                    attachments: pendingAttachments,
                    onRemove: onRemoveAttachment
                )
            }

            TextField("向 Codex 提问", text: $composer.text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)

            HStack(spacing: 16) {
                Menu {
                    Button {
                        togglePlanMode()
                    } label: {
                        Label(composer.collaborationMode == .plan ? "关闭计划模式" : "计划模式", systemImage: "list.bullet")
                    }
                    .disabled(!composer.capabilities.planMode.isSupported)
                    Button(action: onAttachFile) {
                        Label("文件", systemImage: "paperclip")
                    }
                    Button(action: onAttachCamera) {
                        Label("相机", systemImage: "camera")
                    }
                    Button(action: onAttachPhoto) {
                        Label("照片", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                }

                Menu {
                    permissionButton("默认权限", mode: .remoteDefault)
                    permissionButton("自动审核", mode: .autoReview)
                    permissionButton("完全访问权限", mode: .fullAccess)
                    permissionButton("自定义 (config.toml)", mode: .customConfigToml)
                } label: {
                    Image(systemName: permissionIcon)
                        .foregroundStyle(composer.permissionMode == .fullAccess ? .orange : .primary)
                }

                Spacer()

                modelMenu

                Button {
                    switch composer.primaryAction {
                    case .send:
                        onSend()
                    case .stop:
                        onStop()
                    case .disabled:
                        break
                    }
                } label: {
                    Image(systemName: composer.primaryAction == .stop ? "stop.fill" : "arrow.up")
                        .frame(width: 36, height: 36)
                        .background(composer.primaryAction == .disabled ? Color(.systemGray5) : Color.primary)
                        .foregroundStyle(composer.primaryAction == .disabled ? Color.secondary : Color(.systemBackground))
                        .clipShape(Circle())
                }
                .disabled(composer.primaryAction == .disabled)
            }
            .buttonStyle(.plain)
            .font(.title3)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
        .confirmationDialog(
            "完全访问权限风险较高",
            isPresented: $fullAccessConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("启用完全访问权限", role: .destructive) {
                composer.setPermissionMode(.fullAccess)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("完全访问权限会允许远端 Codex 在当前主机上执行更宽松的命令与文件操作。确认你信任该 host 和当前任务后再启用。")
        }
        .alert("当前远端不支持", isPresented: Binding(
            get: { unavailableReason != nil },
            set: { if !$0 { unavailableReason = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(unavailableReason ?? "")
        }
    }

    private var modelMenu: some View {
        Menu {
            Section("模型") {
                ForEach(composer.modelMenu.modelOptions, id: \.id) { option in
                    Button {
                        composer.setModel(option.model)
                    } label: {
                        Label(option.title, systemImage: option.isSelected ? "checkmark" : "circle")
                    }
                    .disabled(!option.isEnabled)
                }
            }

            Menu {
                ForEach(composer.modelMenu.reasoningOptions, id: \.effort) { option in
                    Button {
                        composer.setReasoningEffort(option.effort)
                    } label: {
                        Label(option.title, systemImage: option.isSelected ? "checkmark" : "circle")
                    }
                    .disabled(!option.isEnabled)
                }
            } label: {
                Label("推理强度", systemImage: "speedometer")
            }
            .disabled(!composer.capabilities.reasoningEffort.isSupported)

            if let reason = composer.capabilities.modelSelection.reason ?? composer.capabilities.reasoningEffort.reason {
                Section("不可用") {
                    Text(reason)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(composer.modelMenu.primaryTitle)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("模型菜单")
    }

    @ViewBuilder
    private func permissionButton(_ title: String, mode: PermissionMode) -> some View {
        Button {
            selectPermissionMode(mode)
        } label: {
            Label(title, systemImage: composer.permissionMode == mode ? "checkmark" : "circle")
        }
        .disabled(!(composer.capabilities.permissionModes[mode]?.isSupported ?? false))
    }

    private func togglePlanMode() {
        if let reason = composer.capabilities.planMode.reason {
            unavailableReason = reason
            return
        }
        composer.togglePlanMode()
    }

    private func selectPermissionMode(_ mode: PermissionMode) {
        if let reason = composer.capabilities.permissionModes[mode]?.reason {
            unavailableReason = reason
            return
        }
        if mode == .fullAccess {
            fullAccessConfirmationPresented = true
            return
        }
        composer.setPermissionMode(mode)
    }

    private var permissionIcon: String {
        switch composer.permissionMode {
        case .remoteDefault:
            return "hand.raised"
        case .autoReview:
            return "terminal"
        case .fullAccess:
            return "exclamationmark.shield"
        case .customConfigToml:
            return "gearshape"
        }
    }
}

private struct AttachmentPreviewStrip: View {
    let attachments: [PendingAttachment]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    AttachmentPreviewChip(
                        attachment: attachment,
                        onRemove: {
                            onRemove(index)
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AttachmentPreviewChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            preview
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(attachment.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(attachment.name)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var preview: some View {
        switch attachment.kind {
        case .image:
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        case .file:
            Image(systemName: "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.tertiarySystemFill))
        }
    }
}

#Preview {
    @Previewable @State var composer = InputComposer(modelDisplay: "5.5 超高")
    CodexInputBarView(
        composer: $composer,
        pendingAttachments: [],
        onSend: {},
        onStop: {},
        onAttachPhoto: {},
        onAttachCamera: {},
        onAttachFile: {},
        onRemoveAttachment: { _ in }
    )
}
