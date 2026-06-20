import Foundation
import CodexPortShared
import CodexPortWebRTC

public enum P2PConnectionRecoveryPath: Equatable, Sendable {
    case direct
    case relay
}

public struct P2PConnectionRecoveryRequest: Sendable {
    public var relayHost: RelayHost
    public var session: RelayP2POpenSessionResponse
    public var threadID: String
    public var dataChannel: WebRTCDataChannelTransport
    public var preferDirect: Bool

    public init(
        relayHost: RelayHost,
        session: RelayP2POpenSessionResponse,
        threadID: String,
        dataChannel: WebRTCDataChannelTransport,
        preferDirect: Bool = true
    ) {
        self.relayHost = relayHost
        self.session = session
        self.threadID = threadID
        self.dataChannel = dataChannel
        self.preferDirect = preferDirect
    }
}

public struct P2PConnectionRecoveryTransport: Sendable {
    public var dataChannel: WebRTCDataChannelTransport
    public var path: P2PConnectionRecoveryPath
    public var historyItems: [VisibleItem]

    public init(
        dataChannel: WebRTCDataChannelTransport,
        path: P2PConnectionRecoveryPath,
        historyItems: [VisibleItem] = []
    ) {
        self.dataChannel = dataChannel
        self.path = path
        self.historyItems = historyItems
    }
}

public struct P2PConnectionRecoveryResult: Sendable {
    public var state: P2PConnectionRecoveryState
    public var transport: P2PConnectionRecoveryTransport

    public init(state: P2PConnectionRecoveryState, transport: P2PConnectionRecoveryTransport) {
        self.state = state
        self.transport = transport
    }
}

public struct P2PDirectProbeResult: Sendable {
    public var state: P2PConnectionRecoveryState
    public var transport: P2PConnectionRecoveryTransport?

    public init(state: P2PConnectionRecoveryState, transport: P2PConnectionRecoveryTransport?) {
        self.state = state
        self.transport = transport
    }
}

public protocol P2PConnectionRecoveryRuntime: Sendable {
    func restartICE(_ request: P2PConnectionRecoveryRequest) async throws -> P2PConnectionRecoveryTransport
    func rebuildPeerConnection(_ request: P2PConnectionRecoveryRequest) async throws -> P2PConnectionRecoveryTransport
    func probeDirectPath(_ request: P2PConnectionRecoveryRequest) async throws -> P2PConnectionRecoveryTransport
}

public protocol P2PConnectionHistoryReconciling: Sendable {
    func reconcile(threadID: String) async throws -> [VisibleItem]
}

public struct EmptyP2PConnectionHistoryReconciler: P2PConnectionHistoryReconciling {
    public init() {}

    public func reconcile(threadID: String) async throws -> [VisibleItem] {
        []
    }
}

public final class P2PConnectionRecoveryCoordinator: @unchecked Sendable {
    private let relayHost: RelayHost
    private let session: RelayP2POpenSessionResponse
    private let threadID: String
    private let runtime: P2PConnectionRecoveryRuntime
    private let historyReconciler: P2PConnectionHistoryReconciling
    private let lock = NSLock()
    private var state: P2PConnectionRecoveryState
    private var currentDataChannel: WebRTCDataChannelTransport

    public init(
        relayHost: RelayHost,
        session: RelayP2POpenSessionResponse,
        threadID: String,
        dataChannel: WebRTCDataChannelTransport,
        runtime: P2PConnectionRecoveryRuntime,
        initialPath: P2PConnectionRecoveryPath = .direct,
        historyReconciler: P2PConnectionHistoryReconciling = EmptyP2PConnectionHistoryReconciler()
    ) {
        self.relayHost = relayHost
        self.session = session
        self.threadID = threadID
        self.currentDataChannel = dataChannel
        self.runtime = runtime
        self.historyReconciler = historyReconciler

        var pathState = RemoteConnectionPathState(
            signaling: .authorizedToSignal,
            ice: .gathering,
            dataPath: initialPath == .direct ? .directConnected : .turnRelayedConnected,
            dataChannel: .open,
            hostProtocol: .ready,
            codexLiveSource: .ready
        )
        if initialPath == .relay {
            pathState.markDirectProbeActive(reason: "relay fallback")
        }
        state = P2PConnectionRecoveryState(
            pathState: pathState,
            loadedHistoryItems: [],
            sessionID: session.sessionID.uuidString,
            threadID: threadID
        )
    }

    public var currentState: P2PConnectionRecoveryState {
        lock.withLock { state }
    }

    public func recoverAfterForeground() async throws -> P2PConnectionRecoveryResult {
        try await recover(trigger: .foregrounded)
    }

    public func recoverAfterNetworkChange() async throws -> P2PConnectionRecoveryResult {
        try await recover(trigger: .networkChanged)
    }

    public func recoverAfterWebRTCFailure(_ failure: WebRTCDataChannelConnectionState) async throws -> P2PConnectionRecoveryResult {
        mutate { state in
            state.apply(.webRTC(failure))
        }
        return try await recover(trigger: .staleDataChannelClosed(reason: "WebRTC failure"))
    }

    public func recoverAfterDataChannelClose(reason: String) async throws -> P2PConnectionRecoveryResult {
        try await recover(trigger: .staleDataChannelClosed(reason: reason))
    }

    public func probeDirectPath() async -> P2PDirectProbeResult {
        mutate { state in
            state.apply(.relayFallbackActive)
        }
        return await runDirectProbe()
    }

    public func retryDirectProbeNow() async -> P2PDirectProbeResult {
        mutate { state in
            state.apply(.manualRetryRequested)
        }
        return await runDirectProbe()
    }

    private func recover(trigger: P2PConnectionRecoveryEvent) async throws -> P2PConnectionRecoveryResult {
        mutate { state in
            state.apply(trigger)
        }
        let request = makeRequest(preferDirect: true)
        do {
            let transport = try await runtime.restartICE(request)
            return try await complete(with: transport)
        } catch {
            mutate { state in
                state.apply(.iceRestartFailed(reason: String(describing: error)))
                state.apply(.replacementStarted)
            }
            let rebuilt = try await runtime.rebuildPeerConnection(request)
            return try await complete(with: rebuilt)
        }
    }

    private func runDirectProbe() async -> P2PDirectProbeResult {
        let request = makeRequest(preferDirect: true)
        do {
            let transport = try await runtime.probeDirectPath(request)
            var completedState = try await complete(with: transport).state
            completedState.apply(.directProbeSucceeded)
            lock.withLock {
                state = completedState
            }
            return P2PDirectProbeResult(state: completedState, transport: transport)
        } catch {
            let failedState = mutate { state in
                state.apply(.directProbeFailed(reason: String(describing: error)))
            }
            return P2PDirectProbeResult(state: failedState, transport: nil)
        }
    }

    private func complete(with transport: P2PConnectionRecoveryTransport) async throws -> P2PConnectionRecoveryResult {
        currentDataChannel = transport.dataChannel
        var items = transport.historyItems
        if items.isEmpty {
            items = try await historyReconciler.reconcile(threadID: threadID)
        }
        let completed = mutate { state in
            state.apply(.webRTC(transport.path == .direct ? .directConnected : .turnRelayedConnected))
            state.apply(.webRTC(.dataChannelOpen))
            state.apply(.hostProtocolReady)
            state.apply(.historyReconciled(items: items))
            state.apply(.codexLiveSourceReady)
        }
        return P2PConnectionRecoveryResult(state: completed, transport: transport)
    }

    private func makeRequest(preferDirect: Bool) -> P2PConnectionRecoveryRequest {
        lock.withLock {
            P2PConnectionRecoveryRequest(
                relayHost: relayHost,
                session: session,
                threadID: threadID,
                dataChannel: currentDataChannel,
                preferDirect: preferDirect
            )
        }
    }

    @discardableResult
    private func mutate(_ update: (inout P2PConnectionRecoveryState) -> Void) -> P2PConnectionRecoveryState {
        lock.withLock {
            update(&state)
            return state
        }
    }
}
