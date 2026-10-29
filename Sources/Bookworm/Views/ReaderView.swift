import SwiftUI
import AppKit
import Combine

enum ReadingDirection: String, CaseIterable, Identifiable, Codable {
    // Raw values stay English so existing library.json files keep decoding;
    // `label` is what the UI displays.
    case leftToRight = "Left to Right"
    case rightToLeft = "Right to Left"
    case vertical = "Vertical (Webtoon)"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftToRight: return "从左到右"
        case .rightToLeft: return "从右到左"
        case .vertical: return "纵向（条漫）"
        }
    }

    var systemImage: String {
        switch self {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .vertical: return "arrow.down"
        }
    }
}

enum ZoomMode: Equatable, Hashable, Codable {
    case fitWidth
    case fitHeight
    case fitPage
    case actual
    case custom(CGFloat)

    var label: String {
        switch self {
        case .fitWidth: return "适合宽度"
        case .fitHeight: return "适合高度"
        case .fitPage: return "适合页面"
        case .actual: return "实际大小"
        case .custom(let v): return "\(Int(v * 100))%"
        }
    }

    // Manual Codable so the .custom(CGFloat) associated value can round-trip
    // through library.json. CGFloat isn't Codable on every platform; encoding
    // as Double avoids the issue.
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case fitWidth, fitHeight, fitPage, actual, custom
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fitWidth:  try c.encode(Kind.fitWidth,  forKey: .kind)
        case .fitHeight: try c.encode(Kind.fitHeight, forKey: .kind)
        case .fitPage:   try c.encode(Kind.fitPage,   forKey: .kind)
        case .actual:    try c.encode(Kind.actual,    forKey: .kind)
        case .custom(let v):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(Double(v),   forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .fitWidth:  self = .fitWidth
        case .fitHeight: self = .fitHeight
        case .fitPage:   self = .fitPage
        case .actual:    self = .actual
        case .custom:
            let v = try c.decode(Double.self, forKey: .value)
            self = .custom(CGFloat(v))
        }
    }
}

/// One chapter entry in a text ebook's table of contents.
/// `level` 为缩进层级（0 = 一级标题），`anchor` 为章节内的页内锚点。
struct TOCEntry: Identifiable, Hashable {
    let id = UUID()
    let pageIndex: Int
    let title: String
    var level: Int = 0
    var anchor: String? = nil
}

/// A single in-book search match: which chapter, and a text snippet
/// with the matched phrase in context.
struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
}

/// 搜索用 HTML → 纯文本的正则。模式是常量，预编译一次复用，
/// 避免每次搜索整本书时反复编译同一个 pattern。
private enum PlainTextRegex {
    static let script = try! NSRegularExpression(pattern: "(?s)<script.*?</script>")
    static let style = try! NSRegularExpression(pattern: "(?s)<style.*?</style>")
    static let tag = try! NSRegularExpression(pattern: "<[^>]+>")
    static let whitespace = try! NSRegularExpression(pattern: "\\s+")
}

@MainActor
final class ReaderModel: ObservableObject {
    let itemID: ComicItem.ID
    let library: LibraryStore

    @Published var pageCount: Int = 0
    @Published var currentPage: Int = 0
    @Published var direction: ReadingDirection = .leftToRight {
        didSet { if direction != oldValue, !isRestoring { saveSubject.send(()) } }
    }
    @Published var zoomMode: ZoomMode = .fitPage {
        didSet { if zoomMode != oldValue, !isRestoring { saveSubject.send(()) } }
    }
    @Published var backgroundDark: Bool = true
    @Published var loadError: String?
    @Published var isLoading: Bool = true
    @Published var loadingStatus: String = "正在打开书籍…"
    @Published var isTextBook: Bool = false
    @Published var textZoom: CGFloat = 1.0 {
        didSet { if textZoom != oldValue, !isRestoring { saveSubject.send(()) } }
    }
    /// When on, image-based readers (Paged + future Vertical) overlay
    /// OCR'd speech bubbles with on-hover translations. Off by default
    /// because OCR has a one-shot cost per page and translation hits the
    /// network.
    @Published var translateMode: Bool = false {
        didSet {
            // Translate mode and two-page spread don't mix — the OCR
            // overlay is laid out against a single page. Turning one on
            // turns the other off.
            if translateMode, twoPageSpread { twoPageSpread = false }
            // When the user turns translation on, the book "adopts" the
            // current language pair so it re-opens the same way.
            if translateMode, !isRestoring {
                library.updateTranslateLanguages(
                    itemID: itemID,
                    source: TranslationSettings.shared.sourceLanguage.rawValue,
                    target: TranslationSettings.shared.targetLanguage.rawValue
                )
            }
        }
    }

    /// Two-page spread: render the current page and its neighbour as a
    /// single composed image so the reader shows a book-like spread.
    /// Image-based books only. Persisted per book.
    @Published var twoPageSpread: Bool = false {
        didSet {
            guard twoPageSpread != oldValue else { return }
            if twoPageSpread, translateMode { translateMode = false }
            if twoPageSpread {
                // Snap to an even index so spreads pair up consistently
                // ([0,1], [2,3], …).
                currentPage = currentPage - (currentPage % 2)
            }
            if !isRestoring { saveSubject.send(()) }
        }
    }

    /// Page indices (0-based) the user has bookmarked in this book.
    /// Mirrors `ComicItem.bookmarks`; kept as a Set here for cheap
    /// membership tests and as `@Published` so the toolbar updates live.
    @Published var bookmarkedPages: Set<Int> = []

    /// Chapter list for text-based ebooks, built once on load from the
    /// reader's `pageTitle(at:)`. Empty for image books and for ebook
    /// formats that don't expose chapter titles (MOBI/TXT/FB2/HTML) —
    /// the TOC button only appears when this is non-empty.
    @Published var tableOfContents: [TOCEntry] = []

    /// 目录跳转后需要在当前章节内滚动到的锚点；下次切页时清空。
    @Published var pendingAnchor: String?
    /// 跨章回退时把上一章正文滚到底部（落在最后一页），保持阅读连贯；
    /// 下次切页时清空。
    @Published var pendingScrollToEnd: Bool = false
    /// 用户从目录里点选的条目，用于目录里高亮这一行。
    @Published var currentTOCEntryID: UUID?

    /// Live Text fallback content. Vision's text recogniser fails outright
    /// on stylised manga fonts (verified for Japanese and Chinese — zero
    /// observations across every revision and language hint), so when
    /// translate mode is on for a CJK source language we additionally run
    /// VisionKit's `ImageAnalyzer` ("Live Text") which reads stylised
    /// pages reliably. Live Text only gives a flat transcript with no
    /// per-line bounding boxes, so we render the result in a side panel
    /// instead of the on-image hover overlay.
    @Published var pageTranscriptLines: [String] = []
    /// True iff the side translation panel should be visible. The
    /// translate toggle drives this, plus a toolbar sidebar button so the
    /// user can hide it without leaving translate mode.
    @Published var translationPanelVisible: Bool = false

    /// True while load() is restoring values from the saved item — used to
    /// suppress the didSet observers below so we don't trigger a save during
    /// startup that just re-writes the same values back.
    private var isRestoring: Bool = false

    private var reader: ContentReader?
    private var prefetchTasks: [Int: Task<NSImage?, Never>] = [:]
    private var pageCache = NSCache<NSNumber, NSImage>()
    /// 正文缓存上限：只保留最近访问的若干章，长书顺序阅读时不会无限增长。
    private let contentCacheLimit = 12
    private var contentCache: [Int: PageContent] = [:]
    /// 正文缓存的 LRU 顺序，越靠后越新。
    private var contentCacheOrder: [Int] = []
    /// Low-resolution per-page thumbnails for the page-grid navigator.
    /// Separate from `pageCache` (which holds full-res decodes, limit 6)
    /// so scrolling the grid doesn't evict the pages being read.
    private let pageThumbCache = NSCache<NSNumber, NSImage>()
    private var saveDebouncer: AnyCancellable?
    private let saveSubject = PassthroughSubject<Void, Never>()
    private var translateLangSub: AnyCancellable?

    init(itemID: ComicItem.ID, library: LibraryStore) {
        self.itemID = itemID
        self.library = library
        pageCache.countLimit = 6
        pageThumbCache.countLimit = 400

        saveDebouncer = saveSubject
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.persistProgress() }

        // While this book is being read with translate mode on, mirror
        // any source/target language change back onto the library item
        // so the book remembers its own language pair.
        let settings = TranslationSettings.shared
        translateLangSub = settings.$sourceLanguage
            .combineLatest(settings.$targetLanguage)
            .dropFirst()
            .sink { [weak self] source, target in
                guard let self, self.translateMode else { return }
                self.library.updateTranslateLanguages(
                    itemID: self.itemID,
                    source: source.rawValue,
                    target: target.rawValue
                )
            }
    }

    func load() {
        guard let item = library.item(withID: itemID) else {
            self.loadError = "未找到该书。"
            self.isLoading = false
            return
        }
        let isText = item.format.isEbook

        // Restore saved per-book reading prefs first, behind the
        // `isRestoring` flag so the didSet observers don't try to persist
        // them back out as if the user had just changed them.
        isRestoring = true
        self.isTextBook = isText
        self.bookmarkedPages = Set(item.bookmarks ?? [])

        // Re-apply this book's last translate-mode language pair to the
        // shared settings so turning translation on picks up where the
        // book left off. (Shared settings means the last-opened book
        // wins if two are open at once — acceptable for the common
        // one-book-at-a-time case.)
        if let src = item.lastTranslateSource,
           let lang = SupportedLanguage(rawValue: src) {
            TranslationSettings.shared.sourceLanguage = lang
        }
        if let tgt = item.lastTranslateTarget,
           let lang = SupportedLanguage(rawValue: tgt) {
            TranslationSettings.shared.targetLanguage = lang
        }
        if isText {
            self.direction = item.lastDirection ?? .vertical
            self.zoomMode  = item.lastZoomMode  ?? .fitWidth
            if let savedTextZoom = item.lastTextZoom {
                self.textZoom = CGFloat(savedTextZoom)
            }
        } else {
            if let savedDirection = item.lastDirection {
                self.direction = savedDirection
            }
            // Image books (comics / manga / PDF) always open at Fit Page,
            // regardless of whatever zoom the user happened to leave the
            // book on last session. Pinch-zoom and toolbar zoom still work
            // during reading — they just don't follow the book into its
            // next open. This matches what most dedicated comic readers
            // do and avoids accidentally landing on a 300%-pinched view
            // a week later with no memory of why.
            self.zoomMode = .fitPage
            self.twoPageSpread = item.lastTwoPage ?? false
        }
        isRestoring = false

        self.isLoading = true
        self.loadingStatus = "正在打开书籍…"
        let format = item.format
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // 1. Open the archive / parse the table of contents.
                let r = try ArchiveFactory.makeReader(for: item)
                let count = try r.pageCount()
                let last = item.lastReadPage
                var initialPage = max(0, min(last, max(0, count - 1)))
                // Spread mode pairs pages from even indices — snap the
                // restored page so the saved spread re-opens aligned.
                if (item.lastTwoPage ?? false), !format.isEbook {
                    initialPage -= initialPage % 2
                }

                // Build the table of contents for text ebooks. EPUB exposes a
                // real multi-level TOC; other formats fall back to one flat
                // entry per chapter title.
                var toc: [TOCEntry] = []
                if format.isEbook {
                    if let items = r.tocItems(), !items.isEmpty {
                        toc = items.map {
                            TOCEntry(pageIndex: $0.pageIndex,
                                     title: $0.title,
                                     level: $0.level,
                                     anchor: $0.anchor)
                        }
                    } else {
                        for i in 0..<count {
                            if let title = r.pageTitle(at: i),
                               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                toc.append(TOCEntry(pageIndex: i, title: title))
                            }
                        }
                    }
                }

                await MainActor.run {
                    self.loadingStatus = "正在解码第 \(initialPage + 1) 页…"
                }

                // 2. For image-based books, decode the first page *here* inside
                //    the same detached task. This means the reader UI never
                //    appears with an empty page — by the time `isLoading` flips
                //    to false the visible page is already in `pageCache`, so
                //    ZoomablePageView.task picks it up synchronously on first
                //    paint instead of showing a second spinner.
                var firstPageImage: NSImage?
                if !format.isEbook {
                    if let content = try? r.content(at: initialPage),
                       case .image(let img) = content {
                        firstPageImage = img
                    }
                }

                await MainActor.run {
                    self.reader = r
                    self.pageCount = count
                    self.currentPage = initialPage
                    if let img = firstPageImage {
                        self.pageCache.setObject(img, forKey: NSNumber(value: initialPage))
                    }
                    self.isTextBook = format.isEbook
                    self.tableOfContents = toc
                    self.isLoading = false
                    // 文字书交给悬浮窗继续读同一本书（BR-57）。
                    self.registerFloatingSession()
                }

                // 3. Warm the neighbours in the background — outside the
                //    perceived load critical path.
                if !format.isEbook {
                    await self.prefetchAround(initialPage)
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func image(at index: Int) async -> NSImage? {
        if index < 0 || index >= pageCount { return nil }
        if let cached = pageCache.object(forKey: NSNumber(value: index)) {
            return cached
        }
        if let inFlight = prefetchTasks[index] {
            return await inFlight.value
        }
        let task = makeDecodeTask(index: index)
        prefetchTasks[index] = task
        let img = await task.value
        prefetchTasks.removeValue(forKey: index)
        return img
    }

    /// Chapter title for a text ebook page, if the format exposes one.
    func chapterTitle(at index: Int) -> String? {
        reader?.pageTitle(at: index)
    }

    // MARK: - In-book search

    /// Search the whole book for `rawQuery`, returning per-match hits
    /// with a context snippet. 逐章取内容、读文件、扫正文都在后台完成：
    /// 此前先在 MainActor 上把全书页面内容摸一遍，长书会明显卡住界面。
    func search(_ rawQuery: String) async -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, isTextBook, let reader else { return [] }
        let count = pageCount

        return await Task.detached(priority: .userInitiated) {
            var hits: [SearchHit] = []
            for i in 0..<count {
                guard let content = try? reader.content(at: i) else { continue }
                let title = reader.pageTitle(at: i) ?? "第 \(i + 1) 节"
                // PageContent 可能含 NSImage，跨线程只使用 URL / 纯文本。
                let html: String
                switch content {
                case .htmlFile(let url, _):
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    html = text
                case .htmlString(let text, _):
                    html = text
                case .image:
                    continue
                }
                hits += ReaderModel.searchHits(in: html,
                                                chapterIndex: i,
                                                chapterTitle: title,
                                                query: query)
            }
            return hits.sorted { $0.chapterIndex < $1.chapterIndex }
        }.value
    }

    /// Find every (capped) occurrence of `query` in one chapter's HTML
    /// and build a context snippet around each.
    nonisolated static func searchHits(in html: String,
                                        chapterIndex: Int,
                                        chapterTitle: String,
                                        query: String) -> [SearchHit] {
        let text = htmlToPlainText(html)
        guard !text.isEmpty else { return [] }
        var hits: [SearchHit] = []
        var searchStart = text.startIndex
        let maxPerChapter = 15
        while let range = text.range(of: query,
                                      options: [.caseInsensitive],
                                      range: searchStart..<text.endIndex) {
            let pad = 45
            let lo = text.index(range.lowerBound,
                                 offsetBy: -pad,
                                 limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(range.upperBound,
                                 offsetBy: pad,
                                 limitedBy: text.endIndex) ?? text.endIndex
            var snippet = String(text[lo..<hi])
            if lo != text.startIndex { snippet = "…" + snippet }
            if hi != text.endIndex { snippet += "…" }
            hits.append(SearchHit(chapterIndex: chapterIndex,
                                   chapterTitle: chapterTitle,
                                   snippet: snippet))
            searchStart = range.upperBound
            if hits.count >= maxPerChapter { break }
        }
        return hits
    }

    /// Lightweight HTML → plain text for search. Not a full parser: it
    /// drops script/style blocks, strips tags, decodes the handful of
    /// entities that actually matter for matching, and collapses
    /// whitespace. Good enough to find a phrase; fast enough to run
    /// over a whole book.
    nonisolated static func htmlToPlainText(_ html: String) -> String {
        var s = html
        s = PlainTextRegex.script.replacingMatches(in: s, with: " ")
        s = PlainTextRegex.style.replacingMatches(in: s, with: " ")
        s = PlainTextRegex.tag.replacingMatches(in: s, with: " ")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "'")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201D}")
            .replacingOccurrences(of: "&mdash;", with: "—")
        s = PlainTextRegex.whitespace.replacingMatches(in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func contentSync(at index: Int) -> PageContent? {
        if let cached = contentCache[index] {
            touchContentCache(index)
            return cached
        }
        guard let reader, index >= 0, index < pageCount else { return nil }
        do {
            let c = try reader.content(at: index)
            contentCache[index] = c
            touchContentCache(index)
            return c
        } catch {
            return nil
        }
    }

    /// 把索引标为最近使用；超过上限时淘汰最久未访问的一条。
    private func touchContentCache(_ index: Int) {
        if let pos = contentCacheOrder.firstIndex(of: index) {
            contentCacheOrder.remove(at: pos)
        }
        contentCacheOrder.append(index)
        while contentCacheOrder.count > contentCacheLimit {
            let oldest = contentCacheOrder.removeFirst()
            contentCache.removeValue(forKey: oldest)
        }
    }

    private func makeDecodeTask(index: Int) -> Task<NSImage?, Never> {
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            guard let reader = await self.reader else { return nil }
            do {
                let content = try reader.content(at: index)
                guard case .image(let img) = content else { return nil }
                await MainActor.run {
                    self.pageCache.setObject(img, forKey: NSNumber(value: index))
                }
                return img
            } catch {
                return nil
            }
        }
    }

    /// Decode neighbouring pages in parallel so flipping forward is instant.
    /// The current index gets requested first (it'll already be in-flight from
    /// the visible view, but this is harmless thanks to the prefetchTasks dedupe
    /// in image(at:)).
    func prefetchAround(_ index: Int) async {
        guard !isTextBook else { return }
        let radius = 2
        await withTaskGroup(of: Void.self) { group in
            for offset in -radius...radius {
                let i = index + offset
                if i >= 0 && i < pageCount {
                    group.addTask { [weak self] in
                        _ = await self?.image(at: i)
                    }
                }
            }
        }
    }

    /// How many pages a single next/prev step covers. Two in spread
    /// mode for image books, one otherwise.
    var pageStride: Int { (twoPageSpread && !isTextBook) ? 2 : 1 }

    func goNext() { setPage(currentPage + pageStride) }
    /// 回退：跨章时落到上一章末页（章内已滚到底部），而不是从头开始。
    func goPrev() { setPage(currentPage - pageStride, scrollToEnd: true) }

    // MARK: - Bookmarks

    func isBookmarked(_ page: Int) -> Bool { bookmarkedPages.contains(page) }

    var isCurrentPageBookmarked: Bool { bookmarkedPages.contains(currentPage) }

    /// Toggle the bookmark for a page; persists to the library item.
    func toggleBookmark(at page: Int) {
        let nowOn = library.toggleBookmark(itemID: itemID, page: page)
        if nowOn { bookmarkedPages.insert(page) } else { bookmarkedPages.remove(page) }
    }

    func toggleBookmarkCurrentPage() { toggleBookmark(at: currentPage) }

    // MARK: - Spread / display image

    /// The image to render for `index` — a composed two-page spread when
    /// spread mode is on, otherwise the single decoded page. Both the
    /// paged reader and (when applicable) the translate overlay go
    /// through this so they always agree on what's on screen.
    func displayImage(at index: Int) async -> NSImage? {
        if twoPageSpread && !isTextBook {
            return await spreadImage(leftIndex: index)
        }
        return await image(at: index)
    }

    /// Compose pages `leftIndex` and `leftIndex + 1` side-by-side into a
    /// single image. In right-to-left mode the page order is mirrored so
    /// the lower page number sits on the right. If there's no second
    /// page (last page of an odd-length book) the single page is
    /// returned unchanged.
    func spreadImage(leftIndex: Int) async -> NSImage? {
        guard let first = await image(at: leftIndex) else { return nil }
        guard leftIndex + 1 < pageCount,
              let second = await image(at: leftIndex + 1) else {
            return first
        }
        // Reading order: in RTL the earlier page is on the right.
        let pageA = direction == .rightToLeft ? second : first
        let pageB = direction == .rightToLeft ? first : second
        return ReaderModel.composeSpread(left: pageA, right: pageB)
    }

    /// Draw two page images into one canvas, side by side, vertically
    /// centred against the taller of the two. Nonisolated so the
    /// detached decode tasks can call it off the main actor.
    nonisolated static func composeSpread(left: NSImage, right: NSImage) -> NSImage {
        let lSize = left.size
        let rSize = right.size
        let height = max(lSize.height, rSize.height)
        let width = lSize.width + rSize.width
        guard width > 0, height > 0 else { return left }
        let canvas = NSImage(size: NSSize(width: width, height: height))
        canvas.lockFocus()
        NSColor.clear.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        left.draw(in: NSRect(x: 0,
                              y: (height - lSize.height) / 2,
                              width: lSize.width,
                              height: lSize.height))
        right.draw(in: NSRect(x: lSize.width,
                               y: (height - rSize.height) / 2,
                               width: rSize.width,
                               height: rSize.height))
        canvas.unlockFocus()
        return canvas
    }

    // MARK: - Page-grid thumbnails

    /// A small thumbnail of a single page for the page-grid navigator.
    /// Decoded from the full page on first request and cached in a
    /// dedicated, generously-sized cache.
    func pageThumbnail(at index: Int) async -> NSImage? {
        if index < 0 || index >= pageCount { return nil }
        let key = NSNumber(value: index)
        if let cached = pageThumbCache.object(forKey: key) { return cached }
        guard let full = await image(at: index) else { return nil }
        let thumb = full.resized(maxDimension: 220)
        pageThumbCache.setObject(thumb, forKey: key)
        return thumb
    }

    /// The cover thumbnail for the current book, used as a low-res placeholder
    /// while page 0 is being decoded so the reader never opens to a blank
    /// progress spinner.
    func coverThumbnail() -> NSImage? {
        guard let item = library.item(withID: itemID) else { return nil }
        return library.thumbnailImage(for: item)
    }

    func setPage(_ index: Int, anchor: String? = nil, scrollToEnd: Bool = false) {
        let previousPage = currentPage
        var clamped = max(0, min(pageCount - 1, index))
        // Spread mode always lands on the even page of a pair so the
        // composed image stays aligned with the [0,1],[2,3],… pairing.
        if twoPageSpread, !isTextBook {
            clamped -= clamped % 2
        }
        currentPage = clamped
        // 普通翻页会清掉目录跳转留下的锚点与高亮；带着锚点调用时保留。
        if anchor == nil {
            pendingAnchor = nil
            currentTOCEntryID = nil
        } else {
            pendingAnchor = anchor
        }
        // 只有真正换了章才需要滚到章末；停在原地时不要改动滚动位置。
        pendingScrollToEnd = scrollToEnd && clamped != previousPage
        Task { await prefetchAround(clamped) }
        saveSubject.send(())
        syncFloatingSession(page: clamped)
    }

    // MARK: - 悬浮窗会话

    /// 文字书注册到共享阅读会话，供悬浮窗读取同一本书的正文（BR-57）。
    /// loader 强引用底层 reader，主窗关闭后悬浮窗仍能继续读。
    private func registerFloatingSession() {
        guard isTextBook, pageCount > 0, let contentReader = reader else { return }
        let bookID = itemID.uuidString
        let count = pageCount
        let title = library.item(withID: itemID)?.title ?? ""
        ReadingSession.shared.open(
            bookID: bookID,
            title: title,
            chapterIndex: currentPage,
            chapterCount: count,
            chapterTitle: contentReader.pageTitle(at: currentPage) ?? "",
            offset: 0,
            loader: ReadingSession.Loader(load: { index in
                guard index >= 0, index < count else {
                    throw RuleError.empty("章节")
                }
                let content = try contentReader.content(at: index)
                return ChapterPayload(index: index,
                                      title: contentReader.pageTitle(at: index) ?? "第 \(index + 1) 节",
                                      text: TextExtraction.plainText(from: content),
                                      complete: true)
            }),
            persist: nil
        )
    }

    /// 主窗翻页时把章索引同步给悬浮窗。
    private func syncFloatingSession(page: Int) {
        let session = ReadingSession.shared
        guard session.isActive, session.bookID == itemID.uuidString else { return }
        session.goToChapter(page)
    }

    /// 从目录点选条目：切到对应章节，并滚动到条目锚点。
    func jumpToTOCEntry(_ entry: TOCEntry) {
        setPage(entry.pageIndex, anchor: entry.anchor)
        currentTOCEntryID = entry.id
    }

    func bumpTextZoom(_ delta: CGFloat) {
        textZoom = max(0.6, min(2.5, textZoom + delta))
    }

    func persistProgress() {
        library.updateProgress(
            itemID: itemID,
            page: currentPage,
            pageCount: pageCount,
            direction: direction,
            zoomMode: zoomMode,
            textZoom: Double(textZoom),
            twoPage: twoPageSpread
        )
    }

    func close() {
        persistProgress()
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        pageCache.removeAllObjects()
        contentCache.removeAll()
        contentCacheOrder.removeAll()

        // 悬浮窗还在这本书上时保留会话与底层 reader，让另一端继续读（UC-15）。
        let session = ReadingSession.shared
        let floatingContinues = session.isActive
            && session.bookID == itemID.uuidString
            && FloatingPanelController.shared.isPanelVisible
        if floatingContinues { return }

        session.close(ifBook: itemID.uuidString)
        reader?.close()
        reader = nil
    }
}

struct ReaderView: View {
    let itemID: ComicItem.ID
    @EnvironmentObject var library: LibraryStore
    /// 由 ReaderWindowController 在开窗时创建并注入，加载也在那里直接触发。
    @ObservedObject var model: ReaderModelHolder
    /// 当前阅读内容里可垂直滚动的视图，供 ↑/↓ 使用。
    @State private var scrollBridge = ReaderScrollBridge()
    @ObservedObject private var ebook = EbookSettings.shared
    @ObservedObject private var session = ReadingSession.shared
    @State private var jumpPageText: String = ""
    @State private var showJumpField: Bool = false
    @State private var showingTranslateSettings: Bool = false
    @State private var showingPageGrid: Bool = false
    @State private var showingBookmarks: Bool = false
    @State private var showingTOC: Bool = false
    @State private var showingSearch: Bool = false
    @State private var showingTextFormat: Bool = false
    /// 底部进度条默认隐藏，鼠标移到底部区域时才淡入，避免遮挡正文。
    @State private var bottomBarHovered: Bool = false

    private var backgroundColor: Color {
        guard let m = model.value else { return Color(red: 0.02, green: 0.04, blue: 0.10) }
        if m.isTextBook {
            return ebook.theme.windowBackground
        }
        return m.backgroundDark ? .black : .white
    }

    var body: some View {
        readerBody
            .inspector(isPresented: Binding(
                get: { (model.value?.translationPanelVisible ?? false) && (model.value?.translateMode ?? false) },
                set: { newValue in model.value?.translationPanelVisible = newValue }
            )) {
                if let m = model.value {
                    TranslationPanelView(model: m,
                                          settings: TranslationSettings.shared)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
            }
    }

    @ViewBuilder
    private var readerBody: some View {
        // 正文铺满整个窗口，底栏做成叠在正文最下方的浮层：默认隐藏，
        // 鼠标移到该区域才淡入，这样既不遮挡文字，也不额外占一条高度。
        Group {
            if let m = model.value {
                if m.isLoading {
                    ProgressView(m.loadingStatus)
                        .controlSize(.large)
                        .foregroundStyle(m.backgroundDark ? .white : .black)
                } else if let err = m.loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text("无法打开此文件")
                            .font(.title3.bold())
                        Text(err)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 30)
                    }
                    .foregroundStyle(m.backgroundDark ? .white : .black)
                } else if m.pageCount > 0 {
                    if m.isTextBook {
                        TextPageView(model: m, scrollBridge: scrollBridge)
                    } else if m.direction == .vertical {
                        VerticalPagesView(model: m)
                    } else {
                        PagedReaderView(model: m, scrollBridge: scrollBridge)
                    }
                } else {
                    Text("没有可显示的页面。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let m = model.value, m.pageCount > 0, !m.isLoading {
                bottomBar(model: m)
                    .opacity(bottomBarHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: bottomBarHovered)
                    .onHover { bottomBarHovered = $0 }
            }
        }
        .background(backgroundColor.ignoresSafeArea())
        .toolbar { toolbarContent }
        .background(KeyEventHandlingView(
            onKeyDown: { handleKey(event: $0) },
            onSwipe: { handleSwipe(deltaX: $0) }
        ))
        .onAppear {
            // 正常路径已由 ReaderWindowController 注入模型并调用 load()，
            // 这里只兜底其它构造入口（如 ReaderWindowHost）。
            if model.value == nil {
                let m = ReaderModel(itemID: itemID, library: library)
                model.install(m)
                m.load()
            }
        }
        .onDisappear {
            model.value?.close()
        }
        .onChange(of: session.chapterIndex) { _, newValue in
            guard let m = model.value,
                  m.isTextBook,
                  session.bookID == itemID.uuidString,
                  m.currentPage != newValue else { return }
            m.setPage(newValue)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.value?.goPrev()
            } label: {
                Image(systemName: (model.value?.direction == .rightToLeft) ? "chevron.right" : "chevron.left")
            }
            .help("上一页")

            Button {
                model.value?.goNext()
            } label: {
                Image(systemName: (model.value?.direction == .rightToLeft) ? "chevron.left" : "chevron.right")
            }
            .help("下一页")
        }

        // Page / chapter counter — pulled to the right of the toolbar
        // (not centred), with horizontal breathing room from the
        // navigation buttons on its left and the action controls on its
        // right. Declared before the main primaryAction group so it
        // sits at the left edge of the right-hand cluster.
        ToolbarItemGroup(placement: .primaryAction) {
            if let m = model.value {
                Button {
                    showJumpField.toggle()
                    jumpPageText = "\(m.currentPage + 1)"
                } label: {
                    Text(pageCounterLabel(model: m))
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderless)
                .help(m.isTextBook ? "跳转到章节" : "跳转到页")
                .popover(isPresented: $showJumpField) {
                    JumpToPageView(
                        text: $jumpPageText,
                        pageCount: m.pageCount,
                        label: m.isTextBook ? "章节" : "页"
                    ) { newPage in
                        m.setPage(newPage - 1)
                        showJumpField = false
                    }
                    .padding()
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let m = model.value {
                if m.isTextBook {
                    if !m.tableOfContents.isEmpty {
                        Button {
                            showingTOC.toggle()
                        } label: {
                            Image(systemName: "list.bullet.indent")
                        }
                        .help("目录")
                        .popover(isPresented: $showingTOC) {
                            TableOfContentsView(model: m) { entry in
                                m.jumpToTOCEntry(entry)
                                showingTOC = false
                            }
                        }
                    }
                    Button {
                        showingSearch.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("在书中搜索")
                    .keyboardShortcut("f", modifiers: [.command])
                    .popover(isPresented: $showingSearch) {
                        BookSearchView(model: m) { page in
                            m.setPage(page)
                            showingSearch = false
                        }
                    }
                } else {
                    Button {
                        showingPageGrid.toggle()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help("页面网格")
                    .popover(isPresented: $showingPageGrid) {
                        PageGridView(model: m) { page in
                            m.setPage(page)
                            showingPageGrid = false
                        }
                    }
                }

                Button {
                    m.toggleBookmarkCurrentPage()
                } label: {
                    Image(systemName: m.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(m.isCurrentPageBookmarked ? "移除书签" : "为此页添加书签")
                .keyboardShortcut("d", modifiers: [.command])

                Button {
                    showingBookmarks.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                }
                .help("书签")
                .popover(isPresented: $showingBookmarks) {
                    BookmarksListView(model: m) { page in
                        m.setPage(page)
                        showingBookmarks = false
                    }
                }

                if !m.isTextBook {
                    Toggle(isOn: Binding(
                        get: { m.twoPageSpread },
                        set: { m.twoPageSpread = $0 })
                    ) {
                        Image(systemName: m.twoPageSpread
                              ? "book.pages.fill" : "book.pages")
                    }
                    .toggleStyle(.button)
                    .help(m.twoPageSpread
                          ? "单页" : "双页展开")

                    Picker("方向", selection: Binding(
                        get: { m.direction },
                        set: { m.direction = $0 })
                    ) {
                        ForEach(ReadingDirection.allCases) { d in
                            Label(d.label, systemImage: d.systemImage).tag(d)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    .help("阅读方向")
                }

                if m.isTextBook {
                    // Single "Aa" menu collecting text size, typeface,
                    // line spacing, and colour theme — keeps the ebook
                    // toolbar uncluttered.
                    Menu {
                        textFormatMenuContent(model: m)
                    } label: {
                        Image(systemName: "textformat")
                    }
                    .help("文本格式")
                } else {
                    Menu {
                        Button("适合页面") { m.zoomMode = .fitPage }
                        Button("适合宽度") { m.zoomMode = .fitWidth }
                        Button("适合高度") { m.zoomMode = .fitHeight }
                        Button("实际大小") { m.zoomMode = .actual }
                        Divider()
                        Button("50%") { m.zoomMode = .custom(0.5) }
                        Button("75%") { m.zoomMode = .custom(0.75) }
                        Button("100%") { m.zoomMode = .custom(1.0) }
                        Button("150%") { m.zoomMode = .custom(1.5) }
                        Button("200%") { m.zoomMode = .custom(2.0) }
                    } label: {
                        Label(m.zoomMode.label, systemImage: "magnifyingglass")
                    }
                    .help("缩放")

                    Toggle(isOn: Binding(
                        get: { m.backgroundDark },
                        set: { m.backgroundDark = $0 })
                    ) {
                        Image(systemName: m.backgroundDark ? "moon.fill" : "sun.max.fill")
                    }
                    .toggleStyle(.button)
                    .help("切换背景")

                    translateControls(model: m)
                }
            }
        }
    }

    /// Contents of the ebook "Aa" text-format menu: text size, typeface,
    /// line spacing, and colour theme — all bound to the global
    /// EbookSettings so the choice carries across books and windows.
    @ViewBuilder
    private func textFormatMenuContent(model m: ReaderModel) -> some View {
        Section("字号") {
            Button {
                m.bumpTextZoom(-0.1)
            } label: {
                Label("减小", systemImage: "textformat.size.smaller")
            }
            Button {
                m.bumpTextZoom(+0.1)
            } label: {
                Label("增大", systemImage: "textformat.size.larger")
            }
            Text("\(Int(m.textZoom * 100))%")
        }
        Picker("字体", selection: $ebook.font) {
            ForEach(EbookFont.allCases) { font in
                Text(font.displayName).tag(font)
            }
        }
        Menu("行距") {
            Button("更紧凑") {
                ebook.lineSpacing = max(EbookSettings.minLineSpacing,
                                         ebook.lineSpacing - 0.1)
            }
            Button("更宽松") {
                ebook.lineSpacing = min(EbookSettings.maxLineSpacing,
                                         ebook.lineSpacing + 0.1)
            }
            Text(String(format: "%.1f×", ebook.lineSpacing))
        }
        Picker("主题", selection: $ebook.theme) {
            ForEach(EbookTheme.allCases) { theme in
                Label(theme.displayName, systemImage: theme.symbolName).tag(theme)
            }
        }
    }

    /// The page-counter label. Two-page spread shows the page range
    /// ("Pages 3–4 / 120"); everything else shows a single index.
    private func pageCounterLabel(model m: ReaderModel) -> String {
        if m.isTextBook {
            return "章节 \(m.currentPage + 1) / \(m.pageCount)"
        }
        if m.twoPageSpread, m.currentPage + 1 < m.pageCount {
            return "第 \(m.currentPage + 1)–\(m.currentPage + 2) 页 / 共 \(m.pageCount) 页"
        }
        return "第 \(m.currentPage + 1) / \(m.pageCount) 页"
    }

    /// Translate-mode toggle + settings popover. Only shown for image-based
    /// books — EPUB / MOBI text is already in the document, the user can
    /// pick a system text translator instead.
    @ViewBuilder
    private func translateControls(model m: ReaderModel) -> some View {
        Toggle(isOn: Binding(
            get: { m.translateMode },
            set: { m.translateMode = $0 })
        ) {
            Image(systemName: m.translateMode ? "character.bubble.fill" : "character.bubble")
        }
        .toggleStyle(.button)
        .help(m.translateMode ? "关闭翻译" : "开启翻译")

        if m.translateMode {
            Toggle(isOn: Binding(
                get: { m.translationPanelVisible },
                set: { m.translationPanelVisible = $0 })
            ) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(m.translationPanelVisible
                  ? "隐藏翻译面板"
                  : "显示翻译面板（实时文本）")
        }

        Button {
            showingTranslateSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .help("翻译设置")
        .popover(isPresented: $showingTranslateSettings) {
            TranslateSettingsView(settings: TranslationSettings.shared)
        }
    }

    private func bottomBar(model m: ReaderModel) -> some View {
        // In right-to-left manga mode the slider thumb already travels
        // right-to-left, but the two endpoint labels used to stay fixed at
        // [current ──●── total]. Swap them so the layout reads as
        // [total ──●── current] — i.e. the high page numbers sit on the left
        // end (where the slider ends up) and the low/current sit on the
        // right end (where the reader starts).
        let isRTL = !m.isTextBook && m.direction == .rightToLeft
        let leftNumber  = isRTL ? m.pageCount : (m.currentPage + 1)
        let rightNumber = isRTL ? (m.currentPage + 1) : m.pageCount
        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("\(leftNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, alignment: .trailing)

                PageSlider(
                    value: Binding(
                        get: { Double(m.currentPage) },
                        set: { m.setPage(Int($0.rounded())) }
                    ),
                    range: 0...Double(max(0, m.pageCount - 1)),
                    reversed: isRTL
                )

                Text("\(rightNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.black.opacity(0.55))
    }

    /// Trackpad swipe-between-pages. `deltaX > 0` is a swipe toward the
    /// left — page-forward in left-to-right reading, page-back in RTL
    /// manga — mirroring the page-level mapping in `handleKey`.
    private func handleSwipe(deltaX: CGFloat) {
        guard let m = model.value, deltaX != 0 else { return }
        let isRTL = !m.isTextBook && m.direction == .rightToLeft
        turnPage(forward: isRTL ? deltaX < 0 : deltaX > 0, model: m)
    }

    private func handleKey(event: NSEvent) -> Bool {
        guard let m = model.value else { return false }
        let context = ReaderNavigation.Context(
            isRightToLeft: !m.isTextBook && m.direction == .rightToLeft)
        guard let intent = ReaderNavigation.intent(for: event, context: context) else { return false }
        switch intent {
        case .pageForward:
            turnPage(forward: true, model: m)
        case .pageBackward:
            turnPage(forward: false, model: m)
        case .chapterForward:
            m.goNext()
        case .chapterBackward:
            m.goPrev()
        case .toStart:
            m.setPage(0)
        case .toEnd:
            m.setPage(m.pageCount - 1)
        }
        return true
    }

    /// 页级前进/后退：内容可滚动时先滚一屏，到边界再跨章；整页显示时直接翻页。
    /// 文字书走 WebView 的一屏滚动，图片书走 NSScrollView（放大后仍可一屏滚动）。
    private func turnPage(forward: Bool, model m: ReaderModel) {
        let handled = scrollBridge.turnScreen(forward: forward) { [weak m] in
            guard let m else { return }
            if forward { m.goNext() } else { m.goPrev() }
        }
        if !handled {
            if forward { m.goNext() } else { m.goPrev() }
        }
    }
}

@MainActor
final class ReaderModelHolder: ObservableObject {
    @Published var value: ReaderModel?
    private var innerSubscription: AnyCancellable?

    /// Install the reader model and bridge its `objectWillChange` to ours so
    /// any @Published change on the inner model (isLoading, pageCount,
    /// currentPage, loadingStatus, …) makes ReaderView re-render. Without
    /// this, the body only re-renders when `value` itself is reassigned, so
    /// the view stays frozen on its initial snapshot.
    func install(_ model: ReaderModel) {
        innerSubscription?.cancel()
        innerSubscription = model.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        value = model
    }
}

struct JumpToPageView: View {
    @Binding var text: String
    let pageCount: Int
    let label: String
    var onSubmit: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("跳转到\(label)（1 – \(pageCount)）")
                .font(.callout)
            HStack {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit(submit)
                Button("跳转", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 240)
    }

    private func submit() {
        if let n = Int(text), n >= 1, n <= pageCount {
            onSubmit(n)
        }
    }
}

struct TextPageView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var ebook = EbookSettings.shared
    let scrollBridge: ReaderScrollBridge?

    var body: some View {
        Group {
            if let content = model.contentSync(at: model.currentPage) {
                WebPageView(
                    content: content,
                    bookID: model.itemID.uuidString,
                    pageIndex: model.currentPage,
                    theme: ebook.theme,
                    font: ebook.font,
                    lineSpacing: ebook.lineSpacing,
                    zoom: model.textZoom,
                    onScrollToTop: {},
                    scrollBridge: scrollBridge,
                    anchor: model.pendingAnchor,
                    scrollToEnd: model.pendingScrollToEnd
                )
            } else {
                ProgressView()
            }
        }
    }
}
