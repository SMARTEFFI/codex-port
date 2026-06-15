import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol RelayWebSocketTask: Sendable {
    var receivedStrings: AsyncStream<String> { get }
    func resume()
    func sendString(_ string: String) async throws
    func cancel()
}

public final class RelayWebSocketJSONLTransport: RelayJSONLTransport, @unchecked Sendable {
    public typealias TaskFactory = @Sendable (_ request: URLRequest) -> RelayWebSocketTask

    public let incomingLines: AsyncStream<String>

    private let task: RelayWebSocketTask
    private let incomingContinuation: AsyncStream<String>.Continuation
    private var receiveTask: Task<Void, Never>?

    public convenience init(
        endpointURL: URL,
        hostAgentID: UUID,
        deviceID: UUID,
        pairingRecordID: String
    ) {
        self.init(
            endpointURL: endpointURL,
            hostAgentID: hostAgentID,
            deviceID: deviceID,
            pairingRecordID: pairingRecordID,
            supportedVersions: [.v0_2_0],
            makeTask: { request in
                URLSessionRelayWebSocketTask(request: request)
            }
        )
    }

    public init(
        endpointURL: URL,
        hostAgentID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        supportedVersions: [RelayProtocolVersion],
        makeTask: TaskFactory
    ) {
        var request = URLRequest(url: endpointURL)
        RelayStreamOpenRequestWebSocketCodec.encode(
            RelayStreamOpenRequest(
                hostID: hostAgentID,
                deviceID: deviceID,
                pairingRecordID: pairingRecordID,
                supportedVersions: supportedVersions,
                tags: ["purpose": "host-agent-jsonl"]
            ),
            into: &request
        )

        var continuation: AsyncStream<String>.Continuation?
        incomingLines = AsyncStream { captured in
            continuation = captured
        }
        incomingContinuation = continuation!
        task = makeTask(request)
    }

    deinit {
        stop()
    }

    public func connect() {
        guard receiveTask == nil else { return }
        task.resume()
        let receivedStrings = task.receivedStrings
        receiveTask = Task { [incomingContinuation] in
            for await string in receivedStrings {
                let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
                for line in lines where !line.isEmpty {
                    incomingContinuation.yield(String(line))
                }
            }
        }
    }

    public func sendLine(_ line: String) async throws {
        connect()
        try await task.sendString(line + "\n")
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel()
        incomingContinuation.finish()
    }
}

private final class URLSessionRelayWebSocketTask: RelayWebSocketTask, @unchecked Sendable {
    let receivedStrings: AsyncStream<String>

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncStream<String>.Continuation
    private var receiveTask: Task<Void, Never>?

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        var capturedContinuation: AsyncStream<String>.Continuation?
        receivedStrings = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    deinit {
        cancel()
    }

    func resume() {
        task.resume()
        guard receiveTask == nil else { return }
        receiveTask = Task { [task, continuation] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case let .string(string):
                        continuation.yield(string)
                    case let .data(data):
                        continuation.yield(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        continue
                    }
                } catch {
                    continuation.finish()
                    break
                }
            }
        }
    }

    func sendString(_ string: String) async throws {
        try await task.send(.string(string))
    }

    func cancel() {
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }
}
