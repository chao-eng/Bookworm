import Foundation

// MARK: - 动态 JSON 值

/// 书源里的 `headers` / `overrides` 等字段结构不固定，用枚举承载，
/// 避免 `[String: Any]` 无法 Codable。
enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不支持的 JSON 值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .bool(let v): return String(v)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .number(let v) = self { return Int(v) }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    init(any: Any) {
        switch any {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .number(Double(v))
        case let v as Double: self = .number(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.anyValue }
        case .array(let v): return v.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

// MARK: - 书源规则

struct SearchRule: Codable, Equatable {
    /// 取前 N 条；负数表示先整体反转再取前 |n| 条。
    var limit: Int?
    /// CSS 选择器或 JSON `$$` 路径。
    var listPath: String
    var namePath: String
    var authorPath: String?
    var bookIdPath: String?
    var urlPath: String
    var urlAttr: String?
    var coverPath: String?
    var coverAttr: String?
    var remarkPath: String?
    var newestPath: String?
}

struct PaginationRule: Codable, Equatable {
    var pageParam: String?
    var sizeParam: String?
    var pageSize: Int?
    var startPage: Int?
    var totalRulePath: String?
    var responsePageRulePath: String?
    var responseSizeRulePath: String?
}

struct MenuRule: Codable, Equatable {
    /// 目录条目选择器或 JSON `$$` 路径。
    var listPath: String
    /// 目录链接属性，缺省 `href`。
    var attrBinding: String?
    var isPaginated: Bool?
    var nextPageSelector: String?
    var nextPageText: String?
    var nextUrlTemplate: String?
    var pagination: PaginationRule?
    /// 旧稿的 `menu_native`：需要浏览器渲染，V2 降级为普通请求。
    var needsBrowser: Bool?
    var browserOkTag: String?
    /// 旧稿的 `menu_n_click`：需要模拟点击，V2 标记不支持。
    var requiresClick: Bool?
    var itemIdPath: String?
    var itemNamePath: String?
    var itemUrlPath: String?
    var itemUrlBase: String?
    /// 章节列表是否按从新到旧排列，需要整体反转。
    var isReversed: Bool?
}

struct ContentRule: Codable, Equatable {
    var titlePath: String?
    var contentPath: String
    /// "1" 取文本（默认），"2" 取属性。
    var contentType: String?
    var contentAttr: String?
    /// Base64 编码的正文清洗规则，解码后按 `%&&%` 拆分。
    var filters: [String]?
    /// 需要从正文中删掉的节点选择器。
    var removeSelectors: [String]?
    /// 布尔或对象；对象可含 `next_btn` / `next_val` / `has_next`。
    var multiPage: JSONValue?
    var nextPagePath: String?
    var needsBrowser: Bool?
    var browserOkTag: String?
    var specialSelector: String?
}

struct RequestConfig: Codable, Equatable {
    var timeout: Int?
    var useMobileUA: Bool?
    var headers: [String: String]?
    var cookie: String?
    var contentTimeout: Int?
    var contentMethod: String?
    /// 按源关闭 TLS 校验，需二次确认（BR-41）。
    var allowInsecureTLS: Bool?
}

// MARK: - 健康度

struct SourceHealth: Codable, Equatable {
    var sourceID: String
    var searchWindow: [Bool]
    var tocWindow: [Bool]
    var contentWindow: [Bool]
    var score: Double
    var lastError: String?
    var updatedAt: Date

    init(sourceID: String) {
        self.sourceID = sourceID
        self.searchWindow = []
        self.tocWindow = []
        self.contentWindow = []
        self.score = 1.0
        self.lastError = nil
        self.updatedAt = Date()
    }

    enum Kind { case search, toc, content }

    mutating func record(_ kind: Kind, success: Bool, error: String? = nil) {
        switch kind {
        case .search:
            searchWindow.append(success)
            if searchWindow.count > 20 { searchWindow.removeFirst(searchWindow.count - 20) }
        case .toc:
            tocWindow.append(success)
            if tocWindow.count > 20 { tocWindow.removeFirst(tocWindow.count - 20) }
        case .content:
            contentWindow.append(success)
            if contentWindow.count > 20 { contentWindow.removeFirst(contentWindow.count - 20) }
        }
        var ok = 0
        var total = 0
        for window in [searchWindow, tocWindow, contentWindow] {
            ok += window.filter { $0 }.count
            total += window.count
        }
        score = total == 0 ? 1.0 : Double(ok) / Double(total)
        if !success { lastError = error }
        updatedAt = Date()
    }
}

// MARK: - 书源

struct BookSource: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var homeUrl: String
    var remark: String?
    /// `html` / `json`，缺省按 HTML。
    var kind: String?
    var searchUrl: String
    var searchRule: SearchRule
    var menuRule: MenuRule
    var contentRule: ContentRule
    var request: RequestConfig?
    var enabled: Bool
    var isBuiltin: Bool
    var overrides: [String: JSONValue]?
    var health: SourceHealth?

    var isJSON: Bool { (kind ?? "html").lowercased() == "json" }

    var healthScore: Double { health?.score ?? 1.0 }

    var host: String {
        URL(string: homeUrl)?.host ?? homeUrl
    }
}

// MARK: - 搜索 / 章节 / 缓存

enum MatchLevel: String, Codable, Equatable {
    case exact
    case contains
    case other

    var rank: Int {
        switch self {
        case .exact: return 0
        case .contains: return 1
        case .other: return 2
        }
    }

    var label: String {
        switch self {
        case .exact: return "精确"
        case .contains: return "相关"
        case .other: return "其他"
        }
    }
}

struct SearchItem: Identifiable, Codable, Hashable {
    var sourceID: String
    var bookKey: String
    var name: String
    var author: String?
    var coverURL: String?
    var detailURL: String
    var intro: String?
    var matchLevel: MatchLevel
    var sourceOrder: Int
    var arrivedAt: Date
    var sourceName: String?

    var id: String { "\(sourceID)|\(bookKey)" }
}

struct Chapter: Identifiable, Codable, Hashable {
    var index: Int
    var title: String
    var url: String
    var level: Int?

    var id: Int { index }
}

struct ChapterIndex: Codable {
    var bookID: String
    var sourceID: String
    var chapters: [Chapter]
    var tocMode: String
    var isComplete: Bool
    var sourceFingerprint: String
    var fetchedAt: Date
}

struct ChapterCacheMeta: Codable, Equatable {
    var bookID: String
    var chapterIndex: Int
    var relativePath: String
    var byteSize: Int64
    var complete: Bool
    var fetchedAt: Date
    var lastAccessAt: Date
    var sourceFingerprint: String
}

struct ChapterPayload {
    let index: Int
    let title: String
    let text: String
    let complete: Bool
}

// MARK: - 备份包

struct BackupPackage: Codable {
    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var items: [ComicItem]
    var sources: [BookSource]?
    var floating: FloatingState?
    var excluded: [String]?
}

// MARK: - 搜索展示模型

struct SearchDisplayItem: Identifiable {
    var primary: SearchItem
    var alternatives: [SearchItem]

    var id: String { primary.id }
}

// MARK: - 稳定 id

enum OnlineIdentity {
    /// `sourceID + bookKey` 稳定推导 UUID（SHA-256 前 16 字节）。
    static func bookID(sourceID: String, bookKey: String) -> UUID {
        let digest = AppPaths.sha256Data(Data("\(sourceID)|\(bookKey)".utf8))
        var bytes = [UInt8](digest.prefix(16))
        // 按 RFC 4122 设置版本 4 与 variant 位，保证是合法 UUID 字符串。
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = uuid_t(bytes[0], bytes[1], bytes[2], bytes[3],
                          bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11],
                          bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid)
    }

    static func identifierURL(sourceID: String, bookKey: String) -> URL {
        let encodedSource = sourceID.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? sourceID
        let encodedKey = bookKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookKey
        return URL(string: "online://\(encodedSource)/\(encodedKey)") ?? URL(fileURLWithPath: "/online/\(encodedSource)/\(encodedKey)")
    }
}

// MARK: - 文案

enum OnlineCopy {
    static let noSources = "先导入或启用一个书源"
    static let offlineChapter = "当前离线，这一章还没下载"
    static let chapterIncomplete = "这一章可能不完整"
    static let chapterFailed = "这一章没加载出来，可以重试或换一个来源"
    static let tocFailed = "这本书的目录读不出来，可以换一个来源"
    static let floatingTextOnly = "悬浮窗只支持文字书"
    static let sourceUnhealthy = "这个来源最近常失败"
}
