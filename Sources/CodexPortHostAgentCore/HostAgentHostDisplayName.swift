import Foundation

public enum HostAgentHostDisplayName {
    public static let legacySyntheticDefault = "CodexPort Dev Mac"

    public static func nonSynthetic(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed == legacySyntheticDefault ? nil : trimmed
    }

    public static func resolved(environmentValue: String?, defaultName: @autoclosure () -> String) -> String {
        nonSynthetic(environmentValue) ?? defaultName()
    }
}
