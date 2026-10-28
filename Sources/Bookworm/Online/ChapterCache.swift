import Foundation

/// 章节正文缓存（BR-36~BR-38）。
///
/// 元数据整体写 `ChapterCache/index.json`，正文写
/// `ChapterCache/<bookID>/<index>.txt`；同文件写入串行，全部原子替换。
/// 索引常驻内存字典，改动合并后防抖写盘；文件是否存在只在真正读取时校验。
actor ChapterCache {
    static let shared = ChapterCache()

    /// 内存索引：`bookID|chapterIndex` → 元数据，查找 O(1)。
    private var entries: [String: ChapterCacheMeta] = [:]
    private var loaded = false
    /// 索引改动的防抖写盘任务。
    private var indexSaveTask: Task<Void, Never>?
    private var indexDirty = false

    private let limitKey = "Bookworm.chapterCacheLimitMB"
    private let defaultLimitBytes: Int64 = 500 * 1024 * 1024

    private static func key(bookID: String, index: Int) -> String {
        "\(bookID)|\(index)"
    }

    // MARK: - 读取

    /// 命中缓存时返回文本与完整性标记，并刷新最近访问时间。
    func cachedText(bookID: String, index: Int) -> (text: String, complete: Bool)? {
        loadIfNeeded()
        let cacheKey = Self.key(bookID: bookID, index: index)
        guard var meta = entries[cacheKey] else {
            return nil
        }
        let url = AppPaths.supportDirectory
            .appendingPathComponent("ChapterCache", isDirectory: true)
            .appendingPathComponent(meta.relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 文件被外部删除：真正读取时才发现，清理失效项后重新抓取。
            entries.removeValue(forKey: cacheKey)
            scheduleIndexSave()
            return nil
        }
        meta.lastAccessAt = Date()
        entries[cacheKey] = meta
        scheduleIndexSave()
        return (text, meta.complete)
    }

    func meta(bookID: String, index: Int) -> ChapterCacheMeta? {
        loadIfNeeded()
        return entries[Self.key(bookID: bookID, index: index)]
    }

    // MARK: - 写入

    /// 写入一章正文；返回是否落盘成功。失败不影响本次阅读。
    @discardableResult
    func store(bookID: String,
               index: Int,
               text: String,
               complete: Bool,
               sourceFingerprint: String) -> Bool {
        loadIfNeeded()
        let relative = "\(bookID)/\(index).txt"
        let url = AppPaths.supportDirectory
            .appendingPathComponent("ChapterCache", isDirectory: true)
            .appendingPathComponent(relative)
        let data = Data(text.utf8)
        do {
            try AppPaths.atomicWrite(data, to: url)
        } catch {
            Diagnostics.log("chapter-cache", "写入第 \(index) 章失败：\(error.localizedDescription)")
            return false
        }

        let now = Date()
        entries[Self.key(bookID: bookID, index: index)] = ChapterCacheMeta(bookID: bookID,
                                                                          chapterIndex: index,
                                                                          relativePath: relative,
                                                                          byteSize: Int64(data.count),
                                                                          complete: complete,
                                                                          fetchedAt: now,
                                                                          lastAccessAt: now,
                                                                          sourceFingerprint: sourceFingerprint)
        scheduleIndexSave()
        evictIfNeeded()
        return true
    }

    /// 已有缓存但标记不完整时，仅当新正文长度 >1.05 倍才覆盖（BR-35）。
    @discardableResult
    func storeIfBetter(bookID: String,
                       index: Int,
                       text: String,
                       complete: Bool,
                       sourceFingerprint: String) -> Bool {
        loadIfNeeded()
        if let existing = entries[Self.key(bookID: bookID, index: index)] {
            if existing.complete { return false }
            let newSize = Int64(text.utf8.count)
            let oldSize = max(1, existing.byteSize)
            guard complete || Double(newSize) > Double(oldSize) * 1.05 else { return false }
        }
        return store(bookID: bookID, index: index, text: text,
                     complete: complete, sourceFingerprint: sourceFingerprint)
    }

    // MARK: - 删除与淘汰

    func removeBook(bookID: String) {
        loadIfNeeded()
        entries = entries.filter { $0.value.bookID != bookID }
        writeIndex()
        let dir = AppPaths.chapterCacheDirectory.appendingPathComponent(bookID, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func remove(bookID: String, index: Int) {
        loadIfNeeded()
        entries.removeValue(forKey: Self.key(bookID: bookID, index: index))
        writeIndex()
        try? FileManager.default.removeItem(at: AppPaths.chapterCacheFile(bookID: bookID, index: index))
    }

    func purgeAll() {
        loadIfNeeded()
        entries.removeAll()
        writeIndex()
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: AppPaths.chapterCacheDirectory,
                                                         includingPropertiesForKeys: nil) else { return }
        for child in children where child.pathExtension != "json" {
            try? fm.removeItem(at: child)
        }
    }

    func totalBytes() -> Int64 {
        loadIfNeeded()
        return entries.values.reduce(0) { $0 + $1.byteSize }
    }

    /// 缓存上限（MB），可设 100MB–5GB，默认 500MB。
    var limitBytes: Int64 {
        let stored = UserDefaults.standard.integer(forKey: limitKey)
        guard stored > 0 else { return defaultLimitBytes }
        let megabytes = min(5 * 1024, max(100, stored))
        return Int64(megabytes) * 1024 * 1024
    }

    var limitMegabytes: Int {
        let stored = UserDefaults.standard.integer(forKey: limitKey)
        return stored > 0 ? min(5 * 1024, max(100, stored)) : 500
    }

    func setLimitMegabytes(_ value: Int) {
        UserDefaults.standard.set(min(5 * 1024, max(100, value)), forKey: limitKey)
        evictIfNeeded()
    }

    /// 淘汰顺序：不完整 → 最久未访问 → 最旧抓取（BR-38）。
    private func evictIfNeeded() {
        let limit = limitBytes
        var total = entries.values.reduce(Int64(0)) { $0 + $1.byteSize }
        guard total > limit else { return }

        let candidates = entries.values.sorted { lhs, rhs in
            if lhs.complete != rhs.complete { return !lhs.complete && rhs.complete }
            if lhs.lastAccessAt != rhs.lastAccessAt { return lhs.lastAccessAt < rhs.lastAccessAt }
            return lhs.fetchedAt < rhs.fetchedAt
        }

        var removed = false
        for candidate in candidates {
            guard total > limit else { break }
            try? FileManager.default.removeItem(
                at: AppPaths.chapterCacheFile(bookID: candidate.bookID, index: candidate.chapterIndex))
            total -= candidate.byteSize
            entries.removeValue(forKey: Self.key(bookID: candidate.bookID, index: candidate.chapterIndex))
            removed = true
        }
        if removed { scheduleIndexSave() }
    }

    // MARK: - 索引读写

    private struct IndexFile: Codable {
        var schemaVersion: Int
        var entries: [ChapterCacheMeta]
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: AppPaths.cacheIndexFile),
              let file = try? AppPaths.decodeJSON(IndexFile.self, from: data) else {
            return
        }
        // 加载阶段不逐条 fileExists；失效项留到真正读取时清理。
        for entry in file.entries {
            entries[Self.key(bookID: entry.bookID, index: entry.chapterIndex)] = entry
        }
    }

    /// 索引变动后 1s 合并写盘；多次 store 只落一次。
    private func scheduleIndexSave() {
        indexDirty = true
        guard indexSaveTask == nil else { return }
        indexSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushPendingIndexIfNeeded()
        }
    }

    private func flushPendingIndexIfNeeded() {
        indexSaveTask = nil
        guard !Task.isCancelled, indexDirty else { return }
        writeIndex()
    }

    private func writeIndex() {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        indexDirty = false
        let sorted = entries.values.sorted {
            if $0.bookID != $1.bookID { return $0.bookID < $1.bookID }
            return $0.chapterIndex < $1.chapterIndex
        }
        let file = IndexFile(schemaVersion: 1, entries: sorted)
        do {
            try AppPaths.atomicWriteJSON(file, to: AppPaths.cacheIndexFile)
        } catch {
            Diagnostics.log("chapter-cache", "索引写入失败：\(error.localizedDescription)")
        }
    }
}
