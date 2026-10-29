import SwiftUI
import AppKit

/// 悬浮窗设置（UC-13 步骤 4/5、BR-70）：热键绑定、字号、透明度、颜色、自动翻页。
/// 首屏之外的高级项集中在这里，避免打扰阅读界面。
struct FloatingSettingsView: View {
    @ObservedObject private var model = FloatingPanelController.shared

    @State private var recording: HotkeyCenter.Action?
    @State private var recorderMessage: String?
    @State private var keyMonitor: Any?
    @State private var revision = 0
    @State private var fontColorHex = ""
    @State private var backgroundColorHex = ""
    /// 屏幕取色器必须在取色过程中保持存活，否则放大镜会提前消失。
    @State private var colorSampler: NSColorSampler?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection
                    Divider()
                    hotkeySection
                    Divider()
                    appearanceSection
                    Divider()
                    interactionSection
                    Divider()
                    autoPageSection
                }
                .padding(20)
                .id(revision)
            }
            Divider()
            HStack {
                Spacer()
                Button("恢复默认快捷键") {
                    HotkeyCenter.shared.resetToDefaults()
                    model.persistNow()
                    revision += 1
                }
                Button("完成") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 460, minHeight: 560)
        .onAppear {
            fontColorHex = model.state.fontColor ?? ""
            backgroundColorHex = model.state.backgroundColor ?? ""
        }
        .onDisappear { stopRecording() }
    }

    // MARK: - 显示模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("显示模式").font(.headline)
            Picker("", selection: Binding(
                get: { model.state.mode == .mini ? FloatingState.Mode.mini : .normal },
                set: { model.show(mode: $0) }
            )) {
                Text("默认模式").tag(FloatingState.Mode.normal)
                Text("迷你模式").tag(FloatingState.Mode.mini)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("默认模式显示完整正文；迷你模式缩成一条紧凑文字条。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 快捷键

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷键").font(.headline)
            Text("至少包含 ⌘、⌥ 或 ⌃；点「置空」可禁用单个动作。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recorderMessage {
                Text(recorderMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(HotkeyCenter.Action.allCases, id: \.rawValue) { action in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                        if !action.detail.isEmpty {
                            Text(action.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let failure = HotkeyCenter.shared.failures[action] {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Button {
                        startRecording(action)
                    } label: {
                        Text(recording == action
                             ? "按下组合键…"
                             : HotkeyCenter.shared.binding(for: action).displayText)
                            .frame(minWidth: 96)
                    }
                    Button {
                        _ = HotkeyCenter.shared.setBinding(nil, for: action)
                        model.persistNow()
                        revision += 1
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .help("置空（禁用）")
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外观").font(.headline)
            HStack {
                Text("字号")
                Slider(value: Binding(
                    get: { model.state.fontSize },
                    set: { model.setFontSize($0) }
                ), in: 12...28, step: 1)
                Text("\(Int(model.state.fontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
            HStack {
                Text("透明度")
                Slider(value: Binding(
                    get: { model.state.opacity },
                    set: { model.adjustOpacity($0 - model.state.opacity) }
                ), in: 0.35...1)
                Text("\(Int(model.state.opacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            colorRow("字体颜色",
                     hex: $fontColorHex,
                     preview: Color(hexRGB: model.state.fontColor) ?? .primary,
                     apply: { model.setFontColor($0) })
            colorRow("背景颜色",
                     hex: $backgroundColorHex,
                     preview: Color(hexRGB: model.state.backgroundColor) ?? Color(nsColor: .windowBackgroundColor),
                     apply: { model.setBackgroundColor($0) })
            Toggle("迷你模式显示百分比进度", isOn: Binding(
                get: { model.state.showMiniPercent },
                set: { model.setShowMiniPercent($0) }
            ))
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                Text("窗口标题")
                Picker("", selection: Binding(
                    get: { model.state.windowTitle },
                    set: { model.setWindowTitleMode($0) }
                )) {
                    ForEach(FloatingState.WindowTitle.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("控制顶部书名与章节标题栏（含迷你、隐藏、关闭按钮）；鼠标移出隐藏即悬停时显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 颜色行：左侧小方框既是预览也是取色入口，点击直接唤起系统屏幕取色器；
    /// 右侧仍可手输 RGB 十六进制。
    private func colorRow(_ title: String,
                          hex: Binding<String>,
                          preview: Color,
                          apply: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Button {
                pickColor(into: hex)
            } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(preview)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("点击使用屏幕取色器")
            TextField("#RRGGBB", text: hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110)
                .onChange(of: hex.wrappedValue) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        apply(nil)
                    } else if Color(hexRGB: trimmed) != nil {
                        apply(trimmed)
                    }
                }
            if !hex.wrappedValue.isEmpty {
                Button("还原") {
                    hex.wrappedValue = ""
                    apply(nil)
                }
                .controlSize(.small)
            }
            Spacer()
        }
    }

    /// 直接弹出屏幕取色器（放大镜），取到的颜色回填十六进制。
    private func pickColor(into hex: Binding<String>) {
        let sampler = NSColorSampler()
        colorSampler = sampler
        sampler.show { color in
            DispatchQueue.main.async {
                guard let color else { return }
                hex.wrappedValue = Color(nsColor: color).hexRGBString
            }
        }
    }

    // MARK: - 鼠标与快速隐藏

    private var interactionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("鼠标翻页").font(.headline)
            Picker("", selection: Binding(
                get: { model.state.mousePageTurn },
                set: { model.setMousePageTurn($0) }
            )) {
                ForEach(FloatingState.MousePageTurn.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("启用右键翻页后，按住 ⌥、⌃ 或 ⌘ 再右键可打开菜单；顶部按钮栏始终可点。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("快速隐藏").font(.headline)
            Picker("", selection: Binding(
                get: { model.state.quickHide },
                set: { model.setQuickHideMode($0) }
            )) {
                ForEach(FloatingState.QuickHide.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("鼠标移出窗口时生效；标注「移回重新显示」的选项在鼠标回到窗口位置时恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 自动翻页

    private var autoPageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自动翻页").font(.headline)
            Picker("间隔", selection: Binding(
                get: { model.state.autoPageInterval ?? 0 },
                set: { model.setAutoPageInterval($0 == 0 ? nil : $0) }
            )) {
                Text("关闭").tag(Double(0))
                Text("每 5 秒").tag(Double(5))
                Text("每 10 秒").tag(Double(10))
                Text("每 30 秒").tag(Double(30))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - 录制

    private func startRecording(_ action: HotkeyCenter.Action) {
        stopRecording()
        recorderMessage = nil
        recording = action
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handleRecord(event, action: action)
            }
            return nil
        }
    }

    private func handleRecord(_ event: NSEvent, action: HotkeyCenter.Action) {
        guard recording == action else { return }
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode),
                                    modifiers: Self.carbonModifiers(event.modifierFlags))
        if let error = HotkeyCenter.shared.setBinding(binding, for: action) {
            recorderMessage = error
        } else {
            model.persistNow()
            stopRecording()
        }
        revision += 1
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        recording = nil
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= 0x0100 }
        if flags.contains(.option) { mask |= 0x0800 }
        if flags.contains(.control) { mask |= 0x1000 }
        if flags.contains(.shift) { mask |= 0x0200 }
        return mask
    }
}

/// 设置窗口：菜单「悬浮窗 ▸ 设置」打开，避免打断当前阅读窗。
@MainActor
final class FloatingSettingsWindow {
    static let shared = FloatingSettingsWindow()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: FloatingSettingsView())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered,
                         defer: false)
        w.title = "悬浮窗设置"
        w.contentViewController = hosting
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("FloatingSettings")
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
