import CodexPortRelayCore
import CodexPortShared
import Foundation
import Dispatch

let configuration = try RelayServiceConfiguration(arguments: CommandLine.arguments)
let stateStore = FileRelayAuthenticatedStreamGatewayStateStore(directoryPath: configuration.storagePath)
let gateway = RelayAuthenticatedStreamGateway(
    supportedVersions: [.v0_2_0],
    iceConfigurationProvider: configuration.makeICEConfigurationProvider(),
    initialState: try stateStore.load(),
    stateStore: stateStore
)
let service = RelayPublicWebSocketService(
    host: configuration.listenHost,
    port: configuration.listenPort,
    gateway: gateway
)
let endpoints = try await service.start()

print("CodexPort Relay listening on \(configuration.listenHost):\(configuration.listenPort)")
print("Public stream endpoint: \(configuration.streamEndpointURL.absoluteString)")
print("Host Agent endpoint: \(configuration.hostConnectURL.absoluteString)")
print("Local stream endpoint: \(endpoints.streamEndpointURL.absoluteString)")
print("Local Host Agent endpoint: \(endpoints.hostConnectURL.absoluteString)")

if ProcessInfo.processInfo.environment["CODEXPORT_RELAY_SMOKE_EXIT_AFTER_START"] == "1" {
    await service.stop()
} else {
    await RelayServiceTerminationSignalWaiter().wait()
    await service.stop()
}

private final class RelayServiceTerminationSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "codexport-relay.signals")
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
