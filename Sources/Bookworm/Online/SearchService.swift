import Foundation
import Combine

/// 跨源并发搜索（UC-06）：并发 6、单源 7s、总预算 30s、到达即插入、去重折叠。
@MainActor
final class SearchService: ObservableObject {
    static let shared = SearchService()

    @Published private(set) var items: [SearchDisplayItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var completedSources = 0
    @Published private(set) var totalSources = 0
    @Published private(set) var failedSources = 0
    /// 失败来源的名称，供「查看失败原因」展开（不含正文与完整 URL）。
    @Published private(set) var failedSourceNames: [String] = []
    @Published private(set) var isCancelled = false
    @Published private(set) var lastError: String?
    @Published private(set) var keyword: String = ""

    var progressText: String {
        if isSearching {
            return "搜索中… \(completedSources)/\(totalSources)"
        }
        if totalSources == 0 { return "" }
        return "已搜索 \(totalSources) 个来源，\(failedSources) 个失败"
    }

    private var searchTask: Task<Void, Never>?
    private var requestToken = 0
    /// 单次搜索内的去重键缓存，避免跨批次重复 folding。
    private var dedupeKeyCache: [String: String] = [:]

    private let maxConcurrent = 6
    private let totalBudget: TimeInterval = 30
    /// 单源网络超时：非隔离静态常量，供子任务在主线程之外读取。
    private nonisolated static let perSourceTimeout: TimeInterval = 7

    /// 批量健康度记录：搜索结束后一次落库，避免逐条改 `@Published sources` 触发整页重渲染。
    private struct HealthRecordEntry {
        var sourceID: String
        var success: Bool
        var message: String?
    }

    var hasResults: Bool { !items.isEmpty }

    // MARK: - 启动 / 取消

    func start(keyword: String, sources: [BookSource]) {
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        requestToken += 1
        let token = requestToken
        items = []
        dedupeKeyCache = [:]
        isCancelled = false
        lastError = nil
        failedSources = 0
        failedSourceNames = []
        completedSources = 0
        totalSources = sources.count

        guard !keyword.isEmpty else {
            isSearching = false
            return
        }
        guard !sources.isEmpty else {
            isSearching = false
            lastError = OnlineCopy.noSources
            return
        }

        isSearching = true
        let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(keyword: keyword,
                           sources: sources,
                           order: order,
                           token: token)
        }
    }

    func cancel() {
        guard isSearching else { return }
        isCancelled = true
        isSearching = false
        requestToken += 1
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - 执行

    private func run(keyword: String,
                     sources: [BookSource],
                     order: [String: Int],
                     token: Int) async {
        let deadline = Date().addingTimeInterval(totalBudget)
        // 搜索期间先累积健康度，结束后一次性批量落库（减少 @Published 风暴）。
        var healthRecords: [HealthRecordEntry] = []
        await withTaskGroup(of: SourceOutcome.self) { group in
            var nextIndex = 0
            var inFlight = 0

            func addNext() {
                guard nextIndex < sources.count else { return }
                let source = sources[nextIndex]
                let sourceOrder = order[source.id] ?? 0
                nextIndex += 1
                inFlight += 1
                group.addTask {
                    await SearchService.searchOne(source: source,
                                                  keyword: keyword,
                                                  sourceOrder: sourceOrder)
                }
            }

            // 初始填满并发窗口。
            while inFlight < maxConcurrent, nextIndex < sources.count { addNext() }

            // 滑动窗口：每完成一个源立刻补位，慢源不再阻塞后续源（真正的「到达即插入」）。
            while let outcome = await group.next() {
                inFlight -= 1
                if nextIndex < sources.count {
                    if Date() < deadline, token == requestToken, !Task.isCancelled {
                        addNext()
                    } else {
                        // 预算耗尽或已取消：未启动的源直接记失败，并终止在跑任务。
                        failedSources += sources.count - nextIndex
                        nextIndex = sources.count
                        group.cancelAll()
                    }
                }
                guard token == requestToken, !isCancelled else { return }
                completedSources += 1
                switch outcome {
                case .success(let newItems):
                    self.merge(newItems)
                case .failure(let source, let message):
                    self.failedSources += 1
                    self.lastError = message
                    if let matched = sources.first(where: { $0.id == source }) {
                        self.failedSourceNames.append(matched.name)
                    }
                    healthRecords.append(HealthRecordEntry(sourceID: source,
                                                           success: false,
                                                           message: message))
                case .empty(let source):
                    healthRecords.append(HealthRecordEntry(sourceID: source,
                                                           success: true,
                                                           message: nil))
                }
            }
        }
        guard token == requestToken else { return }
        isSearching = false
        if completedSources < totalSources {
            failedSources = max(failedSources, totalSources - completedSources)
        }
        // 健康度批量落库：一次数组替换、一次发布、一次防抖写盘。
        SourceRepository.shared.recordBatch(healthRecords.map {
            SourceRepository.HealthEntry(sourceID: $0.sourceID, success: $0.success, message: $0.message)
        })
    }

    private enum SourceOutcome {
        case success([SearchItem])
        case empty(String)
        case failure(String, String)
    }

    /// 单源搜索：网络 + 规则解析整体不占用主线程，仅结果合并回主线程。
    private nonisolated static func searchOne(source: BookSource,
                                              keyword: String,
                                              sourceOrder: Int) async -> SourceOutcome {
        do {
            let html = try await withTimeout(seconds: perSourceTimeout) {
                try await NetworkClient.shared.search(source: source, keyword: keyword)
            }
            let base = URL(string: source.homeUrl)
            let extracted = try await RuleEngine.search(html: html, baseURL: base, source: source)
            guard !extracted.records.isEmpty else {
                return .empty(source.id)
            }
            let now = Date()
            let items = extracted.records.map { record in
                SearchItem(sourceID: source.id,
                           bookKey: record.bookKey ?? record.detailURL,
                           name: record.name,
                           author: record.author,
                           coverURL: record.coverURL,
                           detailURL: record.detailURL,
                           intro: record.intro,
                           matchLevel: matchLevel(keyword: keyword, name: record.name),
                           sourceOrder: sourceOrder,
                           arrivedAt: now,
                           sourceName: source.name)
            }
            return .success(items)
        } catch is CancellationError {
            return .failure(source.id, "已取消")
        } catch {
            return .failure(source.id, error.localizedDescription)
        }
    }

    /// 单源 7s 上限；超时中止该源但不阻塞其他源。
    private nonisolated static func withTimeout<T>(seconds: TimeInterval,
                                                   operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NetworkError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NetworkError.timeout
            }
            return result
        }
    }

    // MARK: - 合并与去重

    private func merge(_ incoming: [SearchItem]) {
        guard !incoming.isEmpty else { return }

        // 先给已有结果建「去重键 → 下标」索引，查找变成 O(1)。
        // 主项与备选都登记，保持原来“命中任一条即同组”的语义；先到先得。
        var index: [String: Int] = [:]
        for (idx, display) in items.enumerated() {
            let primaryKey = cachedDedupeKey(display.primary)
            if index[primaryKey] == nil { index[primaryKey] = idx }
            for alternative in display.alternatives {
                let key = cachedDedupeKey(alternative)
                if index[key] == nil { index[key] = idx }
            }
        }

        // 健康度一次性建索引，避免每次比较都线性查书源。
        var health: [String: Double] = [:]
        for source in SourceRepository.shared.sources {
            health[source.id] = source.healthScore
        }

        var displays = items
        for item in incoming {
            let key = cachedDedupeKey(item)
            if let idx = index[key] {
                let existingPrimary = displays[idx].primary
                if SearchService.prefers(item, over: existingPrimary, health: health) {
                    // 新结果更优：降级旧主项为备选。
                    var alternatives = displays[idx].alternatives
                    alternatives.append(existingPrimary)
                    displays[idx] = SearchDisplayItem(primary: item, alternatives: alternatives)
                } else {
                    displays[idx].alternatives.append(item)
                }
            } else {
                index[key] = displays.count
                displays.append(SearchDisplayItem(primary: item, alternatives: []))
            }
        }
        displays.sort { lhs, rhs in
            if lhs.primary.matchLevel.rank != rhs.primary.matchLevel.rank {
                return lhs.primary.matchLevel.rank < rhs.primary.matchLevel.rank
            }
            if lhs.primary.sourceOrder != rhs.primary.sourceOrder {
                return lhs.primary.sourceOrder < rhs.primary.sourceOrder
            }
            return lhs.primary.arrivedAt < rhs.primary.arrivedAt
        }
        items = displays
    }

    private func cachedDedupeKey(_ item: SearchItem) -> String {
        if let cached = dedupeKeyCache[item.id] { return cached }
        let key = SearchService.dedupeKey(item)
        dedupeKeyCache[item.id] = key
        return key
    }

    private static func dedupeKey(_ item: SearchItem) -> String {
        "\(normalize(item.name))|\(normalize(item.author ?? ""))"
    }

    /// 健康度高、匹配等级更精确的优先（BR-23）。
    private static func prefers(_ lhs: SearchItem,
                                over rhs: SearchItem,
                                health: [String: Double]) -> Bool {
        let lhsHealth = health[lhs.sourceID] ?? 1
        let rhsHealth = health[rhs.sourceID] ?? 1
        if lhs.matchLevel.rank != rhs.matchLevel.rank {
            return lhs.matchLevel.rank < rhs.matchLevel.rank
        }
        if lhsHealth != rhsHealth { return lhsHealth > rhsHealth }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private nonisolated static func matchLevel(keyword: String, name: String) -> MatchLevel {
        let k = normalize(keyword)
        let n = normalize(name)
        if n == k { return .exact }
        if n.contains(k) || k.contains(n) { return .contains }
        return .other
    }

    private nonisolated static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "zh_CN"))
        let kept = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || isCJK($0)
        }
        return String(String.UnicodeScalarView(kept))
    }

    private nonisolated static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value)
    }
}
