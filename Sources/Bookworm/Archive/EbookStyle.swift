import Foundation
import AppKit

/// Shared HTML styling for text-based ebook formats (MOBI, TXT, FB2).
enum EbookStyle {
    static func wrap(body: String, title: String? = nil) -> String {
        let safeTitle = title?.replacingOccurrences(of: "<", with: "&lt;") ?? "Bookworm"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(safeTitle)</title>
        <style>
        :root { color-scheme: dark light; }
        html, body { background: transparent; }
        body {
            font-family: -apple-system, "New York", "Iowan Old Style", Georgia, serif;
            font-size: 1.15rem;
            line-height: 1.6;
            margin: 0 auto;
            padding: 48px max(24px, calc(50% - 360px));
            max-width: 100%;
            background: transparent;
            text-rendering: optimizeLegibility;
            -webkit-font-smoothing: antialiased;
            hyphens: auto;
        }
        /* Per-scheme text colors so a flash before our JS override still
           reads, and so accent elements pick up the right palette in both
           light and dark mode. */
        @media (prefers-color-scheme: dark) {
            body { color: #e6ecf2; }
            a { color: #6fa8ff; }
            blockquote { border-left: 3px solid rgba(255,255,255,0.25); color: rgba(230,236,242,0.85); }
            pre { background: rgba(0,0,0,0.35); }
            hr { background: rgba(255,255,255,0.15); }
        }
        @media (prefers-color-scheme: light) {
            body { color: #1c1c1f; }
            a { color: #1b66c9; }
            blockquote { border-left: 3px solid rgba(0,0,0,0.18); color: rgba(28,28,31,0.78); }
            pre { background: rgba(0,0,0,0.06); }
            hr { background: rgba(0,0,0,0.12); }
        }
        h1, h2, h3, h4 { font-family: -apple-system, "New York", Georgia, serif; line-height: 1.25; }
        h1 { font-size: 1.8rem; margin-top: 1.4em; }
        h2 { font-size: 1.4rem; margin-top: 1.2em; }
        h3 { font-size: 1.2rem; }
        p { margin: 0 0 0.95em; text-align: justify; }
        img { max-width: 100%; height: auto; display: block; margin: 1em auto; border-radius: 6px; }
        blockquote { padding-left: 1em; margin: 1em 0; }
        pre, code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.95em; }
        pre { padding: 1em; border-radius: 8px; overflow-x: auto; }
        hr { border: 0; height: 1px; margin: 2em 0; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    static func plainTextToHTML(_ text: String) -> String {
        // Escape and convert paragraphs (double newline) and line breaks.
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = escaped.components(separatedBy: "\n\n")
        return paragraphs
            .map { p in
                let withBreaks = p.replacingOccurrences(of: "\n", with: "<br/>")
                return "<p>\(withBreaks)</p>"
            }
            .joined(separator: "\n")
    }

    static func placeholderCover(title: String) -> NSImage {
        let size = NSSize(width: 480, height: 720)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        let topColor = NSColor(red: 0.05, green: 0.10, blue: 0.26, alpha: 1).cgColor
        let botColor = NSColor(red: 0.02, green: 0.04, blue: 0.12, alpha: 1).cgColor
        let cs = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: cs, colors: [topColor, botColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])

        // Title
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        let truncated = title.count > 80 ? String(title.prefix(80)) + "…" : title
        let attributed = NSAttributedString(string: truncated, attributes: attrs)
        let rect = NSRect(x: 30, y: 60, width: size.width - 60, height: size.height - 120)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Subtle "book" marker
        let sub: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            .paragraphStyle: style
        ]
        let label = NSAttributedString(string: "Bookworm", attributes: sub)
        label.draw(with: NSRect(x: 0, y: 30, width: size.width, height: 24), options: [.usesLineFragmentOrigin])

        image.unlockFocus()
        return image
    }
}
