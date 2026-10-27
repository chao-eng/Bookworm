import Foundation
import AppKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [ComicItem] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanProgress: String = ""
    @Published var rootFolder: URL? {
        didSet { persistRootFolder() }
    }

    private let supportDirectory: URL
    private let libraryFile: URL
    private let thumbnailsDirectory: URL
    private let defaultsKey = "Bookworm.rootFolderBookmark"

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)) ?? fm.temporaryDirectory
        let support = base.appendingPathComponent("Bookworm", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let thumbs = support.appendingPathComponent("Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        self.supportDirectory = support
        self.thumbnailsDirectory = thumbs
        self.libraryFile = support.appendingPathComponent("library.json")

        loadLibrary()
        restoreRootFolder()
    }

    func thumbnailURL(for item: ComicItem) -> URL? {
        guard let name = item.thumbnailFileName else { return nil }
        return thumbnailsDirectory.appendingPathComponent(name)
    }

    func thumbnailImage(for item: ComicItem) -> NSImage? {
        guard let url = thumbnailURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    func item(withID id: ComicItem.ID) -> ComicItem? {
        items.first(where: { $0.id == id })
    }

    /// Books that have been opened at least once, most-recent first.
    /// Drives the File ▸ Open Recent menu.
    var recentlyOpened: [ComicItem] {
        items
            .filter { $0.lastOpened != nil }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }

    /// Books opened and advanced past page 1 but not finished. Drives
    /// the "Continue Reading" shelf at the top of the library.
    var inProgress: [ComicItem] {
        recentlyOpened.filter { $0.isInProgress }
    }

    /// Add a file the user dragged onto the window. If it's already in
    /// the library (matched by path) the existing item's ID is returned
    /// so the caller can just open it. Otherwise a new `isExternal`
    /// item is created, persisted, and queued for thumbnail generation.
    /// Returns nil if the file's extension isn't a supported format.
    @discardableResult
    func addExternalFile(url: URL) -> ComicItem.ID? {
        if let existing = items.first(where: { $0.url.path == url.path }) {
            return existing.id
        }
        guard let format = ComicFormat.from(url: url) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var item = ComicItem(url: url, format: format, fileSize: size)
        item.isExternal = true
        items.append(item)
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        saveLibrary()
        // Generate the cover off the main actor; reuses the same
        // readability-gated path the folder scan uses, so an unreadable
        // drop gets dropped back out of the library cleanly.
        Task { await generateMissingThumbnails() }
        return item.id
    }

    /// Remember the translate-mode language pair for a book so it
    /// re-opens with the same source/target it was last read with.
    func updateTranslateLanguages(itemID: ComicItem.ID, source: String, target: String) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[idx].lastTranslateSource != source
                || items[idx].lastTranslateTarget != target else { return }
        items[idx].lastTranslateSource = source
        items[idx].lastTranslateTarget = target
        saveLibrary()
    }

    /// Clear the File ▸ Open Recent menu by wiping `lastOpened` on every
    /// item. Reading progress (`lastReadPage`) is intentionally left
    /// untouched — this only forgets *when* books were opened.
    func clearRecentlyOpened() {
        for idx in items.indices {
            items[idx].lastOpened = nil
        }
        saveLibrary()
    }

    /// Toggle a page index in a book's bookmark list. Returns the new
    /// bookmarked state for that page (true = now bookmarked).
    @discardableResult
    func toggleBookmark(itemID: ComicItem.ID, page: Int) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return false }
        var marks = items[idx].bookmarks ?? []
        if let at = marks.firstIndex(of: page) {
            marks.remove(at: at)
            items[idx].bookmarks = marks.isEmpty ? nil : marks
            saveLibrary()
            return false
        } else {
            marks.append(page)
            marks.sort()
            items[idx].bookmarks = marks
            saveLibrary()
            return true
        }
    }

    func updateProgress(itemID: ComicItem.ID,
                         page: Int,
                         pageCount: Int?,
                         direction: ReadingDirection? = nil,
                         zoomMode: ZoomMode? = nil,
                         textZoom: Double? = nil,
                         twoPage: Bool? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].lastReadPage = page
        items[idx].lastOpened = Date()
        if let pc = pageCount { items[idx].pageCount = pc }
        if let direction { items[idx].lastDirection = direction }
        if let zoomMode { items[idx].lastZoomMode = zoomMode }
        if let textZoom { items[idx].lastTextZoom = textZoom }
        if let twoPage { items[idx].lastTwoPage = twoPage }
        saveLibrary()
    }

    // MARK: - Folder selection

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择漫画文件夹"
        panel.message = "请选择存放漫画和日漫的文件夹，其中的子文件夹也会一并扫描。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            self.rootFolder = url
            rescan()
        }
    }

    func rescan() {
        guard let root = rootFolder else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.scanFolder(root)
        }
    }

    // MARK: - Scanning

    private func scanFolder(_ root: URL) async {
        await MainActor.run {
            self.isScanning = true
            self.scanProgress = "正在扫描…"
        }
        let foundURLs = enumerateComicFiles(root: root)
        let existingItems = await MainActor.run { self.items }
        var existingByPath: [String: ComicItem] = [:]
        for item in existingItems { existingByPath[item.url.path] = item }

        var nextItems: [ComicItem] = []
        for url in foundURLs {
            if let existing = existingByPath[url.path] {
                nextItems.append(existing)
            } else if let format = ComicFormat.from(url: url) {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let new = ComicItem(url: url, format: format, fileSize: size)
                nextItems.append(new)
            }
        }

        // Preserve drag-dropped external files — they live outside the
        // root folder tree so the enumeration above never finds them.
        // Keep them only while the underlying file still exists.
        let fm = FileManager.default
        for item in existingItems where item.isExternal == true {
            let alreadyIncluded = nextItems.contains { $0.id == item.id }
            if !alreadyIncluded, fm.fileExists(atPath: item.url.path) {
                nextItems.append(item)
            }
        }

        nextItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        await MainActor.run {
            self.items = nextItems
            self.scanProgress = "正在生成封面…"
            self.saveLibrary()
        }

        await generateMissingThumbnails()

        await MainActor.run {
            self.isScanning = false
            self.scanProgress = ""
        }
    }

    private func enumerateComicFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var out: [URL] = []
        for case let u as URL in enumerator {
            // Single source of truth: any file whose extension maps to a
            // ComicFormat is considered a library item — so adding ebook
            // formats in ComicFormat.from(url:) automatically extends the scan.
            if ComicFormat.from(url: u) != nil {
                out.append(u)
            }
        }
        return out
    }

    private enum ThumbnailResult {
        case ok                   // reader opened, cover saved
        case readableButNoCover   // reader opened, cover render failed — keep item, use placeholder
        case unreadable           // reader couldn't open the file at all — drop it from the library
    }

    private func generateMissingThumbnails() async {
        let snapshot = await MainActor.run { self.items }
        var idsToRemove: [ComicItem.ID] = []
        for (idx, item) in snapshot.enumerated() {
            // If the item already has a valid on-disk thumbnail, leave it
            // alone — we trust an earlier scan validated it.
            if item.thumbnailFileName != nil,
               let url = thumbnailURL(for: item),
               FileManager.default.fileExists(atPath: url.path) {
                continue
            }
            await MainActor.run {
                self.scanProgress = "正在生成封面 \(idx + 1) / \(snapshot.count)…"
            }
            let result = await generateThumbnail(for: item)
            if case .unreadable = result {
                idsToRemove.append(item.id)
            }
        }

        if !idsToRemove.isEmpty {
            await MainActor.run {
                let toRemove = Set(idsToRemove)
                self.items.removeAll { toRemove.contains($0.id) }
                self.saveLibrary()
            }
        }
    }

    private func generateThumbnail(for item: ComicItem) async -> ThumbnailResult {
        // Opening the archive / parsing the document is the canonical
        // readability check: every reader's init validates structure (PDF
        // password, archive signature, EPUB OPF, MOBI palmdb, etc.) and
        // throws on failure. If we can't even open it, the user has no
        // hope of reading it — drop it from the library.
        let reader: ContentReader
        do {
            reader = try ArchiveFactory.makeReader(for: item)
        } catch {
            return .unreadable
        }
        defer { reader.close() }

        guard let cover = (try? reader.coverImage()) ?? nil else {
            // Reader opened but cover failed — keep the item, since the
            // book is still readable. Library card falls back to the
            // generic placeholder.
            return .readableButNoCover
        }
        let thumb = cover.resized(maxDimension: 600)
        guard let data = thumb.jpegData(compressionQuality: 0.82) else {
            return .readableButNoCover
        }
        let filename = "\(item.id.uuidString).jpg"
        let url = thumbnailsDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            await MainActor.run {
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx].thumbnailFileName = filename
                    if self.items[idx].pageCount == nil {
                        self.items[idx].pageCount = (try? reader.pageCount()) ?? nil
                    }
                    self.saveLibrary()
                }
            }
            return .ok
        } catch {
            return .readableButNoCover
        }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var items: [ComicItem]
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        self.items = decoded.items
    }

    fileprivate func saveLibrary() {
        let p = Persisted(items: items)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: libraryFile, options: .atomic)
    }

    // MARK: - Backup export / import

    /// Encode the whole library — items, reading progress, bookmarks,
    /// per-book preferences — into a JSON blob the user can stash in
    /// iCloud Drive / Dropbox / a Time Machine folder themselves. This
    /// is the feasible stand-in for built-in cloud sync: real iCloud
    /// needs a container entitlement the ad-hoc-signed SwiftPM build
    /// can't carry.
    func exportBackupData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(Persisted(items: items))
    }

    /// Merge a previously-exported backup back into the current library.
    ///
    /// - Books already present (matched by file path) adopt the
    ///   backup's reading progress + per-book prefs when the backup's
    ///   `lastOpened` is newer; bookmarks are always unioned so neither
    ///   side loses a mark.
    /// - Books in the backup but not the library are added if their
    ///   file still exists on this Mac. Ones outside the library root
    ///   folder are flagged `isExternal` so a rescan doesn't drop them.
    ///
    /// Returns how many items were updated vs. newly added.
    @discardableResult
    func importBackup(data: Data) -> (updated: Int, added: Int) {
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return (0, 0)
        }
        var updated = 0
        var added = 0
        var indexByPath: [String: Int] = [:]
        for (i, item) in items.enumerated() { indexByPath[item.url.path] = i }
        let fm = FileManager.default
        let rootPath = rootFolder?.path

        for imported in decoded.items {
            if let idx = indexByPath[imported.url.path] {
                // Merge into the existing item.
                let union = Set(items[idx].bookmarks ?? [])
                    .union(imported.bookmarks ?? [])
                let mergedBookmarks = union.isEmpty ? nil : union.sorted()
                let bookmarksChanged = mergedBookmarks != items[idx].bookmarks
                items[idx].bookmarks = mergedBookmarks

                let localOpened = items[idx].lastOpened ?? .distantPast
                let importedOpened = imported.lastOpened ?? .distantPast
                if importedOpened > localOpened {
                    items[idx].lastReadPage = imported.lastReadPage
                    items[idx].lastOpened = imported.lastOpened
                    items[idx].lastDirection = imported.lastDirection ?? items[idx].lastDirection
                    items[idx].lastZoomMode = imported.lastZoomMode ?? items[idx].lastZoomMode
                    items[idx].lastTextZoom = imported.lastTextZoom ?? items[idx].lastTextZoom
                    items[idx].lastTwoPage = imported.lastTwoPage ?? items[idx].lastTwoPage
                    items[idx].lastTranslateSource = imported.lastTranslateSource ?? items[idx].lastTranslateSource
                    items[idx].lastTranslateTarget = imported.lastTranslateTarget ?? items[idx].lastTranslateTarget
                    updated += 1
                } else if bookmarksChanged {
                    updated += 1
                }
            } else if fm.fileExists(atPath: imported.url.path) {
                var copy = imported
                if let rootPath, !imported.url.path.hasPrefix(rootPath) {
                    copy.isExternal = true
                }
                copy.thumbnailFileName = nil // regenerate locally
                items.append(copy)
                added += 1
            }
        }

        if updated > 0 || added > 0 {
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            saveLibrary()
            if added > 0 {
                Task { await generateMissingThumbnails() }
            }
        }
        return (updated, added)
    }

    private func persistRootFolder() {
        guard let url = rootFolder else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        } else if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        }
    }

    private func restoreRootFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            self.rootFolder = url
        } else if let url = try? URL(resolvingBookmarkData: bookmark,
                                      options: [],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &stale) {
            self.rootFolder = url
        }
    }
}
