import Foundation
import AppKit
import Combine

/// 书源仓库：`Sources/sources.json`（schemaVersion 1），一次原子写（BR-11）。
@MainActor
final class SourceRepository: ObservableObject {
    static let shared = SourceRepository()

    @Published private(set) var sources: [BookSource] = []

    /// 健康度等高频改动走 1s 防抖合并写盘；结构性变更仍立即保存。
    private var saveTask: Task<Void, Never>?
    private var needsSave = false
    private var terminationObserver: NSObjectProtocol?

    private struct Persisted: Codable {
        var schemaVersion: Int
        var sources: [BookSource]
    }

    init() {
        load()
        // 退出前把防抖中的改动落盘，避免最后一次健康度记录丢失。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
    }

    // MARK: - 查询

    var enabledSources: [BookSource] {
        sources.filter { $0.enabled }
    }

    var hasEnabledSource: Bool {
        sources.contains { $0.enabled }
    }

    func source(id: String) -> BookSource? {
        sources.first { $0.id == id }
    }

    /// 规则指纹：规则变更后用于提示重建目录（BR-30、A-2）。
    static func fingerprint(of source: BookSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = ["\(source.menuRule)", "\(source.contentRule)", source.homeUrl]
            .joined(separator: "|")
        return String(AppPaths.sha256Hex(payload).prefix(16))
    }

    // MARK: - 镜像回退

    /// `fq.luoxx.top` 已封禁 `/content`（403），正文改走 gofq 镜像；两站 item_id 通用，目录仍取原站。
    private static let blockedContentHost = "fq.luoxx.top"
    private static let fallbackContentHost = "gofq.52dns.cc"

    /// 把指向被封禁镜像的正文规则改到可用镜像，并把两层 `data` 路径压成一层。
    @discardableResult
    private static func applyMirrorFallback(menu: inout MenuRule, content: inout ContentRule) -> Bool {
        guard menu.itemUrlPath?.contains(blockedContentHost) == true else { return false }
        menu.itemUrlPath = menu.itemUrlPath?
            .replacingOccurrences(of: blockedContentHost, with: fallbackContentHost)
        menu.itemUrlBase = menu.itemUrlBase?
            .replacingOccurrences(of: blockedContentHost, with: fallbackContentHost)
        content.contentPath = content.contentPath
            .replacingOccurrences(of: "key$$data.key$$data.", with: "key$$data.")
        content.titlePath = content.titlePath?
            .replacingOccurrences(of: "key$$data.key$$data.", with: "key$$data.")
        return true
    }

    // MARK: - 编辑

    func setEnabled(_ enabled: Bool, sourceID: String) {
        guard let idx = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        guard sources[idx].enabled != enabled else { return }
        sources[idx].enabled = enabled
        save()
    }

    /// 一键停用全部在线源（BR-46）。
    func disableAll() {
        guard sources.contains(where: { $0.enabled }) else { return }
        for idx in sources.indices { sources[idx].enabled = false }
        save()
    }

    /// 一键停用失效书源：健康度低于阈值的已启用源（BR-46）。返回停用数量。
    @discardableResult
    func disableUnhealthy(threshold: Double = 0.3) -> Int {
        var count = 0
        for idx in sources.indices where sources[idx].enabled && sources[idx].healthScore < threshold {
            sources[idx].enabled = false
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    /// 导出全部书源（与 sources.json 同结构），供 `NSSavePanel` 落盘。
    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(Persisted(schemaVersion: 1, sources: sources))
    }

    /// 还原内置源的规则与覆盖字段，保留启用状态。
    func restoreBuiltin(sourceID: String) {
        guard let idx = sources.firstIndex(where: { $0.id == sourceID }),
              sources[idx].isBuiltin else { return }
        sources[idx].overrides = nil
        save()
    }

    @discardableResult
    func delete(sourceID: String) -> Bool {
        guard let idx = sources.firstIndex(where: { $0.id == sourceID }) else { return false }
        guard !sources[idx].isBuiltin else { return false }
        sources.remove(at: idx)
        save()
        return true
    }

    /// 保存编辑后的源（规则热更新，BR-39）。只替换规则字段，保留健康度。
    func update(_ source: BookSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        var next = source
        next.health = sources[idx].health
        sources[idx] = next
        save()
    }

    // MARK: - 健康度

    func record(kind: SourceHealth.Kind, sourceID: String, success: Bool, error: String? = nil) {
        guard let idx = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        var health = sources[idx].health ?? SourceHealth(sourceID: sourceID)
        health.record(kind, success: success, error: error.map { Diagnostics.redact($0) })
        sources[idx].health = health
        scheduleSave()
    }

    // MARK: - 导入

    enum ConflictResolution {
        case overwrite
        case keepBoth
        case skip
    }

    struct ImportCandidate {
        var source: BookSource
        /// 同名或同 id 的已有源；nil 表示新增。
        var conflictingID: String?
        /// 该源部分能力不可用的提示（BR-27、09 §3 备注）。
        var warnings: [String]
    }

    struct ImportFailure {
        var name: String
        var message: String
    }

    struct ImportPreview {
        var candidates: [ImportCandidate]
        var failures: [ImportFailure]

        var addedCount: Int { candidates.filter { $0.conflictingID == nil }.count }
        var conflictingCount: Int { candidates.filter { $0.conflictingID != nil }.count }
    }

    /// 解析 JSON 文件或粘贴文本，只预览不落盘（BR-14）。
    func preview(data: Data) -> (preview: ImportPreview?, error: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return (nil, "JSON 格式不合法，请检查括号与引号是否配对")
        }
        var rawList: [Any] = []
        if let array = root as? [Any] {
            rawList = array
        } else if let dict = root as? [String: Any] {
            if let array = dict["sources"] as? [Any] {
                rawList = array
            } else if dict["name"] != nil {
                rawList = [dict]
            } else {
                return (nil, "未找到书源列表，请使用 [ … ] 或 {\"sources\": [ … ]}")
            }
        } else {
            return (nil, "这不是有效的书源 JSON")
        }
        guard !rawList.isEmpty else {
            return (nil, "书源列表为空")
        }

        let decoder = JSONDecoder()
        var candidates: [ImportCandidate] = []
        var failures: [ImportFailure] = []
        let existing = sources

        for raw in rawList {
            guard let itemData = try? JSONSerialization.data(withJSONObject: raw) else {
                failures.append(ImportFailure(name: "未知", message: "无法解析该条目"))
                continue
            }
            var source: BookSource
            do {
                source = try SourceRepository.decodeSource(raw, decoder: decoder)
            } catch LegacySourceError.incomplete {
                let name = (raw as? [String: Any])?["source_name"] as? String ?? "未知"
                failures.append(ImportFailure(name: name,
                                              message: "老版书源缺少搜索、目录或正文规则，无法转换"))
                continue
            } catch {
                let name = (raw as? [String: Any])?["name"] as? String ?? "未知"
                failures.append(ImportFailure(name: name,
                                              message: "缺少或写错字段：\(SourceRepository.describe(decodingError: error))"))
                continue
            }

            let issues = SourceRepository.validate(&source)
            guard issues.isEmpty else {
                failures.append(ImportFailure(name: source.name.isEmpty ? "未知" : source.name,
                                              message: issues.joined(separator: "；")))
                continue
            }

            // 用户导入的源一律按用户源处理，不能冒充内置源。
            source.isBuiltin = false
            let conflictID = existing.first { $0.name == source.name || $0.id == source.id }?.id
            var warnings: [String] = []
            if source.menuRule.needsBrowser == true {
                warnings.append("目录需浏览器渲染：V2 降级为单次抓取")
            }
            if source.menuRule.requiresClick == true {
                warnings.append("目录需模拟点击：V2 不支持")
            }
            if source.contentRule.needsBrowser == true {
                warnings.append("正文需浏览器渲染：V2 不支持")
            }
            if source.contentRule.specialSelector != nil {
                warnings.append("特殊正文处理：V2 不支持")
            }
            candidates.append(ImportCandidate(source: source,
                                              conflictingID: conflictID,
                                              warnings: warnings))
        }

        // 同一批导入里重名的第二条按冲突处理，避免重复落盘。
        var seenNames = Set(existing.map { $0.name })
        for i in candidates.indices where candidates[i].conflictingID == nil {
            if seenNames.contains(candidates[i].source.name) {
                candidates[i].conflictingID = "pending:\(i)"
            } else {
                seenNames.insert(candidates[i].source.name)
            }
        }

        return (ImportPreview(candidates: candidates, failures: failures), nil)
    }

    // MARK: - 老版书源兼容

    /// 老版书源（`source_name` / `book_menu` / `chapter_content`）缺少必要规则时抛出。
    private enum LegacySourceError: Error {
        case incomplete
    }

    private static func decodeSource(_ raw: Any, decoder: JSONDecoder) throws -> BookSource {
        if let dict = raw as? [String: Any],
           dict["source_name"] != nil || dict["search_result"] != nil {
            guard let converted = adaptLegacy(dict) else {
                throw LegacySourceError.incomplete
            }
            return converted
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try decoder.decode(BookSource.self, from: data)
    }

    /// 把老版书源字段映射到 BookSource 规则（字段含义与 V2 规则一一对应）。
    private static func adaptLegacy(_ raw: [String: Any]) -> BookSource? {
        func string(_ key: String) -> String? {
            if let v = raw[key] as? String {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let v = raw[key] as? NSNumber { return v.stringValue }
            return nil
        }
        func integer(_ key: String) -> Int? {
            if let v = raw[key] as? NSNumber { return v.intValue }
            if let v = raw[key] as? String { return Int(v.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        func flag(_ key: String) -> Bool? {
            if let v = raw[key] as? Bool { return v }
            if let v = raw[key] as? NSNumber { return v.boolValue }
            if let v = raw[key] as? String {
                return ["1", "true", "yes", "是"].contains(v.lowercased())
            }
            return nil
        }

        guard let name = string("source_name"),
              let homeURL = string("source_url"),
              let searchURL = string("search_url"),
              let menuSelector = string("book_menu"),
              let contentSelector = string("chapter_content"),
              let result = raw["search_result"] as? [String: Any] else {
            return nil
        }
        func resultString(_ key: String) -> String? {
            if let v = result[key] as? String {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let v = result[key] as? NSNumber { return v.stringValue }
            return nil
        }
        guard let listPath = resultString("list"),
              let namePath = resultString("name"),
              let urlPath = resultString("url") else {
            return nil
        }

        // 老版 `source_type = 2` 的 JSON 源：搜索规则用 `$$` 路径表达。
        let isJSON = listPath.contains("key$$") || listPath.contains("index$$")

        let searchRule = SearchRule(
            limit: resultString("limit").flatMap { Int($0) },
            listPath: listPath,
            namePath: namePath,
            authorPath: resultString("author"),
            bookIdPath: resultString("book_id"),
            urlPath: urlPath,
            urlAttr: resultString("url_attr"),
            coverPath: resultString("cover"),
            coverAttr: resultString("cover_attr"),
            remarkPath: resultString("remark"),
            newestPath: resultString("newest")
        )

        var menuRule = MenuRule(
            listPath: menuSelector,
            attrBinding: string("book_menu_attr"),
            isPaginated: flag("menu_pagination") ?? (string("book_menu_next_url") != nil ? true : nil),
            nextPageSelector: nil,
            nextPageText: nil,
            nextUrlTemplate: string("book_menu_next_url"),
            pagination: nil,
            needsBrowser: flag("menu_native"),
            browserOkTag: string("menu_ok_tag"),
            requiresClick: flag("menu_n_click"),
            itemIdPath: string("item_id"),
            itemNamePath: string("item_name"),
            itemUrlPath: string("item_url"),
            itemUrlBase: string("item_url_base"),
            isReversed: nil
        )

        var multiPage: JSONValue?
        var nextPagePath: String?
        if let nextButton = string("next_btn"),
           let nextValue = string("next_val"), nextValue.contains("页") {
            nextPagePath = nextButton
            multiPage = .object(["next_btn": .string(nextButton),
                                 "next_val": .string(nextValue)])
        } else if flag("multi_page") == true {
            multiPage = .bool(true)
        }

        var contentRule = ContentRule(
            titlePath: string("chapter_title"),
            contentPath: contentSelector,
            contentType: string("chapter_content_type"),
            contentAttr: string("chapter_content_attr"),
            filters: raw["content_filter"] as? [String],
            removeSelectors: raw["selector_filter"] as? [String],
            multiPage: multiPage,
            nextPagePath: nextPagePath,
            needsBrowser: flag("content_native"),
            browserOkTag: string("content_ok_tag"),
            specialSelector: string("special_selector")
        )
        applyMirrorFallback(menu: &menuRule, content: &contentRule)

        var headers: [String: String]?
        if let rawHeaders = raw["headers"] as? [String: Any] {
            headers = rawHeaders.compactMapValues { $0 as? String }
        }
        let request = RequestConfig(
            timeout: integer("time_out"),
            useMobileUA: flag("mobile_ua"),
            headers: headers,
            cookie: string("cookie"),
            contentTimeout: integer("content_timeout"),
            contentMethod: string("content_method"),
            allowInsecureTLS: nil
        )

        return BookSource(id: "",
                          name: name,
                          homeUrl: homeURL,
                          remark: string("source_remark"),
                          kind: isJSON ? "json" : "html",
                          searchUrl: searchURL,
                          searchRule: searchRule,
                          menuRule: menuRule,
                          contentRule: contentRule,
                          request: request,
                          enabled: true,
                          isBuiltin: false,
                          overrides: nil,
                          health: nil)
    }

    /// 应用预览：按用户选择的冲突策略落盘。
    @discardableResult
    func apply(_ preview: ImportPreview, resolution: ConflictResolution) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        var usedNames = Set(sources.map { $0.name })

        for candidate in preview.candidates {
            var incoming = candidate.source
            if let existingID = candidate.conflictingID {
                if existingID.hasPrefix("pending:") {
                    // 同批重复条目：一律按新条目处理（名称加后缀）。
                    switch resolution {
                    case .skip:
                        continue
                    case .overwrite, .keepBoth:
                        incoming.name = SourceRepository.uniqueName(incoming.name, used: usedNames)
                        incoming.id = availableID(preferred: incoming.id,
                                                  name: incoming.name,
                                                  homeURL: incoming.homeUrl)
                        sources.append(incoming)
                        usedNames.insert(incoming.name)
                        added += 1
                    }
                    continue
                }
                switch resolution {
                case .skip:
                    continue
                case .overwrite:
                    if let idx = sources.firstIndex(where: { $0.id == existingID }) {
                        let old = sources[idx]
                        incoming.id = old.id
                        incoming.isBuiltin = old.isBuiltin
                        incoming.health = old.health
                        // 用户覆盖的 Cookie / 请求头优先（BR-42）。
                        if incoming.request?.cookie == nil {
                            incoming.request?.cookie = old.request?.cookie
                        }
                        if incoming.request?.headers == nil {
                            incoming.request?.headers = old.request?.headers
                        }
                        sources[idx] = incoming
                        updated += 1
                    }
                case .keepBoth:
                    incoming.name = SourceRepository.uniqueName(incoming.name, used: usedNames)
                    incoming.id = availableID(preferred: incoming.id,
                                              name: incoming.name,
                                              homeURL: incoming.homeUrl)
                    sources.append(incoming)
                    usedNames.insert(incoming.name)
                    added += 1
                }
            } else {
                incoming.name = SourceRepository.uniqueName(incoming.name, used: usedNames)
                incoming.id = availableID(preferred: incoming.id,
                                          name: incoming.name,
                                          homeURL: incoming.homeUrl)
                sources.append(incoming)
                usedNames.insert(incoming.name)
                added += 1
            }
        }
        if added > 0 || updated > 0 {
            sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            save()
        }
        return (added, updated)
    }

    // MARK: - 校验

    /// 就地规整并返回错误清单；空数组表示通过（UC-05 2b）。
    static func validate(_ source: inout BookSource) -> [String] {
        var issues: [String] = []
        source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.name.isEmpty { issues.append("缺少 name") }
        if source.name.count > 40 { issues.append("name 超过 40 字") }
        if !isHTTPURL(source.homeUrl) {
            issues.append("homeUrl 必须是 http/https 地址")
        }
        if !source.searchUrl.contains("###keyword###") {
            issues.append("searchUrl 必须包含 ###keyword###")
        }
        if source.searchRule.listPath.isEmpty { issues.append("缺少 searchRule.listPath") }
        if source.searchRule.namePath.isEmpty { issues.append("缺少 searchRule.namePath") }
        if source.searchRule.urlPath.isEmpty { issues.append("缺少 searchRule.urlPath") }
        if source.menuRule.listPath.isEmpty { issues.append("缺少 menuRule.listPath") }
        if source.contentRule.contentPath.isEmpty { issues.append("缺少 contentRule.contentPath") }
        return issues
    }

    private static func isHTTPURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func uniqueName(_ base: String, used: Set<String>) -> String {
        guard used.contains(base) else { return base }
        var n = 2
        while used.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    private static func generateID(name: String, homeURL: String, avoiding: [BookSource]) -> String {
        var seed = "\(name)|\(homeURL)|\(UUID().uuidString)"
        var digest = String(AppPaths.sha256Hex(seed).prefix(12))
        while avoiding.contains(where: { $0.id == digest }) {
            seed += "-x"
            digest = String(AppPaths.sha256Hex(seed).prefix(12))
        }
        return digest
    }

    /// 导入时优先沿用文件里的 id；冲突或为空则新建。
    private func availableID(preferred: String, name: String, homeURL: String) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !sources.contains(where: { $0.id == trimmed }) {
            return trimmed
        }
        return SourceRepository.generateID(name: name, homeURL: homeURL, avoiding: sources)
    }

    private static func describe(decodingError: Error) -> String {
        guard let error = decodingError as? DecodingError else {
            return decodingError.localizedDescription
        }
        switch error {
        case .keyNotFound(let key, _):
            return "缺少字段 \(key.stringValue)"
        case .typeMismatch(_, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "字段类型不符" : "字段 \(path) 类型不符"
        case .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "字段值为空" : "字段 \(path) 值为空"
        case .dataCorrupted(let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "数据格式错误" : "字段 \(path) 格式错误"
        @unknown default:
            return "数据格式错误"
        }
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.sourcesFile) else { return }
        guard let file = try? AppPaths.decodeJSON(Persisted.self, from: data) else {
            Diagnostics.log("sources", "sources.json 解析失败，保留空列表")
            return
        }
        sources = file.sources.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        migrateLegacyJSONSources()
    }

    /// 修复早期导入的老版 JSON 源：`$$` 路径曾被标记为 html、丢失 book_id 路径，
    /// 以及正文落在已封禁的 fq.luoxx.top 上。
    private func migrateLegacyJSONSources() {
        var changed = false
        for idx in sources.indices {
            var source = sources[idx]
            let rule = source.searchRule
            let usesJSONPath = rule.listPath.contains("key$$") || rule.listPath.contains("index$$")
            if usesJSONPath, (source.kind ?? "html").lowercased() != "json" {
                source.kind = "json"
                if source.searchRule.bookIdPath == nil,
                   source.searchRule.urlPath.contains("###book_id###") {
                    source.searchRule.bookIdPath = "key$$book_id"
                }
                changed = true
            }
            if Self.applyMirrorFallback(menu: &source.menuRule, content: &source.contentRule) {
                changed = true
            }
            sources[idx] = source
        }
        if changed { save() }
    }

    /// 立即把未落盘的改动写入磁盘（退出、切换等场景）。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard needsSave else { return }
        save()
    }

    /// 1s 防抖：同一批健康度记录只写一次盘。
    private func scheduleSave() {
        needsSave = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            guard self.needsSave else { return }
            self.save()
        }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        needsSave = false
        let file = Persisted(schemaVersion: 1, sources: sources)
        do {
            try AppPaths.atomicWriteJSON(file, to: AppPaths.sourcesFile)
        } catch {
            Diagnostics.log("sources", "写入失败：\(error.localizedDescription)")
        }
    }
}
