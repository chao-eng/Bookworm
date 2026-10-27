import Foundation
import AppKit

/// Reads images out of zip/cbz/rar/cbr/7z archives by shelling out to
/// /usr/bin/tar (bsdtar, libarchive-backed). Works for any archive
/// libarchive can read.
final class TarArchiveReader: ContentReader {
    private let url: URL
    private let entries: [String]
    private let lock = NSLock()
    private var memoryCache: [Int: Data] = [:]
    private let cacheLimit = 8

    init(url: URL) throws {
        self.url = url
        let raw = try TarArchiveReader.listEntries(at: url)
        let images = raw.filter { ImageEntryFilter.isImagePath($0) }
        let sorted = ImageEntryFilter.naturalSort(images)
        guard !sorted.isEmpty else {
            throw ArchiveError.noPages
        }
        self.entries = sorted
    }

    func pageCount() throws -> Int { entries.count }

    func pageTitle(at index: Int) -> String? {
        guard index >= 0, index < entries.count else { return nil }
        return (entries[index] as NSString).lastPathComponent
    }

    func content(at index: Int) throws -> PageContent {
        let img = try image(at: index)
        return .image(img)
    }

    func data(at index: Int) throws -> Data {
        guard index >= 0, index < entries.count else { throw ArchiveError.indexOutOfRange }

        lock.lock()
        if let cached = memoryCache[index] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let entryPath = entries[index]
        let data = try TarArchiveReader.extractData(archive: url, entry: entryPath)

        lock.lock()
        if memoryCache.count >= cacheLimit {
            if let firstKey = memoryCache.keys.first {
                memoryCache.removeValue(forKey: firstKey)
            }
        }
        memoryCache[index] = data
        lock.unlock()

        return data
    }

    func image(at index: Int) throws -> NSImage {
        let d = try data(at: index)
        guard let img = ImageDecoder.image(from: d) else {
            throw ArchiveError.decodeFailed
        }
        return img
    }

    func close() {
        lock.lock()
        memoryCache.removeAll()
        lock.unlock()
    }

    // MARK: - bsdtar helpers

    static let tarPath = "/usr/bin/tar"

    static func extractAll(archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tarPath)
        proc.arguments = ["-xf", archive.path, "-C", directory.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run() } catch {
            throw ArchiveError.toolFailed("无法启动 tar：\(error.localizedDescription)")
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "tar exited with status \(proc.terminationStatus)"
            throw ArchiveError.toolFailed("无法解压压缩包：\(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func listEntries(at url: URL) throws -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tarPath)
        proc.arguments = ["-tf", url.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            throw ArchiveError.toolFailed("无法启动 tar：\(error.localizedDescription)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errMsg = String(data: errData, encoding: .utf8) ?? "tar exited with status \(proc.terminationStatus)"
            throw ArchiveError.toolFailed("无法读取压缩包：\(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        guard let text = String(data: outData, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
    }

    private static func extractData(archive: URL, entry: String) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tarPath)
        // -O: write to stdout; provide entry as exact pattern.
        proc.arguments = ["-xOf", archive.path, entry]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            throw ArchiveError.toolFailed("无法启动 tar：\(error.localizedDescription)")
        }

        // Read potentially large data fully.
        let outHandle = outPipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = outHandle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errMsg = String(data: errData, encoding: .utf8) ?? "tar exited with status \(proc.terminationStatus)"
            throw ArchiveError.toolFailed("无法提取页面：\(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if buffer.isEmpty {
            throw ArchiveError.toolFailed("条目数据为空：\(entry)")
        }
        return buffer
    }
}
