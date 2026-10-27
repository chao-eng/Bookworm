import Foundation

/// Bing's public translator at bing.com/translator requires a per-session
/// token pair (IG + IID) before its ttranslatev3 endpoint will accept
/// requests. We scrape those out of the HTML on first use and cache them
/// for ~25 minutes (the token expires around 30 min).
actor BingSessionStore {
    static let shared = BingSessionStore()

    private struct Session {
        let ig: String
        let iid: String
        let key: String
        let token: String
        let fetchedAt: Date
    }

    private var current: Session?

    func session() async throws -> (ig: String, iid: String, key: String, token: String) {
        if let c = current, Date().timeIntervalSince(c.fetchedAt) < 25 * 60 {
            return (c.ig, c.iid, c.key, c.token)
        }
        let fresh = try await fetchFresh()
        current = fresh
        return (fresh.ig, fresh.iid, fresh.key, fresh.token)
    }

    private func fetchFresh() async throws -> Session {
        let url = URL(string: "https://www.bing.com/translator")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let err as URLError {
            throw TranslationError.network(err)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranslationError.badResponse(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw TranslationError.parsing("Bing 页面不是 UTF-8 编码")
        }

        guard let ig    = firstMatch(in: html, pattern: #"IG:"([^"]+)""#),
              let iid   = firstMatch(in: html, pattern: #"data-iid="([^"]+)""#),
              let token = firstMatch(in: html, pattern: #"params_AbusePreventionHelper\s*=\s*\[\s*\d+\s*,\s*"([^"]+)""#),
              let key   = firstMatch(in: html, pattern: #"params_AbusePreventionHelper\s*=\s*\[\s*(\d+)"#) else {
            throw TranslationError.parsing("找不到 Bing 会话令牌")
        }
        return Session(ig: ig, iid: iid, key: key, token: token, fetchedAt: Date())
    }

    private func firstMatch(in haystack: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let match = regex.firstMatch(in: haystack, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: haystack) else { return nil }
        return String(haystack[r])
    }
}

struct BingTranslator: TranslationEngine {
    func translate(_ text: String,
                   sourceLang: String?,
                   targetLang: String) async throws -> String {
        let session = try await BingSessionStore.shared.session()

        var components = URLComponents(string: "https://www.bing.com/ttranslatev3")!
        components.queryItems = [
            URLQueryItem(name: "isVertical", value: "1"),
            URLQueryItem(name: "&IG", value: session.ig),
            URLQueryItem(name: "IID", value: session.iid),
        ]
        guard let url = components.url else {
            throw TranslationError.parsing("无法构建 Bing 请求 URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.bing.com/translator", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "fromLang", value: mapLang(sourceLang ?? "auto", isSource: true)),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "to", value: mapLang(targetLang, isSource: false)),
            URLQueryItem(name: "token", value: session.token),
            URLQueryItem(name: "key", value: session.key),
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let err as URLError {
            throw TranslationError.network(err)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranslationError.badResponse(http.statusCode)
        }

        // Response: [{"detectedLanguage":{"language":"ja","score":1.0},"translations":[{"text":"...", "to":"en"}]}]
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let translations = first["translations"] as? [[String: Any]],
              let translated = translations.first?["text"] as? String else {
            // Sometimes Bing returns {"statusCode": 4xx, ...} when the session
            // expired — surface that explicitly.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = obj["statusCode"] as? Int {
                throw TranslationError.badResponse(code)
            }
            throw TranslationError.parsing("响应格式异常")
        }
        return translated
    }

    /// Map our internal language codes to Bing's expected codes.
    private func mapLang(_ code: String, isSource: Bool) -> String {
        if isSource && code == "auto" { return "auto-detect" }
        switch code {
        case "zh-CN": return "zh-Hans"
        case "zh-TW": return "zh-Hant"
        default:      return code
        }
    }
}
