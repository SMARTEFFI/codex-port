import Foundation
import Testing
@testable import CodexPortCore
@testable import CodexPortShared

@Test func relayLineLoopTransportConnectsTwoEndpointClientsToOneLineService() async throws {
    let hub = TestRelayLineHub()
    let iPhoneATransport = await hub.makeTransport()
    let iPhoneBTransport = await hub.makeTransport()
    let iPhoneAStore = SessionStore(protocolClient: FakeCodexProtocol())
    let iPhoneBStore = SessionStore(protocolClient: FakeCodexProtocol())
    let iPhoneA = RelayJSONLSessionClient(
        clientID: "iphone-a",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: iPhoneATransport,
        sessionStore: iPhoneAStore
    )
    let iPhoneB = RelayJSONLSessionClient(
        clientID: "iphone-b",
        sessionID: "session-1",
        threadID: "thread-1",
        turnID: "turn-1",
        transport: iPhoneBTransport,
        sessionStore: iPhoneBStore
    )

    try await iPhoneA.attach()
    try await iPhoneB.attach()
    try await iPhoneA.sendPrompt("from iphone a", writeID: "write-a")
    try await iPhoneB.sendPrompt("from iphone b", writeID: "write-b")

    await waitForRelayLineLoop(timeout: .milliseconds(500)) {
        iPhoneAStore.visibleItems.contains(.userMessage("from iphone a"))
            && iPhoneAStore.visibleItems.contains(.userMessage("from iphone b"))
            && iPhoneAStore.visibleItems.contains(.assistantMessage("from iphone a"))
            && iPhoneAStore.visibleItems.contains(.assistantMessage("from iphone b"))
            && iPhoneBStore.visibleItems.contains(.userMessage("from iphone a"))
            && iPhoneBStore.visibleItems.contains(.userMessage("from iphone b"))
            && iPhoneBStore.visibleItems.contains(.assistantMessage("from iphone a"))
            && iPhoneBStore.visibleItems.contains(.assistantMessage("from iphone b"))
    }

    #expect(await hub.commandsSnapshot().contains(#""clientID":"iphone-a""#))
    #expect(await hub.commandsSnapshot().contains(#""clientID":"iphone-b""#))
    #expect(iPhoneAStore.visibleItems.contains(.userMessage("from iphone a")))
    #expect(iPhoneAStore.visibleItems.contains(.userMessage("from iphone b")))
    #expect(iPhoneAStore.visibleItems.contains(.assistantMessage("from iphone a")))
    #expect(iPhoneAStore.visibleItems.contains(.assistantMessage("from iphone b")))
    #expect(iPhoneBStore.visibleItems.contains(.userMessage("from iphone a")))
    #expect(iPhoneBStore.visibleItems.contains(.userMessage("from iphone b")))
    #expect(iPhoneBStore.visibleItems.contains(.assistantMessage("from iphone a")))
    #expect(iPhoneBStore.visibleItems.contains(.assistantMessage("from iphone b")))
}

private actor TestRelayLineHub {
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var commands: [String] = []

    func makeTransport() -> RelayLineLoopTransport {
        let id = UUID()
        var capturedContinuation: AsyncStream<String>.Continuation?
        let incomingLines = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        if let capturedContinuation {
            register(id: id, continuation: capturedContinuation)
        }
        return RelayLineLoopTransport(incomingLines: incomingLines) { line in
            await self.receiveCommand(line)
        }
    }

    func commandsSnapshot() -> String {
        commands.joined(separator: "\n")
    }

    private func register(id: UUID, continuation: AsyncStream<String>.Continuation) {
        continuations[id] = continuation
    }

    private func receiveCommand(_ line: String) async {
        commands.append(line)
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return
        }

        switch type {
        case "attach":
            guard let clientID = object["clientID"] as? String else { return }
            await broadcast(try? RelayEndpointJSONLCodec.encodeEvent(
                .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-1"),
                clientID: clientID
            ))
        case "prompt":
            guard let text = object["text"] as? String else { return }
            let writeID = object["writeID"] as? String ?? UUID().uuidString
            for clientID in ["iphone-a", "iphone-b"] {
                await broadcast(try? RelayEndpointJSONLCodec.encodeEvent(
                    .sessionStarted(sessionID: "session-1", threadID: "thread-1", turnID: "turn-\(writeID)"),
                    clientID: clientID
                ))
                await broadcast(try? RelayEndpointJSONLCodec.encodeEvent(
                    .userMessage(turnID: "turn-\(writeID)", itemID: "user-\(writeID)", text: text),
                    clientID: clientID
                ))
                await broadcast(try? RelayEndpointJSONLCodec.encodeEvent(
                    .assistantTextDelta(turnID: "turn-\(writeID)", itemID: "assistant-\(writeID)", text: text),
                    clientID: clientID
                ))
                broadcast(try? RelayEndpointJSONLCodec.encodeEvent(
                    .turnCompleted(turnID: "turn-\(writeID)"),
                    clientID: clientID
                ))
            }
        default:
            break
        }
    }

    private func broadcast(_ line: String?) {
        guard let line else { return }
        for continuation in continuations.values {
            continuation.yield(line)
        }
    }
}

private func waitForRelayLineLoop(
    timeout: Duration = .milliseconds(200),
    condition: @escaping @Sendable () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
