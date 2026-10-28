import Foundation
import Combine

/// 阅读会话：当前书 + 章 + 章内字符偏移，是主窗与悬浮窗共享的唯一进度真值（BR-57、BR-59）。
@MainActor
final class ReadingSession: ObservableObject {
    static let shared = ReadingSession()

    enum Source {
        case main
        case floating
    }

    struct Loader {
        /// 加载第 N 章（本地书为第 N 页）的文本内容。
        var load: (Int) async throws -> ChapterPayload
    }

    @Published private(set) var bookID: String = ""
    @Published private(set) var bookTitle: String = ""
    @Published private(set) var chapterIndex: Int = 0
    @Published private(set) var chapterCount: Int = 0
    @Published private(set) var chapterTitle: String = ""
    @Published private(set) var offset: Int = 0
    @Published private(set) var text: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?
    /// 本章正文是否完整（BR-34/BR-35 的提示依据）。
    @Published private(set) var isChapterComplete: Bool = true
    @Published private(set) var isActive: Bool = false
    @Published private(set) var lastUpdateSource: Source = .main

    var bookPercent: Double {
        guard chapterCount > 0 else { return 0 }
        let fraction: Double
        if text.isEmpty {
            fraction = 0
        } else {
            fraction = Double(min(max(offset, 0), text.count)) / Double(text.count)
        }
        return min(1, max(0, (Double(chapterIndex) + fraction) / Double(chapterCount)))
    }

    private var loader: Loader?
    private var persist: ((Int, Int, Double) -> Void)?
    private var persistTask: Task<Void, Never>?
    private var loadToken = 0
    private var lastPersistAt: Date = .distantPast

    // MARK: - 打开与关闭

    /// 打开会话；同一本书再次打开时保留现有进度。
    func open(bookID: String,
              title: String,
              chapterIndex: Int,
              chapterCount: Int,
              chapterTitle: String = "",
              offset: Int = 0,
              loader: Loader,
              persist: ((Int, Int, Double) -> Void)?) {
        let sameBook = isActive && self.bookID == bookID
        if isActive && !sameBook {
            flush()
        }
        self.bookID = bookID
        self.bookTitle = title
        self.chapterCount = max(chapterCount, 1)
        self.loader = loader
        self.persist = persist
        isActive = true
        if sameBook {
            return
        }
        self.chapterIndex = max(0, min(chapterIndex, self.chapterCount - 1))
        self.chapterTitle = chapterTitle
        self.offset = 0
        self.text = ""
        self.lastError = nil
        loadChapter(index: self.chapterIndex, offset: offset)
    }

    /// 主窗关闭后悬浮窗可继续；只在匹配当前书时重置。
    func close(ifBook bookID: String) {
        guard isActive, self.bookID == bookID else { return }
        flush()
        isActive = false
        loader = nil
        persist = nil
        self.bookID = ""
        self.text = ""
        self.offset = 0
        self.chapterIndex = 0
        self.chapterCount = 0
        self.chapterTitle = ""
    }

    // MARK: - 切章

    /// 切章。`landingAtEnd` 为 true 时落在章末（最后一页），用于向后翻页
    /// 跨过章边界时保持阅读连贯，而不是回到上一章开头。
    func goToChapter(_ index: Int, landingAtEnd: Bool = false) {
        guard isActive, chapterCount > 0 else { return }
        let target = min(max(index, 0), chapterCount - 1)
        guard target != chapterIndex || text.isEmpty else { return }
        flush()
        chapterIndex = target
        offset = 0
        loadChapter(index: target, offset: 0, landingAtEnd: landingAtEnd)
    }

    func nextChapter() { goToChapter(chapterIndex + 1) }
    func prevChapter(landingAtEnd: Bool = false) {
        goToChapter(chapterIndex - 1, landingAtEnd: landingAtEnd)
    }

    func retry() {
        guard isActive else { return }
        loadChapter(index: chapterIndex, offset: min(offset, max(0, text.count)))
    }

    private func loadChapter(index: Int, offset: Int, landingAtEnd: Bool = false) {
        guard let loader else { return }
        loadToken += 1
        let token = loadToken
        isLoading = true
        isChapterComplete = true
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let payload = try await loader.load(index)
                guard token == self.loadToken else { return }
                self.text = payload.text
                self.chapterTitle = payload.title
                self.chapterIndex = payload.index
                self.isChapterComplete = payload.complete
                self.offset = landingAtEnd
                    ? payload.text.count
                    : min(max(offset, 0), payload.text.count)
                self.isLoading = false
                self.lastUpdateSource = .main
                self.schedulePersist(immediate: true)
            } catch {
                guard token == self.loadToken else { return }
                self.isLoading = false
                if case NetworkError.cancelled = error { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - 进度

    /// 翻页只改章内偏移（BR-59）；两端同时翻页以最后操作时间为准。
    func updateOffset(_ newOffset: Int, from source: Source) {
        guard isActive else { return }
        let clamped = min(max(newOffset, 0), text.count)
        guard clamped != offset else { return }
        offset = clamped
        lastUpdateSource = source
        schedulePersist(immediate: false)
    }

    /// 睡眠唤醒 / 退出前强制写盘（BR-64、BR-66）。
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        guard isActive, let persist else { return }
        persist(chapterIndex, offset, bookPercent)
        lastPersistAt = Date()
    }

    /// 节流写盘：最多 1s 一次。
    private func schedulePersist(immediate: Bool) {
        if immediate {
            flush()
            return
        }
        if persistTask != nil { return }
        let elapsed = Date().timeIntervalSince(lastPersistAt)
        let delay = max(0, 1.0 - elapsed)
        persistTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            self.flush()
        }
    }
}
