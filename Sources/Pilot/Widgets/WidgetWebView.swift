import AppKit
import OSLog
import PilotCore
import UniformTypeIdentifiers
import WebKit

private let webLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// An HTML widget's page (ADR 0016, Q680): made only for a widget that is made here or trusted, so a locked widget never
/// starts WebKit. The page is served from its folder through Pilot's own scheme, `pilot-widget://<id>/`, with Pilot's
/// answers under `/__pilot/`; its main frame never leaves the widget; it gets data only as JSON, through a `pilotdata`
/// event and `/__pilot/data`, never a bridge to a shell. It may reach any website (Q676). No persistent data, no Safe
/// Browsing (real network). It draws no background when WebKit's private `drawsBackground` takes, so the glass shows
/// through; otherwise the tile is solid. Pilot's bundled desk pages share one data store and, through WebKit's private
/// `_setRelatedWebView:`, one WebContent process: five measured 72 MB of WebKit with a process each, 33 MB sharing one
/// (2026-10-31). A crash there ends every desk page; each loads again once (WidgetNavigationGuard). Every other page,
/// made here or trusted, keeps its own store and process.
///
/// Its `<html>` carries its size class, `size-strip`, `size-square`, `size-wide` or `size-large` (Widget.SizeClass): set
/// before the page's own script runs, and changed, with a `pilotsize` event whose detail is `{size}`, when a resize
/// crosses a class's line or the page loads again. Edit widget's Layout keeps one class instead.
@MainActor
final class WidgetWebView {
    static let scheme = "pilot-widget"
    /// Every page view made in this run: the renders prove a locked widget makes none.
    private(set) static var made = 0
    /// The one store the desk pages use: WebKit refuses to relate views with different stores.
    private static let deskData = WKWebsiteDataStore.nonPersistent()
    /// The desk pages alive now, any of which a new desk page joins in its process.
    private static let desk = NSHashTable<WKWebView>.weakObjects()

    let view: WKWebView
    /// Whether the page draws over the glass (drawsBackground took) or on a solid tile.
    let seeThrough: Bool
    private let handler: WidgetSchemeHandler
    /// Told the page's content height after each data it is sent, read by the look kit (PilotKit.height); the desk sets it
    /// for Pilot's ready desk widgets, whose height follows their content.
    var fitted: ((Double) -> Void)?
    private let guardian: WidgetNavigationGuard
    /// The class its placement keeps (Edit widget's Layout), nil for Auto: by its size.
    let layout: Widget.SizeClass?
    /// The class on its `<html>` now.
    private(set) var size: Widget.SizeClass
    /// The size Auto follows instead of the view's: a fitted desk page's placement's (WidgetDesk.page); nil follows the view.
    var fixed: CGSize? { didSet { if fixed != oldValue { resized() } } }

    /// Nil for anything but an HTML widget whose trust runs, read now from its record. `size` is the tile's it will fill,
    /// which gives its first class.
    init?(widget: Widget, store: WidgetStore, size tile: CGSize? = nil, layout: Widget.SizeClass? = nil) {
        guard widget.draw == .html, store.trust(of: widget).runs else { return nil }
        handler = WidgetSchemeHandler(widget: widget, store: store)
        guardian = WidgetNavigationGuard(id: widget.id)
        self.layout = layout
        size = layout ?? Widget.SizeClass(tile ?? CGSize(width: widget.size.width, height: widget.size.height))
        let config = WKWebViewConfiguration()
        // A plain word from the enum, set before any of the page's script.
        config.userContentController.addUserScript(WKUserScript(source: "document.documentElement.classList.add('\(size.css)')",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let shares = ReadyWidgets.isDesk(widget)
        config.websiteDataStore = shares ? Self.deskData : .nonPersistent()
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.setURLSchemeHandler(handler, forURLScheme: Self.scheme)
        let relate = NSSelectorFromString("_setRelatedWebView:")
        if shares, let related = Self.desk.anyObject, config.responds(to: relate) { config.perform(relate, with: related) }
        let page = WidgetPageView(frame: .zero, configuration: config)
        view = page
        if shares { Self.desk.add(view) }
        Self.made += 1
        seeThrough = Self.clearBackground(view)
        view.navigationDelegate = guardian
        view.uiDelegate = guardian
        page.resized = { [weak self] in self?.resized() }
        // A load (the first, or once more after a crash) starts with the class it was made with: it gets the one now.
        guardian.loaded = { [weak self] in self?.mark() }
        view.load(URLRequest(url: Self.url(widget.id)))
    }

    /// Its class again from its size, held near a line; the page told only on a change.
    private func resized() {
        guard layout == nil else { return }
        let box = fixed ?? view.frame.size
        guard box.width > 0, box.height > 0 else { return }
        let next = Widget.SizeClass(box, after: size)
        guard next != size else { return }
        size = next
        mark()
    }

    /// Puts its class on the page's `<html>`, every other size class off, and tells the page.
    private func mark() {
        view.callAsyncJavaScript("""
            const c = document.documentElement.classList
            for (const n of [...c]) if (n.startsWith('size-')) c.remove(n)
            c.add('size-' + size)
            window.dispatchEvent(new CustomEvent('pilotsize', {detail: {size}}))
            """, arguments: ["size": size.rawValue], in: nil, in: .page) { _ in }
    }

    static func url(_ id: String, _ path: String = "") -> URL { URL(string: "\(scheme)://\(id)/\(path)")! }

    /// T15's see-through: set the private key only where WebKit has its accessors (KVC finds `_setDrawsBackground:` and
    /// `_drawsBackground` on macOS 27; an unknown key would raise), then read it back; false (a solid tile) unless it reads
    /// false.
    static func clearBackground(_ view: WKWebView) -> Bool {
        guard view.responds(to: NSSelectorFromString("_setDrawsBackground:")), view.responds(to: NSSelectorFromString("_drawsBackground")) else { return false }
        view.setValue(false, forKey: "drawsBackground")
        return (view.value(forKey: "drawsBackground") as? Bool) == false
    }

    /// Hands the page its newest data, with Pilot's theme as its `theme` when it is an object without one (the look kit's
    /// colours, PilotKit.theme; the desk renders hand their own): kept for `/__pilot/data`, and sent as a `pilotdata` event
    /// whose detail is the data, passed as an argument, never written into script text.
    func send(_ data: JSONValue) {
        var data = data
        if case .object(var fields) = data, fields["theme"] == nil {
            fields["theme"] = Self.theme(Look.shared.theme)
            data = .object(fields)
        }
        handler.latest = data
        guard let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(data), options: [.fragmentsAllowed]) else { return }
        view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('pilotdata', {detail: data}))", arguments: ["data": object],
                                 in: nil, in: .page) { _ in }
        guard fitted != nil else { return }
        view.callAsyncJavaScript("return window.PilotKit && PilotKit.height ? PilotKit.height() : 0", arguments: [:], in: nil, in: .page) { [weak self] result in
            if case .success(let height as NSNumber) = result, height.doubleValue > 0 { self?.fitted?(height.doubleValue) }
        }
    }

    /// PilotTheme's fields as the look kit takes them (`--pk-<field>`), each colour `#rrggbb`.
    static func theme(_ t: PilotTheme) -> JSONValue {
        func hex(_ rgb: UInt32) -> JSONValue { .string(String(format: "#%06x", rgb)) }
        return .object(["dark": .bool(t.dark), "ground": hex(t.ground), "surface": hex(t.surface), "raised": hex(t.raised),
                        "line": hex(t.line), "line2": hex(t.line2), "text": hex(t.text), "text2": hex(t.text2), "text3": hex(t.text3),
                        "accent": hex(t.accent), "second": hex(t.second), "third": hex(t.third), "good": hex(t.good),
                        "amber": hex(t.amber), "problem": hex(t.problem), "graphs": .array(t.graphs.map(hex))])
    }

    /// Ends the page: WebKit lets its WebContent process go once no view holds it.
    func end() {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }
}

/// Serves one widget's folder, answering each request at once on the main thread, so no task is ever touched after
/// WebKit stops it. A request for another widget's id, from a widget that is locked now (its trust record is read on
/// every request), for a path that is not a plain file inside the widget's folder once every link is resolved, or past
/// the gallery's 2 MB, is refused with 403. `/__pilot/…` is Pilot's own and never read from the folder. The widget and
/// its folder's real path are the ones the page was made for: a change to either ends the page (WidgetDesk.widgetChanged).
@MainActor
final class WidgetSchemeHandler: NSObject, WKURLSchemeHandler {
    let widget: Widget, store: WidgetStore
    private let root: URL
    /// The newest data the page was sent.
    var latest: JSONValue = .object([:])

    init(widget: Widget, store: WidgetStore) {
        self.widget = widget; self.store = store
        root = widget.folder.resolvingSymlinksInPath().standardizedFileURL
    }

    private var id: String { widget.id }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let (status, body, type) = answer(url)
        if status != 200 { webLog.notice("widget \(self.id, privacy: .public): \(status, privacy: .public) for \(url.path(percentEncoded: true), privacy: .private)") }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Cache-Control": "no-store", "Content-Length": "\(body.count)"])!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    /// Nothing is in flight: every task is answered inside `start`.
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The status, body and type for `url`.
    func answer(_ url: URL) -> (Int, Data, String) {
        let refused = (403, Data(), "text/plain")
        guard url.scheme == WidgetWebView.scheme, url.host(percentEncoded: false) == id, widget.draw == .html,
              store.trust(of: widget).runs else { return refused }
        // Each part decoded on its own, so `%2e%2e` or `%2f` cannot climb out: a part that is not a safe path inside a
        // folder once decoded (empty, `.`, `..`, a slash, backslash or NUL) is refused.
        let raw = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var parts: [String] = []
        for (i, part) in raw.enumerated() {
            if part.isEmpty, i == raw.count - 1 { break }   // a trailing slash
            guard let decoded = String(part).removingPercentEncoding, Widget.isSafeEntry(decoded), !decoded.contains("/") else { return refused }
            parts.append(decoded)
        }
        if parts.first == "__pilot" {
            guard parts == ["__pilot", "data"], let body = try? JSONEncoder().encode(latest) else { return (404, Data(), "text/plain") }
            return (200, body, "application/json")
        }
        if parts.isEmpty { parts = [Widget.entryName] }
        let file = parts.reduce(widget.folder) { $0.appending(path: $1) }.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return refused }
        guard let body = try? Widget.readFile(file, limit: Widget.fileLimit) else {
            return FileManager.default.fileExists(atPath: file.path) ? refused : (404, Data(), "text/plain")
        }
        let ext = file.pathExtension.lowercased()
        let type = ext == "html" || ext == "htm" ? "text/html; charset=utf-8"
            : UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return (200, body, type)
    }
}

/// A page's view, which tells its widget each new size: a resize's class change reaches the page without a timer.
private final class WidgetPageView: WKWebView {
    var resized: () -> Void = {}
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        resized()
    }
}

/// Keeps the main frame in the widget: a main-frame navigation anywhere but `pilot-widget://<id>/` is cancelled, and so is
/// one with no frame (a new window); `window.open` gets no view. Frames inside the page may load what they like.
@MainActor
final class WidgetNavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    /// Told when a load finishes: the page gets its size class as it is now.
    var loaded: () -> Void = {}
    init(id: String) { self.id = id }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let frame = action.targetFrame else { return .cancel }
        guard frame.isMainFrame else { return .allow }
        let url = action.request.url
        return url?.scheme == WidgetWebView.scheme && url?.host(percentEncoded: false) == id ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    private var reloaded = false

    /// A crashed page loads again once; after that it stays blank until the widget shows again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webLog.notice("widget \(self.id, privacy: .public): its page's process ended\(self.reloaded ? "" : "; loading it again", privacy: .public)")
        guard !reloaded else { return }
        reloaded = true
        webView.load(URLRequest(url: WidgetWebView.url(id)))
    }
}
