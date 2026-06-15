import Foundation
import CodexPortShared

public struct HostAgentP2PAcceptRequest: Equatable, Sendable {
    public var session: RelayP2POpenSessionResponse
    public var offer: RelayP2PSignalingMessageDTO

    public init(session: RelayP2POpenSessionResponse, offer: RelayP2PSignalingMessageDTO) {
        self.session = session
        self.offer = offer
    }
}

public struct HostAgentP2PAcceptResponse: Sendable {
    public var answer: RelayP2PSignalingMessageDTO
    public var iceCandidates: [RelayP2PSignalingMessageDTO]
    public var localICECandidateUpdates: AsyncStream<RelayP2PSignalingMessageDTO>
    public var dataChannel: WebRTCDataChannelTransport

    public init(
        answer: RelayP2PSignalingMessageDTO,
        iceCandidates: [RelayP2PSignalingMessageDTO],
        localICECandidateUpdates: AsyncStream<RelayP2PSignalingMessageDTO> = AsyncStream { $0.finish() },
        dataChannel: WebRTCDataChannelTransport
    ) {
        self.answer = answer
        self.iceCandidates = iceCandidates
        self.localICECandidateUpdates = localICECandidateUpdates
        self.dataChannel = dataChannel
    }
}

public protocol HostAgentP2PDataChannelAccepting: Sendable {
    func accept(_ request: HostAgentP2PAcceptRequest) async throws -> HostAgentP2PAcceptResponse

    func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws
}

public extension HostAgentP2PDataChannelAccepting {
    func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {}
}

public enum HostAgentP2PSignalingListenerEvent: Equatable, Sendable {
    case hostPresencePublished(hostID: UUID)
    case hostPresencePublishFailed(reason: String)
    case pollFailed(reason: String)
    case offerReceived(sessionID: UUID, deviceID: UUID)
    case dataChannelAccepted(sessionID: UUID, deviceID: UUID)
    case dataChannelAcceptFailed(sessionID: UUID, reason: String)
    case dataChannelCommandReceived(sessionID: UUID, HostAgentLocalRelayCommandDiagnosticSummary)
    case dataChannelCommandOutput(sessionID: UUID, HostAgentLocalRelayOutputDiagnosticSummary)
    case dataChannelCommandFailed(sessionID: UUID, inputBytes: Int, reason: String)
}

public final class HostAgentP2PSignalingListener: @unchecked Sendable {
    public typealias EventHandler = @Sendable (HostAgentP2PSignalingListenerEvent) async -> Void

    private let host: RelayHostIdentity
    private let signalingClient: HostAgentP2PSignalingClient
    private let acceptor: HostAgentP2PDataChannelAccepting
    private let service: HostAgentLocalRelayService
    private let pollInterval: Duration
    private let onEvent: EventHandler
    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var endpoints: [UUID: HostAgentP2PDataChannelEndpoint] = [:]
    private var dataChannels: [UUID: WebRTCDataChannelTransport] = [:]
    private var localICEForwardTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRemoteICECandidates: [UUID: [RelayP2PSignalingMessageDTO]] = [:]
    private var acceptedSessionIDs: Set<UUID> = []
    private var isStopped = true

    public init(
        hostID: UUID,
        signalingClient: HostAgentP2PSignalingClient,
        acceptor: HostAgentP2PDataChannelAccepting,
        service: HostAgentLocalRelayService,
        pollInterval: Duration = .seconds(1),
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.host = RelayHostIdentity(
            id: hostID,
            displayName: "CodexPort Host",
            userName: NSUserName(),
            publicKey: EndpointPublicKey(rawValue: Data("host-agent-public-key".utf8))
        )
        self.signalingClient = signalingClient
        self.acceptor = acceptor
        self.service = service
        self.pollInterval = pollInterval
        self.onEvent = onEvent
    }

    public init(
        host: RelayHostIdentity,
        signalingClient: HostAgentP2PSignalingClient,
        acceptor: HostAgentP2PDataChannelAccepting,
        service: HostAgentLocalRelayService,
        pollInterval: Duration = .seconds(1),
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.host = host
        self.signalingClient = signalingClient
        self.acceptor = acceptor
        self.service = service
        self.pollInterval = pollInterval
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    public func start() {
        let task = Task { [weak self] in
            await self?.publishHostPresence()
            while !Task.isCancelled {
                await self?.pollOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
        let shouldRun = lock.withLock {
            guard pollTask == nil else { return false }
            isStopped = false
            pollTask = task
            return true
        }
        if !shouldRun {
            task.cancel()
        }
    }

    public func stop() {
        let snapshot = lock.withLock {
            isStopped = true
            let pollTask = self.pollTask
            self.pollTask = nil
            let endpoints = Array(self.endpoints.values)
            let localICEForwardTasks = Array(self.localICEForwardTasks.values)
            self.endpoints.removeAll()
            self.dataChannels.removeAll()
            self.localICEForwardTasks.removeAll()
            self.pendingRemoteICECandidates.removeAll()
            self.acceptedSessionIDs.removeAll()
            return (pollTask, endpoints, localICEForwardTasks)
        }
        snapshot.0?.cancel()
        for endpoint in snapshot.1 {
            endpoint.stop()
        }
        for task in snapshot.2 {
            task.cancel()
        }
    }

    public func pollOnce() async {
        guard !lock.withLock({ isStopped }) else { return }
        let messages: [RelayP2PHostDrainedMessageDTO]
        do {
            messages = try await signalingClient.drainHostMessages(hostID: host.id)
        } catch {
            await onEvent(.pollFailed(reason: String(describing: error)))
            return
        }
        for drained in messages {
            switch drained.message.kind {
            case .offer:
                await acceptOfferIfNeeded(drained)
            case .iceCandidate:
                await applyRemoteICECandidateIfPossible(drained)
            case .answer:
                continue
            }
        }
    }

    private func publishHostPresence() async {
        guard !lock.withLock({ isStopped }) else { return }
        do {
            _ = try await signalingClient.publishHostPresence(host)
            await onEvent(.hostPresencePublished(hostID: host.id))
        } catch {
            await onEvent(.hostPresencePublishFailed(reason: String(describing: error)))
        }
    }

    private func acceptOfferIfNeeded(_ drained: RelayP2PHostDrainedMessageDTO) async {
        let sessionID = drained.session.sessionID
        let shouldAccept = lock.withLock {
            guard !isStopped, !acceptedSessionIDs.contains(sessionID) else { return false }
            acceptedSessionIDs.insert(sessionID)
            return true
        }
        guard shouldAccept else { return }

        do {
            await onEvent(.offerReceived(sessionID: sessionID, deviceID: drained.session.deviceID))
            let response = try await acceptor.accept(HostAgentP2PAcceptRequest(
                session: drained.session,
                offer: drained.message
            ))
            try await signalingClient.send(response.answer, sessionID: sessionID)
            for candidate in response.iceCandidates {
                try await signalingClient.send(candidate, sessionID: sessionID)
            }
            let localICEForwardTask = makeLocalICEForwardTask(
                sessionID: sessionID,
                updates: response.localICECandidateUpdates
            )
            let endpoint = HostAgentP2PDataChannelEndpoint(
                dataChannel: response.dataChannel,
                service: service,
                onEvent: { [onEvent] event in
                    switch event {
                    case let .commandReceived(summary):
                        await onEvent(.dataChannelCommandReceived(sessionID: sessionID, summary))
                    case let .commandOutput(summary):
                        await onEvent(.dataChannelCommandOutput(sessionID: sessionID, summary))
                    case let .commandFailed(inputBytes, reason):
                        await onEvent(.dataChannelCommandFailed(sessionID: sessionID, inputBytes: inputBytes, reason: reason))
                    }
                }
            )
            endpoint.start()
            lock.withLock {
                guard !isStopped else {
                    endpoint.stop()
                    localICEForwardTask.cancel()
                    return
                }
                endpoints[sessionID] = endpoint
                dataChannels[sessionID] = response.dataChannel
                localICEForwardTasks[sessionID] = localICEForwardTask
            }
            await applyPendingRemoteICECandidates(sessionID: sessionID, dataChannel: response.dataChannel)
            await onEvent(.dataChannelAccepted(sessionID: sessionID, deviceID: drained.session.deviceID))
        } catch {
            _ = lock.withLock {
                acceptedSessionIDs.remove(sessionID)
            }
            await onEvent(.dataChannelAcceptFailed(sessionID: sessionID, reason: String(describing: error)))
        }
    }

    private func makeLocalICEForwardTask(
        sessionID: UUID,
        updates: AsyncStream<RelayP2PSignalingMessageDTO>
    ) -> Task<Void, Never> {
        Task { [signalingClient] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                try? await signalingClient.send(update, sessionID: sessionID)
            }
        }
    }

    private func applyRemoteICECandidateIfPossible(_ drained: RelayP2PHostDrainedMessageDTO) async {
        let sessionID = drained.session.sessionID
        let dataChannel = lock.withLock { dataChannels[sessionID] }
        guard let dataChannel else {
            lock.withLock {
                pendingRemoteICECandidates[sessionID, default: []].append(drained.message)
            }
            return
        }
        try? await acceptor.addRemoteICECandidate(
            drained.message,
            sessionID: sessionID,
            to: dataChannel
        )
    }

    private func applyPendingRemoteICECandidates(
        sessionID: UUID,
        dataChannel: WebRTCDataChannelTransport
    ) async {
        let pending = lock.withLock {
            let pending = pendingRemoteICECandidates[sessionID] ?? []
            pendingRemoteICECandidates.removeValue(forKey: sessionID)
            return pending
        }
        for message in pending {
            try? await acceptor.addRemoteICECandidate(
                message,
                sessionID: sessionID,
                to: dataChannel
            )
        }
    }
}

public struct UnavailableHostAgentP2PDataChannelAcceptor: HostAgentP2PDataChannelAccepting {
    public init() {}

    public func accept(_ request: HostAgentP2PAcceptRequest) async throws -> HostAgentP2PAcceptResponse {
        throw HostAgentP2PDataChannelAcceptorError.runtimeUnavailable(
            "Real HostAgent WebRTC DataChannel runtime is not linked. Configure a production HostAgentP2PDataChannelAccepting implementation before enabling P2P listener mode."
        )
    }

    public func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        throw HostAgentP2PDataChannelAcceptorError.runtimeUnavailable(
            "Real HostAgent WebRTC DataChannel runtime is not linked. Configure a production HostAgentP2PDataChannelAccepting implementation before enabling P2P listener mode."
        )
    }
}

public enum HostAgentP2PDataChannelAcceptorError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
}
