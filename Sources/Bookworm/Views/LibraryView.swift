import SwiftUI
import AppKit

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "标题"
    case dateAdded = "添加日期"
    case lastOpened = "最近打开"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var openBooks: OpenBooks
    @State private var search: String = ""
    @State private var sort: LibrarySort = .title
    @State private var cardSize: CGFloat = 180
    @State private var serverURL: String? = nil
    @State private var showingServerInfo: Bool = false

    var filtered: [ComicItem] {
        let base = library.items.filter { item in
            search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .title:
            return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAdded:
            return base.sorted { $0.dateAdded > $1.dateAdded }
        case .lastOpened:
            return base.sorted {
                ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                grid
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
                .frame(width: 200)

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

            Button {
                toggleServer()
            } label: {
                Image(systemName: serverURL == nil ? "wifi" : "wifi.circle.fill")
                    .foregroundStyle(serverURL == nil ? Color.primary : Color.accentColor)
            }
            .help(serverURL == nil
                  ? "在本机网络上共享书库"
                  : "正在共享：\(serverURL!) — 点击停止")
            .popover(isPresented: $showingServerInfo) {
                serverInfoPopover
            }

            Button {
                library.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新扫描书库")
            .disabled(library.isScanning)

            Button {
                library.promptForFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("更换书库文件夹")
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
        [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.4), spacing: 24)]
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if search.isEmpty, !library.inProgress.isEmpty {
                    continueReadingShelf
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(filtered) { item in
                        LibraryCard(item: item, width: cardSize)
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
        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("标记为未读") {
            library.updateProgress(itemID: item.id, page: 0, pageCount: item.pageCount)
        }
    }

    private func open(_ item: ComicItem) {
        openBooks.open(itemID: item.id, library: library)
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

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let total = item.pageCount {
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
        } else if let frac = item.progressFraction, item.lastReadPage > 0 {
            Text("\(Int((frac * 100).rounded()))%")
                .font(.caption2.bold().monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
    }

    /// Thin progress fill along the bottom edge of the cover, mirroring
    /// the percentage badge for an at-a-glance scan down the grid.
    @ViewBuilder
    private var progressBar: some View {
        if let frac = item.progressFraction, item.lastReadPage > 0 {
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

    private func loadThumbnail() {
        if let img = library.thumbnailImage(for: item) {
            self.thumbnail = img
        }
    }
}
