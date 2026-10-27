import SwiftUI
import AppKit
import WebKit

struct WebPageView: NSViewRepresentable {
    let content: PageContent
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
        context.coordinator.desiredAnchor = anchor
        context.coordinator.style = currentStyle
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.pageZoom = zoom
        scrollBridge?.webView = web
        context.coordinator.style = currentStyle
        context.coordinator.desiredAnchor = anchor
        let key = contentKey()
        let contentChanged = context.coordinator.lastContent != key
        if contentChanged {
            context.coordinator.lastContent = key
            context.coordinator.resetScrollAnchor()
            load(into: web)
        }
        applyStyle(web)
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
        switch content {
        case .htmlFile(let u, _): return "f:" + u.path
        case .htmlString(let s, _): return "s:\(s.hashValue)"
        case .image: return "image"
        }
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

    private func applyStyle(_ web: WKWebView) {
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
    // same comfortable left/right padding as the MOBI/TXT wrapper. The
    // `max(28px, calc(50% - 380px))` formula gives a content column that's
    // ≤ 760px wide and centered, with a minimum 28-px side gutter on narrow
    // windows.
    static let marginCSS = """
    html { margin: 0 !important; padding: 0 !important; }
    body {
        margin: 0 auto !important;
        padding: 48px max(28px, calc(50% - 380px)) !important;
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastContent: String?
        var style: ReadingStyle = ReadingStyle(theme: .dark, font: .serif, lineSpacing: 1.6)
        /// 当前希望滚动到的锚点。
        var desiredAnchor: String?
        /// 已经滚动过的锚点，避免 SwiftUI 每次刷新都重复滚动。
        private var lastScrolledAnchor: String?

        func resetScrollAnchor() {
            lastScrolledAnchor = nil
        }

        func scrollToAnchorIfNeeded(in webView: WKWebView) {
            guard let anchor = desiredAnchor, !anchor.isEmpty,
                  anchor != lastScrolledAnchor else { return }
            lastScrolledAnchor = anchor
            webView.evaluateJavaScript(WebPageView.scrollScript(for: anchor),
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
            // 先注入样式再滚动，避免样式引起重排把锚点位置带偏。
            webView.evaluateJavaScript(
                WebPageView.overrideScript(for: style)
            ) { [weak self] _, _ in
                self?.scrollToAnchorIfNeeded(in: webView)
            }
        }

        // Some EPUBs trigger same-document navigations (anchor links between
        // sections inside one chapter). Re-applying on commit catches those.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                WebPageView.overrideScript(for: style),
                completionHandler: nil
            )
        }
    }
}
