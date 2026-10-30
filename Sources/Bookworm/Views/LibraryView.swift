import SwiftUI
import AppKit

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "标题"
    case dateAdded = "添加日期"
    case lastOpened = "最近打开"
    var id: String { rawValue }
}

/// 侧边栏分类筛选。
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case inProgress = "继续阅读"
    case unread = "未读"
    case finished = "已读完"
    case ebooks = "电子书"
    case comics = "漫画"
    case pdf = "PDF"
    case online = "在线书籍"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all:        return "books.vertical"
        case .inProgress: return "clock.arrow.circlepath"
        case .unread:     return "circle"
        case .finished:   return "checkmark.circle"
        case .ebooks:     return "book.closed"
        case .comics:     return "photo.on.rectangle.angled"
        case .pdf:        return "doc.richtext"
        case .online:     return "globe"
        }
    }
}

/// 书架统一的浅色主题取值，避免颜色散落在各视图里。
private enum LibraryPalette {
    static let content = Color.white
    static let hairline = Color.black.opacity(0.10)
    static let divider = Color.black.opacity(0.12)
    static let cardBorder = Color.black.opacity(0.10)
    static let sidebarTop = Color(red: 0.949, green: 0.953, blue: 0.965)
    static let sidebarBottom = Color(red: 0.929, green: 0.933, blue: 0.953)
    static let sidebarWarm = Color(red: 0.965, green: 0.914, blue: 0.937)
}

/// 是否有阅读进度：在线书看百分比，本地书看已读到第几页。
private func hasReadingProgress(_ item: ComicItem) -> Bool {
    item.isOnline ? (item.bookPercent ?? 0) > 0 : item.lastReadPage > 0
}

/// 侧边栏毛玻璃背景，让窗口背后的桌面透出淡淡一层。
private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 侧边栏行：图标 + 文字，选中高亮，悬停淡灰底。
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    var isSelected: Bool = false
    var isDisabled: Bool = false
    var helpText: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.16)
                          : (hovering && !isDisabled ? Color.black.opacity(0.04) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(helpText ?? title)
    }
}

/// 「…」popover 里的操作项，保持与侧边栏一致的轻量样式。
private struct MoreMenuItem: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering && !isDisabled ? Color.black.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }
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
    @State private var filter: LibraryFilter = .all
    @State private var showingMoreMenu = false

    /// 排序后的条目。缓存里只存 id 顺序，这里再按 id 取 `library.items`
    /// 的最新值，保证阅读进度、封面等字段不会过期。
    private func visibleItems() -> [ComicItem] {
        let ids = orderCache.sortedIDs(items: library.items,
                                       search: search,
                                       sort: sort,
                                       filter: filter)
        var byID = [ComicItem.ID: ComicItem](minimumCapacity: library.items.count)
        for item in library.items { byID[item.id] = item }
        return ids.compactMap { byID[$0] }
    }

    var body: some View {
        let visible = visibleItems()
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
            Rectangle()
                .fill(LibraryPalette.hairline)
                .frame(width: 1)
            content(visible: visible)
        }
        // 隐藏标题栏后内容延伸到红绿灯区域，顶部留白由各区域自行控制。
        .ignoresSafeArea(edges: .top)
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

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 隐藏标题栏后窗口红绿灯覆盖在侧边栏顶部，搜索框下移避让。
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 38)
                .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Bookworm")
                    SidebarRow(title: "在线搜书",
                               systemImage: "magnifyingglass.circle",
                               isDisabled: !sources.hasEnabledSource,
                               helpText: sources.hasEnabledSource
                                     ? "在启用的在线书源里搜索"
                                     : OnlineCopy.noSources) {
                        activeSheet = .onlineSearch
                    }
                    SidebarRow(title: "书源管理",
                               systemImage: "square.stack.3d.up") {
                        activeSheet = .sourceManagement
                    }

                    sectionHeader("书库")
                    ForEach(LibraryFilter.allCases) { item in
                        SidebarRow(title: item.rawValue,
                                   systemImage: item.systemImage,
                                   isSelected: filter == item) { filter = item }
                    }

                    sectionHeader("书库位置")
                    folderRow
                    SidebarRow(title: "更换书库文件夹",
                               systemImage: "folder") { library.promptForFolder() }
                    SidebarRow(title: "重新扫描书库",
                               systemImage: "arrow.clockwise",
                               isDisabled: library.isScanning) { library.rescan() }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .background {
            SidebarVisualEffect()
                .overlay {
                    ZStack {
                        LinearGradient(colors: [LibraryPalette.sidebarTop,
                                                LibraryPalette.sidebarBottom],
                                       startPoint: .top, endPoint: .bottom)
                        RadialGradient(colors: [LibraryPalette.sidebarWarm.opacity(0.45), .clear],
                                       center: UnitPoint(x: 0.05, y: 1.0),
                                       startRadius: 0,
                                       endRadius: 420)
                    }
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(library.rootFolder?.lastPathComponent ?? "未选择书库")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .help(library.rootFolder?.path ?? "未选择书库文件夹")
    }

    // MARK: - 内容区

    private func content(visible: [ComicItem]) -> some View {
        VStack(spacing: 0) {
            titleRow
            Rectangle()
                .fill(LibraryPalette.divider)
                .frame(height: 1)
                .padding(.horizontal, 24)

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
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }

            Text("\(visible.count) 本书")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .background(LibraryPalette.content)
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            Text(filter.rawValue)
                .font(.system(size: 30, weight: .bold))

            Spacer()

            // 「继续阅读」始终按最近阅读排序，排序选项在此分类下无效，直接隐藏避免误导。
            if filter != .inProgress {
                Picker("排序", selection: $sort) {
                    ForEach(LibrarySort.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
            }

            HStack(spacing: 6) {
                Image(systemName: "square.resize")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $cardSize, in: 120...280)
                    .frame(width: 100)
            }
            .help("封面大小")

            Button {
                showingMoreMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(LibraryPalette.content))
                    .overlay(Circle().strokeBorder(LibraryPalette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("更多操作")
            .popover(isPresented: $showingMoreMenu, arrowEdge: .bottom) {
                moreMenu
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                MoreMenuItem(title: "书源管理", systemImage: "square.stack.3d.up") {
                    showingMoreMenu = false
                    activeSheet = .sourceManagement
                }
                MoreMenuItem(title: serverURL == nil ? "共享书库" : "停止共享书库",
                             systemImage: "wifi") {
                    toggleServer()
                }
                if serverURL != nil {
                    MoreMenuItem(title: "复制共享地址", systemImage: "doc.on.doc") {
                        copyServerURL()
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MoreMenuItem(title: "重新扫描书库",
                             systemImage: "arrow.clockwise",
                             isDisabled: library.isScanning) {
                    showingMoreMenu = false
                    library.rescan()
                }
                MoreMenuItem(title: "更换书库文件夹", systemImage: "folder") {
                    showingMoreMenu = false
                    library.promptForFolder()
                }
            }

            if showingServerInfo, let url = serverURL {
                Divider()
                serverInfoContent(url: url)
            }
        }
        .padding(16)
        .frame(width: 280)
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
            } else if !search.isEmpty {
                Text("没有与“\(search)”匹配的书籍。")
                    .foregroundStyle(.secondary)
            } else if filter != .all {
                // 书库里有书、只是当前分类为空，此时不应引导用户更换文件夹。
                Text("“\(filter.rawValue)”分类下还没有书籍。")
                    .foregroundStyle(.secondary)
            } else {
                Text("此文件夹中没有找到书籍。")
                    .foregroundStyle(.secondary)
                Button("选择其他文件夹") { library.promptForFolder() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columns: [GridItem] {
        // 列宽固定为封面宽度：列宽一旦大于卡片，卡片左对齐后会在每列右侧多出空白，视觉上就像书间距被放大。
        [GridItem(.adaptive(minimum: CGFloat(cardSize), maximum: CGFloat(cardSize)), spacing: 28)]
    }

    private func grid(items: [ComicItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(items) { item in
                    LibraryCard(item: item, width: CGFloat(cardSize)) {
                        menuItems(for: item)
                    }
                    .onTapGesture(count: 2) { open(item) }
                    .contextMenu { menuItems(for: item) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
    }

    /// 右键菜单与卡片右下角「•••」共用同一份菜单项。
    @ViewBuilder
    private func menuItems(for item: ComicItem) -> some View {
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

    private func copyServerURL() {
        guard let url = serverURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @ViewBuilder
    private func serverInfoContent(url: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.circle.fill").foregroundStyle(.tint)
                Text("局域网共享").font(.headline)
            }
            Text("在 Wi-Fi 内任意设备的浏览器中打开此网址：")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(url).font(.callout.monospaced())
                    .textSelection(.enabled)
                Button {
                    copyServerURL()
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("复制")
            }
            Text("仅共享图像类书籍（漫画 / 日漫 / PDF），电子书请留在应用内阅读。无密码保护——同一网络中的任何人都可访问。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LibraryCard<MenuContent: View>: View {
    let item: ComicItem
    let width: CGFloat
    let menuContent: MenuContent
    @EnvironmentObject var library: LibraryStore
    @State private var thumbnail: NSImage?
    /// 当前已加载 / 正在加载的缩略图文件名，用于避免重复解码。
    @State private var thumbnailKey: String?
    @State private var loadTask: Task<Void, Never>?

    init(item: ComicItem, width: CGFloat, @ViewBuilder menuContent: () -> MenuContent) {
        self.item = item
        self.width = width
        self.menuContent = menuContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.12))
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // 没有封面时把书名放在封面中心，避免只留一个空框。
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(12)
                }
            }
            .frame(width: width, height: width * 1.45)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(LibraryPalette.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)

            // 参考图样式：封面下方只保留进度文字与「•••」菜单，固定行高保证网格不错位。
            HStack(spacing: 0) {
                Text(progressLabel)
                    .font(.system(size: 11, design: .default).monospacedDigit())
                    .foregroundStyle(item.isFinished ? Color.green : .secondary)
                    .lineLimit(1)
                    .help(item.title)
                Spacer(minLength: 0)
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
            }
            .frame(width: width, height: 16)
        }
        .contentShape(Rectangle())
        .onAppear(perform: loadThumbnail)
        .onChange(of: item.thumbnailFileName) { loadThumbnail() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    /// 底部进度文案：已读完 / 百分比 / 未读。
    private var progressLabel: String {
        if item.isFinished { return "已读完" }
        if let frac = item.progressFraction, hasReadingProgress(item) {
            return "\(Int((frac * 100).rounded()))%"
        }
        return "未读"
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
        let filterRaw: String
        let count: Int
        let hash: Int
    }

    private var signature: Signature?
    private var ids: [ComicItem.ID] = []

    func sortedIDs(items: [ComicItem],
                   search: String,
                   sort: LibrarySort,
                   filter: LibraryFilter) -> [ComicItem.ID] {
        let sig = Self.signature(items: items, search: search, sort: sort, filter: filter)
        if sig == signature { return ids }

        var base = items.filter { matches($0, filter: filter) }
        if !search.isEmpty {
            base = base.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        switch filter {
        case .inProgress:
            // 「继续阅读」按最近阅读时间倒序，忽略顶部排序选项。
            base.sort { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        default:
            switch sort {
            case .title:
                base.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case .dateAdded:
                base.sort { $0.dateAdded > $1.dateAdded }
            case .lastOpened:
                base.sort { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            }
        }
        ids = base.map(\.id)
        signature = sig
        return ids
    }

    private func matches(_ item: ComicItem, filter: LibraryFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .inProgress:
            return item.isInProgress
        case .unread:
            return !hasReadingProgress(item)
        case .finished:
            return item.isFinished
        case .ebooks:
            return item.format.isEbook && !item.isOnline
        case .comics:
            return item.format.isImageBased && item.format != .pdf
        case .pdf:
            return item.format == .pdf
        case .online:
            return item.isOnline
        }
    }

    /// 只把影响筛选和排序的字段算进签名：标题、日期、最近打开等；
    /// 进度、页数、封面之外的字段变化不会让缓存失效。
    private static func signature(items: [ComicItem],
                                  search: String,
                                  sort: LibrarySort,
                                  filter: LibraryFilter) -> Signature {
        var hasher = Hasher()
        hasher.combine(search)
        hasher.combine(sort.rawValue)
        hasher.combine(filter.rawValue)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.title)
            // 阅读状态类筛选依赖进度字段，必须计入签名，否则读完一本书后列表中不会移出。
            if filter == .inProgress || filter == .unread || filter == .finished {
                hasher.combine(item.lastReadPage)
                hasher.combine(item.pageCount)
                hasher.combine(item.bookPercent)
            }
            // 「继续阅读」强制按最近打开倒序，与实际 sort 取值无关，同样要计入签名。
            if filter == .inProgress {
                hasher.combine(item.lastOpened)
            }
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
                         filterRaw: filter.rawValue,
                         count: items.count,
                         hash: hasher.finalize())
    }
}

extension Notification.Name {
    static let bookwormShowOnlineSearch = Notification.Name("Bookworm.ShowOnlineSearch")
    static let bookwormShowSourceManagement = Notification.Name("Bookworm.ShowSourceManagement")
}
