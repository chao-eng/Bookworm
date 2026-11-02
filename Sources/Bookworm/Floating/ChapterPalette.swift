import SwiftUI
import AppKit
import Combine

/// 章节面板的数据快照。查询变化后列表实时过滤，回车或点击直接跳转。
@MainActor
final class ChapterPaletteModel: ObservableObject {
    let bookTitle: String
    let chapters: [ReadingSession.ChapterSummary]
    let chapterCount: Int
    let currentIndex: Int

    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            message = nil
            selection = trimmedQuery.isEmpty
                ? (chapters.firstIndex { $0.index == currentIndex } ?? 0)
                : 0
        }
    }
    @Published var selection: Int = 0
    @Published var message: String?

    init(bookTitle: String,
         chapters: [ReadingSession.ChapterSummary],
         chapterCount: Int,
         currentIndex: Int) {
        self.bookTitle = bookTitle
        self.chapters = chapters
        self.chapterCount = chapterCount
        self.currentIndex = currentIndex
        self.selection = chapters.firstIndex { $0.index == currentIndex } ?? 0
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 纯数字按 1 基章节号定位，其他文字按标题包含匹配。
    var entries: [ReadingSession.ChapterSummary] {
        guard !trimmedQuery.isEmpty else { return chapters }
        if let number = Int(trimmedQuery) {
            return chapters.filter { $0.index == number - 1 }
        }
        return chapters.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var selectedEntry: ReadingSession.ChapterSummary? {
        let list = entries
        guard !list.isEmpty else { return nil }
        return list[min(max(selection, 0), list.count - 1)]
    }

    var emptyHint: String {
        guard !trimmedQuery.isEmpty else { return "这本书没有可用的章节列表" }
        if let number = Int(trimmedQuery) {
            return "没有第 \(number) 章，共 \(chapterCount) 章"
        }
        return "没有匹配的章节"
    }

    func move(by delta: Int) {
        let list = entries
        guard !list.isEmpty else { return }
        selection = min(max(selection + delta, 0), list.count - 1)
    }

    func select(chapterIndex: Int) {
        guard let position = entries.firstIndex(where: { $0.index == chapterIndex }) else { return }
        selection = position
    }

    /// 返回要跳转的章节索引；输入无效时只更新提示，不跳转。
    func submit() -> Int? {
        guard let target = selectedEntry else {
            message = emptyHint
            return nil
        }
        return target.index
    }
}

/// 可以成为 key window 的临时面板：不激活 Bookworm，但搜索框能接收键盘输入。
final class ChapterPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 章节面板的显示、定位与键盘监听。
@MainActor
final class ChapterPaletteController: NSObject, NSWindowDelegate {
    static let shared = ChapterPaletteController()

    private static let panelSize = CGSize(width: 340, height: 420)

    private var panel: ChapterPalettePanel?
    private var model: ChapterPaletteModel?
    private var keyMonitor: Any?
    private var onClose: (() -> Void)?
    private var isHiding = false

    private override init() {}

    func show(anchor: CGRect, onClose: @escaping () -> Void) {
        let session = ReadingSession.shared
        guard session.isActive else { return }

        // 同一时间只保留一个面板；旧面板关闭时也会复位控制器的状态。
        if panel != nil { hide() }

        let chapters: [ReadingSession.ChapterSummary]
        if session.chapters.isEmpty {
            chapters = (0..<max(session.chapterCount, 1)).map {
                ReadingSession.ChapterSummary(index: $0, title: "第 \($0 + 1) 章")
            }
        } else {
            chapters = session.chapters
        }

        let model = ChapterPaletteModel(bookTitle: session.bookTitle,
                                        chapters: chapters,
                                        chapterCount: max(session.chapterCount, 1),
                                        currentIndex: session.chapterIndex)
        self.model = model
        self.onClose = onClose

        let view = ChapterPaletteView(
            model: model,
            onJump: { [weak self] index in self?.jump(to: index) },
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)

        let panel = ChapterPalettePanel(contentRect: CGRect(origin: .zero,
                                                            size: Self.panelSize),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered,
                                        defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel

        position(panel, anchor: anchor)
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
    }

    func hide() {
        guard let panel, !isHiding else { return }
        isHiding = true
        removeKeyMonitor()
        panel.delegate = nil
        panel.orderOut(nil)
        self.panel = nil
        model = nil
        let callback = onClose
        onClose = nil
        isHiding = false
        callback?()
    }

    private func jump(to index: Int) {
        FloatingPanelController.shared.jumpToChapter(index)
        hide()
    }

    private func position(_ panel: NSPanel, anchor: CGRect) {
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
            ?? screens.first
        guard let visible = screen?.visibleFrame else { return }

        var size = Self.panelSize
        size.height = min(size.height, max(180, visible.height - 16))

        var x = anchor.maxX + 8
        if x + size.width > visible.maxX - 8 {
            x = anchor.minX - size.width - 8
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        let y = min(max(anchor.maxY - size.height, visible.minY + 8),
                    visible.maxY - size.height - 8) 
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height),
                       display: false)
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// ↑↓ 移动选择，回车跳转，Esc 关闭；其余按键交给搜索框。
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel?.isKeyWindow == true, let model else { return event }
        // 输入法组词中（拼音候选窗口）不拦截任何键，交给输入法自己处理，
        // 否则方向键无法选候选词、回车会提前跳章、Esc 会关掉面板。
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return event
        }
        // 带修饰键的方向键是输入框的选区/光标操作（⇧↑、⌘↑），不能吞。
        if !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            return event
        }
        switch event.keyCode {
        case 125:
            model.move(by: 1)
            return nil
        case 126:
            model.move(by: -1)
            return nil
        case 36, 76:
            if let index = model.submit() {
                jump(to: index)
            }
            return nil
        case 53:
            hide()
            return nil
        default:
            return event
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard !isHiding,
              let window = notification.object as? NSWindow,
              window === panel else { return }
        hide()
    }
}

/// 章节面板内容：标题行、搜索框、章节列表和底部提示。
struct ChapterPaletteView: View {
    @ObservedObject var model: ChapterPaletteModel
    let onJump: (Int) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchArea
            Divider()
            chapterList
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .onAppear { searchFocused = true }
        // 面板先 orderFront 再 makeKey，首次聚焦可能发生在非 key 状态下；
        // 成为 key 后再申请一次，保证打开即可直接输入。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("章节列表")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(model.bookTitle.isEmpty ? "当前书籍" : model.bookTitle) · 第 \(model.currentIndex + 1) / \(model.chapterCount) 章")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭章节列表")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("输入章节号，或搜索标题", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit {
                        if let index = model.submit() { onJump(index) }
                    }
                Button("跳转") {
                    if let index = model.submit() { onJump(index) }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if let message = model.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let entries = model.entries
                if entries.isEmpty {
                    emptyState
                } else {
                    // 过滤结果与选中项每次渲染只算一次，避免每行重复全量过滤。
                    let selectedIndex = model.selectedEntry?.index
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { chapter in
                            row(chapter, isSelected: chapter.index == selectedIndex)
                                .id(chapter.index)
                                .onTapGesture {
                                    model.select(chapterIndex: chapter.index)
                                    onJump(chapter.index)
                                }
                        }
                    }
                    .padding(8)
                }
            }
            .onAppear { scrollToSelection(proxy) }
            .onChange(of: model.selection) { _, _ in scrollToSelection(proxy) }
            .onChange(of: model.query) { _, _ in scrollToSelection(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ chapter: ReadingSession.ChapterSummary, isSelected: Bool) -> some View {
        let isCurrent = chapter.index == model.currentIndex
        return HStack(spacing: 8) {
            Text("\(chapter.index + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text(chapter.title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isCurrent {
                Text("正在读")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(.leading, CGFloat(min(max(chapter.level, 0), 4)) * 10)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(model.emptyHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 56)
    }

    private var footer: some View {
        Text("↑↓ 选择 · 回车跳转 · Esc 关闭")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 7)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let target = model.selectedEntry else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(target.index, anchor: .center)
            }
        }
    }
}
