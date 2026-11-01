import AppKit
import PilotCore
import SwiftUI

/// The shelf's panels: one per screen showing a Stage workspace, in the room the tiler keeps at its left edge
/// (PilotBlock.shelfWidth), the screen's full visible height. A panel is moved only when its frame changed and is made
/// only when a Stage workspace first shows on its screen, so a refresh that changes nothing costs nothing here.
@MainActor
final class ShelfPanels: ShelfPresenting {
    private weak var shelf: WindowShelf?
    private var panels: [String: NSPanel] = [:]
    /// The room above the shelf's first place on a screen, by its name: the top bar's and the outer gap's (the tiler's
    /// top edge for its tiles).
    private let top: @MainActor (String) -> CGFloat

    init(shelf: WindowShelf, top: @escaping @MainActor (String) -> CGFloat) {
        self.shelf = shelf
        self.top = top
    }

    func show(_ screens: [ShelfScreen]) {
        let shown = Set(screens.map(\.id))
        for (id, panel) in panels where !shown.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        guard let shelf else { return }
        for screen in screens {
            guard let display = screen.display else { continue }
            let frame = NSRect(x: display.frame.minX, y: display.visibleFrame.minY, width: CGFloat(PilotBlock.shelfWidth),
                               height: display.visibleFrame.height)
            let panel = panels[screen.id] ?? Self.panel(ShelfView(shelf: shelf, screen: screen.id, top: { [top, name = screen.monitorName] in top(name) }))
            panels[screen.id] = panel
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }


    /// The Fly (Q708) on `screen`: `incoming` from its card (`card`, in the panel's top-left coordinates) to the stage,
    /// the box round the stage's windows (their bounds, which need no Screen Recording), or the room right of the shelf
    /// with none; the stage's windows join through the flight as their stills come in.
    func fly(_ incoming: ShelfStill, from card: CGRect, flat: Bool, on screen: ShelfScreen, landed: @escaping @MainActor () -> Void) -> ShelfFlight? {
        guard let panel = panels[screen.id], panel.isVisible, let display = screen.display else { return nil }
        let start = CGRect(x: panel.frame.minX + card.minX, y: panel.frame.maxY - card.maxY, width: card.width, height: card.height)
        let staged = Self.frames(screen.staged)
        let room = display.visibleFrame
        let stage = staged.values.reduce(CGRect.null) { $0.union($1) }
        let to = stage.isNull ? CGRect(x: room.minX + CGFloat(PilotBlock.shelfWidth) + 16, y: room.minY + 16,
                                       width: room.width - CGFloat(PilotBlock.shelfWidth) - 32, height: room.height - 32) : stage
        let look = ShelfFlyLook(StyleTokens.of(Look.shared.style, theme: Look.shared.theme))
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fly = ShelfFly.shared
        // Reduce motion: the card does not travel; the stage's window fades out over the one coming in.
        if !reduce {
            fly.fly([ShelfLeg(still: incoming, from: start, to: to, turnFrom: flat ? 0 : ShelfGroup<EmptyView>.turn, turnTo: 0)],
                    over: display.frame, look: look, reduceMotion: false, landed: landed)
        }
        return PanelFlight(fly: fly, staged: staged, card: start, screen: display.frame, look: look, reduce: reduce, landed: { if reduce { landed() } })
    }

    /// Each window's bounds on screen in AppKit's coordinates, read from the window server's list (no capture).
    static func frames(_ ids: [Int]) -> [Int: CGRect] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var out: [Int: CGRect] = [:]
        for id in ids {
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            out[id] = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return out
    }

    /// A shelf's window: the gap handles' panel (borderless, so never key and never activating Pilot: focus stays with
    /// the window a click brings to the stage; on every Space, out of Cmd+Tab, just above the desktop's icons and under
    /// every window). The tiler never lays it out: a panel is a popup to it (OwnApp).
    private static func panel(_ content: ShelfView) -> NSPanel {
        let panel = GapHandlePanels.panel()
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }
}

/// The stage's windows on a Fly: each with a still flies from where it stands to the card's place.
@MainActor
private struct PanelFlight: ShelfFlight {
    let fly: ShelfFly
    let staged: [Int: CGRect]
    let card: CGRect
    let screen: CGRect
    let look: ShelfFlyLook
    let reduce: Bool
    let landed: @MainActor () -> Void

    func leave(_ stills: [Int: ShelfStill]) {
        let legs = stills.compactMap { id, still in
            staged[id].map { ShelfLeg(still: still, from: $0, to: card, turnFrom: 0, turnTo: ShelfGroup<EmptyView>.turn) }
        }
        fly.fly(legs, over: screen, look: look, reduceMotion: reduce, landed: landed)
    }
}

extension ShelfScreen {
    /// The NSScreen the tiler's monitor is: by its display's UUID, else its name.
    var display: NSScreen? {
        NSScreen.screens.first { s in displayUUID.map { DisplayIdentity.uuid(of: s) == $0 } ?? false }
            ?? NSScreen.screens.first { $0.localizedName == monitorName }
    }

    /// Whether the pointer is over this screen's shelf now.
    @MainActor var holdsPointer: Bool {
        guard let frame = display?.frame else { return false }
        let at = NSEvent.mouseLocation
        return frame.contains(at) && at.x < frame.minX + CGFloat(PilotBlock.shelfWidth)
    }
}
