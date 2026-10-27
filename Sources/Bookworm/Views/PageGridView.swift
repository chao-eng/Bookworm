import SwiftUI
import AppKit

/// Popover navigator showing a lazy grid of page thumbnails for the
/// current book. Tapping a cell jumps the reader to that page. The
/// current page is ringed; bookmarked pages get a corner flag.
struct PageGridView: View {
    @ObservedObject var model: ReaderModel
    /// Called with the chosen page index; the host closes the popover.
    let onSelect: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 124), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.tint)
                Text("页面").font(.headline)
                Spacer()
                Text("\(model.pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(0..<model.pageCount, id: \.self) { idx in
                            PageThumbCell(
                                model: model,
                                index: idx,
                                isCurrent: idx == model.currentPage,
                                isBookmarked: model.isBookmarked(idx)
                            )
                            .id(idx)
                            .onTapGesture { onSelect(idx) }
                        }
                    }
                    .padding(14)
                }
                .onAppear {
                    proxy.scrollTo(model.currentPage, anchor: .center)
                }
            }
        }
        .frame(width: 420, height: 480)
    }
}

private struct PageThumbCell: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    let isCurrent: Bool
    let isBookmarked: Bool

    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.18))
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.black.opacity(0.15),
                                  lineWidth: isCurrent ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .padding(4)
                }
            }
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .task(id: index) {
            thumb = await model.pageThumbnail(at: index)
        }
    }
}

/// Popover list of the pages the user has bookmarked in this book.
struct BookmarksListView: View {
    @ObservedObject var model: ReaderModel
    let onSelect: (Int) -> Void

    private var sortedPages: [Int] { model.bookmarkedPages.sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.yellow)
                Text("书签").font(.headline)
                Spacer()
                Text("\(sortedPages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if sortedPages.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("还没有书签")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("可通过工具栏或 ⌘D 为当前页添加书签。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedPages, id: \.self) { page in
                            BookmarkRow(model: model, page: page) {
                                onSelect(page)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 380)
    }
}

private struct BookmarkRow: View {
    @ObservedObject var model: ReaderModel
    let page: Int
    let onSelect: () -> Void

    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.18))
                }
            }
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("第 \(page + 1) 页")
                .font(.callout)
            Spacer()
            if page == model.currentPage {
                Text("当前")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.toggleBookmark(at: page)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("移除书签")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .task(id: page) {
            thumb = await model.pageThumbnail(at: page)
        }
    }
}
