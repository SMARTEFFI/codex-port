import Foundation
import CodexPortShared

public final class HostAgentP2PDataChannelEndpoint: @unchecked Sendable {
    private let dataChannel: WebRTCDataChannelTransport
    private let service: HostAgentLocalRelayService
    private let onEvent: @Sendable (HostAgentP2PDataChannelEndpointEvent) async -> Void
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var pendingBuffer = Data()
    private var isStopped = true

    public init(
        dataChannel: WebRTCDataChannelTransport,
        service: HostAgentLocalRelayService,
        onEvent: @escaping @Sendable (HostAgentP2PDataChannelEndpointEvent) async -> Void = { _ in }
    ) {
        self.dataChannel = dataChannel
        self.service = service
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    public func start() {
        let incomingMessages = dataChannel.incomingMessages
        let task = Task { [weak self] in
            for await message in incomingMessages {
                guard let self else { return }
                let lines = self.completedLines(from: message)
                for line in lines where !line.isEmpty {
                    await self.handle(line)
                }
            }
        }

        let shouldRun = lock.withLock {
            guard receiveTask == nil else { return false }
            isStopped = false
            receiveTask = task
            return true
        }

        if !shouldRun {
            task.cancel()
        }
    }

    public func stop() {
        let task = lock.withLock {
            isStopped = true
            pendingBuffer.removeAll()
            let task = receiveTask
            receiveTask = nil
            return task
        }
        task?.cancel()
    }

    private func completedLines(from message: Data) -> [String] {
        lock.withLock {
            guard !isStopped else { return [] }
            pendingBuffer.append(message)
            return drainCompleteLines()
        }
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = pendingBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingBuffer[..<newlineIndex]
            pendingBuffer.removeSubrange(...newlineIndex)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    private func handle(_ line: String) async {
        guard !lock.withLock({ isStopped }) else { return }
        do {
            let summary = try HostAgentLocalRelayJSONLCodec.decodeCommand(from: line).diagnosticSummary(inputBytes: line.utf8.count)
            await onEvent(.commandReceived(summary))
            try await service.handleLine(line) { [weak self] outputLine in
                if let outputSummary = HostAgentLocalRelayJSONLCodec.diagnosticOutputSummary(from: outputLine) {
                    await self?.onEvent(.commandOutput(outputSummary))
                }
                try? await self?.send(outputLine)
            }
        } catch {
            await onEvent(.commandFailed(inputBytes: line.utf8.count, reason: String(describing: error)))
            await sendError(error)
        }
    }

    private func send(_ line: String) async throws {
        guard !lock.withLock({ isStopped }) else { return }
        try await dataChannel.send(Data((line + "\n").utf8))
    }

    private func sendError(_ error: Error) async {
        guard let line = try? HostAgentLocalRelayJSONLCodec.encodeError(String(describing: error)) else {
            return
        }
        try? await send(line)
    }
}

public enum HostAgentP2PDataChannelEndpointEvent: Equatable, Sendable {
    case commandReceived(HostAgentLocalRelayCommandDiagnosticSummary)
    case commandOutput(HostAgentLocalRelayOutputDiagnosticSummary)
    case commandFailed(inputBytes: Int, reason: String)
}

public struct HostAgentLocalRelayCommandDiagnosticSummary: Equatable, Sendable {
    public var type: String
    public var clientID: String?
    public var sessionID: String?
    public var threadID: String?
    public var writeID: String?
    public var inputBytes: Int

    public init(
        type: String,
        clientID: String? = nil,
        sessionID: String? = nil,
        threadID: String? = nil,
        writeID: String? = nil,
        inputBytes: Int
    ) {
        self.type = type
        self.clientID = clientID
        self.sessionID = sessionID
        self.threadID = threadID
        self.writeID = writeID
        self.inputBytes = inputBytes
    }

    public var logDescription: String {
        [
            "type=\(type)",
            clientID.map { "client=\($0)" },
            sessionID.map { "session=\($0)" },
            threadID.map { "thread=\($0)" },
            writeID.map { "write=\($0)" },
            "bytes=\(inputBytes)",
        ].compactMap { $0 }.joined(separator: " ")
    }
}

public struct HostAgentLocalRelayOutputDiagnosticSummary: Equatable, Sendable {
    public var type: String
    public var event: String?
    public var clientID: String?
    public var sessionID: String?
    public var threadID: String?
    public var turnID: String?
    public var itemID: String?
    public var requestID: String?
    public var writeID: String?
    public var status: String?
    public var outputBytes: Int

    public init(
        type: String,
        event: String? = nil,
        clientID: String? = nil,
        sessionID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String? = nil,
        requestID: String? = nil,
        writeID: String? = nil,
        status: String? = nil,
        outputBytes: Int
    ) {
        self.type = type
        self.event = event
        self.clientID = clientID
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.requestID = requestID
        self.writeID = writeID
        self.status = status
        self.outputBytes = outputBytes
    }

    public var logDescription: String {
        [
            "type=\(type)",
            event.map { "event=\($0)" },
            clientID.map { "client=\($0)" },
            sessionID.map { "session=\($0)" },
            threadID.map { "thread=\($0)" },
            turnID.map { "turn=\($0)" },
            itemID.map { "item=\($0)" },
            requestID.map { "request=\($0)" },
            writeID.map { "write=\($0)" },
            status.map { "status=\($0)" },
            "bytes=\(outputBytes)",
        ].compactMap { $0 }.joined(separator: " ")
    }
}
