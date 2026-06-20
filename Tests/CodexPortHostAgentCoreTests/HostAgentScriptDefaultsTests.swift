import Foundation
import Testing

@Test func hostAgentStartScriptsDoNotDefaultToSyntheticHostName() throws {
    let root = try repositoryRoot()
    let scripts = [
        "scripts/start-host-agent-menu-p2p.sh",
        "scripts/issue74-start-hostagent-p2p.sh",
        "scripts/issue74-idle-tui-sim-smoke.sh",
        "scripts/issue74-idle-tui-device-smoke.sh",
        "scripts/issue74-make-verify-deeplinks.sh",
    ]

    for script in scripts {
        let contents = try String(contentsOf: root.appending(path: script), encoding: .utf8)
        #expect(!contents.contains("CODEXPORT_RELAY_HOST_NAME:-CodexPort Dev Mac"))
    }
}

@Test func hostAgentHostNameHelperReturnsLocalMachineName() throws {
    let root = try repositoryRoot()
    let output = try runShell(
        "source scripts/lib/host-name.sh; codexport_default_host_name",
        at: root
    )

    #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) != "CodexPort Dev Mac")
}

private func repositoryRoot() throws -> URL {
    var url = URL(filePath: #filePath)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    throw ScriptDefaultsTestError.repositoryRootNotFound
}

private func runShell(_ command: String, at directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.currentDirectoryURL = directory
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = ["-c", command]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ScriptDefaultsTestError.commandFailed(text)
    }
    return text
}

private enum ScriptDefaultsTestError: Error {
    case repositoryRootNotFound
    case commandFailed(String)
}
