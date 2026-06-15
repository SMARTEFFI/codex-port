import CodexPortHostAgentCore
import CodexPortRelayCore
import CodexPortShared
import CodexPortWebRTC
import Foundation
import Dispatch

let configuration = try HostAgentCommandLineConfiguration(arguments: CommandLine.arguments)

switch configuration.mode {
case .manifest:
    let manifest = HostAgentProductManifest.default
    print("\(manifest.productName) \(manifest.sharedContractVersion.major).\(manifest.sharedContractVersion.minor).\(manifest.sharedContractVersion.patch)")
case let .listIdleThreadsJSON(limit):
    let response = try await HostAgentCodexAppServerThreadListProvider().listThreads(limit: limit)
    let output = HostAgentIdleThreadListOutput(
        generatedAtUnixTime: Date().timeIntervalSince1970,
        threads: response.threads
            .filter(\.isIdleCandidate)
            .map(HostAgentIdleThreadSummary.init(snapshot:))
    )
    let data = try JSONEncoder().encode(output)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
case .localRelayJSONL:
    let service = HostAgentLocalRelayService(adapterFactory: configuration.adapterFactory)
    while let line = readLine() {
        do {
            try await service.handleLine(line) { outputLine in
                FileHandle.standardOutput.write(Data((outputLine + "\n").utf8))
            }
        } catch {
            let outputLine = try HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error))
            FileHandle.standardOutput.write(Data((outputLine + "\n").utf8))
        }
    }
    await service.stopAll()
case let .localRelayWebSocket(port):
    guard let seed = configuration.localRelaySeed else {
        throw HostAgentCommandLineConfigurationError.missingRelaySeed("localRelaySeed")
    }
    let gateway = RelayAuthenticatedStreamGateway(supportedVersions: [.v0_2_0])
    _ = await gateway.registerHost(seed.host)
    var pairings: [PairingRecord] = []
    for device in seed.devices {
        let pairing = try await gateway.authorize(device: device, forHostID: seed.host.id, pairedAt: Date())
        pairings.append(pairing)
    }
    let service = HostAgentLocalRelayService(adapterFactory: configuration.adapterFactory)
    let server = RelayWebSocketLineStreamServer(port: port, gateway: gateway) { _, line, writer in
        try await service.handleLine(line) { outputLine in
            try? await writer.sendLine(outputLine)
        }
    }
    let endpointURL = try await server.start()
    print("CodexPort Host Agent local Relay WebSocket listening at \(endpointURL.absoluteString)")
    for pairing in pairings {
        print("Pairing Record: \(pairing.id)")
    }
    await waitForTerminationSignal()
    await server.stop()
    await service.stopAll()
case .relayConnect:
    guard let relayConfiguration = configuration.relayConfiguration else {
        throw HostAgentCommandLineConfigurationError.missingRelayBaseURL
    }
    let service = HostAgentLocalRelayService(adapterFactory: configuration.adapterFactory)
    let connector = HostAgentRelayConnector(
        host: relayConfiguration.host,
        endpointURL: relayConfiguration.hostConnectURL,
        service: service
    )
    connector.connect()
    print("CodexPort Host Agent connected to Relay at \(relayConfiguration.hostConnectURL.absoluteString)")
    await waitForTerminationSignal()
    connector.stop()
    await service.stopAll()
case .p2pListen:
    guard let relayConfiguration = configuration.relayConfiguration else {
        throw HostAgentCommandLineConfigurationError.missingRelayBaseURL
    }
    let diagnosticsRunID = ProcessInfo.processInfo.environment["CODEXPORT_ISSUE74_RUN_ID"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let service = HostAgentLocalRelayService(adapterFactory: configuration.adapterFactory)
    let webRTCConfiguration = WebRTCRuntimeConfigurationEnvironment.makeOrDefault(
        environment: ProcessInfo.processInfo.environment
    )
    let listener = HostAgentP2PSignalingListener(
        host: relayConfiguration.host,
        signalingClient: HostAgentP2PSignalingClient(relayBaseURL: relayConfiguration.relayBaseURL),
        acceptor: configuration.webRTCSidecarCommand.map { command in
            HostAgentWebRTCSidecarAcceptor(configuration: WebRTCSidecarConfiguration(
                command: command,
                iceConfiguration: webRTCConfiguration
            ))
        } ?? HostAgentWebRTCDataChannelAcceptor(
            configuration: webRTCConfiguration
        ),
        service: service,
        onEvent: { event in
            writeP2PDiagnosticsLine("CodexPort Host Agent P2P listener: \(event.logDescription)", runID: diagnosticsRunID)
        }
    )
    listener.start()
    writeP2PDiagnosticsLine(
        "CodexPort Host Agent P2P signaling listener polling \(relayConfiguration.relayBaseURL.absoluteString)",
        runID: diagnosticsRunID
    )
    if configuration.webRTCSidecarCommand == nil {
        writeP2PDiagnosticsLine(
            "CodexPort Host Agent P2P DataChannel runtime uses platform WebRTC SDK runtime when linked; otherwise it reports unavailable.",
            runID: diagnosticsRunID
        )
    } else {
        writeP2PDiagnosticsLine(
            "CodexPort Host Agent P2P DataChannel runtime delegated to CODEXPORT_WEBRTC_SIDECAR_PATH.",
            runID: diagnosticsRunID
        )
    }
    await waitForTerminationSignal()
    listener.stop()
    await service.stopAll()
}

private func waitForTerminationSignal() async {
    let waiter = HostAgentTerminationSignalWaiter()
    await waiter.wait()
}

private func writeStdoutLine(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func writeP2PDiagnosticsLine(_ line: String, runID: String?) {
    guard let runID, !runID.isEmpty else {
        writeStdoutLine(line)
        return
    }
    writeStdoutLine("\(line) run=\(runID)")
}

private struct HostAgentIdleThreadListOutput: Codable {
    var generatedAtUnixTime: TimeInterval
    var threads: [HostAgentIdleThreadSummary]
}

private struct HostAgentIdleThreadSummary: Codable {
    var id: String
    var status: String
    var updatedAtUnixTime: TimeInterval
    var cwd: String?
    var gitRepository: String?
    var gitBranch: String?
    var previewBytes: Int

    init(snapshot: RelayThreadSummarySnapshot) {
        self.id = snapshot.id
        self.status = snapshot.status
        self.updatedAtUnixTime = snapshot.updatedAtUnixTime
        self.cwd = snapshot.cwd
        self.gitRepository = snapshot.gitRepository
        self.gitBranch = snapshot.gitBranch
        self.previewBytes = snapshot.preview.utf8.count
    }
}

private extension RelayThreadSummarySnapshot {
    var isIdleCandidate: Bool {
        let normalizedStatus = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ![
            "busy",
            "in_progress",
            "in-progress",
            "pending",
            "processing",
            "queued",
            "running",
            "started",
            "working",
        ].contains(normalizedStatus)
    }
}

private extension HostAgentP2PSignalingListenerEvent {
    var logDescription: String {
        switch self {
        case let .hostPresencePublished(hostID):
            "hostPresencePublished host=\(hostID)"
        case let .hostPresencePublishFailed(reason):
            "hostPresencePublishFailed reasonBytes=\(reason.utf8.count)"
        case let .pollFailed(reason):
            "pollFailed reasonBytes=\(reason.utf8.count)"
        case let .offerReceived(sessionID, deviceID):
            "offerReceived session=\(sessionID) device=\(deviceID)"
        case let .dataChannelAccepted(sessionID, deviceID):
            "dataChannelAccepted session=\(sessionID) device=\(deviceID)"
        case let .dataChannelAcceptFailed(sessionID, reason):
            "dataChannelAcceptFailed session=\(sessionID) reasonBytes=\(reason.utf8.count)"
        case let .dataChannelCommandReceived(sessionID, summary):
            "dataChannelCommandReceived p2pSession=\(sessionID) \(summary.logDescription)"
        case let .dataChannelCommandOutput(sessionID, summary):
            "dataChannelCommandOutput p2pSession=\(sessionID) \(summary.logDescription)"
        case let .dataChannelCommandFailed(sessionID, inputBytes, reason):
            "dataChannelCommandFailed p2pSession=\(sessionID) bytes=\(inputBytes) reasonBytes=\(reason.utf8.count)"
        }
    }
}

private final class HostAgentTerminationSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "codexport-host-agent.signals")
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            install(signalNumber: SIGINT)
            install(signalNumber: SIGTERM)
        }
    }

    private func install(signalNumber: Int32) {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler { [weak self] in
            self?.resume()
        }
        lock.withLock {
            sources.append(source)
        }
        source.resume()
    }

    private func resume() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            for source in sources {
                source.cancel()
            }
            sources.removeAll()
            return continuation
        }
        continuation?.resume()
    }
}
