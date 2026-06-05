import Foundation

public enum SessionScrollAnchor: Equatable, Sendable {
    case bottom
    case preserve
}

public struct SessionTimelineState: Equatable, Sendable {
    public private(set) var items: [VisibleItem]
    public private(set) var isPinnedToBottom: Bool

    public init(items: [VisibleItem] = [], isPinnedToBottom: Bool = true) {
        self.items = items
        self.isPinnedToBottom = isPinnedToBottom
    }

    @discardableResult
    public mutating func replaceLoadedItems(_ items: [VisibleItem]) -> SessionScrollAnchor {
        self.items = items
        isPinnedToBottom = true
        return .bottom
    }

    @discardableResult
    public mutating func applyLiveItems(_ items: [VisibleItem]) -> SessionScrollAnchor {
        self.items = items
        return isPinnedToBottom ? .bottom : .preserve
    }

    @discardableResult
    public mutating func prependHistoryItems(_ items: [VisibleItem]) -> SessionScrollAnchor {
        self.items = items
        isPinnedToBottom = false
        return .preserve
    }

    @discardableResult
    public mutating func setPinnedToBottom(_ pinned: Bool) -> Bool {
        guard isPinnedToBottom != pinned else { return false }
        isPinnedToBottom = pinned
        return true
    }

    @discardableResult
    public mutating func userMovedAwayFromBottom() -> Bool {
        setPinnedToBottom(false)
    }

    @discardableResult
    public mutating func userReturnedToBottom() -> Bool {
        setPinnedToBottom(true)
    }
}
