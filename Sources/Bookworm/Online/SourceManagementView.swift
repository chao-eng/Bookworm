import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 书源管理（UC-05、07 §4）。
struct SourceManagementView: View {
    @ObservedObject private var repository = SourceRepository.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pasteText = ""
    @State private var showingPaste = false
    @State private var showingURLImport = false
    @State private var urlText = ""
    @State private var urlBusy = false
    @State private var urlImportError: String?
    /// 进行中的链接下载任务，弹窗关闭时取消，避免取消后仍弹出预览。
    @State private var urlImportTask: Task<Void, Never>?
    @State private var importPreview: ImportPreviewBox?
    @State private var importError: String?
    @State private var editingSource: BookSource?
    @State private var banner: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let banner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            if repository.sources.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .onAppear {
            pasteText = ""
        }
        .sheet(isPresented: $showingPaste) {
            pasteSheet
        }
        .sheet(isPresented: $showingURLImport) {
            urlImportSheet
        }
        .sheet(item: $importPreview) { box in
            ImportPreviewSheet(preview: box.preview) { resolution in
                let result = repository.apply(box.preview, resolution: resolution)
                banner = "已导入：新增 \(result.added) 个，更新 \(result.updated) 个"
                importPreview = nil
            } onCancel: {
                importPreview = nil
            }
        }
        .sheet(item: $editingSource) { source in
            SourceEditorSheet(source: source) { updated in
                repository.update(updated)
                banner = "已保存「\(updated.name)」"
                editingSource = nil
            } onCancel: {
                editingSource = nil
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            sheetCloseButton { dismiss() }
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.tint)
            Text("书源管理").font(.title3.bold())
            Spacer()
            Menu("导入") {
                Button("从文件导入") { importFromFile() }
                Button("从链接导入") { openURLImport() }
                Button("粘贴 JSON") { showingPaste = true }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            Button("完成") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 弹窗左上角的统一关闭按钮。
    private func sheetCloseButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("关闭")
        .keyboardShortcut(.cancelAction)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("还没有书源")
                .font(.headline)
            Text("导入或在启动时粘贴一份书源 JSON，就能搜索在线书。\n本应用不内置任何书源。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("从文件导入") { importFromFile() }
                    .buttonStyle(.borderedProminent)
                Button("从链接导入") { openURLImport() }
                Button("粘贴 JSON") { showingPaste = true }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(repository.sources) { source in
                    sourceRow(source)
                    Divider().padding(.leading, 20)
                }
            }
        }
    }

    private func sourceRow(_ source: BookSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { repository.setEnabled($0, sourceID: source.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(source.enabled ? "停用这个来源" : "启用这个来源")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(source.name).font(.body.weight(.medium))
                    Text(source.isBuiltin ? "内置" : "用户")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    healthLabel(source)
                    if source.request?.allowInsecureTLS == true {
                        Text("已关闭 TLS 校验")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    }
                }
                HStack(spacing: 8) {
                    Text(source.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = source.health?.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button("编辑") { editingSource = source }
                if source.isBuiltin {
                    Button("还原") { repository.restoreBuiltin(sourceID: source.id) }
                } else {
                    Button("删除") {
                        if repository.delete(sourceID: source.id) {
                            banner = "已删除「\(source.name)」"
                        }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func healthLabel(_ source: BookSource) -> some View {
        let score = source.healthScore
        let percent = Int((score * 100).rounded())
        let color: Color = score >= 0.7 ? .green : (score >= 0.3 ? .secondary : .orange)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("健康 \(percent)%")
                .font(.caption2)
                .foregroundStyle(color == .secondary ? Color.secondary : color)
            if score < 0.3 {
                Text("建议停用")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("已启用 \(repository.enabledSources.count) / \(repository.sources.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("一键停用失效书源") {
                let count = repository.disableUnhealthy()
                banner = "已停用 \(count) 个失效书源"
            }
            .controlSize(.small)
            .disabled(unhealthyCount == 0)
            .help("健康度低于 30% 的已启用书源会被停用")
            Button("一键停用全部在线源") {
                repository.disableAll()
                banner = "已停用全部在线源，搜索入口会置灰"
            }
            .controlSize(.small)
            .disabled(repository.enabledSources.isEmpty)
            Button("导出书源") { exportSources() }
                .controlSize(.small)
                .disabled(repository.sources.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var unhealthyCount: Int {
        repository.sources.filter { $0.enabled && $0.healthScore < 0.3 }.count
    }

    // MARK: 导出

    private func exportSources() {
        guard let data = repository.exportData() else {
            importError = "生成书源 JSON 失败"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出书源"
        panel.allowedContentTypes = [.json]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Bookworm-Sources-\(stamp.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            importError = nil
            banner = "已导出 \(repository.sources.count) 个书源"
        } catch {
            importError = "写入文件失败：\(error.localizedDescription)"
        }
    }

    // MARK: 导入

    private func importFromFile() {
        importError = nil
        let panel = NSOpenPanel()
        panel.title = "导入书源"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            importError = "读取文件失败，请确认文件可访问"
            return
        }
        handleImportData(data)
    }

    /// 打开链接导入弹窗，清掉上一次的输入、错误与残留任务。
    private func openURLImport() {
        urlText = ""
        urlImportError = nil
        urlBusy = false
        urlImportTask = nil
        showingURLImport = true
    }

    /// 从 http(s) 链接下载书源 JSON，下载完成后复用同一套预览流程。
    private func startURLImport() {
        // 回车（onSubmit）与「导入」按钮共用入口，防止下载中重复触发并发下载。
        guard !urlBusy else { return }
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            urlImportError = "请输入以 http:// 或 https:// 开头的有效链接"
            return
        }
        urlImportError = nil
        urlBusy = true
        urlImportTask = Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                // 用户已关闭弹窗：不再弹预览、也不动已重置的状态。
                guard !Task.isCancelled else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else {
                    await MainActor.run {
                        urlBusy = false
                        urlImportError = "下载失败：服务器返回 \(status)"
                    }
                    return
                }
                await MainActor.run {
                    urlBusy = false
                    showingURLImport = false
                    handleImportData(data)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    urlBusy = false
                    urlImportError = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private var urlImportSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                sheetCloseButton { showingURLImport = false }
                Text("从链接导入书源").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("填入返回书源 JSON 的 http(s) 地址，支持 [ … ] 或 {\"sources\": [ … ]} 格式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://www.luoxx.top/book_source.txt", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { startURLImport() }
                if let urlImportError {
                    Text(urlImportError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            Divider()
            HStack(spacing: 12) {
                if urlBusy {
                    ProgressView().controlSize(.small)
                    Text("下载中…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { showingURLImport = false }
                Button("导入") { startURLImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlBusy || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 600, height: 200)
        .onDisappear {
            // 弹窗以任何方式关闭（取消按钮、左上角关闭、Esc）都中止进行中的下载。
            urlImportTask?.cancel()
            urlImportTask = nil
        }
    }

    private func handleImportData(_ data: Data) {
        let result = repository.preview(data: data)
        if let error = result.error {
            importError = error
            return
        }
        guard let preview = result.preview else {
            importError = "没有可用的书源"
            return
        }
        if preview.candidates.isEmpty {
            let first = preview.failures.prefix(3)
                .map { "\($0.name)：\($0.message)" }
                .joined(separator: "\n")
            let rest = preview.failures.count > 3
                ? "\n…另有 \(preview.failures.count - 3) 条格式不兼容"
                : ""
            importError = "这些书源格式不兼容，未导入任何条目：\n\(first)\(rest)"
            return
        }
        importError = nil
        importPreview = ImportPreviewBox(preview: preview)
    }

    private var pasteSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                sheetCloseButton { showingPaste = false }
                Text("粘贴书源 JSON").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            TextEditor(text: $pasteText)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 620, minHeight: 300)
                .padding(12)
            Divider()
            HStack {
                Text("支持 [ … ]、{\"sources\": [ … ]} 或单个书源对象")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { showingPaste = false }
                Button("预览") {
                    guard let data = pasteText.data(using: .utf8) else { return }
                    showingPaste = false
                    handleImportData(data)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 680, height: 440)
    }
}

// MARK: - 导入预览

private struct ImportPreviewSheet: View {
    let preview: SourceRepository.ImportPreview
    let onConfirm: (SourceRepository.ConflictResolution) -> Void
    let onCancel: () -> Void

    @State private var choice: ConflictChoice = .skip

    enum ConflictChoice: String, CaseIterable, Identifiable {
        case overwrite = "覆盖"
        case keepBoth = "保留两者"
        case skip = "跳过"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("关闭")
                Text("导入预览").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("新增 \(preview.addedCount) · 冲突 \(preview.conflictingCount) · 失败 \(preview.failures.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(preview.candidates.indices, id: \.self) { idx in
                        let candidate = preview.candidates[idx]
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(candidate.source.name).font(.body.weight(.medium))
                                Text(candidate.conflictingID == nil ? "新增" : "冲突")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            ForEach(candidate.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Divider()
                    }

                    ForEach(preview.failures, id: \.name) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.name).font(.body.weight(.medium))
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Divider()
                    }

                    if preview.conflictingCount > 0 {
                        Picker("同名冲突时", selection: $choice) {
                            ForEach(ConflictChoice.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("确认导入") {
                    switch choice {
                    case .overwrite: onConfirm(.overwrite)
                    case .keepBoth: onConfirm(.keepBoth)
                    case .skip: onConfirm(.skip)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 620, height: 480)
    }
}

// MARK: - 编辑

private struct SourceEditorSheet: View {
    let source: BookSource
    let onSave: (BookSource) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var issues: [String] = []
    @State private var pendingSource: BookSource?
    @State private var confirmingTLS = false

    init(source: BookSource,
         onSave: @escaping (BookSource) -> Void,
         onCancel: @escaping () -> Void) {
        self.source = source
        self.onSave = onSave
        self.onCancel = onCancel
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        _text = State(initialValue: (try? encoder.encode(source))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("关闭")
                Text("编辑书源").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 620, minHeight: 340)
                .padding(12)
            if text.contains("\"allowInsecureTLS\": true") || text.contains("\"allowInsecureTLS\":true") {
                Text("⚠︎ 该来源关闭了 TLS 校验，容易遭受中间人攻击。只在你信任这个站点时保留。")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if !issues.isEmpty {
                Text(issues.joined(separator: "；"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider()
            HStack {
                Text("必填：name、homeUrl、searchUrl、searchRule、tocRule、contentRule")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 700, height: 540)
        .alert("关闭 TLS 校验有风险", isPresented: $confirmingTLS) {
            Button("继续保存", role: .destructive) {
                if let pendingSource { onSave(pendingSource) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该来源的 HTTPS 证书将不再校验，可能被中间人窃听或篡改。只在你信任这个站点时开启。")
        }
    }

    private func save() {
        issues = []
        guard let data = text.data(using: .utf8) else { return }
        guard var decoded = try? AppPaths.decodeJSON(BookSource.self, from: data) else {
            issues = ["JSON 格式不合法，请检查括号、引号与字段名"]
            return
        }
        decoded.id = source.id
        decoded.isBuiltin = source.isBuiltin
        let validation = SourceRepository.validate(&decoded)
        guard validation.isEmpty else {
            issues = validation
            return
        }
        if decoded.request?.allowInsecureTLS == true,
           source.request?.allowInsecureTLS != true {
            pendingSource = decoded
            confirmingTLS = true
            return
        }
        onSave(decoded)
    }
}

/// `sheet(item:)` 需要一个 Identifiable 的包装器。
private struct ImportPreviewBox: Identifiable {
    let id = UUID()
    let preview: SourceRepository.ImportPreview
}
