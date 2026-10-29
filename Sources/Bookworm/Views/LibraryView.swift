import SwiftUI
import AppKit

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "标题"
    case dateAdded = "添加日期"
    case lastOpened = "最近打开"
    var id: String { rawValue }
}

private enum LibrarySheet: String, Identifiable {
    case onlineSearch
    case sourceManagement
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var openBooks: OpenBooks
    @ObservedObject private var sources = SourceRepository.shared
    @State private var search: String = ""
    @State private var sort: LibrarySort = .title
    // 封面大小写入偏好配置，下次启动沿用上次的取值。
    @AppStorage("library.cardSize") private var cardSize: Double = 180
    @State private var serverURL: String? = nil
    @State private var showingServerInfo: Bool = false
    /// 排序结果缓存；进度、扫描进度等高频更新不会触发全量重排。
    @State private var orderCache = LibraryOrderCache()
    /// 搜索面板与书源管理互斥，统一由一个枚举驱动。
    @State private var activeSheet: LibrarySheet?

    /// 排序后的条目。缓存里只存 id 顺序，这里再按 id 取 `library.items`
    /// 的最新值，保证阅读进度、封面等字段不会过期。
    private func visibleItems() -> [ComicItem] {
        let ids = orderCache.sortedIDs(items: library.items, search: search, sort: sort)
        var byID = [ComicItem.ID: ComicItem](minimumCapacity: library.items.count)
        for item in library.items { byID[item.id] = item }
        return ids.compactMap { byID[$0] }
    }

    var body: some View {
        let visible = visibleItems()
        VStack(spacing: 0) {
            header
            Divider()
            if visible.isEmpty {
                emptyState
            } else {
                grid(items: visible)
            }
            if library.isScanning {
                Divider()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(library.scanProgress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .onlineSearch:
                OnlineSearchView()
                    .environmentObject(library)
                    .environmentObject(openBooks)
            case .sourceManagement:
                SourceManagementView()
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookwormShowOnlineSearch)) { _ in
            activeSheet = sources.hasEnabledSource ? .onlineSearch : .sourceManagement
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookwormShowSourceManagement)) { _ in
            activeSheet = .sourceManagement
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.tint)
            Text("书库")
                .font(.title2.bold())

            if let folder = library.rootFolder {
                Text(folder.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            }

            Spacer()

            TextField("搜索…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Button("在线搜书") {
                activeSheet = .onlineSearch
            }
            .disabled(!sources.hasEnabledSource)
            .help(sources.hasEnabledSource
                  ? "在启用的在线书源里搜索"
                  : OnlineCopy.noSources)

            Picker("排序", selection: $sort) {
                ForEach(LibrarySort.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Slider(value: $cardSize, in: 120...280)
                .frame(width: 120)
                .help("封面大小")

            // 次级操作收进「更多」菜单，避免首行按钮堆砌。
            Menu {
                Button("书源管理") { activeSheet = .sourceManagement }
                Divider()
                Button(serverURL == nil ? "共享书库" : "停止共享书库") { toggleServer() }
                if let url = serverURL {
                    Button("复制共享地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                Divider()
                Button("重新扫描书库") { library.rescan() }
                    .disabled(library.isScanning)
                Button("更换书库文件夹") { library.promptForFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
            .popover(isPresented: $showingServerInfo) {
                serverInfoPopover
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            if library.isScanning {
                Text("正在扫描书库…")
                    .foregroundStyle(.secondary)
            } else if search.isEmpty {
                Text("此文件夹中没有找到漫画。")
                    .foregroundStyle(.secondary)
                Button("选择其他文件夹") { library.promptForFolder() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("没有与“\(search)”匹配的漫画。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(cardSize), maximum: CGFloat(cardSize) * 1.4), spacing: 24)]
    }

    private func grid(items: [ComicItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if search.isEmpty, !library.inProgress.isEmpty {
                    continueReadingShelf
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(items) { item in
                        LibraryCard(item: item, width: CGFloat(cardSize))
                            .onTapGesture(count: 2) { open(item) }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
            }
            .padding(24)
        }
        .background(BookwormBackground())
    }

    /// Horizontal shelf of in-progress books, newest activity first.
    /// Only shown when not searching — it's a "jump back in" affordance,
    /// not a search result.
    private var continueReadingShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                Text("继续阅读")
                    .font(.title3.bold())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(library.inProgress.prefix(15)) { item in
                        LibraryCard(item: item, width: 132)
                            .onTapGesture(count: 2) { open(item) }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.bottom, 4)
            }
            Divider()
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ComicItem) -> some View {
        Button("打开") { open(item) }
        if item.isOnline {
            if let name = SourceRepository.shared.source(id: item.sourceID ?? "")?.name {
                Button("查看来源：\(name)") { activeSheet = .sourceManagement }
            }
        } else {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        if item.format.isEbook {
            Button("在悬浮窗中打开") {
                openInFloating(item)
            }
        } else {
            Button("在悬浮窗中打开（仅文字书）") {}
                .disabled(true)
        }
        Divider()
        Button("标记为未读") {
            if item.isOnline {
                library.updateOnlineProgress(itemID: item.id,
                                             chapterIndex: 0,
                                             offset: 0,
                                             percent: 0)
            } else {
                library.updateProgress(itemID: item.id, page: 0, pageCount: item.pageCount)
            }
        }
        Divider()
        Button("从书架移除", role: .destructive) {
            if openBooks.openItemIDs.contains(item.id) {
                ReaderWindowController.shared.close(itemID: item.id)
            }
            library.removeItem(itemID: item.id)
        }
    }

    private func open(_ item: ComicItem) {
        openBooks.open(itemID: item.id, library: library)
    }

    /// 只把文字书装进悬浮窗，不打开主阅读窗口（BR-57）。
    private func openInFloating(_ item: ComicItem) {
        guard item.format.isEbook else { return }
        if item.isOnline {
            openOnlineInFloating(item)
            return
        }
        Task {
            do {
                let reader = try await Task.detached(priority: .userInitiated) {
                    try ArchiveFactory.makeReader(for: item)
                }.value
                let count = try reader.pageCount()
                guard count > 0 else { return }
                let start = max(0, min(item.lastReadPage, count - 1))
                let bookID = item.id.uuidString
                ReadingSession.shared.open(
                    bookID: bookID,
                    title: item.title,
                    chapterIndex: start,
                    chapterCount: count,
                    chapterTitle: reader.pageTitle(at: start) ?? "",
                    offset: 0,
                    loader: ReadingSession.Loader(load: { index in
                        guard index >= 0, index < count else {
                            throw ArchiveError.indexOutOfRange
                        }
                        let content = try reader.content(at: index)
                        return ChapterPayload(
                            index: index,
                            title: reader.pageTitle(at: index) ?? "第 \(index + 1) 节",
                            text: TextExtraction.plainText(from: content),
                            complete: true
                        )
                    }),
                    persist: { page, _, _ in
                        library.updateProgress(itemID: item.id, page: page, pageCount: count)
                    }
                )
                // 不指定模式：沿用上次的显示模式（含迷你模式）。
                FloatingPanelController.shared.show()
            } catch {
                presentFloatingError(error.localizedDescription)
            }
        }
    }

    /// 在线书没有本地文件，直接走本地解析会抛 `.unsupportedFormat`，
    /// 必须先建好目录与阅读会话再唤出悬浮窗（BR-52、BR-73）。
    private func openOnlineInFloating(_ item: ComicItem) {
        let session = ReadingSession.shared
        let bookID = item.id.uuidString
        if session.isActive, session.bookID == bookID {
            FloatingPanelController.shared.show()
            return
        }
        Task {
            let model = OnlineReaderModel(itemID: item.id, library: library)
            await model.start()
            if let message = model.indexError {
                presentFloatingError(message)
                return
            }
            FloatingPanelController.shared.show()
        }
    }

    private func presentFloatingError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法在悬浮窗中打开"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Server toggle

    private func toggleServer() {
        if serverURL != nil {
            BrowseServer.stop()
            serverURL = nil
            showingServerInfo = false
            return
        }
        do {
            let server = try BrowseServer.start(library: library)
            Task { @MainActor in
                try? await server.waitUntilReady()
                self.serverURL = server.displayURL
            }
            serverURL = server.displayURL
            showingServerInfo = true
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动服务器"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @ViewBuilder
    private var serverInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.circle.fill").foregroundStyle(.tint)
                Text("局域网共享").font(.headline)
            }
            if let url = serverURL {
                Text("在 Wi-Fi 内任意设备的浏览器中打开此网址：")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(url).font(.title3.monospaced())
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .help("复制")
                }
            }
            Text("仅共享图像类书籍（漫画 / 日漫 / PDF），电子书请留在应用内阅读。无密码保护——同一网络中的任何人都可访问。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("停止共享") { toggleServer() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct LibraryCard: View {
    let item: ComicItem
    let width: CGFloat
    @EnvironmentObject var library: LibraryStore
    @State private var thumbnail: NSImage?
    /// 当前已加载 / 正在加载的缩略图文件名，用于避免重复解码。
    @State private var thumbnailKey: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.18))
                            Image(systemName: "book.closed")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: width, height: width * 1.45)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottom) { progressBar }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay(alignment: .topLeading) { progressBadge }

                Text(item.format.displayName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) { onlineBadges }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if item.isOnline {
                    if let total = item.pageCount, total > 0 {
                        Text("第 \(min((item.lastReadChapter ?? 0) + 1, total)) / \(total) 章")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: item.progressFraction ?? 0)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    } else {
                        Text(sourceName ?? "在线")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else if let total = item.pageCount {
                    if item.lastReadPage > 0 {
                        Text("第 \(item.lastReadPage + 1) / \(total) 页")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(item.lastReadPage + 1),
                                     total: Double(max(total, 1)))
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    } else {
                        Text("共 \(total) 页")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(item.format.displayName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onAppear(perform: loadThumbnail)
        .onChange(of: item.thumbnailFileName) { loadThumbnail() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    /// Corner badge: a green check once finished, otherwise a "% read"
    /// pill for books in progress. Nothing for untouched books.
    @ViewBuilder
    private var progressBadge: some View {
        if item.isFinished {
            Image(systemName: "checkmark")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(5)
                .background(Color.green, in: Circle())
                .padding(6)
        } else if let frac = item.progressFraction, hasProgress {
            Text("\(Int((frac * 100).rounded()))%")
                .font(.caption2.bold().monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
    }

    private var hasProgress: Bool {
        item.isOnline ? (item.bookPercent ?? 0) > 0 : item.lastReadPage > 0
    }

    /// 在线书左上/右上徽标：来源名与健康度状态点（07 §2）。
    @ViewBuilder
    private var onlineBadges: some View {
        if item.isOnline {
            HStack(spacing: 4) {
                if let name = sourceName {
                    Text(name.count > 8 ? String(name.prefix(8)) + "…" : name)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                if let health = sourceHealth, health < 0.3 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .help(OnlineCopy.sourceUnhealthy)
                }
            }
            .padding(6)
        }
    }

    private var sourceName: String? {
        guard let sid = item.sourceID else { return nil }
        return SourceRepository.shared.source(id: sid)?.name
    }

    private var sourceHealth: Double? {
        guard let sid = item.sourceID else { return nil }
        return SourceRepository.shared.source(id: sid)?.healthScore
    }

    /// Thin progress fill along the bottom edge of the cover, mirroring
    /// the percentage badge for an at-a-glance scan down the grid.
    @ViewBuilder
    private var progressBar: some View {
        if let frac = item.progressFraction, hasProgress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.black.opacity(0.35))
                    Rectangle()
                        .fill(item.isFinished ? Color.green : Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(frac))
                }
            }
            .frame(height: 4)
        }
    }

    /// 缩略图优先命中共享内存缓存；未命中时在后台线程解码（ImageIO 立即解码），
    /// 再回主线程赋值，滚动回来不会重复解码。
    private func loadThumbnail() {
        guard let url = library.thumbnailURL(for: item) else {
            loadTask?.cancel()
            loadTask = nil
            thumbnailKey = nil
            thumbnail = nil
            return
        }
        let key = url.lastPathComponent
        // 同一个文件且已解码完成时直接复用，不再触发读盘。
        if key == thumbnailKey, thumbnail != nil { return }
        loadTask?.cancel()
        thumbnailKey = key

        if let cached = LibraryStore.thumbnailCache.object(forKey: key as NSString) {
            thumbnail = cached
            loadTask = nil
            return
        }

        thumbnail = nil
        loadTask = Task {
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ImageDecoder.image(from: data)
            }.value
            guard let image else { return }
            LibraryStore.thumbnailCache.setObject(image,
                                                  forKey: key as NSString,
                                                  cost: LibraryStore.thumbnailCost(image))
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}

/// 网格的排序缓存：只在影响筛选 / 顺序的结构性字段变化时重排一次。
/// 阅读进度、扫描进度这类高频更新会命中缓存，不再全量排序。
private final class LibraryOrderCache {
    private struct Signature: Equatable {
        let search: String
        let sortRaw: String
        let count: Int
        let hash: Int
    }

    private var signature: Signature?
    private var ids: [ComicItem.ID] = []

    func sortedIDs(items: [ComicItem], search: String, sort: LibrarySort) -> [ComicItem.ID] {
        let sig = Self.signature(items: items, search: search, sort: sort)
        if sig == signature { return ids }

        var base = items
        if !search.isEmpty {
            base = items.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .title:
            base.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAdded:
            base.sort { $0.dateAdded > $1.dateAdded }
        case .lastOpened:
            base.sort { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        }
        ids = base.map(\.id)
        signature = sig
        return ids
    }

    /// 只把影响筛选和排序的字段算进签名：标题、日期、最近打开等；
    /// 进度、页数、封面之外的字段变化不会让缓存失效。
    private static func signature(items: [ComicItem],
                                  search: String,
                                  sort: LibrarySort) -> Signature {
        var hasher = Hasher()
        hasher.combine(search)
        hasher.combine(sort.rawValue)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.title)
            switch sort {
            case .title:
                break
            case .dateAdded:
                hasher.combine(item.dateAdded)
            case .lastOpened:
                hasher.combine(item.lastOpened)
            }
        }
        return Signature(search: search,
                         sortRaw: sort.rawValue,
                         count: items.count,
                         hash: hasher.finalize())
    }
}

extension Notification.Name {
    static let bookwormShowOnlineSearch = Notification.Name("Bookworm.ShowOnlineSearch")
    static let bookwormShowSourceManagement = Notification.Name("Bookworm.ShowSourceManagement")
}
