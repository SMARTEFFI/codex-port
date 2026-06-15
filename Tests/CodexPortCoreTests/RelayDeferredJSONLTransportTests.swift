import Foundation
import Testing
@testable import CodexPortCore

@Test func relayDeferredJSONLTransportOpensOnceOnFirstSendAndForwardsIncomingLines() async throws {
    let underlying = RecordingDeferredUnderlyingTransport()
    let deferred = RelayDeferredJSONLTransport {
        underlying
    }

    try await deferred.sendLine("first")
    try await deferred.sendLine("second")
    underlying.emit("from-host")

    var iterator = deferred.incomingLines.makeAsyncIterator()
    let received = await iterator.next()

    #expect(underlying.sentLines == ["first", "second"])
    #expect(received == "from-host")
}

private final class RecordingDeferredUnderlyingTransport: RelayJSONLTransport, @unchecked Sendable {
    let incomingLines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sentLinesStorage: [String] = []

    init() {
        var capturedContinuation: AsyncStream<String>.Continuation?
        incomingLines = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    deinit {
        continuation.finish()
    }

    var sentLines: [String] {
        lock.withLock { sentLinesStorage }
    }

    func sendLine(_ line: String) async throws {
        lock.withLock {
            sentLinesStorage.append(line)
        }
    }

    func emit(_ line: String) {
        continuation.yield(line)
    }
}
