import CodexPortCore
import SwiftUI

struct AddHostProfileView: View {
    enum Mode {
        case create
        case edit(HostProfile)
    }

    let mode: Mode
    let onSave: (HostProfileDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form = HostProfileFormModel()
    @State private var errorMessage: String?

    init(mode: Mode = .create, onSave: @escaping (HostProfileDraft) throws -> Void) {
        self.mode = mode
        self.onSave = onSave
        if case let .edit(profile) = mode {
            _form = State(initialValue: HostProfileFormModel(profile: profile))
        }
    }

    var body: some View {
        Form {
            Section("连接") {
                TextField("名称", text: $form.name)
                    .textContentType(.name)
                TextField("Host", text: $form.host)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("端口", text: $form.port)
                    .keyboardType(.numberPad)
            }

            Section("认证") {
                TextField("用户名", text: $form.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("方式", selection: $form.authMethod) {
                    Text("密码").tag(HostProfileAuthMethod.password)
                    Text("SSH Key").tag(HostProfileAuthMethod.key)
                }
                .pickerStyle(.segmented)

                if form.authMethod == .password {
                    SecureField(isEditing ? "新密码（留空沿用已保存凭据）" : "密码", text: $form.password)
                        .textContentType(.password)
                } else {
                    TextField("Key Label", text: $form.privateKeyLabel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $form.privateKey)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(isEditing ? "留空沿用已保存私钥；填写新私钥会替换本地加密存储中的旧凭据。支持未加密 OpenSSH Ed25519 私钥。" : "支持未加密 OpenSSH Ed25519 私钥。私钥内容只保存到应用本地加密存储。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Codex") {
                TextField("codexPath", text: $form.codexPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("defaultDirectory", text: $form.defaultDirectory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isEditing ? "编辑 Host" : "添加 Host")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private func save() {
        do {
            try onSave(form.makeDraft())
            dismiss()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        guard let error = error as? HostProfileFormError else {
            return "保存失败，请稍后重试。"
        }

        switch error {
        case let .requiredField(field):
            return "请填写 \(label(for: field))。"
        case .invalidPort:
            return "端口必须是 1 到 65535。"
        }
    }

    private func label(for field: String) -> String {
        switch field {
        case "name":
            return "名称"
        case "host":
            return "Host"
        case "username":
            return "用户名"
        case "password":
            return "密码"
        case "privateKeyLabel":
            return "Key Label"
        case "privateKey":
            return "SSH 私钥"
        case "codexPath":
            return "codexPath"
        case "defaultDirectory":
            return "defaultDirectory"
        default:
            return field
        }
    }
}

#Preview {
    NavigationStack {
        AddHostProfileView(onSave: { _ in })
    }
}
