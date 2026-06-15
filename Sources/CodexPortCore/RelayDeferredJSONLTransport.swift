import Foundation

public final class RelayDeferredJSONLTransport: RelayJSONLTransport, @unchecked Sendable {
    public typealias OpenTransport = @Sendable () async throws -> RelayJSONLTransport

    public let incomingLines: AsyncStream<String>

    private let openTransport: OpenTransport
    private let lineContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var openTask: Task<RelayJSONLTransport, Error>?
    private var pumpTask: Task<Void, Never>?

    public init(openTransport: @escaping OpenTransport) {
        self.openTransport = openTransport
        var capturedContinuation: AsyncStream<String>.Continuation?
        incomingLines = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        lineContinuation = capturedContinuation!
    }

    deinit {
        pumpTask?.cancel()
        lineContinuation.finish()
    }

    public func sendLine(_ line: String) async throws {
        let transport = try await resolvedTransport()
        try await transport.sendLine(line)
    }

    private func resolvedTransport() async throws -> RelayJSONLTransport {
        let task = lock.withLock {
            if let openTask {
                return openTask
            }
            let task = Task { [openTransport] in
                try await openTransport()
            }
            openTask = task
            return task
        }
        let transport = try await task.value
        startPumpingIfNeeded(from: transport)
        return transport
    }

    private func startPumpingIfNeeded(from transport: RelayJSONLTransport) {
        lock.withLock {
            guard pumpTask == nil else { return }
            let incomingLines = transport.incomingLines
            pumpTask = Task { [lineContinuation] in
                for await line in incomingLines {
                    lineContinuation.yield(line)
                }
            }
        }
    }
}
