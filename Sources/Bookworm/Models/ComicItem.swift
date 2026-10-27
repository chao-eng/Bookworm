import Foundation

enum ComicFormat: String, Codable, CaseIterable {
    case cbz
    case cbr
    case zip
    case rar
    case sevenZip
    case pdf
    case epub
    case mobi
    case azw
    case azw3
    case fb2
    case txt
    case html

    static func from(url: URL) -> ComicFormat? {
        switch url.pathExtension.lowercased() {
        case "cbz": return .cbz
        case "cbr": return .cbr
        case "zip": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        case "pdf": return .pdf
        case "epub": return .epub
        case "mobi", "prc": return .mobi
        case "azw": return .azw
        case "azw3", "kf8": return .azw3
        case "fb2": return .fb2
        case "txt": return .txt
        case "html", "htm", "xhtml": return .html
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .cbz: return "CBZ"
        case .cbr: return "CBR"
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7Z"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .mobi: return "MOBI"
        case .azw: return "AZW"
        case .azw3: return "AZW3"
        case .fb2: return "FB2"
        case .txt: return "TXT"
        case .html: return "HTML"
        }
    }

    var isEbook: Bool {
        switch self {
        case .epub, .mobi, .azw, .azw3, .fb2, .txt, .html: return true
        default: return false
        }
    }

    var isImageBased: Bool { !isEbook }
}

struct ComicItem: Identifiable, Codable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var format: ComicFormat
    var fileSize: Int64
    var dateAdded: Date
    var lastOpened: Date?
    var lastReadPage: Int
    var pageCount: Int?
    var thumbnailFileName: String?

    // Per-book reading preferences. Optional so old library.json files
    // without these keys still decode cleanly — Swift's synthesized Codable
    // uses decodeIfPresent for optional fields.
    var lastDirection: ReadingDirection?
    var lastZoomMode: ZoomMode?
    var lastTextZoom: Double?
    /// Whether the book was last read in two-page spread mode.
    var lastTwoPage: Bool?
    /// Translate-mode source / target language last used for this book,
    /// as `SupportedLanguage` raw values. Lets a Japanese manga and a
    /// Chinese manhua remember their own language pairs.
    var lastTranslateSource: String?
    var lastTranslateTarget: String?

    /// Pages the user explicitly bookmarked within this book (0-based
    /// page indices). Sorted ascending. Optional for backward-compatible
    /// decoding of pre-bookmark library.json files.
    var bookmarks: [Int]?

    /// True for files dragged onto the window from outside the library
    /// root folder. Library rescans rebuild the item list from the root
    /// folder tree, which would otherwise drop these — the flag tells
    /// the scanner to preserve them as long as the file still exists.
    var isExternal: Bool?

    init(url: URL, format: ComicFormat, fileSize: Int64) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.format = format
        self.fileSize = fileSize
        self.dateAdded = Date()
        self.lastOpened = nil
        self.lastReadPage = 0
        self.pageCount = nil
        self.thumbnailFileName = nil
        self.lastDirection = nil
        self.lastZoomMode = nil
        self.lastTextZoom = nil
        self.lastTwoPage = nil
        self.lastTranslateSource = nil
        self.lastTranslateTarget = nil
        self.bookmarks = nil
        self.isExternal = nil
    }

    // MARK: - Reading progress

    /// Fraction of the book read (0…1), or nil if the page count isn't
    /// known yet. Based on `lastReadPage + 1` so being on the last page
    /// reads as 100 %.
    var progressFraction: Double? {
        guard let total = pageCount, total > 0 else { return nil }
        return min(1.0, Double(lastReadPage + 1) / Double(total))
    }

    /// True once the reader has reached the final page.
    var isFinished: Bool {
        guard let total = pageCount, total > 0 else { return false }
        return lastReadPage + 1 >= total
    }

    /// True when the book has been opened and advanced past the first
    /// page but isn't finished — i.e. a candidate for "Continue Reading".
    var isInProgress: Bool {
        lastReadPage > 0 && !isFinished
    }
}
