import Foundation

/// Uses the public `translate.googleapis.com/translate_a/single` endpoint
/// (the same one Google's own browser extensions use). No auth, no quota
/// key — but the endpoint is technically unofficial, so treat any 4xx/5xx
/// as transient and let the user retry.
struct GoogleTranslator: TranslationEngine {
    func translate(_ text: String,
                   sourceLang: String?,
                   targetLang: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sourceLang ?? "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components.url else {
            throw TranslationError.parsing("无法构建请求 URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let err as URLError {
            throw TranslationError.network(err)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranslationError.badResponse(http.statusCode)
        }

        // Response shape:
        //   [[[ "<target>", "<source>", null, null, n], ...], ..., "<detected lang>", ...]
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw TranslationError.parsing("返回内容不是 JSON")
        }
        guard let outer = raw as? [Any], !outer.isEmpty,
              let chunks = outer.first as? [Any] else {
            throw TranslationError.parsing("响应格式异常")
        }

        // Concatenate every segment's translated text — Google chunks long
        // input into pieces and only the first piece is in chunks[0][0].
        var out = ""
        for chunk in chunks {
            if let pair = chunk as? [Any],
               let translated = pair.first as? String {
                out += translated
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
