import Foundation

/// Anything that can take a chunk of source text and produce a translation.
/// Implementations talk to a remote service over the network; the reader
/// caches results so the same text doesn't get re-translated across pages.
protocol TranslationEngine: Sendable {
    /// `sourceLang` may be nil — engines that support auto-detection should
    /// pick it up themselves. `targetLang` is a BCP-47-ish code (e.g. "en",
    /// "id", "ja"); each engine maps it to its own dialect.
    func translate(_ text: String,
                   sourceLang: String?,
                   targetLang: String) async throws -> String
}

enum TranslationEngineKind: String, CaseIterable, Identifiable, Codable {
    case google
    case bing
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google 翻译"
        case .bing:   return "Bing 翻译"
        case .openai: return "OpenAI (GPT)"
        }
    }

    var requiresAPIKey: Bool { self == .openai }
}

enum TranslationError: LocalizedError {
    case network(URLError)
    case badResponse(Int)
    case parsing(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .network(let e):     return "网络错误：\(e.localizedDescription)"
        case .badResponse(let s): return "翻译服务返回 HTTP \(s)。"
        case .parsing(let m):     return "无法解析翻译服务响应：\(m)"
        case .missingAPIKey:      return "缺少 OpenAI API 密钥，请在翻译设置中添加。"
        }
    }
}

/// In-memory cache keyed by (engine, source, target, text). Same text on
/// every page of a chapter only crosses the network once.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()

    private struct Key: Hashable {
        let engine: TranslationEngineKind
        let source: String
        let target: String
        let text: String
    }

    private var entries: [Key: String] = [:]
    private let limit = 4000

    func value(engine: TranslationEngineKind,
               source: String?,
               target: String,
               text: String) -> String? {
        entries[Key(engine: engine, source: source ?? "auto", target: target, text: text)]
    }

    func store(engine: TranslationEngineKind,
               source: String?,
               target: String,
               text: String,
               translation: String) {
        let key = Key(engine: engine, source: source ?? "auto", target: target, text: text)
        if entries.count >= limit {
            // Cheap eviction — drop ~10 % of the cache when we hit the cap.
            // Translation cards aren't security-sensitive so we don't need LRU.
            for k in entries.keys.prefix(limit / 10) { entries.removeValue(forKey: k) }
        }
        entries[key] = translation
    }

    /// How many translations are currently held. Surfaced in the settings
    /// popover so the Clear Cache button can show what it's about to drop.
    var count: Int { entries.count }

    /// Drop every cached translation. The next hover on each bubble will
    /// re-translate against whichever engine + language pair is selected
    /// at that moment. Useful when the user switches target language and
    /// wants to see fresh translations of the bubbles still on screen.
    func clear() {
        entries.removeAll(keepingCapacity: false)
    }
}

/// Factory that returns the appropriate concrete engine instance per kind.
/// Keeps callers from caring about the kind→class mapping.
enum TranslationEngineFactory {
    static func make(kind: TranslationEngineKind, apiKey: String?) -> TranslationEngine {
        switch kind {
        case .google: return GoogleTranslator()
        case .bing:   return BingTranslator()
        case .openai: return OpenAITranslator(apiKey: apiKey ?? "")
        }
    }
}

/// High-level convenience that handles cache lookup, kind dispatch, and
/// API-key enforcement.
@MainActor
enum Translator {
    static func translate(_ text: String,
                          source: String?,
                          target: String,
                          settings: TranslationSettings) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let kind = settings.engine
        if let cached = TranslationCache.shared.value(engine: kind,
                                                      source: source,
                                                      target: target,
                                                      text: trimmed) {
            return cached
        }

        if kind.requiresAPIKey, (settings.openAIAPIKey ?? "").isEmpty {
            throw TranslationError.missingAPIKey
        }
        let engine = TranslationEngineFactory.make(kind: kind,
                                                    apiKey: settings.openAIAPIKey)
        let result = try await engine.translate(trimmed,
                                                 sourceLang: source,
                                                 targetLang: target)
        TranslationCache.shared.store(engine: kind,
                                       source: source,
                                       target: target,
                                       text: trimmed,
                                       translation: result)
        return result
    }
}

/// Languages we expose in the settings UI. Order matters — most common
/// reading-language pairs come first.
enum SupportedLanguage: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case en, ja, ko, zhCN = "zh-CN", zhTW = "zh-TW"
    case fr, de, es, it, pt, ru, ar
    case id, vi, th, tr, nl, sv, pl, uk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:  return "自动检测"
        case .en:    return "英语"
        case .ja:    return "日语"
        case .ko:    return "韩语"
        case .zhCN:  return "简体中文"
        case .zhTW:  return "繁体中文"
        case .fr:    return "法语"
        case .de:    return "德语"
        case .es:    return "西班牙语"
        case .it:    return "意大利语"
        case .pt:    return "葡萄牙语"
        case .ru:    return "俄语"
        case .ar:    return "阿拉伯语"
        case .id:    return "印尼语"
        case .vi:    return "越南语"
        case .th:    return "泰语"
        case .tr:    return "土耳其语"
        case .nl:    return "荷兰语"
        case .sv:    return "瑞典语"
        case .pl:    return "波兰语"
        case .uk:    return "乌克兰语"
        }
    }

    /// macOS Vision framework recognition languages (BCP-47-ish). `auto`
    /// returns nil so we can ask Vision to detect.
    var visionRecognitionLanguage: String? {
        switch self {
        case .auto:  return nil
        case .en:    return "en-US"
        case .ja:    return "ja-JP"
        case .ko:    return "ko-KR"
        case .zhCN:  return "zh-Hans"
        case .zhTW:  return "zh-Hant"
        case .fr:    return "fr-FR"
        case .de:    return "de-DE"
        case .es:    return "es-ES"
        case .it:    return "it-IT"
        case .pt:    return "pt-BR"
        case .ru:    return "ru-RU"
        case .ar:    return "ar-SA"
        case .id:    return nil   // Vision doesn't reliably do Indonesian; let auto-detect handle.
        case .vi:    return "vi-VN"
        case .th:    return "th-TH"
        case .tr:    return "tr-TR"
        case .nl:    return "nl-NL"
        case .sv:    return "sv-SE"
        case .pl:    return "pl-PL"
        case .uk:    return "uk-UA"
        }
    }
}
