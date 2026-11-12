import Foundation
import PilotCore

extension SettingsSchema {
    /// The Menu bar page's keys: the top bar's switch, its background and colour, and which bar the page edits.
    /// The switch answers once it went through (it hides the menu bar through System Events and makes room in the
    /// Pilot block); one refused answers bad-value with the page's reason. The items are a list (`pilot bar-items`).
    /// The readings' look and the clock's style, pattern, second zone and events follow (CLI W18); Show exact menu bar items is
    /// `pilot bar exact`, since turning it on asks Allow (it uses Screen Recording, ADR 0012).
    func registerBar(_ bar: BarItemsStore, topBar: TopBarController) {
        register([.bool("topBar.on", "Top bar", page: "menuBar", standard: false, read: { topBar.isOn }, write: { on throws(ControlError) in try await Self.flip(topBar, to: on) })])
        registerBarAppearance(bar)
        registerPill(.forSettings)
    }

    /// Store-only setters. The isolated bar host never constructs the top-bar switch or a live controller.
    func registerBarAppearance(_ bar: BarItemsStore) {
        let patterns = TopBarClockFormat.presets.map { "\"\($0.title)\"" }.joined(separator: ", ")
        register([
            .choice("bar.background", "Top bar background", page: "menuBar", TopBarBackground.allCases, standard: .solid,
                    read: { bar.background }, write: { value throws(ControlError) in try bar.requireWritable(); bar.background = value }),
            .colour("bar.colour", "Top bar colour", page: "menuBar", read: { bar.colour }, write: { value throws(ControlError) in try bar.requireWritable(); bar.colour = value }),
            .bool("bar.itemColours", "Item colours: the top bar's readings amber or red by load, other apps' items in their own colours",
                  page: "menuBar", standard: true, read: { bar.itemColours }, write: { value throws(ControlError) in try bar.requireWritable(); bar.itemColours = value }),
            .choice("bar.pagePlacement", "The bar the page edits", page: "menuBar", BarPlacement.allCases, standard: .menuBar,
                    read: { bar.pagePlacement }, write: { value throws(ControlError) in try bar.requireWritable(); bar.pagePlacement = value }),
            .choice("bar.readingsLook", "The readings' look in the menu bar", page: "menuBar", BarSettings.ReadingsLook.allCases,
                    standard: BarSettings.defaults.readingsLook, read: { bar.settings.readingsLook }, write: { value throws(ControlError) in try bar.requireWritable(); bar.settings.setReadingsLook(value) }),
            .text("bar.clock", "The clock's time: \(patterns) or a date pattern",
                  page: "menuBar", standard: BarSettings.defaults.clock.rawValue, read: { bar.settings.clock.rawValue },
                  write: { word throws(ControlError) in try bar.requireWritable(); bar.settings.clock = try Self.clock(word) }),
            .choice("bar.clockStyle", "The clock's style: time, the date and time, or two zones", page: "menuBar", BarKind.clock.styles,
                    standard: BarSettings.defaults.entry(.clock).style, read: { bar.settings.entry(.clock).style },
                    write: { value throws(ControlError) in try bar.requireWritable(); bar.settings.set(.clock, style: value) }),
            .choice("bar.clockZone", "The clock's second zone, for the two zones style", page: "menuBar",
                    ClockPopover.zoneChoices(bar.settings.clockZone).map { $0.id ?? "none" }, standard: "none",
                    read: { bar.settings.clockZone ?? "none" }, write: { value throws(ControlError) in try bar.requireWritable(); bar.settings.clockZone = value == "none" ? nil : value }),
            .bool("bar.clockEvents", "The clock's popover lists Calendar's events", page: "menuBar", standard: false,
                  read: { bar.settings.clockEvents }, write: { value throws(ControlError) in try bar.requireWritable(); bar.settings.clockEvents = value }),
        ])
        registerPillFirst(bar)
    }

    /// The pill-first bar (PillFirst, Q160 to Q165): `bar.preset` is the Look and Menu bar picker's preset, pillFirst
    /// beside the saved ones, as `pilot bar preset` chooses it; leaving pillFirst for the preset under it restores the bar
    /// exactly. `pill.pages` is its pill's pages in order: media, calendar, stats, controls, activity, and extensions
    /// pages as Name=id+id+id (up to three; Name= holds none).
    func registerPillFirst(_ bar: BarItemsStore) {
        register([
            .choice("bar.preset", "The top bar's preset: the saved layout's, or the pill-first bar drawn over it", page: "menuBar", BarItemsStore.presetIDs,
                    standard: BarItemsStore.legacyPreset, read: { bar.presetID }, write: { id throws(ControlError) in try bar.choosePreset(id) }),
            .text("pill.pages", "The pill-first bar's pages, comma-separated: \(PillFirst.Kind.allCases.filter { $0 != .extensions }.map(\.rawValue).joined(separator: ", ")), or Name=id+id+id for up to three extensions",
                  page: "menuBar", standard: PillFirst.words(PillFirst.Page.standard), read: { PillFirst.words(bar.pillFirst.pages) },
                  write: { typed throws(ControlError) in
                      try bar.requireWritable()
                      let pages = try PillFirst.pages(typed)
                      bar.pillFirst.pages = pages
                  }),
        ])
    }

    /// The pill's views (spec desktop-controls T7), as Menu bar › Pill edits them: `pill.views` names the views to lead,
    /// the rest following; `pill.hidden` is a set (one must show); `pill.view` is the one the pill shows (not a hidden
    /// one); `pill.extensions` the extensions' ids whose bar items the Extensions view shows, in order, or none. Views:
    /// music, extensions, activity, controls.
    func registerPill(_ store: PillLayoutStore) {
        let all = Pill.View.allCases
        func listed(_ views: [Pill.View]) -> String { views.isEmpty ? "none" : Pill.Layout.names(views) }
        register([
            .text("pill.views", "The pill's view order, comma-separated (the rest follow)", page: "menuBar", standard: listed(all),
                  read: { listed(store.layout.order) }, write: { typed throws(ControlError) in try store.setOrder(Self.views(typed, key: "pill.views")) }),
            .text("pill.hidden", "The pill's hidden views, comma-separated or none (one must show)", page: "menuBar", standard: "none",
                  read: { listed(all.filter(store.layout.hidden.contains)) },
                  write: { typed throws(ControlError) in try store.setHidden(Set(Self.views(typed, key: "pill.hidden"))) }),
            .choice("pill.view", "The view the pill shows", page: "menuBar", all, standard: .music,
                    read: { store.layout.current }, write: { view throws(ControlError) in try store.select(view) }),
            .text("pill.extensions", "The extensions' bar items in the pill's Extensions view, ids comma-separated or none", page: "menuBar",
                  standard: "none", read: { store.layout.extensions.isEmpty ? "none" : store.layout.extensions.joined(separator: ",") },
                  write: { typed throws(ControlError) in try store.setExtensions(Self.words(typed, lowercased: false)) }),
        ])
    }

    static func views(_ typed: String, key: String) throws(ControlError) -> [Pill.View] {
        try named(typed, key: key, noun: "view", from: Pill.View.allCases)
    }

    /// A preset's title or a date pattern as the page's field takes it; empty is refused, as the field keeps the old one.
    static func clock(_ word: String) throws(ControlError) -> TopBarClockFormat {
        if let preset = TopBarClockFormat.presets.first(where: { $0.title.caseInsensitiveCompare(word) == .orderedSame }) { return preset.format }
        guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlError(.badValue, "the clock is a preset or a date pattern, as HH:mm") }
        return TopBarClockFormat(rawValue: word)
    }
}

extension TopBarController: Flipping {}
