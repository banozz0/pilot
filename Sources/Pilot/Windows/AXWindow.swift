import AppKit
import ApplicationServices
import OSLog
import PilotCore
import PilotTilerPrivateApi

let wlog = Logger(subsystem: "dev.banozz.pilot", category: "windows")

/// One window through the Accessibility API. Frames are AX coordinates: top-left origin, y downwards.
@MainActor
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var win: AnyObject?
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success, let win else { return nil }
        let w = AXWindow(element: win as! AXUIElement, pid: app.processIdentifier)
        guard w.isStandard else { wlog.debug("focused window is \(w.subrole ?? "?", privacy: .public), not a standard window; skipped"); return nil }
        return w
    }

    /// The window server's number for this window (Defocus orders its overlay below it), through the private
    /// _AXUIElementGetWindow every tiler uses (declared in PilotTilerPrivateApi); nil when it fails.
    var windowID: CGWindowID? {
        var id = CGWindowID()
        return _AXUIElementGetWindow(element, &id) == .success && id != kCGNullWindowID ? id : nil
    }

    /// The app's windows, front to back.
    static func windows(of pid: pid_t) -> [AXWindow] {
        var list: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &list) == .success,
              let els = list as? [AXUIElement] else { return [] }
        return els.map { AXWindow(element: $0, pid: pid) }.filter(\.isStandard)
    }

    var subrole: String? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &v)
        return v as? String
    }

    /// A window a user would call a window: not Finder's desktop (no subrole, no close button), not a sheet
    /// or a floating panel. A window with no subrole but a close button gets the benefit of the doubt.
    var isStandard: Bool {
        guard let subrole else { return hasCloseButton }
        return subrole == kAXStandardWindowSubrole
    }

    var hasCloseButton: Bool {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &v) == .success && v != nil
    }

    /// The AX window behind an on-screen window record: same app, same frame.
    static func matching(_ info: WindowInfo) -> AXWindow? {
        windows(of: info.pid).first { w in
            guard let f = w.frame else { return false }
            return abs(f.minX - info.frame.minX) < 2 && abs(f.minY - info.frame.minY) < 2
                && abs(f.width - info.frame.width) < 2 && abs(f.height - info.frame.height) < 2
        }
    }

    var frame: CGRect? {
        var pos: AnyObject?, size: AnyObject?
        var p = CGPoint.zero, s = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Position, size, position again: apps that clamp the size to the old position settle on the second pass.
    func setFrame(_ r: CGRect) { Self.write(element, origin: r.origin, size: r.size) }

    /// The writes themselves, on any thread: a drag writes off the main thread (MouseDragTap).
    nonisolated static func write(_ element: AXUIElement, origin: CGPoint, size: CGSize?) {
        var origin = origin
        guard let position = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        guard var size, let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    }

    var isFullScreen: Bool {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &v)
        return (v as? Bool) ?? false
    }

    func setFullScreen(_ on: Bool) {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func minimise() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    var isMinimised: Bool {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &v)
        return (v as? Bool) ?? false
    }

    /// Presses the close button; the app decides what closing means (a document may ask to save).
    @discardableResult
    func close() -> Bool {
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success, let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Brings the window to the front and its app with it.
    func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

/// Screens in AX coordinates.
@MainActor
enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Each screen's top bar height by its name, while the bar shows there (TopBarWindows).
    static var bars: [String: Double] = [:]

    /// Every screen's visible frame (minus menu bar, Pilot's top bar and Dock), in AX coordinates, in NSScreen order.
    static var visibleFrames: [CGRect] {
        NSScreen.screens.map { screen in
            TopBarGeometry.belowBar(WindowGeometry.flip(screen.visibleFrame, primaryHeight: primaryHeight),
                                    screen: WindowGeometry.flip(screen.frame, primaryHeight: primaryHeight), bar: bars[screen.localizedName])
        }
    }

    /// Every screen's whole frame, in AX coordinates, in NSScreen order.
    static var frames: [CGRect] {
        NSScreen.screens.map { WindowGeometry.flip($0.frame, primaryHeight: primaryHeight) }
    }

    static func visibleFrame(containing frame: CGRect) -> CGRect { visibleFrames[index(containing: frame)] }

    /// The index of the screen holding the focused window, else the first. Not NSScreen.main: that follows Pilot's
    /// own key window, which a menu-bar app rarely has.
    static var mainIndex: Int { AXWindow.focused()?.frame.flatMap(holding) ?? 0 }

    /// The screen holding the focused window, as AppKit has it, for placing Pilot's own panels.
    static var focusedScreen: NSScreen? { NSScreen.screens.isEmpty ? nil : NSScreen.screens[mainIndex] }

    /// The screen holding the focused window, else the pointer's: where a bar drop opened by key hangs.
    static var focusedOrPointerScreen: NSScreen? {
        if let i = AXWindow.focused()?.frame.flatMap(holding) { return NSScreen.screens[i] }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.screens.first
    }

    /// The index of the screen holding a window's centre, else the main one.
    static func index(containing frame: CGRect) -> Int { holding(frame) ?? mainIndex }

    private static func holding(_ frame: CGRect) -> Int? { WindowGeometry.screen(holding: frame, among: frames) }
}
