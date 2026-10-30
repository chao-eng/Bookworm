import Foundation
import AppKit
import Combine

/// 后台枚举出的单个文件信息（纯数据，可跨线程传递）。
private struct ScannedFile {
    let url: URL
    let size: Int64
}

/// 单本封面生成的结果，回到主线程后据此合并条目状态。
private struct ThumbnailOutcome {
    let itemID: ComicItem.ID
    let fileName: String?
    let pageCount: Int?
    let isUnreadable: Bool
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [ComicItem] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanProgress: String = ""
    @Published var rootFolder: URL? {
        didSet { persistRootFolder() }
    }

    /// 缩略图内存缓存（按文件名），避免滚动时反复读盘解码。
    static let thumbnailCache = NSCache<NSString, NSImage>()

    /// 估算缩略图解码后的字节数，供 NSCache 按总成本淘汰。
    static func thumbnailCost(_ image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    private let supportDirectory: URL
    private let libraryFile: URL
    private let thumbnailsDirectory: URL
    private let defaultsKey = "Bookworm.rootFolderBookmark"

    /// 进度类高频写入的合并落盘状态（1 秒防抖）。
    private var pendingSaveTask: DispatchWorkItem?
    private var hasPendingSave = false
    private var isTerminating = false
    private var lastProgressItemID: ComicItem.ID?
    /// 正在进行的扫描；重新扫描时取消上一轮。
    private var scanTask: Task<Void, Never>?

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

        LibraryStore.thumbnailCache.countLimit = 120
        LibraryStore.thumbnailCache.totalCostLimit = 96 * 1024 * 1024

        loadLibrary()
        restoreRootFolder()

        // 退出前把防抖窗口里的进度写出，避免最后 1 秒的进度丢失。
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil,
                                                   queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTerminating = true
                self.flushPendingSave()
            }
        }
    }

    func thumbnailURL(for item: ComicItem) -> URL? {
        guard let name = item.thumbnailFileName else { return nil }
        return thumbnailsDirectory.appendingPathComponent(name)
    }

    func thumbnailImage(for item: ComicItem) -> NSImage? {
        guard let url = thumbnailURL(for: item) else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = LibraryStore.thumbnailCache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        LibraryStore.thumbnailCache.setObject(image,
                                              forKey: key,
                                              cost: LibraryStore.thumbnailCost(image))
        return image
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
        if let existing = items.first(where: { !$0.isOnline && $0.url.path == url.path }) {
            return existing.id
        }
        guard let format = ComicFormat.from(url: url), format != .online else { return nil }
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
        // 换到另一本书时先把上一本尚在防抖中的进度落盘，避免丢进度。
        if lastProgressItemID != itemID {
            flushPendingSave()
            lastProgressItemID = itemID
        }
        items[idx].lastReadPage = page
        items[idx].lastOpened = Date()
        if let pc = pageCount { items[idx].pageCount = pc }
        if let direction { items[idx].lastDirection = direction }
        if let zoomMode { items[idx].lastZoomMode = zoomMode }
        if let textZoom { items[idx].lastTextZoom = textZoom }
        if let twoPage { items[idx].lastTwoPage = twoPage }
        scheduleSave()
    }

    // MARK: - Folder selection

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择书籍文件夹"
        panel.message = "请选择存放书籍的文件夹，其中的子文件夹也会一并扫描。"
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
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.scanFolder(root)
        }
    }

    // MARK: - Scanning

    private func scanFolder(_ root: URL) async {
        // 已被新一轮扫描取消的任务不再改动任何状态。
        guard !Task.isCancelled else { return }
        isScanning = true
        scanProgress = "正在扫描…"

        let existingItems = items
        var existingByPath: [String: ComicItem] = [:]
        existingByPath.reserveCapacity(existingItems.count)
        for item in existingItems { existingByPath[item.url.path] = item }

        // 文件枚举与文件大小读取全部在后台线程完成。
        let found = await Task.detached(priority: .userInitiated) {
            LibraryStore.enumerateComicFiles(root: root)
        }.value
        guard !Task.isCancelled else { return }

        // 回到主线程只做条目合并，不再碰文件系统。
        var nextItems: [ComicItem] = []
        nextItems.reserveCapacity(found.count)
        for file in found {
            if let existing = existingByPath[file.url.path] {
                nextItems.append(existing)
            } else if let format = ComicFormat.from(url: file.url) {
                nextItems.append(ComicItem(url: file.url, format: format, fileSize: file.size))
            }
        }

        // 在线书不在文件系统里，重新扫描必须原样保留（BR-08）。
        nextItems.append(contentsOf: existingItems.filter { $0.isOnline })

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

        items = nextItems
        scanProgress = "正在生成封面…"

        await generateMissingThumbnails(persist: false)
        guard !Task.isCancelled else { return }

        // 整次扫描只在结束时落盘一次（含封面文件名、页数与移除的坏条目）。
        saveLibrary()
        isScanning = false
        scanProgress = ""
    }

    /// 在后台线程枚举可读文件并读取大小；不触碰任何 UI 状态。
    nonisolated private static func enumerateComicFiles(root: URL) -> [ScannedFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var out: [ScannedFile] = []
        for case let u as URL in enumerator {
            // Single source of truth: any file whose extension maps to a
            // ComicFormat is considered a library item — so adding ebook
            // formats in ComicFormat.from(url:) automatically extends the scan.
            guard ComicFormat.from(url: u) != nil else { continue }
            var size: Int64 = 0
            if let values = try? u.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize {
                size = Int64(fileSize)
            }
            out.append(ScannedFile(url: u, size: size))
        }
        return out
    }

    /// 生成缺失封面。打开归档、渲染、编码与写盘都在后台线程，
    /// 主线程只按批合并条目状态；`persist` 为 false 时由调用方统一落盘。
    private func generateMissingThumbnails(persist: Bool = true) async {
        guard !Task.isCancelled else { return }
        let snapshot = items
        let thumbsDir = thumbnailsDirectory
        // 判断哪些书缺封面同样在后台跑，主线程不碰文件系统。
        let pending = await Task.detached(priority: .utility) {
            LibraryStore.missingThumbnailItems(in: snapshot, thumbnailsDirectory: thumbsDir)
        }.value
        guard !pending.isEmpty else { return }

        let total = pending.count
        var completed = 0
        var lastPublish = Date.distantPast
        var outcomes: [ThumbnailOutcome] = []
        var removedIDs: Set<ComicItem.ID> = []
        var didChange = false

        // 限制并发，避免同时打开过多归档 / PDF 文件。
        let maxConcurrent = 4
        await withTaskGroup(of: ThumbnailOutcome.self) { group in
            var nextIndex = 0
            while nextIndex < min(maxConcurrent, total) {
                let item = pending[nextIndex]
                group.addTask(priority: .userInitiated) {
                    LibraryStore.makeThumbnail(for: item, in: thumbsDir)
                }
                nextIndex += 1
            }

            while let outcome = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                completed += 1
                if outcome.isUnreadable {
                    removedIDs.insert(outcome.itemID)
                } else if outcome.fileName != nil || outcome.pageCount != nil {
                    outcomes.append(outcome)
                }

                // 进度文案最多每 0.2s 刷新一次，避免扫描期间高频重建网格。
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= 0.2 || completed == total {
                    lastPublish = now
                    if self.applyThumbnailOutcomes(outcomes) { didChange = true }
                    outcomes.removeAll(keepingCapacity: true)
                    self.scanProgress = "正在生成封面 \(completed) / \(total)…"
                }

                if nextIndex < total {
                    let item = pending[nextIndex]
                    group.addTask(priority: .userInitiated) {
                        LibraryStore.makeThumbnail(for: item, in: thumbsDir)
                    }
                    nextIndex += 1
                }
            }
        }

        if applyThumbnailOutcomes(outcomes) { didChange = true }
        if !removedIDs.isEmpty {
            items.removeAll { removedIDs.contains($0.id) }
            didChange = true
        }
        if persist, didChange { saveLibrary() }
    }

    /// 筛出还没有有效封面的本地条目；在后台线程做文件存在性检查。
    nonisolated private static func missingThumbnailItems(in items: [ComicItem],
                                                          thumbnailsDirectory: URL) -> [ComicItem] {
        let fm = FileManager.default
        var out: [ComicItem] = []
        for item in items {
            // 在线书没有本地文件，封面由书源搜索结果单独下载。
            if item.isOnline { continue }
            // If the item already has a valid on-disk thumbnail, leave it
            // alone — we trust an earlier scan validated it.
            if let name = item.thumbnailFileName,
               fm.fileExists(atPath: thumbnailsDirectory.appendingPathComponent(name).path) {
                continue
            }
            out.append(item)
        }
        return out
    }

    /// 把一批封面结果合并进 `items`，每批只发一次 @Published。
    @discardableResult
    private func applyThumbnailOutcomes(_ outcomes: [ThumbnailOutcome]) -> Bool {
        guard !outcomes.isEmpty else { return false }
        var updated = items
        var indexByID: [ComicItem.ID: Int] = [:]
        indexByID.reserveCapacity(updated.count)
        for (idx, item) in updated.enumerated() { indexByID[item.id] = idx }

        var changed = false
        for outcome in outcomes {
            guard let idx = indexByID[outcome.itemID] else { continue }
            if let name = outcome.fileName, updated[idx].thumbnailFileName != name {
                updated[idx].thumbnailFileName = name
                // 重新生成的封面可能覆盖了旧缓存，先剔除。
                LibraryStore.thumbnailCache.removeObject(forKey: name as NSString)
                changed = true
            }
            if updated[idx].pageCount == nil, let count = outcome.pageCount {
                updated[idx].pageCount = count
                changed = true
            }
        }
        if changed { items = updated }
        return changed
    }

    /// 后台打开归档、渲染首页封面、降采样并编码写盘；返回纯数据。
    nonisolated private static func makeThumbnail(for item: ComicItem,
                                                  in directory: URL) -> ThumbnailOutcome {
        // Opening the archive / parsing the document is the canonical
        // readability check: every reader's init validates structure (PDF
        // password, archive signature, EPUB OPF, MOBI palmdb, etc.) and
        // throws on failure. If we can't even open it, the user has no
        // hope of reading it — drop it from the library.
        let reader: ContentReader
        do {
            reader = try ArchiveFactory.makeReader(for: item)
        } catch {
            return ThumbnailOutcome(itemID: item.id, fileName: nil, pageCount: nil, isUnreadable: true)
        }
        defer { reader.close() }

        guard let cover = (try? reader.coverImage()) ?? nil else {
            // Reader opened but cover failed — keep the item, since the
            // book is still readable. Library card falls back to the
            // generic placeholder.
            return ThumbnailOutcome(itemID: item.id, fileName: nil, pageCount: nil, isUnreadable: false)
        }
        let thumb = cover.resized(maxDimension: 600)
        guard let data = thumb.jpegData(compressionQuality: 0.82) else {
            return ThumbnailOutcome(itemID: item.id, fileName: nil, pageCount: nil, isUnreadable: false)
        }
        let filename = "\(item.id.uuidString).jpg"
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return ThumbnailOutcome(itemID: item.id, fileName: nil, pageCount: nil, isUnreadable: false)
        }
        return ThumbnailOutcome(itemID: item.id,
                                fileName: filename,
                                pageCount: (try? reader.pageCount()) ?? nil,
                                isUnreadable: false)
    }

    // MARK: - 在线书条目

    /// 加入或更新一条在线书。已存在时复用原 `id` 与阅读进度（BR-09）。
    /// 返回 true 表示新增，false 表示更新已有条目。
    @discardableResult
    func upsertOnlineItem(_ item: ComicItem) -> Bool {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            // 保留原阅读进度，只刷新来源信息与标题。
            items[idx].title = item.title.isEmpty ? items[idx].title : item.title
            items[idx].detailURL = item.detailURL
            items[idx].sourceID = item.sourceID
            items[idx].bookKey = item.bookKey
            if items[idx].thumbnailFileName == nil {
                items[idx].thumbnailFileName = item.thumbnailFileName
            }
            saveLibrary()
            return false
        }
        items.append(item)
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        saveLibrary()
        return true
    }

    /// 在线书统一进度真值：章节索引 + 章内字符偏移，页码只是派生值。
    func updateOnlineProgress(itemID: ComicItem.ID,
                              chapterIndex: Int,
                              offset: Int,
                              percent: Double?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[idx].lastReadChapter != chapterIndex
                || items[idx].lastChapterOffset != offset
                || (percent.map { abs((items[idx].bookPercent ?? 0) - $0) > 0.0001 } ?? false) else { return }
        // 换到另一本书时先把上一本尚在防抖中的进度落盘，避免丢进度。
        if lastProgressItemID != itemID {
            flushPendingSave()
            lastProgressItemID = itemID
        }
        items[idx].lastReadChapter = max(0, chapterIndex)
        items[idx].lastChapterOffset = max(0, offset)
        if let percent { items[idx].bookPercent = min(1, max(0, percent)) }
        items[idx].lastOpened = Date()
        scheduleSave()
    }

    func updateThumbnail(itemID: ComicItem.ID, fileName: String?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[idx].thumbnailFileName != fileName else { return }
        items[idx].thumbnailFileName = fileName
        // 同名封面可能已被新内容覆盖，先剔除旧缓存。
        if let fileName { LibraryStore.thumbnailCache.removeObject(forKey: fileName as NSString) }
        saveLibrary()
    }

    /// 从书架移除。在线书同时删除章节索引与正文缓存；本地书只删条目，
    /// 绝不删除源文件（BR-07）。
    func removeItem(itemID: ComicItem.ID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        items.removeAll { $0.id == itemID }
        saveLibrary()
        if item.isOnline {
            try? FileManager.default.removeItem(at: AppPaths.chapterIndexFile(bookID: item.id.uuidString))
            Task { await ChapterCache.shared.removeBook(bookID: item.id.uuidString) }
        }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var schemaVersion: Int?
        var items: [ComicItem]
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }

        // 先看顶层版本；缺失按 1 处理（旧版没有该字段）。
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let version = (root?["schemaVersion"] as? Int) ?? 1

        if version >= 2 {
            if let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
                self.items = decoded.items
            } else {
                // 条目级容错：逐条解码，坏条目只跳过自身（BR-06）。
                self.items = LibraryStore.decodeItemsTolerantly(from: data)
                saveLibrary()
            }
            return
        }

        // V1 迁移：先备份，再补默认值，原子替换（BR-01/BR-05）。
        let fm = FileManager.default
        if !fm.fileExists(atPath: AppPaths.libraryV1Backup.path) {
            try? fm.copyItem(at: libraryFile, to: AppPaths.libraryV1Backup)
        }
        self.items = LibraryStore.decodeItemsTolerantly(from: data)
        saveLibrary()
    }

    /// 逐条解码 `items`，单条失败只跳过并累计，不影响整个书库。
    private static func decodeItemsTolerantly(from data: Data) -> [ComicItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawItems = root["items"] as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        var result: [ComicItem] = []
        var skipped = 0
        for raw in rawItems {
            guard let itemData = try? JSONSerialization.data(withJSONObject: raw),
                  let item = try? decoder.decode(ComicItem.self, from: itemData) else {
                skipped += 1
                continue
            }
            result.append(item)
        }
        if skipped > 0 {
            Diagnostics.log("library-migration", "跳过 \(skipped) 条损坏条目，保留 \(result.count) 条")
        }
        return result
    }

    /// 立即全量落盘；同时清掉尚未触发的防抖写入。
    fileprivate func saveLibrary() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        hasPendingSave = false
        let p = Persisted(schemaVersion: 2, items: items)
        guard let data = try? JSONEncoder().encode(p) else { return }
        do {
            try AppPaths.atomicWrite(data, to: libraryFile)
        } catch {
            Diagnostics.log("library-save", "写入失败：\(error.localizedDescription)")
        }
    }

    /// 进度类高频更新先只改内存，1 秒内的连续更新合并成一次落盘。
    private func scheduleSave() {
        hasPendingSave = true
        // 正在退出时不再等防抖窗口，立即写出（避免最后一段进度丢失）。
        if isTerminating {
            saveLibrary()
            return
        }
        pendingSaveTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveLibrary()
            }
        }
        pendingSaveTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// 立即写出尚未落盘的进度（退出、换书等场景）。
    func flushPendingSave() {
        guard hasPendingSave else { return }
        saveLibrary()
    }

    // MARK: - Backup export / import

    static let backupSchemaVersion = 2

    /// 导出备份包：书库条目、进度、书签、偏好与书源，不含正文与缓存（UC-17）。
    func exportBackupData(sources: [BookSource] = [],
                          floating: FloatingState? = nil) -> Data? {
        let package = BackupPackage(schemaVersion: LibraryStore.backupSchemaVersion,
                                    exportedAt: Date(),
                                    appVersion: LibraryStore.appVersion,
                                    items: items,
                                    sources: sources,
                                    floating: floating,
                                    excluded: ["正文缓存", "缩略图", "日志"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(package)
    }

    /// 解析备份文件；兼容 V1 的 `{ items: [...] }` 结构。
    nonisolated static func decodeBackup(_ data: Data) -> BackupPackage? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let pkg = try? decoder.decode(BackupPackage.self, from: data) {
            return pkg
        }
        struct Legacy: Codable {
            var items: [ComicItem]
        }
        if let legacy = try? decoder.decode(Legacy.self, from: data) {
            return BackupPackage(schemaVersion: 1,
                                 exportedAt: Date(),
                                 appVersion: "unknown",
                                 items: legacy.items,
                                 sources: [],
                                 floating: nil,
                                 excluded: nil)
        }
        return nil
    }

    /// Merge a previously-exported backup back into the current library.
    ///
    /// - Books already present (matched by file path for local books,
    ///   by stable id for online books) adopt the backup's reading
    ///   progress + per-book prefs when the backup's `lastOpened` is
    ///   newer; bookmarks are always unioned so neither side loses a
    ///   mark.
    /// - Books in the backup but not the library are added if their
    ///   file still exists on this Mac, or unconditionally for online
    ///   books (PRD UC-17 5a: 源缺失也保留条目). Ones outside the
    ///   library root folder are flagged `isExternal` so a rescan
    ///   doesn't drop them.
    ///
    /// Returns how many items were updated vs. newly added.
    @discardableResult
    func importBackup(data: Data) -> (updated: Int, added: Int) {
        guard let package = LibraryStore.decodeBackup(data) else {
            return (0, 0)
        }
        guard package.schemaVersion <= LibraryStore.backupSchemaVersion else {
            // 备份版本高于当前 App：拒绝写入，由调用方提示先升级。
            return (0, 0)
        }
        var updated = 0
        var added = 0
        var indexByPath: [String: Int] = [:]
        var indexByID: [UUID: Int] = [:]
        for (i, item) in items.enumerated() {
            indexByPath[item.url.path] = i
            indexByID[item.id] = i
        }
        let fm = FileManager.default
        let rootPath = rootFolder?.path

        for imported in package.items {
            let existingIndex = imported.isOnline
                ? indexByID[imported.id]
                : indexByPath[imported.url.path]

            if let idx = existingIndex {
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
                    if imported.isOnline {
                        items[idx].lastReadChapter = imported.lastReadChapter ?? items[idx].lastReadChapter
                        items[idx].lastChapterOffset = imported.lastChapterOffset ?? items[idx].lastChapterOffset
                        items[idx].bookPercent = imported.bookPercent ?? items[idx].bookPercent
                    }
                    updated += 1
                } else if bookmarksChanged {
                    updated += 1
                }
            } else if imported.isOnline || fm.fileExists(atPath: imported.url.path) {
                var copy = imported
                if !imported.isOnline, let rootPath, !imported.url.path.hasPrefix(rootPath) {
                    copy.isExternal = true
                }
                copy.thumbnailFileName = nil // regenerate locally
                if imported.isOnline {
                    copy.thumbnailFileName = imported.thumbnailFileName
                }
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

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
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
