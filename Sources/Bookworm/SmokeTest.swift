import Foundation
import AppKit

/// Headless verification of every `ContentReader` against a folder of books.
/// Invoked from the synthesized `main` when `--smoke-test <folder>` is passed.
enum SmokeTest {
    static func run(folder: String) {
        let url = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            print("Couldn't enumerate \(url.path)")
            return
        }
        var any = false
        for case let fileURL as URL in enumerator {
            guard let format = ComicFormat.from(url: fileURL) else { continue }
            any = true
            print("--- \(fileURL.lastPathComponent) [\(format.displayName)] ---")
            do {
                let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                let item = ComicItem(url: fileURL, format: format, fileSize: size)
                let reader = try ArchiveFactory.makeReader(for: item)
                defer { reader.close() }
                let count = try reader.pageCount()
                print("  pages: \(count)")
                for i in 0..<min(count, 2) {
                    let content = try reader.content(at: i)
                    switch content {
                    case .image(let img):
                        print("  page \(i + 1): image \(Int(img.size.width))x\(Int(img.size.height))")
                    case .htmlFile(let u, _):
                        print("  page \(i + 1): htmlFile \(u.lastPathComponent)")
                    case .htmlString(let s, _):
                        let prefix = s.prefix(120).replacingOccurrences(of: "\n", with: " ")
                        print("  page \(i + 1): htmlString [\(s.count) chars] \(prefix)…")
                    }
                }
                if let cover = (try? reader.coverImage()) ?? nil {
                    print("  cover: \(Int(cover.size.width))x\(Int(cover.size.height))")
                } else {
                    print("  cover: (none)")
                }
            } catch {
                print("  ERROR: \(error.localizedDescription)")
            }
        }
        if !any { print("(no supported files found)") }
    }

}
