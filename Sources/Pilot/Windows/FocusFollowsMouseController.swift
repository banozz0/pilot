import AppKit
import ApplicationServices
import PilotCore

/// Focus follows mouse (Tiling › Mouse and motion, `tiling.focusFollowsMouse`; Sven, 2026-11-20): the window the pointer
/// rests on takes focus without a click, and the border goes with it (EngineObservers reads the new focus as it does a
/// click's). FocusFollowsMouse decides; the tiler focuses (InProcessTiler.focusFollowingMouse), as a click would: the
/// window is raised and its app brought forward, a floating one too, so what has focus is the window in front. Nothing
/// is posted and the pointer never moves (ADR 0001).
///
/// Mouse moves come from a listen-only session tap, only while armed: it sees the moves over Pilot's own windows too,
/// which an NSEvent global monitor never gets, and hands each over without making an NSEvent. A move costs one stored
/// time and point; the window server's list is read once the pointer rests, not per move. A still pointer sends no
/// events, so nothing runs.
@MainActor
final class FocusFollowsMouseController {
    private let tap = ListenOnlyTap(mask: CGEventMask(1) << CGEventType.mouseMoved.rawValue)
    private let tiler: TilerService
    private let focusedWindow: @MainActor () -> CGWindowID?
    private var armed = false
    /// The last move: its time (uptime) and point (AX coordinates).
    private var movedAt: TimeInterval = 0
    private var point = CGPoint.zero
    /// The rest's check, when one is pending; a move while it waits only moves `movedAt`.
    private var pending: DispatchWorkItem?
    /// The focus under way: a rest while it runs is checked again a settle later.
    private var focusing: Task<Void, Never>?

    init(tiler: TilerService, focusedWindow: @escaping @MainActor () -> CGWindowID?) {
        self.tiler = tiler
        self.focusedWindow = focusedWindow
    }

    /// On with the setting while Pilot's tiler is wanted; off, the tap goes and no move reaches Pilot.
    func arm(_ on: Bool) {
        guard on != armed else { return }
        if on {
            armed = tap.start { [unowned self] event in moved(to: event.location) }
            if !armed { wlog.error("focus follows mouse: mouse tap not created") }
        } else {
            tap.stop()
            pending?.cancel(); pending = nil
            armed = false
        }
        wlog.notice("focus follows mouse \(self.armed ? "on" : "off", privacy: .public)")
    }

    private func moved(to point: CGPoint) {
        self.point = point
        movedAt = ProcessInfo.processInfo.systemUptime
        if pending == nil { check(after: FocusFollowsMouse.settle) }
    }

    private func check(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.rested() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rested() {
        pending = nil
        guard armed, tiler.engine.isRunning else { return }
        if focusing != nil { return check(after: FocusFollowsMouse.settle) }
        // Still moving: wait out the rest of the settle before reading the window server's list.
        if let left = FocusFollowsMouse.left(moved: movedAt, now: ProcessInfo.processInfo.systemUptime) { return check(after: left) }
        let at = movedAt
        guard case .focus(let id) = decide(sheet: false) else { return }
        // The sheet is asked of the front app off the main thread (it can hang), only now a window would take focus;
        // the list is read again after, as the windows may have moved while it answered.
        focusing = Task { [weak self] in
            let sheet = await Task.detached { Self.frontShowsSheet() }.value
            guard let self else { return }
            defer { focusing = nil }
            guard armed, movedAt == at, case .focus(id) = decide(sheet: sheet) else { return }
            do {
                let took = try await tiler.engine.focusFollowingMouse(id)
                wlog.debug("focus follows mouse: window \(id) \(took ? "focused" : "refused", privacy: .public)")
            } catch {
                wlog.debug("focus follows mouse: window \(id) not focused: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The window server's list is read only when no button or panel holds focus already.
    private func decide(sheet: Bool) -> FocusFollowsMouse.Decision {
        let key = NSApp.keyWindow
        let holds = FocusFollowsMouse.Holds(buttons: NSEvent.pressedMouseButtons != 0,
                                            pilotPanel: key is NSPanel || key?.attachedSheet != nil || key?.sheetParent != nil, sheet: sheet)
        let screens = Screens.frames
        return FocusFollowsMouse.decide(point: point, windows: holds.buttons || holds.pilotPanel ? [] : listed(screens),
                                        screens: screens, focused: focusedWindow().map(Int.init), holds: holds, moved: movedAt,
                                        now: ProcessInfo.processInfo.systemUptime)
    }

    /// On-screen windows front to back: Pilot's laid-out windows take focus as any app's, its panels and bars do not; its
    /// click-through overlays and another app's whole-screen overlay are looked through.
    private func listed(_ screens: [CGRect]) -> [FocusFollowsMouse.Listed] {
        let me = getpid(), clickThrough = EngineObservers.clickThrough(), focusable = MouseDragTap.draggableOwn()
        return EngineObservers.onScreen().map { w in
            FocusFollowsMouse.Listed(id: Int(w.info.id), layer: w.layer, alpha: w.alpha, frame: w.info.frame,
                                     own: w.info.pid == me && !focusable.contains(w.info.id),
                                     lookThrough: clickThrough.contains(w.info.id) || (screens.contains(w.info.frame) && EngineObservers.isOverlayApp(w.info.pid)))
        }
    }

    /// The front app's focused window shows a sheet (a save or print dialog). Pilot's own sheets are its key window's,
    /// read on the main thread; Pilot is never asked through Accessibility (T59).
    nonisolated private static func frontShowsSheet() -> Bool {
        var children: CFTypeRef?
        guard let window = AXFront.focusedWindow(),
              AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return false }
        return children.contains { child in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success && role as? String == kAXSheetRole
        }
    }
}
