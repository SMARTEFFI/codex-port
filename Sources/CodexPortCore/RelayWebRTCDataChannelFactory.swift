import Foundation
import CodexPortShared
import CodexPortWebRTC

public struct RelayWebRTCDataChannelFactory: RelayP2PDataChannelFactory {
    private let signalingClient: RelayP2PSignalingClient
    private let configuration: WebRTCRuntimeConfiguration
    private let runtime: WebRTCPlatformDataChannelOpening
    private let answerTimeout: Duration
    private let dataChannelOpenTimeout: Duration
    private let remoteICEPollingDuration: Duration

    public init(
        signalingClient: RelayP2PSignalingClient,
        configuration: WebRTCRuntimeConfiguration,
        runtime: WebRTCPlatformDataChannelOpening = DefaultWebRTCPlatformDataChannelRuntime.makeOpeningRuntime(),
        answerTimeout: Duration = .seconds(8),
        dataChannelOpenTimeout: Duration = .seconds(8),
        remoteICEPollingDuration: Duration = .seconds(8)
    ) {
        self.signalingClient = signalingClient
        self.configuration = configuration
        self.runtime = runtime
        self.answerTimeout = answerTimeout
        self.dataChannelOpenTimeout = dataChannelOpenTimeout
        self.remoteICEPollingDuration = remoteICEPollingDuration
    }

    public func openDataChannel(_ request: RelayP2PDataChannelOpenRequest) async throws -> any WebRTCDataChannelTransport {
        let opened = try await runtime.openDataChannel(
            session: request.session,
            configuration: configuration
        )
        try await signalingClient.send(
            RelayP2PSignalingMessageDTO(
                from: .device,
                to: .host,
                kind: .offer,
                payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(opened.offer)
            ),
            sessionID: request.session.sessionID
        )
        for candidate in opened.localICECandidates {
            try await signalingClient.send(
                RelayP2PSignalingMessageDTO(
                    from: .device,
                    to: .host,
                    kind: .iceCandidate,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                ),
                sessionID: request.session.sessionID
            )
        }
        let localICEForwardTask = makeLocalICEForwardTask(
            sessionID: request.session.sessionID,
            updates: opened.localICECandidateUpdates
        )
        var processedICEPayloads: Set<String> = []
        do {
            try await waitForAnswerAndCandidates(
                sessionID: request.session.sessionID,
                dataChannel: opened.dataChannel,
                processedICEPayloads: &processedICEPayloads
            )
            try await waitForDataChannelOpen(opened.dataChannel)
            let remoteICEPollingTask = makeRemoteICEPollingTask(
                sessionID: request.session.sessionID,
                dataChannel: opened.dataChannel,
                processedICEPayloads: processedICEPayloads
            )
            return RelayICEForwardingDataChannelTransport(
                dataChannel: opened.dataChannel,
                localICEForwardTask: localICEForwardTask,
                remoteICEPollingTask: remoteICEPollingTask
            )
        } catch {
            localICEForwardTask.cancel()
            throw error
        }
    }

    private func makeLocalICEForwardTask(
        sessionID: UUID,
        updates: AsyncStream<WebRTCICECandidatePayload>
    ) -> Task<Void, Never> {
        Task { [signalingClient] in
            for await candidate in updates {
                guard !Task.isCancelled else { return }
                let message: RelayP2PSignalingMessageDTO
                do {
                    message = RelayP2PSignalingMessageDTO(
                        from: .device,
                        to: .host,
                        kind: .iceCandidate,
                        payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                    )
                    try await signalingClient.send(message, sessionID: sessionID)
                } catch {
                    return
                }
            }
        }
    }

    private func waitForAnswerAndCandidates(
        sessionID: UUID,
        dataChannel: WebRTCDataChannelTransport,
        processedICEPayloads: inout Set<String>
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: answerTimeout)
        var didApplyAnswer = false

        while clock.now < deadline {
            let messages = try await signalingClient.drainMessages(sessionID: sessionID, endpoint: .device)
            for message in messages {
                switch message.kind {
                case .answer:
                    let answer: WebRTCSessionDescriptionPayload
                    do {
                        answer = try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(message.payload)
                    } catch {
                        throw WebRTCPlatformRuntimeError.invalidAnswerPayload
                    }
                    try await runtime.applyRemoteAnswer(answer, to: dataChannel)
                    didApplyAnswer = true
                case .iceCandidate:
                    guard !processedICEPayloads.contains(message.payload) else { continue }
                    let candidate: WebRTCICECandidatePayload
                    do {
                        candidate = try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(message.payload)
                    } catch {
                        throw WebRTCPlatformRuntimeError.invalidICECandidatePayload
                    }
                    try await runtime.addRemoteICECandidate(candidate, to: dataChannel)
                    processedICEPayloads.insert(message.payload)
                case .offer:
                    continue
                }
            }
            if didApplyAnswer {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebRTCPlatformRuntimeError.answerTimedOut
    }

    private func waitForDataChannelOpen(_ dataChannel: WebRTCDataChannelTransport) async throws {
        let stateUpdates = dataChannel.stateUpdates
        let timeout = dataChannelOpenTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stateUpdates.makeAsyncIterator()
                while let state = await iterator.next() {
                    switch state {
                    case .dataChannelOpen:
                        return
                    case .dataChannelClosed:
                        throw WebRTCDataChannelTransportError.dataChannelClosed
                    case let .directFailed(reason), let .turnFailed(reason):
                        throw WebRTCDataChannelTransportError.iceFailed(reason: reason)
                    case .iceGathering, .directConnected, .turnRelayedConnected:
                        continue
                    }
                }
                throw WebRTCDataChannelTransportError.dataChannelNotOpen
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebRTCDataChannelTransportError.dataChannelNotOpen
            }
            guard let result = try await group.next() else {
                throw WebRTCDataChannelTransportError.dataChannelNotOpen
            }
            group.cancelAll()
            return result
        }
    }

    private func makeRemoteICEPollingTask(
        sessionID: UUID,
        dataChannel: WebRTCDataChannelTransport,
        processedICEPayloads: Set<String>
    ) -> Task<Void, Never> {
        Task { [signalingClient, runtime, remoteICEPollingDuration] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: remoteICEPollingDuration)
            var processedICEPayloads = processedICEPayloads
            while clock.now < deadline && !Task.isCancelled {
                do {
                    let messages = try await signalingClient.drainMessages(sessionID: sessionID, endpoint: .device)
                    for message in messages where message.kind == .iceCandidate {
                        guard !processedICEPayloads.contains(message.payload) else { continue }
                        let candidate = try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(message.payload)
                        try await runtime.addRemoteICECandidate(candidate, to: dataChannel)
                        processedICEPayloads.insert(message.payload)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }
}

private final class RelayICEForwardingDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    let configuration: WebRTCDataChannelConfiguration
    let incomingMessages: AsyncStream<Data>
    let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>

    private let dataChannel: WebRTCDataChannelTransport
    private let localICEForwardTask: Task<Void, Never>
    private let remoteICEPollingTask: Task<Void, Never>

    init(
        dataChannel: WebRTCDataChannelTransport,
        localICEForwardTask: Task<Void, Never>,
        remoteICEPollingTask: Task<Void, Never>
    ) {
        self.dataChannel = dataChannel
        self.localICEForwardTask = localICEForwardTask
        self.remoteICEPollingTask = remoteICEPollingTask
        configuration = dataChannel.configuration
        incomingMessages = dataChannel.incomingMessages
        stateUpdates = dataChannel.stateUpdates
    }

    deinit {
        localICEForwardTask.cancel()
        remoteICEPollingTask.cancel()
    }

    func send(_ message: Data) async throws {
        try await dataChannel.send(message)
    }
}
