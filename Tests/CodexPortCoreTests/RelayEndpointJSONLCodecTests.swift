import Foundation
import Testing
@testable import CodexPortShared

@Test func relayEndpointJSONLCodecRoundTripsRenderableSessionEvents() throws {
    let event = RelayLiveSessionEvent.assistantTextDelta(
        turnID: "turn-1",
        itemID: "assistant-1",
        text: "render this on iOS"
    )

    let line = try RelayEndpointJSONLCodec.encodeEvent(event, clientID: "iphone-a")
    let decoded = try RelayEndpointJSONLCodec.decodeLine(line)

    #expect(decoded == .event(clientID: "iphone-a", event))
    #expect(line.contains(#""text":"render this on iOS""#))
}

@Test func relayEndpointJSONLCodecRoundTripsUserMessageLiveEventWithoutLeakingTelemetry() throws {
    let event = RelayLiveSessionEvent.userMessage(
        turnID: "turn-1",
        itemID: "user-1",
        text: "desktop prompt from TUI"
    )

    let line = try RelayEndpointJSONLCodec.encodeEvent(event, clientID: "iphone-a")
    let decoded = try RelayEndpointJSONLCodec.decodeLine(line)

    #expect(decoded == .event(clientID: "iphone-a", event))
    #expect(line.contains(#""event":"userMessage""#))
    #expect(line.contains(#""text":"desktop prompt from TUI""#))
    #expect(decoded.telemetryDescription.contains("userMessage"))
    #expect(decoded.telemetryDescription.contains("textBytes=23"))
    #expect(!decoded.telemetryDescription.contains("desktop prompt"))
}

@Test func relayEndpointJSONLCodecTelemetryDescriptionDoesNotContainPayloadText() throws {
    let event = RelayLiveSessionEvent.assistantTextDelta(
        turnID: "turn-1",
        itemID: "assistant-1",
        text: "do not put this in telemetry"
    )

    let line = try RelayEndpointJSONLCodec.encodeEvent(event, clientID: "iphone-a")
    let decoded = try RelayEndpointJSONLCodec.decodeLine(line)

    #expect(decoded.telemetryDescription.contains("assistantTextDelta"))
    #expect(decoded.telemetryDescription.contains("textBytes=28"))
    #expect(!decoded.telemetryDescription.contains("do not put this"))
}

@Test func relayEndpointJSONLCodecRoundTripsFailedWriteStatusReason() throws {
    let statusLine = try RelayEndpointJSONLCodec.encodeWriteStatus(
        .failed(reason: "Codex CLI exec timed out."),
        clientID: "iphone-a",
        sessionID: "session-1",
        writeID: "write-1"
    )
    let eventLine = try RelayEndpointJSONLCodec.encodeEvent(
        .writeStatusChanged(writeID: "write-1", status: .failed(reason: "Codex CLI exec timed out.")),
        clientID: "iphone-a"
    )

    #expect(try RelayEndpointJSONLCodec.decodeLine(statusLine) == .writeStatus(
        clientID: "iphone-a",
        sessionID: "session-1",
        writeID: "write-1",
        .failed(reason: "Codex CLI exec timed out.")
    ))
    #expect(try RelayEndpointJSONLCodec.decodeLine(eventLine) == .event(
        clientID: "iphone-a",
        .writeStatusChanged(writeID: "write-1", status: .failed(reason: "Codex CLI exec timed out."))
    ))
}

@Test func relayEndpointJSONLCodecRoundTripsThreadListWithoutLeakingPreviewTelemetry() throws {
    let threads = [
        RelayThreadSummarySnapshot(
            id: "thread-1",
            cwd: "/Users/chenm/Projects/codex-port",
            updatedAtUnixTime: 1_780_991_312,
            preview: "real Codex session preview",
            gitRepository: "git@github.com:zhxsinc/codex-port.git",
            gitBranch: "main",
            status: "completed"
        ),
    ]

    let line = try RelayEndpointJSONLCodec.encodeThreadList(
        threads,
        clientID: "iphone-a",
        requestID: "request-1"
    )
    let decoded = try RelayEndpointJSONLCodec.decodeLine(line)

    #expect(decoded == .threadList(clientID: "iphone-a", requestID: "request-1", threads: threads, nextCursor: nil))
    #expect(decoded.telemetryDescription.contains("threadList"))
    #expect(decoded.telemetryDescription.contains("count=1"))
    #expect(!decoded.telemetryDescription.contains("real Codex session preview"))
}

@Test func relayEndpointJSONLCodecRoundTripsThreadHistoryWithoutLeakingTextTelemetry() throws {
    let message = try RelayEndpointJSONLCodec.decodeLine(RelayEndpointJSONLCodec.encodeEvent(
        .threadHistoryLoaded(
            threadID: "thread-1",
            items: [
                .userMessage("secret desktop question"),
                .assistantMessage("secret desktop answer"),
            ],
            status: .completed
        ),
        clientID: "iphone-a"
    ))

    #expect(message == .event(clientID: "iphone-a", .threadHistoryLoaded(
        threadID: "thread-1",
        items: [
            .userMessage("secret desktop question"),
            .assistantMessage("secret desktop answer"),
        ],
        status: .completed
    )))
    #expect(!message.telemetryDescription.contains("secret desktop question"))
    #expect(!message.telemetryDescription.contains("secret desktop answer"))
}

@Test func relayEndpointJSONLCodecRoundTripsThreadHistoryPageWithoutLeakingTextTelemetry() throws {
    let page = RelayThreadHistoryPage(
        requestID: "history-request-1",
        threadID: "thread-1",
        items: [
            .userMessage("older secret question"),
            .assistantMessage("older secret answer"),
        ],
        status: .completed,
        nextCursor: "older-cursor-2"
    )

    let line = try RelayEndpointJSONLCodec.encodeThreadHistoryPage(page, clientID: "iphone-a")
    let message = try RelayEndpointJSONLCodec.decodeLine(line)

    #expect(message == .threadHistoryPage(clientID: "iphone-a", page))
    #expect(message.telemetryDescription.contains("threadHistoryPage"))
    #expect(message.telemetryDescription.contains("items=2"))
    #expect(!message.telemetryDescription.contains("older secret question"))
    #expect(!message.telemetryDescription.contains("older secret answer"))
}
