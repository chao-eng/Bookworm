import AppKit

/// 阅读器统一键盘导航（BR-18）。
///
/// 键位只表达「方向 × 粒度」两种意图，具体落到翻页 / 翻章 / 滚动由各阅读器
/// 按自身能力实现。此前的本地阅读器与在线阅读器各自维护一套键位表，导致
/// 同一个按键在不同书型里含义不同（本地横向键翻章、在线纵向键翻章）。
enum ReaderNavigation {
    enum Intent {
        /// 前进一屏：文字书滚动一屏，到边界自动跨章；图片书为下一页。
        case pageForward
        /// 后退一屏，语义与 `pageForward` 对称。
        case pageBackward
        case chapterForward
        case chapterBackward
        case toStart
        case toEnd
    }

    /// 物理键 → 意图所需的上下文。
    struct Context {
        /// 从右到左阅读（漫画）时左右方向键互换，让「前」始终跟随阅读流向。
        var isRightToLeft: Bool = false
    }

    /// 解析按键意图；返回 nil 表示不处理，事件继续沿响应者链传递。
    static func intent(for event: NSEvent, context: Context) -> Intent? {
        // ⌘/⌃ 组合键（⌘← 行首、⌃→ 切换桌面等）交给系统处理。
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return nil }
        // 焦点在输入框（含 SwiftUI TextField 的 field editor、搜索框、跳页
        // 输入框以及输入法组字）时，方向键属于文本编辑，交给控件自己。
        if let firstResponder = event.window?.firstResponder, firstResponder is NSText { return nil }

        // ⌥↑/⌥↓ = 上一章/下一章：章级导航独立出来，不与页级争抢方向键。
        if event.modifierFlags.contains(.option) {
            switch event.keyCode {
            case Key.up: return .chapterBackward
            case Key.down: return .chapterForward
            default: return nil
            }
        }

        switch event.keyCode {
        case Key.left:
            return context.isRightToLeft ? .pageForward : .pageBackward
        case Key.right:
            return context.isRightToLeft ? .pageBackward : .pageForward
        case Key.up:
            return .pageBackward
        case Key.down:
            return .pageForward
        case Key.space, Key.pageDown:
            return .pageForward
        case Key.pageUp:
            return .pageBackward
        case Key.home:
            return .toStart
        case Key.end:
            return .toEnd
        default:
            return nil
        }
    }

    private enum Key {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let space: UInt16 = 49
        static let pageUp: UInt16 = 116
        static let pageDown: UInt16 = 121
        static let home: UInt16 = 115
        static let end: UInt16 = 119
    }
}
