import AppKit
import PilotCore
import SwiftUI

/// Home (pilot-ui-redesign T6, Sven's Q1 on Open question 3): the panel's first page, InstrumentHome in every style. Its
/// old board of blocks and its edit mode are gone with the spec; Pilot is the whole app, so Home has no Pilot switch of
/// its own, only the four the Pilot menu has too.
struct HomePage: View {
    let go: (AppPlace) -> Void

    var body: some View { InstrumentHome(go: go) }
}

// MARK: - What Home reads beyond the engine

/// What Home reads beyond the engine, a seam the renders fill: the clock, the settings, and the settings changed last.
struct HomeSources: Sendable {
    /// The time Home's date line reads, given the clock's: the clock's own in the app; a render pins it.
    var now: @MainActor @Sendable (Date) -> Date = { $0 }
    /// The settings the search reads and Jump back in shows the values of: the app's live ones; a render's own.
    var schema: @MainActor @Sendable () -> SettingsSchema = { .live }
    /// Jump back in (pilot-ui-redesign T6): the settings changed last, newest first, by key.
    var recent: @MainActor @Sendable () -> [String] = { HomeRecent.shared.keys }
    /// Keeps the settings a page's visit changed, newest first.
    var remember: @MainActor @Sendable ([String]) -> Void = { HomeRecent.shared.remember($0) }
}

extension EnvironmentValues {
    @Entry var homeSources = HomeSources()
}

/// Jump back in's record (pilot-ui-redesign T6, Open question 5 answered 2026-11-19): the window reads a page's settings as
/// it opens and again as it leaves (InstrumentFrame), and keeps the keys whose value changed, newest first, in Pilot's
/// defaults. A change made with `pilot set` or a key press shows only if it lands while its page is open. Home's own four
/// switches and secrets are never kept, and Home itself is never read, so opening the window on Home opens no store.
@Observable @MainActor
final class HomeRecent {
    static let shared = HomeRecent(defaults: .pilot())

    /// Where the keys are kept.
    static let key = "home.recentSettings"
    /// The most kept.
    static let most = 6

    private(set) var keys: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.key) ?? []
    }

    func remember(_ changed: [String]) {
        guard !changed.isEmpty else { return }
        keys = Array((changed + keys.filter { !changed.contains($0) }).prefix(Self.most))
        defaults.set(keys, forKey: Self.key)
    }

    /// `page`'s settings and their values now, the four switches and secrets aside.
    static func values(of page: AppPage, schema: SettingsSchema) -> [String: JSONValue] {
        let four = Set(Dropdown.Switch.four.compactMap(\.settingKey))
        var values: [String: JSONValue] = [:]
        for setting in schema.sorted where setting.kind != .secret && !four.contains(setting.key) && AppPlace.named(setting.page)?.page == page {
            values[setting.key] = try? schema.get(setting.key)
        }
        return values
    }

    /// The keys whose value differs between the two reads.
    static func changed(from before: [String: JSONValue], to after: [String: JSONValue]) -> [String] {
        before.keys.sorted().filter { after[$0] != nil && after[$0] != before[$0] }
    }
}

/// One page's visit as Jump back in reads it: the page and its settings' values as it opened.
struct HomeVisit {
    let page: AppPage
    let values: [String: JSONValue]

    /// Opens `page`'s visit, none on Home; the schema is asked only for a page that is not Home.
    @MainActor static func opening(_ page: AppPage, schema: () -> SettingsSchema) -> HomeVisit? {
        page == .home ? nil : HomeVisit(page: page, values: HomeRecent.values(of: page, schema: schema()))
    }

    /// The keys the visit changed, read again as it ends.
    @MainActor func changed(schema: () -> SettingsSchema) -> [String] {
        HomeRecent.changed(from: values, to: HomeRecent.values(of: page, schema: schema()))
    }
}

/// What fixes a problem Home names: Pilot's tiler restarts here (card agent-bo-95423025), the rest open
/// the page that fixes them.
@MainActor
enum HomeFix {
    static func of(_ problem: HomeProblems.Problem, go: @escaping (AppPlace) -> Void,
                   restartTiler: @escaping @MainActor () -> Void) -> (title: String, run: @MainActor () -> Void)? {
        switch (problem.kind, problem.place) {
        case (.tiler, _): ("Restart Pilot's tiler", restartTiler)
        // Its Grant is Needs you on Pilot's front (simplify-pages T8): the button names what it opens, not the page.
        case (.accessibility, let place?): ("Grant Accessibility", { go(place) })
        case (_, let place?): ("Open \(place.title)", { go(place) })
        case (_, nil): nil
        }
    }
}

/// The line beside the Hyper switch, as Toybox's greeting says it.
@MainActor
enum HomeGreeting {
    /// "Good evening.": Home's greeting by the hour of `date` (shot 7c-home).
    static func good(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }

    /// The line beside the Hyper switch: first what the switch is, so it never reads as another's, then what needs you
    /// (its button follows), else what the layer key and tiling do.
    /// `tiler` names the tiler (TilerService.tilerName).
    static func line(hyperOn: Bool, problems: [HomeProblems.Problem], layerKey: String, workspace: String?, tiler: String) -> String {
        "Hyper is \(hyperOn ? "on" : "off"). " + rest(hyperOn: hyperOn, problems: problems, layerKey: layerKey, workspace: workspace, tiler: tiler)
    }

    private static func rest(hyperOn: Bool, problems: [HomeProblems.Problem], layerKey: String, workspace: String?, tiler: String) -> String {
        if problems.count > 1 { return "\(problems.count) things need you." }
        if let problem = problems.first {
            switch problem.kind {
            case .tiler: return "\(problem.title), so nothing tiles."
            case .accessibility: return "Accessibility is not granted, so Pilot sees no keys."
            case .secureInput: return "\(problem.title), so Hyper waits."
            case .error: return problem.title.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "."
            }
        }
        guard hyperOn else { return HyperToggle.offWords(layerKey: layerKey) }
        // No workspace and nothing that needs you: tiling is switched off (a new install's default).
        guard let workspace else { return "\(layerKey) is your Hyper key; tiling is off." }
        return "\(layerKey) is your Hyper key; \(tiler) is tiling workspace \(workspace)."
    }
}

// MARK: - Shared parts

/// A bind's keys: one cap with the layer key's sign and the key.
struct HomeKeys: View {
    @Environment(Engine.self) private var engine
    let key: String
    /// False for a plain combo, which shows its own keys.
    var hyper = true

    var body: some View {
        let symbol = engine.settings.layerKeys.symbol
        Kbd(text: hyper ? "\(symbol) \(key)" : key)
    }

    /// A trigger's key as a cap shows it: "↵" for Return, "␣" for Space, "Esc", "⌫", the sublayer's signs before it ("⇧N").
    static func cap(_ key: Key) -> String {
        key.hyper ? caps(key).joined() : key.label
    }

    /// A Hyper trigger's sublayer signs, then its key as a cap shows it; `space` names Space.
    static func caps(_ key: Key, space: String = "␣") -> [String] {
        let name = KeyNames.name(for: key.keyCode)
        let signs = [(Modifiers.shift, "⇧"), (.ctrl, "⌃"), (.alt, "⌥"), (.cmd, "⌘")].filter { !key.modifiers.isDisjoint(with: $0.0) }.map(\.1)
        return signs + [["Return": "↵", "Space": space, "Escape": "Esc", "Delete": "⌫"][name] ?? name]
    }
}

extension HomeKeys {
    /// A trigger as its caps: the layer key's and the key's, or a plain combo's own.
    init(trigger: Key) { self.init(key: Self.cap(trigger), hyper: trigger.hyper) }
}

/// The Hyper key's switch (engine.hyperSwitch, the dropdown's too): off, the layer key does what macOS says and plain
/// combos still run; on again at every launch.
struct HyperToggle: View {
    @Environment(Engine.self) private var engine
    var body: some View {
        Toggle("Hyper key", isOn: Binding(get: { engine.hyperSwitch.isOn }, set: { engine.hyperSwitch.set($0) }))
            .toggleStyle(.pilotSwitch)
            .help(engine.hyperSwitch.isOn ? "Turn the Hyper key off" : "Turn the Hyper key on")
    }

    /// What Hyper off leaves the layer key doing, as Home's line and the Pilot block say it.
    static func offWords(layerKey: String) -> String { "\(layerKey) does what macOS says; plain combos still run." }
}
