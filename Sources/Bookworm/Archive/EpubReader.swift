import Foundation
import AppKit

/// Reads EPUB books. EPUB is a zip archive of XHTML/CSS/images with an OPF
/// manifest that defines the reading order (spine). We extract the whole
/// archive to a temp workspace so WKWebView can resolve relative URLs.
/// 解压后的 EPUB 目录（含 META-INF/container.xml）也直接支持。
final class EpubReader: ContentReader {
    private let url: URL
    private let workspace: URL
    /// 解压后的 EPUB 目录直接作为 workspace，关闭时不能删除用户的书。
    private let ownsWorkspace: Bool
    private let rootDir: URL
    private let spineHRefs: [URL]
    private let spineTitles: [String?]
    private let tocEntries: [ReaderTOCItem]
    private let coverURL: URL?

    init(url: URL) throws {
        self.url = url

        // 有些 EPUB 是解压后的目录（含 META-INF/container.xml）。
        // 直接以目录作为根，避免再对目录执行 tar 解压。
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            self.workspace = url
            self.ownsWorkspace = false
        } else {
            let workspace = BookSandbox.newWorkspace()
            self.workspace = workspace
            self.ownsWorkspace = true
            try TarArchiveReader.extractAll(archive: url, to: workspace)
        }

        let containerURL = workspace.appendingPathComponent("META-INF/container.xml")
        let opfRelative = try EpubReader.readOPFPath(containerURL: containerURL)
        let opfURL = workspace.appendingPathComponent(opfRelative)
        self.rootDir = opfURL.deletingLastPathComponent()

        let parsed = try EpubReader.parseOPF(opfURL: opfURL, rootDir: rootDir)
        guard !parsed.spineURLs.isEmpty else {
            if self.ownsWorkspace { BookSandbox.cleanup(workspace) }
            throw ArchiveError.noPages
        }
        self.spineHRefs = parsed.spineURLs
        self.spineTitles = parsed.spineTitles
        self.tocEntries = parsed.tocEntries
        self.coverURL = parsed.coverURL
    }

    func pageCount() throws -> Int { spineHRefs.count }

    func pageTitle(at index: Int) -> String? {
        guard index >= 0, index < spineTitles.count else { return nil }
        return spineTitles[index]
    }

    func tocItems() -> [ReaderTOCItem]? {
        tocEntries.isEmpty ? nil : tocEntries
    }

    func content(at index: Int) throws -> PageContent {
        guard index >= 0, index < spineHRefs.count else { throw ArchiveError.indexOutOfRange }
        return .htmlFile(spineHRefs[index], baseAccess: workspace)
    }

    func coverImage() throws -> NSImage? {
        if let cover = coverURL, let img = NSImage(contentsOf: cover) {
            return img
        }
        // Fallback: render the first chapter to a placeholder cover.
        return EpubReader.makePlaceholderCover(title: url.deletingPathExtension().lastPathComponent)
    }

    func close() {
        if ownsWorkspace { BookSandbox.cleanup(workspace) }
    }

    // MARK: - Parsing

    private static func readOPFPath(containerURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw ArchiveError.parseFailed("EPUB 缺少 META-INF/container.xml")
        }
        let data = try Data(contentsOf: containerURL)
        guard let doc = try? XMLDocument(data: data, options: []) else {
            throw ArchiveError.parseFailed("container.xml 格式无效")
        }
        // EPUB container.xml uses default namespace urn:oasis:names:tc:opendocument:xmlns:container.
        // XPath with default namespaces is awkward; we use local-name() to ignore the namespace.
        if let nodes = try? doc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"),
           let node = nodes.first,
           let value = node.stringValue, !value.isEmpty {
            return value
        }
        throw ArchiveError.parseFailed("EPUB 中没有 rootfile 路径。")
    }

    private struct OPFData {
        let spineURLs: [URL]
        let spineTitles: [String?]
        let tocEntries: [ReaderTOCItem]
        let coverURL: URL?
    }

    private static func parseOPF(opfURL: URL, rootDir: URL) throws -> OPFData {
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            throw ArchiveError.parseFailed("找不到 OPF 文件 \(opfURL.lastPathComponent)")
        }
        let data = try Data(contentsOf: opfURL)
        guard let doc = try? XMLDocument(data: data, options: []) else {
            throw ArchiveError.parseFailed("OPF XML 格式无效")
        }

        // Build manifest: id -> (href, mediaType, properties)
        struct ManifestItem { let href: String; let mediaType: String; let properties: String }
        var manifest: [String: ManifestItem] = [:]
        if let items = try? doc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            for case let el as XMLElement in items {
                guard let id = el.attribute(forName: "id")?.stringValue,
                      let href = el.attribute(forName: "href")?.stringValue else { continue }
                let media = el.attribute(forName: "media-type")?.stringValue ?? ""
                let props = el.attribute(forName: "properties")?.stringValue ?? ""
                manifest[id] = ManifestItem(href: href, mediaType: media, properties: props)
            }
        }

        // Spine: ordered list of idrefs. The spine's `toc` attribute names the
        // NCX manifest item (EPUB2).
        var spineIDs: [String] = []
        var ncxID: String?
        if let items = try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            for case let el as XMLElement in items {
                if let idref = el.attribute(forName: "idref")?.stringValue {
                    spineIDs.append(idref)
                }
            }
        }
        if let spineEl = (try? doc.nodes(forXPath: "//*[local-name()='spine']"))?.first as? XMLElement {
            ncxID = spineEl.attribute(forName: "toc")?.stringValue
        }

        // 目录：优先 EPUB3 nav.xhtml，其次 EPUB2 toc.ncx。
        // 之前的实现直接用 spine 文件名当章节标题（ch001、ch002…），
        // 与书内真实目录完全不同。
        let bookTitle = normalizedText(
            (((try? doc.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']")) ?? [])
                .first?.stringValue) ?? ""
        )
        var ncxHref: String?
        if let ncxID, let item = manifest[ncxID] {
            ncxHref = item.href
        } else {
            ncxHref = manifest.values
                .first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.href
        }

        var rawTOC: [RawTOCEntry] = []
        if let navHref = manifest.values
            .first(where: { $0.properties.split(separator: " ").contains("nav") })?.href {
            rawTOC = parseNavEntries(
                navURL: rootDir.appendingPathComponent(navHref).standardizedFileURL
            )
        }
        if rawTOC.isEmpty, let ncxHref {
            rawTOC = parseNCXEntries(
                ncxURL: rootDir.appendingPathComponent(ncxHref).standardizedFileURL
            )
        }

        // 章节标题取该文件在目录中第一条（最浅层）的标题。
        var tocTitles: [URL: String] = [:]
        for entry in rawTOC where tocTitles[entry.fileURL] == nil {
            tocTitles[entry.fileURL] = entry.title
        }
        // 封面页通常不在 nav/NCX 目录里，用 OPF guide 补一个“封面”。
        if let coverPage = coverPageURL(opfDoc: doc, rootDir: rootDir),
           tocTitles[coverPage] == nil {
            tocTitles[coverPage] = "封面"
        }

        var spineURLs: [URL] = []
        var spineTitles: [String?] = []
        var pageIndexByURL: [URL: Int] = [:]
        for id in spineIDs {
            guard let entry = manifest[id] else { continue }
            let target = rootDir.appendingPathComponent(entry.href).standardizedFileURL
            if FileManager.default.fileExists(atPath: target.path) {
                pageIndexByURL[target] = spineURLs.count
                spineURLs.append(target)
                let filename = (entry.href as NSString).lastPathComponent
                    .replacingOccurrences(of: ".xhtml", with: "")
                    .replacingOccurrences(of: ".html", with: "")
                let title = tocTitles[target]
                    ?? fallbackChapterTitle(for: target, bookTitle: bookTitle)
                    ?? (filename.isEmpty ? nil : filename)
                spineTitles.append(title)
            }
        }

        // 把目录条目的目标文件映射到 spine 页码，丢弃不在正文里的条目。
        let tocEntries = rawTOC.compactMap { entry -> ReaderTOCItem? in
            guard let index = pageIndexByURL[entry.fileURL] else { return nil }
            return ReaderTOCItem(title: entry.title,
                                 pageIndex: index,
                                 level: entry.level,
                                 anchor: entry.anchor)
        }

        // Cover discovery:
        // 1. EPUB3: manifest item with properties="cover-image"
        // 2. EPUB2: <meta name="cover" content="<manifest-id>"/>
        // 3. Manifest item with id="cover" and image media type
        var coverHref: String?
        for (_, item) in manifest where item.properties.contains("cover-image") {
            coverHref = item.href
            break
        }
        if coverHref == nil,
           let metas = try? doc.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='meta'][@name='cover']") {
            for case let el as XMLElement in metas {
                if let id = el.attribute(forName: "content")?.stringValue, let entry = manifest[id] {
                    coverHref = entry.href
                    break
                }
            }
        }
        if coverHref == nil, let entry = manifest["cover"], entry.mediaType.hasPrefix("image/") {
            coverHref = entry.href
        }

        let coverURL = coverHref.map { rootDir.appendingPathComponent($0).standardizedFileURL }
        return OPFData(spineURLs: spineURLs,
                       spineTitles: spineTitles,
                       tocEntries: tocEntries,
                       coverURL: coverURL)
    }

    /// OPF guide 里 `<reference type="cover">` 指向的封面页文件（不是封面图片）。
    private static func coverPageURL(opfDoc: XMLDocument, rootDir: URL) -> URL? {
        guard let node = (try? opfDoc.nodes(
            forXPath: "//*[local-name()='guide']/*[local-name()='reference'][@type='cover']"
        ))?.first as? XMLElement,
              let href = node.attribute(forName: "href")?.stringValue else { return nil }
        return resourceURL(from: href, baseDirectory: rootDir)
    }

    /// 目录解析的中间结果：文件 + 页内锚点 + 层级。
    private struct RawTOCEntry {
        let title: String
        let fileURL: URL
        let anchor: String?
        let level: Int
    }

    /// 解析 EPUB3 导航文档（nav.xhtml）里的 `<nav epub:type="toc">`。
    /// 层级 = 该 `<a>` 外层 `<ol>` 的嵌套深度（一级标题为 0）。
    private static func parseNavEntries(navURL: URL) -> [RawTOCEntry] {
        guard let data = try? Data(contentsOf: navURL),
              let doc = try? XMLDocument(data: data, options: []) else { return [] }
        let baseDir = navURL.deletingLastPathComponent()

        let navElements = ((try? doc.nodes(forXPath: "//*[local-name()='nav']")) ?? [])
            .compactMap { $0 as? XMLElement }
        let tocNav = navElements.first { el in
            let epubType = el.attribute(forName: "epub:type")?.stringValue ?? ""
            let type = el.attribute(forName: "type")?.stringValue ?? ""
            let role = el.attribute(forName: "role")?.stringValue ?? ""
            return epubType.lowercased().contains("toc")
                || type.lowercased() == "toc"
                || role.lowercased().contains("doc-toc")
        } ?? navElements.first
        guard let tocNav else { return [] }

        var entries: [RawTOCEntry] = []
        let anchors = (try? tocNav.nodes(forXPath: ".//*[local-name()='a']")) ?? []
        for case let anchor as XMLElement in anchors {
            guard let href = anchor.attribute(forName: "href")?.stringValue,
                  let target = splitReference(href,
                                              baseDirectory: baseDir,
                                              currentDocument: navURL) else { continue }
            let title = normalizedText(anchor.stringValue ?? "")
            guard !title.isEmpty else { continue }

            // 统计 `<a>` 到 tocNav 之间包了几层 `<ol>`。
            var depth = 0
            var node = anchor.parent
            while let current = node, current !== tocNav {
                if let el = current as? XMLElement,
                   (el.localName ?? el.name ?? "").lowercased() == "ol" {
                    depth += 1
                }
                node = current.parent
            }
            entries.append(RawTOCEntry(title: title,
                                       fileURL: target.url,
                                       anchor: target.anchor,
                                       level: max(0, depth - 1)))
        }
        return entries
    }

    /// 解析 EPUB2 的 toc.ncx（navMap/navPoint）。
    /// 层级 = 该 navPoint 外层 navPoint 的嵌套数量。
    private static func parseNCXEntries(ncxURL: URL) -> [RawTOCEntry] {
        guard let data = try? Data(contentsOf: ncxURL),
              let doc = try? XMLDocument(data: data, options: []) else { return [] }
        let baseDir = ncxURL.deletingLastPathComponent()

        var entries: [RawTOCEntry] = []
        let points = (try? doc.nodes(forXPath: "//*[local-name()='navPoint']")) ?? []
        for case let point as XMLElement in points {
            let label = (try? point.nodes(
                forXPath: "./*[local-name()='navLabel']/*[local-name()='text']"
            ))?.first?.stringValue ?? ""
            let src = (try? point.nodes(
                forXPath: "./*[local-name()='content']/@src"
            ))?.first?.stringValue ?? ""
            guard let target = splitReference(src, baseDirectory: baseDir,
                                              currentDocument: ncxURL) else { continue }
            let title = normalizedText(label)
            guard !title.isEmpty else { continue }

            var level = 0
            var node = point.parent
            while let current = node {
                if let el = current as? XMLElement,
                   (el.localName ?? el.name ?? "") == "navPoint" {
                    level += 1
                }
                node = current.parent
            }
            entries.append(RawTOCEntry(title: title,
                                       fileURL: target.url,
                                       anchor: target.anchor,
                                       level: level))
        }
        return entries
    }

    /// 把目录里的相对 href（可带 `#fragment`）解析成文件 URL 与锚点。
    /// 纯锚点（`#foo`）指向当前文档。
    private static func splitReference(_ href: String,
                                       baseDirectory: URL,
                                       currentDocument: URL) -> (url: URL, anchor: String?)? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? ""
        var anchor = parts.count > 1 ? String(parts[1]) : nil
        anchor = anchor?.removingPercentEncoding ?? anchor
        if anchor?.isEmpty == true { anchor = nil }

        if path.isEmpty {
            guard anchor != nil else { return nil }
            return (currentDocument, anchor)
        }
        return (baseDirectory.appendingPathComponent(path).standardizedFileURL, anchor)
    }

    /// 没有 nav/NCX 时，退而读章节文件里的第一个标题标签。
    /// 很多 EPUB 的 `<title>` 只是文件名（如 “ch001.xhtml”），因此优先
    /// 用 `<h1>~<h4>`，并排除文件名、书名这类无意义的 `<title>`。
    private static func fallbackChapterTitle(for url: URL, bookTitle: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) else { return nil }

        if let heading = firstMatch(in: html, pattern: "(?is)<h[1-4][^>]*>(.*?)</h[1-4]>") {
            let title = normalizedText(stripTags(heading))
            if !title.isEmpty { return title }
        }

        if let rawTitle = firstMatch(in: html, pattern: "(?is)<title[^>]*>(.*?)</title>") {
            let title = normalizedText(stripTags(rawTitle))
            let filename = url.lastPathComponent.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if !title.isEmpty,
               title.lowercased() != filename,
               title.lowercased() != stem,
               title != bookTitle {
                return title
            }
        }
        return nil
    }

    /// 把目录里的相对 href（可能带 `#fragment`）解析成绝对文件 URL。
    private static func resourceURL(from href: String, baseDirectory: URL) -> URL? {
        let path = href.split(separator: "#", maxSplits: 1,
                              omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !path.isEmpty else { return nil }
        return baseDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func makePlaceholderCover(title: String) -> NSImage? {
        let size = NSSize(width: 480, height: 720)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        let bg = NSColor(red: 0.08, green: 0.13, blue: 0.32, alpha: 1.0)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let truncated = title.count > 60 ? String(title.prefix(60)) + "…" : title
        let str = NSAttributedString(string: truncated, attributes: attrs)
        let bounds = str.boundingRect(with: NSSize(width: size.width - 60, height: size.height - 60), options: [.usesLineFragmentOrigin, .usesFontLeading])
        str.draw(with: NSRect(x: 30, y: (size.height - bounds.height) / 2, width: size.width - 60, height: bounds.height),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        return image
    }
}
