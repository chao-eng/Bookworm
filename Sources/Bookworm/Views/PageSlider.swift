import SwiftUI
import AppKit
import WebKit

/// 记录当前阅读内容的可滚动视图，供页级方向键翻屏使用。
/// 文本格式走 WKWebView 的 JS 滚动，图像/缩放格式走 NSScrollView。
final class ReaderScrollBridge {
    weak var webView: WKWebView?
    weak var scrollView: NSScrollView?

    /// 跨章节流：章节切换需要重新加载内容，期间重复触发的边界回调要丢弃，
    /// 否则连按方向键会一次跨过好几章。
    private var lastBoundaryTurn: TimeInterval = 0

    /// 按「一屏」滚动：文本书走 JS 滚动网页，图片书直接调整 NSScrollView。
    /// 滚到章边界时通过 `onBoundary` 通知调用方跨章。
    /// 返回 false 表示没有可滚动视图（例如纵向条漫的 SwiftUI ScrollView），
    /// 调用方应直接按页翻。
    @discardableResult
    func turnScreen(forward: Bool, onBoundary: @escaping () -> Void) -> Bool {
        if let webView {
            let forwardJS = forward ? "true" : "false"
            let js = """
            (function() {
                var forward = \(forwardJS);
                var root = document.documentElement;
                var h = window.innerHeight || root.clientHeight || 0;
                if (h <= 0) { return 'none'; }
                var maxY = Math.max(0, (root.scrollHeight || 0) - h);
                var y = window.pageYOffset || root.scrollTop || 0;
                if (forward && y >= maxY - 1) { return 'end'; }
                if (!forward && y <= 1) { return 'start'; }

                var width = root.clientWidth || window.innerWidth || 0;
                var px = Math.round(width * 0.5);
                // 行矩形由页面脚本提供（按段落逐行 getClientRects），
                // 拿不到时退化成整屏步进。
                function lineAt(py) {
                    return window.__bwLineRectAt ? window.__bwLineRectAt(px, py) : null;
                }
                function lineHeightAt(py) {
                    var el = document.elementFromPoint(px, py);
                    var v = el ? parseFloat(window.getComputedStyle(el).lineHeight) : NaN;
                    if (!isFinite(v) || v <= 0) {
                        v = parseFloat(window.getComputedStyle(document.body).lineHeight);
                    }
                    if (!isFinite(v) || v <= 0) {
                        v = parseFloat(window.getComputedStyle(document.body).fontSize || '16') * 1.6;
                    }
                    return v;
                }

                var target;
                if (forward) {
                    // 定位视口底边那一行：
                    //  · 它被切掉半行 → 已被遮罩盖住，下一页正好从它开始；
                    //  · 它完整显示 → 下一页从它的下一行开始，避免重复一行。
                    var bottom = null;
                    var probes = [h - 1, h - 4, h - 10, h - 20, h - 34];
                    for (var i = 0; i < probes.length && bottom === null; i++) {
                        if (probes[i] > 0) { bottom = lineAt(probes[i]); }
                    }
                    var step = h * 0.95;
                    if (bottom) {
                        var lhB = bottom.lineHeight || bottom.height || 0;
                        if (bottom.bottom > h + 1) {
                            step = bottom.top;
                        } else if (bottom.next !== null && bottom.next !== undefined) {
                            step = bottom.next;
                        } else {
                            step = bottom.bottom + Math.max(0, lhB - bottom.height) / 2;
                        }
                        step = Math.min(h + lhB, Math.max(h * 0.4, step));
                    }
                    target = Math.min(maxY, y + step);
                } else {
                    // 后退整行数，顶端同样对齐行首。
                    var topLine = null;
                    var tprobes = [1, 4, 10, 20, 34, 60];
                    for (var j = 0; j < tprobes.length && topLine === null; j++) {
                        topLine = lineAt(tprobes[j]);
                    }
                    var lh = lineHeightAt(topLine ? Math.round(Math.max(1, topLine.top + 1)) : 4);
                    var count = Math.max(1, Math.floor(h / lh));
                    var anchor = topLine ? topLine.top + y : y;
                    target = Math.max(0, anchor - count * lh);
                    if (target > y - 1) { target = Math.max(0, y - h * 0.95); }
                }
                window.scrollTo(0, Math.round(target));
                // 翻页后重算底部遮罩：视口底边若切在行中间，把半行遮住，
                // 保证可见文字停在完整的行上（被遮住的正是下一页首行）。
                if (window.__bwSyncMask) {
                    window.__bwSyncMask();
                    requestAnimationFrame(function() { window.__bwSyncMask(); });
                }
                return 'ok';
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let state = result as? String else { return }
                guard state == (forward ? "end" : "start") else { return }
                self.notifyBoundary(onBoundary)
            }
            return true
        }
        if let scrollView, let clip = scrollView.contentView as NSClipView? {
            let viewport = clip.bounds.height
            let docHeight = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, docHeight - viewport)
            // 整页已适配窗口（无纵向滚动空间）时直接按页翻。
            guard viewport > 0, maxY > 0 else {
                notifyBoundary(onBoundary)
                return true
            }
            let y = clip.bounds.origin.y
            let step = max(1, viewport * 0.92)
            if forward, y >= maxY - 0.5 {
                notifyBoundary(onBoundary)
                return true
            }
            if !forward, y <= 0.5 {
                notifyBoundary(onBoundary)
                return true
            }
            let target = forward ? min(y + step, maxY) : max(y - step, 0)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            return true
        }
        return false
    }

    private func notifyBoundary(_ onBoundary: @escaping () -> Void) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastBoundaryTurn > 0.35 else { return }
        lastBoundaryTurn = now
        onBoundary()
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
