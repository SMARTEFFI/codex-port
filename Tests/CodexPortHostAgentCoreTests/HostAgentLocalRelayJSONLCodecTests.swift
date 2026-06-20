import Foundation
import Testing
@testable import CodexPortHostAgentCore
@testable import CodexPortShared

@Test func hostAgentLocalRelayJSONLCodecDecodesAttachAndPromptCommands() throws {
    let listThreadsLine = """
    {"type":"listThreads","clientID":"iphone-a","requestID":"request-1","limit":25}
    """
    let attachLine = """
    {"type":"attach","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","turnID":"turn-1","cwd":"/Users/chenm/Projects/codex-port","loadInitialHistory":false,"resumeLiveSession":false}
    """
    let promptLine = """
    {"type":"prompt","clientID":"iphone-a","sessionID":"session-1","threadID":"thread-1","writeID":"write-1","text":"hello"}
    """
    let loadHistoryLine = """
    {"type":"loadHistory","clientID":"iphone-a","requestID":"history-request-1","threadID":"thread-1","limit":10,"cursor":"older-cursor-1"}
    """
    let startThreadLine = """
    {"type":"startThread","clientID":"iphone-a","requestID":"start-1","cwd":"/Users/chenm/Projects/codex-port"}
    """

    #expect(try HostAgentLocalRelayJSONLCodec.decodeCommand(from: listThreadsLine) == .listThreads(
        clientID: "iphone-a",
        requestID: "request-1",
        limit: 25,
        cursor: nil
    ))
    #expect(try HostAgentLocalRelayJSONLCodec.decodeCommand(from: startThreadLine) == .startThread(
        clientID: "iphone-a",
        requestID: "start-1",
        cwd: "/Users/chenm/Projects/codex-port"
    ))
    #expect(try HostAgentLocalRelayJSONLCodec.decodeCommand(from: attachLine) == .attach(
        clientID: "iphone-a",
        request: HostAgentLocalRelayAttachRequest(
            sessionID: "session-1",
            threadID: "thread-1",
            turnID: "turn-1",
            cwd: "/Users/chenm/Projects/codex-port",
            loadInitialHistory: false,
            resumeLiveSession: false
        )
    ))
    #expect(try HostAgentLocalRelayJSONLCodec.decodeCommand(from: promptLine) == .submit(
        clientID: "iphone-a",
        sessionID: "session-1",
        write: .prompt(writeID: "write-1", threadID: "thread-1", text: "hello")
    ))
    #expect(try HostAgentLocalRelayJSONLCodec.decodeCommand(from: loadHistoryLine) == .loadHistory(
        clientID: "iphone-a",
        requestID: "history-request-1",
        threadID: "thread-1",
        limit: 10,
        cursor: "older-cursor-1"
    ))
}

@Test func hostAgentLocalRelayJSONLCodecOnlyIncludesErrorReasonWhenExplicitlyAllowed() throws {
    let redacted = try HostAgentLocalRelayJSONLCodec.encodeError("secret failure", clientID: "iphone-a")
    let visible = try HostAgentLocalRelayJSONLCodec.encodeError(
        "thread/resume timed out while loading initial history",
        clientID: "iphone-a",
        includeReason: true
    )

    #expect(redacted.contains(#""reasonBytes":"#))
    #expect(!redacted.contains(#""reason":"#))
    #expect(visible.contains(#""reason":"thread\/resume timed out while loading initial history""#))
}
