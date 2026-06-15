import Testing
@testable import CodexPortCore

@Test func sessionDetailLayoutUsesSafeAreaInsetInsteadOfFixedOverlayPadding() {
    let compact = SessionDetailLayoutMetrics.composerSafeAreaInset(isComposerCompact: true)
    let expanded = SessionDetailLayoutMetrics.composerSafeAreaInset(isComposerCompact: false)

    #expect(compact.inputBarPlacement == .safeAreaInset)
    #expect(expanded.inputBarPlacement == .safeAreaInset)
    #expect(compact.transcriptBottomSpacer == 12)
    #expect(expanded.transcriptBottomSpacer == 12)
    #expect(compact.jumpToLatestBottomPadding == 12)
    #expect(expanded.jumpToLatestBottomPadding == 12)
}
