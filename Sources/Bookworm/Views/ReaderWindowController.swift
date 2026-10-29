import AppKit
import SwiftUI

@MainActor
final class ReaderWindowController: NSObject {
    static let shared = ReaderWindowController()

    private var windows: [ComicItem.ID: NSWindow] = [:]
    private var delegates: [ObjectIdentifier: WindowDelegate] = [:]

    func open(itemID: ComicItem.ID, library: LibraryStore, onClose: @escaping () -> Void) {
        if let existing = windows[itemID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let item = library.item(withID: itemID) else { return }

        let root: AnyView
        // 本地书籍的 ReaderModel 在这里创建并直接开始加载，不再依赖
        // SwiftUI 的 onAppear（窗口偶发不触发该回调时会导致一直停在
        // “正在打开书籍…”的初始状态）。
        var localHolder: ReaderModelHolder?
        if item.format == .online {
            root = AnyView(OnlineReaderView(itemID: itemID)
                .environmentObject(library))
        } else {
            let holder = ReaderModelHolder()
            holder.install(ReaderModel(itemID: itemID, library: library))
            localHolder = holder
            root = AnyView(ReaderView(itemID: itemID, model: holder)
                .environmentObject(library))
        }

        let hosting = NSHostingController(rootView: root)
        let initialSize = ReaderWindowController.preferredContentSize(for: item, library: library)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = item.title
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.contentMinSize = NSSize(width: 520, height: 600)

        // Honor any previously-saved window frame (so resizes stick across
        // launches), but on the very first open size the window to the
        // content's aspect ratio so the page isn't cropped or letterboxed.
        let autosaveName = "Reader-\(itemID.uuidString)"
        let frameKey = "NSWindow Frame \(autosaveName)"
        let hasSavedFrame = UserDefaults.standard.string(forKey: frameKey) != nil
        window.setFrameAutosaveName(autosaveName)
        if !hasSavedFrame {
            window.setContentSize(initialSize)
            window.center()
        }

        let delegate = WindowDelegate { [weak self] in
            guard let self else { return }
            self.windows.removeValue(forKey: itemID)
            onClose()
        }
        window.delegate = delegate
        delegates[ObjectIdentifier(window)] = delegate
        windows[itemID] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        localHolder?.value?.load()
    }

    func bringToFront(itemID: ComicItem.ID) {
        windows[itemID]?.makeKeyAndOrderFront(nil)
    }

    /// 关闭某本书的阅读窗（从书架移除前调用）。
    func close(itemID: ComicItem.ID) {
        windows[itemID]?.close()
    }

    /// Sizes the reader window so the page area roughly matches the content's
    /// aspect ratio (so comics and manga pages aren't letterboxed or cropped).
    /// We derive the ratio from the cached cover thumbnail when available;
    /// ebooks fall back to a comfortable reading-column ratio because their
    /// text reflows. Result is clamped to a reasonable fraction of the screen.
    private static func preferredContentSize(for item: ComicItem, library: LibraryStore) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)

        // width / height
        let pageRatio: CGFloat
        if item.format.isEbook {
            pageRatio = 0.72
        } else if let thumb = library.thumbnailImage(for: item),
                  thumb.size.width > 0, thumb.size.height > 0 {
            pageRatio = thumb.size.width / thumb.size.height
        } else {
            pageRatio = 0.68 // typical portrait comic
        }

        // Reserve room for the reader's toolbar and bottom slider.
        let chrome: CGFloat = 96
        let maxH = min(screen.height * 0.90, 1400)
        let minH: CGFloat = 720
        let maxW = screen.width * 0.85
        let minW: CGFloat = 600

        var height = min(maxH, max(minH, screen.height * 0.84))
        let pageHeight = height - chrome
        var width = pageHeight * pageRatio

        if width > maxW {
            width = maxW
            height = (width / pageRatio) + chrome
        }
        if width < minW {
            width = minW
            height = (width / pageRatio) + chrome
        }
        if height > maxH {
            height = maxH
            let ph = height - chrome
            width = ph * pageRatio
        }

        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

/// Placeholder used by the WindowGroup-backed reader scene. Not the primary
/// entry point; double-clicking a library card uses `ReaderWindowController`.
struct ReaderWindowHost: View {
    let itemID: ComicItem.ID?
    @StateObject private var holder = ReaderModelHolder()

    var body: some View {
        if let id = itemID {
            ReaderView(itemID: id, model: holder)
        } else {
            Text("未选择书籍。")
                .foregroundStyle(.secondary)
        }
    }
}
