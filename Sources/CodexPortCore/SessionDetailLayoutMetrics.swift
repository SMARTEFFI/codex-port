import Foundation

public enum SessionInputBarPlacement: Equatable, Sendable {
    case safeAreaInset
}

public struct SessionDetailLayoutMetrics: Equatable, Sendable {
    public var inputBarPlacement: SessionInputBarPlacement
    public var transcriptBottomSpacer: Double
    public var jumpToLatestBottomPadding: Double

    public init(
        inputBarPlacement: SessionInputBarPlacement,
        transcriptBottomSpacer: Double,
        jumpToLatestBottomPadding: Double
    ) {
        self.inputBarPlacement = inputBarPlacement
        self.transcriptBottomSpacer = transcriptBottomSpacer
        self.jumpToLatestBottomPadding = jumpToLatestBottomPadding
    }

    public static func composerSafeAreaInset(isComposerCompact: Bool) -> SessionDetailLayoutMetrics {
        SessionDetailLayoutMetrics(
            inputBarPlacement: .safeAreaInset,
            transcriptBottomSpacer: 12,
            jumpToLatestBottomPadding: 12
        )
    }
}
