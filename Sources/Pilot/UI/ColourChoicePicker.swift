import AppKit
import PilotCore
import SwiftUI

/// Theme or Custom, and a colour well while Custom (Sven, 2026-10-10): the one picker for a ColourChoice, the top bar's
/// colour and the focused window's border.
struct ColourChoicePicker: View {
    @Binding var choice: ColourChoice
    /// The theme's colour: what Theme draws and where the well starts once Custom is picked.
    let theme: UInt32
    /// What VoiceOver calls it.
    let label: String

    var body: some View {
        // The well beside the two segments, or under them where a row is short of room.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { segments; well }
            VStack(alignment: .leading, spacing: 6) { segments; well }
        }
    }

    private var segments: some View {
        Segments(selection: Binding(get: { choice != .theme }, set: { choice = $0 ? .custom(choice.resolved(theme)) : .theme }),
                 options: [(false, "Theme"), (true, "Custom")], label: label)
    }

    @ViewBuilder private var well: some View {
        if case .custom(let rgb) = choice {
            ColorPicker(label, selection: Binding(get: { Color(Paint(rgb)) }, set: { choice = .custom($0.rgb) }), supportsOpacity: false)
                .labelsHidden()
                .onAppear { ColourPanelCloser.shared.wellAppeared() }
                .onHover { if $0 { ColourPanelCloser.shared.pointerOnWell() } }
                .onDisappear { ColourPanelCloser.shared.wellDisappeared() }
        }
    }
}

/// The Colors panel a well opens closes on Esc and on a click outside it, in Pilot or another app (Sven, 2026-10-17):
/// macOS leaves it up. The colour picked so far stays. It watches the panel while a well is on screen or the panel is up, and holds
/// event monitors only while the panel is up. `NSColorPanel.shared` is Pilot's own; another app's panel is never touched.
/// Each time it comes up it opens beside the swatch clicked, on screen: AppKit put it back at its saved frame, the
/// screen's bottom-left corner (Sven, 2026-10-29). The pointer coming onto a well moves the hidden panel there first, so it
/// shows in place; placing it once shown left a frame at the corner (Sven, 2026-10-29). The tiler never lays it out: a
/// panel is a popup (OwnApp.engineWindowType).
@MainActor final class ColourPanelCloser {
    static let shared = ColourPanelCloser()

    enum Input: Equatable { case key(UInt16), click(inPanel: Bool, onWell: Bool) }

    /// Esc closes; a click closes unless it lands in the panel, or on a well, which toggles the panel itself.
    nonisolated static func closes(_ input: Input) -> Bool {
        switch input {
        case .key(let code): code == 53
        case .click(let inPanel, let onWell): !inPanel && !onWell
        }
    }

    /// The panel's bottom-left corner beside `anchor` (the click on the swatch): right of it, or left where the right is
    /// short of room, centred on it, all of it inside `visible`. AppKit's coordinates: bottom-left origin, y up.
    nonisolated static func origin(of size: NSSize, beside anchor: NSPoint, in visible: NSRect) -> NSPoint {
        let gap: CGFloat = 16
        let right = anchor.x + gap
        let x = right + size.width <= visible.maxX ? right : anchor.x - gap - size.width
        let y = anchor.y - size.height / 2
        return NSPoint(x: min(max(x, visible.minX), visible.maxX - size.width),
                       y: min(max(y, visible.minY), visible.maxY - size.height))
    }

    private var wells = 0
    /// The hidden panel already stands beside the well the pointer is on; a well opened from the keyboard is placed once shown.
    private var placed = false
    private var shown: NSObjectProtocol?
    private var monitors: [Any] = []

    func wellAppeared() {
        wells += 1
        guard shown == nil else { return }
        shown = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
            guard let panel = note.object as? NSColorPanel else { return }
            MainActor.assumeIsolated { ColourPanelCloser.shared.panelChanged(panel) }
        }
        if NSColorPanel.sharedColorPanelExists { panelChanged(.shared) }
    }

    /// The pointer on a well: a click there opens the panel, so the hidden panel moves beside it now. An open one stays put.
    func pointerOnWell() {
        let panel = NSColorPanel.shared
        guard !panel.isVisible else { return }
        place(panel)
        placed = true
    }

    private func place(_ panel: NSColorPanel) {
        let anchor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? panel.screen ?? NSScreen.main
        else { return }
        panel.setFrameOrigin(Self.origin(of: panel.frame.size, beside: anchor, in: screen.visibleFrame))
    }

    func wellDisappeared() {
        wells = max(0, wells - 1)
        settle()
    }

    /// The panel watch ends once no well is on screen and the panel is down; an open panel keeps its closer.
    private func settle() {
        guard wells == 0, monitors.isEmpty, let shown else { return }
        NotificationCenter.default.removeObserver(shown)
        self.shown = nil
    }

    private func panelChanged(_ panel: NSColorPanel) {
        if panel.isVisible { arm(panel) } else { disarm() }
    }

    private func arm(_ panel: NSColorPanel) {
        guard monitors.isEmpty else { return }
        if !placed { place(panel) }
        let close = { [weak panel] in panel?.close(); ColourPanelCloser.shared.disarm() }
        if let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard Self.closes(.key(event.keyCode)) else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }) { monitors.append(esc) }
        if let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak panel] event in
            MainActor.assumeIsolated {
                let hit = event.window?.contentView?.hitTest(event.locationInWindow)
                let onWell = sequence(first: hit, next: { $0?.superview }).contains { $0 is NSColorWell }
                if Self.closes(.click(inPanel: event.window === panel, onWell: onWell)) { close() }
            }
            return event
        }) { monitors.append(inside) }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { close() }
        }) { monitors.append(outside) }
    }

    private func disarm() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        placed = false
        settle()
    }
}
