import Foundation

/// The hold-Hyper overlay's timing (card agent-bo-95422448, story 55; SPEC.md, Overlay): the layer key held the delay
/// (0.4 s unless set on Settings › General) with no other key shows that sublayer's page; Shift, Ctrl or Alt held with it
/// turns the page; any key or the release closes it. The engine feeds it the tap's events and a timer's tick, and draws
/// what it returns.
public struct HoldOverlay: Equatable, Sendable {
    /// The delay unless set; the quick tap's window too (HyperLayer).
    public static let delay: TimeInterval = 0.4
    /// The setting's range, a tenth a step (Sven, 2026-10-19).
    public static let delayRange: ClosedRange<TimeInterval> = 0.2...2.0
    public static func clamped(delay: TimeInterval) -> TimeInterval {
        (min(max(delay, delayRange.lowerBound), delayRange.upperBound) * 10).rounded() / 10
    }
    /// A quick tap ends where the overlay shows, so a hold that showed it never also sends Escape; a longer delay keeps the
    /// tap quick (card agent-bo-95422993).
    public static func quickTapWindow(delay: TimeInterval) -> TimeInterval { min(delay, Self.delay) }

    public enum Change: Equatable, Sendable { case none, show(BindsPage.Sublayer), redraw(BindsPage.Sublayer), hide }

    /// When the layer went down, while no key has been pressed since.
    private var downAt: TimeInterval?
    /// The delay this hold was pressed under, so a change mid-hold waits for the next.
    private var holdDelay = HoldOverlay.delay
    public private(set) var showing = false
    public private(set) var sublayer = BindsPage.Sublayer.hyper

    public init() {}

    public mutating func layerDown(at time: TimeInterval, delay: TimeInterval = HoldOverlay.delay) {
        downAt = time
        holdDelay = delay
        sublayer = .hyper
    }

    /// Shows the page once the layer has been held its delay with no key.
    public mutating func tick(at time: TimeInterval) -> Change {
        guard !showing, let downAt, time - downAt >= holdDelay else { return .none }
        showing = true
        return .show(sublayer)
    }

    /// The modifiers held with the layer key; a set with no page (Shift+Alt) keeps the page shown.
    public mutating func modifiers(_ held: Modifiers) -> Change {
        guard let page = BindsPage.Sublayer(modifiers: held), page != sublayer else { return .none }
        sublayer = page
        return showing ? .redraw(page) : .none
    }

    /// Any key while the layer is held: a bind, so the overlay never shows, or closes.
    public mutating func key() -> Change { close() }

    public mutating func layerUp() -> Change { close() }

    private mutating func close() -> Change {
        downAt = nil
        guard showing else { return .none }
        showing = false
        return .hide
    }
}

/// What the overlay lists (story 56): the sublayer's Hyper binds, as the Binds screen's tab has them; plain combos never.
public enum OverlayPage {
    public enum Mode: String, CaseIterable, Sendable {
        case every, mostUsed, pick
        public var title: String {
            switch self {
            case .every: "Every bind"
            case .mostUsed: "My most used"
            case .pick: "My own pick"
            }
        }
    }

    /// Every bind in Binds-screen order; most used, the pressed ones by count, at most `limit`; my pick, the picked ones.
    public static func rows(store: BindStore, actions: [BindsPage.ActionInfo], sublayer: BindsPage.Sublayer, mode: Mode,
                            presses: [String: Int], picks: Set<String>, limit: Int = 12) -> [BindsPage.Row] {
        let all = BindsPage.rows(store: store, actions: actions, tab: .layer(sublayer))
        switch mode {
        case .every: return all
        case .pick: return all.filter { picks.contains($0.id) }
        case .mostUsed:
            let pressed = all.compactMap { row in presses[row.id].flatMap { $0 > 0 ? (row, $0) : nil } }
            return pressed.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
    }

    /// The actions the overlay shows now on any sublayer: what Binds › Overlay switches on.
    public static func shown(store: BindStore, actions: [BindsPage.ActionInfo], mode: Mode, presses: [String: Int],
                             picks: Set<String>) -> Set<String> {
        Set(BindsPage.Sublayer.allCases.flatMap { rows(store: store, actions: actions, sublayer: $0, mode: mode, presses: presses, picks: picks).map(\.id) })
    }

    /// One bind Binds › Overlay lists (story 56): what it does, its whole key ("Hyper+Shift+K"), and whether it shows.
    public struct Choice: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var key: String
        public var shown: Bool
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public var module: String
        public var choices: [Choice]
        public var id: String { module }
    }

    /// Every bind of the active preset the overlay can show (a sublayer's; plain combos never), by module and label, each
    /// ticked when it shows now; `search` narrows them by what it does, its module or its key.
    public static func choices(store: BindStore, actions: [BindsPage.ActionInfo], shown: Set<String>, search: String = "") -> [Group] {
        // The Binds screen's own search, its sublayer sections only.
        let rows = BindsPage.sections(store: store, actions: actions, search: search)
            .filter { if case .layer = $0.tab { true } else { false } }
            .flatMap(\.rows).sorted { ($0.module, $0.label) < ($1.module, $1.label) }
        var groups: [Group] = []
        for row in rows {
            let choice = Choice(id: row.id, label: row.label, key: store.trigger(for: row.id)?.label ?? "", shown: shown.contains(row.id))
            if groups.last?.module == row.module { groups[groups.count - 1].choices.append(choice) }
            else { groups.append(Group(module: row.module, choices: [choice])) }
        }
        return groups
    }

    /// The pick after one bind is switched on or off: what shows now, with that one in or out, so the first switch in
    /// Every bind or My most used keeps every other bind as it was and turns the overlay to My own pick.
    public static func picks(switching id: String, on: Bool, shown: Set<String>) -> Set<String> {
        on ? shown.union([id]) : shown.subtracting([id])
    }
}

/// How often each bind ran (story 56), kept on the Mac and never sent anywhere.
public struct PressCounts: Equatable, Sendable {
    public private(set) var counts: [String: Int]

    public init(counts: [String: Int] = [:]) { self.counts = counts }

    public mutating func count(_ action: String) { counts[action, default: 0] += 1 }
}

public struct PressCountStore: Sendable {
    /// ~/Library/Application Support/Pilot/presses.json
    public static let standard = PressCountStore(url: PilotFolder.support.appending(path: "presses.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// None counted when nothing was pressed yet. A file that does not decode throws, so no save wipes it.
    public func load() throws -> PressCounts { PressCounts(counts: try JSONFile(url: url).load(or: [:])) }

    public func save(_ presses: PressCounts) throws { try JSONFile(url: url).save(presses.counts) }
}
