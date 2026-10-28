import Foundation

/// 网络请求错误分类，用于决定是否重试（BR-63）。
enum NetworkError: LocalizedError {
    case cancelled
    case timeout
    /// 可重试的连接类错误。
    case retryable(String)
    /// 不可重试：404、规则不匹配、需要登录等。
    case fatal(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消"
        case .timeout: return "请求超时"
        case .retryable(let m): return m
        case .fatal(let m): return m
        }
    }

    var isRetryable: Bool {
        switch self {
        case .timeout, .retryable: return true
        case .cancelled, .fatal: return false
        }
    }
}

struct HTTPResult {
    var data: Data
    var status: Int
    var finalURL: URL
    var contentType: String?
}

/// 所有在线书源请求的唯一出口：URLSession、超时、重试、编码探测与 `{{302}}`。
actor NetworkClient {
    static let shared = NetworkClient()

    private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private var insecureSessions: [String: URLSession] = [:]

    // MARK: - 对外请求

    /// 搜索请求：处理 `###keyword###`、`{{gb2312}}`、`{{escape}}` 与 `{{302}}`（BR-17、BR-18）。
    func search(source: BookSource, keyword: String) async throws -> String {
        let timeout = requestTimeout(source)
        if source.searchUrl.contains("{{302}}") {
            let formURL = NetworkClient.buildSearchURL(source: source, keyword: keyword)
            guard let url = formURL else { throw NetworkError.fatal("搜索地址不合法") }
            let usesGB = source.searchUrl.contains("{{gb2312}}")
            let body = "keyword=\(NetworkClient.percentEncode(keyword, gb18030: usesGB))"
            let first = try await performRaw(url: url,
                                          source: source,
                                          method: "POST",
                                          body: body,
                                          followRedirect: false,
                                          timeout: timeout)
            guard first.status == 301 || first.status == 302 || first.status == 303 || first.status == 307,
                  let location = first.location,
                  let next = URL(string: location, relativeTo: url) else {
                throw NetworkError.fatal("302 跳转缺失 Location")
            }
            let second = try await performRaw(url: next,
                                           source: source,
                                           method: "GET",
                                           body: nil,
                                           followRedirect: true,
                                           timeout: timeout)
            return NetworkClient.decode(second.zero)
        }
        guard let url = NetworkClient.buildSearchURL(source: source, keyword: keyword) else {
            throw NetworkError.fatal("搜索地址不合法")
        }
        let result = try await performRaw(url: url,
                                       source: source,
                                       method: "GET",
                                       body: nil,
                                       followRedirect: true,
                                       timeout: timeout)
        return NetworkClient.decode(result.zero)
    }

    /// 目录 / 正文 / 详情页请求。
    func fetchPage(url: URL,
                   source: BookSource,
                   isContent: Bool,
                   timeout: TimeInterval? = nil) async throws -> String {
        let seconds = timeout ?? requestTimeout(source, isContent: isContent)
        let method = (isContent ? source.request?.contentMethod : nil)?.uppercased() == "POST" ? "POST" : "GET"
        let result = try await performRaw(url: url,
                                       source: source,
                                       method: method,
                                       body: nil,
                                       followRedirect: true,
                                       timeout: seconds)
        return NetworkClient.decode(result.zero)
    }

    // MARK: - 模板

    static func buildSearchURL(source: BookSource, keyword: String) -> URL? {
        var template = source.searchUrl
            .replacingOccurrences(of: "{{302}}", with: "")
            .replacingOccurrences(of: "{{gb2312}}", with: "")
            .replacingOccurrences(of: "{{escape}}", with: "")
        let gb = source.searchUrl.contains("{{gb2312}}")
        let encoded = percentEncode(keyword, gb18030: gb)
        template = template.replacingOccurrences(of: "###keyword###", with: encoded)
        guard let resolved = URL(string: template, relativeTo: URL(string: source.homeUrl)) else {
            return nil
        }
        return resolved.absoluteURL
    }

    /// 展开 `###x###` 占位符并补全相对地址。
    static func expand(template: String,
                       replacements: [String: String],
                       base: URL?) -> URL? {
        var text = template
        for (key, value) in replacements {
            text = text.replacingOccurrences(of: "###\(key)###", with: value)
        }
        guard let url = URL(string: text, relativeTo: base) else { return nil }
        return url.absoluteURL
    }

    static func percentEncode(_ text: String, gb18030: Bool) -> String {
        if gb18030 {
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            let encoding = String.Encoding(rawValue: nsEncoding)
            if let data = text.data(using: encoding) {
                return data.map { byte -> String in
                    let scalar = UnicodeScalar(byte)
                    let ch = Character(scalar)
                    if ch.isLetter || ch.isNumber || "-._~".contains(ch) {
                        return String(ch)
                    }
                    return String(format: "%%%02X", byte)
                }.joined()
            }
        }
        return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    // MARK: - 解码

    /// 编码优先级：响应头 charset → `<meta charset>` 嗅探 → UTF-8 → GB18030（BR-17）。
    static func decode(_ result: HTTPResult) -> String {
        if let charset = charsetHint(from: result), let text = string(from: result.data, charset: charset) {
            return text
        }
        if let text = String(data: result.data, encoding: .utf8) {
            return text
        }
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        if let text = String(data: result.data, encoding: gb) {
            return text
        }
        return String(decoding: result.data, as: UTF8.self)
    }

    private static func charsetHint(from result: HTTPResult) -> String? {
        if let contentType = result.contentType,
           let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            let raw = contentType[range.upperBound...]
                .split(separator: ";").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if let raw, !raw.isEmpty { return raw }
        }
        // 嗅探前 2KB 的 meta charset。
        guard let head = String(data: result.data.prefix(2048), encoding: .isoLatin1),
              let range = head.range(of: "charset=", options: .caseInsensitive) else {
            return nil
        }
        let raw = head[range.upperBound...]
            .prefix(20)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'/>"))
        return raw.isEmpty ? nil : raw
    }

    private static func string(from data: Data, charset: String) -> String? {
        let lower = charset.lowercased()
        if lower == "gb2312" || lower == "gbk" || lower == "gb18030" {
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String(data: data,
                          encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)))
        }
        let nsEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard nsEncoding != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(nsEncoding)))
    }

    // MARK: - 执行

    private func requestTimeout(_ source: BookSource, isContent: Bool = false) -> TimeInterval {
        let ms = isContent
            ? (source.request?.contentTimeout ?? source.request?.timeout)
            : source.request?.timeout
        return TimeInterval((ms ?? 7000)) / 1000
    }

    private func performRaw(url: URL,
                            source: BookSource,
                            method: String,
                            body: String?,
                            followRedirect: Bool,
                            timeout: TimeInterval) async throws -> HTTPResultWithLocation {
        var attempt = 0
        while true {
            do {
                return try await once(url: url, source: source, method: method,
                                      body: body, followRedirect: followRedirect, timeout: timeout)
            } catch let error as NetworkError {
                // 重试 1 次 + 1s 退避（BR-63）。
                guard error.isRetryable, attempt == 0 else { throw error }
                attempt += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { throw NetworkError.cancelled }
            }
        }
    }

    private func once(url: URL,
                      source: BookSource,
                      method: String,
                      body: String?,
                      followRedirect: Bool,
                      timeout: TimeInterval) async throws -> HTTPResultWithLocation {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(source.request?.useMobileUA == true ? mobileUA : desktopUA,
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        if let headers = source.request?.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let cookie = source.request?.cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let session = session(for: source)
        let delegate = followRedirect ? nil : RedirectBlocker()
        let data: Data
        let response: URLResponse
        do {
            if let delegate {
                (data, response) = try await session.data(for: request, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw NetworkError.cancelled }
            switch error.code {
            case .timedOut:
                throw NetworkError.timeout
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateUntrusted:
                throw NetworkError.retryable("连接失败：\(error.localizedDescription)")
            default:
                throw NetworkError.retryable(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.fatal("响应格式异常")
        }
        if (500...599).contains(http.statusCode) {
            throw NetworkError.retryable("服务器错误 \(http.statusCode)")
        }
        if http.statusCode == 404 {
            throw NetworkError.fatal("页面不存在（404）")
        }
        if http.statusCode >= 400 {
            throw NetworkError.fatal("请求失败（\(http.statusCode)）")
        }
        return HTTPResultWithLocation(data: data,
                                      status: http.statusCode,
                                      finalURL: http.url ?? url,
                                      contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                      location: http.value(forHTTPHeaderField: "Location"))
    }

    private func session(for source: BookSource) -> URLSession {
        guard source.request?.allowInsecureTLS == true else {
            return URLSession.shared
        }
        if let cached = insecureSessions[source.id] { return cached }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config,
                                 delegate: InsecureTrustDelegate(),
                                 delegateQueue: nil)
        insecureSessions[source.id] = session
        return session
    }
}

private struct HTTPResultWithLocation {
    var data: Data
    var status: Int
    var finalURL: URL
    var contentType: String?
    var location: String?

    var zero: HTTPResult {
        HTTPResult(data: data, status: status, finalURL: finalURL, contentType: contentType)
    }
}

/// 不自动跟随跳转，便于读取 Location 后手动 GET（BR-18）。
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// 按源关闭 TLS 校验（BR-41 二次确认后才会走到这里）。
private final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
