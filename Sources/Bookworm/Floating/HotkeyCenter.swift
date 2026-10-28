import AppKit
import Carbon

/// 全局热键（BR-55、BR-56、UC-13）。
///
/// 只使用 Carbon `RegisterEventHotKey`：不需要辅助功能权限，也不激活 App。
/// 注册失败（系统拒绝或与其他动作重复）必须留下可见的错误文案，不静默失败。
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    enum Action: String, CaseIterable {
        case toggleVisibility
        case nextPage
        case prevPage
        case nextChapter
        case prevChapter
        case toggleAutoPage

        var title: String {
            switch self {
            case .toggleVisibility: return "显示/隐藏悬浮窗"
            case .nextPage: return "下一页"
            case .prevPage: return "上一页"
            case .nextChapter: return "下一章"
            case .prevChapter: return "上一章"
            case .toggleAutoPage: return "自动翻页开关"
            }
        }

        var detail: String {
            switch self {
            case .toggleVisibility: return "任意 App 前台时都可唤出"
            case .nextPage, .prevPage: return "仅悬浮窗生效"
            default: return ""
            }
        }

        /// 默认组合：⌥⌘ + R / ← / → / ↑ / ↓ / P。
        var defaultBinding: HotkeyBinding {
            let mods: UInt32 = 0x0100 | 0x0800
            switch self {
            case .toggleVisibility: return HotkeyBinding(keyCode: 15, modifiers: mods)
            case .nextPage: return HotkeyBinding(keyCode: 124, modifiers: mods)
            case .prevPage: return HotkeyBinding(keyCode: 123, modifiers: mods)
            case .nextChapter: return HotkeyBinding(keyCode: 125, modifiers: mods)
            case .prevChapter: return HotkeyBinding(keyCode: 126, modifiers: mods)
            case .toggleAutoPage: return HotkeyBinding(keyCode: 35, modifiers: mods)
            }
        }
    }

    /// 热键触发后的动作分发；由 `FloatingPanelController` 注入。
    var onAction: ((Action) -> Void)?

    private(set) var bindings: [Action: HotkeyBinding] = [:]
    /// 动作 → 失败原因（设置页标红用）。
    private(set) var failures: [Action: String] = [:]

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4257_4D31 // 'BWM1'

    private init() {}

    // MARK: - 安装与注册

    func install(state: FloatingState) {
        installHandlerIfNeeded()
        applyStored(state.hotkeys)
    }

    /// 用持久化配置覆盖内存绑定；缺字段的动作回落到默认组合。
    func applyStored(_ stored: [String: HotkeyBinding]?) {
        unregisterAll()
        failures.removeAll()
        for action in Action.allCases {
            let binding = stored?[action.rawValue] ?? action.defaultBinding
            bindings[action] = binding
            guard !binding.isDisabled else { continue }
            if let reason = register(action, binding) {
                failures[action] = reason
            }
        }
    }

    /// 修改单个动作的组合键；返回错误文案（成功返回 nil）。
    func setBinding(_ binding: HotkeyBinding?, for action: Action) -> String? {
        let newValue = binding ?? HotkeyBinding(keyCode: 0, modifiers: 0)

        if !newValue.isDisabled {
            if newValue.modifiers & (0x0100 | 0x0800 | 0x1000) == 0 {
                return "快捷键至少需要包含 ⌘、⌥ 或 ⌃"
            }
            if let other = bindings.first(where: { $0.key != action && $0.value == newValue && !$0.value.isDisabled })?.key {
                return "该快捷键已被「\(other.title)」占用"
            }
        }

        unregister(action)
        if !newValue.isDisabled, let reason = register(action, newValue) {
            // 注册失败保留原组合（BR-55：保留原值不变）。
            if let old = bindings[action], !old.isDisabled {
                _ = register(action, old)
            }
            failures[action] = reason
            return reason
        }

        bindings[action] = newValue
        failures[action] = nil
        return nil
    }

    func resetToDefaults() {
        var stored: [String: HotkeyBinding] = [:]
        for action in Action.allCases {
            stored[action.rawValue] = action.defaultBinding
        }
        applyStored(stored)
    }

    func binding(for action: Action) -> HotkeyBinding {
        bindings[action] ?? action.defaultBinding
    }

    /// 写回 `FloatingState.hotkeys` 的字典。
    var storedBindings: [String: HotkeyBinding] {
        var result: [String: HotkeyBinding] = [:]
        for (action, binding) in bindings {
            result[action.rawValue] = binding
        }
        return result
    }

    // MARK: - Carbon 注册

    private func register(_ action: Action, _ binding: HotkeyBinding) -> String? {
        guard let index = Action.allCases.firstIndex(of: action) else {
            return "未知动作"
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index) + 1)
        let status = RegisterEventHotKey(binding.keyCode,
                                         binding.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            return "该快捷键已被其他应用使用"
        }
        hotKeyRefs[action] = ref
        return nil
    }

    private func unregister(_ action: Action) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            let index = Int(hotKeyID.id) - 1
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotkeyCenter.shared.dispatch(index: index)
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)
    }

    private func dispatch(index: Int) {
        guard index >= 0, index < Action.allCases.count else { return }
        onAction?(Action.allCases[index])
    }
}
