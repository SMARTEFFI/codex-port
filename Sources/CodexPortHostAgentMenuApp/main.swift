import AppKit
import CodexPortHostAgentCore
import CodexPortShared
import CodexPortWebRTC
import CoreImage.CIFilterBuiltins
import SwiftUI

struct CodexPortHostAgentMenuApplication: App {
    @NSApplicationDelegateAdaptor(HostAgentMenuAppDelegate.self) private var appDelegate
    @StateObject private var model: HostAgentMenuModel

    init() {
        let model = HostAgentMenuModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra("CodexPort Host Agent", systemImage: "terminal") {
            HostAgentMenuContent(
                snapshot: model.snapshot,
                onNewPairing: model.startNewPairing,
                onRefreshPairing: model.refreshPairing,
                onCopyPairingKey: model.copyPairingKey,
                onRevokePairing: model.revokePairing,
                onQuit: model.quit
            )
        }
        .menuBarExtraStyle(.window)
    }
}

CodexPortHostAgentMenuApplication.main()

@MainActor
private final class HostAgentMenuModel: ObservableObject {
    @Published private var lifecycle = HostAgentLifecycleController(status: .running)
    @Published private var pairedDevices = HostAgentMenuFixture.pairedDevices
    @Published private var pairingCoordinator: HostAgentMenuPairingCoordinator
    private let backend: HostAgentRuntimeBackend
    private let pairingPublisher: HostAgentRelayPairingPublisher?
    private let pairingRecordsClient: HostAgentRelayPairingRecordsClient?
    private let relayConnector: HostAgentRelayConnector?
    private let p2pListener: HostAgentP2PSignalingListener?
    private let localRelayService: HostAgentLocalRelayService?
    private var pairedDeviceRefreshTask: Task<Void, Never>?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let relayConfiguration = Self.makeRelayConfiguration(environment: environment)
        backend = Self.makeBackend(environment: environment)
        pairingCoordinator = HostAgentMenuPairingCoordinator(
            hostID: relayConfiguration?.host.id ?? Self.defaultHostID,
            hostDisplayName: relayConfiguration?.host.displayName
        )
        pairingPublisher = relayConfiguration.map { HostAgentRelayPairingPublisher(configuration: $0) }
        pairingRecordsClient = relayConfiguration.map { HostAgentRelayPairingRecordsClient(configuration: $0) }
        if let relayConfiguration {
            let threadProviders = HostAgentRuntimeThreadProviderFactory.make(
                backend: backend,
                codexControlSocketPath: Self.codexControlSocketPath(environment["CODEXPORT_CODEX_CONTROL_SOCKET_PATH"])
            )
            let service = HostAgentLocalRelayService(
                adapterFactory: Self.makeAdapterFactory(environment: environment),
                threadListProvider: threadProviders.threadListProvider,
                threadStarter: threadProviders.threadStarter,
                threadHistoryProvider: threadProviders.threadHistoryProvider
            )
            localRelayService = service
            if Self.isP2PListenerEnabled(environment: environment) {
                relayConnector = nil
                Self.writeLogLine("CodexPort Host Agent P2P listener starting")
                p2pListener = HostAgentP2PSignalingListener(
                    host: relayConfiguration.host,
                    signalingClient: HostAgentP2PSignalingClient(relayBaseURL: relayConfiguration.relayBaseURL),
                    acceptorFactory: Self.makeP2PAcceptorFactory(environment: environment),
                    service: service,
                    onEvent: { event in
                        Self.writeLogLine("CodexPort Host Agent P2P listener: \(event)")
                    }
                )
                p2pListener?.start()
            } else {
                p2pListener = nil
                relayConnector = HostAgentRelayConnector(
                    host: relayConfiguration.host,
                    endpointURL: relayConfiguration.hostConnectURL,
                    service: service
                )
                relayConnector?.connect()
            }
        } else {
            localRelayService = nil
            relayConnector = nil
            p2pListener = nil
        }
        startPairedDeviceRefreshLoop()
    }

    deinit {
        pairedDeviceRefreshTask?.cancel()
        relayConnector?.stop()
        p2pListener?.stop()
    }

    var snapshot: HostAgentMenuSnapshot {
        HostAgentMenuSnapshot(
            lifecycle: Self.lifecycleSnapshot(lifecycle.snapshot, backend: backend),
            pairedDevices: pairedDevices,
            pairing: pairingCoordinator.snapshot
        )
    }

    func startNewPairing() {
        let snapshot = pairingCoordinator.startNewPairing(presentation: .manualAndQR)
        publishPairing(snapshot)
    }

    func refreshPairing() {
        let snapshot = pairingCoordinator.refreshPairing(presentation: .manualAndQR)
        publishPairing(snapshot)
    }

    private func publishPairing(_ snapshot: HostAgentMenuPairingSnapshot) {
        guard let pairingPublisher else { return }
        Task {
            do {
                try await pairingPublisher.publish(snapshot)
                await refreshPairedDevices()
            } catch {
                print("CodexPort Host Agent pairing publish failed: \(error)")
            }
        }
    }

    private func startPairedDeviceRefreshLoop() {
        pairedDeviceRefreshTask?.cancel()
        guard pairingRecordsClient != nil else { return }
        pairedDeviceRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPairedDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func refreshPairedDevices() async {
        guard let pairingRecordsClient else { return }
        do {
            pairedDevices = try await pairingRecordsClient.pairedDevices()
        } catch {
            print("CodexPort Host Agent pairing records refresh failed: \(error)")
        }
    }

    func copyPairingKey() {
        guard let key = pairingCoordinator.copyPairingKey() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    func revokePairing(_ recordID: String) {
        guard let pairingRecordsClient else { return }
        Task {
            do {
                try await pairingRecordsClient.revokePairing(recordID: recordID)
                await refreshPairedDevices()
            } catch {
                print("CodexPort Host Agent pairing revoke failed: \(error)")
            }
        }
    }

    func quit() {
        lifecycle.quit()
        NSApplication.shared.terminate(nil)
    }

    private static func makeRelayConfiguration(environment: [String: String]) -> HostAgentRelayConfiguration? {
        let relayBaseURL: URL
        if let rawBaseURL = environment["CODEXPORT_RELAY_BASE_URL"], !rawBaseURL.isEmpty {
            guard let overrideURL = URL(string: rawBaseURL) else {
                return nil
            }
            relayBaseURL = overrideURL
        } else {
            relayBaseURL = HostAgentRelayConfiguration.productionRelayBaseURL
        }
        let hostID = (environment["CODEXPORT_RELAY_HOST_ID"].flatMap(UUID.init(uuidString:))) ?? defaultHostID
        let hostName = HostAgentHostDisplayName.resolved(
            environmentValue: environment["CODEXPORT_RELAY_HOST_NAME"],
            defaultName: defaultHostName
        )
        let hostUser = environment["CODEXPORT_RELAY_HOST_USER"].flatMap(nonEmpty) ?? defaultHostUser
        let host = RelayHostIdentity(
            id: hostID,
            displayName: hostName,
            userName: hostUser,
            publicKey: EndpointPublicKey(rawValue: Data("host-agent-public-key".utf8))
        )
        guard let configuration = try? HostAgentRelayConfiguration(relayBaseURL: relayBaseURL, host: host) else {
            return nil
        }
        return configuration
    }

    private static let defaultHostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private static var defaultHostName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac" : name
    }

    private static var defaultHostUser: String {
        let user = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? "macos" : user
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeAdapterFactory(
        environment: [String: String]
    ) -> HostAgentLocalRelayRuntime.AdapterFactory {
        let executablePath = HostAgentCodexCommandResolver.executablePath(
            explicitCommand: environment["CODEXPORT_HOST_AGENT_COMMAND"],
            environment: environment
        )
        return HostAgentRuntimeAdapterFactory.make(configuration: HostAgentRuntimeAdapterFactoryConfiguration(
            backend: makeBackend(environment: environment),
            executablePath: executablePath,
            processArguments: parsedArgumentsJSON(environment["CODEXPORT_HOST_AGENT_ARGUMENTS_JSON"]),
            codexExecBaseArguments: parsedArgumentsJSON(environment["CODEXPORT_CODEX_EXEC_ARGUMENTS_JSON"]),
            codexExecResumeArguments: parsedArgumentsJSON(environment["CODEXPORT_CODEX_EXEC_RESUME_ARGUMENTS_JSON"]),
            codexExecTimeout: parsedTimeout(environment["CODEXPORT_CODEX_EXEC_TIMEOUT_SECONDS"]),
            codexControlSocketPath: codexControlSocketPath(environment["CODEXPORT_CODEX_CONTROL_SOCKET_PATH"])
        ))
    }

    private static func makeBackend(environment: [String: String]) -> HostAgentRuntimeBackend {
        (try? HostAgentRuntimeBackend.parse(environment["CODEXPORT_HOST_AGENT_BACKEND"]))
            ?? HostAgentRuntimeBackend.productionDefault
    }

    private static func isP2PListenerEnabled(environment: [String: String]) -> Bool {
        switch environment["CODEXPORT_HOST_AGENT_P2P_LISTEN"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "p2p", "p2p-webrtc-datachannel":
            return true
        default:
            return false
        }
    }

    private static func makeP2PAcceptorFactory(
        environment: [String: String]
    ) -> any HostAgentP2PDataChannelAcceptorFactory {
        guard let executablePath = environment["CODEXPORT_WEBRTC_SIDECAR_PATH"], !executablePath.isEmpty else {
            return HostAgentWebRTCDataChannelAcceptorFactory()
        }
        return HostAgentWebRTCSidecarAcceptorFactory(command: HostAgentProcessCommand(
            executablePath: executablePath,
            arguments: parsedArgumentsJSON(environment["CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON"])
        ))
    }

    private static func codexControlSocketPath(_ rawValue: String?) -> String {
        if let rawValue, !rawValue.isEmpty {
            return rawValue
        }
        return "\(FileManager.default.homeDirectoryForCurrentUser.path)/.codex/app-server-control/app-server-control.sock"
    }

    private static func lifecycleSnapshot(
        _ snapshot: HostAgentLifecycleSnapshot,
        backend: HostAgentRuntimeBackend
    ) -> HostAgentLifecycleSnapshot {
        var presentation = snapshot.presentation
        presentation.statusText = "\(presentation.statusText) · \(backendDetail(backend))"
        return HostAgentLifecycleSnapshot(
            status: snapshot.status,
            availableActions: snapshot.availableActions,
            presentation: presentation
        )
    }

    private static func backendDetail(_ backend: HostAgentRuntimeBackend) -> String {
        switch backend {
        case .processStdio:
            return "process-stdio"
        case .codexExecJSON:
            return "codex-exec-json"
        case .codexCLILive:
            return "codex-cli-live"
        }
    }

    private static func parsedArgumentsJSON(_ rawValue: String?) -> [String] {
        guard let rawValue, !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arguments
    }

    private static func parsedTimeout(_ rawValue: String?) -> Duration {
        guard let rawValue, let seconds = Double(rawValue), seconds > 0 else {
            return .seconds(120)
        }
        return .milliseconds(Int64(seconds * 1_000))
    }

    nonisolated private static func writeLogLine(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

private struct HostAgentMenuContent: View {
    let snapshot: HostAgentMenuSnapshot
    let onNewPairing: () -> Void
    let onRefreshPairing: () -> Void
    let onCopyPairingKey: () -> Void
    let onRevokePairing: (String) -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostAgentStatusHeader(statusText: snapshot.statusText)

            Divider()
                .padding(.vertical, 8)

            HostAgentPairedDevicesSection(
                title: snapshot.deviceSectionTitle,
                emptyText: snapshot.emptyDeviceListText,
                devices: snapshot.pairedDevices,
                onRevokePairing: onRevokePairing
            )

            Divider()
                .padding(.vertical, 8)

            HostAgentPairingSection(
                pairing: snapshot.pairing,
                onNewPairing: onNewPairing,
                onRefreshPairing: onRefreshPairing,
                onCopyPairingKey: onCopyPairingKey
            )

            Divider()
                .padding(.vertical, 8)

            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .padding(.vertical, 7)
                .accessibilityIdentifier("host-agent-menu-quit")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 390, alignment: .leading)
    }
}

private struct HostAgentStatusHeader: View {
    let statusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("CodexPort Host Agent")
                .font(.title3.weight(.regular))
        }
    }
}

private struct HostAgentPairingSection: View {
    let pairing: HostAgentMenuPairingSnapshot
    let onNewPairing: () -> Void
    let onRefreshPairing: () -> Void
    let onCopyPairingKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("New Pairing", action: onNewPairing)
                .buttonStyle(.plain)
                .padding(.vertical, 7)
                .accessibilityIdentifier("host-agent-menu-new-pairing")

            if pairing.state == .ready {
                if let payload = pairing.qrPayload {
                    HostAgentQRCodeView(payload: payload)
                        .frame(width: 112, height: 112)
                        .accessibilityLabel("Pairing QR Code")
                }
                if let pairingKey = pairing.pairingKey {
                    Text(pairingKey)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button(pairing.refreshCommandTitle, action: onRefreshPairing)
                        .buttonStyle(.plain)
                        .disabled(!pairing.canRefresh)
                        .accessibilityIdentifier("host-agent-menu-refresh-pairing")
                    Button(pairing.copyCommandTitle, action: onCopyPairingKey)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("host-agent-menu-copy-pairing-key")
                }
                if let expiresAt = pairing.expiresAt {
                    Text("Expires \(expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if pairing.state == .expired {
                Text("Pairing expired")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HostAgentQRCodeView: View {
    let payload: String

    var body: some View {
        if let image = qrImage {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
        } else {
            Text(payload)
                .font(.caption2.monospaced())
        }
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct HostAgentPairedDevicesSection: View {
    let title: String
    let emptyText: String
    let devices: [HostAgentMenuPairedDevice]
    let onRevokePairing: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)

            if devices.isEmpty {
                Text(emptyText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(devices) { device in
                    HostAgentPairedDeviceRow(device: device, onRevokePairing: onRevokePairing)
                }
            }
        }
    }
}

private struct HostAgentPairedDeviceRow: View {
    let device: HostAgentMenuPairedDevice
    let onRevokePairing: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(device.statusText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button(device.managementTitle) {
                if case let .revoke(recordID) = device.management {
                    onRevokePairing(recordID)
                }
            }
                .buttonStyle(.plain)
                .disabled(!device.isManagementEnabled)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private final class HostAgentMenuAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment

        if environment["CODEXPORT_HOST_AGENT_MENU_SMOKE"] == "1" {
            print("CodexPort Host Agent menu app started")
        }

        if let rawSeconds = environment["CODEXPORT_HOST_AGENT_MENU_SMOKE_EXIT_AFTER_SECONDS"],
           let seconds = Double(rawSeconds),
           seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private enum HostAgentMenuFixture {
    static let pairedDevices: [HostAgentMenuPairedDevice] = []
}
