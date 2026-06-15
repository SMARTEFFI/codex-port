import Foundation

public final class HostAgentLogRecorder: @unchecked Sendable {
    private var recordedEntries: [String] = []
    private let lock = NSLock()

    public init() {}

    public var entries: [String] {
        lock.withLock {
            recordedEntries
        }
    }

    public func record(_ message: String) {
        lock.withLock {
            recordedEntries.append(message)
        }
    }
}

public struct HostAgentDiagnosticExporter: Sendable {
    public init() {}

    public func export(logs: [String], extraSecretHints: [String] = []) -> String {
        export(logs: logs, diagnostics: [], signalingLogs: [], extraSecretHints: extraSecretHints)
    }

    public func export(
        logs: [String],
        diagnostics: [String],
        signalingLogs: [String],
        extraSecretHints: [String] = []
    ) -> String {
        let redactor = HostAgentLogRedactor(secretHints: extraSecretHints)
        return (logs + diagnostics + signalingLogs)
            .map { redactor.redact($0) }
            .joined(separator: "\n")
    }
}

private struct HostAgentLogRedactor: Sendable {
    private let secretHints: [String]

    init(secretHints: [String]) {
        self.secretHints = secretHints
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    func redact(_ value: String) -> String {
        var redacted = value
        for hint in secretHints {
            redacted = redacted.replacingOccurrences(of: hint, with: "[REDACTED]")
        }
        redacted = redacted.redacting(pattern: #"sk-[A-Za-z0-9_\-]+"#)
        redacted = redacted.redacting(pattern: #"pairing-token-[A-Za-z0-9_\-]+"#)
        return redacted
    }
}

private extension String {
    func redacting(pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: "[REDACTED]")
    }
}
