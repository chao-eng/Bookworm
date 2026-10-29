import Foundation
import CoreGraphics

/// 悬浮窗配置与状态（A-4）。
struct FloatingState: Codable, Equatable {
    struct Rect: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ rect: CGRect) {
            self.init(x: rect.origin.x, y: rect.origin.y,
                      width: rect.width, height: rect.height)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = (try? c.decode(Double.self, forKey: .x)) ?? 0
            y = (try? c.decode(Double.self, forKey: .y)) ?? 0
            width = (try? c.decode(Double.self, forKey: .width)) ?? 360
            height = (try? c.decode(Double.self, forKey: .height)) ?? 240
        }

        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    enum Mode: String, Codable {
        case normal
        case mini
        case hidden
    }

    /// 鼠标翻页键位映射。
    enum MousePageTurn: Int, Codable, CaseIterable {
        case off = 0
        case prevWithLeft = 1
        case prevWithRight = 2

        var title: String {
            switch self {
            case .off: return "关闭鼠标翻页"
            case .prevWithLeft: return "上一页：左键；下一页：右键"
            case .prevWithRight: return "上一页：右键；下一页：左键"
            }
        }
    }

    /// 鼠标移出悬浮窗后的快速隐藏方式。
    enum QuickHide: Int, Codable, CaseIterable {
        case off = 0
        case hideOnExit = 1
        case keepPercent = 2
        case shrinkIcon = 3
        case shrinkIconDoubleClick = 4
        case hideDoubleClick = 5

        var title: String {
            switch self {
            case .off: return "关闭快速隐藏"
            case .hideOnExit: return "鼠标移出完全隐藏窗口，移回重新显示"
            case .keepPercent: return "鼠标移出保留右下角百分比不隐藏，移回重新显示"
            case .shrinkIcon: return "鼠标移出缩小为小图标，移回重新显示"
            case .shrinkIconDoubleClick: return "鼠标移出缩小为小图标，双击小图标重新显示"
            case .hideDoubleClick: return "鼠标移出完全隐藏，鼠标双击窗口区域重新显示"
            }
        }
    }

    var isVisible: Bool
    var mode: Mode
    var frame: Rect
    /// 迷你条宽度：用户手动拖过边框后记住，下次收起/唤出沿用；nil 用默认宽度。
    var miniWidth: Double?
    var opacity: Double
    var fontSize: Double
    /// 字体颜色与背景颜色：`#RRGGBB`；nil 表示跟随主题默认。
    var fontColor: String?
    var backgroundColor: String?
    var autoPageInterval: Double?
    var lastBookID: String?
    var lastChapterIndex: Int?
    /// 快捷操作：迷你条是否显示百分比进度。
    var showMiniPercent: Bool
    /// 鼠标左/右键翻页映射。
    var mousePageTurn: MousePageTurn
    /// 鼠标移出后的快速隐藏方式。
    var quickHide: QuickHide
    /// 动作 → 热键绑定；nil 表示该动作置空禁用（BR-56）。
    var hotkeys: [String: HotkeyBinding]?

    init(isVisible: Bool = false,
         mode: Mode = .normal,
         frame: Rect = Rect(x: 0, y: 0, width: 380, height: 260),
         miniWidth: Double? = nil,
         opacity: Double = 0.9,
         fontSize: Double = 16,
         fontColor: String? = nil,
         backgroundColor: String? = nil,
         autoPageInterval: Double? = nil,
         lastBookID: String? = nil,
         lastChapterIndex: Int? = nil,
         showMiniPercent: Bool = true,
         mousePageTurn: MousePageTurn = .off,
         quickHide: QuickHide = .off,
         hotkeys: [String: HotkeyBinding]? = nil) {
        self.isVisible = isVisible
        self.mode = mode
        self.frame = frame
        self.miniWidth = miniWidth
        self.opacity = opacity
        self.fontSize = fontSize
        self.fontColor = fontColor
        self.backgroundColor = backgroundColor
        self.autoPageInterval = autoPageInterval
        self.lastBookID = lastBookID
        self.lastChapterIndex = lastChapterIndex
        self.showMiniPercent = showMiniPercent
        self.mousePageTurn = mousePageTurn
        self.quickHide = quickHide
        self.hotkeys = hotkeys
    }

    /// 容许缺字段：旧文件或部分写入不应导致整份配置失效。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = (try? c.decode(Bool.self, forKey: .isVisible)) ?? false
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .normal
        frame = (try? c.decode(Rect.self, forKey: .frame))
            ?? Rect(x: 0, y: 0, width: 380, height: 260)
        miniWidth = try? c.decodeIfPresent(Double.self, forKey: .miniWidth)
        opacity = min(1, max(0.35, (try? c.decode(Double.self, forKey: .opacity)) ?? 0.9))
        fontSize = min(28, max(12, (try? c.decode(Double.self, forKey: .fontSize)) ?? 16))
        fontColor = try? c.decodeIfPresent(String.self, forKey: .fontColor)
        backgroundColor = try? c.decodeIfPresent(String.self, forKey: .backgroundColor)
        autoPageInterval = try? c.decodeIfPresent(Double.self, forKey: .autoPageInterval)
        lastBookID = try? c.decodeIfPresent(String.self, forKey: .lastBookID)
        lastChapterIndex = try? c.decodeIfPresent(Int.self, forKey: .lastChapterIndex)
        showMiniPercent = (try? c.decode(Bool.self, forKey: .showMiniPercent)) ?? true
        mousePageTurn = (try? c.decode(MousePageTurn.self, forKey: .mousePageTurn)) ?? .off
        quickHide = (try? c.decode(QuickHide.self, forKey: .quickHide)) ?? .off
        hotkeys = try? c.decodeIfPresent([String: HotkeyBinding].self, forKey: .hotkeys)
    }
}

/// 全局热键绑定：Carbon keyCode + 修饰键位掩码。
struct HotkeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon 修饰键掩码（cmdKey / optionKey / controlKey / shiftKey）。
    var modifiers: UInt32

    /// `keyCode == 0 && modifiers == 0` 作为「已置空禁用」的哨兵值（BR-56）。
    var isDisabled: Bool { keyCode == 0 && modifiers == 0 }

    var displayText: String {
        if isDisabled { return "未设置" }
        var parts: [String] = []
        if modifiers & 0x0100 != 0 { parts.append("⌘") }
        if modifiers & 0x0800 != 0 { parts.append("⌥") }
        if modifiers & 0x1000 != 0 { parts.append("⌃") }
        if modifiers & 0x0200 != 0 { parts.append("⇧") }
        parts.append(HotkeyBinding.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for code: UInt32) -> String {
        switch code {
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 49: return "空格"
        case 36: return "↩"
        case 53: return "Esc"
        default: return "#\(code)"
        }
    }
}

/// `Floating/state.json` 读写；变更后 1s 内写盘。
enum FloatingStateStore {
    static func load() -> FloatingState {
        guard let data = try? Data(contentsOf: AppPaths.floatingStateFile),
              let state = try? AppPaths.decodeJSON(FloatingState.self, from: data) else {
            return FloatingState()
        }
        return state
    }

    static func save(_ state: FloatingState) {
        do {
            try AppPaths.atomicWriteJSON(state, to: AppPaths.floatingStateFile)
        } catch {
            Diagnostics.log("floating-state", "保存失败：\(error.localizedDescription)")
        }
    }
}
