import AppKit
import Observation
import PilotCore
import SwiftUI

/// Where the focused window's border is drawn; the real one is a panel, tests a fake.
@MainActor
protocol WindowBorderSurface: AnyObject {
    /// `frame` in AppKit coordinates, `color` 0xRRGGBB: the theme's accent or the picked colour, stacked directly above
    /// window `above`, the focused one.
    func show(frame: CGRect, width: Int, color: UInt32, above: CGWindowID?)
    func hide()
    /// The line lent to a drag of window `id`, which moves it from its own thread (DragFollower): its window server
    /// number while it is shown above that window and can be moved so (WindowServerMove). Nil by default.
    func lend(above id: CGWindowID) -> UInt32?
    /// The drag is over or cut short: where the window server has the line is no longer known here.
    func giveBack()
}

extension WindowBorderSurface {
    func lend(above id: CGWindowID) -> UInt32? { nil }
    func giveBack() {}
}

/// The focused-window border (card agent-bo-95422950, story 125): EngineObservers hands it each read of the focused
/// window (focus, move, resize), Look's switch, width and colour (the accent, or the one picked) redraw it; PilotCore's WindowBorder decides.
@MainActor
final class WindowBorderController {
    private let surface: any WindowBorderSurface
    private let look: Look
    private let screens: () -> [CGRect]
    private let primaryHeight: () -> CGFloat
    private var window: WindowBorder.Window?
    /// The window whose drag has the line (DragFollower), and how to take it back.
    private var lease: (id: CGWindowID, revoke: () -> Void)?

    init(surface: any WindowBorderSurface = WindowBorderPanel(), look: Look = .shared,
         screens: @escaping () -> [CGRect] = { Screens.frames }, primaryHeight: @escaping () -> CGFloat = { Screens.primaryHeight }) {
        self.surface = surface; self.look = look; self.screens = screens; self.primaryHeight = primaryHeight
    }

    func update(_ window: WindowBorder.Window?) {
        self.window = window
        refresh()
    }

    /// Off or with no window, the screens are not read at all; WindowBorder.frame decides the rest. While a drag has the
    /// line, its window's reads leave it to the drag; any other window, or none, takes it back first.
    func refresh() {
        if let lease {
            if look.windowBorder, lease.id == window?.windowID { return }
            self.lease = nil
            lease.revoke()
            surface.giveBack()
        }
        guard look.windowBorder, let window, let frame = WindowBorder.frame(for: window, on: look.windowBorder, width: look.windowBorderWidth,
                                                                         screens: screens(), primaryHeight: primaryHeight()) else { return surface.hide() }
        surface.show(frame: frame, width: look.windowBorderWidth, color: look.windowBorderColour.resolved(look.theme.accent), above: window.windowID)
    }

    /// The border lent to a drag of window `id`, and how far its corner sits out from the window's: nil when it is off,
    /// shown for another window, or cannot be moved off the main thread. `revoke` stops the drag moving it.
    func lend(_ id: CGWindowID, revoke: @escaping () -> Void) -> DragFollower.DragBorder? {
        guard look.windowBorder, let window, window.windowID == id,
              let frame = WindowBorder.frame(for: window, on: true, width: look.windowBorderWidth, screens: screens(), primaryHeight: primaryHeight()),
              let number = surface.lend(above: id) else { return nil }
        lease?.revoke()
        lease = (id, revoke)
        // WindowBorder.frame's own reach out from the window's corner, read back in window-server coordinates
        return (number, window.frame.minX - frame.minX)
    }

    /// The drag's end, or its resize: the line is the main thread's again, placed by the next update.
    func giveBack() {
        guard lease != nil else { return }
        lease = nil
        surface.giveBack()
    }

    /// Follows Look's settings from now on; the focused window arrives through `update`.
    func start() {
        withObservationTracking {
            _ = (look.windowBorder, look.windowBorderWidth, look.windowBorderColour, look.theme.accent)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.start()
            }
        }
    }
}

/// A borderless, see-through panel that clicks pass through, on every Space and out of the window cycle, holding a
/// rounded line in the accent just outside the window's edge. It sits directly above the focused window, at its level,
/// so a window stacked over that one (the capture editor over Ghostex) covers the line (P32), and it is ordered there
/// again on every read, so it comes over other windows with its own.
@MainActor
final class WindowBorderPanel: WindowBorderSurface {
    /// macOS 26's corner on a standard window, so the line hugs it.
    static let windowRadius: CGFloat = 16
    let window: NSPanel
    private let line = NSView()
    /// The last line drawn: AX sends a move or a destroyed menu many times over, and an unchanged line is left alone.
    private var drawn: (width: Int, color: UInt32)?
    /// The window the panel last framed, and the one it is stacked above: the same, once its layer was read.
    private var above: CGWindowID?
    private var stacked: CGWindowID?
    /// Where the window server has the panel after a move AppKit has not been told of yet (WindowServerMove), and
    /// AppKit's catch-up, due once the moves stop.
    private var placed: CGRect?
    private var sync: DispatchWorkItem?
    /// A drag moved the line from its own thread: neither `placed` nor AppKit's frame is where the window server has it.
    private var drifted = false
    /// How long after the last move AppKit's frame catches up: told at once, its commit lands a median 4.15 ms later,
    /// after the next 240 Hz move, and would pull the border back for a frame.
    static let syncAfter: TimeInterval = 0.1

    init() {
        window = Self.overlay()
        line.wantsLayer = true
        window.contentView = line
    }

    /// A borderless, see-through panel that clicks pass through, on every Space and out of the window cycle, drawn over
    /// another app's windows: the border's, and the drop zone's (DropZonePanel).
    static func overlay() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        // An NSPanel hides when its app deactivates, and Pilot is rarely active: an overlay must stay.
        window.hidesOnDeactivate = false
        return window
    }

    /// The corner of a line `width` wide drawn just outside a window's edge, so it hugs the window's own corner.
    static func radius(outside width: Int) -> CGFloat { windowRadius + CGFloat(width) }

    func show(frame: CGRect, width: Int, color: UInt32, above id: CGWindowID?) {
        if drawn?.width != width || drawn?.color != color {
            let layer = line.layer
            layer?.borderWidth = CGFloat(width)
            layer?.cornerRadius = Self.radius(outside: width)
            layer?.borderColor = NSColor(Color(hex: color)).cgColor
            drawn = (width, color)
        }
        place(frame)
        // Stacking never crosses levels, so the panel takes the window's own first, read once a window: the read is a
        // window-server call. With no window number, above every normal window, as before P32.
        if !window.isVisible || id != above {
            let layer = id.flatMap(DragFollower.layer(of:))
            (above, stacked) = (id, layer == nil ? nil : id)
            let level = layer.map(NSWindow.Level.init(rawValue:)) ?? .floating
            if window.level != level { window.level = level }
        }
        // Ordered again on every read, not only when focus moves: the window can come to the front again while it keeps
        // focus (an app's activation, a click on Pilot's editor), and a stacking kept from before left the line under
        // the windows it had just come over (Sven on build 76).
        if let stacked { window.order(.above, relativeTo: Int(stacked)) } else { window.orderFrontRegardless() }
    }

    /// A pending AppKit catch-up is dropped: it would put the line back where the drag found it, under the drag's moves.
    func lend(above id: CGWindowID) -> UInt32? {
        guard window.isVisible, above == id, WindowServerMove.available, let number = WindowServerMove.number(window.windowNumber) else { return nil }
        sync?.cancel()
        sync = nil
        return number
    }

    /// The next place moves the line whatever this side last had it at: the drag moved it meanwhile.
    func giveBack() {
        sync?.cancel()
        (sync, placed, drifted) = (nil, nil, true)
    }

    func hide() {
        syncAppKit()
        if window.isVisible { window.orderOut(nil) }
    }

    /// The panel at `frame`. A move of the shown panel goes to the window server at once (WindowServerMove): AppKit's
    /// setFrame reaches it at AppKit's next commit, a median 4.15 ms later, so a border fed the window's place in time
    /// still showed 1.3 frames behind a 240 Hz drag (move-lag). A resize, or the first show, is AppKit's.
    private func place(_ frame: CGRect) {
        let current = placed ?? window.frame
        guard drifted || current != frame else { return }
        drifted = false
        if window.isVisible, current.size == frame.size, WindowServerMove.move(window.windowNumber, to: frame) {
            placed = frame
            syncLater()
        } else {
            placed = nil
            window.setFrame(frame, display: false)
        }
    }

    private func syncLater() {
        sync?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.syncAppKit() } }
        sync = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.syncAfter, execute: item)
    }

    /// AppKit's frame where the window server already has the panel: no move on screen.
    private func syncAppKit() {
        sync?.cancel()
        sync = nil
        guard let frame = placed else { return }
        placed = nil
        window.setFrame(frame, display: false)
    }
}

/// A window's move straight to the window server, through SkyLight's CGSMoveWindow (private, looked up once by path,
/// as the cursor calls are): it is there when the call returns. False when the call is gone or refused: AppKit's setFrame then.
@MainActor
enum WindowServerMove {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Move = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32
    private nonisolated static let calls: (Connection, Move)? = {
        guard let connection = CursorCalls.symbol("CGSMainConnectionID"), let move = CursorCalls.symbol("CGSMoveWindow") else {
            wlog.error("border: CGSMoveWindow not found, moves go through AppKit")
            return nil
        }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(move, to: Move.self))
    }()

    nonisolated static var available: Bool { calls != nil }

    /// An NSWindow's number as the window server's id: nil while it has none.
    static func number(_ window: Int) -> UInt32? { UInt32(exactly: window).flatMap { $0 > 0 ? $0 : nil } }

    /// `frame` in AppKit coordinates; the window server takes its top-left corner, y down from the primary screen's top.
    static func move(_ window: Int, to frame: CGRect) -> Bool {
        guard let id = number(window) else { return false }
        return move(id, corner: WindowGeometry.flip(frame, primaryHeight: Screens.primaryHeight).origin)
    }

    /// Window `id`'s top-left corner to `corner`, window-server coordinates; from any thread (a drag's, DragFollower).
    nonisolated static func move(_ id: UInt32, corner: CGPoint) -> Bool {
        guard let (connection, move) = calls else { return false }
        var corner = corner
        return move(connection(), id, &corner) == 0
    }
}
