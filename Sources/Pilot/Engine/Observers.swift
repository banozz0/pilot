import AppKit
import ApplicationServices
import Observation
import PilotCore
import PilotTiler

/// A Pilot window the focused-window border marks while it has the keys, as any app's window (P32).
protocol BorderedWindow: NSWindow {}

extension BorderedWindow {
    /// Brought to the front with no change of key window (a click on it, or a second open while it has the keys): the
    /// border is stacked over it again (Sven on build 76).
    func raised() { NotificationCenter.default.post(name: borderedWindowRaised, object: self) }
}

let borderedWindowRaised = Notification.Name("dev.banozz.pilot.borderedWindowRaised")

struct WindowInfo: Identifiable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect
}

/// The engine's published state: focused app, focused window frame, window list per app, desktop per display.
/// Other modules (and the game, later) read it; keep it public and cheap.
@Observable @MainActor
final class EngineObservers {
    private(set) var focusedApp: NSRunningApplication?
    /// Screen coordinates with a top-left origin, as the Accessibility API reports them.
    private(set) var focusedWindowFrame: CGRect?
    private(set) var focusedWindowTitle: String?
    private(set) var focusedWindowSubrole: String?
    /// Display identifier (as com.apple.spaces names it) to the 1-based index of its current desktop, plus the count.
    private(set) var desktopPerDisplay: [String: (index: Int, count: Int)] = [:]
    /// Pilot's tiler: the focused workspace and the one each monitor shows.
    let tiler: TilerService

    /// One AX observer per app once it has been in front, kept until it quits: adding the notifications is a call into
    /// the app, and redoing it on every switch held the main thread, and the key tap with it (sampled 2026-10-09).
    @ObservationIgnored private var axObservers: [pid_t: AXObserver] = [:]
    /// The focused app's pid, read once per refresh so an AX callback asks the app nothing.
    @ObservationIgnored private var focusedPid: pid_t = 0
    private var tokens: [NSObjectProtocol] = []
    /// Each read of the focused window: focus, move, resize, the tiler's writes (the window border follows it, card agent-bo-95422950).
    var onFocusedWindow: (WindowBorder.Window?) -> Void = { _ in }
    /// The focused window's title, frame and AX element as one app reports them; tests pass a fake.
    @ObservationIgnored var readFocusedWindow: @MainActor (pid_t) -> FocusedWindowRead? = { EngineObservers.drawnFocusedWindow($0) }
    /// The last read's window server number: the tiler's writes to other windows are not re-read.
    @ObservationIgnored private(set) var focusedWindowID: CGWindowID?
    /// The last read's window and its AX element: a move or resize of that element reads its frame alone.
    @ObservationIgnored private var focusedWindow: WindowBorder.Window?
    @ObservationIgnored private var focusedElement: AXUIElement?
    /// Moves and resizes, read at most once per display frame, off the main thread.
    @ObservationIgnored let follower: FrameFollower
    /// The focused window while the mouse holds it: its window server bounds every display frame.
    @ObservationIgnored let drag: DragFollower
    /// The drag follower holds one of Pilot's own windows: its release reads no AppKit frame (ownWindowNote).
    @ObservationIgnored private var ownDrag = false

    /// What the focused app's AX observer re-reads the focused window on. Minimise fires no focus change while the app
    /// keeps focus, so it is listened for itself (card agent-bo-95422995).
    static let axNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowMovedNotification,
                                  kAXWindowResizedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    /// An app hidden, shown again or quit may leave the frontmost app unchanged, so no activation follows.
    static let workspaceRefreshNotifications = [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                                                NSWorkspace.didTerminateApplicationNotification]
    /// Pilot's own windows: AX does not report them to Pilot's own observer; only read while Pilot is the focused app.
    static let ownWindowRefreshNotifications = [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                                NSWindow.willCloseNotification]
    /// A window the border marks (BorderedWindow) takes the keys while another app stays in front: read whatever is active.
    static let borderedWindowNotifications = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willMoveNotification,
                                              NSWindow.didMoveNotification, NSWindow.didResizeNotification, borderedWindowRaised]

    typealias FocusedWindowRead = (title: String?, window: WindowBorder.Window, element: AXUIElement?)

    init(tiler: TilerService = TilerService(), follower: FrameFollower = FrameFollower(), drag: DragFollower = DragFollower()) {
        self.tiler = tiler
        self.follower = follower
        self.drag = drag
        follower.landed = { [weak self] in self?.frameLanded($0, $1) }
        follower.full = { [weak self] in self?.refreshFocusedWindow() }
        follower.settled = { [weak self] id, frame in self?.settled(id, frame) }
        drag.landed = { [weak self] id, frame in
            guard let self, focusedWindowID == id else { return }
            followed(frame)
        }
        drag.ended = { [weak self] in self?.settle() }
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFocusedApp() }
        })
        for name in Self.workspaceRefreshNotifications {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let quit = name == NSWorkspace.didTerminateApplicationNotification
                    ? (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier : nil
                Task { @MainActor in
                    if let quit { self?.forgetObserver(quit) }
                    self?.refreshFocusedApp()
                }
            })
        }
        for name in Self.ownWindowRefreshNotifications {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if NSApp.isActive { self?.refreshFocusedWindow() } }
            })
        }
        // Every Pilot window posts these, the border's own panel each drag frame: only a marked one gets a Task, or
        // Pilot's key window (or the window its sheet or child sits on), or one resigning key, while Pilot is in front,
        // as Pilot never observes itself through Accessibility (T59).
        for name in Self.borderedWindowNotifications {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                let resigned = note.name == NSWindow.didResignKeyNotification
                MainActor.assumeIsolated {
                    guard window is BorderedWindow || (NSApp.isActive && window != nil
                        && (resigned || window === NSApp.keyWindow || window === NSApp.keyWindow?.sheetParent || window === NSApp.keyWindow?.parent))
                    else { return }
                    self?.ownWindowNote(name, window)
                }
            })
        }
        // A Space switch that keeps the front app sends no activation: its focused window is read again, so the border
        // leaves a window that stayed on the other Space (tester bug 9).
        tokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDesktops()
                self?.refreshFocusedWindow()
            }
        })
        TilerFrames.landed = { [weak self] in self?.tilerLanded($0) }
        refreshFocusedApp()
        refreshDesktops()
    }

    /// On-screen windows of one app (layer 0, the ones a user would call windows).
    func windows(of app: NSRunningApplication) -> [WindowInfo] { windows().filter { $0.pid == app.processIdentifier } }

    /// On-screen windows by the tiler's id: its window ids are CGWindowIDs.
    func windowsByID() -> [Int: WindowInfo] {
        Dictionary(windows().map { (Int($0.id), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// On-screen window frames by the tiler's id.
    func framesByID() -> [Int: CGRect] { windowsByID().mapValues(\.frame) }

    func windows() -> [WindowInfo] { Self.normal(Self.onScreen(), skipping: Self.clickThrough()) }

    /// The normal-level windows of `list`, without `skipping`.
    nonisolated static func normal(_ list: [(info: WindowInfo, layer: Int, alpha: Double)], skipping: Set<CGWindowID>) -> [WindowInfo] {
        list.filter { $0.layer == 0 && !skipping.contains($0.info.id) }.map(\.info)
    }

    /// Pilot's own click-through overlays: never a window to focus, swap or drag. Defocus's panels sit at the normal level
    /// (card agent-bo-95423220), the rest above it. A deferred panel not shown yet has no window number (≤ 0) and is on
    /// no list to skip (card agent-bo-95423302).
    static func clickThrough(_ windows: [NSWindow] = NSApp.windows) -> Set<CGWindowID> {
        Set(windows.compactMap { $0.ignoresMouseEvents ? CGWindowID(exactly: $0.windowNumber) : nil })
    }

    /// Another app with no Dock icon (an agent's cursor, a screen overlay): its whole-screen window takes no pointer in
    /// practice. Never Pilot's own, which clickThrough tells.
    static func isOverlayApp(_ pid: pid_t) -> Bool {
        pid != getpid() && NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy != .regular } ?? false
    }

    /// Every on-screen window, front to back, with its layer and alpha; windows() keeps the normal ones, the Alt+drag tap
    /// needs the rest to know a menu or panel is on top.
    nonisolated static func onScreen() -> [(info: WindowInfo, layer: Int, alpha: Double)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            return (WindowInfo(id: id, pid: pid, title: w[kCGWindowName as String] as? String ?? "", frame: frame), layer,
                    w[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// A readable dump for the menu bar's "Print observers" and the debug log.
    func snapshot() -> String {
        var lines: [String] = []
        let app = focusedApp.map { "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "?"), pid \($0.processIdentifier))" } ?? "none"
        lines.append("focused app: \(app)")
        let frame = focusedWindowFrame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
        lines.append("focused window: \(focusedWindowTitle ?? "") \(frame) \(focusedWindowSubrole ?? "no subrole")")
        if let focusedApp {
            let ws = windows(of: focusedApp)
            lines.append("windows of focused app: \(ws.count)")
            for w in ws { lines.append("  #\(w.id) \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)) \(w.title)") }
        }
        for (display, d) in desktopPerDisplay.sorted(by: { $0.key < $1.key }) {
            lines.append("display \(display): desktop \(d.index) of \(d.count)")
        }
        lines += tiler.lines
        return lines.joined(separator: "\n")
    }

    // MARK: focused app and window

    #if DEBUG
    /// The renders' focused app, without starting the observers.
    func seed(focusedApp: NSRunningApplication, windowTitle: String? = nil) {
        (self.focusedApp, focusedWindowTitle) = (focusedApp, windowTitle)
        focusedPid = focusedApp.processIdentifier
    }
    #endif

    func refreshFocusedApp() {
        focusedApp = NSWorkspace.shared.frontmostApplication
        focusedPid = focusedApp?.processIdentifier ?? 0
        watchFocusedApp()
        refreshFocusedWindow()
    }

    func refreshFocusedWindow() {
        guard let read = Self.ownKeyWindow() ?? focusedApp.flatMap({ readFocusedWindow($0.processIdentifier) }) else {
            focusedWindowFrame = nil; focusedWindowTitle = nil; focusedWindowID = nil; focusedWindow = nil; focusedElement = nil
            return onFocusedWindow(nil)
        }
        // Set only when they change: the top bar reads the title.
        if read.window.subrole != focusedWindowSubrole { focusedWindowSubrole = read.window.subrole }
        if read.window.frame != focusedWindowFrame { focusedWindowFrame = read.window.frame }
        focusedWindowID = read.window.windowID
        if read.title != focusedWindowTitle { focusedWindowTitle = read.title }
        (focusedWindow, focusedElement) = (read.window, read.element)
        onFocusedWindow(read.window)
        // Another app's window: the window server's frame again once the app has surely committed it (FrameFollower)
        if read.element != nil, let id = read.window.windowID { follower.settle(id) }
    }

    /// One of borderedWindowNotifications from Pilot's window `window`, one the border may mark. The mouse dragging the
    /// focused one, the window server moves it and AppKit hears of it a few times a drag (Pilot's log: 1 to 8 moves in
    /// drags of 0.3 to 1 s, against 37 to 116 display frames), so the border followed those few and trailed the window
    /// (Sven, 2026-11-20): the drag follower reads the window server every frame instead, as for another app's window.
    /// A live resize is AppKit's own, its frame current, and keeps the AppKit read.
    private func ownWindowNote(_ name: Notification.Name, _ window: NSWindow?) {
        if name == NSWindow.willMoveNotification || name == NSWindow.didMoveNotification, let window, !window.inLiveResize,
           let id = CGWindowID(exactly: window.windowNumber), id == focusedWindowID, drag.moved(id) {
            ownDrag = true
            return follower.cancelSettle()
        }
        Task { @MainActor in self.refreshFocusedWindow() }
    }

    /// A window of the focused app moved or resized: the focused one's frame is read alone, any other re-reads the
    /// focused window whole, as the last read may be stale; a frame later at most (FrameFollower).
    /// While the mouse holds it, the drag follower reads it every display frame instead (DragFollower).
    func windowMoved(_ element: AXUIElement) {
        if drag.moved(focusedWindowID) {
            ownDrag = false
            return follower.cancelSettle()
        }
        follower.moved(focusedElement.map { CFEqual($0, element) } == true ? .frame(element) : .full)
        if let focusedWindowID { follower.settle(focusedWindowID) }
    }

    /// The release: one AX read puts the border on the window where the app says it landed, the settle reads where
    /// the window server draws it.
    /// Pilot's own window keeps the follower's last frame: AppKit may not have heard the last move yet, and its own
    /// didMove reads it once it has.
    private func settle() {
        if ownDrag { ownDrag = false } else { follower.moved(focusedElement.map { .frame($0) } ?? .full) }
        if let focusedWindowID { follower.settle(focusedWindowID) }
    }

    /// The moved window's frame, read off the main thread; dropped when focus went to another window meanwhile, and
    /// when the read failed: a closed window re-reads on its destroyed notification, and a hung app must not be asked
    /// eight more times on the key tap's thread.
    private func frameLanded(_ element: AXUIElement, _ frame: CGRect?) {
        guard let focusedElement, CFEqual(focusedElement, element) else { return }
        followed(frame)
    }

    /// Where the window server draws the focused window once its reads stopped (FrameFollower.settle): the border
    /// goes there, comes back for a window drawn at last (just opened), and goes for one drawn nowhere (another Space).
    private func settled(_ id: CGWindowID, _ frame: CGRect?) {
        guard focusedWindowID == id, var window = focusedWindow else { return }
        let drawn = (frame: frame ?? window.frame, on: frame != nil)
        guard drawn.frame != window.frame || drawn.on != window.drawn else { return }
        (window.frame, window.drawn) = drawn
        focusedWindow = window
        focusedWindowFrame = window.frame
        onFocusedWindow(window)
    }

    /// The focused window's new frame from a move: the border follows it.
    private func followed(_ frame: CGRect?) {
        guard var window = focusedWindow, let frame, frame != window.frame else { return }
        window.frame = frame
        focusedWindow = window
        focusedWindowFrame = frame
        onFocusedWindow(window)
    }

    /// The tiler finished writing these windows' frames (TilerFrames): the focused one is re-read, as AX skipped its
    /// glide and its last move can race the gliding mark. With no window server number to match, any write re-reads.
    /// The read's settle reads catch an app that settles its own frame after the write (one that cannot take its tile,
    /// or draws it late) while the gliding mark still dropped its AX moves (live bug 2026-11-16).
    func tilerLanded(_ ids: Set<UInt32>) {
        guard focusedApp != nil, focusedWindowID.map(ids.contains) ?? true else { return }
        refreshFocusedWindow()
    }


    /// Pilot's key window when the border marks it (BorderedWindow): a non-activating panel such as the capture editor
    /// takes the keys while another app stays in front, so AX would name that app's window (P32). `marked: false` takes
    /// any key window, for when Pilot itself is in front, read as AX would: a sheet's or child's window is its parent, and the
    /// subrole and full screen are the window's own, so a dialog, alert or the launcher is never ringed or blurred.
    static func ownKeyWindow(marked: Bool = true) -> FocusedWindowRead? {
        guard let key = NSApp?.keyWindow, !marked || key is BorderedWindow else { return nil }
        return ownWindow(marked ? key : key.sheetParent ?? key.parent ?? key, marked: marked)
    }

    /// One of Pilot's windows read from AppKit, as `ownKeyWindow` reads the key one.
    static func ownWindow(_ w: NSWindow, marked: Bool) -> FocusedWindowRead? {
        guard w.isVisible, let id = CGWindowID(exactly: w.windowNumber) else { return nil }
        return (w.title, WindowBorder.Window(frame: WindowGeometry.flip(w.frame, primaryHeight: Screens.primaryHeight),
                                             subrole: marked ? "AXStandardWindow" : w.accessibilitySubrole()?.rawValue,
                                             fullScreen: !marked && w.styleMask.contains(.fullScreen), minimised: w.isMiniaturized, windowID: id), nil)
    }

    /// The focused window of app `pid` through Accessibility, at the frame the window server draws it (live bug
    /// 2026-11-16: AX had Photo Booth at its tile while it was drawn off it, and the border ringed empty space): its own
    /// number's frame, or the app's frontmost drawn window when that number draws nothing (WindowBorder.asDrawn); not
    /// drawn when the app draws none (just opened, or on another Space). Pilot's own window keeps AppKit's frame:
    /// the window server takes a moved window's frame a run loop turn later, when AppKit commits it, and the read a
    /// move sets off came first, so the border stayed where the window had been (tester bug 9, 2026-11-19).
    static func drawnFocusedWindow(_ pid: pid_t, read focused: @MainActor (pid_t) -> FocusedWindowRead? = axFocusedWindow) -> FocusedWindowRead? {
        guard var read = focused(pid) else { return nil }
        guard pid != getpid(), let id = read.window.windowID, !read.window.minimised, !read.window.fullScreen else { return read }
        let drawn = DragFollower.drawnBounds(of: id)
        let front = drawn != nil ? nil : normal(onScreen(), skipping: []).first { $0.pid == pid }.map { (id: $0.id, frame: $0.frame) }
        read.window = WindowBorder.asDrawn(read.window, drawn: drawn, front: front)
        return read
    }

    /// The focused window of app `pid` through Accessibility; nil when it has none. Pilot's own is read from AppKit with
    /// no element, so no Accessibility ask, here or in FrameFollower's reads off the main thread, reaches its own
    /// process: there AppKit answers on the asking thread and deadlocks against SwiftUI (T59).
    static func axFocusedWindow(_ pid: pid_t) -> FocusedWindowRead? {
        guard pid != getpid() else { return ownKeyWindow(marked: false) }
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win else { return nil }
        let w = win as! AXUIElement
        var pos: AnyObject?, size: AnyObject?, title: AnyObject?, subrole: AnyObject?
        var p = CGPoint.zero, s = CGSize.zero
        AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subrole)
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size)
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
        if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
        let ax = AXWindow(element: w, pid: pid)
        return (title as? String, WindowBorder.Window(frame: CGRect(origin: p, size: s), subrole: subrole as? String,
                                                      fullScreen: ax.isFullScreen, minimised: ax.isMinimised, windowID: ax.windowID), w)
    }

    private func watchFocusedApp() {
        let pid = focusedPid
        // Never Pilot's own process (T59): its windows report through AppKit (borderedWindowNotifications).
        guard pid != 0, pid != getpid(), axObservers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let added = Self.axNotifications.map { AXObserverAddNotification(observer, appEl, $0 as CFString, me) }
        // An app still launching, or hung, may refuse: kept only once it answered, so its next activation tries again
        guard [.success, .notificationAlreadyRegistered].contains(added[0]) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObservers[pid] = observer
    }

    /// A quit app's observer leaves the run loop.
    private func forgetObserver(_ pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Only the focused app's observer re-reads the focused window, as when it had the one observer.
    fileprivate func isFocused(_ observer: ObjectIdentifier) -> Bool { axObservers[focusedPid].map(ObjectIdentifier.init) == observer }

    // MARK: desktops

    /// Reads the Spaces layout the Dock persists in com.apple.spaces. Pilot numbers desktops per monitor.
    func refreshDesktops() {
        CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
        guard let config = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString) as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else { desktopPerDisplay = [:]; return }
        var result: [String: (index: Int, count: Int)] = [:]
        for m in monitors {
            guard let display = m["Display Identifier"] as? String,
                  let spaces = m["Spaces"] as? [[String: Any]],
                  let current = m["Current Space"] as? [String: Any] else { continue }
            let desktops = spaces.filter { ($0["type"] as? Int) == 0 }   // type 0: a user desktop, not a fullscreen app
            let ids = desktops.compactMap { $0["ManagedSpaceID"] as? Int }
            let index = (current["ManagedSpaceID"] as? Int).flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result[display] = (index, ids.count)
        }
        desktopPerDisplay = result
    }
}

private let axCallback: AXObserverCallback = { observer, element, notification, refcon in
    guard let refcon else { return }
    let observers = Unmanaged<EngineObservers>.fromOpaque(refcon).takeUnretainedValue()
    let fired = ObjectIdentifier(observer)
    // Only the focused app's events count; asked first, since every app once in front keeps its observer
    guard MainActor.assumeIsolated({ observers.isFocused(fired) }) else { return }
    guard [kAXWindowMovedNotification, kAXWindowResizedNotification].contains(notification as String) else {
        return MainActor.assumeIsolated { observers.refreshFocusedWindow() }
    }
    // A window gliding to its tile moves every frame: the border follows when it lands (card agent-bo-95423033)
    if tilerIsGliding(element) { return }
    // A drag moves it a hundred times a second: never an AX read here, on the key tap's thread. The callback runs on
    // the main run loop, so the element never leaves it.
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated { observers.windowMoved(element) }
}
