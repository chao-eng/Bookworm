import Foundation
import Combine

/// 章节索引、正文抓取、预取与健康度（UC-07~UC-09）。
@MainActor
final class ChapterService: ObservableObject {
    static let shared = ChapterService()

    /// 磁盘不足 1GB 时的一次性提示（UC-09 4b）。
    @Published private(set) var storageWarning: String?

    private var inFlight: [String: Task<ChapterPayload, Error>] = [:]
    private var prefetchTask: Task<Void, Never>?

    private let maxTOCPages = 200
    private let maxContentPages = 30

    // MARK: - 目录

    /// 读取已落盘的章节索引；没有则返回 nil。
    func loadIndex(bookID: String) -> ChapterIndex? {
        guard let data = try? Data(contentsOf: AppPaths.chapterIndexFile(bookID: bookID)),
              let index = try? AppPaths.decodeJSON(ChapterIndex.self, from: data) else {
            return nil
        }
        return index
    }

    /// 抓取并落盘目录（UC-07）。已有索引且未要求强制刷新时直接复用（BR-62）。
    func buildIndex(bookID: String,
                    detailURL: URL,
                    source: BookSource,
                    force: Bool = false) async throws -> ChapterIndex {
        if !force, let existing = loadIndex(bookID: bookID),
           existing.sourceFingerprint == SourceRepository.fingerprint(of: source) {
            return existing
        }
        if let inFlightIndex = indexTasks[bookID] {
            return try await inFlightIndex.value
        }
        let task = Task { try await self.fetchIndex(bookID: bookID,
                                                    detailURL: detailURL,
                                                    source: source) }
        indexTasks[bookID] = task
        defer { indexTasks[bookID] = nil }
        do {
            return try await task.value
        } catch {
            throw error
        }
    }

    private var indexTasks: [String: Task<ChapterIndex, Error>] = [:]

    private func fetchIndex(bookID: String,
                            detailURL: URL,
                            source: BookSource) async throws -> ChapterIndex {
        let rule = source.menuRule
        var collected: [ExtractedChapter] = []
        var seen: Set<String> = []
        var mode = "single"
        var complete = true

        func append(_ list: [ExtractedChapter]) -> Int {
            var added = 0
            for chapter in list {
                let key = chapter.url.absoluteString
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                collected.append(chapter)
                added += 1
            }
            return added
        }

        do {
            let firstHTML = try await NetworkClient.shared.fetchPage(url: detailURL,
                                                                     source: source,
                                                                     isContent: false)
            let firstList = try await RuleEngine.chapters(html: firstHTML,
                                                          baseURL: detailURL,
                                                          source: source)
            _ = append(firstList)

            if rule.isPaginated == true {
                mode = "paged"
            }

            if rule.isPaginated == true, source.isJSON, let pagination = rule.pagination,
               let pageParam = pagination.pageParam {
                // JSON 目录分页：按页码参数逐页抓取。
                let start = pagination.startPage ?? 1
                var page = start
                var pages = 1
                while pages < maxTOCPages {
                    guard var components = URLComponents(url: detailURL, resolvingAgainstBaseURL: false) else { break }
                    var items = components.queryItems ?? []
                    items.removeAll { $0.name == pageParam }
                    items.append(URLQueryItem(name: pageParam, value: String(page)))
                    if let sizeParam = pagination.sizeParam, let size = pagination.pageSize {
                        items.removeAll { $0.name == sizeParam }
                        items.append(URLQueryItem(name: sizeParam, value: String(size)))
                    }
                    components.queryItems = items
                    guard let pageURL = components.url else { break }
                    let html = try await NetworkClient.shared.fetchPage(url: pageURL,
                                                                         source: source,
                                                                         isContent: false)
                    let list = try await RuleEngine.chapters(html: html,
                                                              baseURL: pageURL,
                                                              source: source)
                    if list.isEmpty { break }
                    if append(list) == 0 { break }
                    page += 1
                    pages += 1
                    if pages >= maxTOCPages { complete = false }
                }
            } else if rule.isPaginated == true {
                var next: URL? = try await RuleEngine.nextChapterPage(html: firstHTML,
                                                                      baseURL: detailURL,
                                                                      source: source)
                var pages = 1
                while let url = next, pages < maxTOCPages {
                    if Task.isCancelled { throw NetworkError.cancelled }
                    let html = try await NetworkClient.shared.fetchPage(url: url,
                                                                         source: source,
                                                                         isContent: false)
                    let list = try await RuleEngine.chapters(html: html,
                                                              baseURL: url,
                                                              source: source)
                    if append(list) == 0 { break }
                    next = try await RuleEngine.nextChapterPage(html: html,
                                                                 baseURL: url,
                                                                 source: source)
                    pages += 1
                    if pages >= maxTOCPages { complete = false }
                }
            }
        } catch {
            recordTOC(sourceID: source.id, success: false, error: error.localizedDescription)
            throw error
        }

        guard !collected.isEmpty else {
            recordTOC(sourceID: source.id, success: false, error: "目录为空")
            throw RuleError.empty("目录")
        }
        if rule.isReversed == true {
            collected.reverse()
        }

        let chapters = collected.enumerated().map { offset, item in
            Chapter(index: offset, title: item.title, url: item.url.absoluteString, level: item.level)
        }
        let index = ChapterIndex(bookID: bookID,
                                 sourceID: source.id,
                                 chapters: chapters,
                                 tocMode: mode,
                                 isComplete: complete,
                                 sourceFingerprint: SourceRepository.fingerprint(of: source),
                                 fetchedAt: Date())
        do {
            try AppPaths.atomicWriteJSON(index, to: AppPaths.chapterIndexFile(bookID: bookID))
        } catch {
            Diagnostics.log("chapter-index", "写入失败：\(error.localizedDescription)")
        }
        recordTOC(sourceID: source.id, success: true)
        return index
    }

    // MARK: - 正文

    /// 读取正文：命中缓存直接返回，未命中则抓取并写缓存（BR-35、BR-62）。
    func payload(bookID: String, chapter: Chapter, source: BookSource) async throws -> ChapterPayload {
        let key = "\(bookID)|\(chapter.index)"
        if let cached = await ChapterCache.shared.cachedText(bookID: bookID, index: chapter.index) {
            return ChapterPayload(index: chapter.index,
                                  title: chapter.title,
                                  text: cached.text,
                                  complete: cached.complete)
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { () -> ChapterPayload in
            defer { Task { @MainActor in ChapterService.shared.inFlight[key] = nil } }
            return try await ChapterService.shared.fetchPayload(bookID: bookID,
                                                                chapter: chapter,
                                                                source: source)
        }
        inFlight[key] = task
        return try await task.value
    }

    private func fetchPayload(bookID: String,
                              chapter: Chapter,
                              source: BookSource) async throws -> ChapterPayload {
        guard let url = URL(string: chapter.url) else {
            throw NetworkError.fatal("章节地址不合法")
        }
        let rule = source.contentRule
        var texts: [String] = []
        var title = chapter.title
        var pages = 0
        var complete = true
        var currentURL: URL? = url

        do {
            while let pageURL = currentURL, pages < maxContentPages {
                if Task.isCancelled { throw NetworkError.cancelled }
                let html = try await NetworkClient.shared.fetchPage(url: pageURL,
                                                                     source: source,
                                                                     isContent: true)
                let content = try await RuleEngine.content(html: html,
                                                            baseURL: pageURL,
                                                            source: source)
                if let extractedTitle = content.title, !extractedTitle.isEmpty, pages == 0 {
                    title = extractedTitle
                }
                texts.append(content.text)
                pages += 1
                let multi = rule.multiPage?.boolValue == true || rule.multiPage?.objectValue != nil
                if multi || rule.nextPagePath != nil {
                    currentURL = try await RuleEngine.nextContentPage(html: html,
                                                                       baseURL: pageURL,
                                                                       source: source)
                } else {
                    currentURL = nil
                }
                if pages >= maxContentPages, currentURL != nil {
                    complete = false
                }
            }
        } catch {
            recordContent(sourceID: source.id, success: false, error: error.localizedDescription)
            throw error
        }

        var text = texts.joined(separator: "\n\n")
        let filtered = RuleEngine.applyFilters(text, filters: rule.filters)
        text = filtered.text
        if !RuleEngine.isComplete(text) {
            complete = false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuleError.empty("正文")
        }
        // 过滤误伤时不写缓存（BR-33）。
        if !filtered.rolledBack {
            await ChapterCache.shared.storeIfBetter(bookID: bookID,
                                                    index: chapter.index,
                                                    text: text,
                                                    complete: complete,
                                                    sourceFingerprint: SourceRepository.fingerprint(of: source))
        }
        recordContent(sourceID: source.id, success: true)
        return ChapterPayload(index: chapter.index, title: title, text: text, complete: complete)
    }

    /// 缓存命中判断，供 UI 决定是否显示加载态。
    func isCached(bookID: String, chapterIndex: Int) async -> Bool {
        await ChapterCache.shared.cachedText(bookID: bookID, index: chapterIndex) != nil
    }

    // MARK: - 预取

    /// 预取当前章 ±2，并发 3，可取消（BR-37）。
    func prefetch(bookID: String, chapters: [Chapter], around index: Int, source: BookSource) {
        prefetchTask?.cancel()
        guard availableDiskBytes() > 1_000_000_000 else {
            if storageWarning == nil {
                storageWarning = "存储空间不足，已暂停预取"
            }
            return
        }
        let lower = max(0, index - 2)
        let upper = min(chapters.count - 1, index + 2)
        guard lower <= upper else { return }
        let targets = (lower...upper).filter { $0 != index }.map { chapters[$0] }
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for chunk in targets.chunked(into: 3) {
                if Task.isCancelled { return }
                await withTaskGroup(of: Void.self) { group in
                    for chapter in chunk {
                        group.addTask { @MainActor in
                            guard !Task.isCancelled else { return }
                            _ = try? await self.payload(bookID: bookID, chapter: chapter, source: source)
                        }
                    }
                    await group.waitForAll()
                }
            }
        }
    }

    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// 切章/切书时取消在途请求；同书同章除外（BR-61）。
    func cancelInFlight(except key: String? = nil) {
        for (taskKey, task) in inFlight where taskKey != key {
            task.cancel()
        }
        if let key {
            inFlight = inFlight.filter { $0.key == key }
        } else {
            inFlight.removeAll()
        }
    }

    // MARK: - 健康度

    private func recordTOC(sourceID: String, success: Bool, error: String? = nil) {
        SourceRepository.shared.record(kind: .toc, sourceID: sourceID, success: success, error: error)
    }

    private func recordContent(sourceID: String, success: Bool, error: String? = nil) {
        SourceRepository.shared.record(kind: .content, sourceID: sourceID, success: success, error: error)
    }

    private func availableDiskBytes() -> Int64 {
        let url = AppPaths.supportDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
