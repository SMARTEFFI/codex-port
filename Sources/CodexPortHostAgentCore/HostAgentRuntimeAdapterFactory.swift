import Foundation

public enum HostAgentRuntimeBackend: Equatable, Sendable {
    case processStdio
    case codexExecJSON
    case codexCLILive

    public static let productionDefault: HostAgentRuntimeBackend = .codexCLILive

    public static func parse(_ rawValue: String?) throws -> HostAgentRuntimeBackend {
        guard let rawValue, !rawValue.isEmpty else {
            return productionDefault
        }
        switch rawValue {
        case "process-stdio":
            return .processStdio
        case "codex-exec-json":
            return .codexExecJSON
        case "codex-cli-live":
            return .codexCLILive
        default:
            throw HostAgentRuntimeBackendError.invalidBackend(rawValue)
        }
    }
}

public enum HostAgentRuntimeBackendError: Error, Equatable, Sendable {
    case invalidBackend(String)
}

public struct HostAgentRuntimeAdapterFactoryConfiguration: Equatable, Sendable {
    public var backend: HostAgentRuntimeBackend
    public var executablePath: String
    public var processArguments: [String]
    public var codexExecBaseArguments: [String]
    public var codexExecResumeArguments: [String]
    public var codexExecTimeout: Duration
    public var codexControlSocketPath: String

    public init(
        backend: HostAgentRuntimeBackend,
        executablePath: String,
        processArguments: [String],
        codexExecBaseArguments: [String],
        codexExecResumeArguments: [String],
        codexExecTimeout: Duration,
        codexControlSocketPath: String
    ) {
        self.backend = backend
        self.executablePath = executablePath
        self.processArguments = processArguments
        self.codexExecBaseArguments = codexExecBaseArguments
        self.codexExecResumeArguments = codexExecResumeArguments
        self.codexExecTimeout = codexExecTimeout
        self.codexControlSocketPath = codexControlSocketPath
    }
}

public enum HostAgentRuntimeAdapterFactory {
    public static func make(
        configuration: HostAgentRuntimeAdapterFactoryConfiguration
    ) -> HostAgentLocalRelayRuntime.AdapterFactory {
        { request in
            switch configuration.backend {
            case .processStdio:
                return AnyHostAgentLiveSessionAdapter(HostAgentProcessLiveAdapter(
                    command: HostAgentProcessCommand(
                        executablePath: configuration.executablePath,
                        arguments: configuration.processArguments,
                        workingDirectory: request.cwd
                    ),
                    sessionID: request.sessionID,
                    threadID: request.threadID,
                    turnID: request.turnID
                ))
            case .codexExecJSON:
                return AnyHostAgentLiveSessionAdapter(HostAgentCodexExecJSONAdapter(
                    command: HostAgentCodexExecJSONCommand(
                        executablePath: configuration.executablePath,
                        baseArguments: configuration.codexExecBaseArguments.isEmpty
                            ? HostAgentCodexExecJSONCommand.defaultArguments
                            : configuration.codexExecBaseArguments,
                        resumeArguments: configuration.codexExecResumeArguments.isEmpty
                            ? HostAgentCodexExecJSONCommand.defaultArguments
                            : configuration.codexExecResumeArguments
                    ),
                    sessionID: request.sessionID,
                    initialThreadID: request.threadID,
                    turnID: request.turnID,
                    sessionWorkingDirectory: request.cwd,
                    processTimeout: configuration.codexExecTimeout
                ))
            case .codexCLILive:
                return AnyHostAgentLiveSessionAdapter(
                    HostAgentCodexCLILiveAdapter(
                        session: CodexCLILiveSessionDescriptor(
                            sessionID: request.sessionID,
                            threadID: request.threadID,
                            turnID: request.turnID
                        ),
                        producer: CodexAppServerControlSocketLiveProducer(
                            transport: CodexAppServerControlWebSocketTransport(
                                socketPath: configuration.codexControlSocketPath
                            )
                        )
                    ),
                    description: "Codex CLI live adapter"
                )
            }
        }
    }
}
