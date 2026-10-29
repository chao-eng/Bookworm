import AppKit
import SwiftUI
import Combine

/// 悬浮静默窗（UC-10~UC-15、BR-47~BR-66、BR-73）。
///
/// 只承载文本内容，不抢焦点：`NSPanel` 使用 `nonactivatingPanel`，
/// 永不 `makeKey`，所有显示/翻页都只作用于面板自身。
@MainActor
final class FloatingPanelController: NSObject, ObservableObject {
    static let shared = FloatingPanelController()

    @Published private(set) var state: FloatingState
    /// 当前页文本；只有排版完成后才整体替换，避免空白帧（BR-50）。
    @Published private(set) var pageText: String = ""
    @Published private(set) var pageIndex: Int = 0
    @Published private(set) var pageCount: Int = 0
    /// 临时提示（已经是最后一页 / 加载超时等），2 秒后自动消失。
    @Published private(set) var notice: String?
    /// 快速隐藏是否已生效（窗口整体透明 / 只剩百分比 / 缩成小图标）。
    @Published private(set) var quickHidden = false

    private static let miniSize = CGSize(width: 260, height: 44)
    /// 快速隐藏时收起的小图标尺寸。
    private static let quickHideIconSize = CGSize(width: 44, height: 44)
    /// 迷你条宽度可拖动范围。
    private static let minMiniWidth: CGFloat = 160
    private static let maxMiniWidth: CGFloat = 760
    private static let defaultSize = CGSize(width: 420, height: 320)
    private static let minSize = CGSize(width: 280, height: 180)
    private static let maxSize = CGSize(width: 900, height: 720)

    private var panel: FloatingPanel?
    private var normalFrame: CGRect = .zero
    /// 上次显示用的模式（普通 / 迷你）。隐藏后仍保留，下次唤出沿用；
    /// 同时写进 UserDefaults，重启应用后依旧记得是否用迷你模式。
    private var lastVisibleMode: FloatingState.Mode = .normal {
        didSet {
            guard oldValue != lastVisibleMode else { return }
            UserDefaults.standard.set(lastVisibleMode.rawValue, forKey: Self.lastModeKey)
        }
    }
    private static let lastModeKey = "Bookworm.floating.lastMode"

    private var pages: [TextPage] = []
    private var paginatedText: String = ""
    private var paginatedFontSize: Double = 0
    private var paginatedSize: CGSize = .zero

    /// 精简态按「行」翻页：每页只放得下一行，放不下的部分顺延到下一迷你页。
    private var miniPages: [TextPage] = []
    private var miniPaginatedText: String = ""
    /// 迷你字号按正文字号等比缩放：16pt 正文对应 11pt 迷你字号，
    /// 这样调整字号设置时迷你条也会同步变化。
    private static let miniFontScale: CGFloat = 11.0 / 16.0
    var miniFontSize: CGFloat {
        min(20, max(9, CGFloat(state.fontSize) * Self.miniFontScale))
    }
    /// 迷你条高度随字号增长，避免大字号被上下裁切。
    private var miniBarHeight: CGFloat {
        max(Self.miniSize.height, (miniFontSize + 33).rounded())
    }
    /// 迷你正文上一次排版采用的字号；字号变了要重排。
    private var miniPaginatedFontSize: CGFloat = 0
    /// 迷你条中正文以外的固定占用：左右内边距 24，百分比可见时再加 30 + 一段间距 6。
    private var miniChromeWidth: CGFloat {
        state.showMiniPercent ? 60 : 26
    }
    /// 迷你正文上一次排版采用的宽度；宽度变了要重排，才能始终铺满整条。
    private var miniPaginatedWidth: CGFloat = 0

    private var cancellables = Set<AnyCancellable>()
    private var saveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var cacheReleaseTask: Task<Void, Never>?
    private var loadingWatchdog: Task<Void, Never>?
    private var autoPageTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []

    private var wheelAccum: CGFloat = 0
    private var lastWheelTurn: Date = .distantPast

    /// 快速隐藏前窗口的位置与尺寸限制，恢复时原样还原。
    private var quickHideSavedFrame: CGRect = .zero
    private var quickHideSavedMinSize: CGSize = .zero
    private var quickHideSavedMaxSize: CGSize = .zero
    /// 整体隐藏（只剩透明区域）时用全局鼠标移动监听判断移回。
    private var quickHideMouseMonitor: Any?

    private override init() {
        state = FloatingStateStore.load()
    }

    // MARK: - 安装

    func install() {
        normalFrame = initialFrame()
        bindSession()
        observeSystem()
        observeScreens()
        HotkeyCenter.shared.onAction = { [weak self] action in
            Task { @MainActor in self?.handle(action) }
        }
        HotkeyCenter.shared.install(state: state)
        // 启动时不再自动恢复悬浮窗（双击打开图书不应同时弹出悬浮窗），
        // 只有显式操作（快捷键、菜单、右键「在悬浮窗中打开」）才显示。
        // 上次用迷你模式就沿用迷你模式：先从 UserDefaults 取（隐藏时也会记住），
        // 取不到再退回当前持久化的模式。
        if let raw = UserDefaults.standard.string(forKey: Self.lastModeKey),
           let saved = FloatingState.Mode(rawValue: raw), saved != .hidden {
            lastVisibleMode = saved
        } else if state.mode != .hidden {
            lastVisibleMode = state.mode
        }
        state.isVisible = false
        Diagnostics.log("float", "install mode=\(state.mode.rawValue) last=\(lastVisibleMode.rawValue) normal=\(rectText(normalFrame)) saved=\(state.frame.x),\(state.frame.y) \(state.frame.width)x\(state.frame.height)")
    }

    // MARK: - 显隐与模式

    var isPanelVisible: Bool {
        panel?.isVisible == true && state.mode != .hidden && !quickHidden
    }

    func toggle() {
        if isPanelVisible { hide() } else { show() }
    }

    func show(mode: FloatingState.Mode? = nil) {
        let target: FloatingState.Mode
        if let mode {
            target = mode
        } else {
            target = lastVisibleMode == .mini ? .mini : .normal
        }
        guard target != .hidden else {
            hide()
            return
        }

        // 快速隐藏状态下唤出：先恢复原窗口，再按目标模式重新布局。
        cancelQuickHide(restoringFrame: true)
        let panel = ensurePanel()
        if target == .mini {
            applyMiniFrame(panel)
        } else {
            applyNormalFrame(panel)
        }
        state.mode = target
        state.isVisible = true
        // 立即记住这次的模式（含迷你），避免未收起就退出应用时丢失。
        if target != .hidden { lastVisibleMode = target }
        Diagnostics.log("float", "show[\(target.rawValue)] panel=\(rectText(panel.frame)) normal=\(rectText(normalFrame))")
        recenterIfNeeded(panel)
        panel.orderFrontRegardless()
        repaginateIfNeeded()
        updatePage()
        rescheduleAutoPageTimer()
        if ReadingSession.shared.isLoading {
            beginLoadingWatchdog()
        } else {
            loadingWatchdog?.cancel()
            loadingWatchdog = nil
        }
        persistSoon()
    }

    func hide() {
        // 快速隐藏会缩过窗口，先还原真实尺寸再记录位置。
        cancelQuickHide(restoringFrame: true)
        if state.mode != .hidden {
            lastVisibleMode = state.mode
        }
        // 隐藏前记下眼前这份真实尺寸：用户拖动缩放后即便系统没上报，
        // 再次显示也能保持同样的宽高比例（BR-53）。
        syncVisibleNormalFrame()
        state.mode = .hidden
        state.isVisible = false
        panel?.orderOut(nil)
        autoPageTimer?.invalidate()
        autoPageTimer = nil
        loadingWatchdog?.cancel()
        loadingWatchdog = nil
        persistSoon()
        scheduleCacheRelease()
    }

    func toggleMini() {
        if state.mode == .mini {
            show(mode: .normal)
        } else {
            show(mode: .mini)
        }
    }

    /// 关闭按钮：收起并立刻释放排版缓存（BR-58 的 5s 约定由 `scheduleCacheRelease` 兜底）。
    func close() {
        hide()
        releasePagesNow()
    }

    func persistNow() {
        saveTask?.cancel()
        saveTask = nil
        syncVisibleNormalFrame()
        state.hotkeys = HotkeyCenter.shared.storedBindings
        FloatingStateStore.save(state)
    }

    /// 把窗口当前的真实位置/尺寸同步进 `normalFrame`，作为下次唤出的基准：
    /// 普通态直接记整块 frame；迷你态尺寸固定，只把拖动后的位置折算回去
    /// （左上角对齐），这样下次唤出（含展开回普通态）都停在同一处。
    private func syncVisibleNormalFrame() {
        // 快速隐藏时窗口可能已被缩成小图标，不能拿来当正常尺寸记录。
        guard let panel, panel.isVisible, !quickHidden else { return }
        if state.mode == .normal {
            normalFrame = Self.clamped(panel.frame)
        } else if state.mode == .mini {
            normalFrame.origin = CGPoint(x: panel.frame.minX,
                                         y: panel.frame.maxY - normalFrame.height)
            normalFrame = Self.clamped(normalFrame)
            state.miniWidth = Double(panel.frame.width)
        } else {
            return
        }
        state.frame = FloatingState.Rect(normalFrame)
        Diagnostics.log("float", "sync[\(state.mode.rawValue)] panel=\(rectText(panel.frame)) normal=\(rectText(normalFrame))")
    }

    private func rectText(_ r: CGRect) -> String {
        "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))"
    }

    /// 导入备份时应用悬浮窗外观与热键（UC-17），保留当前窗口位置。
    func importState(_ imported: FloatingState) {
        var next = imported
        next.frame = state.frame
        state = next
        HotkeyCenter.shared.install(state: next)
        repaginateIfNeeded(force: true)
        updatePage()
        if state.isVisible, state.mode != .hidden {
            show(mode: state.mode)
        } else {
            hide()
        }
        persistNow()
    }

    // MARK: - 外观

    func increaseFont() { setFontSize(state.fontSize + 1) }
    func decreaseFont() { setFontSize(state.fontSize - 1) }

    func setFontSize(_ value: Double) {
        let clamped = min(28, max(12, value))
        guard clamped != state.fontSize else { return }
        state.fontSize = clamped
        if state.mode == .mini, let panel, panel.isVisible, !quickHidden {
            // 迷你条高度随字号变化，先按新字号调整窗口再重排。
            applyMiniFrame(panel)
            repaginateMiniIfNeeded(force: true)
        } else {
            repaginateIfNeeded(force: true)
        }
        updatePage()
        persistSoon()
    }

    func adjustOpacity(_ delta: Double) {
        state.opacity = min(1, max(0.35, state.opacity + delta))
        persistSoon()
    }

    /// 字体颜色 / 背景颜色：传 `#RRGGBB`，传 nil 恢复主题默认。
    func setFontColor(_ hex: String?) {
        let normalized = Self.normalizedHex(hex)
        guard state.fontColor != normalized else { return }
        state.fontColor = normalized
        persistSoon()
    }

    func setBackgroundColor(_ hex: String?) {
        let normalized = Self.normalizedHex(hex)
        guard state.backgroundColor != normalized else { return }
        state.backgroundColor = normalized
        persistSoon()
    }

    private static func normalizedHex(_ hex: String?) -> String? {
        guard let trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return Color(hexRGB: trimmed)?.hexRGBString
    }

    func setAutoPageInterval(_ interval: Double?) {
        state.autoPageInterval = interval
        rescheduleAutoPageTimer()
        persistSoon()
    }

    func toggleAutoPage() {
        if state.autoPageInterval != nil {
            setAutoPageInterval(nil)
            showNotice("自动翻页已关闭")
        } else {
            setAutoPageInterval(10)
            showNotice("自动翻页已开启，每 10 秒一页")
        }
    }

    // MARK: - 迷你百分比 / 鼠标操作 / 快速隐藏

    func setShowMiniPercent(_ value: Bool) {
        guard state.showMiniPercent != value else { return }
        state.showMiniPercent = value
        if state.mode == .mini {
            // 百分比占用的宽度会变，正文要按新宽度重新折行。
            repaginateMiniIfNeeded(force: true)
            updatePage()
        }
        persistSoon()
    }

    func setMousePageTurn(_ mode: FloatingState.MousePageTurn) {
        guard state.mousePageTurn != mode else { return }
        state.mousePageTurn = mode
        persistSoon()
    }

    func setQuickHideMode(_ mode: FloatingState.QuickHide) {
        guard state.quickHide != mode else { return }
        // 先按旧模式恢复窗口，再切换到新模式。
        cancelQuickHide(restoringFrame: true)
        state.quickHide = mode
        persistSoon()
    }

    /// SwiftUI 悬停状态变化：移出触发快速隐藏，移回按需恢复。
    func hoverChanged(_ inside: Bool) {
        guard let panel, panel.isVisible, state.mode != .hidden else { return }
        guard state.quickHide != .off else { return }
        if inside {
            guard quickHidden else { return }
            // 这两种要等用户双击，悬停不自动恢复。
            if state.quickHide == .shrinkIconDoubleClick || state.quickHide == .hideDoubleClick {
                return
            }
            cancelQuickHide(restoringFrame: true)
        } else {
            beginQuickHide()
        }
    }

    private func beginQuickHide() {
        guard !quickHidden, let panel, panel.isVisible, state.mode != .hidden else { return }
        let mode = state.quickHide
        guard mode != .off else { return }
        // 某些情况下悬停结束事件会在鼠标仍在窗口内时误报（例如恢复窗口后追踪区刷新），
        // 此时若收起就会和「移回显示」互相拉扯，直接忽略。
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        quickHidden = true
        switch mode {
        case .off:
            break
        case .hideOnExit, .keepPercent:
            // 窗口仍然占着原来的位置但看不见（或只剩百分比）：
            // 让点击穿透到下层应用，再靠全局鼠标移动监听判断「移回」。
            panel.ignoresMouseEvents = true
            startQuickHideMouseMonitor()
        case .hideDoubleClick:
            // 需要双击窗口区域恢复，窗口必须继续接收鼠标事件。
            panel.ignoresMouseEvents = false
        case .shrinkIcon, .shrinkIconDoubleClick:
            shrinkPanelToIcon(panel)
        }
    }

    /// 恢复快速隐藏前的窗口状态；`restoringFrame` 为 true 时还原被缩小的尺寸。
    private func cancelQuickHide(restoringFrame: Bool) {
        guard quickHidden else { return }
        quickHidden = false
        stopQuickHideMouseMonitor()
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        let mode = state.quickHide
        guard restoringFrame,
              mode == .shrinkIcon || mode == .shrinkIconDoubleClick else { return }
        panel.minSize = quickHideSavedMinSize
        panel.maxSize = quickHideSavedMaxSize
        panel.setFrame(quickHideSavedFrame, display: true)
        if state.mode == .mini {
            repaginateMiniIfNeeded(force: true)
        } else {
            repaginateIfNeeded(force: true)
        }
        updatePage()
    }

    private func shrinkPanelToIcon(_ panel: FloatingPanel) {
        quickHideSavedFrame = panel.frame
        quickHideSavedMinSize = panel.minSize
        quickHideSavedMaxSize = panel.maxSize
        let size = Self.quickHideIconSize
        panel.minSize = size
        panel.maxSize = size
        // 图标停在原窗口的右下角，和百分比位置保持一致。
        let origin = CGPoint(x: panel.frame.maxX - size.width,
                             y: panel.frame.minY)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func startQuickHideMouseMonitor() {
        stopQuickHideMouseMonitor()
        quickHideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.quickHidden, let panel = self.panel else { return }
                if panel.frame.contains(NSEvent.mouseLocation) {
                    self.cancelQuickHide(restoringFrame: true)
                }
            }
        }
    }

    private func stopQuickHideMouseMonitor() {
        if let quickHideMouseMonitor {
            NSEvent.removeMonitor(quickHideMouseMonitor)
            self.quickHideMouseMonitor = nil
        }
    }

    /// 左键：快速隐藏态下用于「双击恢复」，否则按设置翻页。
    /// 返回 true 表示事件已被消费，不再交给 SwiftUI（避免误触按钮/菜单）。
    private func handlePanelMouseDown(_ event: NSEvent) -> Bool {
        if quickHidden {
            guard state.quickHide == .hideDoubleClick
                    || state.quickHide == .shrinkIconDoubleClick else { return false }
            if event.clickCount >= 2 { cancelQuickHide(restoringFrame: true) }
            return true
        }
        guard state.mousePageTurn != .off, state.mode != .hidden else { return false }
        guard event.clickCount == 1, !isInHeaderArea(event) else { return false }
        guard canMousePage else { return false }
        switch state.mousePageTurn {
        case .off:
            return false
        case .prevWithLeft:
            prevPage()
            return true
        case .prevWithRight:
            nextPage()
            return true
        }
    }

    /// 右键：快速隐藏态下用于「双击恢复」，否则按设置翻页；
    /// 按住 ⌥ / ⌃ / ⌘ 时保留右键菜单，便于随时打开设置。
    private func handlePanelRightMouseDown(_ event: NSEvent) -> Bool {
        if quickHidden {
            guard state.quickHide == .hideDoubleClick
                    || state.quickHide == .shrinkIconDoubleClick else { return false }
            if event.clickCount >= 2 { cancelQuickHide(restoringFrame: true) }
            return true
        }
        guard state.mousePageTurn != .off, state.mode != .hidden else { return false }
        let modifiers: NSEvent.ModifierFlags = [.option, .control, .command]
        guard event.modifierFlags.intersection(modifiers).isEmpty else { return false }
        guard event.clickCount == 1, !isInHeaderArea(event) else { return false }
        guard canMousePage else { return false }
        switch state.mousePageTurn {
        case .off:
            return false
        case .prevWithLeft:
            nextPage()
            return true
        case .prevWithRight:
            prevPage()
            return true
        }
    }

    /// 占位态、加载中、以及错误页（含「重试」按钮）不接管鼠标点击，
    /// 避免鼠标翻页把界面上的按钮一起挡住。
    private var canMousePage: Bool {
        let session = ReadingSession.shared
        guard session.isActive, !session.isLoading else { return false }
        return session.lastError == nil || !session.text.isEmpty
    }

    /// 顶部 26pt 是悬浮按钮栏（迷你、隐藏、关闭），鼠标翻页要避开。
    private func isInHeaderArea(_ event: NSEvent) -> Bool {
        guard state.mode == .normal, let panel else { return false }
        return event.locationInWindow.y >= panel.frame.height - 26
    }

    // MARK: - 热键分发

    private func handle(_ action: HotkeyCenter.Action) {
        switch action {
        case .toggleVisibility:
            toggle()
        case .nextPage:
            guard ensureVisibleForAction() else { return }
            nextPage()
        case .prevPage:
            guard ensureVisibleForAction() else { return }
            prevPage()
        case .nextChapter:
            guard ensureVisibleForAction() else { return }
            guard ReadingSession.shared.chapterIndex + 1 < ReadingSession.shared.chapterCount else {
                showNotice("已经是最后一章")
                return
            }
            ReadingSession.shared.nextChapter()
            resetAutoPageTimer()
        case .prevChapter:
            guard ensureVisibleForAction() else { return }
            guard ReadingSession.shared.chapterIndex > 0 else {
                showNotice("已经是第一章")
                return
            }
            ReadingSession.shared.prevChapter()
            resetAutoPageTimer()
        case .toggleAutoPage:
            guard ensureVisibleForAction() else { return }
            toggleAutoPage()
        }
    }

    /// 隐藏态下按翻页热键自动转显示（BR-54）；无会话只提示不自动开书（BR-51）。
    private func ensureVisibleForAction() -> Bool {
        let session = ReadingSession.shared
        // 先确认有可读内容，再决定是否显示面板：否则会把空面板拉起来显示
        // 「未打开书籍」，看起来像凭空多出一个悬浮窗。
        guard session.isActive else {
            if isPanelVisible {
                showNotice("先打开一本书")
            }
            return false
        }
        if !isPanelVisible {
            // 沿用上次的显示模式（迷你模式也照旧）。
            show()
        }
        return true
    }

    // MARK: - 翻页

    func nextPage() {
        guard let list = readyPages() else { return }
        let session = ReadingSession.shared
        let current = TextPaginator.pageIndex(for: session.offset, in: list)
        if current + 1 < list.count {
            session.updateOffset(list[current + 1].range.location, from: .floating)
            resetAutoPageTimer()
        } else if session.chapterIndex + 1 < session.chapterCount {
            session.nextChapter()
            resetAutoPageTimer()
        } else {
            showNotice("已经是最后一页")
        }
    }

    func prevPage() {
        guard let list = readyPages() else { return }
        let session = ReadingSession.shared
        let current = TextPaginator.pageIndex(for: session.offset, in: list)
        if current > 0 {
            session.updateOffset(list[current - 1].range.location, from: .floating)
            resetAutoPageTimer()
        } else if session.chapterIndex > 0 {
            // 跨章回退落在上一章末页，保持翻页连贯。
            session.prevChapter(landingAtEnd: true)
            resetAutoPageTimer()
        } else {
            showNotice("已经是第一页")
        }
    }

    /// 当前模式可用的页表；正常态按面板排版，精简态按单行排版。
    private func readyPages() -> [TextPage]? {
        let session = ReadingSession.shared
        guard session.isActive else {
            showNotice("先打开一本书")
            return nil
        }
        let list = pagesForCurrentMode()
        guard !list.isEmpty else { return nil }
        return list
    }

    func retry() {
        ReadingSession.shared.retry()
        if ReadingSession.shared.isLoading {
            beginLoadingWatchdog()
        }
    }

    // MARK: - 排版

    private func repaginateIfNeeded(force: Bool = false) {
        guard state.mode != .mini else { return }
        let session = ReadingSession.shared
        let text = session.text
        guard !text.isEmpty else {
            pages = []
            paginatedText = ""
            pageText = ""
            pageIndex = 0
            pageCount = 0
            return
        }
        let size = textAreaSize()
        let fontSize = state.fontSize
        if !force,
           text == paginatedText,
           fontSize == paginatedFontSize,
           size == paginatedSize {
            return
        }
        let result = TextPaginator.paginate(text: text,
                                            fontSize: CGFloat(fontSize),
                                            lineSpacing: 6,
                                            size: size)
        pages = result
        paginatedText = text
        paginatedFontSize = fontSize
        paginatedSize = size
    }

    /// 精简态单行排版：每页只取一行，放不下的字符自动出现在下一页（BR-54）。
    private func repaginateMiniIfNeeded(force: Bool = false) {
        let text = ReadingSession.shared.text
        guard !text.isEmpty else {
            miniPages = []
            miniPaginatedText = ""
            miniPaginatedWidth = 0
            miniPaginatedFontSize = 0
            return
        }
        let width = miniTextWidth()
        let fontSize = miniFontSize
        if !force,
           text == miniPaginatedText,
           width == miniPaginatedWidth,
           fontSize == miniPaginatedFontSize { return }
        let result = TextPaginator.paginate(text: text,
                                            fontSize: fontSize,
                                            lineSpacing: 0,
                                            size: CGSize(width: width, height: fontSize + 7),
                                            weight: .medium)
        // 空行单独成页会让翻页出现空白，这里直接跳过纯空白页。
        let nonBlank = result.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        miniPages = nonBlank.isEmpty ? result : nonBlank
        miniPaginatedText = text
        miniPaginatedWidth = width
        miniPaginatedFontSize = fontSize
    }

    /// 迷你条正文可用宽度：按面板当前真实宽度减去固定占用，保证文字铺满整条。
    private func miniTextWidth() -> CGFloat {
        let width = panel?.frame.width ?? Self.miniSize.width
        return max(60, width - miniChromeWidth - 2)
    }

    /// 按当前显示模式取页表：正常态用面板排版结果，精简态用单行排版结果。
    private func pagesForCurrentMode() -> [TextPage] {
        if state.mode == .mini {
            repaginateMiniIfNeeded()
            return miniPages
        }
        repaginateIfNeeded()
        return pages
    }

    /// 按当前章内字符偏移定位到页；偏移是唯一真值（BR-59）。
    private func updatePage() {
        let session = ReadingSession.shared
        guard session.isActive else {
            pageText = ""
            pageIndex = 0
            pageCount = 0
            return
        }
        let list = pagesForCurrentMode()
        guard !list.isEmpty else { return }
        let index = TextPaginator.pageIndex(for: session.offset, in: list)
        pageIndex = index
        pageCount = list.count
        pageText = list[index].text
    }

    private func textAreaSize() -> CGSize {
        let frame = panel?.frame ?? normalFrame
        let width = max(120, frame.width - 28)
        let height = max(60, frame.height - 50)
        return CGSize(width: width, height: height)
    }

    private func sessionChanged() {
        let session = ReadingSession.shared
        if session.isLoading {
            beginLoadingWatchdog()
        } else {
            loadingWatchdog?.cancel()
            loadingWatchdog = nil
        }
        repaginateIfNeeded()
        updatePage()
        if state.isVisible || state.mode != .hidden {
            state.lastBookID = session.bookID.isEmpty ? state.lastBookID : session.bookID
            state.lastChapterIndex = session.isActive ? session.chapterIndex : state.lastChapterIndex
        }
    }

    private func bindSession() {
        ReadingSession.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.sessionChanged() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 面板

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }

        if normalFrame == .zero {
            normalFrame = initialFrame()
        }
        let panel = FloatingPanel(contentRect: normalFrame,
                                  styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                  backing: .buffered,
                                  defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 窗口阴影会在半透明底色边缘透出一圈暗边，看起来像边框；
        // 普通态与迷你态都不需要，故始终关闭。
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize
        panel.onScrollDelta = { [weak self] delta in
            Task { @MainActor in self?.handleScroll(delta) }
        }
        let hosting = FloatingHostingView(rootView: FloatingPanelView(model: self))
        hosting.onMouseDown = { [weak self] event in
            self?.handlePanelMouseDown(event) ?? false
        }
        hosting.onRightMouseDown = { [weak self] event in
            self?.handlePanelRightMouseDown(event) ?? false
        }
        panel.contentView = hosting
        self.panel = panel
        observeWindow(panel)
        return panel
    }

    private func applyNormalFrame(_ panel: FloatingPanel) {
        normalFrame = Self.clamped(normalFrame)
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize
        panel.setFrame(normalFrame, display: true)
        state.frame = FloatingState.Rect(normalFrame)
    }

    private func applyMiniFrame(_ panel: FloatingPanel) {
        // 收起前先把正常态的真实尺寸记下来，展开时才能回到同样的宽高比例。
        if state.mode == .normal, panel.isVisible {
            normalFrame = Self.clamped(panel.frame)
        }
        normalFrame = Self.clamped(normalFrame)
        // 迷你条宽度可以手动拖动：沿用上次拖出来的宽度，高度随字号自适应。
        let miniWidth = min(Self.maxMiniWidth,
                            max(Self.minMiniWidth,
                                CGFloat(state.miniWidth ?? Double(Self.miniSize.width))))
        let size = CGSize(width: miniWidth, height: miniBarHeight)
        let origin = CGPoint(x: normalFrame.origin.x,
                             y: normalFrame.maxY - size.height)
        panel.minSize = CGSize(width: Self.minMiniWidth, height: miniBarHeight)
        panel.maxSize = CGSize(width: Self.maxMiniWidth, height: miniBarHeight)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// 位置落在已移除的显示器时回退到主屏（BR-53）。
    private func recenterIfNeeded(_ panel: FloatingPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if !visible.intersects(panel.frame) {
            let size = panel.frame.size
            let rect = CGRect(x: visible.midX - size.width / 2,
                              y: visible.midY - size.height / 2,
                              width: size.width,
                              height: size.height)
            panel.setFrame(rect, display: true)
            if state.mode == .mini {
                normalFrame = CGRect(x: rect.origin.x,
                                     y: rect.maxY - normalFrame.height,
                                     width: normalFrame.width,
                                     height: normalFrame.height)
            } else {
                normalFrame = rect
            }
            state.frame = FloatingState.Rect(normalFrame)
        }
    }

    private func observeWindow(_ panel: FloatingPanel) {
        let move = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                          object: panel,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelFrameChanged() }
        }
        let resize = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                                            object: panel,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.panelFrameChanged()
                // 按当前模式重排版：迷你条被拖宽后正文要重新折行。
                if self?.state.mode == .mini {
                    self?.repaginateMiniIfNeeded(force: true)
                } else {
                    self?.repaginateIfNeeded(force: true)
                }
                self?.updatePage()
            }
        }
        windowObservers.append(contentsOf: [move, resize])
    }

    private func panelFrameChanged() {
        // 隐藏态不采信任何帧变化，避免把过渡态尺寸写进正常态基准；
        // 快速隐藏缩成图标时同样不记录，否则会把 44pt 图标当成正常尺寸。
        guard let panel, state.mode != .hidden, !quickHidden else { return }
        if state.mode == .mini {
            normalFrame.origin.x = panel.frame.origin.x
            normalFrame.origin.y = panel.frame.maxY - normalFrame.height
            // 迷你条被横向拖宽/拖窄也要记住，下次唤出沿用同一宽度。
            state.miniWidth = Double(panel.frame.width)
        } else {
            normalFrame = panel.frame
        }
        state.frame = FloatingState.Rect(normalFrame)
        Diagnostics.log("float", "moved[\(state.mode.rawValue)] panel=\(rectText(panel.frame)) normal=\(rectText(normalFrame))")
        persistSoon()
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, !self.quickHidden else { return }
                self.normalFrame = Self.clamped(self.normalFrame)
                if self.state.mode == .mini {
                    self.applyMiniFrame(panel)
                } else if self.state.mode == .normal {
                    panel.setFrame(self.normalFrame, display: true)
                }
                // BR-66：唤醒后重置自动翻页计时，唤醒瞬间不立即翻页。
                self.resetAutoPageTimer()
            }
        }
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, !self.quickHidden else { return }
                self.normalFrame = Self.clamped(self.normalFrame)
                if self.state.mode == .mini {
                    self.applyMiniFrame(panel)
                } else if self.state.mode == .normal {
                    panel.setFrame(self.normalFrame, display: true)
                }
                self.repaginateIfNeeded(force: true)
                self.updatePage()
            }
        }
    }

    // MARK: - 滚轮与自动翻页

    private func handleScroll(_ delta: CGFloat) {
        guard state.mode != .hidden else { return }
        let now = Date()
        guard now.timeIntervalSince(lastWheelTurn) > 0.25 else { return }
        wheelAccum += delta
        guard abs(wheelAccum) >= 30 else { return }
        if wheelAccum < 0 { nextPage() } else { prevPage() }
        wheelAccum = 0
        lastWheelTurn = now
    }

    private func rescheduleAutoPageTimer() {
        autoPageTimer?.invalidate()
        autoPageTimer = nil
        guard let interval = state.autoPageInterval, interval > 0, state.mode != .hidden else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoPageTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoPageTimer = timer
    }

    private func autoPageTick() {
        guard state.mode != .hidden, isPanelVisible else { return }
        nextPage()
    }

    private func resetAutoPageTimer() {
        guard autoPageTimer != nil else { return }
        rescheduleAutoPageTimer()
    }

    // MARK: - 加载态与提示

    /// 在线章未缓存时先显示加载态；8s 仍未完成则自动收起（BR-73）。
    private func beginLoadingWatchdog() {
        loadingWatchdog?.cancel()
        loadingWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, ReadingSession.shared.isLoading else { return }
            self.hide()
            Diagnostics.log("floating", "章节加载超过 8s，自动收起悬浮窗")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    private func scheduleCacheRelease() {
        cacheReleaseTask?.cancel()
        cacheReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.state.mode == .hidden else { return }
            self.releasePagesNow()
        }
    }

    private func releasePagesNow() {
        pages = []
        paginatedText = ""
        miniPages = []
        miniPaginatedText = ""
        miniPaginatedWidth = 0
        miniPaginatedFontSize = 0
        pageText = ""
        pageIndex = 0
        pageCount = 0
    }

    // MARK: - 持久化与几何

    private func persistSoon() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func initialFrame() -> CGRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        var rect = state.frame.cgRect
        if rect.width < 100 || rect.height < 100 {
            rect = CGRect(origin: .zero, size: Self.defaultSize)
        }
        if rect.origin == .zero {
            rect.origin = CGPoint(x: visible.maxX - rect.width - 40,
                                 y: visible.maxY - rect.height - 60)
        }
        return Self.clamped(rect)
    }

    private static func clamped(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(max(rect.width, minSize.width), maxSize.width)
        result.size.height = min(max(rect.height, minSize.height), maxSize.height)

        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.contains(CGPoint(x: result.midX, y: result.midY)) }
            ?? NSScreen.main
            ?? screens.first
        guard let visible = screen?.visibleFrame else { return result }

        if !visible.intersects(result) {
            result.origin = CGPoint(x: visible.midX - result.width / 2,
                                    y: visible.midY - result.height / 2)
            return result
        }
        // 位置不再强行挤进屏幕边缘：迷你条的位置是按正常窗口的宽高折算出来的，
        // 若按宽高做边缘夹紧，拖到靠右的迷你条会被拉回旧位置（保存/还原失真）。
        // 只有整块窗口完全落到屏幕之外时才居中。
        return result
    }
}

// MARK: - 面板

final class FloatingPanel: NSPanel {
    var onScrollDelta: ((CGFloat) -> Void)?

    /// 永不成为 key window：前台 App 不失焦（BR-47）。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollDelta {
            onScrollDelta(event.scrollingDeltaY)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// 承载悬浮窗内容的宿主视图：拦一层鼠标按下事件，用于左/右键翻页与双击恢复。
/// 返回 true 表示事件已被消费，不再交给 SwiftUI。
final class FloatingHostingView<Content: View>: NSHostingView<Content> {
    var onMouseDown: ((NSEvent) -> Bool)?
    var onRightMouseDown: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if onMouseDown?(event) == true { return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if onRightMouseDown?(event) == true { return }
        super.rightMouseDown(with: event)
    }
}

// MARK: - 视图

struct FloatingPanelView: View {
    @ObservedObject var model: FloatingPanelController
    @ObservedObject private var session = ReadingSession.shared
    @State private var hovering = false

    var body: some View {
        ZStack {
            if showsBackground { background }
            if model.quickHidden {
                quickHiddenBody
            } else if model.state.mode == .mini {
                miniBody
            } else {
                normalBody
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(model.state.opacity)
        .onHover { inside in
            hovering = inside
            model.hoverChanged(inside)
        }
        .contextMenu { menu }
    }

    /// 完全隐藏 / 只留百分比时不能铺满背景，否则「隐藏」只是变成了纯色块。
    private var showsBackground: Bool {
        guard model.quickHidden else { return true }
        return isIconQuickHide
    }

    private var cornerRadius: CGFloat {
        model.quickHidden && isIconQuickHide ? 10 : 14
    }

    private var isIconQuickHide: Bool {
        model.state.quickHide == .shrinkIcon || model.state.quickHide == .shrinkIconDoubleClick
    }

    /// 快速隐藏态的极简外观：完全透明 / 只留右下角百分比 / 缩成小图标。
    @ViewBuilder
    private var quickHiddenBody: some View {
        switch model.state.quickHide {
        case .hideOnExit, .hideDoubleClick:
            Color.clear
        case .keepPercent:
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    Text(percentLabel)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.thinMaterial))
                }
            }
            .padding(8)
        case .shrinkIcon, .shrinkIconDoubleClick:
            Image(systemName: "book.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(fontColor ?? Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .off:
            Color.clear
        }
    }

    private var backgroundColor: Color? {
        Color(hexRGB: model.state.backgroundColor)
    }

    @ViewBuilder
    private var background: some View {
        if let backgroundColor {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundColor)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private var fontColor: Color? {
        Color(hexRGB: model.state.fontColor)
    }

    // MARK: 正常态

    private var normalBody: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            Text(pageLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            if hovering {
                header
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.thinMaterial))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 22)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !session.isActive {
            placeholder
        } else if session.isLoading {
            loading
        } else if let error = session.lastError, session.text.isEmpty {
            errorView(error)
        } else if session.text.isEmpty {
            Text("这一页没有内容")
                .font(.system(size: model.state.fontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(model.pageText)
                .font(.system(size: model.state.fontSize))
                .lineSpacing(6)
                .foregroundStyle(fontColor ?? Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.top, 30)
                .padding(.bottom, 20)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "book")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("打开一本书")
                .font(.system(size: 13, weight: .medium))
            Text("先读一本书，再唤出悬浮窗")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在加载这一章…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text("这一章没加载出来")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
            Button("重试") { model.retry() }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            headerButton("rectangle.compress.vertical", "迷你模式") { model.toggleMini() }
            headerButton("minus", "隐藏悬浮窗") { model.hide() }
            headerButton("xmark", "关闭悬浮窗") { model.close() }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.thinMaterial)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func headerButton(_ symbol: String, _ hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .help(hint)
    }

    // MARK: 迷你态

    /// 迷你态只留正文与百分比：图标（含关闭按钮）全部隐藏，恢复/关闭走右键菜单。
    private var miniBody: some View {
        HStack(spacing: 6) {
            Text(miniText)
                .font(.system(size: model.miniFontSize, weight: .medium))
                .foregroundStyle(fontColor ?? Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.state.showMiniPercent {
                Text(percentLabel)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: 文案

    private var headerTitle: String {
        let title = session.bookTitle.isEmpty ? "未打开书籍" : session.bookTitle
        return session.chapterTitle.isEmpty ? title : "\(title) · \(session.chapterTitle)"
    }

    private var pageLabel: String {
        guard model.pageCount > 0 else { return "" }
        return "\(model.pageIndex + 1) / \(model.pageCount)"
    }

    /// 迷你态显示当前迷你页的整行正文：一行放不下的内容顺延到下一页，
    /// 因此这里不再按首行截断，也不再使用省略号（BR-54）。
    private var miniText: String {
        guard session.isActive else { return "打开一本书" }
        if session.isLoading { return "正在加载…" }
        let text = model.pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "这一页没有内容" : text
    }

    private var percentLabel: String {
        guard session.isActive else { return "—" }
        return "\(Int((session.bookPercent * 100).rounded()))%"
    }

    // MARK: 右键菜单

    @ViewBuilder
    private var menu: some View {
        Button("放大字号") { model.increaseFont() }
        Button("缩小字号") { model.decreaseFont() }
        Divider()
        Button("更透明") { model.adjustOpacity(-0.05) }
        Button("更不透明") { model.adjustOpacity(0.05) }
        Menu("自动翻页") {
            Button("关闭") { model.setAutoPageInterval(nil) }
            Button("每 5 秒") { model.setAutoPageInterval(5) }
            Button("每 10 秒") { model.setAutoPageInterval(10) }
            Button("每 30 秒") { model.setAutoPageInterval(30) }
        }
        Divider()
        Toggle("迷你模式", isOn: Binding(
            get: { model.state.mode == .mini },
            set: { model.show(mode: $0 ? .mini : .normal) }
        ))
        Button("隐藏悬浮窗") { model.hide() }
        Divider()
        Button("设置") { FloatingSettingsWindow.shared.show() }
    }
}

// MARK: - 颜色

extension Color {
    /// `#RRGGBB` / `RRGGBB` / `#RGB` → Color；无效时返回 nil。
    init?(hexRGB: String?) {
        var s = (hexRGB ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// 转成 `#RRGGBB`，供取色器回写。
    var hexRGBString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
