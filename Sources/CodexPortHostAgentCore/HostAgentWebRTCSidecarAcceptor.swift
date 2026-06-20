import Foundation
import CodexPortShared

public struct WebRTCSidecarConfiguration: Equatable, Sendable {
    public var command: HostAgentProcessCommand
    public var iceConfiguration: WebRTCRuntimeConfiguration

    public init(command: HostAgentProcessCommand, iceConfiguration: WebRTCRuntimeConfiguration) {
        self.command = command
        self.iceConfiguration = iceConfiguration
    }
}

public protocol HostAgentWebRTCSidecarProcess: Sendable {
    var messages: AsyncStream<WebRTCSidecarMessage> { get }

    func start(command: HostAgentProcessCommand) async throws
    func send(_ message: WebRTCSidecarMessage) async throws
    func stop() async
}

public final class HostAgentWebRTCJSONLSidecarProcess: HostAgentWebRTCSidecarProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let messagesContinuation: AsyncStream<WebRTCSidecarMessage>.Continuation
    private var process: Process?
    private var standardInputPipe: Pipe?
    private var stdoutLineBuffer = ""

    public let messages: AsyncStream<WebRTCSidecarMessage>

    public init() {
        var continuation: AsyncStream<WebRTCSidecarMessage>.Continuation!
        messages = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        messagesContinuation = continuation
    }

    public func start(command: HostAgentProcessCommand) async throws {
        let process = Process()
        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, override in
                override
            }
        }
        if let workingDirectory = command.workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.terminationHandler = { [weak self] _ in
            self?.messagesContinuation.finish()
        }

        lock.withLock {
            self.process = process
            self.standardInputPipe = standardInputPipe
        }
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.appendOutput(handle.availableData)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { _ in
            _ = standardErrorPipe.fileHandleForReading.availableData
        }

        do {
            try process.run()
        } catch {
            lock.withLock {
                self.process = nil
                self.standardInputPipe = nil
            }
            throw error
        }
    }

    public func send(_ message: WebRTCSidecarMessage) async throws {
        guard let handle = lock.withLock({ standardInputPipe?.fileHandleForWriting }) else {
            throw HostAgentWebRTCSidecarError.notRunning
        }
        var data = try encoder.encode(message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    public func stop() async {
        let process = lock.withLock {
            let process = self.process
            self.process = nil
            self.standardInputPipe = nil
            return process
        }
        process?.terminate()
        messagesContinuation.finish()
    }

    private func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = lock.withLock {
            stdoutLineBuffer.append(String(decoding: data, as: UTF8.self))
            let segments = stdoutLineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            guard stdoutLineBuffer.last == "\n" else {
                stdoutLineBuffer = String(segments.last ?? "")
                return segments.dropLast().map(String.init)
            }
            stdoutLineBuffer = ""
            return segments.dropLast().map(String.init)
        }
        for line in lines where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let message = try? decoder.decode(WebRTCSidecarMessage.self, from: data) {
                messagesContinuation.yield(message)
            }
        }
    }
}

public actor HostAgentWebRTCSidecarAcceptor: HostAgentP2PDataChannelAccepting {
    private let configuration: WebRTCSidecarConfiguration
    private let process: HostAgentWebRTCSidecarProcess
    private var didStart = false
    private var routingTask: Task<Void, Never>?
    private var sessions: [UUID: SessionState] = [:]

    public init(
        configuration: WebRTCSidecarConfiguration,
        process: HostAgentWebRTCSidecarProcess = HostAgentWebRTCJSONLSidecarProcess()
    ) {
        self.configuration = configuration
        self.process = process
    }

    deinit {
        routingTask?.cancel()
        Task { [process] in
            await process.stop()
        }
    }

    public func accept(_ request: HostAgentP2PAcceptRequest) async throws -> HostAgentP2PAcceptResponse {
        try await startIfNeeded()
        let sessionID = request.session.sessionID
        let dataChannel = HostAgentWebRTCSidecarDataChannelTransport(sessionID: sessionID) { [weak self] data in
            guard let self else { throw HostAgentWebRTCSidecarError.stopped }
            try await self.sendDataChannelMessage(data, sessionID: sessionID)
        }
        var localICEContinuation: AsyncStream<RelayP2PSignalingMessageDTO>.Continuation!
        let localICEUpdates = AsyncStream<RelayP2PSignalingMessageDTO> { continuation in
            localICEContinuation = continuation
        }

        let accepted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebRTCSidecarMessage, Error>) in
            sessions[sessionID] = SessionState(
                acceptedContinuation: continuation,
                localICEContinuation: localICEContinuation,
                dataChannel: dataChannel
            )
            Task {
                do {
                    try await process.send(WebRTCSidecarMessage(
                        type: .accept,
                        sessionID: sessionID,
                        hostID: request.session.hostID,
                        deviceID: request.session.deviceID,
                        offer: request.offer,
                        iceConfiguration: request.iceConfiguration ?? configuration.iceConfiguration
                    ))
                } catch {
                    self.failAccept(sessionID: sessionID, error: error)
                }
            }
        }
        guard let answer = accepted.answer else {
            throw HostAgentWebRTCSidecarError.missingField("answer")
        }
        return HostAgentP2PAcceptResponse(
            answer: answer,
            iceCandidates: accepted.iceCandidates ?? [],
            localICECandidateUpdates: localICEUpdates,
            dataChannel: dataChannel
        )
    }

    public func restartICE(
        _ request: HostAgentP2PAcceptRequest,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> HostAgentP2PAcceptResponse {
        try await startIfNeeded()
        let sessionID = request.session.sessionID
        guard var state = sessions[sessionID] else {
            throw HostAgentWebRTCSidecarError.unknownSession(sessionID)
        }
        var localICEContinuation: AsyncStream<RelayP2PSignalingMessageDTO>.Continuation!
        let localICEUpdates = AsyncStream<RelayP2PSignalingMessageDTO> { continuation in
            localICEContinuation = continuation
        }
        let accepted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebRTCSidecarMessage, Error>) in
            state.acceptedContinuation = continuation
            state.localICEContinuation = localICEContinuation
            sessions[sessionID] = state
            Task {
                do {
                    try await process.send(WebRTCSidecarMessage(
                        type: .restartICE,
                        sessionID: sessionID,
                        hostID: request.session.hostID,
                        deviceID: request.session.deviceID,
                        offer: request.offer,
                        iceConfiguration: request.iceConfiguration ?? configuration.iceConfiguration
                    ))
                } catch {
                    self.failAccept(sessionID: sessionID, error: error)
                }
            }
        }
        guard let answer = accepted.answer else {
            throw HostAgentWebRTCSidecarError.missingField("answer")
        }
        return HostAgentP2PAcceptResponse(
            answer: answer,
            iceCandidates: accepted.iceCandidates ?? [],
            localICECandidateUpdates: localICEUpdates,
            dataChannel: state.dataChannel
        )
    }

    public func addRemoteICECandidate(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        guard sessions[sessionID] != nil else {
            throw HostAgentWebRTCSidecarError.unknownSession(sessionID)
        }
        try await process.send(WebRTCSidecarMessage(
            type: .remoteICE,
            sessionID: sessionID,
            candidate: message
        ))
    }

    private func startIfNeeded() async throws {
        guard !didStart else { return }
        try await process.start(command: configuration.command)
        didStart = true
        routingTask = Task { [weak self, process] in
            for await message in process.messages {
                await self?.handle(message)
            }
        }
    }

    private func handle(_ message: WebRTCSidecarMessage) async {
        guard let sessionID = message.sessionID else { return }
        switch message.type {
        case .accepted:
            guard var state = sessions[sessionID] else { return }
            state.acceptedContinuation?.resume(returning: message)
            state.acceptedContinuation = nil
            sessions[sessionID] = state
        case .localICE:
            guard let candidate = message.candidate else { return }
            sessions[sessionID]?.localICEContinuation.yield(candidate)
        case .dataChannelMessage:
            guard let base64 = message.base64,
                  let data = Data(base64Encoded: base64) else { return }
            sessions[sessionID]?.dataChannel.deliver(data)
        case .dataChannelState:
            guard let state = Self.connectionState(message.state, reason: message.reason) else { return }
            sessions[sessionID]?.dataChannel.deliver(state)
            if state == .dataChannelClosed {
                sessions[sessionID]?.localICEContinuation.finish()
                sessions[sessionID]?.dataChannel.finish()
                sessions.removeValue(forKey: sessionID)
            }
        case .error:
            let error = HostAgentWebRTCSidecarError.sidecarFailed(message.reason ?? "Sidecar failed.")
            failAccept(sessionID: sessionID, error: error)
            sessions[sessionID]?.dataChannel.deliver(.directFailed(reason: message.reason ?? "Sidecar failed."))
        case .accept, .restartICE, .remoteICE, .dataChannelSend:
            break
        }
    }

    private func failAccept(sessionID: UUID, error: Error) {
        guard var state = sessions[sessionID] else { return }
        state.acceptedContinuation?.resume(throwing: error)
        state.acceptedContinuation = nil
        state.localICEContinuation.finish()
        state.dataChannel.finish()
        sessions[sessionID] = state
    }

    private func sendDataChannelMessage(_ data: Data, sessionID: UUID) async throws {
        try await process.send(WebRTCSidecarMessage(
            type: .dataChannelSend,
            sessionID: sessionID,
            base64: data.base64EncodedString()
        ))
    }

    private static func connectionState(_ rawValue: String?, reason: String?) -> WebRTCDataChannelConnectionState? {
        switch rawValue {
        case "iceGathering":
            return .iceGathering
        case "directConnected":
            return .directConnected
        case "turnRelayedConnected":
            return .turnRelayedConnected
        case "dataChannelOpen":
            return .dataChannelOpen
        case "dataChannelClosed":
            return .dataChannelClosed
        case "directFailed":
            return .directFailed(reason: reason ?? "Direct connection failed.")
        case "turnFailed":
            return .turnFailed(reason: reason ?? "TURN relay failed.")
        default:
            return nil
        }
    }

    private struct SessionState {
        var acceptedContinuation: CheckedContinuation<WebRTCSidecarMessage, Error>?
        var localICEContinuation: AsyncStream<RelayP2PSignalingMessageDTO>.Continuation
        var dataChannel: HostAgentWebRTCSidecarDataChannelTransport
    }
}

public struct HostAgentWebRTCSidecarAcceptorFactory: HostAgentP2PDataChannelAcceptorFactory {
    private let command: HostAgentProcessCommand
    private let processFactory: @Sendable () -> HostAgentWebRTCSidecarProcess

    public init(
        command: HostAgentProcessCommand,
        processFactory: @escaping @Sendable () -> HostAgentWebRTCSidecarProcess = { HostAgentWebRTCJSONLSidecarProcess() }
    ) {
        self.command = command
        self.processFactory = processFactory
    }

    public func makeAcceptor(configuration: WebRTCRuntimeConfiguration) -> HostAgentP2PDataChannelAccepting {
        HostAgentWebRTCSidecarAcceptor(
            configuration: WebRTCSidecarConfiguration(
                command: command,
                iceConfiguration: configuration
            ),
            process: processFactory()
        )
    }
}

private final class HostAgentWebRTCSidecarDataChannelTransport: WebRTCDataChannelTransport, @unchecked Sendable {
    private let sessionID: UUID
    private let sendHandler: @Sendable (Data) async throws -> Void
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation

    let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    let incomingMessages: AsyncStream<Data>
    let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>

    init(sessionID: UUID, sendHandler: @escaping @Sendable (Data) async throws -> Void) {
        self.sessionID = sessionID
        self.sendHandler = sendHandler
        var incomingContinuation: AsyncStream<Data>.Continuation!
        incomingMessages = AsyncStream { continuation in
            incomingContinuation = continuation
        }
        self.incomingContinuation = incomingContinuation
        var stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation!
        stateUpdates = AsyncStream { continuation in
            stateContinuation = continuation
        }
        self.stateContinuation = stateContinuation
    }

    func send(_ message: Data) async throws {
        try await sendHandler(message)
    }

    fileprivate func deliver(_ message: Data) {
        incomingContinuation.yield(message)
    }

    fileprivate func deliver(_ state: WebRTCDataChannelConnectionState) {
        stateContinuation.yield(state)
    }

    fileprivate func finish() {
        incomingContinuation.finish()
        stateContinuation.finish()
    }
}

public enum HostAgentWebRTCSidecarError: Error, Equatable, Sendable {
    case notRunning
    case stopped
    case missingField(String)
    case unknownSession(UUID)
    case sidecarFailed(String)
}
