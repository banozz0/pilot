import AppKit
import Observation
import PilotCore
import SwiftUI

/// The items of the macOS menu bar and Pilot's top bar (card agent-bo-95422910): stored, saved on every change as
/// `bar.items`. The first start carries today's settings over: the menu bar's readings (menuBar.stats, or on a Mac that
/// never saved them the Stats app's own choices, read only), the top bar's layout (topBar.settings) and the pomodoro's
/// Countdown in menu bar; the old keys are read, never deleted.
@Observable @MainActor
final class BarItemsStore {
    static let shared = BarItemsStore()
    static let key = "bar.items"
    @ObservationIgnored private let defaults: UserDefaults

    /// Existing malformed data is not first launch. Keep it recoverable and refuse every writer.
    private(set) var loadError: String?

    func requireWritable() throws(ControlError) {
        if let loadError { throw ControlError(.badValue, loadError) }
    }

    // Roll back through the backing storage: re-entering an observable setter recurses.
    /// Stored, so a change reaches both bars and the pages at once (cards 775 and 776).
    var settings: BarSettings {
        didSet {
            guard loadError == nil else { _settings = oldValue; return }
            if held == nil { save() }
        }
    }
    /// The settings as they stood when a drag began changing them in memory (the spacer's stretch): while held a change
    /// redraws both bars and writes nothing, so a drag of many steps saves once, on `release`.
    @ObservationIgnored private var held: BarSettings?

    func hold() { if held == nil { held = settings } }

    /// The drag is over: its last change is saved once, or with `restore` the settings go back to the hold's start,
    /// which is what is saved already.
    func release(restore: Bool = false) {
        guard let before = held else { return }
        if restore { settings = before }
        held = nil
        if settings != before { save() }
    }

    private func save() {
        guard loadError == nil else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
    /// Which bar the Menu bar page shows and + edits (Menu bar, Top bar or Both), kept across launches: it was the page's
    /// own state, so every launch opened on Menu bar (Sven, 2026-10-10).
    var pagePlacement: BarPlacement {
        didSet { guard loadError == nil else { _pagePlacement = oldValue; return }; defaults.set(pagePlacement.rawValue, forKey: Self.pagePlacementKey) }
    }
    static let pagePlacementKey = "bar.pagePlacement"
    /// Set at the first start, or once a saved Pilot item has moved to the mark alone (spec pilot-1-1 T28).
    static let markAloneKey = "bar.pilotMarkAlone"
    /// Set at the first start, or once a saved bar's extensions' items have their own places (spec pilot-1.1 T50).
    static let extensionsApartKey = "bar.extensionsApart"
    /// The top bar switched on or off: the page shows the bar the items now sit in, Top bar or Menu bar; a pick by hand
    /// after it stays until the next switch (Sven, 2026-10-11).
    func topBarSwitched(_ on: Bool) { pagePlacement = on ? .topBar : .menuBar }
    /// The top bar's own Background and Colour (Sven, 2026-10-10: on Look's Glass he could not read it): Solid and the
    /// theme's bar colour until picked, whatever Look's Glass says. TopBarStrip draws them, TopBarWindows the glass.
    var background: TopBarBackground {
        didSet { guard loadError == nil else { _background = oldValue; return }; defaults.set(background.rawValue, forKey: Self.backgroundKey) }
    }
    var colour: ColourChoice {
        didSet { guard loadError == nil else { _colour = oldValue; return }; defaults.set(colour.rawValue, forKey: Self.colourKey) }
    }
    static let backgroundKey = "bar.background", colourKey = "bar.colour"
    /// Item colours (Sven, Q251), on until turned off: EnvironmentValues.barItemColours.
    var itemColours: Bool {
        didSet { guard loadError == nil else { _itemColours = oldValue; return }; defaults.set(itemColours, forKey: Self.itemColoursKey) }
    }
    static let itemColoursKey = "bar.itemColours"
    /// Whether Pilot's top bar is on, so items placed in both leave the macOS menu bar; Engine points it at the top
    /// bar's switch, which is observed through it.
    @ObservationIgnored var isTopBarOn: @MainActor () -> Bool = { false }

    init(defaults: UserDefaults = .pilot(), statsPrefs: () -> [String: Any] = BarItemsStore.statsPrefs,
         extensionOrder: @escaping @Sendable () -> [String] = { ExtensionBar.withBar(in: Extension.folder).map(\.id) }) {
        self.defaults = defaults
        pagePlacement = defaults.string(forKey: Self.pagePlacementKey).flatMap(BarPlacement.init(rawValue:)) ?? .menuBar
        background = defaults.string(forKey: Self.backgroundKey).flatMap(TopBarBackground.init(rawValue:)) ?? .solid
        colour = defaults.string(forKey: Self.colourKey).flatMap(ColourChoice.init(rawValue:)) ?? .theme
        itemColours = defaults.object(forKey: Self.itemColoursKey) as? Bool ?? true
        // A bar saved before each extension's item had its own place (spec pilot-1.1 T50) gives each one its place in the
        // order its Extensions slot drew them, by title, as ExtensionBar lists them; the folder is read only then.
        let decoder = JSONDecoder()
        decoder.userInfo[BarSettings.extensionOrder] = extensionOrder
        if let stored = defaults.object(forKey: Self.key) {
            let savedSettings: BarSettings
            do {
                guard let data = stored as? Data else { throw ThemeFailure("saved bar settings are not data") }
                try BarSettings.validateSavedData(data)
                savedSettings = try decoder.decode(BarSettings.self, from: data)
            } catch {
                loadError = "saved bar settings are malformed; edits refused; original data retained"
                settings = .defaults
                return
            }
            var saved = savedSettings
            // Pilot's mark alone, once (spec pilot-1-1 T28, Sven Q643): a bar saved with the workspace number beside the mark
            // moves to the mark; a style picked after this stays.
            if !defaults.bool(forKey: Self.markAloneKey) {
                if saved.entry(.pilot).style == .iconNumber {
                    saved.set(.pilot, style: .icon)
                    defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
                }
                defaults.set(true, forKey: Self.markAloneKey)
            }
            if !defaults.bool(forKey: Self.extensionsApartKey) {
                defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
                defaults.set(true, forKey: Self.extensionsApartKey)
            }
            settings = saved
            return
        }
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        // A Mac that never saved menu-bar readings takes the Stats app's, as the first start always did; one without
        // Stats starts from round 4's defaults.
        let stats = decode(MenuBarStats.Choices.self, "menuBar.stats") ?? {
            let prefs = statsPrefs()
            return prefs.isEmpty ? nil : MenuBarStats.fromStats(prefs)
        }()
        settings = BarSettings.migrated(stats: stats, topBar: decode(TopBarSettings.self, "topBar.settings"),
                                        pomodoroCountdown: defaults.object(forKey: "pomodoro.countdown") as? Bool)
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
        defaults.set(true, forKey: Self.markAloneKey)
        defaults.set(true, forKey: Self.extensionsApartKey)
        let on = settings.entries.filter(\.on).map { "\($0.kind.rawValue) \($0.placement.rawValue)" }.joined(separator: ", ")
        log.notice("bar items carried over: \(on, privacy: .public)")
    }

    /// What `place` draws now, the top bar's switch deciding what leaves the macOS menu bar.
    func slots(in place: BarPlace, side: TopBarSide? = nil) -> [BarSlot] {
        loadError == nil ? settings.slots(in: place, topBarOn: isTopBarOn(), side: side) : []
    }

    func shows(_ kind: BarKind, in place: BarPlace) -> Bool { loadError == nil && settings.shows(kind, in: place, topBarOn: isTopBarOn()) }

    /// Whether an extension's bar item shows in `place` now (Surfaces v2).
    func shows(extension id: String, in place: BarPlace) -> Bool { loadError == nil && settings.shows(extension: id, in: place, topBarOn: isTopBarOn()) }

    /// The observers dump's line, so a live check reads what each bar shows: the menu bar now, the top bar once on.
    var line: String {
        let names = { (slots: [BarSlot]) in slots.map(\.name).joined(separator: ", ") }
        return "bar items: menu bar " + names(slots(in: .menuBar)) + "; top bar "
            + TopBarSide.allCases.map { "\($0.rawValue) " + names(settings.slots(in: .topBar, topBarOn: true, side: $0)) }.joined(separator: " | ")
    }

    /// The Stats app's preferences, read only; empty when it was never installed.
    nonisolated static func statsPrefs() -> [String: Any] {
        let domain = "eu.exelban.Stats" as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return [:] }
        return CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }
}

/// One macOS menu-bar item as drawn: its slot's items (its identity), their parts, and whether it is the group, its
/// readings side by side (card agent-bo-95422911).
struct StatusItemContent: Equatable {
    let kinds: [BarKind]
    let parts: [[BarPart]]
    let isGroup: Bool
    /// Its one-line tooltip (BarTooltip); a change to it alone redraws nothing.
    var tooltip = ""
    /// An extension's own item (Surfaces v2): its id, part of its identity.
    var extensionID: String? = nil
    /// The theme's accent for Pilot's mark (spec pilot-1-1 T28), so a theme change redraws the item; nil without the mark.
    var accent: UInt32? = nil

    /// Its identity in the menu bar, and its autosave name's end.
    var key: String { kinds.map(\.rawValue).joined(separator: "+") + (extensionID.map { ".\($0)" } ?? "") }
}

/// Where the items go: the real menu bar, or a fake in the tests so none lands in Sven's.
@MainActor
protocol StatusItemHosting: AnyObject {
    /// One menu-bar item per content, left to right; an empty list removes them all.
    func show(_ items: [StatusItemContent])
    /// An item's popover, hung under that item; `stats` keeps their readings and busiest processes read while it shows.
    func present(_ popover: AnyView, for kinds: [BarKind])
    /// An extension's popover, hung under its own item (Surfaces v2).
    func present(_ popover: AnyView, extension id: String)
    /// An item's right-click menu, hung under that item; a pick comes back through `perform`.
    func menu(_ rows: [BarMenuRow], for kinds: [BarKind], perform: @escaping (BarAction) -> Void)
    /// The item's click, left or right, routed back to MenuBarStatusItems.
    var clicked: (StatusItemContent, _ right: Bool) -> Void { get set }
}

/// The macOS menu bar's bar items (cards agent-bo-95422910, 911 and 912): one item per slot the store places there, in
/// order, Pilot's own icon first, each drawn in its style from the readings it needs, redrawn only when its parts change;
/// a click opens its popover, Pilot's the dropdown, or runs its one action. The items'
/// readers (BarReadings, shared with the top bar) run only while an item holds them; with no reading shown nothing reads.
@MainActor
final class MenuBarStatusItems {
    static let shared = MenuBarStatusItems(store: .shared, host: StatusBarHost())

    private let store: BarItemsStore
    private let host: StatusItemHosting
    private var sources: BarSources?
    private var shown: [StatusItemContent]?
    private var held: Set<BarKind> = []

    init(store: BarItemsStore, host: StatusItemHosting) {
        self.store = store; self.host = host
        host.clicked = { [weak self] content, right in self?.click(content, right: right) }
    }

    func start(_ sources: BarSources) {
        self.sources = sources
        apply()
    }

    func stop() {
        sources?.readings.hold([], replacing: &held)
        sources = nil
        host.show([])
        shown = []
    }

    private func apply() {
        guard let sources else { return }
        let (contents, kinds, combine) = withObservationTracking {
            let settings = store.settings
            let slots = store.slots(in: .menuBar)
            let kinds = Set(slots.flatMap(\.kinds))
            let inputs = sources.inputs(for: slots.flatMap(\.entries))
            let accent = Look.shared.theme.accent
            let contents = slots.compactMap { slot in
                BarParts.parts(slot, inputs, settings: settings).map {
                    StatusItemContent(kinds: slot.kinds, parts: $0, isGroup: slot.isGroup, tooltip: BarTooltip.text(slot, inputs),
                                      accent: $0.joined().contains(.mark) ? accent : nil)
                }
            }
            // Each extension's own item after Pilot's (Surfaces v2). The bar items are always held here: one never placed
            // shows in this bar, and a round asks only the ones placed somewhere.
            let extensions = sources.extensionBar.items.filter { store.shows(extension: $0.id, in: .menuBar) }.compactMap(\.face).map {
                StatusItemContent(kinds: [.extensions], parts: [[.extensionItem($0)]], isGroup: false, tooltip: $0.tooltip, extensionID: $0.id)
            }
            return (contents + extensions, kinds.union([.extensions]), settings.combineProcesses)
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply() }
        }
        sources.sampler.combineProcesses = combine
        sources.readings.clockSeconds = store.settings.clock.showsSeconds
        sources.readings.hold(kinds, replacing: &held)
        if contents != shown {
            host.show(contents)
            shown = contents
        }
    }

    /// An item's click: the group and most items open their popover; the layout cycles, Keep awake switches, Option-click
    /// on Volume mutes.
    /// A right-click opens the item's menu (the Group's for the group), which has no Move to here: sides are the top bar's;
    /// Capture's click opens its own actions alone.
    func click(_ content: StatusItemContent, right: Bool = false, option: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard let sources else { return }
        if let id = content.extensionID {
            return host.present(AnyView(ExtensionItemPopover(id: id, bar: sources.extensionBar)), extension: id)
        }
        let popover = { [host, store] in host.present(AnyView(BarPopover(kinds: content.kinds, sources: sources, store: store)), for: content.kinds) }
        let click = BarClick(content.kinds, isGroup: content.isGroup, option: option)
        if right || click == .menu {
            let kind = content.isGroup ? BarKind.group : content.kinds[0]
            let rows = right ? sources.menu(kind, in: .menuBar, store: store) : sources.clickMenu(kind, store: store)
            host.menu(rows, for: content.kinds) { [store] action in
                sources.perform(action, on: kind, store: store, popover: popover)
            }
            return
        }
        if click == .popover { popover() } else { sources.perform(click) }
    }
}

/// An open popover's own watch: every second, with the process list when it shows CPU or RAM, from the moment it opens
/// until it closes, never longer (the popover object itself may outlive its showing).
@MainActor
final class PopoverWatch {
    private let sampler: SystemSampler
    private let interval: Duration
    /// Cancelled from deinit too, so a popover whose view goes without SwiftUI's onDisappear (BarPanel's dismiss drops
    /// it) never leaves a watch running.
    nonisolated(unsafe) private var task: Task<Void, Never>?

    init(sampler: SystemSampler, interval: Duration = .seconds(1)) { self.sampler = sampler; self.interval = interval }

    func opened(_ stats: [MenuBarStats.Stat]) {
        task?.cancel()
        let sampler = sampler, interval = interval
        let needs: SystemSampler.Needs = stats.contains(where: MenuBarStats.listsProcesses.contains) ? [.rows, .processes] : .rows
        task = Task { await sampler.watch(every: interval, needs: needs) }
    }

    func closed() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// The real menu bar: one NSStatusItem per item, showing a template picture of its parts (StatusItemImage, cards
/// agent-bo-95422837 and 911; Pilot's mark keeps its accent box), redrawn only when they or the accent change; the focused app shows its own icon and name. No SwiftUI in
/// the item: macOS redraws it once per menu bar on every change, and a hosted view cost a layout and render each time.
@MainActor
final class StatusBarHost: NSObject, StatusItemHosting {
    private struct Shown {
        var content: StatusItemContent
        let item: NSStatusItem
    }
    private var shown: [Shown] = []
    var clicked: (StatusItemContent, _ right: Bool) -> Void = { _, _ in }

    func show(_ items: [StatusItemContent]) {
        // The same items in the same order: only what they show changed, so the pictures follow in place, nothing moves;
        // a new tooltip alone redraws nothing.
        if items.map(\.key) == shown.map(\.content.key) {
            for index in shown.indices where shown[index].content != items[index] {
                let (before, after) = (shown[index].content, items[index])
                shown[index].content = after
                if before.tooltip != after.tooltip { shown[index].item.button?.toolTip = after.tooltip }
                if before.parts != after.parts || before.isGroup != after.isGroup || before.accent != after.accent { draw(shown[index]) }
            }
            return
        }
        for entry in shown { NSStatusBar.system.removeStatusItem(entry.item) }
        // A new item lands left of the ones made before it, so the rightmost comes first.
        shown = items.reversed().map(makeItem).reversed()
        for entry in shown {
            entry.item.button?.toolTip = entry.content.tooltip
            draw(entry)
        }
    }

    private func makeItem(_ content: StatusItemContent) -> Shown {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "pilot.bar." + content.key
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return Shown(content: content, item: item)
    }

    private func draw(_ entry: Shown) {
        guard let button = entry.item.button else { return }
        let parts = entry.content.parts.joined()
        if case .extensionItem(let face)? = parts.first {
            // An extension's gauges and text, in their tones (ExtensionGaugeIcon); nothing to show takes no room.
            let image = ExtensionGaugeIcon.image(face)
            button.contentTintColor = nil
            button.title = ""
            button.imagePosition = .imageOnly
            button.image = image
            entry.item.length = image == nil ? 0 : NSStatusItem.variableLength
            return
        }
        if case .app(let name, let showsName)? = parts.first(where: { if case .app = $0 { true } else { false } }) {
            // An app's icon keeps its colours: drawn by the button itself, never as a template.
            let icon = NSWorkspace.shared.frontmostApplication?.icon
            icon?.size = NSSize(width: 16, height: 16)
            button.image = icon
            button.imagePosition = showsName ? .imageLeading : .imageOnly
            button.title = showsName ? name : ""
            entry.item.length = NSStatusItem.variableLength
            return
        }
        let image = StatusItemImage.image(entry.content.parts, accent: entry.content.accent)
        // A reading past its threshold turns amber; the group's picture is one template, so only a lone item can.
        button.contentTintColor = !entry.content.isGroup && entry.content.parts.joined().contains(.warn) ? NSColor(Theme.yellow) : nil
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = image
        // A reading this Mac lacks takes no room.
        entry.item.length = image == nil ? 0 : NSStatusItem.variableLength
    }

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let content = shown.first(where: { $0.item.button === button })?.content else { return }
        clicked(content, NSApp.currentEvent?.type == .rightMouseUp)
    }

    func menu(_ rows: [BarMenuRow], for kinds: [BarKind], perform: @escaping (BarAction) -> Void) {
        guard let button = shown.first(where: { $0.content.kinds == kinds })?.item.button else { return }
        BarMenu.show(rows, under: button, perform: perform)
    }

    func present(_ view: AnyView, extension id: String) {
        BarPanel.shared.toggle(extension: id, under: shown.first(where: { $0.content.extensionID == id })?.item.button, view)
    }

    /// The item's popover or the dropdown, hung under its button (BarPanel: the same item again closes it).
    func present(_ view: AnyView, for kinds: [BarKind]) {
        BarPanel.shared.toggle(kinds, under: shown.first(where: { $0.content.kinds == kinds })?.item.button, view)
    }
}

/// A reading's popover over the shared sampler, which its own PopoverWatch keeps reading from showing to going, in
/// both bars.
struct LiveStatPopover: View {
    let stats: [MenuBarStats.Stat]
    let openHome: () -> Void
    @State private var watch = PopoverWatch(sampler: .shared)

    var body: some View {
        let sampler = SystemSampler.shared
        StatPopover(stats: stats, rows: sampler.rows, busiest: [.cpu: sampler.busiestCPU, .ram: sampler.busiestMemory,
                                                                .disk: sampler.busiestDisk, .network: sampler.busiestNetwork],
                    values: sampler.latestValues, latest: sampler.latest, history: sampler.history, openHome: openHome)
            .onAppear { watch.opened(stats) }
            .onDisappear { watch.closed() }
    }
}

/// A reading's details, Stats-style: one line per reading with its graph and value (round 3's All in one), then This
/// Mac's rows for each and the busiest processes for CPU, RAM, disk and network.
struct StatPopover: View {
    @Environment(\.style) private var style
    let stats: [MenuBarStats.Stat]
    let rows: [SystemStats.Row]
    /// The busiest processes for each reading that lists them (CPU, RAM, disk, network).
    let busiest: [MenuBarStats.Stat: [SystemStats.Row]]
    var values: SystemStats.Values?
    var latest: SystemStats.Raw?
    var history: [SystemStats.Values] = []
    let openHome: () -> Void

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentStatPopover(popover: self)
        case .toybox: ToyStatPopover(popover: self)
        }
    }

}
