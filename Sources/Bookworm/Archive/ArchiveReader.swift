import Foundation
import AppKit

/// A single renderable page. Can be a raster image (comics) or HTML (ebooks).
enum PageContent {
    case image(NSImage)
    case htmlFile(URL, baseAccess: URL)
    case htmlString(String, baseURL: URL?)
}

/// 阅读器解析出的目录条目，支持多级层级。
/// `pageIndex` 是条目指向的 spine 页；`level` 为缩进层级（0 = 一级标题）；
/// `anchor` 是页内锚点（可为 nil，表示跳到该页开头）。
struct ReaderTOCItem {
    let title: String
    let pageIndex: Int
    let level: Int
    let anchor: String?
}

protocol ContentReader: AnyObject {
    func pageCount() throws -> Int
    func pageTitle(at index: Int) -> String?
    func content(at index: Int) throws -> PageContent
    func coverImage() throws -> NSImage?
    /// 多级目录；为 nil 时由调用方退回按 `pageTitle(at:)` 生成扁平目录。
    func tocItems() -> [ReaderTOCItem]?
    func close()
}

extension ContentReader {
    func pageTitle(at index: Int) -> String? { nil }
    func tocItems() -> [ReaderTOCItem]? { nil }
    func coverImage() throws -> NSImage? {
        if let content = try? content(at: 0), case .image(let img) = content {
            return img
        }
        return nil
    }
}

enum ArchiveError: LocalizedError {
    case indexOutOfRange
    case noPages
    case decodeFailed
    case toolFailed(String)
    case unsupportedFormat
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .indexOutOfRange: return "页码超出范围。"
        case .noPages: return "此文件中没有可读取的页面。"
        case .decodeFailed: return "无法解码页面图像。"
        case .toolFailed(let m): return m
        case .unsupportedFormat: return "不支持的文件格式。"
        case .parseFailed(let m): return m
        }
    }
}

enum ArchiveFactory {
    static func makeReader(for item: ComicItem) throws -> ContentReader {
        switch item.format {
        case .pdf:
            return try PDFArchiveReader(url: item.url)
        case .cbz, .zip, .cbr, .rar, .sevenZip:
            return try TarArchiveReader(url: item.url)
        case .epub:
            return try EpubReader(url: item.url)
        case .mobi, .azw, .azw3:
            return try MobiReader(url: item.url)
        case .fb2:
            return try Fb2Reader(url: item.url)
        case .txt:
            return try TxtReader(url: item.url)
        case .html:
            return try HtmlReader(url: item.url)
        }
    }
}

struct ImageEntry {
    let path: String
    let originalIndex: Int
}

enum ImageEntryFilter {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif"
    ]

    static func isImagePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("__macosx/") { return false }
        if lower.hasSuffix("/") { return false }
        let name = (lower as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        guard let dot = lower.lastIndex(of: ".") else { return false }
        let ext = String(lower[lower.index(after: dot)...])
        return extensions.contains(ext)
    }

    static func naturalSort(_ entries: [String]) -> [String] {
        entries.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

/// Shared support directory for extracted ebook content. Each book gets its own
/// subdirectory; cleared when the reader closes.
enum BookSandbox {
    static var rootDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Bookworm/Books", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newWorkspace() -> URL {
        let dir = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
