import AppKit
import Observation
import PilotCore

/// Where each bar drew its slots, so the overflow item knows which went for room (TopBarOverflow). The bar was edited
/// on itself here until Q185 (Sven, 2026-10-16): the Menu bar page's strip and tray took that over, and the on-bar edit
/// mode is parked on branch parked/bar-edit-on-bar.
@Observable @MainActor
final class BarFrames {
    static let shared = BarFrames()
    /// The bar's coordinate space, the strip's whole frame, top left at the bar's own.
    static let space = "pilot.bar"

    /// A slot of one bar: its screen, side and index in that side's slots.
    struct SlotKey: Hashable {
        let screen: String
        let side: TopBarSide
        let index: Int
    }

    /// Each bar's slots as drawn, in its own space.
    private(set) var frames: [SlotKey: CGRect] = [:]

    /// A bar drew the slot at `index` of `side` at `rect` (its own space); unchanged frames write nothing.
    func report(_ rect: CGRect, side: TopBarSide, index: Int, on screen: String) {
        let key = SlotKey(screen: screen, side: side, index: index)
        if frames[key] != rect { frames[key] = rect }
    }

    /// The slots of `sides` the bar on `screen` put off the row for room (TopBarRow): drawn with a width, wholly left of
    /// the bar, in the bar's order. The overflow item lists them (TopBarOverflow).
    func gone(on screen: String, in sides: [TopBarSide: [BarSlot]]) -> [BarSlot] {
        TopBarSide.allCases.flatMap { side in
            (sides[side] ?? []).enumerated().compactMap { i, slot in
                frames[SlotKey(screen: screen, side: side, index: i)].flatMap { $0.width > 0 && $0.maxX <= 0 ? slot : nil }
            }
        }
    }
}

extension BarItemsStore {
    /// A pilot://bar link (BarRoute): edit=1 opens the Menu bar page, where the bar is dragged; the rest change the bar
    /// as a drag there would.
    func route(_ url: URL) {
        guard let route = BarRoute(url) else { return tblog.error("bar link names nothing Pilot has: \(LinkToken.redact(url.absoluteString), privacy: .public)") }
        if route == .edit { AppWindowController.shared.open(.menuBar) } else { route.apply(to: &settings) }
        tblog.notice("bar link: \(LinkToken.redact(url.query ?? ""), privacy: .public)")
    }
}
