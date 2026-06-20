import Foundation
import CodexPortShared

public protocol WebRTCSidecarInputOutput: Sendable {
    var inputLines: AsyncStream<String> { get }
    func sendLine(_ line: String) async throws
}

public final class FileHandleWebRTCSidecarInputOutput: WebRTCSidecarInputOutput, @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    public let inputLines: AsyncStream<String>

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
        inputLines = AsyncStream { continuation in
            Task.detached { [input] in
                var buffer = Data()
                while true {
                    let data = input.availableData
                    guard !data.isEmpty else {
                        continuation.finish()
                        return
                    }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        continuation.yield(String(decoding: lineData, as: UTF8.self))
                    }
                }
            }
        }
    }

    public func sendLine(_ line: String) async throws {
        try output.write(contentsOf: Data((line + "\n").utf8))
    }
}

public final class WebRTCSidecarRunner: @unchecked Sendable {
    private let runtime: WebRTCPlatformDataChannelAccepting
    private let io: WebRTCSidecarInputOutput
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var dataChannels: [UUID: WebRTCDataChannelTransport] = [:]
    private var localICEForwardTasks: [UUID: Task<Void, Never>] = [:]
    private var incomingForwardTasks: [UUID: Task<Void, Never>] = [:]
    private var stateForwardTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        runtime: WebRTCPlatformDataChannelAccepting = DefaultWebRTCPlatformDataChannelRuntime.makeAcceptingRuntime(),
        io: WebRTCSidecarInputOutput
    ) {
        self.runtime = runtime
        self.io = io
    }

    public func run() async {
        for await line in io.inputLines {
            guard let data = line.data(using: .utf8),
                  let message = try? decoder.decode(WebRTCSidecarMessage.self, from: data) else {
                continue
            }
            await handle(message)
        }
        stopAll()
    }

    private func handle(_ message: WebRTCSidecarMessage) async {
        switch message.type {
        case .accept:
            await handleAccept(message)
        case .restartICE:
            await handleRestartICE(message)
        case .remoteICE:
            await handleRemoteICE(message)
        case .dataChannelSend:
            await handleDataChannelSend(message)
        case .accepted, .localICE, .dataChannelMessage, .dataChannelState, .error:
            break
        }
    }

    private func handleAccept(_ message: WebRTCSidecarMessage) async {
        guard let sessionID = message.sessionID,
              let hostID = message.hostID,
              let deviceID = message.deviceID,
              let offerMessage = message.offer,
              let configuration = message.iceConfiguration else {
            await sendError(sessionID: message.sessionID, reason: "Missing accept fields.")
            return
        }
        let offer: WebRTCSessionDescriptionPayload
        do {
            offer = try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(offerMessage.payload)
        } catch {
            await sendError(sessionID: sessionID, reason: "Invalid offer payload.")
            return
        }
        let session = RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: "sidecar-\(hostID.uuidString)-\(deviceID.uuidString)",
            selectedVersion: .v0_2_0,
            openedAtUnixTime: Date().timeIntervalSince1970
        )
        do {
            let accepted = try await runtime.acceptDataChannel(
                offer: offer,
                session: session,
                configuration: configuration
            )
            lock.withLock {
                dataChannels[sessionID] = accepted.dataChannel
            }
            try await send(WebRTCSidecarMessage(
                type: .accepted,
                sessionID: sessionID,
                answer: RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .answer,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(accepted.answer)
                ),
                iceCandidates: try accepted.localICECandidates.map { candidate in
                    RelayP2PSignalingMessageDTO(
                        from: .host,
                        to: .device,
                        kind: .iceCandidate,
                        payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                    )
                }
            ))
            startForwarding(sessionID: sessionID, accepted: accepted)
        } catch {
            await sendError(sessionID: sessionID, reason: String(describing: error))
        }
    }

    private func handleRemoteICE(_ message: WebRTCSidecarMessage) async {
        guard let sessionID = message.sessionID,
              let candidateMessage = message.candidate,
              let dataChannel = lock.withLock({ dataChannels[sessionID] }) else {
            return
        }
        do {
            let candidate = try RelayP2PWebRTCSignalingPayloadCodec.decodeICECandidate(candidateMessage.payload)
            try await runtime.addRemoteICECandidate(candidate, to: dataChannel)
        } catch {
            await sendError(sessionID: sessionID, reason: String(describing: error))
        }
    }

    private func handleRestartICE(_ message: WebRTCSidecarMessage) async {
        guard let sessionID = message.sessionID,
              let hostID = message.hostID,
              let deviceID = message.deviceID,
              let offerMessage = message.offer,
              let configuration = message.iceConfiguration,
              let dataChannel = lock.withLock({ dataChannels[sessionID] }) else {
            await sendError(sessionID: message.sessionID, reason: "Missing restartICE fields.")
            return
        }
        let offer: WebRTCSessionDescriptionPayload
        do {
            offer = try RelayP2PWebRTCSignalingPayloadCodec.decodeSessionDescription(offerMessage.payload)
        } catch {
            await sendError(sessionID: sessionID, reason: "Invalid offer payload.")
            return
        }
        let session = RelayP2POpenSessionResponse(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: "sidecar-\(hostID.uuidString)-\(deviceID.uuidString)",
            selectedVersion: .v0_2_0,
            openedAtUnixTime: Date().timeIntervalSince1970
        )
        do {
            let accepted = try await runtime.restartICE(
                offer: offer,
                session: session,
                configuration: configuration,
                dataChannel: dataChannel
            )
            try await send(WebRTCSidecarMessage(
                type: .accepted,
                sessionID: sessionID,
                answer: RelayP2PSignalingMessageDTO(
                    from: .host,
                    to: .device,
                    kind: .answer,
                    payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(accepted.answer)
                ),
                iceCandidates: try accepted.localICECandidates.map { candidate in
                    RelayP2PSignalingMessageDTO(
                        from: .host,
                        to: .device,
                        kind: .iceCandidate,
                        payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                    )
                }
            ))
            restartLocalICEForwarding(sessionID: sessionID, updates: accepted.localICECandidateUpdates)
        } catch {
            await sendError(sessionID: sessionID, reason: String(describing: error))
        }
    }

    private func restartLocalICEForwarding(
        sessionID: UUID,
        updates: AsyncStream<WebRTCICECandidatePayload>
    ) {
        let task = Task { [weak self] in
            for await candidate in updates {
                guard !Task.isCancelled else { return }
                do {
                    try await self?.send(WebRTCSidecarMessage(
                        type: .localICE,
                        sessionID: sessionID,
                        candidate: RelayP2PSignalingMessageDTO(
                            from: .host,
                            to: .device,
                            kind: .iceCandidate,
                            payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                        )
                    ))
                } catch {
                    return
                }
            }
        }
        let previous = lock.withLock {
            localICEForwardTasks.updateValue(task, forKey: sessionID)
        }
        previous?.cancel()
    }

    private func handleDataChannelSend(_ message: WebRTCSidecarMessage) async {
        guard let sessionID = message.sessionID,
              let base64 = message.base64,
              let data = Data(base64Encoded: base64),
              let dataChannel = lock.withLock({ dataChannels[sessionID] }) else {
            return
        }
        do {
            try await dataChannel.send(data)
        } catch {
            await sendError(sessionID: sessionID, reason: String(describing: error))
        }
    }

    private func startForwarding(sessionID: UUID, accepted: WebRTCPlatformDataChannelAcceptResult) {
        let localICEForwardTask = Task { [weak self] in
            for await candidate in accepted.localICECandidateUpdates {
                guard !Task.isCancelled else { return }
                do {
                    try await self?.send(WebRTCSidecarMessage(
                        type: .localICE,
                        sessionID: sessionID,
                        candidate: RelayP2PSignalingMessageDTO(
                            from: .host,
                            to: .device,
                            kind: .iceCandidate,
                            payload: try RelayP2PWebRTCSignalingPayloadCodec.encode(candidate)
                        )
                    ))
                } catch {
                    return
                }
            }
        }
        let incomingForwardTask = Task { [weak self] in
            for await data in accepted.dataChannel.incomingMessages {
                guard !Task.isCancelled else { return }
                try? await self?.send(WebRTCSidecarMessage(
                    type: .dataChannelMessage,
                    sessionID: sessionID,
                    base64: data.base64EncodedString()
                ))
            }
        }
        let stateForwardTask = Task { [weak self] in
            for await state in accepted.dataChannel.stateUpdates {
                guard !Task.isCancelled else { return }
                try? await self?.send(Self.message(sessionID: sessionID, state: state))
            }
        }
        lock.withLock {
            localICEForwardTasks[sessionID] = localICEForwardTask
            incomingForwardTasks[sessionID] = incomingForwardTask
            stateForwardTasks[sessionID] = stateForwardTask
        }
    }

    private static func message(sessionID: UUID, state: WebRTCDataChannelConnectionState) -> WebRTCSidecarMessage {
        switch state {
        case .iceGathering:
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "iceGathering")
        case .directConnected:
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "directConnected")
        case let .directFailed(reason):
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "directFailed", reason: reason)
        case .turnRelayedConnected:
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "turnRelayedConnected")
        case let .turnFailed(reason):
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "turnFailed", reason: reason)
        case .dataChannelOpen:
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "dataChannelOpen")
        case .dataChannelClosed:
            return WebRTCSidecarMessage(type: .dataChannelState, sessionID: sessionID, state: "dataChannelClosed")
        }
    }

    private func sendError(sessionID: UUID?, reason: String) async {
        try? await send(WebRTCSidecarMessage(type: .error, sessionID: sessionID, reason: reason))
    }

    private func send(_ message: WebRTCSidecarMessage) async throws {
        try await io.sendLine(String(decoding: encoder.encode(message), as: UTF8.self))
    }

    private func stopAll() {
        let tasks = lock.withLock {
            let tasks = Array(localICEForwardTasks.values) + Array(incomingForwardTasks.values) + Array(stateForwardTasks.values)
            localICEForwardTasks.removeAll()
            incomingForwardTasks.removeAll()
            stateForwardTasks.removeAll()
            dataChannels.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }
}
