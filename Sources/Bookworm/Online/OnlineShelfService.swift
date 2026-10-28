import Foundation
import AppKit

enum OnlineShelfError: LocalizedError {
    case sourceMissing
    case badDetailURL
    case emptyTOC
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "这本书的来源已被移除，可以换一个来源"
        case .badDetailURL:
            return "详情页地址不合法，可以换一个来源"
        case .emptyTOC:
            return OnlineCopy.tocFailed
        case .incompatible(let message):
            return message
        }
    }
}

/// 把搜索结果变成书架条目（UC-07）：先抓目录，再落库，最后补封面。
@MainActor
final class OnlineShelfService: ObservableObject {
    static let shared = OnlineShelfService()

    /// 正在加入书架的条目，用于按钮禁用与重复点击防护。
    @Published private(set) var busyIDs: Set<String> = []

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 加入书架并返回书架里的条目（不自动打开）。
    func addToShelf(_ item: SearchItem,
                    library: LibraryStore,
                    refreshIndex: Bool = false) async throws -> ComicItem {
        let uuid = OnlineIdentity.bookID(sourceID: item.sourceID, bookKey: item.bookKey)
        let busyKey = uuid.uuidString
        guard !busyIDs.contains(busyKey) else {
            if let existing = library.item(withID: uuid) { return existing }
            throw OnlineShelfError.incompatible("正在处理这本书，请稍候")
        }
        busyIDs.insert(busyKey)
        defer { busyIDs.remove(busyKey) }

        guard let source = SourceRepository.shared.source(id: item.sourceID) else {
            throw OnlineShelfError.sourceMissing
        }
        guard let detailURL = URL(string: item.detailURL) else {
            throw OnlineShelfError.badDetailURL
        }

        let index = try await ChapterService.shared.buildIndex(bookID: busyKey,
                                                               detailURL: detailURL,
                                                               source: source,
                                                               force: refreshIndex)
        guard !index.chapters.isEmpty else { throw OnlineShelfError.emptyTOC }

        var comic = ComicItem(searchItem: item)
        comic.pageCount = index.chapters.count
        let added = library.upsertOnlineItem(comic)
        if added || library.item(withID: comic.id)?.thumbnailFileName == nil {
            downloadCover(urlString: item.coverURL, bookID: comic.id, library: library)
        }
        return library.item(withID: comic.id) ?? comic
    }

    /// 下载封面写进缩略图目录；失败只用占位，不阻塞阅读。
    func downloadCover(urlString: String?, bookID: ComicItem.ID, library: LibraryStore) {
        guard let urlString, let url = URL(string: urlString) else { return }
        let fileName = "\(bookID.uuidString).jpg"
        let destination = AppPaths.thumbnailsDirectory.appendingPathComponent(fileName)
        Task.detached(priority: .utility) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode < 400,
                  let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
            else { return }
            try? FileManager.default.createDirectory(at: AppPaths.thumbnailsDirectory,
                                                     withIntermediateDirectories: true)
            try? jpeg.write(to: destination, options: .atomic)
            await MainActor.run {
                library.updateThumbnail(itemID: bookID, fileName: fileName)
            }
        }
    }
}
