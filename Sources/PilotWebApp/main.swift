// The web-app template: one binary, stamped per site by the WebApps module; the site lives in Info.plist
// (WebAppKey). Test-only env, honoured only with PILOT_HEADLESS=1 (no window, no Dock icon): PILOT_EVAL runs
// JavaScript after the page loads, prints the result and the page's share of the window and quits a second later, once no
// popup is open (each prints as PILOT_POPUP, and PILOT_POPUP_DONE when it closes itself back on the site);
// PILOT_DOWNLOADS puts downloads in that folder instead of ~/Downloads; PILOT_FIND searches the page for its text as the
// find bar does, prints the bar's label and quits; the Dock badge prints as PILOT_BADGE; PILOT_WINDOW_TOP picks the window
// top (a WindowTop raw value, else Standard), so a run never reads Sven's setting, and Slim strip's page colour prints as
// PILOT_PAGE_COLOUR. A headless run never asks macOS
// or anyone about notifications: a request is answered as Sven's Don't Allow, which that app's defaults keep (fine on a
// throwaway stamp only).
import AppKit
import UserNotifications
import WebKit
import WebApps

let info = Bundle.main.infoDictionary ?? [:]
let env = ProcessInfo.processInfo.environment
let appName = info["CFBundleName"] as? String ?? "Web App"
let startURL: URL = {
    guard let url = (info[WebAppKey.url] as? String).flatMap(URL.init(string:)) else {
        FileHandle.standardError.write(Data("PilotWebApp: no \(WebAppKey.url) in Info.plist; Pilot stamps it per site\n".utf8))
        exit(1)
    }
    return url
}()
let stampedSite = SameSite(siteURL: startURL, extraHosts: info[WebAppKey.sameSiteHosts] as? [String] ?? [])
let sameSite = SameSite.forWebApp(siteURL: startURL, extraHosts: info[WebAppKey.sameSiteHosts] as? [String] ?? [])
let headless = env["PILOT_HEADLESS"] == "1"
let downloadsFolder = headless ? env["PILOT_DOWNLOADS"].map { URL(fileURLWithPath: $0) } ?? Downloads.folder : Downloads.folder

@MainActor func openExternally(_ url: URL) {
    let ws = NSWorkspace.shared
    let browser = (info[WebAppKey.externalBrowser] as? String).flatMap(ws.urlForApplication(withBundleIdentifier:))
    if headless {  // test runs never touch Sven's browser
        print("PILOT_EXTERNAL \(url) -> \(browser?.path ?? "default browser")"); fflush(stdout); return
    }
    if let app = browser {
        ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    } else {
        ws.open(url)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    /// Over the page, hidden until Cmd+F (card agent-bo-95422811).
    var findBar: FindBar!
    /// Under the page: one row per download (card agent-bo-95422810).
    let downloads = NSStackView()
    var downloadRows: [ObjectIdentifier: DownloadRow] = [:]
    var popups: [NSWindow] = []
    /// Each popup's sign-in trip, by its web view, and the page this window showed when it opened: one back on the site
    /// after a sign-in page closes itself. Judged by the stamped site alone, so Messenger's popup is not home on Facebook.
    var trips: [ObjectIdentifier: (trip: SignInTrip, opener: URL?)] = [:]
    var titleObservation: NSKeyValueObservation?
    /// The window top Pilot set (Q355), and the page colour Slim strip takes.
    var chrome: WindowChrome!
    var colourObservations: [NSKeyValueObservation] = []
    var didRunTestHooks = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let config = WKWebViewConfiguration()
        if let s = info[WebAppKey.dataStoreID] as? String, let id = UUID(uuidString: s) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "Version/27.0.1 Safari/605.1.15"
        config.userContentController.add(notifications, name: NotificationBridge.handler)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        downloads.orientation = .vertical
        downloads.spacing = 0
        // The page takes every point the download rows leave; with no download it fills the window.
        findBar = FindBar(webView: webView)
        let page = NSStackView(views: [findBar, webView, downloads])
        page.orientation = .vertical
        page.spacing = 0
        page.distribution = .fill
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        downloads.setContentHuggingPriority(.required, for: .vertical)
        chrome = WindowChrome(window: window)
        window.contentView = chrome.host(page)
        chrome.apply(headless ? env["PILOT_WINDOW_TOP"].flatMap(WindowTop.init) ?? .standard : WindowTop.saved())
        if !headless { chrome.followPilot() }  // Sven's next pick reaches an open web app at once
        func follow<Value>(_ colour: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
            webView.observe(colour) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageColourChanged() } }
        }
        colourObservations = [follow(\.themeColor), follow(\.underPageBackgroundColor)]
        window.title = appName
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("PilotMainWindow")
        titleObservation = webView.observe(\.title) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                if let t = wv.title, !t.isEmpty { self?.window.title = t }
                // The unread count the site puts in its title badges the Dock icon (story 187).
                let badge = DockBadge.label(fromTitle: wv.title)
                if headless { print("PILOT_BADGE \(badge ?? "none")"); fflush(stdout) }
                if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
            }
        }
        notifications.attach(webView: webView, window: window)
        // The page starts with the permission it already has: the script goes in before the first load.
        Task {
            webView.configuration.userContentController.addUserScript(await notifications.script())
            webView.load(URLRequest(url: startURL))
        }
        if !headless {  // test runs never put a window on screen, where a tiler would place it
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        if headless {  // a page that never loads still ends the run
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NSApp.terminate(nil) }
        }
    }

    /// Slim strip's colour: the site's theme-color, else what it draws behind its page.
    func pageColourChanged() {
        chrome.pageColour = webView.themeColor ?? webView.underPageBackgroundColor
        if headless, let colour = chrome.pageColour?.usingColorSpace(.sRGB) {
            print(String(format: "PILOT_PAGE_COLOUR %.2f %.2f %.2f", colour.redComponent, colour.greenComponent, colour.blueComponent)); fflush(stdout)
        }
    }

    // Dock click with the window closed brings it back, page state intact.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: menu

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(); let menu = NSMenu(title: title)
            items.forEach(menu.addItem); item.submenu = menu; main.addItem(item); return menu
        }
        func mi(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        _ = sub(appName, [mi("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
                       mi("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                       .separator(),
                       mi("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")])
        _ = sub("File", [mi("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        let find = FindInPage.menuItems.map { item in
            let action = switch item.step {
            case .next: #selector(findNext)
            case .previous: #selector(findPrevious)
            case .show, .close: #selector(showFind)
            }
            return mi(item.title, action, item.key, item.shift ? [.command, .shift] : .command)
        }
        _ = sub("Edit", [mi("Undo", Selector(("undo:")), "z"), mi("Redo", Selector(("redo:")), "z", [.command, .shift]),
                         .separator(),
                         mi("Cut", #selector(NSText.cut(_:)), "x"), mi("Copy", #selector(NSText.copy(_:)), "c"),
                         mi("Paste", #selector(NSText.paste(_:)), "v"), mi("Select All", #selector(NSText.selectAll(_:)), "a"),
                         .separator()] + find)
        _ = sub("View", [mi("Reload", #selector(reload), "r"),
                         mi("Back", #selector(goBack), "["), mi("Forward", #selector(goForward), "]"),
                         .separator(),
                         mi("Copy Page URL", #selector(copyURL), "l"),
                         mi("Open in Browser", #selector(openInBrowser), "o", [.command, .shift]),
                         .separator(),
                         mi("Actual Size", #selector(zoomReset), "0"), mi("Zoom In", #selector(zoomIn), "="),
                         mi("Zoom Out", #selector(zoomOut), "-")])
        let win = sub("Window", [mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc func reload() { webView.reload() }
    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func zoomReset() { webView.pageZoom = 1 }
    @objc func zoomIn() { webView.pageZoom += 0.1 }
    @objc func zoomOut() { webView.pageZoom -= 0.1 }
    @objc func copyURL() {
        guard let url = webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc func openInBrowser() { if let url = webView.url { openExternally(url) } }

    // MARK: navigation — a clicked link to another site leaves the app; redirects (OAuth) and sign-in pages stay.

    func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if let url = action.request.url, mainFrame, sameSite.route(url, click: action.navigationType == .linkActivated) == .browser {
            openExternally(url); decisionHandler(.cancel); return
        }
        if let url = action.request.url, mainFrame { trips[ObjectIdentifier(wv)]?.trip.visit(url) }  // redirects too
        if let url = action.request.url, !["http", "https", "about", "data", "blob"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url); decisionHandler(.cancel); return  // mailto:, tel:, app links
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)  // <a download>
    }

    /// Test runs only: how much of the window the page has, beside the download rows.
    var layoutLine: String {
        "layout page=\(Int(webView.frame.height)) rows=\(Int(downloads.frame.height)) window=\(Int(window.contentView?.frame.height ?? 0))"
    }

    /// The page's Notification API (card agent-bo-95422812); a headless run prints instead of asking anyone.
    let notifications = WebNotifications(notifier: headless ? PrintingNotifier() : MacNotifier())

    // MARK: find in page (card agent-bo-95422811): the bar does the work

    @objc func showFind() { findBar.toggle() }
    @objc func findNext() { findBar.step(.next) }
    @objc func findPrevious() { findBar.step(.previous) }

    // MARK: downloads (card agent-bo-95422810) — what the page cannot show, or the site sends as an attachment

    func webView(_ wv: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.isForMainFrame && (!response.canShowMIMEType || Downloads.isAttachment(response.response)) ? .download : .allow)
    }

    func webView(_ wv: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ wv: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let destination = Downloads.destination(for: suggestedFilename, in: downloadsFolder)
        let row = DownloadRow(file: destination, progress: download.progress)
        downloadRows[ObjectIdentifier(download)] = row
        downloads.addArrangedSubview(row)
        if headless { print("PILOT_DOWNLOAD \(destination.path)"); fflush(stdout) }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let row = downloadRows.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // The Dock's Downloads stack bounces, as it does for Safari's.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: row.file.path)
        do {
            try Downloads.mark(row.file, with: Downloads.quarantine(agent: appName, source: download.originalRequest?.url, page: download.webView?.url))
            row.show(.done)
        } catch {
            row.show(.unmarked(error.localizedDescription))  // said, never hidden: Gatekeeper will not ask about it
        }
        if headless {
            window.contentView?.layoutSubtreeIfNeeded()
            print("PILOT_DOWNLOADED \(row.file.path) \(layoutLine)"); fflush(stdout)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        // A download that failed before the site answered has no row yet: it gets one, so the failure is never silent.
        let row = downloadRows.removeValue(forKey: ObjectIdentifier(download)) ?? {
            let row = DownloadRow(file: downloadsFolder.appending(path: Downloads.unansweredName(download.originalRequest?.url)),
                                  progress: download.progress)
            downloads.addArrangedSubview(row)
            return row
        }()
        row.show(.failed(error.localizedDescription))
        if headless { print("PILOT_DOWNLOAD_FAILED \(row.file.lastPathComponent) \(error.localizedDescription)"); fflush(stdout) }
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        if wv !== webView { return popupFinished(wv) }
        guard headless, !didRunTestHooks else { return }
        if let query = env["PILOT_FIND"] {
            didRunTestHooks = true
            return findBar.search(query) { label, found in
                print("PILOT_FIND label=\(label) found=\(found)"); fflush(stdout)
                NSApp.terminate(nil)
            }
        }
        guard let js = env["PILOT_EVAL"] else { return }
        didRunTestHooks = true
        wv.evaluateJavaScript(js) { result, error in
            print("PILOT_EVAL result=\(String(describing: result)) error=\(String(describing: error)) \(self.layoutLine)")
            fflush(stdout)
            self.quitOncePopupsClose()
        }
    }

    /// A second after PILOT_EVAL, or later while a popup it opened is still on its way back (the 30 second cap still holds).
    func quitOncePopupsClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.popups.isEmpty ? NSApp.terminate(nil) : self.quitOncePopupsClose() }
    }

    // MARK: UI delegate — target=_blank, window.open popups, alerts, file upload

    func webView(_ wv: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        // target=_blank links stay in this window or leave for the browser; script and sized windows (OAuth sign-in and
        // the like) are a real child window sharing the session.
        switch sameSite.route(url, click: action.navigationType == .linkActivated, newWindow: true,
                              sized: windowFeatures.width != nil || windowFeatures.height != nil) {
        case .here: webView.load(action.request); return nil
        case .browser: openExternally(url); return nil
        case .popup: break
        }
        if headless { print("PILOT_POPUP \(url)"); fflush(stdout) }
        let popup = WKWebView(frame: .zero, configuration: config)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowFeatures.width?.doubleValue ?? 500,
                                             height: windowFeatures.height?.doubleValue ?? 650),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = popup
        w.center()
        if !headless { w.makeKeyAndOrderFront(nil) }
        popups.append(w)
        var trip = SignInTrip(site: stampedSite)
        trip.visit(url)
        trips[ObjectIdentifier(popup)] = (trip, webView.url)
        // Closed with its close button too, not only by the page's window.close(): the window, its web view and the page's
        // scripts went on running until the app quit.
        NotificationCenter.default.addObserver(self, selector: #selector(popupClosed(_:)), name: NSWindow.willCloseNotification, object: w)
        return popup
    }

    func webViewDidClose(_ wv: WKWebView) {
        popups.first { $0.contentView === wv }?.close()
    }

    /// A sign-in popup back on the site closes a moment later, once the page there has handed its result to the opener,
    /// unless it moved on or closed itself first. Still open then, the site meant a new tab: this window, still on the
    /// page that opened it, reloads with the sign-in's cookies (the landing URL may hold a one-time token).
    func popupFinished(_ wv: WKWebView) {
        guard let url = wv.url, let opened = trips[ObjectIdentifier(wv)], opened.trip.isOver(at: url) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak wv] in
            guard let self, let wv, !wv.isLoading, wv.url == url, popups.contains(where: { $0.contentView === wv }) else { return }
            if headless { print("PILOT_POPUP_DONE \(url)"); fflush(stdout) }
            webViewDidClose(wv)
            if webView.url == opened.opener { webView.reload() }
        }
    }

    @objc func popupClosed(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: w)
        if let popup = w.contentView as? WKWebView {
            popup.stopLoading()
            trips[ObjectIdentifier(popup)] = nil
        }
        popups.removeAll { $0 === w }
        // On the next pass, once the close is done with it: the web view goes with the window.
        DispatchQueue.main.async { w.contentView = nil }
    }

    func webView(_ wv: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }

    func webView(_ wv: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ wv: WKWebView, runOpenPanelWith params: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = params.allowsMultipleSelection
        p.canChooseDirectories = params.allowsDirectories
        p.beginSheetModal(for: window) { completionHandler($0 == .OK ? p.urls : nil) }
    }
}

/// What the page's notifications reach outside the app: macOS and Sven, or, in a headless run, standard output.
@MainActor protocol Notifier {
    /// The web app's own ask, once per web app.
    func askSven(over window: NSWindow?) async -> Bool
    func askMacOS() async -> Bool
    func macOSAllows() async -> Bool
    func post(id: Int, title: String, body: String, identifier: String)
    func remove(identifier: String)
    func tell(_ text: String, over window: NSWindow?)
}

struct MacNotifier: Notifier {
    private var center: UNUserNotificationCenter { .current() }

    func askSven(over window: NSWindow?) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = "\(appName) wants to show notifications"
        alert.informativeText = "\(startURL.host ?? appName) can show macOS notifications while \(appName) is running."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    func askMacOS() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }

    func macOSAllows() async -> Bool { [.authorized, .provisional].contains(await center.notificationSettings().authorizationStatus) }

    func post(id: Int, title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["id": id]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func remove(identifier: String) { center.removeDeliveredNotifications(withIdentifiers: [identifier]) }

    func tell(_ text: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Test runs: nobody is asked, Sven's answer is no, and what would show is printed.
struct PrintingNotifier: Notifier {
    func askSven(over window: NSWindow?) async -> Bool { false }
    func askMacOS() async -> Bool { false }
    func macOSAllows() async -> Bool { false }
    func post(id: Int, title: String, body: String, identifier: String) { print("PILOT_NOTIFY \(title)"); fflush(stdout) }
    func remove(identifier: String) {}
    func tell(_ text: String, over window: NSWindow?) { print("PILOT_SAID \(text)"); fflush(stdout) }
}

/// The page's notifications (card agent-bo-95422812): the script it starts with, its messages, Sven's and macOS's
/// answers kept per web app, and a click that brings the web app forward and runs the page's onclick.
@MainActor final class WebNotifications: NSObject, WKScriptMessageHandler {
    private let notifier: any Notifier
    private let decisions = NotificationDecisions()
    private weak var webView: WKWebView?
    private weak var window: NSWindow?

    init(notifier: any Notifier) { self.notifier = notifier }

    func attach(webView: WKWebView, window: NSWindow) {
        self.webView = webView
        self.window = window
        if notifier is MacNotifier { UNUserNotificationCenter.current().delegate = self }
    }

    /// macOS is asked what it allows only when Sven allowed this web app; otherwise the answer is already known.
    func script() async -> WKUserScript {
        let allows = decisions.decision == .allowed ? await notifier.macOSAllows() : false
        return script(permission: decisions.pagePermission(macOSAllows: allows))
    }

    private func script(permission: PagePermission) -> WKUserScript {
        WKUserScript(source: NotificationBridge.script(permission: permission), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// After an answer the next page load must start with it, not with the permission the app launched with. The
    /// notification script is the template's only user script, so replacing all of them replaces just it.
    private func restart(with permission: PagePermission) {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        controller.addUserScript(script(permission: permission))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the site's own page: never an embedded frame (an ad), nor a page of another site the main frame was sent to.
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, sameSite.contains(url) else { return }
        switch WebNotificationMessage(message.body) {
        case .request(let id)?:
            let page = message.webView
            let gate = NotificationGate(decisions: decisions, askUser: { [weak self] in await self?.notifier.askSven(over: self?.window) ?? false },
                                        askMacOS: { [notifier] in await notifier.askMacOS() })
            Task {
                let answer = await gate.request()
                restart(with: answer.permission)
                _ = try? await page?.evaluateJavaScript("window.__pilotNotification.resolve(\(id), '\(answer.permission.rawValue)')")
                if let said = answer.message { notifier.tell(said, over: window) }
            }
        case .show(let id, let title, let body, let tag)?:
            notifier.post(id: id, title: title, body: body, identifier: WebNotificationMessage.identifier(id: id, tag: tag))
        case .close(let id, let tag)?:
            notifier.remove(identifier: WebNotificationMessage.identifier(id: id, tag: tag))
        case nil:
            return
        }
    }
}

/// One shown while the web app is in front still shows; a click brings it forward and runs the page's onclick.
extension WebNotifications: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let id = response.notification.request.content.userInfo["id"] as? Int {
            webView?.evaluateJavaScript("window.__pilotNotification.click(\(id))")
        }
        done()
    }
}

/// The find bar over the page (card agent-bo-95422811): the search field, how many matches, previous, next and Done.
/// It counts the matches in the page's text once typing pauses, lights the next one with WKWebView's own find, and
/// hands the keyboard back to the page when it closes.
@MainActor final class FindBar: NSStackView, NSSearchFieldDelegate {
    private weak var webView: WKWebView?
    private let field = NSSearchField()
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        isHidden = true
        orientation = .horizontal
        edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        field.placeholderString = "Find in page"
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        label.textColor = .secondaryLabelColor
        let button = { (image: String, name: String, action: Selector) -> NSButton in
            let button = NSButton(image: NSImage(systemSymbolName: image, accessibilityDescription: name)!, target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            return button
        }
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .accessoryBarAction
        [NSView(), field, label, button("chevron.up", "Previous match", #selector(previous)),
         button("chevron.down", "Next match", #selector(next)), done].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { nil }

    /// Cmd+F: opens with the keyboard in the field; again, it closes.
    func toggle() {
        guard isHidden else { return close() }
        isHidden = false
        window?.makeFirstResponder(field)
        search(field.stringValue)
    }

    func step(_ step: FindInPage.Step) {
        // Return before the typed word was searched: search it now, which lights the first match.
        if let pending, !pending.isCancelled, step == .next || step == .previous { return search(field.stringValue) }
        switch step {
        case .next: find(backwards: false)
        case .previous: find(backwards: true)
        case .close: close()
        case .show: toggle()
        }
    }

    @objc private func next() { step(.next) }
    @objc private func previous() { step(.previous) }

    @objc private func close() {
        isHidden = true
        webView?.evaluateJavaScript("getSelection().removeAllRanges()")
        window?.makeFirstResponder(webView)
    }

    /// Each keystroke waits 120 ms for the next, so a word typed is one search of the page, not one per letter.
    func controlTextDidChange(_ note: Notification) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self.map { $0.search($0.field.stringValue) } } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Return and Shift+Return step, Escape closes; the field types everything else.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): step(FindInPage.step(for: .return, shift: NSEvent.modifierFlags.contains(.shift)))
        case #selector(NSResponder.cancelOperation(_:)): step(FindInPage.step(for: .escape))
        default: return false
        }
        return true
    }

    /// Counts the matches in the page's text, says how many, and lights the next one; `report` gets the label and
    /// whether WebKit found one (the headless PILOT_FIND hook).
    func search(_ query: String, report: (@MainActor (String, Bool) -> Void)? = nil) {
        pending?.cancel()
        if field.stringValue != query { field.stringValue = query }  // never while typing: the caret would jump
        guard !query.isEmpty, let webView else { label.stringValue = ""; return }
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] text, _ in
            guard let self, query == self.field.stringValue else { return }
            let said = FindInPage.label(query: query, count: FindInPage.count(query, in: text as? String ?? ""))
            self.label.stringValue = said
            self.find(backwards: false) { report?(said, $0) }
        }
    }

    private func find(backwards: Bool, then done: (@MainActor (Bool) -> Void)? = nil) {
        guard !field.stringValue.isEmpty, let webView else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(field.stringValue, configuration: configuration) { done?($0.matchFound) }
    }
}

/// One download under the page: its line (Downloads.status), its buttons once it is done (Downloads.actions), and a
/// close button.
@MainActor final class DownloadRow: NSStackView {
    let file: URL
    private let label = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []  // one per Downloads.Action, in its order
    private var observation: NSKeyValueObservation?
    private var ended = false

    init(file: URL, progress: Progress) {
        self.file = file
        super.init(frame: .zero)
        orientation = .horizontal
        edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A stack view drops a subview that leaves it, so closing is removing.
        let closer = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self,
                              action: #selector(removeFromSuperview))
        closer.bezelStyle = .accessoryBarAction
        closer.isBordered = false
        addArrangedSubview(label)
        addArrangedSubview(NSView())
        for (index, action) in Downloads.Action.allCases.enumerated() {
            let button = NSButton(title: action.rawValue, target: self, action: #selector(press(_:)))
            button.bezelStyle = .accessoryBarAction
            button.isHidden = true
            button.tag = index
            buttons.append(button)
            addArrangedSubview(button)
        }
        addArrangedSubview(closer)
        show(.progress(received: 0, total: -1))
        observation = progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let state = Downloads.State.progress(received: progress.completedUnitCount, total: progress.totalUnitCount)
            DispatchQueue.main.async { self?.show(state) }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Every received chunk reports; the label changes only when its text does (a percent, a size step). An end state
    /// stops the progress and shows the buttons it offers.
    func show(_ state: Downloads.State) {
        if ended, case .progress = state { return }  // a tick queued before the end must not cover it
        let text = Downloads.status(name: file.lastPathComponent, state)
        if label.stringValue != text { label.stringValue = text }
        if case .progress = state { return }
        let offered = Downloads.actions(state)
        for (action, button) in zip(Downloads.Action.allCases, buttons) { button.isHidden = !offered.contains(action) }
        ended = true
        observation = nil
    }

    @objc private func press(_ sender: NSButton) {
        switch Downloads.Action.allCases[sender.tag] {
        case .open: NSWorkspace.shared.open(file)
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(headless ? .prohibited : .regular)
app.run()
