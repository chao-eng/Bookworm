import Foundation
import AppKit

/// Reads EPUB books. EPUB is a zip archive of XHTML/CSS/images with an OPF
/// manifest that defines the reading order (spine). We extract the whole
/// archive to a temp workspace so WKWebView can resolve relative URLs.
final class EpubReader: ContentReader {
    private let url: URL
    private let workspace: URL
    private let rootDir: URL
    private let spineHRefs: [URL]
    private let spineTitles: [String?]
    private let coverURL: URL?

    init(url: URL) throws {
        self.url = url
        self.workspace = BookSandbox.newWorkspace()

        try TarArchiveReader.extractAll(archive: url, to: workspace)

        let containerURL = workspace.appendingPathComponent("META-INF/container.xml")
        let opfRelative = try EpubReader.readOPFPath(containerURL: containerURL)
        let opfURL = workspace.appendingPathComponent(opfRelative)
        self.rootDir = opfURL.deletingLastPathComponent()

        let parsed = try EpubReader.parseOPF(opfURL: opfURL, rootDir: rootDir)
        guard !parsed.spineURLs.isEmpty else {
            BookSandbox.cleanup(workspace)
            throw ArchiveError.noPages
        }
        self.spineHRefs = parsed.spineURLs
        self.spineTitles = parsed.spineTitles
        self.coverURL = parsed.coverURL
    }

    func pageCount() throws -> Int { spineHRefs.count }

    func pageTitle(at index: Int) -> String? {
        guard index >= 0, index < spineTitles.count else { return nil }
        return spineTitles[index]
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
        BookSandbox.cleanup(workspace)
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

        // Spine: ordered list of idrefs.
        var spineIDs: [String] = []
        if let items = try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            for case let el as XMLElement in items {
                if let idref = el.attribute(forName: "idref")?.stringValue {
                    spineIDs.append(idref)
                }
            }
        }

        var spineURLs: [URL] = []
        var spineTitles: [String?] = []
        for id in spineIDs {
            guard let entry = manifest[id] else { continue }
            let target = rootDir.appendingPathComponent(entry.href).standardizedFileURL
            if FileManager.default.fileExists(atPath: target.path) {
                spineURLs.append(target)
                let title = (entry.href as NSString).lastPathComponent
                    .replacingOccurrences(of: ".xhtml", with: "")
                    .replacingOccurrences(of: ".html", with: "")
                spineTitles.append(title.isEmpty ? nil : title)
            }
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
        return OPFData(spineURLs: spineURLs, spineTitles: spineTitles, coverURL: coverURL)
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
