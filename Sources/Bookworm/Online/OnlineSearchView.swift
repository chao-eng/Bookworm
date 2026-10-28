import SwiftUI
import AppKit

/// 跨源搜书面板（UC-06、07 §3）。
struct OnlineSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var openBooks: OpenBooks
    @ObservedObject private var search = SearchService.shared
    @ObservedObject private var sources = SourceRepository.shared
    @ObservedObject private var shelf = OnlineShelfService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var expanded: Set<String> = []
    @State private var addError: String?
    @State private var showingSources = false
    @State private var showingFailures = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sources.hasEnabledSource {
                searchBar
            } else {
                noSourceGuide
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            Divider()
            content
            if search.totalSources > 0 {
                Divider()
                footer
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { focused = true }
        .sheet(isPresented: $showingSources) {
            SourceManagementView()
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("关闭")
            .keyboardShortcut(.cancelAction)
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(.tint)
            Text("搜索在线书").font(.title3.bold())
            Spacer()
            Button("书源管理") { showingSources = true }
            Button("完成") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("输入书名或作者…", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { performSearch() }

            Button("搜索") { performSearch() }
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if search.isSearching {
                Button("停止") { search.cancel() }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var noSourceGuide: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(OnlineCopy.noSources)
                .foregroundStyle(.secondary)
            Spacer()
            Button("去管理书源") { showingSources = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: 结果

    @ViewBuilder
    private var content: some View {
        if search.isSearching || search.hasResults || search.totalSources > 0 {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("搜索中… \(search.completedSources)/\(max(search.totalSources, 1)) 个来源")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                    ForEach(search.items) { display in
                        resultRow(display)
                        Divider().padding(.leading, 20)
                    }
                    if !search.isSearching, search.items.isEmpty {
                        emptyResults
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("试试输入书名或作者")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            Text("没找到，换个关键词或检查书源")
                .foregroundStyle(.secondary)
            Button("去管理书源") { showingSources = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func resultRow(_ display: SearchDisplayItem) -> some View {
        let primary = display.primary
        let busy = shelf.busyIDs.contains(
            OnlineIdentity.bookID(sourceID: primary.sourceID, bookKey: primary.bookKey).uuidString
        )
        return HStack(alignment: .top, spacing: 12) {
            cover(for: primary.coverURL, size: CGSize(width: 52, height: 72))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(primary.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(primary.matchLevel.label)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                }
                HStack(spacing: 8) {
                    if let author = primary.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("来源：\(primary.sourceName ?? primary.sourceID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let score = SourceRepository.shared.source(id: primary.sourceID)?.healthScore, score < 0.3 {
                        Text(OnlineCopy.sourceUnhealthy)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let intro = primary.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !display.alternatives.isEmpty {
                    alternativesView(display)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                Button("阅读") { add(primary, openAfter: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                Button("加入书架") { add(primary, openAfter: false) }
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { add(primary, openAfter: true) }
    }

    private func alternativesView(_ display: SearchDisplayItem) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(display.id) },
            set: { isOn in
                if isOn { expanded.insert(display.id) } else { expanded.remove(display.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(display.alternatives) { alt in
                    HStack(spacing: 8) {
                        Text(alt.sourceName ?? alt.sourceID)
                            .font(.caption)
                        Text("匹配：\(alt.matchLevel.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("用这个来源阅读") { add(alt, openAfter: true) }
                            .controlSize(.mini)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("更多来源（\(display.alternatives.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cover(for urlString: String?, size: CGSize) -> some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.gray.opacity(0.18))
                    }
                }
            } else {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.18))
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: 底部汇总

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if search.isSearching {
                    Text("已搜索 \(search.completedSources)/\(max(search.totalSources, 1)) 个来源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if search.isCancelled {
                    Text("已取消，已展示的结果仍可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("已搜索 \(search.completedSources) 个来源，\(search.failedSources) 个失败")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !search.failedSourceNames.isEmpty {
                    Button(showingFailures ? "收起失败原因" : "查看失败原因") {
                        showingFailures.toggle()
                    }
                    .controlSize(.small)
                    if sources.hasEnabledSource {
                        Button("一键停用全部在线源") {
                            sources.disableAll()
                        }
                        .controlSize(.small)
                        .help("搜索持续失败时，可以先全部停用再逐个启用")
                    }
                }
            }
            if showingFailures {
                Text(search.failedSourceNames.joined(separator: "、"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: 动作

    private func performSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addError = nil
        showingFailures = false
        search.start(keyword: trimmed, sources: sources.enabledSources)
    }

    private func add(_ item: SearchItem, openAfter: Bool) {
        addError = nil
        Task {
            do {
                let comic = try await OnlineShelfService.shared.addToShelf(item, library: library)
                if openAfter {
                    openBooks.open(itemID: comic.id, library: library)
                    dismiss()
                }
            } catch {
                addError = error.localizedDescription
            }
        }
    }
}
