import Foundation
import Testing

@Test func codexportRelayExecutableStartsAndPrintsOperatorEndpointsInSmokeMode() async throws {
    let relayExecutable = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: ".build/debug/codexport-relay")
    let process = Process()
    process.executableURL = relayExecutable
    process.arguments = ["--listen-host", "127.0.0.1", "--port", "0"]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "CODEXPORT_RELAY_PUBLIC_BASE_URL": "https://relay.example.test",
        "CODEXPORT_RELAY_SMOKE_EXIT_AFTER_START": "1",
    ]) { _, new in new }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, Comment(rawValue: errorOutput))
    #expect(output.contains("CodexPort Relay listening on 127.0.0.1:0"))
    #expect(output.contains("Public stream endpoint: wss://relay.example.test/v0/streams"))
    #expect(output.contains("Host Agent endpoint: wss://relay.example.test/v0/host/connect"))
    #expect(output.contains("Local stream endpoint: ws://127.0.0.1:"))
    #expect(output.contains("Local Host Agent endpoint: ws://127.0.0.1:"))
}
