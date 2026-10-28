import Foundation

/// Every bind (stories 29 and 50; SPEC.md, Bind store): the active preset's default keys plus the keys set in it, one
/// trigger doing one thing. The file lists every action's trigger, so a reader outside Pilot sees the whole table, and
/// marks the ones set by hand as custom; each preset's own list of those is what is read back.
public struct BindStore: Equatable, Sendable {
    /// The file's schema version. A change of shape adds a case to `file(from:)`, never a second format.
    public static let version = 3

    public enum BindError: Error, Equatable { case triggerTaken(Key, by: String) }
    public enum LoadError: Error, Equatable { case newerVersion(Int), unreadable(String) }

    /// A bind the last load could not keep, because another held its trigger first.
    public struct Refusal: Equatable, Sendable {
        public var action: String, trigger: Key, takenBy: String
        public init(action: String, trigger: Key, takenBy: String) { self.action = action; self.trigger = trigger; self.takenBy = takenBy }
    }

    /// The key tables a preset starts from (story 149): Pilot default, the starter that ships; My binds, Sven's layout,
    /// listed only for a file that already holds it (`holdsMyBinds`); empty, Start from scratch's.
    public enum Base: String, CaseIterable, Sendable {
        case pilot, myBinds, empty
        /// The built-in preset on this base; empty has none.
        public var builtIn: Preset? {
            switch self { case .pilot: .pilot; case .myBinds: .myBinds; case .empty: nil }
        }
    }

    /// A named bind set (story 149): a base table plus the keys set in it, which stay with it. The built-ins are one per
    /// base but empty and keep their names; the rest come from New preset or an import, and can be renamed and deleted.
    public struct Preset: Hashable, Sendable, Identifiable {
        public var id: String, name: String, base: Base
        public init(id: String, name: String, base: Base) { self.id = id; self.name = name; self.base = base }
        public static let pilot = Preset(id: "pilot", name: "Pilot default", base: .pilot)
        public static let myBinds = Preset(id: "myBinds", name: "My binds", base: .myBinds)
        public var title: String { name }
        public var isBuiltIn: Bool { id == base.rawValue }
    }

    /// One preset's keys set by hand: action id → trigger, nil where the action was unbound, and those switched off.
    struct Edits: Equatable, Sendable {
        var custom: [String: Key?] = [:], disabled: Set<String> = []
    }

    private let tables: [Base: [String: Key]]
    /// Every preset, the built-ins first, in the order the picker lists them.
    public private(set) var presets: [Preset]
    public private(set) var preset: Preset
    private var defaults: [String: Key] { tables[preset.base] ?? [:] }
    /// The other presets' keys while they are not active, by preset id.
    private var stashed: [String: Edits] = [:]
    /// Every registered action, so one with no default key still gets its row in the file.
    private let registered: Set<String>
    /// The active preset's keys set by hand: action id → trigger, nil where it was unbound. Never two on one trigger.
    private var custom: [String: Key?] = [:]
    /// Trigger → action id, what the tap runs.
    public private(set) var binds: [Key: String] = [:]
    private var triggers: [String: Key] = [:]
    public private(set) var refused: [Refusal] = []
    /// Imported shell, URL, Shortcuts and picker binds (story 58): each keeps its key and does nothing until turned on.
    private var disabled: Set<String> = []
    /// Sven's app binds (story 143), by bundle id then trigger: kept across presets, and for apps not installed.
    private var apps: [String: [Key: AppBind]] = [:]
    /// Mouse buttons (Q184, MouseKeys): trigger → action, kept across presets as the mouse is, and apart from the key
    /// table, so a button runs an action that keeps its own key too.
    private var mouse: [Key: MouseBind] = [:]

    /// A mouse bind: its action, and for a media key or a key the mouse sends the device it was caught from.
    public struct MouseBind: Equatable, Sendable {
        public var action: String, device: MouseKeys.Device?
        /// The drawn button that sends a media key or a key, as the mouse's own app (NGenuity) sets it: Binds › Mouse shows
        /// the bind on that button. Nil for a plain button, which is its own.
        public var button: Int?
        public init(action: String, device: MouseKeys.Device?, button: Int? = nil) {
            self.action = action; self.device = device; self.button = button
        }
    }
    /// The version of the file this store was read from; an older file is not written back only to say 3.
    public private(set) var fileVersion = BindStore.version
    /// Said once after a load that had to change something: a file on the Omarchy preset, which no longer ships.
    public private(set) var notice: String?

    /// A bind that holds in one app only (story 143): its own action on a trigger there, or nil, off here, so the key
    /// reaches the app itself. It wins over the normal bind on that trigger while the app is in front.
    public struct AppBind: Equatable, Hashable, Sendable {
        public var app: String, trigger: Key, action: String?
        /// Imported and not turned on yet (story 58): the tap holds its key and pressing it does nothing.
        public var disabled = false
        /// An app shortcut's (story 151): the menu item's own shortcut when it was set, which finds the item again once
        /// an update moves it or its title flips.
        public var appKey: Key?
        public init(app: String, trigger: Key, action: String?, disabled: Bool = false, appKey: Key? = nil) {
            self.app = app; self.trigger = trigger; self.action = action; self.disabled = disabled; self.appKey = appKey
        }
    }

    /// `tables` holds each base's default keys; a built-in preset is listed for each one given, empty aside. `actions`
    /// names every registered action, so one with no default key still gets its row in the file. The first built-in,
    /// Pilot default where it is given, is active.
    public init(presets tables: [Base: [String: Key]], actions: [String] = []) {
        self.tables = tables
        presets = Base.allCases.compactMap { tables[$0] != nil ? $0.builtIn : nil }
        preset = presets.first ?? .myBinds
        registered = Set(actions)
        rebuild()
    }

    /// One bind set, as My binds.
    public init(defaults: [String: Key], actions: [String] = []) {
        self.init(presets: [.myBinds: defaults], actions: actions)
    }

    /// Reads a file of any version up to this one. A hand-edited file with two binds on one trigger keeps the first. A
    /// file before version 3 holds one preset's keys: My binds', or the one it names; Omarchy's land on My binds, with a
    /// notice, since Omarchy no longer ships.
    public init(json: Data, presets tables: [Base: [String: Key]], actions: [String] = []) throws(LoadError) {
        self.init(presets: tables, actions: actions)
        let file = try Self.file(from: json)
        fileVersion = file.version
        var all: [String: Edits] = [:], refusals: [String: [Refusal]] = [:]
        if let rows = file.presets {
            for row in rows {
                let base = try row.resolvedBase
                if !presets.contains(where: { $0.id == row.id }) {
                    guard !Base.allCases.map(\.rawValue).contains(row.id) else { throw .unreadable("preset \(row.id)") }
                    presets.append(Preset(id: row.id, name: row.name, base: base))
                }
                (all[row.id], refusals[row.id]) = try Self.edits(row.binds)
            }
        }
        let named = file.preset ?? Preset.myBinds.id
        if let found = presets.first(where: { $0.id == named }) {
            preset = found
        } else if file.version < 3, named == "omarchy", presets.contains(.myBinds) {
            preset = .myBinds
            notice = "Omarchy no longer ships with Pilot: My binds is on, with your keys. Import Omarchy to get it back."
        } else {
            throw .unreadable("preset \(named)")
        }
        if file.presets == nil { (all[preset.id], refusals[preset.id]) = try Self.edits(file.binds) }
        let active = all.removeValue(forKey: preset.id) ?? Edits()
        (custom, disabled, stashed) = (active.custom, active.disabled, all.filter { $0.value != Edits() })
        // A hand-edited file with two rows on one trigger in one app keeps the first.
        for row in file.apps ?? [] {
            let key = try row.trigger.resolved
            if apps[row.app]?[key] == nil {
                apps[row.app, default: [:]][key] = AppBind(app: row.app, trigger: key, action: row.action, disabled: row.disabled == true,
                                                           appKey: try row.appKey.map { t throws(LoadError) in try t.resolved })
            }
        }
        // A hold's row names the trigger held (P74).
        for (row, held) in (file.mouse ?? []).map({ ($0, false) }) + (file.holds ?? []).map({ ($0, true) }) {
            let named = try row.trigger.resolved
            guard MouseKeys.isMouse(named.keyCode), !held || !MouseKeys.isHold(named.keyCode) else { throw .unreadable("mouse trigger \(row.trigger.key)") }
            let key = held ? MouseKeys.hold(named) : named
            // A plain scroll, hand-written, is left out: the wheel is bound under Hyper only.
            if mouse[key] == nil, MouseKeys.isTrigger(key) { mouse[key] = MouseBind(action: row.action, device: row.device, button: Self.sender(row.button, of: key)) }
        }
        rebuild()
        refused = (refusals[preset.id] ?? []) + refused
    }

    public init(json: Data, defaults: [String: Key], actions: [String] = []) throws(LoadError) {
        try self.init(json: json, presets: [.myBinds: defaults], actions: actions)
    }

    /// A preset's custom rows: the first of two on one trigger stays, the other is refused.
    private static func edits(_ rows: [Row]) throws(LoadError) -> (Edits, [Refusal]) {
        var edits = Edits(), taken: [Key: String] = [:], refusals: [Refusal] = []
        for row in rows where row.custom {
            let key = try row.trigger.map { t throws(LoadError) in try t.resolved }
            if let key, let first = taken[key] { refusals.append(Refusal(action: row.action, trigger: key, takenBy: first)); continue }
            if let key { taken[key] = row.action }
            edits.custom[row.action] = .some(key)
            if row.disabled == true { edits.disabled.insert(row.action) }
        }
        return (edits, refusals)
    }

    // MARK: presets (story 149)

    /// Switches to `preset`: its default keys and the keys set in it. The keys set in the one left stay with it, and app
    /// binds stay as they are.
    public mutating func use(_ preset: Preset) {
        guard let target = presets.first(where: { $0.id == preset.id }) else { return }
        let left = Edits(custom: custom, disabled: disabled)
        stashed[self.preset.id] = left == Edits() ? nil : left
        let edits = stashed.removeValue(forKey: target.id) ?? Edits()
        (self.preset, custom, disabled) = (target, edits.custom, edits.disabled)
        rebuild()
    }

    public func preset(id: String) -> Preset? { presets.first { $0.id == id } }

    /// New preset: from scratch (empty but the Pilot menu), or a copy of the active one with the keys set in it. It is
    /// named `name`, or that with a number when another has the name, and becomes the active one.
    @discardableResult
    public mutating func addPreset(named name: String, copying: Bool) -> Preset {
        let edits = copying ? Edits(custom: custom, disabled: disabled) : Edits()
        return add(Preset(id: "", name: name, base: copying ? preset.base : .empty), edits)
    }

    /// New preset on `base`'s default keys alone, none of the keys set in any preset (Ask Pilot's /preset, Q327): it
    /// becomes the active one. Nil when this store has no table for `base` (My binds on a file that never held it).
    @discardableResult
    public mutating func addPreset(named name: String, base: Base) -> Preset? {
        guard tables[base] != nil else { return nil }
        return add(Preset(id: "", name: name, base: base), Edits())
    }

    private mutating func add(_ draft: Preset, _ edits: Edits) -> Preset {
        let name = freeName(draft.name)
        let slug = Notes.slug(name)
        var id = slug, n = 2
        while preset(id: id) != nil || Base(rawValue: id) != nil { id = "\(slug)-\(n)"; n += 1 }
        let new = Preset(id: id, name: name, base: draft.base)
        presets.append(new)
        stashed[id] = edits
        use(new)
        return new
    }

    /// `name` trimmed, or "Untitled", with " 2", " 3"… when another preset than `except` has it.
    private func freeName(_ name: String, except: String? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        let taken = Set(presets.filter { $0.id != except }.map { $0.name.lowercased() })
        var candidate = base, n = 2
        while taken.contains(candidate.lowercased()) { candidate = "\(base) \(n)"; n += 1 }
        return candidate
    }

    /// Renames a preset made with New preset or an import; a built-in keeps its name. False when nothing changed.
    @discardableResult
    public mutating func renamePreset(_ target: Preset, to name: String) -> Bool {
        guard let i = presets.firstIndex(where: { $0.id == target.id }), !presets[i].isBuiltIn else { return false }
        let new = freeName(name, except: target.id)
        guard new != presets[i].name else { return false }
        presets[i].name = new
        if preset.id == target.id { preset.name = new }
        return true
    }

    /// Deletes a preset made with New preset or an import, and the keys set in it; the active one gives way to the
    /// first built-in. False for a built-in.
    @discardableResult
    public mutating func deletePreset(_ target: Preset) -> Bool {
        guard let found = preset(id: target.id), !found.isBuiltIn else { return false }
        if preset.id == found.id, let first = presets.first { use(first) }
        presets.removeAll { $0.id == found.id }
        stashed[found.id] = nil
        return true
    }

    /// A bind file's active preset added as a new one (Import's Add as preset): its name, or `name` for a file before
    /// version 3, its base and the keys set in it, which become the active preset. App binds are not part of a preset.
    @discardableResult
    public mutating func importPreset(_ json: Data, name: String) throws(LoadError) -> Preset {
        let file = try Self.file(from: json)
        if let rows = file.presets {
            guard let row = rows.first(where: { $0.id == file.preset }) ?? rows.first else { throw .unreadable("no preset") }
            return add(Preset(id: "", name: row.name, base: try row.resolvedBase), try Self.edits(row.binds).0)
        }
        let base: Base = tables[.myBinds] != nil ? .myBinds : .empty
        return add(Preset(id: "", name: name, base: base), try Self.edits(file.binds).0)
    }

    /// The action a key or a mouse trigger runs.
    public func action(for key: Key) -> String? { binds[key] ?? mouse[key]?.action }

    // MARK: mouse buttons (Q184)

    /// Every mouse bind, by trigger.
    public var mouseBinds: [(trigger: Key, bind: MouseBind)] {
        // A button's plain bind before its Hyper one, so the file's order never flips between launches (P51).
        mouse.sorted { ($0.key.keyCode, $0.key.hyper ? 1 : 0) < ($1.key.keyCode, $1.key.hyper ? 1 : 0) }.map { ($0.key, $0.value) }
    }

    /// Binds a mouse trigger to `action` from `device` (a media key's), or frees it with nil; another mouse trigger on that
    /// action keeps it. A button holds one bind (Q257), one under Hyper (P51) and one held (P74): binding on it frees its own
    /// trigger and any media key tied to it, of the same kind as the new one. A plain scroll is refused.
    public mutating func setMouse(_ key: Key, to action: String?, device: MouseKeys.Device? = nil, button: Int? = nil) {
        guard MouseKeys.isTrigger(key) else { return }
        let bind = action.map { MouseBind(action: $0, device: device, button: Self.sender(button, of: key)) }
        func kind(_ k: Key) -> (Bool, Bool) { (k.hyper, MouseKeys.isHold(k.keyCode)) }
        if let on = bind.flatMap({ MouseKeys.number(MouseKeys.plain(key)) ?? $0.button }) {
            let held = mouse.filter { $0.key != key && kind($0.key) == kind(key) && (MouseKeys.number(MouseKeys.plain($0.key)) == on || $0.value.button == on) }.keys
            for other in held { mouse[other] = nil }
        }
        mouse[key] = bind
    }

    /// The drawn button a media key or a key the mouse sends, or its hold, sits on: only those have one, and only a button
    /// past the main clicks that a CGEvent numbers (3 to 32).
    private static func sender(_ button: Int?, of key: Key) -> Int? {
        guard MouseKeys.isSent(MouseKeys.plain(key).keyCode), let button, (3...32).contains(button) else { return nil }
        return button
    }

    /// What `key` runs with `app` in front: the app's own bind first, nil where it is off there, then the normal bind.
    public func action(for key: Key, app: String?) -> String? { bind(for: key, app: app)?.action }

    /// The bind the tap runs for `key` with `app` in front, and whether it is an imported app bind not turned on yet
    /// (a normal bind's switched-off state is its action's, `isDisabled(_:)`).
    public func bind(for key: Key, app: String?) -> (action: String, disabled: Bool)? {
        if let app, let own = apps[app]?[key] { return own.action.map { ($0, own.disabled) } }
        return binds[key].map { ($0, false) }
    }

    /// The key `action` has with `app` in front: the app's own key for it, else its normal key unless the app's binds
    /// take that key over.
    public func trigger(for action: String, app: String?) -> Key? {
        guard let app, let rules = apps[app] else { return triggers[action] }
        if let own = rules.filter({ $0.value.action == action }).keys.min(by: { $0.label < $1.label }) { return own }
        return triggers[action].flatMap { rules[$0] == nil ? $0 : nil }
    }

    /// Every app bind, by app then key.
    public var appBinds: [AppBind] {
        apps.keys.sorted().flatMap(appBinds(in:))
    }

    public func appBinds(in app: String) -> [AppBind] {
        (apps[app] ?? [:]).values.sorted { $0.trigger.label < $1.trigger.label }
    }

    public func appBind(_ key: Key, in app: String) -> AppBind? { apps[app]?[key] }

    /// Binds `key` in `app` to `action`, or off there with nil; `old`, when the editor moved the bind from another key
    /// in that app, is freed. Refused, store unchanged, while another of that app's binds holds the key (by "" when that
    /// one is off here); an app bind over a normal bind's key is an override, never a clash.
    /// `appKey` is the menu item's own shortcut, for an app shortcut (story 151).
    public mutating func set(_ key: Key, in app: String, to action: String?, from old: Key? = nil, appKey: Key? = nil) throws(BindError) {
        if let other = apps[app]?[key], key != old { throw .triggerTaken(key, by: other.action ?? "") }
        setApp(key, in: app, to: action, from: old, appKey: appKey)
    }

    /// Binds `key` in `app` whatever held it there: the editor's Replace. Returns the app bind it displaced.
    @discardableResult
    public mutating func replace(_ key: Key, in app: String, with action: String?, from old: Key? = nil, appKey: Key? = nil) -> AppBind? {
        let other = key == old ? nil : appBind(key, in: app)
        setApp(key, in: app, to: action, from: old, appKey: appKey)
        return other
    }

    /// Drops one app bind; the app's normal binds hold that key again. False when there was none.
    @discardableResult
    public mutating func remove(_ key: Key, in app: String) -> Bool {
        guard apps[app]?.removeValue(forKey: key) != nil else { return false }
        if apps[app]?.isEmpty == true { apps[app] = nil }
        return true
    }

    public mutating func enable(_ key: Key, in app: String) { apps[app]?[key]?.disabled = false }

    private mutating func setApp(_ key: Key, in app: String, to action: String?, from old: Key?, appKey: Key?) {
        if let old, old != key { apps[app]?[old] = nil }
        apps[app, default: [:]][key] = AppBind(app: app, trigger: key, action: action, appKey: appKey)
    }

    public func trigger(for action: String) -> Key? { triggers[action] }
    /// Why `action` has no key: its default, which another action holds (Sven's own key or an earlier default).
    public func refusal(for action: String) -> Refusal? { refused.first { $0.action == action } }

    public func isCustom(_ action: String) -> Bool { custom.keys.contains(action) }

    /// The key the active preset's layout gives `action`, whatever was set by hand: what Reset puts back.
    public func defaultTrigger(for action: String) -> Key? { defaults[action] }

    /// An imported bind not turned on yet: the tap still holds its key, and pressing it does nothing.
    public func isDisabled(_ action: String) -> Bool { disabled.contains(action) }

    public var switchedOff: [String] { disabled.sorted() }

    public mutating func enable(_ action: String) { disabled.remove(action) }

    /// Every action the file lists: the registered ones, the active preset's (its app and web binds included) and the
    /// ones Sven set, those he left with no key included.
    public var actions: [String] { Set(defaults.keys).union(registered).union(custom.keys).sorted() }

    /// The action holding `key`, unless it is `action` itself or `old`, the bind being edited, which gives the key up:
    /// the clash the Binds screen warns about.
    public func clash(_ key: Key, for action: String, from old: String? = nil) -> String? {
        binds[key].flatMap { $0 == action || $0 == old ? nil : $0 }
    }

    /// Binds `action` to `key`, or unbinds it with nil; `old`, when the editor changed what a bind runs, is left with no
    /// key. Refused, store unchanged, when another action holds the key.
    public mutating func set(_ action: String, to key: Key?, from old: String? = nil) throws(BindError) {
        if let key, let other = clash(key, for: action, from: old) { throw .triggerTaken(key, by: other) }
        vacate(old, for: action)
        assign(action, key)
        rebuild()
    }

    /// Binds `action` to `key` and leaves whichever action held it with no key: the editor's Replace. Returns that action.
    @discardableResult
    public mutating func replace(_ action: String, with key: Key, from old: String? = nil) -> String? {
        let other = clash(key, for: action, from: old)
        if let other { custom[other] = .some(nil) }
        vacate(old, for: action)
        assign(action, key)
        rebuild()
        return other
    }

    /// A renamed action (a focus preset's `focus.session:<name>`) keeps its bind and its switched-off state, its app
    /// binds too; a name that already has its own bind is left alone.
    @discardableResult
    public mutating func rename(_ old: String, to new: String) -> Bool {
        guard old != new, !isCustom(new) else { return false }
        let inApps = mapAppBinds { var b = $0; if b.action == old { b.action = new }; return b }
        guard let key = custom.removeValue(forKey: old) else { return inApps }
        custom[new] = key
        if disabled.remove(old) != nil { disabled.insert(new) }
        rebuild()
        return true
    }

    /// Drops an action that is gone (a deleted focus preset's `focus.session:<name>`): its bind and its app binds leave
    /// the file and its key is free. False when it had no bind of its own.
    @discardableResult
    public mutating func remove(_ action: String) -> Bool {
        let inApps = mapAppBinds { $0.action == action ? nil : $0 }
        guard custom.removeValue(forKey: action) != nil else { return inApps }
        rebuild()
        return true
    }

    /// Every app bind through `change`, nil dropping it; true when any changed.
    private mutating func mapAppBinds(_ change: (AppBind) -> AppBind?) -> Bool {
        let before = apps
        apps = apps.compactMapValues { rules in
            let kept = rules.compactMapValues(change)
            return kept.isEmpty ? nil : kept
        }
        return apps != before
    }

    private mutating func vacate(_ old: String?, for action: String) {
        if let old, old != action { assign(old, nil) }
    }

    /// A trigger equal to the default is no custom bind.
    private mutating func assign(_ action: String, _ key: Key?) {
        if key == defaults[action] { custom[action] = nil } else { custom[action] = .some(key) }
    }

    /// Puts one action back on its default; refused while another action holds that default.
    public mutating func reset(_ action: String) throws(BindError) {
        if let key = defaults[action], let other = clash(key, for: action) { throw .triggerTaken(key, by: other) }
        custom[action] = nil
        rebuild()
    }

    public mutating func resetAll() {
        custom = [:]
        rebuild()
    }

    /// Sven's binds first, then each default on a trigger still free; a default that finds its trigger taken is refused.
    private mutating func rebuild() {
        binds = [:]
        refused = []
        disabled = disabled.filter(isCustom)
        for (action, key) in custom { if let key { binds[key] = action } }
        for (action, key) in defaults.sorted(by: { $0.key < $1.key }) where !isCustom(action) {
            if let other = binds[key] { refused.append(Refusal(action: action, trigger: key, takenBy: other)) } else { binds[key] = action }
        }
        triggers = Dictionary(uniqueKeysWithValues: binds.map { ($1, $0) })
    }

    // MARK: export and import (stories 41 and 58)

    /// Another Mac's bind file read against this store: its own binds only, never its defaults. A bind on a trigger one
    /// of Sven's own binds here holds is a clash and leaves his; a default here gives way, as it does to his own binds.
    public struct Import: Equatable, Sendable {
        public struct Row: Equatable, Sendable { public var action: String, trigger: Key? }
        public internal(set) var added: [Row] = [], changed: [Row] = [], clashes: [Refusal] = []
        /// App binds (story 143) new or changed here, and those whose key one of Sven's own binds in that app holds.
        public internal(set) var apps: [AppBind] = [], appClashes: [AppBind] = []

        /// The new binds that arrive switched off. A changed one is a command this Mac already has on another key, so it
        /// stays on or off as it is.
        public var switchedOff: [String] { added.map(\.action).filter(BindStore.arrivesOff) }
        /// The app binds that arrive switched off, by the same rule.
        public var appsSwitchedOff: [AppBind] { apps.filter { $0.action.map(BindStore.arrivesOff) ?? false } }

        /// "pilot-export.json: 12 new binds, 3 changed, 1 clash (Hyper+Shift+T). …", the wireframe's preview line.
        public func summary(name: String) -> String {
            func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            let keys = clashes.isEmpty ? "" : " (" + clashes.map(\.trigger.label).joined(separator: ", ") + ")"
            let off = switchedOff.count + appsSwitchedOff.count
            let offLine = off == 0 ? "" : " \(count(off, "shell, URL or Shortcuts bind stays", "shell, URL or Shortcuts binds stay")) "
                + "switched off until you turn \(off == 1 ? "it" : "them") on."
            let appLine = apps.isEmpty && appClashes.isEmpty ? ""
                : " \(count(apps.count, "app bind", "app binds"))\(appClashes.isEmpty ? "" : ", \(appClashes.count) kept as they are here")."
            return "\(name): \(count(added.count, "new bind", "new binds")), \(changed.count) changed, "
                + "\(count(clashes.count, "clash", "clashes"))\(keys).\(appLine)\(offLine)"
        }
    }

    public func plan(importing json: Data) throws(LoadError) -> Import {
        var plan = Import(), taken: [Key: String] = [:]
        let file = try Self.file(from: json)
        for row in file.apps ?? [] {
            let key = try row.trigger.resolved
            let bind = AppBind(app: row.app, trigger: key, action: row.action, appKey: try row.appKey.map { t throws(LoadError) in try t.resolved })
            guard !plan.apps.contains(where: { $0.app == bind.app && $0.trigger == key }) else { continue }
            // Sven's own bind on that key in that app stays, as his normal binds do.
            if let here = apps[row.app]?[key] { if here.action != row.action { plan.appClashes.append(bind) }; continue }
            plan.apps.append(bind)
        }
        for row in file.binds where row.custom {
            let key = try row.trigger.map { t throws(LoadError) in try t.resolved }
            guard key != trigger(for: row.action) else { continue }
            if let key {
                if let other = taken[key] ?? clash(key, for: row.action).flatMap({ isCustom($0) ? $0 : nil }) {
                    plan.clashes.append(Refusal(action: row.action, trigger: key, takenBy: other))
                    continue
                }
                taken[key] = row.action
            }
            let r = Import.Row(action: row.action, trigger: key)
            if isCustom(row.action) { plan.changed.append(r) } else { plan.added.append(r) }
        }
        return plan
    }

    /// Applies a plan: its new and changed binds become Sven's own, the shell, URL, Shortcuts and picker ones off.
    public mutating func apply(_ plan: Import) {
        for r in plan.added + plan.changed { assign(r.action, r.trigger) }
        disabled.formUnion(plan.switchedOff)
        for var b in plan.apps {
            b.disabled = b.action.map(Self.arrivesOff) ?? false
            apps[b.app, default: [:]][b.trigger] = b
        }
        rebuild()
    }

    /// Whether an imported bind arrives switched off: it runs a command or opens a URL (story 58), a script command
    /// and an extension command included. An app link to a web page stays on; one to any other scheme can reach a command (pilot://run,
    /// shortcuts://), so it does not.
    public static func arrivesOff(_ action: String) -> Bool {
        // A quicklink's URL is Sven's to set, to any scheme (card agent-bo-95423030).
        if Quicklink.parse(action) != nil { return true }
        if ScriptCommand.file(inAction: action) != nil || Extension.command(inAction: action) != nil { return true }
        switch AppLink(id: action) {
        case .web(let url)?, .url(_, let url)?: return !["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "")
        case .open?, .privateWindow?: return false
        case nil: break
        }
        switch DriveRoute(id: action) {
        case .shell?, .url?, .shortcut?, .picker?: return true
        default: return false
        }
    }

    /// `pilot://import?pack=<the file, base64url>`: a bind file someone can paste anywhere and Pilot opens.
    public static func link(for json: Data) -> URL {
        let pack = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var c = URLComponents()
        c.scheme = "pilot"; c.host = "import"; c.queryItems = [URLQueryItem(name: "pack", value: pack)]
        return c.url!
    }

    public static func pack(in url: URL) -> Data? {
        guard let pack = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pack" })?.value
        else { return nil }
        let base64 = pack.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }

    // MARK: the file

    /// The file; an older `version` is how a file of that version read in reads back unchanged: no presets list before
    /// 3, no apps list before 2.
    public func json(version: Int = BindStore.version) -> Data {
        let rows = actions.map {
            Row(action: $0, custom: isCustom($0), trigger: trigger(for: $0).map(Trigger.init), disabled: isDisabled($0))
        }
        let appRows = appBinds.map {
            AppRow(app: $0.app, action: $0.action, trigger: Trigger($0.trigger), disabled: $0.disabled, appKey: $0.appKey.map(Trigger.init))
        }
        var all = stashed
        all[preset.id] = Edits(custom: custom, disabled: disabled)
        let presetRows = version < 3 ? nil : presets.map { p in
            let edits = all[p.id] ?? Edits()
            return PresetRow(id: p.id, name: p.name, base: p.base.rawValue, binds: edits.custom.keys.sorted().map {
                Row(action: $0, custom: true, trigger: edits.custom[$0]!.map(Trigger.init), disabled: edits.disabled.contains($0))
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Written only when a mouse bind exists, so every other file reads as before; an older file gains them too, so a
        // mouse bind set on it is written at once.
        func mouseRows(holds: Bool) -> [MouseRow]? {
            let binds = mouseBinds.filter { MouseKeys.isHold($0.trigger.keyCode) == holds }
            return binds.isEmpty ? nil : binds.map {
                MouseRow(trigger: Trigger(MouseKeys.plain($0.trigger)), action: $0.bind.action, device: $0.bind.device, button: $0.bind.button)
            }
        }
        return try! encoder.encode(File(version: version, preset: preset.id, presets: presetRows, binds: rows,
                                        apps: version >= 2 ? appRows : nil, mouse: mouseRows(holds: false), holds: mouseRows(holds: true)))
    }

    /// A file without a preset (written before presets) is My binds; one without apps (version 1) has no app binds. From
    /// version 3, `presets` holds each preset's own keys, which is what is read back; `binds` is the active preset's
    /// whole table, for readers.
    /// `mouse` (Q184) is optional within version 3: a reader that does not know it skips it. So is `holds` (P74): a held
    /// trigger's binds, each row naming the trigger held, so a reader before it never meets a hold's name and keeps the rest.
    private struct File: Codable {
        var version: Int; var preset: String?; var presets: [PresetRow]?; var binds: [Row]; var apps: [AppRow]?
        var mouse: [MouseRow]? = nil
        var holds: [MouseRow]? = nil

        /// Every row on a retired action's id moved to the id that replaced it (RetiredActions). An old custom row takes
        /// the new id's place unless the new id has a custom row of its own; an old default row just goes.
        func retiring() -> File {
            func current(_ rows: [Row]) -> [Row] {
                var rows = rows
                for (old, new) in RetiredActions.renamed {
                    guard let i = rows.firstIndex(where: { $0.action == old }) else { continue }
                    if rows[i].custom, !rows.contains(where: { $0.action == new && $0.custom }) {
                        var row = rows[i]
                        row.action = new
                        rows.removeAll { $0.action == new }
                        rows.append(row)
                    }
                    rows.removeAll { $0.action == old }
                }
                return rows
            }
            var file = self
            file.binds = current(binds)
            file.presets = presets?.map { var p = $0; p.binds = current(p.binds); return p }
            file.apps = apps?.map { var a = $0; a.action = a.action.map { RetiredActions.current($0) }; return a }
            file.mouse = mouse?.map { var m = $0; m.action = RetiredActions.current(m.action); return m }
            file.holds = holds?.map { var m = $0; m.action = RetiredActions.current(m.action); return m }
            return file
        }
    }
    /// A mouse bind's row: `{"action": "media.next", "trigger": {"hyper": false, "key": "Mouse 4", "modifiers": []}}`.
    /// A media key's adds the device it was learnt from: `"device": {"vendor": 2385, "product": 5899, "name": "…"}`.
    /// A media key's may add the drawn button that sends it, `"button": 3`; a reader that does not know it skips it.
    private struct MouseRow: Codable { var trigger: Trigger, action: String, device: MouseKeys.Device?, button: Int? = nil }
    private struct PresetRow: Codable {
        var id: String, name: String, base: String, binds: [Row]
        var resolvedBase: Base {
            get throws(LoadError) {
                guard let b = Base(rawValue: base) else { throw .unreadable("preset \(id) base \(base)") }
                return b
            }
        }
    }
    /// v0 has no version field.
    private struct Version: Decodable { var version: Int? }

    private struct Row: Codable {
        var action: String, custom: Bool, trigger: Trigger?
        /// Written only when true, so a file with nothing switched off is the same as before.
        var disabled: Bool? = nil
        // An unbound action says so: "trigger" : null, never a missing field.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(action, forKey: .action); try c.encode(custom, forKey: .custom); try c.encode(trigger, forKey: .trigger)
            if disabled == true { try c.encode(true, forKey: .disabled) }
        }
    }

    /// An app bind's row (version 2): `"action" : null` is off in that app. `custom` is always true, the binds rows' shape.
    private struct AppRow: Codable {
        var app: String, action: String?, custom = true, trigger: Trigger
        var disabled: Bool? = nil
        /// An app shortcut's item's own shortcut (story 151), written only when there is one.
        var appKey: Trigger? = nil
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(app, forKey: .app); try c.encode(action, forKey: .action); try c.encode(custom, forKey: .custom)
            try c.encode(trigger, forKey: .trigger)
            if disabled == true { try c.encode(true, forKey: .disabled) }
            if let appKey { try c.encode(appKey, forKey: .appKey) }
        }
    }

    /// `{"hyper": true, "key": "X", "modifiers": ["shift"]}`; a plain combo has hyper false and may name a side ("leftAlt").
    private struct Trigger: Codable {
        var hyper: Bool, key: String, modifiers: [String]

        init(_ key: Key) { hyper = key.hyper; self.key = KeyNames.name(for: key.keyCode); modifiers = key.modifiers.names }
        init(hyper: Bool, key: String, modifiers: [String]) { self.hyper = hyper; self.key = key; self.modifiers = modifiers }

        var resolved: Key {
            get throws(LoadError) {
                guard let code = KeyNames.code(for: key), let mods = Modifiers(names: modifiers) else {
                    throw .unreadable("trigger \(modifiers) \(key)")
                }
                return Key(keyCode: code, modifiers: mods, hyper: hyper)
            }
        }
    }

    /// v0, before sublayers: no version field, binds by action id, a trigger was a Hyper key code and a shift flag.
    private struct V0: Decodable {
        struct Trigger: Decodable { var keyCode: Int64, shift: Bool }
        var binds: [String: Trigger?]
    }

    /// Whether a bind file needs My binds' table (SH8): it is on My binds, names no preset (a file before presets), lands
    /// on it from Omarchy, or holds a preset made from it: `init(json:)`'s preset pick. A new user's never does, so Pilot
    /// lists My binds only for a file that already holds it; a file it cannot read runs Pilot default either way.
    public static func holdsMyBinds(_ json: Data) -> Bool {
        guard let file = try? file(from: json) else { return false }
        let named = file.preset ?? Preset.myBinds.id
        return named == Preset.myBinds.id || (file.version < 3 && named == "omarchy")
            || file.presets?.contains { $0.base == Base.myBinds.rawValue } == true
    }

    /// The migrations: each older version is read in its own shape and brought to this one.
    private static func file(from json: Data) throws(LoadError) -> File {
        do {
            let version = try JSONDecoder().decode(Version.self, from: json).version ?? 0
            switch version {
            case 0:
                let rows = try JSONDecoder().decode(V0.self, from: json).binds.sorted { $0.key < $1.key }.map { action, t in
                    Row(action: action, custom: true, trigger: t.map {
                        Trigger(hyper: true, key: KeyNames.name(for: $0.keyCode), modifiers: $0.shift ? ["shift"] : [])
                    })
                }
                return File(version: 0, binds: rows).retiring()
            // Version 1 is version 2 without the apps list, version 2 is 3 without the presets list.
            case 1, 2, Self.version:
                var file = try JSONDecoder().decode(File.self, from: json)
                file.version = version
                if version < 3 { file.presets = nil }
                return file.retiring()
            default: throw LoadError.newerVersion(version)
            }
        } catch let error as LoadError {
            throw error
        } catch {
            throw .unreadable(String(describing: error))
        }
    }
}
