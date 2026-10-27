import Foundation
import AppKit

/// Native reader for MOBI / AZW / older AZW3 files.
///
/// Handles the classic MOBI 6 layout: PalmDB → record 0 (MOBI header + EXTH) →
/// PalmDOC-compressed text records → image records. KF8 (AZW3) files contain
/// an embedded EPUB-like book; this reader falls back to the MOBI 6 boundary
/// for AZW3 where present. Encrypted (DRM'd) books cannot be opened.
final class MobiReader: ContentReader {
    private let url: URL
    private let chapters: [String]
    private let titleString: String?
    private let coverData: Data?

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        let parsed = try MobiReader.parse(data: data, sourceTitle: url.deletingPathExtension().lastPathComponent)
        guard !parsed.chapters.isEmpty else { throw ArchiveError.noPages }
        self.chapters = parsed.chapters
        self.titleString = parsed.title
        self.coverData = parsed.coverData
    }

    func pageCount() throws -> Int { chapters.count }

    func pageTitle(at index: Int) -> String? {
        if index == 0, let t = titleString { return t }
        return "Chapter \(index + 1)"
    }

    func content(at index: Int) throws -> PageContent {
        guard index >= 0, index < chapters.count else { throw ArchiveError.indexOutOfRange }
        let body = chapters[index]
        let styled = EbookStyle.wrap(body: body, title: titleString)
        return .htmlString(styled, baseURL: nil)
    }

    func coverImage() throws -> NSImage? {
        if let data = coverData, let img = NSImage(data: data) { return img }
        return EbookStyle.placeholderCover(title: titleString ?? url.deletingPathExtension().lastPathComponent)
    }

    func close() {}

    // MARK: - Parsing

    private struct Parsed {
        let chapters: [String]
        let title: String?
        let coverData: Data?
    }

    private static func parse(data: Data, sourceTitle: String) throws -> Parsed {
        guard data.count >= 78 else {
            throw ArchiveError.parseFailed("文件太小，不是有效的 MOBI 书籍")
        }
        // PalmDB header
        let nameBytes = data[0..<32]
        let palmName = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? sourceTitle

        let numRecords = Int(readUInt16(data, offset: 76))
        guard numRecords > 0 else {
            throw ArchiveError.parseFailed("MOBI 文件中没有记录")
        }
        let recordListStart = 78
        guard data.count >= recordListStart + numRecords * 8 else {
            throw ArchiveError.parseFailed("MOBI 记录列表被截断")
        }

        var recordOffsets: [Int] = []
        for i in 0..<numRecords {
            let offsetField = recordListStart + i * 8
            let off = Int(readUInt32(data, offset: offsetField))
            recordOffsets.append(off)
        }
        recordOffsets.append(data.count) // sentinel for last record size

        func recordRange(_ i: Int) -> Range<Int>? {
            guard i >= 0, i < numRecords else { return nil }
            let start = recordOffsets[i]
            let end = recordOffsets[i + 1]
            if start >= 0, end > start, end <= data.count { return start..<end }
            return nil
        }

        // Record 0 holds the PalmDOC header + MOBI header + EXTH.
        guard let r0 = recordRange(0) else {
            throw ArchiveError.parseFailed("缺少 MOBI 头部记录")
        }
        let headerRec = data.subdata(in: r0)
        guard headerRec.count >= 16 else { throw ArchiveError.parseFailed("MOBI 记录 0 数据过短") }

        let compression = Int(readUInt16(headerRec, offset: 0))
        let textLength = Int(readUInt32(headerRec, offset: 4))
        let recordCount = Int(readUInt16(headerRec, offset: 8))
        // recordSize at offset 10, encryption at 12, unused at 14.
        let encryption = Int(readUInt16(headerRec, offset: 12))
        if encryption != 0 {
            throw ArchiveError.parseFailed("这本 MOBI 书籍带有 DRM 保护，无法打开。")
        }

        // Look for MOBI header identifier at offset 16.
        var encoding: String.Encoding = .utf8
        var fullTitle: String?
        var coverOffset: Int?
        var thumbOffset: Int?
        var firstImageRecord: Int = 0

        if headerRec.count >= 24 {
            let ident = headerRec.subdata(in: 16..<20)
            if ident == Data([0x4D, 0x4F, 0x42, 0x49]) { // "MOBI"
                let mobiHeaderLength = Int(readUInt32(headerRec, offset: 20))
                let mobiEnd = 16 + mobiHeaderLength
                if mobiHeaderLength >= 24, headerRec.count >= mobiEnd {
                    let codepage = readUInt32(headerRec, offset: 16 + 28)
                    switch codepage {
                    case 1252: encoding = .windowsCP1252
                    case 65001: encoding = .utf8
                    default: encoding = .utf8
                    }
                    if headerRec.count >= 16 + 84 + 4 {
                        firstImageRecord = Int(readUInt32(headerRec, offset: 16 + 108))
                    }
                    // Full title
                    if headerRec.count >= 16 + 92 {
                        let titleOff = Int(readUInt32(headerRec, offset: 16 + 84))
                        let titleLen = Int(readUInt32(headerRec, offset: 16 + 88))
                        if titleOff > 0, titleLen > 0, titleOff + titleLen <= headerRec.count {
                            fullTitle = String(data: headerRec.subdata(in: titleOff..<(titleOff + titleLen)), encoding: encoding)
                        }
                    }
                    // EXTH header begins right after the MOBI header (if flag bit set).
                    let exthFlag = readUInt32(headerRec, offset: 16 + 112)
                    if (exthFlag & 0x40) != 0, headerRec.count >= mobiEnd + 12 {
                        let exth = headerRec.subdata(in: mobiEnd..<headerRec.count)
                        if exth.count >= 12, exth.subdata(in: 0..<4) == Data([0x45, 0x58, 0x54, 0x48]) {
                            let recordsInExth = Int(readUInt32(exth, offset: 8))
                            var p = 12
                            for _ in 0..<recordsInExth {
                                if p + 8 > exth.count { break }
                                let type = readUInt32(exth, offset: p)
                                let len = Int(readUInt32(exth, offset: p + 4))
                                if len < 8 || p + len > exth.count { break }
                                let payload = exth.subdata(in: (p + 8)..<(p + len))
                                switch type {
                                case 201: // cover offset (image record index relative to first image record)
                                    if payload.count >= 4 {
                                        coverOffset = Int(readUInt32(payload, offset: 0))
                                    }
                                case 202: // thumbnail offset
                                    if payload.count >= 4 {
                                        thumbOffset = Int(readUInt32(payload, offset: 0))
                                    }
                                default:
                                    break
                                }
                                p += len
                            }
                        }
                    }
                }
            }
        }

        // Concatenate text records 1..recordCount.
        var rawText = Data()
        rawText.reserveCapacity(textLength)
        for i in 1...max(1, recordCount) {
            guard let range = recordRange(i) else { break }
            var record = data.subdata(in: range)
            // Strip trailing flags. Last byte's low 3 bits indicate number of
            // trailing-entry bytes; if multibyte flag is set we also strip those.
            if let trimmed = MobiReader.stripTrailingEntries(record: record) {
                record = trimmed
            }
            switch compression {
            case 1:
                rawText.append(record)
            case 2, 4098:
                rawText.append(PalmDocCompression.decompress(record))
            default:
                throw ArchiveError.parseFailed("这本 MOBI 使用了不支持的压缩方式。")
            }
            if rawText.count >= textLength { break }
        }

        if rawText.count > textLength {
            rawText = rawText.prefix(textLength)
        }

        let fullHTML = String(data: rawText, encoding: encoding) ?? String(decoding: rawText, as: UTF8.self)

        // Strip null bytes that occasionally appear.
        let cleaned = fullHTML.replacingOccurrences(of: "\u{0000}", with: "")
        let chapters = MobiReader.splitChapters(html: cleaned)

        // Cover record (binary image).
        var coverData: Data?
        let chosenImageOffset = coverOffset ?? thumbOffset
        if let off = chosenImageOffset, firstImageRecord > 0 {
            let imageRecordIndex = firstImageRecord + off
            if let range = recordRange(imageRecordIndex) {
                let candidate = data.subdata(in: range)
                if MobiReader.looksLikeImage(candidate) {
                    coverData = candidate
                }
            }
        }
        if coverData == nil, firstImageRecord > 0 {
            // Fallback: first image record.
            if let range = recordRange(firstImageRecord) {
                let candidate = data.subdata(in: range)
                if MobiReader.looksLikeImage(candidate) {
                    coverData = candidate
                }
            }
        }

        let title = fullTitle ?? palmName

        return Parsed(chapters: chapters, title: title.isEmpty ? sourceTitle : title, coverData: coverData)
    }

    private static func splitChapters(html: String) -> [String] {
        // MOBI HTML uses <mbp:pagebreak/> or <p height="N"></p>; we split on
        // mbp:pagebreak and obvious chapter <h1>/<h2> markers, but fall back to
        // chunking by ~30k chars to keep WebViews responsive.
        let pagebreak = html.replacingOccurrences(of: "<mbp:pagebreak/>", with: "\n\u{0001}\n",
                                                  options: .caseInsensitive)
            .replacingOccurrences(of: "<mbp:pagebreak />", with: "\n\u{0001}\n",
                                  options: .caseInsensitive)
            .replacingOccurrences(of: "<mbp:pagebreak></mbp:pagebreak>", with: "\n\u{0001}\n",
                                  options: .caseInsensitive)
        var chunks = pagebreak.components(separatedBy: "\u{0001}")
        chunks = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        if chunks.isEmpty {
            chunks = [html]
        }

        // Subdivide any really large chunk by paragraph boundaries to keep
        // each WebKit page snappy.
        let softLimit = 60_000
        var output: [String] = []
        for chunk in chunks {
            if chunk.count <= softLimit {
                output.append(chunk)
                continue
            }
            // Split at paragraph boundaries roughly every softLimit chars.
            var current = ""
            for paragraph in chunk.components(separatedBy: "</p>") {
                let withClose = paragraph + "</p>"
                if current.count + withClose.count > softLimit, !current.isEmpty {
                    output.append(current)
                    current = ""
                }
                current += withClose
            }
            if !current.isEmpty { output.append(current) }
        }
        return output
    }

    /// Strips MOBI multibyte / trailing-entry bytes from a text record.
    private static func stripTrailingEntries(record: Data) -> Data? {
        guard !record.isEmpty else { return record }
        var data = record
        // Heuristic: low 3 bits of last byte indicate number of trailing entries.
        let last = Int(data[data.endIndex - 1])
        let trailingEntries = last & 0b111
        // We don't have the trailing-flags field handy without the MOBI header;
        // applying just one entry chop tends to suffice. Skip if record is short.
        if trailingEntries > 0 && data.count > 4 {
            // Each trailing entry: read backwards, variable-length integer (continuation bit).
            for _ in 0..<trailingEntries {
                var i = data.endIndex - 1
                while i > data.startIndex {
                    let b = data[i]
                    if (b & 0x80) != 0 {
                        data = data.subdata(in: data.startIndex..<i)
                        break
                    }
                    i -= 1
                }
            }
        }
        return data
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // JPEG
        if data[0] == 0xFF, data[1] == 0xD8 { return true }
        // PNG
        if data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return true }
        // GIF
        if data[0] == 0x47, data[1] == 0x49, data[2] == 0x46 { return true }
        return false
    }

    // MARK: - Binary helpers

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let hi = UInt16(data[data.startIndex + offset])
        let lo = UInt16(data[data.startIndex + offset + 1])
        return (hi << 8) | lo
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

/// PalmDOC / LZ77-style decompression as used by classic MOBI text records.
enum PalmDocCompression {
    static func decompress(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(input.count * 2)
        var i = input.startIndex
        let end = input.endIndex
        while i < end {
            let byte = input[i]
            if byte == 0x00 || (byte >= 0x09 && byte <= 0x7F) {
                output.append(byte)
                i += 1
            } else if byte <= 0x08 {
                // Literal: next `byte` bytes are output as-is.
                let count = Int(byte)
                i += 1
                let take = min(count, end - i)
                if take > 0 {
                    output.append(input.subdata(in: i..<(i + take)))
                    i += take
                }
            } else if byte >= 0x80 && byte <= 0xBF {
                // Pair: 16-bit big-endian. Bits 14-11 are distance high, 10-3 dist low,
                // bits 2-0 are length-3.
                if i + 1 >= end { break }
                let hi = UInt16(byte)
                let lo = UInt16(input[i + 1])
                let pair = (hi << 8) | lo
                // Mask top 2 bits (mode indicator '10').
                let masked = pair & 0x3FFF
                let distance = Int(masked >> 3)
                let length = Int(masked & 0b111) + 3
                if distance == 0 || distance > output.count {
                    // Malformed; bail out.
                    i += 2
                    continue
                }
                let start = output.endIndex - distance
                for k in 0..<length {
                    let idx = start + k
                    if idx >= output.endIndex {
                        // wrap (overlap) — re-read from output's current end-distance.
                        let wrapStart = output.endIndex - distance
                        output.append(output[wrapStart + (k % distance)])
                    } else {
                        output.append(output[idx])
                    }
                }
                i += 2
            } else { // 0xC0...0xFF
                // Space + (byte XOR 0x80).
                output.append(0x20)
                output.append(byte ^ 0x80)
                i += 1
            }
        }
        return output
    }
}

extension String.Encoding {
    static let windowsCP1252: String.Encoding = {
        // CFStringEncoding 0x0500 == kCFStringEncodingWindowsLatin1
        let cf = CFStringEncoding(0x0500)
        let raw = CFStringConvertEncodingToNSStringEncoding(cf)
        return String.Encoding(rawValue: raw)
    }()
}
