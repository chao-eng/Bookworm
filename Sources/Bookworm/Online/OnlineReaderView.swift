import SwiftUI
import AppKit
import Combine

/// 在线阅读窗模型（UC-07、UC-08）：目录加载、会话注册、预取。
@MainActor
final class OnlineReaderModel: ObservableObject {
    let itemID: ComicItem.ID
    let library: LibraryStore

    @Published private(set) var bookID: String = ""
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var sourceName: String = ""
    @Published private(set) var isLoadingIndex = true
    @Published private(set) var indexError: String?
    @Published private(set) var isIndexComplete = true
    @Published var fontSize: Double {
        didSet {
            let clamped = min(30, max(13, fontSize))
            if clamped != fontSize { fontSize = clamped; return }
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
        }
    }

    /// 整章排版缓存：翻页与正文视图共用，文本/尺寸/排版参数不变时直接复用。
    let pageCache = OnlinePageCache()

    private var source: BookSource?
    private var started = false

    private enum Keys {
        static let fontSize = "Bookworm.online.fontSize"
    }

    init(itemID: ComicItem.ID, library: LibraryStore) {
        self.itemID = itemID
        self.library = library
        let saved = UserDefaults.standard.double(forKey: Keys.fontSize)
        self.fontSize = (saved >= 13 && saved <= 30) ? saved : 19
    }

    // MARK: - 启动

    func start() async {
        guard !started else { return }
        started = true

        guard let item = library.item(withID: itemID), item.isOnline else {
            indexError = "这本书已经不在书架里了"
            isLoadingIndex = false
            return
        }
        bookID = item.id.uuidString

        guard let sourceID = item.sourceID,
              let source = SourceRepository.shared.source(id: sourceID) else {
            indexError = OnlineShelfError.sourceMissing.errorDescription
            isLoadingIndex = false
            return
        }
        self.source = source
        sourceName = source.name

        if let index = ChapterService.shared.loadIndex(bookID: bookID),
           index.sourceFingerprint == SourceRepository.fingerprint(of: source) {
            apply(index: index, item: item)
            isLoadingIndex = false
        } else {
            await rebuildIndex(force: false)
        }
    }

    /// 规则变更或目录不完整时可由用户触发重建。
    func rebuildIndex(force: Bool = true) async {
        guard let item = library.item(withID: itemID),
              let source,
              let detail = item.detailURL,
              let detailURL = URL(string: detail) else {
            indexError = OnlineShelfError.sourceMissing.errorDescription
            isLoadingIndex = false
            return
        }
        isLoadingIndex = true
        indexError = nil
        do {
            let index = try await ChapterService.shared.buildIndex(bookID: bookID,
                                                                   detailURL: detailURL,
                                                                   source: source,
                                                                   force: force)
            guard !index.chapters.isEmpty else { throw OnlineShelfError.emptyTOC }
            apply(index: index, item: item)
        } catch {
            indexError = error.localizedDescription
        }
        isLoadingIndex = false
    }

    private func apply(index: ChapterIndex, item: ComicItem) {
        chapters = index.chapters
        isIndexComplete = index.isComplete
        guard let source else { return }
        let start = min(max(item.lastReadChapter ?? 0, 0), max(index.chapters.count - 1, 0))
        openSession(start: start, offset: item.lastChapterOffset ?? 0, item: item, source: source)
    }

    private func openSession(start: Int,
                             offset: Int,
                             item: ComicItem,
                             source: BookSource) {
        let chapters = self.chapters
        let bookID = self.bookID
        ReadingSession.shared.open(bookID: bookID,
                                   title: item.title,
                                   chapterIndex: start,
                                   chapterCount: chapters.count,
                                   chapterTitle: chapters.isEmpty ? "" : chapters[start].title,
                                   offset: offset,
                                   loader: ReadingSession.Loader(load: { index in
            guard index >= 0, index < chapters.count else {
                throw RuleError.empty("章节")
            }
            return try await ChapterService.shared.payload(bookID: bookID,
                                                          chapter: chapters[index],
                                                          source: source)
        }), persist: { [library] chapter, offset, percent in
            library.updateOnlineProgress(itemID: item.id,
                                         chapterIndex: chapter,
                                         offset: offset,
                                         percent: percent)
        })
        prefetch(around: start)
    }

    func prefetch(around index: Int) {
        guard let source else { return }
        ChapterService.shared.prefetch(bookID: bookID,
                                       chapters: chapters,
                                       around: index,
                                       source: source)
    }

    func close() {
        guard !bookID.isEmpty else { return }
        ChapterService.shared.cancelPrefetch()
        // 悬浮窗还在这本书上时保留会话，让另一端继续读（UC-15）。
        if FloatingPanelController.shared.isPanelVisible,
           ReadingSession.shared.bookID == bookID {
            return
        }
        ReadingSession.shared.close(ifBook: bookID)
    }

    func retry() {
        if indexError != nil {
            Task { await rebuildIndex(force: true) }
        } else {
            ReadingSession.shared.retry()
        }
    }
}

/// 整章分页缓存。键包含正文、容器尺寸、字号/行距与字体，
/// 命中时直接返回上次的页表；仅当这些因素变化才重新交给 TextPaginator。
/// 只在主线程使用。
final class OnlinePageCache {
    struct Key: Hashable {
        let text: String
        let size: CGSize
        let fontSize: CGFloat
        let lineSpacing: CGFloat
        let fontID: String

        init(text: String,
             size: CGSize,
             fontSize: CGFloat,
             lineSpacing: CGFloat,
             fontID: String = EbookFont.serif.rawValue) {
            self.text = text
            self.size = size
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            self.fontID = fontID
        }
    }

    private var storage: [Key: [TextPage]] = [:]
    private var order: [Key] = []
    /// 保留最近几种排版组合（主窗与正文视图的尺寸可能略有差异）。
    private let capacity = 3

    /// 取页表；`cacheable` 为 false（如尺寸尚未确定）时只排版不入缓存。
    func pages(for key: Key, cacheable: Bool = true) -> [TextPage] {
        guard cacheable, key.size.width > 0, key.size.height > 0 else {
            return Self.layout(key)
        }
        if let cached = storage[key] {
            return cached
        }
        let result = Self.layout(key)
        // 换章后旧文本的页表不再复用，清掉避免占内存。
        if let currentText = order.last?.text, currentText != key.text {
            storage.removeAll()
            order.removeAll()
        }
        storage[key] = result
        order.append(key)
        if order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
        return result
    }

    private static func layout(_ key: Key) -> [TextPage] {
        let font = (EbookFont(rawValue: key.fontID) ?? .serif).nsFont(size: key.fontSize)
        return TextPaginator.paginate(text: key.text,
                                      fontSize: key.fontSize,
                                      lineSpacing: key.lineSpacing,
                                      size: key.size,
                                      font: font)
    }
}

@MainActor
final class OnlineReaderModelHolder: ObservableObject {
    @Published var value: OnlineReaderModel?
    private var innerSubscription: AnyCancellable?

    func install(_ model: OnlineReaderModel) {
        value = model
        innerSubscription = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - 阅读窗

struct OnlineReaderView: View {
    let itemID: ComicItem.ID

    var body: some View {
        OnlineReaderHost(itemID: itemID)
    }
}

private struct OnlineReaderHost: View {
    let itemID: ComicItem.ID

    @EnvironmentObject private var library: LibraryStore
    @StateObject private var holder = OnlineReaderModelHolder()
    @ObservedObject private var session = ReadingSession.shared
    @ObservedObject private var ebook = EbookSettings.shared

    @State private var showingTOC = false
    @State private var pageAreaSize: CGSize = .zero
    /// 底部进度条默认隐藏，鼠标移到底部区域时才淡入，与本地阅读窗口一致。
    @State private var bottomBarHovered = false

    private var model: OnlineReaderModel? { holder.value }

    var body: some View {
        // 与本地阅读窗口一致：正文铺满，底栏做成叠在最下方的浮层，
        // 默认隐藏、鼠标移上去才淡入，既不遮挡正文也不占高度。
        HStack(spacing: 0) {
            if showingTOC {
                tocSidebar
                    .frame(width: 250)
                Divider()
            }
            mainArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let model, !model.isLoadingIndex {
                bottomBar(model)
                    .opacity(bottomBarHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: bottomBarHovered)
                    .onHover { bottomBarHovered = $0 }
            }
        }
        .background(ebook.theme.windowBackground.ignoresSafeArea())
        .toolbar { toolbarContent }
        .background(KeyEventHandlingView(onKeyDown: { handleKey($0) }))
        .onAppear {
            if holder.value == nil {
                let model = OnlineReaderModel(itemID: itemID, library: library)
                holder.install(model)
                Task { await model.start() }
            }
        }
        .onDisappear {
            holder.value?.close()
        }
        .onChange(of: session.chapterIndex) { _, newValue in
            holder.value?.prefetch(around: newValue)
        }
    }

    // MARK: 主区域

    private var mainArea: some View {
        Group {
            if let model, model.isLoadingIndex {
                ProgressView("正在读取目录…")
                    .controlSize(.large)
            } else if let model, let error = model.indexError {
                errorState(title: "目录没读出来",
                           message: error,
                           retry: { model.retry() })
            } else if session.isLoading, session.text.isEmpty {
                ProgressView("正在加载第 \(session.chapterIndex + 1) 章…")
                    .controlSize(.large)
            } else if let error = session.lastError, session.text.isEmpty {
                errorState(title: "这一章没加载出来",
                           message: error,
                           retry: { session.retry() })
            } else {
                VStack(spacing: 0) {
                    if !session.isChapterComplete {
                        Text(OnlineCopy.chapterIncomplete)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                    }
                    OnlinePagedTextView(session: session,
                                        fontSize: model?.fontSize ?? 19,
                                        font: ebook.font,
                                        theme: ebook.theme,
                                        lineSpacing: lineSpacing(fontSize: model?.fontSize ?? 19),
                                        pageCache: model?.pageCache,
                                        areaSize: $pageAreaSize,
                                        onTurn: { turnPage($0) })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ebook.theme.textColor)
    }

    /// 与本地阅读窗口一致的额外行距：按「行高 = 字号 × 倍数」换算。
    private func lineSpacing(fontSize: Double) -> CGFloat {
        ebook.font.extraLineSpacing(size: CGFloat(fontSize), multiplier: ebook.lineSpacing)
    }

    private func errorState(title: String, message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(title).font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: 目录

    private var tocSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录")
                    .font(.headline)
                    .foregroundStyle(ebook.theme.textColor)
                Spacer()
                if let model, !model.isIndexComplete {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .help("目录可能不完整")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(holder.value?.chapters ?? []) { chapter in
                            let isCurrent = chapter.index == session.chapterIndex
                            Button {
                                session.goToChapter(chapter.index)
                            } label: {
                                Text(chapter.title)
                                    .font(.system(size: 12,
                                                  weight: isCurrent ? .semibold : .regular))
                                    // 主题是应用内自选配色，系统外观可能仍是浅色，
                                    // 因此不能用 Color.primary（深色主题下会变黑看不见）。
                                    .foregroundStyle(isCurrent
                                                     ? Color.accentColor
                                                     : ebook.theme.textColor)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, CGFloat((chapter.level ?? 0) * 12) + 14)
                                    .padding(.trailing, 12)
                                    .padding(.vertical, 6)
                                    .background(isCurrent
                                                ? Color.accentColor.opacity(0.18)
                                                : Color.clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(chapter.index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // 打开目录时直接停在当前章节，而不是从第一章开始。
                .onAppear { scrollTOC(proxy) }
                .onChange(of: session.chapterIndex) { _, _ in scrollTOC(proxy) }
            }
        }
        .background(ebook.theme.windowBackground)
    }

    /// 把目录滚动到正在阅读的章节并居中。LazyVStack 的行在首次布局后才存在，
    /// 延后一拍再滚动才能命中。
    private func scrollTOC(_ proxy: ScrollViewProxy) {
        let target = session.chapterIndex
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    // MARK: 工具栏与底栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                showingTOC.toggle()
            } label: {
                Image(systemName: "list.bullet")
            }
            .help("目录")

            Button {
                session.prevChapter()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("上一章")
            .disabled(session.chapterIndex <= 0)

            Button {
                session.nextChapter()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("下一章")
            .disabled(session.chapterIndex + 1 >= session.chapterCount)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let model {
                // 与本地阅读窗口同一套「Aa」菜单：字号、字体、行距、主题。
                Menu {
                    textFormatMenu(model: model)
                } label: {
                    Image(systemName: "textformat")
                }
                .help("文本格式")
            }

            Button {
                Task { await holder.value?.rebuildIndex(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新读取目录")
        }
    }

    @ViewBuilder
    private func textFormatMenu(model: OnlineReaderModel) -> some View {
        Section("字号") {
            Button {
                model.fontSize = max(13, model.fontSize - 1)
            } label: {
                Label("减小", systemImage: "textformat.size.smaller")
            }
            Button {
                model.fontSize = min(30, model.fontSize + 1)
            } label: {
                Label("增大", systemImage: "textformat.size.larger")
            }
            Text("\(Int(model.fontSize)) pt")
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

    private func bottomBar(_ model: OnlineReaderModel) -> some View {
        HStack(spacing: 10) {
            Text(session.chapterTitle.isEmpty ? "第 \(session.chapterIndex + 1) 章" : session.chapterTitle)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.85))
            if !model.sourceName.isEmpty {
                Text(model.sourceName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text("第 \(session.chapterIndex + 1) / \(max(session.chapterCount, 1)) 章")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
            Text("\(Int((session.bookPercent * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // 与本地阅读窗口底栏同样使用半透明深色背景，主题切换时观感一致。
        .background(Color.black.opacity(0.55))
    }

    // MARK: 翻页与按键

    private func turnPage(_ delta: Int) {
        guard let model, !session.text.isEmpty, pageAreaSize.width > 50 else { return }
        let pages = model.pageCache.pages(for: OnlinePageCache.Key(text: session.text,
                                                                   size: pageAreaSize,
                                                                   fontSize: CGFloat(model.fontSize),
                                                                   lineSpacing: lineSpacing(fontSize: model.fontSize),
                                                                   fontID: ebook.font.rawValue))
        guard !pages.isEmpty else { return }
        let index = TextPaginator.pageIndex(for: session.offset, in: pages)
        let target = index + delta
        if target >= 0, target < pages.count {
            session.updateOffset(pages[target].range.location, from: .main)
        } else if delta > 0 {
            session.nextChapter()
        } else {
            // 跨章回退落在上一章末页，保持翻页连贯。
            session.prevChapter(landingAtEnd: true)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let intent = ReaderNavigation.intent(for: event, context: .init()) else { return false }
        switch intent {
        case .pageForward:
            turnPage(1)
        case .pageBackward:
            turnPage(-1)
        case .chapterForward:
            session.nextChapter()
        case .chapterBackward:
            session.prevChapter()
        case .toStart:
            session.goToChapter(0)
        case .toEnd:
            session.goToChapter(max(0, session.chapterCount - 1))
        }
        return true
    }
}

// MARK: - 分页正文

struct OnlinePagedTextView: View {
    @ObservedObject var session: ReadingSession
    let fontSize: Double
    /// 与本地阅读窗口共享同一套排版设置。
    let font: EbookFont
    let theme: EbookTheme
    let lineSpacing: CGFloat
    /// 与主窗翻页共用同一份页表缓存。
    let pageCache: OnlinePageCache?
    /// 把本视图真实的排版区域回传给主窗，保证点按/按键翻页用同一份页表。
    @Binding var areaSize: CGSize
    let onTurn: (Int) -> Void

    @State private var pages: [TextPage] = []
    @State private var pagesKey: OnlinePageCache.Key?

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(120, geo.size.width - 64),
                              height: max(120, geo.size.height - 32))
            let key = OnlinePageCache.Key(text: session.text,
                                          size: size,
                                          fontSize: CGFloat(fontSize),
                                          lineSpacing: lineSpacing,
                                          fontID: font.rawValue)
            // 首次布局尺寸为 0 时只排版不写缓存。
            let cacheable = geo.size.width > 0 && geo.size.height > 0
            Group {
                if pagesKey == key, let index = currentIndex, index < pages.count {
                    // 用 TextKit 按分页时同一套属性绘制，保证「分页高度 == 实际
                    // 文字高度」，不会在页底留下多余空白。
                    OnlineTextPageView(text: pages[index].text,
                                       font: font,
                                       fontSize: CGFloat(fontSize),
                                       lineSpacing: lineSpacing,
                                       theme: theme)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let third = geo.size.width / 3
                if location.x < third {
                    onTurn(-1)
                } else if location.x > geo.size.width - third {
                    onTurn(1)
                }
            }
            .task(id: key) {
                let result = pageCache?.pages(for: key, cacheable: cacheable)
                    ?? TextPaginator.paginate(text: key.text,
                                              fontSize: key.fontSize,
                                              lineSpacing: key.lineSpacing,
                                              size: key.size,
                                              font: font.nsFont(size: key.fontSize))
                pages = result
                pagesKey = key
                if areaSize != size { areaSize = size }
            }
        }
    }

    private var currentIndex: Int? {
        guard !pages.isEmpty else { return nil }
        return TextPaginator.pageIndex(for: session.offset, in: pages)
    }
}

/// 单页正文的 TextKit 视图。SwiftUI `Text` 的行高/段间距与 TextKit 分页口径
/// 不一致，会让每页底部残留空白；这里直接复用 TextKit（与分页相同的字体、
/// 行距、容器宽度）绘制，分页结果与显示结果完全对齐。
private struct OnlineTextPageView: NSViewRepresentable {
    let text: String
    let font: EbookFont
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let theme: EbookTheme

    func makeNSView(context: Context) -> TextPageNSView { TextPageNSView() }

    func updateNSView(_ view: TextPageNSView, context: Context) {
        view.update(text: text,
                    font: font.nsFont(size: fontSize),
                    lineSpacing: lineSpacing,
                    theme: theme)
    }
}

private final class TextPageNSView: NSView {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)

    private var pageText = ""
    private var fontKey = ""
    private var font = NSFont.systemFont(ofSize: 19)
    private var lineSpacing: CGFloat = 0
    private var theme: EbookTheme = .light

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
    }

    required init?(coder: NSCoder) { nil }

    func update(text: String, font: NSFont, lineSpacing: CGFloat, theme: EbookTheme) {
        let key = "\(font.fontName)|\(font.pointSize)"
        guard text != pageText || key != fontKey
                || lineSpacing != self.lineSpacing || theme != self.theme else { return }
        pageText = text
        fontKey = key
        self.font = font
        self.lineSpacing = lineSpacing
        self.theme = theme
        applyText()
    }

    override func layout() {
        super.layout()
        guard container.size != bounds.size else { return }
        container.size = bounds.size
        needsDisplay = true
    }

    private func applyText() {
        var attributes = TextPaginator.attributes(font: font, lineSpacing: lineSpacing)
        attributes[.foregroundColor] = theme.nsTextColor
        storage.setAttributedString(NSAttributedString(string: pageText, attributes: attributes))
        container.size = bounds.size
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard container.size.width > 0, container.size.height > 0 else { return }
        let glyphRange = layoutManager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return }
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }
}
