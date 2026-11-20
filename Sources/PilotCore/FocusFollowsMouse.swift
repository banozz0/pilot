import CoreGraphics
import Foundation

/// Focus follows mouse (Sven, 2026-11-20, Omarchy's Hyprland `follow_mouse = 1`): once the pointer rests over another
/// window, that window takes focus, as a click would give it, with no click. Which window, if any, is decided here from
/// what the pointer rests on; FocusFollowsMouseController gathers it, Pilot's tiler focuses. Frames and points are AX
/// coordinates (top-left origin), as CGEvent locations and the window server's list are.
public enum FocusFollowsMouse {
    /// How long the pointer must rest before focus moves, so a sweep across windows never flickers focus on the way.
    public static let settle: TimeInterval = 0.12
    /// The window server's level for menus (kCGPopUpMenuWindowLevel): one on screen means a menu is open.
    public static let menuLayer = 101
    /// A window showing less than this of itself on the pointer's screen, a strip's sliver or a window parked in a
    /// corner, never takes focus: focusing it would scroll the strip or bring a hidden window back.
    public static let minimumShown: CGFloat = 40

    /// One on-screen window, front to back as the window server lists them. `id` is its window number (the tiler's
    /// window id); `own` marks one of Pilot's panels, bars or menus, which never take focus this way; `lookThrough` one
    /// that takes no pointer: Pilot's click-through overlays (the border, Defocus, the cursor) and another app's
    /// whole-screen overlay with no Dock icon (an agent's cursor).
    public struct Listed: Sendable, Equatable {
        public let id: Int
        public let layer: Int
        public let alpha: Double
        public let frame: CGRect
        public let own: Bool
        public let lookThrough: Bool

        public init(id: Int, layer: Int, alpha: Double = 1, frame: CGRect, own: Bool = false, lookThrough: Bool = false) {
            self.id = id; self.layer = layer; self.alpha = alpha; self.frame = frame; self.own = own; self.lookThrough = lookThrough
        }
    }

    /// What holds focus where it is, whatever the pointer rests on.
    public struct Holds: Sendable, Equatable {
        /// A mouse button is down: a drag, a selection, a resize.
        public var buttons = false
        /// Pilot's key window is one of its panels: Hyper+Space, a note, a prompt; or one of its windows shows a sheet.
        public var pilotPanel = false
        /// The focused window shows a sheet (a save dialog).
        public var sheet = false

        public init(buttons: Bool = false, pilotPanel: Bool = false, sheet: Bool = false) {
            self.buttons = buttons; self.pilotPanel = pilotPanel; self.sheet = sheet
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Focus this window.
        case focus(Int)
        /// The pointer moved too lately: decide again this much later.
        case wait(TimeInterval)
        /// Nothing to do, and why.
        case stay(Reason)
    }

    public enum Reason: String, Sendable {
        case buttons, pilotPanel, sheet, menuOpen, notAWindow, sliver, focused
    }

    /// The window to focus with the pointer at `point`, last moved at `moved`, `now` (seconds on one clock), over
    /// `windows` front to back on `screens`, `focused` holding focus. The front window under the pointer counts, so a
    /// floating window under another takes focus only where it shows; a fullscreen one never does (it is alone on its Space). Nothing while a button is held, Pilot's panel or a
    /// sheet is up or a menu is open anywhere, nor over the menu bar, a top bar, a dock, the desktop or Pilot's own panels:
    /// the front window there is not another app's normal window.
    public static func decide(point: CGPoint, windows: [Listed], screens: [CGRect], focused: Int?, holds: Holds,
                              moved: TimeInterval, now: TimeInterval) -> Decision {
        if let left = left(moved: moved, now: now) { return .wait(left) }
        if holds.buttons { return .stay(.buttons) }
        if holds.pilotPanel { return .stay(.pilotPanel) }
        let seen = windows.filter { !$0.lookThrough && $0.alpha > 0 }
        if seen.contains(where: { $0.layer >= menuLayer && !screens.contains($0.frame) }) { return .stay(.menuOpen) }
        // The front window under the pointer, as a drag finds it: another app's normal window or Pilot's own laid-out one.
        guard let i = MouseDrag.hit(point, among: seen.map { ($0.layer, $0.alpha, $0.frame, $0.own) }, screens: screens) else {
            return .stay(.notAWindow)
        }
        let front = seen[i]
        let screen = screens.first { $0.contains(point) } ?? screens.first ?? .null
        let shown = front.frame.intersection(screen)
        guard shown.width >= minimumShown, shown.height >= minimumShown else { return .stay(.sliver) }
        if front.id == focused { return .stay(.focused) }
        if holds.sheet { return .stay(.sheet) }
        return .focus(front.id)
    }

    /// How much longer the pointer must rest, last moved at `moved`, `now`; nil once it has rested the settle.
    public static func left(moved: TimeInterval, now: TimeInterval) -> TimeInterval? {
        let rested = now - moved
        return rested < settle ? settle - rested : nil
    }
}
