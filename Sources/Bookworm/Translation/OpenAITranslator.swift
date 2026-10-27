import Foundation

/// Uses the OpenAI Chat Completions endpoint with a user-supplied API key.
/// The system prompt steers the model to return only the translation
/// (no explanations, no quotes) so the result can be slotted straight into
/// the tooltip overlay.
struct OpenAITranslator: TranslationEngine {
    let apiKey: String
    let model: String

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        self.model = model ?? "gpt-4o-mini"
    }

    func translate(_ text: String,
                   sourceLang: String?,
                   targetLang: String) async throws -> String {
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let sourceClause = (sourceLang == nil || sourceLang == "auto")
            ? "detected source language"
            : sourceLang!
        let system = "You translate manga and comic dialogue from \(sourceClause) to \(targetLang). Reply with only the translation. No quotes, no explanations, no language labels. Preserve sound effects as English equivalents when natural; otherwise transliterate. If the input is already in \(targetLang), return it unchanged."

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": text],
            ],
            "temperature": 0.2,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let err as URLError {
            throw TranslationError.network(err)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Surface OpenAI's own error message if the body is JSON.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw TranslationError.parsing("OpenAI 返回 \(http.statusCode)：\(msg)")
            }
            throw TranslationError.badResponse(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parsing("OpenAI 响应格式异常")
        }
        // Strip leading/trailing quotes the model sometimes wraps even when
        // we ask it not to.
        var out = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if (out.hasPrefix("\"") && out.hasSuffix("\"")) ||
           (out.hasPrefix("「") && out.hasSuffix("」")) ||
           (out.hasPrefix("“") && out.hasSuffix("”")) {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }
}
