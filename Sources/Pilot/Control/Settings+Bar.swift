import Foundation
import PilotCore

extension SettingsSchema {
    /// The Menu bar page's keys: the top bar's switch, its background and colour, and which bar the page edits.
    /// The switch answers once it went through (it hides the menu bar through System Events and makes room in the
    /// Pilot block); one refused answers bad-value with the page's reason. The items are a list (`pilot bar-items`).
    /// The readings' look and the clock's style, pattern, second zone and events follow (CLI W18); Show exact menu bar items is
    /// `pilot bar exact`, since turning it on asks Allow (it uses Screen Recording, ADR 0012).
    func registerBar(_ bar: BarItemsStore, topBar: TopBarController) {
        register([
            .bool("topBar.on", "Top bar", page: "menuBar", standard: false, read: { topBar.isOn }, write: { on throws(ControlError) in try await Self.flip(topBar, to: on) }),
            .choice("bar.background", "Top bar background", page: "menuBar", TopBarBackground.allCases, standard: .solid,
                    read: { bar.background }, write: { bar.background = $0 }),
            .colour("bar.colour", "Top bar colour", page: "menuBar", read: { bar.colour }, write: { bar.colour = $0 }),
            .bool("bar.itemColours", "Item colours: the top bar's readings amber or red by load, other apps' items in their own colours",
                  page: "menuBar", standard: true, read: { bar.itemColours }, write: { bar.itemColours = $0 }),
            .choice("bar.pagePlacement", "The bar the page edits", page: "menuBar", BarPlacement.allCases, standard: .menuBar,
                    read: { bar.pagePlacement }, write: { bar.pagePlacement = $0 }),
            .choice("bar.readingsLook", "The readings' look in the menu bar", page: "menuBar", BarSettings.ReadingsLook.allCases,
                    standard: BarSettings.defaults.readingsLook, read: { bar.settings.readingsLook }, write: { bar.settings.setReadingsLook($0) }),
            .text("bar.clock", "The clock's time: \(TopBarClockFormat.presets.map { "\"\($0.title)\"" }.joined(separator: ", ")) or a date pattern",
                  page: "menuBar", standard: BarSettings.defaults.clock.rawValue, read: { bar.settings.clock.rawValue },
                  write: { word throws(ControlError) in bar.settings.clock = try Self.clock(word) }),
            .choice("bar.clockStyle", "The clock's style: time, the date and time, or two zones", page: "menuBar", BarKind.clock.styles,
                    standard: BarSettings.defaults.entry(.clock).style, read: { bar.settings.entry(.clock).style },
                    write: { bar.settings.set(.clock, style: $0) }),
            .choice("bar.clockZone", "The clock's second zone, for the two zones style", page: "menuBar",
                    ClockPopover.zoneChoices(bar.settings.clockZone).map { $0.id ?? "none" }, standard: "none",
                    read: { bar.settings.clockZone ?? "none" }, write: { bar.settings.clockZone = $0 == "none" ? nil : $0 }),
            .bool("bar.clockEvents", "The clock's popover lists Calendar's events", page: "menuBar", standard: false,
                  read: { bar.settings.clockEvents }, write: { bar.settings.clockEvents = $0 }),
        ])
    }

    /// A preset's title or a date pattern as the page's field takes it; empty is refused, as the field keeps the old one.
    static func clock(_ word: String) throws(ControlError) -> TopBarClockFormat {
        if let preset = TopBarClockFormat.presets.first(where: { $0.title.caseInsensitiveCompare(word) == .orderedSame }) { return preset.format }
        guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlError(.badValue, "the clock is a preset or a date pattern, as HH:mm") }
        return TopBarClockFormat(rawValue: word)
    }
}

extension TopBarController: Flipping {}
