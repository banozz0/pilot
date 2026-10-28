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
    /// An app came to the front (bind hints listen here, card agent-bo-95422934).
    var onActivate: (NSRunningApplication) -> Void = { _ in }
    /// Each read of the focused window: focus, move, resize, the tiler's writes (the window border follows it, card agent-bo-95422950).
    var onFocusedWindow: (WindowBorder.Window?) -> Void = { _ in }
    /// The focused window's title, frame and AX element as one app reports them; tests pass a fake.
    @ObservationIgnored var readFocusedWindow: @MainActor (pid_t) -> FocusedWindowRead? = EngineObservers.axFocusedWindow
    /// The last read's window server number: the tiler's writes to other windows are not re-read.
    @ObservationIgnored private var focusedWindowID: CGWindowID?
    /// The last read's window and its AX element: a move or resize of that element reads its frame alone.
    @ObservationIgnored private var focusedWindow: WindowBorder.Window?
    @ObservationIgnored private var focusedElement: AXUIElement?
    /// Moves and resizes, read at most once per display frame, off the main thread.
    @ObservationIgnored let follower: FrameFollower
    /// The focused window while the mouse holds it: its window server bounds every display frame.
    @ObservationIgnored let drag: DragFollower

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
    static let borderedWindowNotifications = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didMoveNotification, NSWindow.didResizeNotification, borderedWindowRaised]

    typealias FocusedWindowRead = (title: String?, window: WindowBorder.Window, element: AXUIElement?)

    init(tiler: TilerService = TilerService(), follower: FrameFollower = FrameFollower(), drag: DragFollower = DragFollower()) {
        self.tiler = tiler
        self.follower = follower
        self.drag = drag
        follower.landed = { [weak self] in self?.frameLanded($0, $1) }
        follower.full = { [weak self] in self?.refreshFocusedWindow() }
        drag.landed = { [weak self] id, frame in
            guard let self, focusedWindowID == id else { return }
            followed(frame)
        }
        drag.ended = { [weak self] in self?.settle() }
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.refreshFocusedApp()
                if let app { self?.onActivate(app) }
            }
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
        // Every Pilot window posts these, the border's own panel each drag frame: only a marked one gets a Task.
        for name in Self.borderedWindowNotifications {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard note.object is BorderedWindow else { return }
                Task { @MainActor in self?.refreshFocusedWindow() }
            })
        }
        tokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDesktops() }
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
    }

    /// A window of the focused app moved or resized: the focused one's frame is read alone, any other re-reads the
    /// focused window whole, as the last read may be stale; a frame later at most (FrameFollower).
    /// While the mouse holds it, the drag follower reads it every display frame instead (DragFollower).
    func windowMoved(_ element: AXUIElement) {
        if drag.moved(focusedWindowID) { return }
        follower.moved(focusedElement.map { CFEqual($0, element) } == true ? .frame(element) : .full)
    }

    /// The release: one AX read puts the border on the window where the app says it landed.
    private func settle() { follower.moved(focusedElement.map { .frame($0) } ?? .full) }

    /// The moved window's frame, read off the main thread; dropped when focus went to another window meanwhile, and
    /// when the read failed: a closed window re-reads on its destroyed notification, and a hung app must not be asked
    /// eight more times on the key tap's thread.
    private func frameLanded(_ element: AXUIElement, _ frame: CGRect?) {
        guard let focusedElement, CFEqual(focusedElement, element) else { return }
        followed(frame)
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
    func tilerLanded(_ ids: Set<UInt32>) {
        guard focusedApp != nil, focusedWindowID.map(ids.contains) ?? true else { return }
        refreshFocusedWindow()
    }

    /// Pilot's key window when the border marks it (BorderedWindow): a non-activating panel such as the capture editor
    /// takes the keys while another app stays in front, so AX would name that app's window (P32).
    static func ownKeyWindow() -> FocusedWindowRead? {
        guard let w = NSApp?.keyWindow, w is BorderedWindow, w.isVisible, let id = CGWindowID(exactly: w.windowNumber) else { return nil }
        return (w.title, WindowBorder.Window(frame: WindowGeometry.flip(w.frame, primaryHeight: Screens.primaryHeight), subrole: "AXStandardWindow",
                                             fullScreen: false, minimised: w.isMiniaturized, windowID: id), nil)
    }

    /// The focused window of app `pid` through Accessibility; nil when it has none.
    static func axFocusedWindow(_ pid: pid_t) -> FocusedWindowRead? {
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
        guard pid != 0, axObservers[pid] == nil else { return }
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
