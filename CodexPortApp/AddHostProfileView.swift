import CodexPortCore
import CodexPortShared
import SwiftUI
import VisionKit

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
    @State private var isPairing = false
    @State private var isScannerPresented = false

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
                Picker("连接方式", selection: connectionMethodBinding) {
                    Text("Direct SSH").tag(ConnectionMethodSelection.directSSH)
                    Text("Relay").tag(ConnectionMethodSelection.relay)
                }
                .pickerStyle(.segmented)

                TextField("名称", text: $form.name)
                    .textContentType(.name)
                if connectionMethodSelection == .directSSH {
                    TextField("Host", text: $form.host)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $form.port)
                        .keyboardType(.numberPad)
                }
            }

            if connectionMethodSelection == .directSSH {
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
            } else {
                Section("配对") {
                    TextField("配对码", text: $form.pairingMaterial)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        isScannerPresented = true
                    } label: {
                        Label("扫描 Pairing QR", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!RelayPairingScannerView.isSupported)
                    TextField("本机设备名称", text: $form.deviceDisplayName)
                        .textContentType(.name)
                    Text("使用 Mac 上 CodexPort Host Agent 生成的一次性 Pairing Token，不保存 SSH 凭据。")
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

        }
        .navigationTitle(isEditing ? "编辑 Host" : "添加 Host")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        await save()
                    }
                } label: {
                    if isPairing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("保存")
                    }
                }
                .disabled(isPairing)
            }
        }
        .sheet(isPresented: $isScannerPresented) {
            RelayPairingScannerView { material in
                if form.applyScannedPairingMaterial(material) {
                    isScannerPresented = false
                }
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            applyDefaultRelayDeviceDisplayName()
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private var connectionMethodSelection: ConnectionMethodSelection {
        switch form.connectionMethod {
        case .directSSH:
            .directSSH
        case .relay:
            .relay
        }
    }

    private var connectionMethodBinding: Binding<ConnectionMethodSelection> {
        Binding {
            connectionMethodSelection
        } set: { selection in
            switch selection {
            case .directSSH:
                form.selectDirectSSHConnection()
            case .relay:
                form.selectRelayConnection()
                applyDefaultRelayDeviceDisplayName()
            }
        }
    }

    private func applyDefaultRelayDeviceDisplayName() {
        guard !isEditing, connectionMethodSelection == .relay else { return }
        guard form.deviceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceName.isEmpty else { return }
        form.deviceDisplayName = deviceName
    }

    @MainActor
    private func save() async {
        guard !isPairing else { return }
        errorMessage = nil
        do {
            if connectionMethodSelection == .relay, !isEditing {
                isPairing = true
                defer { isPairing = false }
                let input = try form.makeRelayPairingInput(defaultDeviceDisplayName: UIDevice.current.name)
                let client = RelayHostProductionPairingClient(
                    devicePublicKey: EndpointPublicKey(rawValue: Data("ios-device-public-key".utf8))
                )
                let draft = try await client.pair(
                    input,
                    codexPath: form.codexPath,
                    defaultDirectory: form.defaultDirectory,
                    profileName: form.name
                )
                try onSave(draft)
            } else {
                try onSave(form.makeDraft())
            }
            dismiss()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? HostProfileFormError {
            switch error {
            case let .requiredField(field):
                return "请填写 \(label(for: field))。"
            case .invalidPort:
                return "端口必须是 1 到 65535。"
            }
        }
        if let error = error as? RelayHostProductionPairingInputError {
            switch error {
            case .invalidRelayEndpoint:
                return "配对服务配置无效，请重新安装最新构建。"
            case .missingPairingToken:
                return "请扫描 QR 或填写配对码。"
            }
        }
        if let error = error as? RelayHostProductionPairingClientError {
            switch error {
            case let .httpStatus(status):
                if status == 400 {
                    return "配对码无效、已过期或已被使用。请在 HostAgent 菜单重新 New Pairing 后复制新的 Pairing Key。"
                }
                return "配对失败，服务返回 HTTP \(status)。"
            case .requestTimedOut:
                return "配对请求超时。请确认 Mac 上的 HostAgent 在线，并重新生成 Pairing Key 后再试。"
            case .appTransportSecurityBlocked:
                return "iOS 阻止了当前配对请求。请重新安装最新构建。"
            case let .transport(message):
                return "配对请求失败：\(message)"
            case .invalidResponse:
                return "配对失败：服务返回了无效响应。"
            case .invalidResponsePayload:
                return "配对失败：服务响应格式不符合 0.2.x 协议。"
            }
        }
        return "保存失败，请稍后重试。"
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

private enum ConnectionMethodSelection: Hashable {
    case directSSH
    case relay
}

private struct RelayPairingScannerView: UIViewControllerRepresentable {
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onMaterial: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onMaterial: onMaterial)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onMaterial: (String) -> Void

        init(onMaterial: @escaping (String) -> Void) {
            self.onMaterial = onMaterial
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(items: addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(items: updatedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle(items: [item])
        }

        private func handle(items: [RecognizedItem]) {
            guard let payload = items.lazy.compactMap(Self.payloadString).first else { return }
            onMaterial(payload)
        }

        private static func payloadString(from item: RecognizedItem) -> String? {
            guard case let .barcode(barcode) = item,
                  let payload = barcode.payloadStringValue,
                  !payload.isEmpty
            else { return nil }
            return payload
        }
    }
}

#Preview {
    NavigationStack {
        AddHostProfileView(onSave: { _ in })
    }
}
