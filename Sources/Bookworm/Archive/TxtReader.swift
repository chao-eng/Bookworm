import Foundation
import AppKit

final class TxtReader: ContentReader {
    private let chapters: [String]
    private let title: String

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let text: String
        if let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let s = String(data: data, encoding: .windowsCP1252) {
            text = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            text = s
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        self.title = url.deletingPathExtension().lastPathComponent
        let html = EbookStyle.plainTextToHTML(text)
        // Split big text into ~80k-char pages so WebKit doesn't choke.
        self.chapters = TxtReader.paginate(html: html, softLimit: 80_000)
    }

    private static func paginate(html: String, softLimit: Int) -> [String] {
        if html.count <= softLimit { return [html] }
        var output: [String] = []
        var current = ""
        for paragraph in html.components(separatedBy: "</p>") {
            let withClose = paragraph + "</p>"
            if current.count + withClose.count > softLimit, !current.isEmpty {
                output.append(current)
                current = ""
            }
            current += withClose
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    func pageCount() throws -> Int { chapters.count }

    func pageTitle(at index: Int) -> String? {
        if chapters.count == 1 { return title }
        return "第 \(index + 1) 部分"
    }

    func content(at index: Int) throws -> PageContent {
        guard index >= 0, index < chapters.count else { throw ArchiveError.indexOutOfRange }
        return .htmlString(EbookStyle.wrap(body: chapters[index], title: title), baseURL: nil)
    }

    func coverImage() throws -> NSImage? {
        EbookStyle.placeholderCover(title: title)
    }

    func close() {}
}

final class HtmlReader: ContentReader {
    private let url: URL
    private let title: String

    init(url: URL) throws {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }

    func pageCount() throws -> Int { 1 }
    func pageTitle(at index: Int) -> String? { title }

    func content(at index: Int) throws -> PageContent {
        guard index == 0 else { throw ArchiveError.indexOutOfRange }
        // Hand the file URL to WKWebView so it can resolve relative resources.
        return .htmlFile(url, baseAccess: url.deletingLastPathComponent())
    }

    func coverImage() throws -> NSImage? {
        EbookStyle.placeholderCover(title: title)
    }

    func close() {}
}

final class Fb2Reader: ContentReader {
    private let title: String
    private let html: String
    private let coverData: Data?

    init(url: URL) throws {
        self.title = url.deletingPathExtension().lastPathComponent
        let data = try Data(contentsOf: url)
        let (body, cover) = try Fb2Reader.parse(data: data)
        self.html = body
        self.coverData = cover
    }

    func pageCount() throws -> Int { 1 }

    func content(at index: Int) throws -> PageContent {
        guard index == 0 else { throw ArchiveError.indexOutOfRange }
        return .htmlString(EbookStyle.wrap(body: html, title: title), baseURL: nil)
    }

    func coverImage() throws -> NSImage? {
        if let data = coverData, let img = NSImage(data: data) { return img }
        return EbookStyle.placeholderCover(title: title)
    }

    func close() {}

    private static func parse(data: Data) throws -> (String, Data?) {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: []) }
        catch { throw ArchiveError.parseFailed("FB2 XML 格式无效") }

        // Collect inline binaries (id -> base64 data)
        var binaries: [String: String] = [:]
        if let nodes = try? doc.nodes(forXPath: "//*[local-name()='binary']") {
            for case let el as XMLElement in nodes {
                if let id = el.attribute(forName: "id")?.stringValue,
                   let s = el.stringValue {
                    binaries[id] = s.replacingOccurrences(of: "\n", with: "")
                                    .replacingOccurrences(of: "\r", with: "")
                                    .replacingOccurrences(of: " ", with: "")
                }
            }
        }

        // Build HTML from <body> sections
        var html = ""
        let sections = (try? doc.nodes(forXPath: "//*[local-name()='body']/*[local-name()='section']")) ?? []
        if sections.isEmpty {
            // Fall back to body's full text.
            if let body = (try? doc.nodes(forXPath: "//*[local-name()='body']"))?.first as? XMLElement {
                html += Fb2Reader.render(node: body, binaries: binaries)
            }
        } else {
            for case let sec as XMLElement in sections {
                html += Fb2Reader.render(node: sec, binaries: binaries)
                html += "<hr/>"
            }
        }

        // Cover: usually <description><title-info><coverpage><image l:href="#id"/>
        var coverData: Data?
        if let imageNodes = try? doc.nodes(forXPath: "//*[local-name()='coverpage']/*[local-name()='image']"),
           let first = imageNodes.first as? XMLElement,
           let href = first.attribute(forName: "href")?.stringValue
                   ?? first.attribute(forName: "l:href")?.stringValue {
            let id = href.hasPrefix("#") ? String(href.dropFirst()) : href
            if let base64 = binaries[id] {
                coverData = Data(base64Encoded: base64)
            }
        }

        return (html, coverData)
    }

    private static func render(node: XMLElement, binaries: [String: String]) -> String {
        var out = ""
        for child in node.children ?? [] {
            if let el = child as? XMLElement {
                let name = el.localName ?? el.name ?? ""
                switch name {
                case "title":
                    out += "<h2>\(renderChildren(of: el, binaries: binaries))</h2>"
                case "subtitle":
                    out += "<h3>\(renderChildren(of: el, binaries: binaries))</h3>"
                case "p":
                    out += "<p>\(renderChildren(of: el, binaries: binaries))</p>"
                case "empty-line":
                    out += "<br/>"
                case "section":
                    out += render(node: el, binaries: binaries)
                case "image":
                    let href = el.attribute(forName: "href")?.stringValue
                            ?? el.attribute(forName: "l:href")?.stringValue ?? ""
                    let id = href.hasPrefix("#") ? String(href.dropFirst()) : href
                    if let b64 = binaries[id] {
                        out += "<img src=\"data:image/jpeg;base64,\(b64)\" alt=\"\"/>"
                    }
                case "emphasis":
                    out += "<em>\(renderChildren(of: el, binaries: binaries))</em>"
                case "strong":
                    out += "<strong>\(renderChildren(of: el, binaries: binaries))</strong>"
                case "epigraph", "cite":
                    out += "<blockquote>\(renderChildren(of: el, binaries: binaries))</blockquote>"
                case "poem", "stanza":
                    out += "<div class=\"poem\">\(renderChildren(of: el, binaries: binaries))</div>"
                case "v":
                    out += "<div>\(renderChildren(of: el, binaries: binaries))</div>"
                default:
                    out += renderChildren(of: el, binaries: binaries)
                }
            } else if let text = child.stringValue {
                out += text
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
        }
        return out
    }

    private static func renderChildren(of element: XMLElement, binaries: [String: String]) -> String {
        return render(node: element, binaries: binaries)
    }
}
