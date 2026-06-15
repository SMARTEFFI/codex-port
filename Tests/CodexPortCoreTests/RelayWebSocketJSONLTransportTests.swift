import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayWebSocketJSONLTransportBuildsAuthenticatedStreamRequestAndFramesLines() async throws {
    let endpointURL = try #require(URL(string: "wss://relay.example.test/v0/streams"))
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let task = RecordingRelayWebSocketTask()
    let transport = RelayWebSocketJSONLTransport(
        endpointURL: endpointURL,
        hostAgentID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-record",
        supportedVersions: [.v0_2_0],
        makeTask: { request in
            task.record(request: request)
            return task
        }
    )

    transport.connect()
    try await transport.sendLine(#"{"type":"attach"}"#)
    task.deliver(#"{"type":"event"}"#)
    let receivedLine = await transport.nextLine(timeout: .milliseconds(300))

    let request = try #require(task.request)
    #expect(request.url == endpointURL)
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Host-Agent-ID") == "11111111-2222-3333-4444-555555555555")
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Device-ID") == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Pairing-Record-ID") == "pairing-record")
    #expect(request.value(forHTTPHeaderField: "X-CodexPort-Relay-Versions") == "0.2.0")
    #expect(try RelayStreamOpenRequestWebSocketCodec.decode(from: request) == RelayStreamOpenRequest(
        hostID: hostID,
        deviceID: deviceID,
        pairingRecordID: "pairing-record",
        supportedVersions: [.v0_2_0],
        tags: ["purpose": "host-agent-jsonl"]
    ))
    #expect(task.didResume)
    #expect(task.sentStrings == [#"{"type":"attach"}"# + "\n"])
    #expect(receivedLine == #"{"type":"event"}"#)
}

@Test func relayWebSocketTransportFactoryOnlyCreatesTransportForHostsWithEndpointURL() throws {
    let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let factory = RelayWebSocketTransportFactory()
    let hostWithEndpoint = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        deviceID: deviceID,
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let hostWithoutEndpoint = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )
    let hostWithoutDeviceID = RelayHost(
        hostAgentID: hostID,
        displayName: "Mac Studio",
        userName: "chenm",
        pairingRecordID: "pairing-record",
        relayEndpointURL: URL(string: "wss://relay.example.test/v0/streams")!,
        presence: .online(activeConnectionCount: 1),
        diagnosticsSummary: "Ready"
    )

    #expect(factory.makeTransport(for: hostWithEndpoint) != nil)
    #expect(factory.makeTransport(for: hostWithoutEndpoint) == nil)
    #expect(factory.makeTransport(for: hostWithoutDeviceID) == nil)
}

private final class RecordingRelayWebSocketTask: RelayWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedContinuation: AsyncStream<String>.Continuation?
    private(set) var request: URLRequest?
    private(set) var didResume = false
    private(set) var sentStrings: [String] = []

    let receivedStrings: AsyncStream<String>

    init() {
        var continuation: AsyncStream<String>.Continuation?
        receivedStrings = AsyncStream { captured in
            continuation = captured
        }
        receivedContinuation = continuation
    }

    func record(request: URLRequest) {
        lock.withLock {
            self.request = request
        }
    }

    func resume() {
        lock.withLock {
            didResume = true
        }
    }

    func sendString(_ string: String) async throws {
        lock.withLock {
            sentStrings.append(string)
        }
    }

    func cancel() {
        receivedContinuation?.finish()
    }

    func deliver(_ string: String) {
        receivedContinuation?.yield(string)
    }
}

private extension RelayWebSocketJSONLTransport {
    func nextLine(timeout: Duration) async -> String? {
        let task = Task<String?, Never> {
            var iterator = incomingLines.makeAsyncIterator()
            return await iterator.next()
        }
        let timeoutTask = Task<String?, Never> {
            try? await Task.sleep(for: timeout)
            return nil
        }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                await timeoutTask.value
            }
            let result = await group.next() ?? nil
            task.cancel()
            timeoutTask.cancel()
            return result
        }
    }
}
