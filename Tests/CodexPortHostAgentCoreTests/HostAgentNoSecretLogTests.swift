import Foundation
import Testing
@testable import CodexPortHostAgentCore

@Test func hostAgentDiagnosticExportRedactsSecretsAndPromptPlaintext() {
    let logger = HostAgentLogRecorder()
    let sentinels = [
        "pairing-token-123456",
        "sk-codex-secret-token",
        "ssh-password-secret",
        "secret codex user prompt plaintext",
    ]

    logger.record("pairing token pairing-token-123456 was generated")
    logger.record("codex token sk-codex-secret-token loaded from local environment")
    logger.record("ssh password ssh-password-secret should never be logged")
    logger.record("prompt secret codex user prompt plaintext should be opaque")

    let export = HostAgentDiagnosticExporter().export(logs: logger.entries, extraSecretHints: sentinels)

    for sentinel in sentinels {
        #expect(export.contains(sentinel) == false)
    }
    #expect(export.contains("[REDACTED]"))
    #expect(export.contains("pairing token [REDACTED] was generated"))
    #expect(export.contains("prompt [REDACTED] should be opaque"))
}

@Test func hostAgentSupportExportRedactsAllClientHostPayloadAndCredentialClasses() {
    let sentinels = [
        "pairing-token-123456",
        "sk-codex-secret-token",
        "ssh-password-secret",
        "API_KEY_SECRET_123",
        "PROMPT_SECRET_98b7c",
        "ASSISTANT_SECRET_74ad",
        "COMMAND_OUTPUT_SECRET_31a9",
        "DIFF_SECRET_55ff",
        "APPROVAL_SECRET_22aa",
    ]

    let export = HostAgentDiagnosticExporter().export(
        logs: [
            "Host protocol ready",
            "prompt PROMPT_SECRET_98b7c",
            "assistant ASSISTANT_SECRET_74ad",
            "command output COMMAND_OUTPUT_SECRET_31a9",
            "diff DIFF_SECRET_55ff",
            "approval APPROVAL_SECRET_22aa",
        ],
        diagnostics: [
            "Signaling: authorized to signal",
            "DataChannel: open",
            "Codex token sk-codex-secret-token",
            "SSH secret ssh-password-secret",
            "API key API_KEY_SECRET_123",
        ],
        signalingLogs: [
            "offer payload PROMPT_SECRET_98b7c",
            "pairing token pairing-token-123456",
        ],
        extraSecretHints: sentinels
    )

    for sentinel in sentinels {
        #expect(export.contains(sentinel) == false)
    }
    #expect(export.contains("Signaling: authorized to signal"))
    #expect(export.contains("DataChannel: open"))
    #expect(export.contains("prompt [REDACTED]"))
    #expect(export.contains("offer payload [REDACTED]"))
}
