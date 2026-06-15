import Foundation

public enum HostAgentCodexCommandResolver {
    public static func executablePath(
        explicitCommand: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard explicitCommand == nil || explicitCommand?.isEmpty == true else {
            return explicitCommand!
        }
        return resolve("codex", environment: environment) ?? "codex"
    }

    public static func resolve(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if command.contains("/") {
            return command
        }
        for directory in searchPath(environment: environment) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func searchPath(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        return pathDirectories + [
            "\(home)/.local/bin",
            "\(home)/.codex/packages/standalone/current/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }
}
