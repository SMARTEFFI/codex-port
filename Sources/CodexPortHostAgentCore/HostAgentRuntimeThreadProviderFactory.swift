import Foundation

public struct HostAgentRuntimeThreadProviders: Sendable {
    public var threadListProvider: any HostAgentThreadListProviding
    public var threadStarter: any HostAgentThreadStarting
    public var threadHistoryProvider: any HostAgentThreadHistoryProviding

    public init(
        threadListProvider: any HostAgentThreadListProviding,
        threadStarter: any HostAgentThreadStarting,
        threadHistoryProvider: any HostAgentThreadHistoryProviding
    ) {
        self.threadListProvider = threadListProvider
        self.threadStarter = threadStarter
        self.threadHistoryProvider = threadHistoryProvider
    }
}

public enum HostAgentRuntimeThreadProviderFactory {
    public static func make(
        backend: HostAgentRuntimeBackend,
        codexControlSocketPath: String
    ) -> HostAgentRuntimeThreadProviders {
        switch backend {
        case .codexCLILive:
            // Live writes use the control socket, but metadata must remain available
            // when the daemon socket is not running yet. New threads must be
            // created through the same control socket that will receive their
            // first live prompt; otherwise the daemon cannot find the thread.
            let provider = HostAgentCodexAppServerThreadListProvider()
            return HostAgentRuntimeThreadProviders(
                threadListProvider: provider,
                threadStarter: HostAgentCodexAppServerControlThreadProvider(
                    transport: CodexAppServerControlWebSocketTransport(socketPath: codexControlSocketPath)
                ),
                threadHistoryProvider: provider
            )
        case .processStdio, .codexExecJSON:
            let provider = HostAgentCodexAppServerThreadListProvider()
            return HostAgentRuntimeThreadProviders(
                threadListProvider: provider,
                threadStarter: provider,
                threadHistoryProvider: provider
            )
        }
    }
}
