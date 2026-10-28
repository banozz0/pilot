import AppKit
import PilotCore
import SwiftUI

/// Where the drop zone is drawn; the real one is a panel, tests a fake.
@MainActor
protocol DropZoneSurface: AnyObject {
    /// `frame` in AppKit coordinates, just below window `below` (the one being dragged), drawn in `theme`'s colours with
    /// an `edge` as wide as the focused window's border.
    func show(frame: CGRect, below: UInt32?, theme: PilotTheme, edge: Int)
    func hide()
}

/// The drop-zone preview (card agent-bo-95423032): while a tiled window is dragged, the own tiler hands it the frame the
/// window would land in (TilerDropZone), nil at the release; it is drawn in the theme's accent.
@MainActor
final class DropZone {
    private let surface: any DropZoneSurface
    private let look: Look

    init(surface: any DropZoneSurface = DropZonePanel(), look: Look = .shared) {
        self.surface = surface; self.look = look
    }

    func update(_ frame: CGRect?, below: UInt32?) {
        guard let frame else { return surface.hide() }
        surface.show(frame: frame, below: below, theme: look.theme, edge: look.windowBorderWidth)
    }
}

/// An overlay panel (WindowBorderPanel.overlay) ordered just below the dragged window so it never covers it; a panel, so
/// the tiler never lays it out. Its look is all layer properties, set once per theme: a move only sets the frame, never
/// redraws; it fades in and out, the frame never animates.
@MainActor
final class DropZonePanel: DropZoneSurface {
    /// The fade in and out: short enough for a drag, long enough to cover the window landing a few frames after the release.
    static let fade: CFTimeInterval = 0.12
    let window: NSPanel
    private let zone = NSView()
    private var drawn: (theme: PilotTheme, edge: Int)?
    /// Between show and hide, the fade-out included; a show during the fade-out turns it back.
    private var shown = false

    init() {
        window = WindowBorderPanel.overlay()
        zone.wantsLayer = true
        zone.alphaValue = 0
        window.contentView = zone
    }

    /// The panel round a window landing at `landing`: its edge just outside, where the focus border will be drawn.
    static func frame(around landing: CGRect, edge: Int) -> CGRect { landing.insetBy(dx: -CGFloat(edge), dy: -CGFloat(edge)) }

    /// The landing slot in the focus border's own language: the accent line, full strength, exactly where the border
    /// appears once the window lands, round the window's corner, and the accent at a fifth over the tile under it.
    static func paint(_ layer: CALayer, _ theme: PilotTheme, edge: Int) {
        let accent = NSColor(Color(hex: theme.accent))
        layer.backgroundColor = accent.withAlphaComponent(0.2).cgColor
        layer.borderColor = accent.cgColor
        layer.borderWidth = CGFloat(edge)
        layer.cornerRadius = WindowBorderPanel.radius(outside: edge)
    }

    func show(frame: CGRect, below: UInt32?, theme: PilotTheme, edge: Int) {
        if drawn?.theme != theme || drawn?.edge != edge, let layer = zone.layer {
            Self.paint(layer, theme, edge: edge)
            drawn = (theme, edge)
        }
        let frame = Self.frame(around: frame, edge: edge)
        if window.frame != frame { window.setFrame(frame, display: false) }
        if let below { window.order(.below, relativeTo: Int(below)) } else if !window.isVisible { window.orderFrontRegardless() }
        if !shown { shown = true; fade(to: 1) }
    }

    func hide() {
        guard shown else { return }
        shown = false
        fade(to: 0) { [weak self] in if self?.shown == false { self?.window.orderOut(nil) } }
    }

    /// The zone's opacity to `alpha` from wherever it is now (a layer animation); `done` runs once the fade ends.
    private func fade(to alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            zone.animator().alphaValue = alpha
        } completionHandler: { done?() }
    }
}
