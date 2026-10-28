import Foundation
import CryptoKit

/// V2 新增目录与原子写入工具。
///
/// 所有在线书、书源、悬浮窗数据都落在
/// `~/Library/Application Support/Bookworm/` 下，不引入数据库。
enum AppPaths {
    /// 进程内只解析一次。原先每次访问都跑 FileManager.url + createDirectory，
    /// 而 libraryFile / chapterCacheFile / sourcesFile 都经它派生，属高频路径。
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Bookworm", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // 子目录同样只创建一次，避免每个派生文件路径都触发一次系统调用。
    static let thumbnailsDirectory: URL = directory("Thumbnails")
    static let chaptersDirectory: URL = directory("Chapters")
    static let chapterCacheDirectory: URL = directory("ChapterCache")
    static let sourcesDirectory: URL = directory("Sources")
    static let floatingDirectory: URL = directory("Floating")
    static let logsDirectory: URL = directory("Logs")

    static let libraryFile: URL = supportDirectory.appendingPathComponent("library.json")
    static let libraryV1Backup: URL = supportDirectory.appendingPathComponent("library.v1.backup.json")
    static let sourcesFile: URL = sourcesDirectory.appendingPathComponent("sources.json")
    static let floatingStateFile: URL = floatingDirectory.appendingPathComponent("state.json")
    static let cacheIndexFile: URL = chapterCacheDirectory.appendingPathComponent("index.json")

    static func chapterIndexFile(bookID: String) -> URL {
        chaptersDirectory.appendingPathComponent("\(bookID).json")
    }

    static func chapterCacheFile(bookID: String, index: Int) -> URL {
        chapterCacheDirectory
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent("\(index).txt")
    }

    private static func directory(_ name: String) -> URL {
        let url = supportDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 原子写入：先写同目录临时文件，再 rename 覆盖，避免半截文件。
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    static func atomicWriteJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try atomicWrite(data, to: url)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    static func sha256Data(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
