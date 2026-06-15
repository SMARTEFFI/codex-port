import Foundation
import Testing

@Test func localRelayWebSocketExecutableStaysAliveWhenStandardInputCloses() async throws {
    let executableURL = packageRoot()
        .appendingPathComponent(".build/debug/codexport-host-agent")
    try #require(FileManager.default.isExecutableFile(atPath: executableURL.path))

    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executableURL
    process.arguments = ["--local-relay-websocket", "--port", "0"]
    process.environment = [
        "CODEXPORT_HOST_AGENT_COMMAND": "/bin/sh",
        "CODEXPORT_HOST_AGENT_ARGUMENTS_JSON": #"["-c","while IFS= read -r line; do printf 'codex:assistant:%s\\n' \"$line\"; done"]"#,
        "CODEXPORT_RELAY_HOST_ID": "11111111-2222-3333-4444-555555555555",
        "CODEXPORT_RELAY_HOST_NAME": "Mac Studio",
        "CODEXPORT_RELAY_HOST_USER": "chenm",
        "CODEXPORT_RELAY_DEVICE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "CODEXPORT_RELAY_DEVICE_NAME": "iPhone A",
    ]
    process.standardInput = try #require(FileHandle(forReadingAtPath: "/dev/null"))
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()

    try await Task.sleep(for: .milliseconds(250))
    let isRunningAfterStandardInputClosed = process.isRunning

    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
    }
    _ = try? stderr.fileHandleForReading.close()
    _ = try? stdout.fileHandleForReading.close()

    #expect(isRunningAfterStandardInputClosed)
}

@Test func hostAgentMenuExecutableStartsAndExitsForSmoke() async throws {
    let executable = URL(filePath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/debug/codexport-host-agent-menu")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))

    let process = Process()
    process.executableURL = executable
    process.environment = [
        "CODEXPORT_HOST_AGENT_MENU_SMOKE": "1",
        "CODEXPORT_HOST_AGENT_MENU_SMOKE_EXIT_AFTER_SECONDS": "0.2",
    ]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    try process.run()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning {
        process.terminate()
    }
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    #expect(process.isRunning == false)
    #expect(output.contains("CodexPort Host Agent menu app started"))
}

private func packageRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
