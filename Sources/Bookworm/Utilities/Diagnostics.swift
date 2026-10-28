import Foundation

/// 脱敏日志。
///
/// 按日切分写入 `Application Support/Bookworm/Logs/bookworm-YYYY-MM-DD.log`，
/// 保留 7 天。绝不记录正文、Cookie、完整查询串与用户目录全称（BR-45）。
enum Diagnostics {
    /// 是否输出 debug 级日志（诊断模式）。
    nonisolated(unsafe) static var verbose: Bool = false

    private static let queue = DispatchQueue(label: "bookworm.diagnostics")
    private static let retentionDays = 7
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ category: String, _ message: String) {
        let line = "[\(stampFormatter.string(from: Date()))] [\(category)] \(redact(message))"
        queue.async {
            let now = Date()
            let file = AppPaths.logsDirectory
                .appendingPathComponent("bookworm-\(formatter.string(from: now)).log")
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file, options: .atomic)
            }
            pruneOldLogs(reference: now)
        }
    }

    static func debug(_ category: String, _ message: String) {
        guard verbose else { return }
        log(category, message)
    }

    /// 一键导出诊断文本：版本、系统、源名、健康度与脱敏错误（BR-45）。
    static func report(appVersion: String,
                       sourceSummaries: [String],
                       recentErrors: [String]) -> String {
        var lines: [String] = []
        lines.append("Bookworm 诊断")
        lines.append("版本：\(appVersion)")
        lines.append("系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("时间：\(stampFormatter.string(from: Date()))")
        if sourceSummaries.isEmpty {
            lines.append("书源：无")
        } else {
            lines.append("书源：")
            lines.append(contentsOf: sourceSummaries.map { "  - \(redact($0))" })
        }
        if !recentErrors.isEmpty {
            lines.append("最近错误：")
            lines.append(contentsOf: recentErrors.map { "  - \(redact($0))" })
        }
        lines.append("说明：不含正文、Cookie 与完整查询串。")
        return lines.joined(separator: "\n")
    }

    /// 抹掉 URL 的查询串与用户目录前缀。
    static func redact(_ text: String) -> String {
        var result = text
        // 去掉 URL 查询串和片段，保留主机与路径。
        if let q = result.firstIndex(of: "?") {
            let head = result[..<q]
            result = String(head)
        }
        if let hash = result.firstIndex(of: "#") {
            result = String(result[..<hash])
        }
        // 用户目录全称替换为 ~。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, home != "/" {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        return result
    }

    private static func pruneOldLogs(reference: Date) {
        let fm = FileManager.default
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: reference) else { return }
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.logsDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            if modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
