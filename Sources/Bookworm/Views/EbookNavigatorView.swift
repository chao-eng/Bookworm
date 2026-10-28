import SwiftUI

/// Popover table of contents for a text ebook. Lists every chapter the
/// reader exposed a title for, indented by heading level; tapping a row
/// jumps there.
struct TableOfContentsView: View {
    @ObservedObject var model: ReaderModel
    let onSelect: (TOCEntry) -> Void

    /// 当前应高亮的行：点击过目录就用点中的那行，否则取本页的第一条。
    private var highlightedEntryID: UUID? {
        if let id = model.currentTOCEntryID { return id }
        return model.tableOfContents.first { $0.pageIndex == model.currentPage }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .foregroundStyle(.tint)
                Text("目录").font(.headline)
                Spacer()
                Text("\(model.tableOfContents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.tableOfContents) { entry in
                            tocRow(entry)
                            Divider()
                        }
                    }
                }
                .onAppear {
                    if let id = highlightedEntryID {
                        proxy.scrollTo(id, anchor: .center)
                    } else if let current = model.tableOfContents
                        .last(where: { $0.pageIndex <= model.currentPage }) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 340, height: 460)
    }

    @ViewBuilder
    private func tocRow(_ entry: TOCEntry) -> some View {
        let isCurrent = entry.id == highlightedEntryID
        let indent = CGFloat(min(entry.level, 4)) * 16
        HStack(spacing: 8) {
            if isCurrent {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            } else {
                Spacer().frame(width: 12)
            }
            Text(entry.title)
                .font(entry.level == 0 ? .callout : .subheadline)
                .fontWeight(isCurrent || entry.level == 0 ? .semibold : .regular)
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14 + indent)
        .padding(.trailing, 14)
        .padding(.vertical, entry.level == 0 ? 9 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(entry) }
        .id(entry.id)
    }
}

/// Popover full-text search across a text ebook. Live-searches the whole
/// book (debounced) and lists matches with a context snippet; tapping a
/// match jumps to that chapter.
struct BookSearchView: View {
    @ObservedObject var model: ReaderModel
    let onSelect: (Int) -> Void

    @State private var query: String = ""
    @State private var results: [SearchHit] = []
    @State private var isSearching: Bool = false
    @State private var didSearch: Bool = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("在本书中搜索…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch(immediate: true) }
                if isSearching {
                    ProgressView().controlSize(.mini)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        didSearch = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(width: 380, height: 440)
        .onChange(of: query) { _, _ in runSearch(immediate: false) }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).count < 2 {
            centeredMessage(icon: "text.magnifyingglass",
                             title: "搜索整本书",
                             subtitle: "请输入至少两个字符。")
        } else if isSearching && results.isEmpty {
            centeredMessage(icon: "hourglass",
                             title: "正在搜索…",
                             subtitle: nil)
        } else if didSearch && results.isEmpty {
            centeredMessage(icon: "questionmark.circle",
                             title: "没有匹配项",
                             subtitle: "本书中没有与“\(query)”匹配的内容。")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { hit in
                        searchRow(hit)
                        Divider()
                    }
                }
            }
            if results.count >= 1 {
                Divider()
                Text("\(results.count) 个匹配项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func searchRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.chapterTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .lineLimit(1)
            Text(highlighted(hit.snippet))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(hit.chapterIndex) }
    }

    /// Bold the matched query inside the snippet so the eye lands on it.
    private func highlighted(_ snippet: String) -> AttributedString {
        var attributed = AttributedString(snippet)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchRange].range(
            of: needle, options: [.caseInsensitive]
        ) {
            attributed[found].font = .callout.bold()
            attributed[found].foregroundColor = .accentColor
            searchRange = found.upperBound..<attributed.endIndex
        }
        return attributed
    }

    private func centeredMessage(icon: String,
                                  title: String,
                                  subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// Debounced search. `immediate` skips the debounce (used for the
    /// Return key) so an explicit submit feels instant.
    private func runSearch(immediate: Bool) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            results = []
            didSearch = false
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
            let hits = await model.search(q)
            if Task.isCancelled { return }
            results = hits
            didSearch = true
            isSearching = false
        }
    }
}
