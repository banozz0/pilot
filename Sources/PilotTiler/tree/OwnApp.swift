// Pilot (card agent-bo-95422999, route 2): Pilot's own windows. AeroSpace never managed its own process ("AX requests
// crash if you send them to yourself"), so in-process the engine skipped Pilot's windows; and AX from Pilot to itself
// could block the main thread, which runs the key tap. The engine moves these windows through AppKit on the main thread
// instead: MacApp's interface, with no AX thread and no AX call.
import AppKit

/// One of Pilot's windows as the engine sees it: an NSWindow in the app, a fake in tests.
@MainActor
protocol OwnWindow: AnyObject {
    var windowNumber: Int { get }
    var frame: NSRect { get }
    var title: String { get }
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    var isKeyWindow: Bool { get }
    var isFullScreen: Bool { get }
    var engineWindowType: AxUiElementWindowType { get }
    func setFrame(_ frame: NSRect, display: Bool)
    func makeKeyAndOrderFront(_ sender: Any?)
    func performClose(_ sender: Any?)
    func miniaturize(_ sender: Any?)
    func deminiaturize(_ sender: Any?)
    func toggleFullScreen(_ sender: Any?)
}

extension NSWindow: OwnWindow {
    var isFullScreen: Bool { styleMask.contains(.fullScreen) }

    /// A titled, resizable window tiles and a fixed-size one floats as a dialog; panels (the menu, alerts), sheets and
    /// child or raised windows are never laid out.
    var engineWindowType: AxUiElementWindowType {
        guard styleMask.contains(.titled), !(self is NSPanel), !isSheet, parent == nil, level == .normal else { return .popup }
        return styleMask.contains(.resizable) ? .window : .dialog
    }
}

extension OwnWindow {
    fileprivate var engineId: UInt32? { windowNumber > 0 ? UInt32(exactly: windowNumber) : nil }

    /// The frame in the engine's coordinates: top-left origin on the main screen, y down.
    fileprivate var engineRect: Rect { frame.monitorFrameNormalized() }

    /// The engine's own write: the move and resize it posts are not news to the engine (OwnApp.isWritingFrame).
    fileprivate func setEngineFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        let old = engineRect
        let topLeft = topLeft ?? old.topLeftCorner
        let size = size ?? old.size
        OwnApp.isWritingFrame = true
        defer { OwnApp.isWritingFrame = false }
        setFrame(Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height).appKitFrame, display: true)
    }
}

final class OwnApp: MacApp {
    /// Pilot's windows; tests swap in fakes.
    @MainActor static var windows: () -> [any OwnWindow] = { NSApp?.windows ?? [] }
    @MainActor private static var observers: [any NSObjectProtocol] = []
    @MainActor fileprivate static var isWritingFrame = false

    private init(_ nsApp: NSRunningApplication) {
        super.init(nsApp, AXUIElementCreateApplication(nsApp.processIdentifier), [], nil)
    }

    @MainActor
    static func register(_ nsApp: NSRunningApplication) -> MacApp {
        // MacApp's AX values are thread-guarded, made and destroyed under one token; with no AX thread none is ever read.
        let app = $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: nsApp.processIdentifier, idForDebug: nsApp.idForDebug)) {
            let app = OwnApp(nsApp)
            app.destroyAxValues()
            return app
        }
        allAppsMap[nsApp.processIdentifier] = app
        observeWindows()
        return app
    }

    @MainActor fileprivate static func window(_ id: UInt32) -> (any OwnWindow)? { windows().first { $0.engineId == id } }

    /// What the AX notifications are for another app's windows: each event as the engine handles that notification.
    /// Panels (the menu, alerts) are never laid out, so their events are not news either.
    @MainActor private static func observeWindows() {
        guard observers.isEmpty else { return }
        let events: [(Notification.Name, @MainActor (UInt32) -> Void)] = [
            (NSWindow.didBecomeKeyNotification, { _ in refreshOnWindowEvent(kAXFocusedWindowChangedNotification) }),
            (NSWindow.willCloseNotification, { _ in refreshOnWindowEvent(kAXUIElementDestroyedNotification) }),
            (NSWindow.didMiniaturizeNotification, { _ in refreshOnWindowEvent(kAXWindowMiniaturizedNotification) }),
            (NSWindow.didDeminiaturizeNotification, { _ in refreshOnWindowEvent(kAXWindowDeminiaturizedNotification) }),
            (NSWindow.didMoveNotification, { if !isWritingFrame { windowMoved($0, kAXMovedNotification) } }),
            (NSWindow.didResizeNotification, { if !isWritingFrame { windowResized($0, kAXResizedNotification) } }),
        ]
        observers = events.map { name, handle in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let window, window.engineWindowType != .popup, let id = window.engineId else { return }
                    handle(id)
                }
            }
        }
    }

    override func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [UInt32] {
        await MainActor.run { OwnApp.windows().filter { $0.isVisible || $0.isMiniaturized }.compactMap(\.engineId) }
    }

    @MainActor override func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        guard let id = OwnApp.windows().first(where: \.isKeyWindow)?.engineId else { return nil }
        return try await MacWindow.getOrRegister(windowId: id, macApp: self)
    }

    /// AppKit raises it, and Pilot comes forward as any app does (MacApp.nativeFocus), less the AX way: a plain
    /// `activate()` alone was refused (live bug 2026-10-20, OwnWindowTests).
    @MainActor override func raise(_ windowId: UInt32, raises: Bool, glidingAtCall: Bool) async -> (line: String, ways: [AppActivation])? {
        OwnApp.window(windowId)?.makeKeyAndOrderFront(nil)
        return ("raised by AppKit", AppActivation.order.filter { $0 != .axFrontmost })
    }

    override func getAxRect(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        await MainActor.run { OwnApp.window(windowId)?.engineRect }
    }

    override func getAxSize(_ windowId: UInt32, _ cm: CancellationMode) async throws -> CGSize? {
        try await getAxRect(windowId, cm)?.size
    }

    override func getAxRectForTermination(_ windowId: UInt32) -> Rect? {
        Thread.isMainThread ? MainActor.assumeIsolated { OwnApp.window(windowId)?.engineRect } : nil
    }

    /// Pilot's own windows jump: AppKit's own animation would post moves the engine reads as the user's.
    override func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?, glidingFrom: Rect? = nil,
                             duration: Duration = GlideSet.duration, span: ClosedRange<CGFloat>? = nil, screen: GlideScreen? = nil,
                             fromCorner: Bool = false, then: CGPoint? = nil) {
        onMain { OwnApp.window(windowId)?.setEngineFrame(topLeft, size) }
    }

    override func setAxFrameForTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setAxFrame(windowId, topLeft, size)
    }

    override func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        onMain { OwnApp.window(windowId)?.performClose(nil) }
    }

    /// A window gone by the time it is asked about (a tip the next tip released mid-refresh) is never laid out: taken for
    /// a tiled window, it held half of Pilot's window's tile, empty, until the next refresh (Sven 2026-10-10).
    override func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        await MainActor.run { OwnApp.window(windowId)?.engineWindowType } ?? .popup
    }

    override func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        await MainActor.run { OwnApp.window(windowId).map { $0.engineWindowType != .popup } } == true
    }

    override func getAxTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        await MainActor.run { OwnApp.window(windowId)?.title }
    }

    override func isMacosNativeMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        await MainActor.run { OwnApp.window(windowId)?.isMiniaturized }
    }

    override func isMacosNativeFullscreen(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        await MainActor.run { OwnApp.window(windowId)?.isFullScreen }
    }

    override func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        onMain {
            guard let window = OwnApp.window(windowId) else { return }
            value ? window.miniaturize(nil) : window.deminiaturize(nil)
        }
    }

    override func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        onMain {
            guard let window = OwnApp.window(windowId), window.isFullScreen != value else { return }
            window.toggleFullScreen(nil)
        }
    }
}

/// Frame writes come from the main actor (layout, unparking), so they land at once; from anywhere else, they wait for it.
private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread { MainActor.assumeIsolated(body) } else { Task.startUnstructured { @MainActor in body() } }
}

/// Pilot's app window coming on screen: another app's new window reaches the engine as AX's window-created notification,
/// but Pilot's own posts nothing when macOS keeps another app in front (opened from a panel, Pilot never active, so no
/// key or activation event). It floated where AppKit put it until some other event refreshed (Sven 2026-10-10, 22 s
/// behind Ghostex).
public enum TilerOwnWindows {
    @MainActor public static func shown() { refreshOnWindowEvent(kAXWindowCreatedNotification) }
    /// One of Pilot's windows was brought forward on purpose (opened, or raised again): Show desktop ends, else a window
    /// it holds in the hide corner, which raising it again (it was in front at the press) never brings back, opens out
    /// of sight (Sven on 1.0.2 build 6, Edit widget on a desktop widget). Not on key alone: Cmd+Tab back to the app in
    /// front at the press keeps it. True when it ended.
    @MainActor @discardableResult public static func broughtForward() -> Bool {
        guard shownDesktop != nil else { return false }
        shownDesktop = nil
        refreshOnWindowEvent(kAXWindowCreatedNotification)
        return true
    }
    /// One of Pilot's windows the tiler lays out (tiled or floating), not a panel, sheet, child or raised window.
    @MainActor public static func isLaidOut(_ window: NSWindow) -> Bool { window.engineWindowType != .popup }
}
