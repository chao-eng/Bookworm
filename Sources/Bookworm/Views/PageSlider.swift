import SwiftUI
import AppKit
import WebKit

/// 记录当前阅读内容的可滚动视图，供 ↑/↓ 方向键滚动使用。
/// 文本格式走 WKWebView 的 JS 滚动，图像/缩放格式走 NSScrollView。
final class ReaderScrollBridge {
    weak var webView: WKWebView?
    weak var scrollView: NSScrollView?

    /// 返回 false 表示当前页面没有可滚动内容（例如整页已适配窗口），
    /// 调用方应把按键事件继续交给响应者链。
    @discardableResult
    func scrollVertically(by dy: CGFloat) -> Bool {
        if let webView {
            webView.evaluateJavaScript("window.scrollBy(0, \(dy));", completionHandler: nil)
            return true
        }
        if let scrollView, let clip = scrollView.contentView as NSClipView? {
            let docHeight = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, docHeight - clip.bounds.height)
            let y = min(max(0, clip.bounds.origin.y + dy), maxY)
            guard abs(y - clip.bounds.origin.y) > 0.01 else { return true }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            return true
        }
        return false
    }
}

struct PageSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reversed: Bool

    var body: some View {
        // Flipping the binding alone only mirrored the thumb's position — the
        // fill direction (and which way you had to drag) stayed left-to-right.
        // Forcing layoutDirection on the Slider's environment flips the whole
        // control: thumb starts on the right at page 0, the fill grows from
        // the right toward the thumb, and dragging left advances pages,
        // which matches the right-to-left reading flow.
        Slider(value: $value, in: range, step: 1)
            .controlSize(.regular)
            .tint(.white)
            .environment(\.layoutDirection, reversed ? .rightToLeft : .leftToRight)
    }
}

struct KeyEventHandlingView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    /// Trackpad swipe-between-pages gesture. Receives the event's
    /// `deltaX` (positive = swipe toward the left). Optional so existing
    /// callers that only want key handling don't have to supply it.
    var onSwipe: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKeyDown = onKeyDown
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onSwipe = onSwipe
    }
}

final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onSwipe: ((CGFloat) -> Void)?
    private var keyMonitor: Any?
    private var swipeMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard let eventWindow = window else { return }

        // 窗口级本地监听在事件派发给第一响应者「之前」执行，所以焦点落在
        // WKWebView、页码滑块或工具栏按钮上时方向键依然能翻页。仅靠
        // makeFirstResponder 抢一次焦点做不到这一点——焦点一旦被别的控件
        // 拿走就再也回不来。是否放行（输入框、⌘/⌃ 组合键）由 handleKey 决定。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak eventWindow] event in
            guard let self, let eventWindow, event.window === eventWindow else { return event }
            return self.onKeyDown?(event) == true ? nil : event
        }
        // 触控板双指滑动也走监听，这样焦点在 WKWebView 里时滑动翻页仍然有效。
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self, weak eventWindow] event in
            guard let self, let eventWindow, event.window === eventWindow, event.deltaX != 0 else {
                return event
            }
            self.onSwipe?(event.deltaX)
            return nil
        }

        // 兜底：把本视图设为第一响应者，保证就算本地监听没能覆盖到（例如
        // 某些输入法或系统级拦截），按键与滑动仍能经由响应者链抵达这里。
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Two/three-finger trackpad swipe (the system "swipe between pages"
    /// gesture). Distinct from scrollWheel, so it doesn't fight the
    /// reader's NSScrollView panning when the page is zoomed in.
    override func swipe(with event: NSEvent) {
        if event.deltaX != 0 {
            onSwipe?(event.deltaX)
        } else {
            super.swipe(with: event)
        }
    }

    deinit { removeMonitors() }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
        }
    }
}
