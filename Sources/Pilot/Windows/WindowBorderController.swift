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

    init(surface: any WindowBorderSurface = WindowBorderPanel(), look: Look = .shared,
         screens: @escaping () -> [CGRect] = { Screens.frames }, primaryHeight: @escaping () -> CGFloat = { Screens.primaryHeight }) {
        self.surface = surface; self.look = look; self.screens = screens; self.primaryHeight = primaryHeight
    }

    func update(_ window: WindowBorder.Window?) {
        self.window = window
        refresh()
    }

    /// Off or with no window, the screens are not read at all; WindowBorder.frame decides the rest.
    func refresh() {
        guard look.windowBorder, let window, let frame = WindowBorder.frame(for: window, on: look.windowBorder, width: look.windowBorderWidth,
                                                                         screens: screens(), primaryHeight: primaryHeight()) else { return surface.hide() }
        surface.show(frame: frame, width: look.windowBorderWidth, color: look.windowBorderColour.resolved(look.theme.accent), above: window.windowID)
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
        if window.frame != frame { window.setFrame(frame, display: false) }
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

    func hide() { if window.isVisible { window.orderOut(nil) } }
}
