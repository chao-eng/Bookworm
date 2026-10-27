import Foundation
import AppKit
import PDFKit

final class PDFArchiveReader: ContentReader {
    private let document: PDFDocument

    init(url: URL) throws {
        guard let doc = PDFDocument(url: url) else {
            throw ArchiveError.toolFailed("无法打开 PDF：\(url.lastPathComponent)")
        }
        self.document = doc
    }

    func pageCount() throws -> Int {
        document.pageCount
    }

    func pageTitle(at index: Int) -> String? {
        "Page \(index + 1)"
    }

    func content(at index: Int) throws -> PageContent {
        let img = try renderImage(at: index)
        return .image(img)
    }

    func coverImage() throws -> NSImage? {
        try renderImage(at: 0)
    }

    private func renderImage(at index: Int) throws -> NSImage {
        guard index >= 0, index < document.pageCount else {
            throw ArchiveError.indexOutOfRange
        }
        guard let page = document.page(at: index) else {
            throw ArchiveError.decodeFailed
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        return image
    }

    func close() {}
}
