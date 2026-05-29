import Foundation
import Testing
@testable import CodexPortCore

@Test func jsonRPCCodecEncodesRequestAndDecodesResponseNotificationAndServerRequest() throws {
    let codec = JSONRPCCodec()

    let encoded = try codec.encodeRequest(JSONRPCOutboundRequest(id: .number(1), method: "thread/list", params: .object(["limit": .number(20)])))
    #expect(String(data: encoded, encoding: .utf8)?.contains("\"method\":\"thread/list\"") == true)
    #expect(String(data: encoded, encoding: .utf8)?.contains("\"jsonrpc\"") == false)

    let encodedNotification = try codec.encodeNotification(JSONRPCNotification(method: "initialized", params: .object([:])))
    #expect(String(data: encodedNotification, encoding: .utf8) == #"{"method":"initialized"}"#)

    let response = try codec.decode(#"{"id":1,"result":{"threads":[]}}"#.data(using: .utf8)!)
    #expect(response == .response(id: .number(1), result: .object(["threads": .array([])])))

    let notification = try codec.decode(#"{"method":"turn/started","params":{"turnId":"t1"}}"#.data(using: .utf8)!)
    #expect(notification == .notification(method: "turn/started", params: .object(["turnId": .string("t1")])))

    let serverRequest = try codec.decode(#"{"id":"approval-1","method":"item/fileChange/requestApproval","params":{"path":"README.md"}}"#.data(using: .utf8)!)
    #expect(serverRequest == .request(id: .string("approval-1"), method: "item/fileChange/requestApproval", params: .object(["path": .string("README.md")])))
}

@Test func appServerStartupCommandPrefersSharedControlSocketBridgeThenFallsBackToStdio() {
    let command = AppServerStartupCommand(codexPath: "/opt/homebrew/bin/codex")

    #expect(command.shellCommand.contains(#"SOCKET="${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock""#))
    #expect(command.shellCommand.contains(#"if [ -S "$SOCKET" ] && command -v node >/dev/null 2>&1; then node -e"#))
    #expect(command.shellCommand.contains(#""$SOCKET"; STATUS=$?; [ "$STATUS" -eq 0 ] && exit 0; fi; exec /opt/homebrew/bin/codex app-server --listen stdio://"#))
    #expect(!command.shellCommand.contains("daemon start"))
    #expect(!command.shellCommand.contains("ws://"))
}

@Test func appServerShellCommandAddsCommonCLIPrefixToPreflightCommands() {
    let command = AppServerShellCommand(codexPath: "codex")
    let prefix = #"export PATH="$HOME/.codex/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"; "#

    #expect(command.versionCommand == "\(prefix)codex --version")
    #expect(command.proxyHelpCommand == "\(prefix)codex app-server proxy --help")
    #expect(command.appServerHelpCommand == "\(prefix)codex app-server --help")
    #expect(command.daemonStartCommand == "\(prefix)codex app-server daemon start")
    #expect(command.proxyCommand == "\(prefix)codex app-server proxy")
    #expect(command.appServerCommand.hasPrefix("\(prefix)SOCKET="))
    #expect(command.appServerCommand.hasSuffix("; exec codex app-server --listen stdio://"))
    #expect(command.appServerCommand.contains("; fi; exec codex app-server --listen stdio://"))
}

@Test func jsonRPCCodecReportsRawInvalidMessages() throws {
    let codec = JSONRPCCodec()

    #expect(throws: JSONRPCCodecError.invalidMessage("daemon already running")) {
        _ = try codec.decode(Data("daemon already running".utf8))
    }
}

@Test func jsonRPCFramerHandlesSplitAndCoalescedNewlineDelimitedMessages() throws {
    var framer = JSONRPCFramer(codec: JSONRPCCodec())

    #expect(try framer.receive(Data(#"{"jsonrpc":"2.0","id":1"#.utf8)).isEmpty)
    let first = try framer.receive(Data(
        ",\"result\":{}}\n{\"method\":\"turn/started\",\"params\":{}}\n".utf8
    ))

    #expect(first == [
        .response(id: .number(1), result: .object([:])),
        .notification(method: "turn/started", params: .object([:]))
    ])
}
