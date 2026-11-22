import Foundation
import Observation
import PilotCore

/// Defaults › Menu (story 152, task N6): the Hyper+Space root's order and hidden branches (MenuRoot), two string lists
/// of branch ids in Pilot's settings, so an id a later build drops is only a stale string; the extra rows switched on
/// (`menu.rootExtras`, Sven 2026-10-20) the same way, their places among the branches in the order. A `menu.pins` left by
/// Build 76's pins is never read.
/// Its own store, as FileSearchSettings is, so pages that render without an engine read it; the menu reads it as it
/// opens, and the Ring menu's Pilot ring reads `root.shownExtras()`.
@Observable @MainActor
final class MenuRootSettings {
    static let shared = MenuRootSettings()

    var root: MenuRoot {
        didSet {
            defaults.set(root.order, forKey: Self.orderKey)
            defaults.set(root.hidden.sorted(), forKey: Self.hiddenKey)
            defaults.set(root.extras.sorted(), forKey: Self.extrasKey)
        }
    }
    /// Your fallbacks (spec launcher-best T4): what a search that finds nothing offers, in order (MenuFallbacks ids);
    /// nil is Pilot's own offers.
    var fallbacks: [String]? { didSet { defaults.set(fallbacks, forKey: Self.fallbacksKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    private static let orderKey = "menu.rootOrder", hiddenKey = "menu.rootHidden", extrasKey = "menu.rootExtras", fallbacksKey = "menu.fallbacks"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        root = MenuRoot(order: defaults.stringArray(forKey: Self.orderKey) ?? [],
                        hidden: Set(defaults.stringArray(forKey: Self.hiddenKey) ?? []),
                        extras: Set(defaults.stringArray(forKey: Self.extrasKey) ?? []))
        fallbacks = defaults.stringArray(forKey: Self.fallbacksKey)
    }

    /// The fallbacks there are to pick today: Pilot's four, your quicklinks taking words, your scripts asking for them.
    static func fallbackOptions(fills: [String: String] = ScriptCommand.fills(ScriptCommand.find())) -> [MenuFallbacks.Option] {
        MenuFallbacks.options(links: QuicklinkBook.shared.links, fills: fills)
    }

    /// Today's branches in today's order, all shown, the extras switched on after System; stale ids go too. Which extras
    /// are on stays: they have their own switches.
    func reset() { root = MenuRoot(extras: root.extras) }
}
