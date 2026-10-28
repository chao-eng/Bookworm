import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
enum AppMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--smoke-test"), idx + 1 < args.count {
            SmokeTest.run(folder: args[idx + 1])
            exit(0)
        }
        if let idx = args.firstIndex(of: "--ocr-test"), idx + 1 < args.count {
            OCRDiagnostic.run(imagePath: args[idx + 1])
            exit(0)
        }
        if args.contains("--serve-test") {
            serveTestAndExit()
        }
        BookwormApp.main()
    }

    /// Smoke-test the BrowseServer HTTP parser without a UI: bind on a
    /// random port, curl the root and a 404 path, print statuses, exit.
    /// Run with `swift run Bookworm --serve-test`.
    private static func serveTestAndExit() -> Never {
        Task { @MainActor in
            do {
                let library = LibraryStore()
                let server = try BrowseServer.start(library: library, port: 0)
                try await server.waitUntilReady()
                let base = "http://127.0.0.1:\(server.port)"
                async let root = URLSession.shared.data(from: URL(string: base + "/")!)
                async let miss = URLSession.shared.data(from: URL(string: base + "/nope")!)
                let (_, r1) = try await root
                let (_, r2) = try await miss
                let s1 = (r1 as? HTTPURLResponse)?.statusCode ?? -1
                let s2 = (r2 as? HTTPURLResponse)?.statusCode ?? -1
                print("[serve-test] port=\(server.port) root=\(s1) miss=\(s2)")
                assert(s1 == 200 && s2 == 404, "unexpected statuses")
                BrowseServer.stop()
                exit(s1 == 200 && s2 == 404 ? 0 : 1)
            } catch {
                print("[serve-test] failed: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(2)
    }
}

/// AppKit delegate. Owns the two app-wide stores so that AppKit-level
/// integration points — files opened from Finder / the Dock, and the
/// Dock's right-click menu — can reach them without SwiftUI plumbing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryStore()
    let openBooks = OpenBooks()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FloatingPanelController.shared.install()
    }

    /// 退出前强制写盘（BR-64）。
    func applicationWillTerminate(_ notification: Notification) {
        ReadingSession.shared.flush()
        FloatingPanelController.shared.persistNow()
    }

    /// Files opened from Finder (double-click, "Open With"), dropped on
    /// the Dock icon, or passed on the command line. Each supported file
    /// is registered as a library item and opened in a reader window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where ComicFormat.from(url: url) != nil {
            if let id = library.addExternalFile(url: url) {
                openBooks.open(itemID: id, library: library)
            }
        }
    }

    /// Right-click Dock menu — a shortcut list of recently opened books.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let recents = Array(library.recentlyOpened.prefix(8))
        guard !recents.isEmpty else { return nil }
        let menu = NSMenu()
        for item in recents {
            let entry = NSMenuItem(title: item.title,
                                    action: #selector(openRecentFromDock(_:)),
                                    keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func openRecentFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? ComicItem.ID else { return }
        openBooks.open(itemID: id, library: library)
    }
}

struct BookwormApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Only force `.regular` when launched as a plain executable (e.g.
        // `swift run`), where nothing has promoted us out of the "background
        // process" activation policy and we'd otherwise come up without a
        // Dock icon or menu bar. When launched as a .app bundle,
        // NSApplicationMain has already set the policy from Info.plist;
        // calling it again from inside App.init has been observed to race
        // SwiftUI startup and SIGTRAP on some macOS versions.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        WindowGroup("Bookworm") {
            RootView()
                .environmentObject(appDelegate.library)
                .environmentObject(appDelegate.openBooks)
                // Floor large enough that the onboarding's 480-pt 3D orb,
                // tagline and pill CTA all fit at once without the user
                // having to manually resize the window.
                .frame(minWidth: 760, minHeight: 780)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        // First-open size — wide enough for the library grid later, tall
        // enough for the welcome screen on first launch. Subsequent opens
        // use whatever frame macOS remembered for the window.
        .defaultSize(width: 980, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") {
                    appDelegate.library.promptForFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("打开文件…") {
                    openFilePanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("重新扫描书库") {
                    appDelegate.library.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Menu("最近打开") {
                    let recents = appDelegate.library.recentlyOpened
                    if recents.isEmpty {
                        Button("暂无最近书籍") {}.disabled(true)
                    } else {
                        ForEach(recents.prefix(12)) { item in
                            Button(item.title) {
                                appDelegate.openBooks.open(itemID: item.id,
                                                            library: appDelegate.library)
                            }
                        }
                        Divider()
                        Button("清除菜单") {
                            appDelegate.library.clearRecentlyOpened()
                        }
                    }
                }

                Divider()

                Button("搜索在线书…") {
                    NotificationCenter.default.post(name: .bookwormShowOnlineSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("书源管理…") {
                    NotificationCenter.default.post(name: .bookwormShowSourceManagement, object: nil)
                }

                Divider()

                // The feasible stand-in for cloud sync: an explicit
                // backup file the user can drop into iCloud Drive /
                // Dropbox themselves. Real iCloud sync needs an iCloud
                // container entitlement, which the ad-hoc-signed
                // SwiftPM build can't carry.
                Button("导出书库备份…") {
                    exportLibraryBackup()
                }
                Button("导入书库备份…") {
                    importLibraryBackup()
                }
            }

            // Sparkle 自动更新，位于应用菜单（Bookworm ▸）下
            // like every other Mac app that ships Sparkle.
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Updater.shared.checkForUpdates()
                }
                .disabled(!Updater.shared.canCheck)
                Button("更新设置…") {
                    UpdateSettingsWindow.shared.show()
                }
            }

            // 悬浮静默窗的菜单入口，与全局热键并存（UC-10~UC-13）。
            CommandMenu("悬浮窗") {
                Button("显示 / 隐藏") {
                    FloatingPanelController.shared.toggle()
                }
                Divider()
                Button("下一页") { FloatingPanelController.shared.nextPage() }
                Button("上一页") { FloatingPanelController.shared.prevPage() }
                Button("下一章") { ReadingSession.shared.nextChapter() }
                Button("上一章") { ReadingSession.shared.prevChapter() }
                Divider()
                Button("自动翻页") { FloatingPanelController.shared.toggleAutoPage() }
                Button("迷你模式") { FloatingPanelController.shared.toggleMini() }
                Divider()
                Button("设置") { FloatingSettingsWindow.shared.show() }
            }
        }

        WindowGroup("阅读器", for: ComicItem.ID.self) { $itemID in
            ReaderWindowHost(itemID: itemID)
                .environmentObject(appDelegate.library)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 800)
    }
}

@MainActor
final class OpenBooks: ObservableObject {
    @Published var openItemIDs: Set<ComicItem.ID> = []

    /// Open a book in its own reader window, or bring the existing
    /// window forward if it's already open. Single entry point shared
    /// by the library grid, the drag-and-drop handler, the File ▸ Open
    /// Recent menu, the Dock menu, and Finder file-opens.
    func open(itemID: ComicItem.ID, library: LibraryStore) {
        if openItemIDs.contains(itemID) {
            ReaderWindowController.shared.bringToFront(itemID: itemID)
            return
        }
        openItemIDs.insert(itemID)
        ReaderWindowController.shared.open(itemID: itemID, library: library) { [weak self] in
            self?.openItemIDs.remove(itemID)
        }
    }
}

extension BookwormApp {
    private var supportedExtensions: [String] {
        ["cbz", "cbr", "zip", "rar", "7z", "pdf",
         "epub", "mobi", "prc", "azw", "azw3", "kf8",
         "fb2", "txt", "html", "htm", "xhtml"]
    }

    /// File ▸ Open File… — pick one or more supported files anywhere on
    /// disk, add them to the library as external items, and open them.
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "打开书籍"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let id = appDelegate.library.addExternalFile(url: url) {
                    appDelegate.openBooks.open(itemID: id, library: appDelegate.library)
                }
            }
        }
    }

    /// File ▸ Export Library Backup… — write the whole library (items,
    /// reading progress, bookmarks, per-book prefs) to a JSON file.
    func exportLibraryBackup() {
        guard let data = appDelegate.library.exportBackupData(
            sources: SourceRepository.shared.sources,
            floating: FloatingPanelController.shared.state
        ) else { return }
        let panel = NSSavePanel()
        panel.title = "导出书库备份"
        panel.allowedContentTypes = [.json]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Bookworm-Library-\(stamp.string(from: Date())).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// File ▸ Import Library Backup… — merge a previously-exported
    /// backup file back into the current library.
    func importLibraryBackup() {
        let panel = NSOpenPanel()
        panel.title = "导入书库备份"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let result = appDelegate.library.importBackup(data: data)

        // 书源与悬浮窗配置按合并方式恢复（UC-17）。
        if let pkg = LibraryStore.decodeBackup(data) {
            if let sources = pkg.sources, !sources.isEmpty,
               let encoded = try? JSONEncoder().encode(sources),
               let preview = SourceRepository.shared.preview(data: encoded).preview {
                SourceRepository.shared.apply(preview, resolution: .overwrite)
            }
            if let floating = pkg.floating {
                FloatingPanelController.shared.importState(floating)
            }
        }

        let alert = NSAlert()
        if result.updated == 0 && result.added == 0 {
            alert.messageText = "没有可导入的内容"
            alert.informativeText = "备份中没有与本机文件匹配的书籍。"
        } else {
            alert.messageText = "书库备份已导入"
            alert.informativeText = """
            已更新 \(result.updated) 本书的阅读进度，并新增 \(result.added) 本书。
            """
        }
        alert.runModal()
    }
}

struct RootView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var openBooks: OpenBooks
    @State private var dropTargeted: Bool = false
    /// 未选书库文件夹时，从菜单进入在线书源仍能打开书架。
    @State private var forceLibrary: Bool = false

    var body: some View {
        Group {
            if library.rootFolder == nil && library.items.isEmpty && !forceLibrary {
                OnboardingView()
            } else {
                LibraryView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookwormShowOnlineSearch)) { _ in
            forceLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookwormShowSourceManagement)) { _ in
            forceLibrary = true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("拖放以打开", systemImage: "arrow.down.doc")
                            .font(.title2.bold())
                            .foregroundStyle(.tint)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Accept files dropped anywhere on the main window. Each supported
    /// file is registered as an external library item and opened; the
    /// provider load is async so we hop back to the main actor to touch
    /// the store and the window controller.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else {
                    url = nil
                }
                guard let url, ComicFormat.from(url: url) != nil else { return }
                Task { @MainActor in
                    if let id = library.addExternalFile(url: url) {
                        openBooks.open(itemID: id, library: library)
                    }
                }
            }
        }
        return accepted
    }
}
