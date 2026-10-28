import Foundation
import AppKit

struct TextPage {
    let range: NSRange
    let text: String
}

/// 把一章纯文本按固定宽度/字号切成读页。
///
/// 使用 TextKit 排版：同一份 `NSAttributedString` 依次挂多个
/// `NSTextContainer`，每个容器的字形范围即一页。分页结果只依赖
/// 宽度、高度、字号与行距；字符偏移是唯一进度真值，页码只是派生值。
enum TextPaginator {
    /// 段落属性只描述行距与换行方式。段间距固定为 0：正文本身已用空行分隔，
    /// 且在线正文由 NSTextView 按同一份属性渲染，多出来的段间距会让实测高度
    /// 小于分页高度、导致每页底部留白（BR-60）。
    static func attributes(fontSize: CGFloat,
                           lineSpacing: CGFloat,
                           fontWeight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        attributes(font: NSFont.systemFont(ofSize: fontSize, weight: fontWeight),
                   lineSpacing: lineSpacing)
    }

    static func attributes(font: NSFont,
                           lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .paragraphStyle: paragraph
        ]
    }

    static func paginate(text: String,
                         fontSize: CGFloat,
                         lineSpacing: CGFloat,
                         size: CGSize,
                         weight: NSFont.Weight = .regular,
                         font: NSFont? = nil) -> [TextPage] {
        let nsText = text as NSString
        guard nsText.length > 0, size.width > 10, size.height > 10 else {
            return [TextPage(range: NSRange(location: 0, length: nsText.length), text: text)]
        }

        let attributed = NSAttributedString(string: text,
                                            attributes: attributes(font: font ?? NSFont.systemFont(ofSize: fontSize,
                                                                                                   weight: weight),
                                                                   lineSpacing: lineSpacing))
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var pages: [TextPage] = []
        var glyphStart = 0
        let totalGlyphs = layoutManager.numberOfGlyphs
        var guardCount = 0

        while glyphStart < totalGlyphs && guardCount < 4000 {
            guardCount += 1
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0 else { break }
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                        actualGlyphRange: nil)
            let pageText = nsText.substring(with: charRange)
            pages.append(TextPage(range: charRange, text: pageText))
            glyphStart = glyphRange.upperBound
        }

        if pages.isEmpty {
            pages.append(TextPage(range: NSRange(location: 0, length: nsText.length), text: text))
        }
        return pages
    }

    /// 字符偏移所在页（页首偏移 ≤ offset 的最后一页）。
    static func pageIndex(for offset: Int, in pages: [TextPage]) -> Int {
        guard !pages.isEmpty else { return 0 }
        var result = 0
        for (idx, page) in pages.enumerated() {
            if page.range.location <= offset { result = idx } else { break }
        }
        return result
    }
}

// MARK: - HTML → 纯文本

/// 正文提取用的正则。模式是常量，预编译一次复用。
private enum HTMLTextRegex {
    static let script = try! NSRegularExpression(pattern: "(?s)<script.*?</script>")
    static let style = try! NSRegularExpression(pattern: "(?s)<style.*?</style>")
    static let lineBreak = try! NSRegularExpression(pattern: "<br\\s*/?>",
                                                    options: .caseInsensitive)
    static let tag = try! NSRegularExpression(pattern: "<[^>]+>")
    static let spaces = try! NSRegularExpression(pattern: "[ \\t]+")
    static let blankLines = try! NSRegularExpression(pattern: "\\n\\s*\\n\\s*\\n+")
}

enum TextExtraction {
    /// 轻量 HTML 转纯文本：去掉脚本、样式与标签，解码常用实体。
    /// 用于把 EPUB / TXT 的阅读内容交给悬浮窗展示。
    static func plainText(fromHTML html: String) -> String {
        var s = html
        s = HTMLTextRegex.script.replacingMatches(in: s, with: " ")
        s = HTMLTextRegex.style.replacingMatches(in: s, with: " ")
        s = HTMLTextRegex.lineBreak.replacingMatches(in: s, with: "\n")
        s = s.replacingOccurrences(of: "</p>", with: "\n\n")
        s = HTMLTextRegex.tag.replacingMatches(in: s, with: " ")
        let entities: [String: String] = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&#39;": "'", "&rsquo;": "'", "&lsquo;": "'", "&quot;": "\"",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&mdash;": "—"
        ]
        for (key, value) in entities {
            s = s.replacingOccurrences(of: key, with: value)
        }
        s = HTMLTextRegex.spaces.replacingMatches(in: s, with: " ")
        s = HTMLTextRegex.blankLines.replacingMatches(in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(from content: PageContent) -> String {
        switch content {
        case .htmlString(let html, _):
            return plainText(fromHTML: html)
        case .htmlFile(let url, _):
            let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return plainText(fromHTML: html)
        case .image:
            return ""
        }
    }
}

// MARK: - 预编译正则替换

extension NSRegularExpression {
    /// 等价于 `String.replacingOccurrences(of:with:options:.regularExpression)`：
    /// 正则只编译一次反复复用，`template` 仍按 ICU 规则展开 `$1` 等捕获组。
    func replacingMatches(in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return stringByReplacingMatches(in: text,
                                        options: [],
                                        range: range,
                                        withTemplate: template)
    }
}
