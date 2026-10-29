import Foundation
import WebKit

// MARK: - JSON `$$` 路径

/// 解析 `key$$a.index$$*.key$$b` 形式的键路径（09 §4）。
enum JSONPathResolver {
    enum Step {
        case key(String)
        case index(Int)
        case allIndices
    }

    /// 无 `$$` 前缀的普通键按直接键名处理，并记录一次告警。
    private nonisolated(unsafe) static var warnedPlainKeys: Set<String> = []

    /// 解析结果缓存：搜索时「每条结果 × 每个字段」都会重复解析同一个路径，
    /// 而规则里的路径字符串总共只有几十个。加锁是因为解析可能来自不同上下文。
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var parsedCache: [String: [Step]] = [:]

    static func parse(_ path: String) -> [Step] {
        // 解析本身很便宜，直接持锁完成「查缓存 → 未命中再解析 → 写缓存」，
        // 顺带保护了 warnedPlainKeys 的写入。
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = parsedCache[path] { return cached }
        let steps = parseUncached(path)
        parsedCache[path] = steps
        return steps
    }

    private static func parseUncached(_ path: String) -> [Step] {
        var steps: [Step] = []
        for raw in path.split(separator: ".").map(String.init) {
            if raw.hasPrefix("index$$") {
                let value = String(raw.dropFirst("index$$".count))
                if value == "*" {
                    steps.append(.allIndices)
                } else if let n = Int(value) {
                    steps.append(.index(n))
                }
            } else if raw.hasPrefix("key$$") {
                steps.append(.key(String(raw.dropFirst("key$$".count))))
            } else if !raw.isEmpty {
                if !warnedPlainKeys.contains(raw) {
                    warnedPlainKeys.insert(raw)
                    Diagnostics.log("jsonpath", "普通键按直接键名处理：\(raw)")
                }
                steps.append(.key(raw))
            }
        }
        return steps
    }

    static func resolve(_ path: String, in root: Any) -> [Any] {
        var current: [Any] = [root]
        for step in parse(path) {
            var next: [Any] = []
            switch step {
            case .key(let key):
                for value in current {
                    if let dict = value as? [String: Any], let child = dict[key] {
                        next.append(child)
                    }
                }
            case .index(let index):
                for value in current {
                    if let array = value as? [Any], array.indices.contains(index) {
                        next.append(array[index])
                    }
                }
            case .allIndices:
                for value in current {
                    if let array = value as? [Any] {
                        next.append(contentsOf: array)
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// 列表路径：末级键若直接返回数组，则展开为数组元素（与老版规则的列表语义一致）。
    static func resolveList(_ path: String, in root: Any) -> [Any] {
        var output: [Any] = []
        for node in resolve(path, in: root) {
            if let array = node as? [Any] {
                output.append(contentsOf: array)
            } else {
                output.append(node)
            }
        }
        return output
    }

    static func string(_ path: String, in root: Any) -> String? {
        guard let first = resolve(path, in: root).first else { return nil }
        if let s = first as? String { return s }
        if let n = first as? NSNumber {
            let double = n.doubleValue
            return double == double.rounded() ? String(Int(double)) : String(double)
        }
        return nil
    }
}

// MARK: - 规则求值结果

enum RuleError: LocalizedError {
    case empty(String)
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case .empty(let what): return "\(what)为空"
        case .mismatch(let what): return "规则不匹配：\(what)"
        }
    }
}

struct ExtractedSearchRecord {
    var name: String
    var author: String?
    var coverURL: String?
    var detailURL: String
    var bookKey: String?
    var intro: String?
}

struct ExtractedSearch {
    var records: [ExtractedSearchRecord]
    var skipped: Int
}

struct ExtractedChapter {
    var title: String
    var url: URL
    var level: Int
}

struct ExtractedContent {
    var title: String?
    var text: String
}

// MARK: - 规则引擎

/// 规则求值：JSON 源走 `JSONPathResolver`，HTML 源走离屏 `WKWebView`（禁网、3s 超时）。
@MainActor
enum RuleEngine {
    // MARK: 搜索

    static func search(html: String, baseURL: URL?, source: BookSource) async throws -> ExtractedSearch {
        if source.isJSON, source.searchRule.listPath.contains("$$") {
            return try searchJSON(html: html, baseURL: baseURL, source: source)
        }
        // `kind = json` 但 listPath 无 `$$`：降级为 HTML 解析（BR-20）。
        return try await searchHTML(html: html, baseURL: baseURL, source: source)
    }

    private static func searchJSON(html: String, baseURL: URL?, source: BookSource) throws -> ExtractedSearch {
        let root = try parseJSON(html)
        let rule = source.searchRule
        var nodes = JSONPathResolver.resolveList(rule.listPath, in: root)
        if let limit = rule.limit {
            if limit < 0 {
                nodes = Array(nodes.reversed())
                nodes = Array(nodes.prefix(abs(limit)))
            } else {
                nodes = Array(nodes.prefix(limit))
            }
        }
        var records: [ExtractedSearchRecord] = []
        var skipped = 0
        for node in nodes {
            guard let name = JSONPathResolver.string(rule.namePath, in: node),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped += 1
                continue
            }
            let bookKey = rule.bookIdPath.flatMap { JSONPathResolver.string($0, in: node) }
            let rawURL = rule.urlPath.contains("$$")
                ? JSONPathResolver.string(rule.urlPath, in: node)
                : rule.urlPath
            guard let rawURL, !rawURL.isEmpty,
                  let detail = NetworkClient.expand(template: rawURL,
                                                    replacements: ["name": name,
                                                                   "book_id": bookKey ?? "",
                                                                   "bookKey": bookKey ?? ""],
                                                    base: baseURL) else {
                skipped += 1
                continue
            }
            records.append(ExtractedSearchRecord(
                name: name,
                author: rule.authorPath.flatMap { JSONPathResolver.string($0, in: node) },
                coverURL: rule.coverPath.flatMap { JSONPathResolver.string($0, in: node) }
                    .flatMap { NetworkClient.expand(template: $0, replacements: [:], base: baseURL)?.absoluteString },
                detailURL: detail.absoluteString,
                bookKey: bookKey ?? detail.absoluteString,
                intro: rule.remarkPath.flatMap { JSONPathResolver.string($0, in: node) }
            ))
        }
        return ExtractedSearch(records: records, skipped: skipped)
    }

    private static func searchHTML(html: String, baseURL: URL?, source: BookSource) async throws -> ExtractedSearch {
        let rule = source.searchRule
        var rules: [String: Any] = [
            "list": rule.listPath,
            "name": rule.namePath,
            "url": rule.urlPath
        ]
        if let author = rule.authorPath { rules["author"] = author }
        if let cover = rule.coverPath { rules["cover"] = cover }
        if let coverAttr = rule.coverAttr { rules["coverAttr"] = coverAttr }
        if let urlAttr = rule.urlAttr { rules["urlAttr"] = urlAttr }
        if let bookId = rule.bookIdPath { rules["bookId"] = bookId }
        if let remark = rule.remarkPath { rules["remark"] = remark }
        if let limit = rule.limit { rules["limit"] = limit }

        let script = """
        (function(r){
          \(selectorJS)
          function textOf(node){
            if(!node) return '';
            return (node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim();
          }
          function valueOf(scope, path, attr){
            if(!path) return attr ? ((scope.getAttribute && scope.getAttribute(attr)) || '') : '';
            var nodes = qsa(scope, path);
            if(!nodes.length) return '';
            if(attr) return nodes[0].getAttribute(attr) || '';
            return textOf(nodes[0]);
          }
          var out = [];
          var nodes = qsa(document, r.list);
          if (r.limit !== undefined) {
            if (r.limit < 0) { nodes = nodes.slice().reverse().slice(0, Math.abs(r.limit)); }
            else { nodes = nodes.slice(0, r.limit); }
          }
          nodes.forEach(function(node){
            var name = valueOf(node, r.name, null);
            if(!name) return;
            var bookId = r.bookId ? valueOf(node, r.bookId, null) : '';
            var rawURL = r.url || '';
            var url = '';
            if (rawURL.indexOf('###') >= 0) {
              url = rawURL.replace(/###book_id###/g, encodeURIComponent(bookId))
                          .replace(/###name###/g, encodeURIComponent(name));
            } else if (/^https?:/i.test(rawURL)) {
              url = rawURL;
            } else {
              url = valueOf(node, rawURL, r.urlAttr || null);
            }
            if (!url) {
              var a = qsa(node, 'a')[0];
              if (a) url = a.getAttribute(r.urlAttr || 'href') || '';
            }
            var cover = r.cover ? valueOf(node, r.cover, r.coverAttr || null) : '';
            out.push({
              name: name,
              author: r.author ? valueOf(node, r.author, null) : '',
              cover: cover,
              url: url,
              bookKey: bookId,
              intro: r.remark ? valueOf(node, r.remark, null) : ''
            });
          });
          return JSON.stringify(out);
        })(\(jsonLiteral(rules)))
        """
        let raw = try await evaluate(html: html, baseURL: baseURL, script: script)
        let array = (raw as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []

        var records: [ExtractedSearchRecord] = []
        var skipped = 0
        for entry in array {
            let name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { skipped += 1; continue }
            let urlString = (entry["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty,
                  let url = URL(string: urlString, relativeTo: baseURL)?.absoluteURL else {
                skipped += 1
                continue
            }
            let coverRaw = (entry["cover"] as? String ?? "")
            let cover = coverRaw.isEmpty ? nil : URL(string: coverRaw, relativeTo: baseURL)?.absoluteString
            let bookKey = (entry["bookKey"] as? String ?? "")
            records.append(ExtractedSearchRecord(
                name: name,
                author: nonEmpty(entry["author"] as? String),
                coverURL: cover,
                detailURL: url.absoluteString,
                bookKey: bookKey.isEmpty ? url.absoluteString : bookKey,
                intro: nonEmpty(entry["intro"] as? String)
            ))
        }
        return ExtractedSearch(records: records, skipped: skipped)
    }

    /// 老版书源的选择器常在中间层级使用 `:eq/:gt/:lt`，这里按层级递归截取，
    /// 使 `.listmain dd:gt(11) a` 这类写法也能命中。
    private static let selectorJS: String = """
    function qsa(root, sel){
      if(!sel) return [];
      sel = String(sel).trim();
      if(!sel) return [];
      var parts = splitSel(sel);
      if(parts.length > 1){
        var acc = [];
        for(var i=0;i<parts.length;i++){ acc = acc.concat(qsa(root, parts[i])); }
        return uniqNodes(acc);
      }
      var m = sel.match(/:((?:eq|gt|lt))\\((\\d+)\\)/);
      if(!m) return query(root, sel, true);
      var before = sel.slice(0, m.index).trim();
      var after = sel.slice(m.index + m[0].length).trim();
      var nodes = before ? qsa(root, before)
                         : (root === document ? Array.prototype.slice.call(document.querySelectorAll('*')) : [root]);
      var n = parseInt(m[2], 10);
      if(m[1] === 'eq') nodes = nodes[n] ? [nodes[n]] : [];
      else if(m[1] === 'gt') nodes = nodes.slice(n + 1);
      else nodes = nodes.slice(0, n);
      if(!after) return nodes;
      var out = [];
      for(var j=0;j<nodes.length;j++){ out = out.concat(qsa(nodes[j], after)); }
      return uniqNodes(out);
    }
    function query(root, sel, includeSelf){
      var s = sel.charAt(0) === '>' ? ':scope ' + sel : sel;
      var nodes = [];
      try { if(root !== document && includeSelf && root.matches && root.matches(s)) nodes.push(root); } catch(e) {}
      try { nodes = nodes.concat(Array.prototype.slice.call(root.querySelectorAll(s))); } catch(e) {}
      return nodes;
    }
    function uniqNodes(list){
      var seen = new Set(); var out = [];
      for(var i=0;i<list.length;i++){ if(!seen.has(list[i])){ seen.add(list[i]); out.push(list[i]); } }
      return out;
    }
    function splitSel(sel){
      var parts = [], cur = '', depth = 0, quote = null;
      for(var i=0;i<sel.length;i++){
        var c = sel[i];
        if(quote){ cur += c; if(c === quote) quote = null; continue; }
        if(c === '"' || c === "'"){ quote = c; cur += c; continue; }
        if(c === '[' || c === '('){ depth++; cur += c; continue; }
        if(c === ']' || c === ')'){ depth--; cur += c; continue; }
        if(c === ',' && depth === 0){ parts.push(cur.trim()); cur = ''; continue; }
        cur += c;
      }
      if(cur.trim()) parts.push(cur.trim());
      return parts.filter(function(p){ return p.length > 0; });
    }
    """

    // MARK: 目录

    static func chapters(html: String, baseURL: URL?, source: BookSource) async throws -> [ExtractedChapter] {
        let rule = source.menuRule
        if source.isJSON, rule.listPath.contains("$$") {
            return try chaptersJSON(html: html, baseURL: baseURL, source: source)
        }
        var rules: [String: Any] = ["list": rule.listPath]
        if let id = rule.itemIdPath { rules["itemId"] = id }
        if let name = rule.itemNamePath { rules["itemName"] = name }
        if let url = rule.itemUrlPath { rules["itemUrl"] = url }
        if let attr = rule.attrBinding { rules["attr"] = attr }
        let script = """
        (function(r){
          \(selectorJS)
          function textOf(node){ return node ? (node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim() : ''; }
          function valueOf(scope, path, attr){
            if(!path) return attr ? ((scope.getAttribute && scope.getAttribute(attr)) || '') : '';
            var nodes = qsa(scope, path);
            if(!nodes.length) return '';
            if(attr) return nodes[0].getAttribute(attr) || '';
            return textOf(nodes[0]);
          }
          var out = [];
          var nodes = qsa(document, r.list);
          nodes.forEach(function(node, i){
            var itemId = r.itemId ? valueOf(node, r.itemId, null) : '';
            var title = r.itemName ? valueOf(node, r.itemName, null) : '';
            if(!title) title = textOf(node);
            var url = '';
            if (r.itemUrl) {
              if (r.itemUrl.indexOf('###') >= 0) {
                url = r.itemUrl.replace(/###item_id###/g, encodeURIComponent(itemId))
                              .replace(/###index###/g, String(i))
                              .replace(/###title###/g, encodeURIComponent(title));
              } else {
                url = valueOf(node, r.itemUrl, r.attr || null);
              }
            }
            if(!url) {
              var a = qsa(node, 'a')[0] || (node.tagName === 'A' ? node : null);
              if (a) url = a.getAttribute(r.attr || 'href') || '';
            }
            if(!url && node.getAttribute) url = node.getAttribute(r.attr || 'href') || '';
            if(!url) return;
            out.push({title: title || ('第 ' + (i + 1) + ' 章'), url: url});
          });
          return JSON.stringify(out);
        })(\(jsonLiteral(rules)))
        """
        let raw = try await evaluate(html: html, baseURL: baseURL, script: script)
        let array = (raw as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []

        var chapters: [ExtractedChapter] = []
        for entry in array {
            let title = (entry["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let urlString = (entry["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: urlString, relativeTo: baseURL)?.absoluteURL else { continue }
            chapters.append(ExtractedChapter(title: title.isEmpty ? "第 \(chapters.count + 1) 章" : title,
                                             url: url,
                                             level: 0))
        }
        guard !chapters.isEmpty else { throw RuleError.empty("目录") }
        return chapters
    }

    private static func chaptersJSON(html: String, baseURL: URL?, source: BookSource) throws -> [ExtractedChapter] {
        let rule = source.menuRule
        let root = try parseJSON(html)
        let nodes = JSONPathResolver.resolveList(rule.listPath, in: root)
        var chapters: [ExtractedChapter] = []
        for node in nodes {
            let title = (rule.itemNamePath.flatMap { JSONPathResolver.string($0, in: node) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let itemID = rule.itemIdPath.flatMap { JSONPathResolver.string($0, in: node) } ?? ""
            var rawURL: String?
            if let itemUrlPath = rule.itemUrlPath {
                // `item_url` 可能是 `$$` 路径，也可能是含 `###item_id###` 的固定模板。
                rawURL = itemUrlPath.contains("$$")
                    ? JSONPathResolver.string(itemUrlPath, in: node)
                    : itemUrlPath
            }
            if rawURL == nil {
                rawURL = JSONPathResolver.string("key$$url", in: node)
            }
            guard let rawURL, !rawURL.isEmpty else { continue }
            let expanded = rawURL
                .replacingOccurrences(of: "###item_id###", with: itemID)
                .replacingOccurrences(of: "###title###", with: title)
            guard let url = URL(string: expanded, relativeTo: baseURL)?.absoluteURL else { continue }
            chapters.append(ExtractedChapter(title: title.isEmpty ? "第 \(chapters.count + 1) 章" : title,
                                             url: url,
                                             level: 0))
        }
        guard !chapters.isEmpty else { throw RuleError.empty("目录") }
        return chapters
    }

    /// 目录分页的「下一页」链接。
    static func nextChapterPage(html: String, baseURL: URL?, source: BookSource) async throws -> URL? {
        let rule = source.menuRule
        let selector = rule.nextPageSelector ?? "a.next"
        let text = rule.nextPageText
        let script = """
        (function(r){
          var nodes = Array.prototype.slice.call(document.querySelectorAll(r.selector));
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            var label = (node.innerText || node.textContent || '').trim();
            if (r.text && label.indexOf(r.text) < 0) continue;
            var href = node.getAttribute('href') || '';
            if (href) return href;
          }
          return '';
        })(\(jsonLiteral(["selector": selector, "text": text ?? ""])))
        """
        let raw = try await evaluate(html: html, baseURL: baseURL, script: script)
        guard let href = raw as? String, !href.isEmpty,
              let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return url
    }

    // MARK: 正文

    static func content(html: String, baseURL: URL?, source: BookSource) async throws -> ExtractedContent {
        let rule = source.contentRule
        if source.isJSON, rule.contentPath.contains("$$") {
            let root = try parseJSON(html)
            let title = rule.titlePath.flatMap { JSONPathResolver.string($0, in: root) }
            let values = JSONPathResolver.resolveList(rule.contentPath, in: root)
            let joined = values.compactMap { value -> String? in
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
                return nil
            }.joined(separator: "\n")
            let text = normalizeText(plainText(fromHTML: joined))
            guard !text.isEmpty else { throw RuleError.empty("正文") }
            return ExtractedContent(title: title, text: text)
        }

        var rules: [String: Any] = ["content": rule.contentPath]
        if let title = rule.titlePath { rules["title"] = title }
        if let type = rule.contentType { rules["type"] = type }
        if let attr = rule.contentAttr { rules["attr"] = attr }
        if let selectors = rule.removeSelectors, !selectors.isEmpty { rules["remove"] = selectors }
        let script = """
        (function(r){
          \(selectorJS)
          function textOf(node){ return node ? (node.innerText || node.textContent || '') : ''; }
          if (r.remove) {
            r.remove.forEach(function(sel){
              try { Array.prototype.slice.call(document.querySelectorAll(sel)).forEach(function(n){ n.remove(); }); } catch(e) {}
            });
          }
          var title = r.title ? (qsa(document, r.title)[0] ? textOf(qsa(document, r.title)[0]).trim() : '') : '';
          var nodes = qsa(document, r.content);
          var text = '';
          if (nodes.length) {
            if (r.type === '2' && r.attr) {
              text = nodes[0].getAttribute(r.attr) || '';
            } else {
              text = nodes.map(function(n){ return textOf(n); }).join('\\n');
            }
          }
          return JSON.stringify({title: title, content: text});
        })(\(jsonLiteral(rules)))
        """
        let raw = try await evaluate(html: html, baseURL: baseURL, script: script)
        let dict = (raw as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var text = (dict["content"] as? String ?? "")
        text = normalizeText(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuleError.empty("正文")
        }
        let title = nonEmpty(dict["title"] as? String)
        return ExtractedContent(title: title, text: text)
    }

    /// 正文分页的「下一页」链接。
    static func nextContentPage(html: String, baseURL: URL?, source: BookSource) async throws -> URL? {
        guard let path = source.contentRule.nextPagePath, !path.isEmpty else { return nil }
        let script = """
        (function(sel){
          var nodes = Array.prototype.slice.call(document.querySelectorAll(sel));
          if (!nodes.length) return '';
          var n = nodes[0];
          return n.getAttribute('href') || '';
        })(\(jsonLiteral(path)))
        """
        let raw = try await evaluate(html: html, baseURL: baseURL, script: script)
        guard let href = raw as? String, !href.isEmpty,
              let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return url
    }

    // MARK: 正文清洗与完整性

    /// `content_filter`：Base64 解码后按 `%&&%` 拆分逐段移除；单条减少 >20% 视为误伤回滚（BR-32、BR-33）。
    static func applyFilters(_ text: String, filters: [String]?) -> (text: String, rolledBack: Bool) {
        guard let filters, !filters.isEmpty else { return (text, false) }
        var result = text
        var rolledBack = false
        for encoded in filters {
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else { continue }
            for fragment in decoded.components(separatedBy: "%&&%") {
                let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let candidate = result.replacingOccurrences(of: trimmed, with: "")
                guard !candidate.isEmpty,
                      Double(candidate.count) >= Double(result.count) * 0.8 else {
                    // 误伤：回滚本条过滤结果且不写缓存（BR-33）。
                    Diagnostics.log("content-filter", "过滤误伤，已回滚")
                    rolledBack = true
                    continue
                }
                result = candidate
            }
        }
        return (result, rolledBack)
    }

    static let incompleteKeywords = ["本章未完", "请登录", "继续阅读", "章节错误", "内容加载失败"]

    static func isComplete(_ text: String) -> Bool {
        !incompleteKeywords.contains { text.contains($0) }
    }

    // MARK: 工具

    private static func parseJSON(_ html: String) throws -> Any {
        // `},]` → `}]` 修复（BR-20）。
        let repaired = html.replacingOccurrences(of: "},]", with: "}]")
        guard let data = repaired.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw RuleError.mismatch("响应不是合法 JSON")
        }
        return root
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 块级标签（段落 / 换行 / 标题 / 列表 / 表格行）统一替换为换行。
    private static let blockTagRegex = try! NSRegularExpression(
        pattern: "</?(p|div|br|h[1-6]|li|tr)[^>]*>",
        options: [.caseInsensitive])
    /// 其余标签整体丢弃。
    private static let anyTagRegex = try! NSRegularExpression(pattern: "<[^>]+>")

    /// JSON 源正文常内嵌 HTML 片段，先转成纯文本段落。
    private static func plainText(fromHTML string: String) -> String {
        guard string.contains("<") else { return string }
        var text = string
        // 预编译正则：正文清洗每章都跑，`.regularExpression` 每次调用都要重新编译。
        text = blockTagRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "\n")
        text = anyTagRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&ldquo;": "“", "&rdquo;": "”"]
        for (key, value) in entities {
            text = text.replacingOccurrences(of: key, with: value)
        }
        return text
    }

    private static func normalizeText(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var output: [String] = []
        var blank = 0
        for line in lines {
            if line.isEmpty {
                blank += 1
                if blank <= 1 { output.append("") }
            } else {
                blank = 0
                output.append(line)
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonLiteral(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func evaluate(html: String, baseURL: URL?, script: String) async throws -> Any? {
        try await RuleWebViewPool.shared.evaluate(html: html, baseURL: baseURL, script: script)
    }
}

// MARK: - 离屏 WebView 池

/// 3 个离屏 `WKWebView`，禁网、禁本地存储、3s 超时（BR-44）。
@MainActor
final class RuleWebViewPool {
    static let shared = RuleWebViewPool()

    private var idle: [WKWebView] = []
    private var waiters: [CheckedContinuation<WKWebView, Never>] = []
    private var created = 0
    private let maxCount = 3
    private var blockRuleList: WKContentRuleList?
    private var blockListPrepared = false
    private var blockListCompiling = false
    private var blockListWaiters: [CheckedContinuation<Void, Never>] = []

    func evaluate(html: String, baseURL: URL?, script: String) async throws -> Any? {
        await prepareBlockList()
        let webView = await borrow()
        do {
            try await load(html: html, baseURL: baseURL, in: webView)
            return try await run(script: script, in: webView)
        } catch {
            // 超时说明这个 webview 可能已卡死（WebKit 不再回调），
            // 直接丢弃并从池里补一个新的，绝不能把它还回池里。
            if RuleWebViewPool.isTimeout(error) {
                discard(webView)
            } else {
                release(webView)
            }
            throw error
        }
    }

    // MARK: 池

    private func borrow() async -> WKWebView {
        if let webView = idle.popLast() { return webView }
        if created < maxCount {
            created += 1
            return makeWebView()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release(_ webView: WKWebView) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: webView)
        } else {
            idle.append(webView)
        }
    }

    /// 丢弃一个已卡死的 webview。若有人在等空闲实例，直接补一个新的，
    /// 否则 `waiters` 会永远挂起。
    private func discard(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        if created > 0 { created -= 1 }
        if let waiter = waiters.first {
            waiters.removeFirst()
            created += 1
            waiter.resume(returning: makeWebView())
        }
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if case NetworkError.timeout = error { return true }
        return false
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: """
            (function(){
              try { window.fetch = function(){ return Promise.reject(new Error('blocked')); }; } catch(e){}
              try { window.XMLHttpRequest = function(){ throw new Error('blocked'); }; } catch(e){}
              try { window.WebSocket = function(){ throw new Error('blocked'); }; } catch(e){}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        if let blockRuleList {
            controller.add(blockRuleList)
        }
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isHidden = true
        return webView
    }

    /// 阻断所有网络请求与本地存储（BR-44）。
    private func prepareBlockList() async {
        if blockListPrepared { return }
        if blockListCompiling {
            await withCheckedContinuation { continuation in
                blockListWaiters.append(continuation)
            }
            return
        }
        blockListCompiling = true
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        let list = await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "bookworm-block-all",
                encodedContentRuleList: rules) { list, _ in
                    continuation.resume(returning: list)
                }
        }
        blockRuleList = list
        blockListPrepared = true
        blockListCompiling = false
        let pending = blockListWaiters
        blockListWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    // MARK: 加载

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var resumed = false
        private var completion: ((Error?) -> Void)?

        func setCompletion(_ completion: @escaping (Error?) -> Void) {
            self.completion = completion
        }

        func finish(_ error: Error?) {
            guard !resumed else { return }
            resumed = true
            completion?(error)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(error)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            finish(error)
        }
    }

    private func load(html: String, baseURL: URL?, in webView: WKWebView) async throws {
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.setCompletion { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            webView.loadHTMLString(html, baseURL: baseURL)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                waiter.finish(NetworkError.timeout)
            }
        }
    }

    /// 保证 `run` 的 continuation 只 resume 一次（JS 回调与超时互相竞争）。
    private final class ScriptWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Any?, Error>?
        private var finished = false

        func bind(_ continuation: CheckedContinuation<Any?, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<Any?, Error>) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    private func run(script: String, in webView: WKWebView) async throws -> Any? {
        let waiter = ScriptWaiter()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            waiter.bind(continuation)
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    waiter.finish(.failure(error))
                } else {
                    waiter.finish(.success(result))
                }
            }
            // 超时只负责 resume 一次，不再用结构化并发等待 JS 回调；
            // 否则 evaluateJavaScript 永不回调时这里会永久挂住。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                waiter.finish(.failure(NetworkError.timeout))
            }
        }
    }
}
