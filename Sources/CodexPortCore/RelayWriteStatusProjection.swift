import CodexPortShared

public struct RelayWriteStatusProjection: Sendable {
    public init() {}

    public func apply(_ event: RelayLiveSessionEvent, to composer: inout InputComposer) {
        guard case let .writeStatusChanged(_, status) = event else {
            return
        }

        switch status {
        case .queued:
            composer.text = ""
            composer.attachments = []
            composer.isRunning = false
        case .running:
            composer.isRunning = true
        case .handled:
            composer.isRunning = false
        case .failed:
            composer.isRunning = false
        }
    }
}
