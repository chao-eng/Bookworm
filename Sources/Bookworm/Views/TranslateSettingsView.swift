import SwiftUI

/// Popover content for translate-mode preferences. Lets the user pick an
/// engine, source/target languages, and (for OpenAI) paste an API key + pick
/// a model. Bound directly to TranslationSettings.shared so changes
/// propagate to every reader window immediately.
struct TranslateSettingsView: View {
    @ObservedObject var settings: TranslationSettings
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyTestStatus: TestStatus = .idle
    @State private var lastCacheClearMessage: String?

    enum TestStatus: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("翻译引擎", selection: $settings.engine) {
                ForEach(TranslationEngineKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("源语言").frame(width: 60, alignment: .leading)
                Picker("", selection: $settings.sourceLanguage) {
                    ForEach(SupportedLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Text("目标语言").frame(width: 60, alignment: .leading)
                Picker("", selection: $settings.targetLanguage) {
                    ForEach(SupportedLanguage.allCases.filter { $0 != .auto }) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
            }

            if settings.engine == .openai {
                Divider().padding(.vertical, 2)
                openAIBlock
            }

            Divider().padding(.vertical, 2)
            cacheBlock
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            apiKeyDraft = settings.openAIAPIKey ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.tint)
            Text("翻译").font(.headline)
            Spacer()
        }
    }

    private var openAIBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenAI").font(.subheadline.weight(.semibold))

            HStack {
                Text("模型").frame(width: 60, alignment: .leading)
                TextField("gpt-4o-mini", text: $settings.openAIModel)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top) {
                Text("API 密钥").frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("sk-…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitAPIKey() }
                    HStack(spacing: 8) {
                        Button("保存") { commitAPIKey() }
                            .disabled(apiKeyDraft == (settings.openAIAPIKey ?? ""))
                        Button("测试") { testAPIKey() }
                            .disabled(apiKeyDraft.isEmpty || apiKeyTestStatus == .running)
                        if case .running = apiKeyTestStatus {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    statusLabel
                }
            }
            Text("密钥保存在 macOS 钥匙串（`app.bookworm.translation`）中，不会写入普通设置文件。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch apiKeyTestStatus {
        case .idle:
            EmptyView()
        case .running:
            EmptyView()
        case .ok(let result):
            Text("✓ \(result)").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text("✗ \(message)").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var cacheBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text("翻译与 OCR 结果会保存在内存中，直到退出应用。若想重新识别/翻译当前页面，可清除缓存。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("清除缓存") { clearCaches() }
                if let message = lastCacheClearMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
            }
        }
    }

    private func clearCaches() {
        let translationCount = TranslationCache.shared.count
        TranslationCache.shared.clear()
        OCRService.shared.clearCache()
        lastCacheClearMessage = "已清除 \(translationCount) 条译文"
        // Fade the toast back out after a beat so the popover doesn't keep
        // the success message around forever.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            lastCacheClearMessage = nil
        }
    }

    private func commitAPIKey() {
        settings.openAIAPIKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyTestStatus = .idle
    }

    private func testAPIKey() {
        commitAPIKey()
        apiKeyTestStatus = .running
        let key = settings.openAIAPIKey ?? ""
        let model = settings.openAIModel.isEmpty ? "gpt-4o-mini" : settings.openAIModel
        Task { @MainActor in
            let translator = OpenAITranslator(apiKey: key, model: model)
            do {
                let out = try await translator.translate("hello",
                                                          sourceLang: "en",
                                                          targetLang: settings.targetLanguage.rawValue)
                apiKeyTestStatus = .ok("hello → \(out)")
            } catch {
                apiKeyTestStatus = .failed(error.localizedDescription)
            }
        }
    }
}
