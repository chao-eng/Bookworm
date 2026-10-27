import Foundation
import SwiftUI

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
        self.theme = EbookTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .dark
    }
}
