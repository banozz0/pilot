import Foundation

/// When an action ships (SPEC.md tiers).
public enum Tier: String, Codable, Sendable { case v1, v1_1, v2, no }

/// A group of actions with one mechanism. Omarchy's binding files map onto these one to one.
public enum Module: String, Codable, CaseIterable, Sendable {
    case engine, windows, workspaces, apps, captures, system, media, drive, dictation
    /// The Ring menu's openers (P74): `rings.open:<ring>`, held.
    case rings
}

/// One thing Pilot can do. Every action is bindable; defaults are a subset.
public struct Action: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let module: Module
    public let defaultKey: Key?
    public let tier: Tier
    /// Step actions (grow, volume) honour key repeat; one-shot actions ignore it.
    public let repeats: Bool
    /// What every caller but its key runs: the menu, pilot://run, Home. A held action's is its hold and release at once.
    public let run: @Sendable @MainActor () -> Void
    /// A held action (the menu bar peek, card agent-bo-95423008): true as its key goes down, false as that key comes up.
    public let hold: (@Sendable @MainActor (Bool) -> Void)?
    /// More words the Hyper+Space search matches besides the label ("feedback" for Report a bug).
    public let keywords: String?

    public init(id: String, label: String, module: Module, defaultKey: Key? = nil, tier: Tier = .v1,
                repeats: Bool = false, keywords: String? = nil, run: @escaping @Sendable @MainActor () -> Void) {
        self.id = id; self.label = label; self.module = module; self.defaultKey = defaultKey
        self.tier = tier; self.repeats = repeats; self.keywords = keywords; self.run = run; hold = nil
    }

    /// A held action; run any other way than by its key it lets go at once, so nothing is left held.
    public init(id: String, label: String, module: Module, defaultKey: Key? = nil, tier: Tier = .v1,
                hold: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.id = id; self.label = label; self.module = module; self.defaultKey = defaultKey
        self.tier = tier; repeats = false; keywords = nil; self.hold = hold
        run = { hold(true); hold(false) }
    }

    /// The same action under a new label or with a new run, every other field kept.
    public func with(label: String? = nil, run: (@Sendable @MainActor () -> Void)? = nil) -> Action {
        if let hold, run == nil { return Action(id: id, label: label ?? self.label, module: module, defaultKey: defaultKey, tier: tier, hold: hold) }
        return Action(id: id, label: label ?? self.label, module: module, defaultKey: defaultKey, tier: tier, repeats: repeats, keywords: keywords,
                      run: run ?? self.run)
    }
}

/// Modules register their actions here; the Binds screen and Learn → Keybindings render from it. The default keys are
/// the bind store's defaults (BindStore), which holds the binds the tap runs.
public struct ActionRegistry: Sendable {
    public private(set) var actions: [String: Action] = [:]
    /// Action id → default key.
    public private(set) var defaults: [String: Key] = [:]

    public init() {}

    public enum RegistrationError: Error, Equatable { case duplicateId(String), keyTaken(Key, by: String) }

    /// Registers an action and its default key. Refuses a second action on the same id or default key: a key never
    /// does two things.
    public mutating func register(_ action: Action) throws(RegistrationError) {
        if actions[action.id] != nil { throw .duplicateId(action.id) }
        if let key = action.defaultKey, let taken = defaults.first(where: { $0.value == key })?.key { throw .keyTaken(key, by: taken) }
        actions[action.id] = action
        if let key = action.defaultKey { defaults[action.id] = key }
    }

    public var sorted: [Action] { actions.values.sorted { $0.id < $1.id } }
}

/// Action ids that are gone, by the id that took their place: the bind file, aliases, frecency and favourites read an
/// old id as its new one, so a bind or a menu row saved under it keeps working.
public enum RetiredActions {
    /// Q369 (Sven, 2026-10-20): one colour picker, the capture magnifier's.
    public static let renamed = ["system.colourPicker": "captures.pickColour"]

    public static func current(_ id: String) -> String { renamed[id] ?? id }

    /// A menu row's key (MenuEntry.Target.key, `action:<id>`) with its action's current id.
    public static func current(key: String) -> String {
        guard key.hasPrefix("action:") else { return key }
        return "action:" + current(String(key.dropFirst("action:".count)))
    }
}
