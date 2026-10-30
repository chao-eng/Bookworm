import Foundation
import SwiftUI
import AppKit

/// Reading typeface for text-based ebooks. Maps to a CSS `font-family`
/// stack of fonts that ship with macOS — no bundled font files.
enum EbookFont: String, CaseIterable, Identifiable, Codable {
    case serif
    case system
    case sans
    case rounded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serif:   return "衬线体"
        case .system:  return "系统字体"
        case .sans:    return "无衬线体"
        case .rounded: return "圆体"
        }
    }

    /// CSS `font-family` value. All faces here ship with macOS.
    var cssFamily: String {
        switch self {
        case .serif:
            return "\"New York\", \"Iowan Old Style\", Georgia, \"Times New Roman\", serif"
        case .system:
            return "-apple-system, system-ui, \"Helvetica Neue\", sans-serif"
        case .sans:
            return "\"Helvetica Neue\", Helvetica, Arial, sans-serif"
        case .rounded:
            return "ui-rounded, \"SF Pro Rounded\", -apple-system, sans-serif"
        }
    }

    /// TextKit 字体：与上面的 CSS 字体栈对应，供在线阅读器排版与绘制共用，
    /// 让本地/在线两种阅读窗口的字形保持一致。
    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .system:
            return base
        case .sans:
            return NSFont(name: "Helvetica Neue", size: size) ?? base
        case .serif:
            guard let descriptor = base.fontDescriptor.withDesign(.serif),
                  let font = NSFont(descriptor: descriptor, size: size) else { return base }
            return font
        case .rounded:
            guard let descriptor = base.fontDescriptor.withDesign(.rounded),
                  let font = NSFont(descriptor: descriptor, size: size) else { return base }
            return font
        }
    }

    /// 把「行高倍数」换算成 TextKit 的额外行距，口径与本地阅读器的 CSS
    /// `line-height` 一致（行高 = 字号 × 倍数），而不是在系统行高上再叠加。
    func extraLineSpacing(size: CGFloat, multiplier: Double) -> CGFloat {
        let font = nsFont(size: size)
        let natural = font.ascender - font.descender + font.leading
        return max(0, size * CGFloat(multiplier) - natural)
    }
}

/// A reading colour scheme for text-based ebooks. Goes beyond the plain
/// dark/light toggle that image readers use — sepia and pure-black are
/// the two most-requested additions for long-form reading.
enum EbookTheme: String, CaseIterable, Identifiable, Codable {
    case light
    case sepia
    case dark
    case black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .sepia: return "米黄"
        case .dark:  return "深色"
        case .black: return "纯黑"
        }
    }

    var symbolName: String {
        switch self {
        case .light: return "sun.max"
        case .sepia: return "book.closed"
        case .dark:  return "moon"
        case .black: return "moon.stars.fill"
        }
    }

    /// True for schemes that want light text — used where a simple bool
    /// is still convenient (e.g. tinting a spinner).
    var isDark: Bool { self == .dark || self == .black }

    /// SwiftUI colour painted behind the web view so the window matches
    /// the page even before the WebKit content lays out.
    var windowBackground: Color {
        switch self {
        case .light: return Color(red: 0.97, green: 0.95, blue: 0.91)
        case .sepia: return Color(red: 0.93, green: 0.88, blue: 0.78)
        case .dark:  return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .black: return .black
        }
    }

    /// CSS hex for the page background.
    var cssBackground: String {
        switch self {
        case .light: return "#f7f3e9"
        case .sepia: return "#ede0c8"
        case .dark:  return "#1e1e22"
        case .black: return "#000000"
        }
    }

    /// CSS hex for body text.
    var cssText: String {
        switch self {
        case .light: return "#1c1c1f"
        case .sepia: return "#3a2f1e"
        case .dark:  return "#e6ecf2"
        case .black: return "#d6d6d8"
        }
    }

    /// CSS hex for links.
    var cssLink: String {
        switch self {
        case .light: return "#1b66c9"
        case .sepia: return "#9a5b16"
        case .dark:  return "#6fa8ff"
        case .black: return "#6fa8ff"
        }
    }

    /// 正文颜色（与 `cssText` 同值），让在线阅读器与本地阅读器配色一致。
    var textColor: Color {
        switch self {
        case .light: return Color(red: 28 / 255, green: 28 / 255, blue: 31 / 255)
        case .sepia: return Color(red: 58 / 255, green: 47 / 255, blue: 30 / 255)
        case .dark:  return Color(red: 230 / 255, green: 236 / 255, blue: 242 / 255)
        case .black: return Color(red: 214 / 255, green: 214 / 255, blue: 216 / 255)
        }
    }

    /// TextKit 绘制用的正文颜色。
    var nsTextColor: NSColor {
        switch self {
        case .light: return NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1)
        case .sepia: return NSColor(srgbRed: 58 / 255, green: 47 / 255, blue: 30 / 255, alpha: 1)
        case .dark:  return NSColor(srgbRed: 230 / 255, green: 236 / 255, blue: 242 / 255, alpha: 1)
        case .black: return NSColor(srgbRed: 214 / 255, green: 214 / 255, blue: 216 / 255, alpha: 1)
        }
    }
}

/// Global typography + colour preferences for text-based ebooks. Stored
/// in UserDefaults so they apply across every reader window and persist
/// across launches — the same model `TranslationSettings` uses.
@MainActor
final class EbookSettings: ObservableObject {
    static let shared = EbookSettings()

    @Published var font: EbookFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: Keys.font) }
    }
    /// CSS `line-height` multiplier. 1.4–2.4, default 1.6.
    @Published var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: Keys.lineSpacing) }
    }
    @Published var theme: EbookTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    static let minLineSpacing: Double = 1.4
    static let maxLineSpacing: Double = 2.4

    private enum Keys {
        static let font        = "Bookworm.ebook.font"
        static let lineSpacing = "Bookworm.ebook.lineSpacing"
        static let theme       = "Bookworm.ebook.theme"
    }

    init() {
        let d = UserDefaults.standard
        self.font = EbookFont(rawValue: d.string(forKey: Keys.font) ?? "") ?? .serif
        let saved = d.double(forKey: Keys.lineSpacing)
        self.lineSpacing = saved >= EbookSettings.minLineSpacing
            && saved <= EbookSettings.maxLineSpacing ? saved : 1.6
        self.theme = EbookTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .light
    }
}
