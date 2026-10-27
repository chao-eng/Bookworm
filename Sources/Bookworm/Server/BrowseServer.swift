import Foundation
import Network
import AppKit
import Darwin

/// Tiny LAN HTTP server: other devices on the same network can browse the
/// library and read image books (comics/manga/PDF) through a browser.
/// Ebooks are intentionally not served — their assets need per-chapter file
/// resolution the reader handles in-app.
///
/// ponytail: single-threaded on the main actor for library reads AND image
/// encoding. Fine for LAN-scale traffic; move JPEG encoding off-main if the
/// server ever hosts more than a few concurrent readers.
@MainActor
final class BrowseServer {
    static var shared: BrowseServer?

    private let listener: NWListener
    private let library: LibraryStore
    private(set) var port: UInt16

    /// Reader instances stay open for the server's lifetime so page hits
    /// don't re-parse the archive every request. Cleared on `stop()`.
    private var openReaders: [ComicItem.ID: ContentReader] = [:]

    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var isReady: Bool = false

    private init(library: LibraryStore, port: UInt16) throws {
        self.library = library
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        var chosen: (NWListener, UInt16)?
        for candidate in [port, port + 1, port + 2, port + 3, port + 9, 0] {
            guard let np = NWEndpoint.Port(rawValue: candidate) else { continue }
            if let l = try? NWListener(using: params, on: np) {
                chosen = (l, l.port?.rawValue ?? candidate)
                break
            }
        }
        guard let (l, p) = chosen else {
            throw NSError(domain: "BrowseServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法在 \(port) 附近绑定端口。"])
        }
        self.listener = l
        self.port = p

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: .main)
            Task { @MainActor in await self.handle(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in self.handleState(state) }
        }
        listener.start(queue: .main)
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let realPort = listener.port?.rawValue { self.port = realPort }
            isReady = true
            let conts = readyContinuations
            readyContinuations.removeAll()
            for c in conts { c.resume() }
        case .failed(let error):
            let conts = readyContinuations
            readyContinuations.removeAll()
            for c in conts { c.resume(throwing: error) }
        default:
            break
        }
    }

    /// Await until the listener reaches `.ready` (so `port` is resolved
    /// and connections will actually be accepted).
    func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { cont in
            readyContinuations.append(cont)
        }
    }

    static func start(library: LibraryStore, port: UInt16 = 8080) throws -> BrowseServer {
        stop()
        let s = try BrowseServer(library: library, port: port)
        shared = s
        return s
    }

    static func stop() {
        shared?.tearDown()
        shared = nil
    }

    private func tearDown() {
        listener.cancel()
        for reader in openReaders.values { reader.close() }
        openReaders.removeAll()
    }

    /// User-facing URL ("http://192.168.1.5:8080") — falls back to loopback
    /// if no non-loopback IPv4 is available.
    var displayURL: String {
        let host = BrowseServer.localIPv4() ?? "127.0.0.1"
        return "http://\(host):\(port)"
    }

    // MARK: - Request loop

    private func handle(_ conn: NWConnection) async {
        var buffer = Data()
        while buffer.count < 16 * 1024 {
            let chunk: Data? = await withCheckedContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, _ in
                    if isComplete && (data?.isEmpty ?? true) {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: data)
                    }
                }
            }
            guard let chunk else { break }
            buffer.append(chunk)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer.prefix(upTo: headEnd.lowerBound), encoding: .utf8) else {
            send(status: "400 Bad Request", conn: conn, body: nil, contentType: nil)
            return
        }
        route(head: head, conn: conn)
    }

    private func route(head: String, conn: NWConnection) {
        let firstLine = head.split(separator: "\r\n", omittingEmptySubsequences: true)
            .first.map { String($0) } ?? head
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(status: "405 Method Not Allowed", conn: conn, body: nil, contentType: nil)
            return
        }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path

        if path == "/" || path == "/index.html" {
            renderLibrary(conn: conn); return
        }
        if path.hasPrefix("/cover/") && path.hasSuffix(".jpg") {
            let id = String(path.dropFirst("/cover/".count).dropLast(".jpg".count))
            renderCover(idStr: id, conn: conn); return
        }
        if let match = matchPageURL(path) {
            renderPage(idStr: match.0, page: match.1, conn: conn); return
        }
        if path.hasPrefix("/book/") {
            renderBook(idStr: String(path.dropFirst("/book/".count)), conn: conn); return
        }
        send(status: "404 Not Found", conn: conn,
             body: Data("未找到".utf8), contentType: "text/plain; charset=utf-8")
    }

    private func matchPageURL(_ path: String) -> (String, Int)? {
        guard path.hasPrefix("/book/"), path.hasSuffix(".jpg") else { return nil }
        let stripped = String(path.dropLast(".jpg".count))
        let parts = stripped.split(separator: "/")
        guard parts.count == 4, parts[0] == "book", parts[2] == "page",
              let n = Int(parts[3]) else { return nil }
        return (String(parts[1]), n)
    }

    // MARK: - Routes

    private func renderLibrary(conn: NWConnection) {
        let host = Host.current().localizedName ?? "Mac"
        let html = LibraryPage.render(items: library.items, hostName: host)
        send(status: "200 OK", conn: conn,
             body: Data(html.utf8), contentType: "text/html; charset=utf-8")
    }

    private func renderCover(idStr: String, conn: NWConnection) {
        guard let id = UUID(uuidString: idStr),
              let item = library.item(withID: id),
              let url = library.thumbnailURL(for: item),
              let data = try? Data(contentsOf: url) else {
            send(status: "404 Not Found", conn: conn, body: nil, contentType: nil)
            return
        }
        send(status: "200 OK", conn: conn, body: data,
             contentType: "image/jpeg", cache: "public, max-age=86400")
    }

    private func renderBook(idStr: String, conn: NWConnection) {
        guard let id = UUID(uuidString: idStr),
              let item = library.item(withID: id) else {
            send(status: "404 Not Found", conn: conn, body: nil, contentType: nil); return
        }
        if item.format.isEbook {
            let html = ReaderPage.unsupported(item: item)
            send(status: "200 OK", conn: conn,
                 body: Data(html.utf8), contentType: "text/html; charset=utf-8")
            return
        }
        do {
            let reader = try getReader(for: item)
            let count = try reader.pageCount()
            let html = ReaderPage.render(item: item, pageCount: count)
            send(status: "200 OK", conn: conn,
                 body: Data(html.utf8), contentType: "text/html; charset=utf-8")
        } catch {
            send(status: "500 Internal Server Error", conn: conn,
                 body: Data(error.localizedDescription.utf8),
                 contentType: "text/plain; charset=utf-8")
        }
    }

    private func renderPage(idStr: String, page: Int, conn: NWConnection) {
        guard let id = UUID(uuidString: idStr),
              let item = library.item(withID: id) else {
            send(status: "404 Not Found", conn: conn, body: nil, contentType: nil); return
        }
        do {
            let reader = try getReader(for: item)
            let content = try reader.content(at: page)
            guard case .image(let img) = content,
                  let jpeg = img.resized(maxDimension: 2400)
                              .jpegData(compressionQuality: 0.86) else {
                send(status: "415 Unsupported Media Type", conn: conn, body: nil, contentType: nil)
                return
            }
            send(status: "200 OK", conn: conn, body: jpeg,
                 contentType: "image/jpeg", cache: "public, max-age=3600")
        } catch {
            send(status: "500 Internal Server Error", conn: conn,
                 body: Data(error.localizedDescription.utf8),
                 contentType: "text/plain; charset=utf-8")
        }
    }

    private func getReader(for item: ComicItem) throws -> ContentReader {
        if let existing = openReaders[item.id] { return existing }
        let r = try ArchiveFactory.makeReader(for: item)
        openReaders[item.id] = r
        return r
    }

    // MARK: - HTTP write

    private func send(status: String, conn: NWConnection,
                       body: Data?, contentType: String?,
                       cache: String = "no-store") {
        let payload = body ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Cache-Control: \(cache)\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Local IP discovery

    /// First non-loopback IPv4 on an `en*` interface (Wi-Fi / Ethernet).
    static func localIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let start = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var current: UnsafeMutablePointer<ifaddrs>? = start
        var found: String?
        while let ptr = current {
            let iface = ptr.pointee
            let flags = Int32(iface.ifa_flags)
            let name = String(cString: iface.ifa_name)
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               name.hasPrefix("en"),
               let sa = iface.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST) == 0 {
                    found = String(cString: host)
                    break
                }
            }
            current = iface.ifa_next
        }
        return found
    }
}

// MARK: - HTML

private enum LibraryPage {
    static func render(items: [ComicItem], hostName: String) -> String {
        let cards = items.map { item -> String in
            let title = htmlEscape(item.title)
            let format = htmlEscape(item.format.displayName)
            let badge = item.format.isEbook
                ? "<div class=\"badge\">电子书 — 请在应用内打开</div>" : ""
            return """
            <a class="card" href="/book/\(item.id.uuidString)">
              <div class="cover"><img src="/cover/\(item.id.uuidString).jpg" loading="lazy" alt=""></div>
              <div class="meta">
                <div class="title">\(title)</div>
                <div class="sub">\(format)</div>
                \(badge)
              </div>
            </a>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-CN"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Bookworm — \(htmlEscape(hostName))</title>
        <style>
          :root { color-scheme: dark light; }
          html, body { margin: 0; background: #14161a; color: #eee; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
          header { padding: 20px 24px; display: flex; align-items: baseline; gap: 10px; }
          header h1 { margin: 0; font-size: 22px; }
          header .host { color: #999; font-size: 13px; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 20px; padding: 0 24px 40px; }
          a.card { color: inherit; text-decoration: none; background: #1c1e22; border-radius: 8px; overflow: hidden; display: block; transition: transform .12s ease; }
          a.card:hover { transform: translateY(-2px); }
          .cover { aspect-ratio: 2/3; background: #2a2d33; }
          .cover img { width: 100%; height: 100%; object-fit: cover; display: block; }
          .meta { padding: 8px 10px; }
          .title { font-size: 13px; line-height: 1.3; max-height: 2.6em; overflow: hidden; }
          .sub { font-size: 11px; color: #999; margin-top: 4px; }
          .badge { font-size: 10px; color: #f0c674; margin-top: 4px; }
          .empty { padding: 60px; text-align: center; color: #999; }
        </style>
        </head><body>
        <header><h1>Bookworm</h1><span class="host">由 \(htmlEscape(hostName)) 提供</span></header>
        \(items.isEmpty ? "<div class=\"empty\">书库中还没有书籍。</div>" : "<div class=\"grid\">\(cards)</div>")
        </body></html>
        """
    }
}

private enum ReaderPage {
    static func render(item: ComicItem, pageCount: Int) -> String {
        let title = htmlEscape(item.title)
        let id = item.id.uuidString
        return """
        <!doctype html>
        <html lang="zh-CN"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
          :root { color-scheme: dark; }
          html, body { margin: 0; background: #000; color: #fff; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
          .stage { min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 12px 12px 72px; }
          img.page { max-width: 100%; max-height: calc(100vh - 96px); height: auto; user-select: none; -webkit-user-select: none; }
          nav { position: fixed; bottom: 12px; left: 0; right: 0; display: flex; align-items: center; justify-content: center; gap: 10px; padding: 0 12px; }
          nav a, nav button { background: rgba(255,255,255,0.12); color: #fff; padding: 8px 14px; border-radius: 8px; border: 0; font: inherit; font-size: 14px; text-decoration: none; cursor: pointer; }
          nav button:disabled { opacity: 0.4; cursor: default; }
          nav .count { min-width: 90px; text-align: center; font-variant-numeric: tabular-nums; color: #ccc; }
        </style>
        </head><body>
        <div class="stage"><img id="page" class="page" alt=""></div>
        <nav>
          <a href="/">← 书库</a>
          <button id="prev" aria-label="上一页">上一页</button>
          <span class="count" id="count"></span>
          <button id="next" aria-label="下一页">下一页</button>
        </nav>
        <script>
          const bookId = "\(id)";
          const total = \(pageCount);
          let p = 0;
          const hash = location.hash.match(/p=(\\d+)/);
          if (hash) p = Math.max(0, Math.min(total-1, parseInt(hash[1], 10) - 1));
          const $ = id => document.getElementById(id);
          function render() {
            $('page').src = `/book/${bookId}/page/${p}.jpg`;
            $('count').textContent = `${p+1} / ${total}`;
            $('prev').disabled = p === 0;
            $('next').disabled = p === total - 1;
            history.replaceState(null, '', `#p=${p+1}`);
          }
          $('prev').onclick = () => { if (p>0) { p--; render(); } };
          $('next').onclick = () => { if (p<total-1) { p++; render(); } };
          document.addEventListener('keydown', e => {
            if (['ArrowLeft','PageUp'].includes(e.key)) { if (p>0) { p--; render(); } e.preventDefault(); }
            if (['ArrowRight','PageDown',' '].includes(e.key)) { if (p<total-1) { p++; render(); } e.preventDefault(); }
          });
          render();
        </script>
        </body></html>
        """
    }

    static func unsupported(item: ComicItem) -> String {
        let title = htmlEscape(item.title)
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
          body { background: #14161a; color: #ccc; font-family: -apple-system, sans-serif; padding: 40px; }
          a { color: #6fa8ff; }
        </style>
        </head><body>
        <h2>\(title)</h2>
        <p>电子书暂不支持通过局域网共享——请在 Bookworm 应用中打开。</p>
        <p><a href="/">← 书库</a></p>
        </body></html>
        """
    }
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}
