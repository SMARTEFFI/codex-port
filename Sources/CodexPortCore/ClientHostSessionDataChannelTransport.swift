import Foundation
import CodexPortShared

public final class ClientHostSessionDataChannelTransport: RelayJSONLTransport, @unchecked Sendable {
    public let incomingLines: AsyncStream<String>

    private let dataChannel: WebRTCDataChannelTransport
    private let lineContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var pendingBuffer = Data()

    public init(dataChannel: WebRTCDataChannelTransport) {
        self.dataChannel = dataChannel
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.incomingLines = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        self.lineContinuation = capturedContinuation!
        self.receiveTask = Task { [weak self] in
            for await message in dataChannel.incomingMessages {
                self?.receive(message)
            }
        }
    }

    deinit {
        receiveTask?.cancel()
        lineContinuation.finish()
    }

    public func sendLine(_ line: String) async throws {
        for frame in WebRTCDataChannelJSONLFraming.frames(forLine: line) {
            try await dataChannel.send(frame)
        }
    }

    private func receive(_ message: Data) {
        let lines = lock.withLock {
            pendingBuffer.append(message)
            return drainCompleteLines()
        }
        for line in lines {
            lineContinuation.yield(line)
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
}
