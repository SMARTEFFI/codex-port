import Foundation
import CodexPortShared

public struct HostAgentP2PAcceptRequest: Equatable, Sendable {
    public var session: RelayP2POpenSessionResponse
    public var offer: RelayP2PSignalingMessageDTO
    public var iceConfiguration: WebRTCRuntimeConfiguration?

    public init(
        session: RelayP2POpenSessionResponse,
        offer: RelayP2PSignalingMessageDTO,
        iceConfiguration: WebRTCRuntimeConfiguration? = nil
    ) {
        self.session = session
        self.offer = offer
        self.iceConfiguration = iceConfiguration
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

    func restartICE(
        _ request: HostAgentP2PAcceptRequest,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> HostAgentP2PAcceptResponse

    func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws
}

public protocol HostAgentP2PDataChannelAcceptorFactory: Sendable {
    func makeAcceptor(configuration: WebRTCRuntimeConfiguration) -> HostAgentP2PDataChannelAccepting
}

public struct StaticHostAgentP2PDataChannelAcceptorFactory: HostAgentP2PDataChannelAcceptorFactory {
    private let acceptor: HostAgentP2PDataChannelAccepting

    public init(acceptor: HostAgentP2PDataChannelAccepting) {
        self.acceptor = acceptor
    }

    public func makeAcceptor(configuration: WebRTCRuntimeConfiguration) -> HostAgentP2PDataChannelAccepting {
        acceptor
    }
}

public extension HostAgentP2PDataChannelAccepting {
    func restartICE(
        _ request: HostAgentP2PAcceptRequest,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> HostAgentP2PAcceptResponse {
        try await accept(request)
    }

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
    private let acceptorFactory: HostAgentP2PDataChannelAcceptorFactory
    private let service: HostAgentLocalRelayService
    private let pollInterval: Duration
    private let onEvent: EventHandler
    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var endpoints: [UUID: HostAgentP2PDataChannelEndpoint] = [:]
    private var dataChannels: [UUID: WebRTCDataChannelTransport] = [:]
    private var acceptors: [UUID: HostAgentP2PDataChannelAccepting] = [:]
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
        self.acceptorFactory = StaticHostAgentP2PDataChannelAcceptorFactory(acceptor: acceptor)
        self.service = service
        self.pollInterval = pollInterval
        self.onEvent = onEvent
    }

    public convenience init(
        host: RelayHostIdentity,
        signalingClient: HostAgentP2PSignalingClient,
        acceptor: HostAgentP2PDataChannelAccepting,
        service: HostAgentLocalRelayService,
        pollInterval: Duration = .seconds(1),
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.init(
            host: host,
            signalingClient: signalingClient,
            acceptorFactory: StaticHostAgentP2PDataChannelAcceptorFactory(acceptor: acceptor),
            service: service,
            pollInterval: pollInterval,
            onEvent: onEvent
        )
    }

    public init(
        host: RelayHostIdentity,
        signalingClient: HostAgentP2PSignalingClient,
        acceptorFactory: HostAgentP2PDataChannelAcceptorFactory,
        service: HostAgentLocalRelayService,
        pollInterval: Duration = .seconds(1),
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.host = host
        self.signalingClient = signalingClient
        self.acceptorFactory = acceptorFactory
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
            self.acceptors.removeAll()
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
        let existingSessionState = lock.withLock { (dataChannels[sessionID], acceptors[sessionID]) }
        if let dataChannel = existingSessionState.0,
           let acceptor = existingSessionState.1 {
            switch Self.offerIntent(for: drained.message) {
            case .iceRestart:
                await restartICEForAcceptedOffer(drained, acceptor: acceptor, dataChannel: dataChannel)
            case .openDataChannel:
                await replaceAcceptedDataChannel(drained, acceptor: acceptor)
            }
            return
        }

        let shouldAccept = lock.withLock {
            guard !isStopped, !acceptedSessionIDs.contains(sessionID) else { return false }
            acceptedSessionIDs.insert(sessionID)
            return true
        }
        guard shouldAccept else { return }

        do {
            await onEvent(.offerReceived(sessionID: sessionID, deviceID: drained.session.deviceID))
            let iceConfiguration = try await signalingClient.iceConfiguration(
                hostID: drained.session.hostID,
                deviceID: drained.session.deviceID,
                pairingRecordID: drained.session.pairingRecordID,
                supportedVersions: [drained.session.selectedVersion]
            ).configuration
            let acceptor = acceptorFactory.makeAcceptor(configuration: iceConfiguration)
            let response = try await acceptor.accept(HostAgentP2PAcceptRequest(
                session: drained.session,
                offer: drained.message,
                iceConfiguration: iceConfiguration
            ))
            try await signalingClient.send(response.answer, sessionID: sessionID)
            for candidate in response.iceCandidates {
                try await signalingClient.send(candidate, sessionID: sessionID)
            }
            let localICEForwardTask = makeLocalICEForwardTask(
                sessionID: sessionID,
                updates: response.localICECandidateUpdates
            )
            let endpoint = makeEndpoint(sessionID: sessionID, dataChannel: response.dataChannel)
            endpoint.start()
            lock.withLock {
                guard !isStopped else {
                    endpoint.stop()
                    localICEForwardTask.cancel()
                    return
                }
                endpoints[sessionID] = endpoint
                dataChannels[sessionID] = response.dataChannel
                acceptors[sessionID] = acceptor
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

    private func replaceAcceptedDataChannel(
        _ drained: RelayP2PHostDrainedMessageDTO,
        acceptor: HostAgentP2PDataChannelAccepting
    ) async {
        let sessionID = drained.session.sessionID
        do {
            await onEvent(.offerReceived(sessionID: sessionID, deviceID: drained.session.deviceID))
            let iceConfiguration = try await signalingClient.iceConfiguration(
                hostID: drained.session.hostID,
                deviceID: drained.session.deviceID,
                pairingRecordID: drained.session.pairingRecordID,
                supportedVersions: [drained.session.selectedVersion]
            ).configuration
            let response = try await acceptor.accept(HostAgentP2PAcceptRequest(
                session: drained.session,
                offer: drained.message,
                iceConfiguration: iceConfiguration
            ))
            try await signalingClient.send(response.answer, sessionID: sessionID)
            for candidate in response.iceCandidates {
                try await signalingClient.send(candidate, sessionID: sessionID)
            }
            let endpoint = makeEndpoint(sessionID: sessionID, dataChannel: response.dataChannel)
            endpoint.start()
            let localICEForwardTask = makeLocalICEForwardTask(
                sessionID: sessionID,
                updates: response.localICECandidateUpdates
            )
            let previous = lock.withLock {
                let previous = (endpoints[sessionID], localICEForwardTasks[sessionID])
                endpoints[sessionID] = endpoint
                dataChannels[sessionID] = response.dataChannel
                localICEForwardTasks[sessionID] = localICEForwardTask
                return previous
            }
            previous.0?.stop()
            previous.1?.cancel()
            await applyPendingRemoteICECandidates(sessionID: sessionID, dataChannel: response.dataChannel)
            await onEvent(.dataChannelAccepted(sessionID: sessionID, deviceID: drained.session.deviceID))
        } catch {
            await onEvent(.dataChannelAcceptFailed(sessionID: sessionID, reason: String(describing: error)))
        }
    }

    private func makeEndpoint(
        sessionID: UUID,
        dataChannel: WebRTCDataChannelTransport
    ) -> HostAgentP2PDataChannelEndpoint {
        HostAgentP2PDataChannelEndpoint(
            dataChannel: dataChannel,
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
    }

    private func restartICEForAcceptedOffer(
        _ drained: RelayP2PHostDrainedMessageDTO,
        acceptor: HostAgentP2PDataChannelAccepting,
        dataChannel: WebRTCDataChannelTransport
    ) async {
        let sessionID = drained.session.sessionID
        do {
            await onEvent(.offerReceived(sessionID: sessionID, deviceID: drained.session.deviceID))
            let iceConfiguration = try await signalingClient.iceConfiguration(
                hostID: drained.session.hostID,
                deviceID: drained.session.deviceID,
                pairingRecordID: drained.session.pairingRecordID,
                supportedVersions: [drained.session.selectedVersion]
            ).configuration
            let response = try await acceptor.restartICE(
                HostAgentP2PAcceptRequest(
                    session: drained.session,
                    offer: drained.message,
                    iceConfiguration: iceConfiguration
                ),
                dataChannel: dataChannel
            )
            try await signalingClient.send(response.answer, sessionID: sessionID)
            for candidate in response.iceCandidates {
                try await signalingClient.send(candidate, sessionID: sessionID)
            }
            replaceLocalICEForwardTask(
                sessionID: sessionID,
                updates: response.localICECandidateUpdates
            )
            await onEvent(.dataChannelAccepted(sessionID: sessionID, deviceID: drained.session.deviceID))
        } catch {
            await onEvent(.dataChannelAcceptFailed(sessionID: sessionID, reason: String(describing: error)))
        }
    }

    private func replaceLocalICEForwardTask(
        sessionID: UUID,
        updates: AsyncStream<RelayP2PSignalingMessageDTO>
    ) {
        let task = makeLocalICEForwardTask(sessionID: sessionID, updates: updates)
        let previous = lock.withLock {
            localICEForwardTasks.updateValue(task, forKey: sessionID)
        }
        previous?.cancel()
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
        let sessionState = lock.withLock { (dataChannels[sessionID], acceptors[sessionID]) }
        guard let dataChannel = sessionState.0, let acceptor = sessionState.1 else {
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
        guard let acceptor = lock.withLock({ acceptors[sessionID] }) else {
            return
        }
        for message in pending {
            try? await acceptor.addRemoteICECandidate(
                message,
                sessionID: sessionID,
                to: dataChannel
            )
        }
    }

    private static func offerIntent(for message: RelayP2PSignalingMessageDTO) -> WebRTCSessionDescriptionOfferIntent {
        guard let data = message.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["intent"] != nil else {
            return .iceRestart
        }
        guard let offer = try? RelayP2PWebRTCSignalingPayloadCodec.decodeOffer(message.payload) else {
            return .iceRestart
        }
        return offer.intent
    }
}

public struct UnavailableHostAgentP2PDataChannelAcceptor: HostAgentP2PDataChannelAccepting {
    public init() {}

    public func accept(_ request: HostAgentP2PAcceptRequest) async throws -> HostAgentP2PAcceptResponse {
        throw HostAgentP2PDataChannelAcceptorError.runtimeUnavailable(
            "Real HostAgent WebRTC DataChannel runtime is not linked. Configure a production HostAgentP2PDataChannelAccepting implementation before enabling P2P listener mode."
        )
    }

    public func restartICE(
        _ request: HostAgentP2PAcceptRequest,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> HostAgentP2PAcceptResponse {
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
