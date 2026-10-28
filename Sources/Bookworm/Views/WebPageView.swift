import SwiftUI
import AppKit
import WebKit

struct WebPageView: NSViewRepresentable {
    let content: PageContent
    /// 当前书籍标识：同一本书内换章只原地换内容，换书才需要按新的身份判断。
    let bookID: String
    /// 当前页（章）索引，参与内容身份判断。
    let pageIndex: Int
    /// Reading colour scheme — drives both background and text colour.
    let theme: EbookTheme
    /// Reading typeface.
    let font: EbookFont
    /// CSS line-height multiplier.
    let lineSpacing: Double
    let zoom: CGFloat
    let onScrollToTop: () -> Void
    let scrollBridge: ReaderScrollBridge?
    /// 目录跳转后要滚动到的页内锚点（元素 id），nil 表示从页首开始。
    let anchor: String?
    /// 跨章回退时把正文滚到章末，落在上一章最后一页，保持阅读连贯。
    var scrollToEnd: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(Self.bootCSSScript)

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground") // best-effort transparent background
        web.underPageBackgroundColor = .clear
        web.pageZoom = zoom
        scrollBridge?.webView = web
        context.coordinator.lastContent = nil
        context.coordinator.lastAppliedStyle = nil
        context.coordinator.lastZoom = nil
        context.coordinator.desiredAnchor = anchor
        context.coordinator.desiredScrollToEnd = scrollToEnd
        context.coordinator.style = currentStyle
        Self.hideScrollers(in: web)
        return web
    }

    /// 隐藏 WebView 内部滚动条。系统设置为「始终显示滚动条」时，右侧滑块
    /// 会常驻并挤压正文右边缘；CSS 隐藏 webkit 滚动条之外再兜底处理原生
    /// NSScroller，滚动本身不受影响。
    static func hideScrollers(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            return
        }
        for sub in view.subviews { hideScrollers(in: sub) }
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        scrollBridge?.webView = web
        let style = currentStyle
        context.coordinator.style = style
        context.coordinator.desiredAnchor = anchor
        context.coordinator.desiredScrollToEnd = scrollToEnd

        let key = contentKey()
        let contentChanged = context.coordinator.lastContent != key
        if contentChanged {
            context.coordinator.lastContent = key
            context.coordinator.resetScrollAnchor()
            load(into: web)
        }
        // 缩放与样式只在换章或真正变化时才应用。之前每次 SwiftUI 更新
        // 都无条件注入 <style>，脚本先删后建 style 节点会让整章 CSS
        // 重算并重排（工具栏状态变化、翻页都会触发），这里加缓存避免。
        if contentChanged || context.coordinator.lastZoom != zoom {
            context.coordinator.lastZoom = zoom
            web.pageZoom = zoom
        }
        if contentChanged || context.coordinator.lastAppliedStyle != style {
            applyStyle(web, coordinator: context.coordinator)
        }
        if !contentChanged {
            // 同一章节内换锚点（点到别的子标题）时立即滚动。
            context.coordinator.scrollToAnchorIfNeeded(in: web)
        }
    }

    /// The full set of typography + colour inputs bundled so the
    /// coordinator can re-inject the override after async navigation.
    private var currentStyle: ReadingStyle {
        ReadingStyle(theme: theme, font: font, lineSpacing: lineSpacing)
    }

    private func contentKey() -> String {
        let payload: String
        switch content {
        case .htmlFile(let u, _): payload = "f:" + u.path
        case .htmlString(let s, _): payload = "s:\(s.hashValue)"
        case .image: payload = "image"
        }
        // 书籍与页码一起参与身份判断：换书、换章都要原地换内容，
        // 同一章的样式/锚点变化则不应触发重新加载。
        return "\(bookID)#\(pageIndex)#\(payload)"
    }

    private func load(into web: WKWebView) {
        switch content {
        case .htmlFile(let url, let baseAccess):
            web.loadFileURL(url, allowingReadAccessTo: baseAccess)
        case .htmlString(let html, let baseURL):
            web.loadHTMLString(html, baseURL: baseURL)
        case .image:
            break
        }
    }

    private func applyStyle(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.lastAppliedStyle = currentStyle
        web.evaluateJavaScript(Self.overrideScript(for: currentStyle),
                               completionHandler: nil)
    }

    private static var bootCSSScript: WKUserScript {
        // Declare both schemes are supported so a flash of unstyled content
        // adopts the OS appearance until applyStyle() runs with the
        // reader's chosen theme.
        let js = """
        (function() {
            let attach = function() {
                let s = document.createElement('style');
                s.id = 'bookworm-style-boot';
                s.textContent = `:root { color-scheme: dark light; }`;
                document.head ? document.head.appendChild(s) : document.documentElement.appendChild(s);
            };
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', attach);
            } else { attach(); }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Bundle of everything that affects the injected stylesheet.
    struct ReadingStyle: Equatable {
        var theme: EbookTheme
        var font: EbookFont
        var lineSpacing: Double
    }

    // Shared reading-margin rules pinned to body so EPUB chapters get the
    // same comfortable left/right padding as the MOBI/TXT wrapper. 正文列宽
    // 跟随窗口铺满（只保留固定页边距），与在线阅读窗口的排版宽度一致；
    // 同时隐藏 WebKit 的滚动条，避免右侧滑块挤压/遮挡正文（BR-60）。
    static let marginCSS = """
    html {
        margin: 0 !important;
        padding: 0 !important;
        scrollbar-width: none !important;
    }
    html::-webkit-scrollbar,
    body::-webkit-scrollbar,
    *::-webkit-scrollbar {
        width: 0 !important;
        height: 0 !important;
        background: transparent !important;
        display: none !important;
    }
    body {
        margin: 0 auto !important;
        padding: 36px 32px 40px !important;
        max-width: 100% !important;
        box-sizing: border-box !important;
    }
    body img, body figure, body table {
        max-width: 100% !important;
        height: auto !important;
        box-sizing: border-box !important;
    }
    """

    /// Build the full override stylesheet for a given reading style.
    /// The `body *` selector with `!important` nukes any colour the
    /// EPUB/MOBI author baked into individual elements (they often
    /// assume a light theme and ship dark-on-light text that becomes
    /// invisible in dark mode). Font-family and line-height are pinned
    /// to `body` only — applying them to `body *` would clobber `<pre>`
    /// monospace and tight heading leading.
    static func css(for style: ReadingStyle) -> String {
        let t = style.theme
        return """
        \(marginCSS)
        html, body { background: transparent !important; color: \(t.cssText) !important; }
        body {
            color: \(t.cssText) !important;
            font-family: \(style.font.cssFamily) !important;
            line-height: \(String(format: "%.2f", style.lineSpacing)) !important;
        }
        body p, body div, body span, body li, body td, body blockquote,
        body h1, body h2, body h3, body h4, body h5, body h6 {
            color: \(t.cssText) !important;
        }
        body a, body a *, body a:visited, body a:visited * { color: \(t.cssLink) !important; }
        body img { opacity: \(t.isDark ? "0.95" : "1"); }
        """
    }

    static func overrideScript(for style: ReadingStyle) -> String {
        let cssText = css(for: style)
        let scheme = style.theme.isDark ? "dark" : "light"
        // The window background is painted by SwiftUI behind the web
        // view; we keep the page itself transparent so that shows
        // through, but set color-scheme so form controls/scrollbars
        // match.
        return """
        (function() {
            document.documentElement.style.colorScheme = '\(scheme)';
            let id = 'bookworm-style';
            let existing = document.getElementById(id);
            if (existing) existing.remove();
            let s = document.createElement('style');
            s.id = id;
            s.textContent = `\(cssText.replacingOccurrences(of: "`", with: "\\`"))`;
            document.head ? document.head.appendChild(s) : document.documentElement.appendChild(s);
            \(bottomMaskScript(fallbackColor: style.theme.cssBackground))
            if (window.__bwSyncMask) { requestAnimationFrame(function() { window.__bwSyncMask(); }); }
        })();
        """
    }

    /// 页面上下边遮罩：滚动式阅读时视口边缘常常正好切在一行中间，露出的
    /// 半行看上去就像被工具栏/底栏压住。这里在视口上下各盖一层与页面同色的
    /// 遮罩，只显示完整的行；底边被遮的那一行恰好是下一页首行，翻页依旧连续。
    /// 手动滚动（滚轮）时撤掉遮罩，避免盖住刚滚出来的正文。
    static func bottomMaskScript(fallbackColor: String) -> String {
        """
        window.__bwMaskFallback = '\(fallbackColor)';
        (function() {
            // 视口内某一点所在「文字行」的矩形（视口坐标）。按行框逐行取
            // getClientRects，比 caretRangeFromPoint 稳：段落内的每一行都是
            // 一个矩形，翻页对齐和底部遮罩都用它。
            window.__bwLineRectAt = function(px, py) {
                var el = document.elementFromPoint(px, py);
                var depth = 0;
                while (el && el !== document.body && el !== document.documentElement && depth < 6) {
                    try {
                        var r = document.createRange();
                        r.selectNodeContents(el);
                        var rects = r.getClientRects();
                        if (rects.length && rects.length < 5000) {
                            for (var i = 0; i < rects.length; i++) {
                                var rc = rects[i];
                                if (rc.height > 0 && py >= rc.top - 1 && py <= rc.bottom + 1) {
                                    // 同一段落里紧跟着的下一行行顶（可能落在视口外），
                                    // 翻页时据此判断“下一页第一行”到底是哪一行。
                                    var next = null;
                                    for (var k = i + 1; k < rects.length; k++) {
                                        if (rects[k].height > 0) { next = rects[k].top; break; }
                                    }
                                    var lh = parseFloat(window.getComputedStyle(el).lineHeight);
                                    return {
                                        top: rc.top,
                                        bottom: rc.bottom,
                                        height: rc.height,
                                        next: next,
                                        lineHeight: (isFinite(lh) && lh > 0) ? lh : rc.height
                                    };
                                }
                            }
                        }
                    } catch (e) {}
                    el = el.parentElement;
                    depth++;
                }
                return null;
            };

            // 取页面在该点真正露出来的背景色（窗口背景是透明的，
            // 所以一路透明时交给 Swift 侧传入的主题底色兜底）。
            function pageColor(px, py) {
                var el = document.elementFromPoint(px, py);
                while (el) {
                    var bg = window.getComputedStyle(el).backgroundColor;
                    if (bg && bg !== 'transparent' && bg !== 'rgba(0, 0, 0, 0)') { return bg; }
                    el = el.parentElement;
                }
                return null;
            }

            function maskNode(id, atTop) {
                var mask = document.getElementById(id);
                if (mask && mask.isConnected) { return mask; }
                mask = document.createElement('div');
                mask.id = id;
                mask.style.cssText = 'position:fixed;left:0;right:0;' +
                    (atTop ? 'top:0;' : 'bottom:0;') + 'height:0;' +
                    'pointer-events:none;z-index:2147483647;';
                (document.body || document.documentElement).appendChild(mask);
                return mask;
            }

            function applyMask(id, atTop, height, color) {
                var mask = maskNode(id, atTop);
                if (height < 1) { mask.style.height = '0px'; return; }
                mask.style.background = color;
                mask.style.height = Math.round(height) + 'px';
            }

            window.__bwHideMask = function() {
                applyMask('bw-top-mask', true, 0, '');
                applyMask('bw-bottom-mask', false, 0, '');
            };

            // 视口上下边可能各切在一行中间。把被切的半行遮住（用页面同色），
            // 可见文字就只剩完整的行；底边被遮的那一行正好是下一页首行，
            // 顶边被遮的那一行在上一页已经完整看过。
            window.__bwSyncMask = function() {
                var root = document.documentElement;
                var h = window.innerHeight || root.clientHeight || 0;
                var width = root.clientWidth || window.innerWidth || 0;
                if (h <= 0 || width <= 0) { window.__bwHideMask(); return; }
                var px = Math.round(width * 0.5);
                var bg = pageColor(px, Math.max(1, Math.round(h - 3))) || window.__bwMaskFallback;

                var bottomLine = null;
                var bprobes = [h - 1, h - 4, h - 10, h - 20, h - 34];
                for (var i = 0; i < bprobes.length && bottomLine === null; i++) {
                    if (bprobes[i] > 0) { bottomLine = window.__bwLineRectAt(px, bprobes[i]); }
                }
                var bh = 0;
                if (bottomLine && bottomLine.bottom > h + 1) {
                    bh = Math.min(h, Math.max(1, h - bottomLine.top));
                }
                applyMask('bw-bottom-mask', false, bh, bg);

                var topLine = null;
                var tprobes = [1, 4, 10, 20, 34, 60];
                for (var j = 0; j < tprobes.length && topLine === null; j++) {
                    topLine = window.__bwLineRectAt(px, tprobes[j]);
                }
                var th = 0;
                if (topLine && topLine.top < -1) {
                    th = Math.min(h, Math.max(1, topLine.bottom + 1));
                }
                applyMask('bw-top-mask', true, th, bg);
            };

            if (!window.__bwMaskWheelBound) {
                window.__bwMaskWheelBound = true;
                window.addEventListener('wheel', function() { window.__bwHideMask(); },
                                        { passive: true });
            }
        })();
        """
    }

    /// 把锚点转成 `scrollIntoView` 脚本。锚点里的中文、引号都要安全嵌入。
    static func scrollScript(for anchor: String) -> String {
        let literal: String
        if let data = try? JSONSerialization.data(withJSONObject: anchor,
                                                  options: .fragmentsAllowed),
           let json = String(data: data, encoding: .utf8) {
            literal = json
        } else {
            literal = "\"\""
        }
        return """
        (function() {
            function go() {
                var id = \(literal);
                var el = document.getElementById(id);
                if (!el) {
                    var named = document.getElementsByName(id);
                    el = named.length ? named[0] : null;
                }
                if (el) { el.scrollIntoView({ block: 'start' }); }
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', go);
            } else {
                setTimeout(go, 0);
            }
        })();
        """
    }

    /// 把正文滚到文档末尾。跨章回退时用，让上一章停在最后一页。
    static let scrollToEndScript = """
    (function() {
        function go() {
            var doc = document.documentElement;
            var h = window.innerHeight || doc.clientHeight || 0;
            var maxY = Math.max(0, (doc.scrollHeight || 0) - h);
            window.scrollTo(0, maxY);
        }
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', go);
        } else {
            setTimeout(go, 0);
        }
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastContent: String?
        /// 上一次注入到页面里的样式；与当前样式相同就不再重复注入。
        var lastAppliedStyle: ReadingStyle?
        /// 上一次设置的 pageZoom；避免每次 SwiftUI 更新都重设。
        var lastZoom: CGFloat?
        var style: ReadingStyle = ReadingStyle(theme: .dark, font: .serif, lineSpacing: 1.6)
        /// 当前希望滚动到的锚点。
        var desiredAnchor: String?
        /// 当前希望在加载完成后滚到章末。
        var desiredScrollToEnd = false
        /// 已经滚动过的锚点，避免 SwiftUI 每次刷新都重复滚动。
        private var lastScrolledAnchor: String?
        /// 已经执行过章末滚动，避免重复触发。
        private var didScrollToEnd = false

        func resetScrollAnchor() {
            lastScrolledAnchor = nil
            didScrollToEnd = false
        }

        func scrollToAnchorIfNeeded(in webView: WKWebView) {
            guard let anchor = desiredAnchor, !anchor.isEmpty,
                  anchor != lastScrolledAnchor else { return }
            lastScrolledAnchor = anchor
            webView.evaluateJavaScript(WebPageView.scrollScript(for: anchor),
                                       completionHandler: nil)
        }

        func scrollToEndIfNeeded(in webView: WKWebView) {
            guard desiredScrollToEnd, !didScrollToEnd else { return }
            didScrollToEnd = true
            webView.evaluateJavaScript(WebPageView.scrollToEndScript,
                                       completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Open external links in the user's default browser; allow file:// and about: navigation.
            if let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        // Re-inject the colour override against the freshly-loaded document.
        // applyDark from updateNSView fires immediately after loadFileURL,
        // which is asynchronous — so our <style> was being attached to the
        // previous chapter's document (or about:blank) and the new chapter
        // would render with the publisher's own dark-on-dark text. Catching
        // didFinish guarantees the override lands on the real document.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 加载完成后重新确认原生滚动条隐藏（WebKit 可能在内容加载时重建内部视图）。
            WebPageView.hideScrollers(in: webView)
            // 先注入样式再滚动，避免样式引起重排把锚点位置带偏。
            lastAppliedStyle = style
            webView.evaluateJavaScript(
                WebPageView.overrideScript(for: style)
            ) { [weak self] _, _ in
                guard let self else { return }
                self.scrollToAnchorIfNeeded(in: webView)
                self.scrollToEndIfNeeded(in: webView)
            }
        }

        // Some EPUBs trigger same-document navigations (anchor links between
        // sections inside one chapter). Re-applying on commit catches those.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            lastAppliedStyle = style
            webView.evaluateJavaScript(
                WebPageView.overrideScript(for: style),
                completionHandler: nil
            )
        }
    }
}
