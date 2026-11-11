import Foundation

/// What the Binds screen shows (story 28, wireframe mSEMT3YCZpU sections 2 to 4): a section per sublayer, the other
/// Hyper keys, the plain combos (story 51) and the actions with no key, so every action is listed, and the clash the
/// editor shows before anything is saved.
public enum BindsPage {
    /// The modifiers held with Hyper that make a section of their own. Other sets (Hyper+Shift+Alt) go under Other Hyper keys.
    public enum Sublayer: CaseIterable, Sendable {
        case hyper, shift, ctrl, alt, shiftCtrl

        public var modifiers: Modifiers {
            switch self {
            case .hyper: []
            case .shift: .shift
            case .ctrl: .ctrl
            case .alt: .alt
            case .shiftCtrl: [.shift, .ctrl]
            }
        }

        /// The sublayer a trigger's modifiers make; nil for a set with none.
        public init?(modifiers: Modifiers) {
            guard let s = Self.allCases.first(where: { $0.modifiers == modifiers }) else { return nil }
            self = s
        }

        /// "Hyper+Shift+Ctrl"
        public var title: String { (["Hyper"] + modifiers.labels).joined(separator: "+") }
    }

    public enum Tab: Hashable, Sendable {
        /// `otherHyper`: Hyper with a set of modifiers no sublayer names, such as Hyper+Shift+Alt.
        case layer(Sublayer), otherHyper, plain, unbound

        /// The page's sections, top to bottom.
        public static let sections: [Tab] = Sublayer.allCases.map(Tab.layer) + [.otherHyper, .plain, .unbound]

        public var title: String {
            switch self {
            case .layer(let s): s.title
            case .otherHyper: "Other Hyper keys"
            case .plain: AppSection.plainCombos.title
            case .unbound: "Not bound"
            }
        }

        /// For a narrow window: what the sublayer adds to Hyper, "+Shift".
        public var shortTitle: String {
            switch self {
            case .layer(.hyper), .otherHyper, .plain, .unbound: title
            case .layer(let s): "+" + s.modifiers.labels.joined(separator: "+")
            }
        }

        /// One line under the heading saying what the section holds, where its title alone does not: what a plain combo
        /// is, with two (card agent-bo-95422786). A section with one shows even when empty, so the page can say it.
        public var explanation: String? {
            guard self == .plain else { return nil }
            return "A plain combo is a bind without Hyper: hold Cmd, Ctrl or Alt and press a key, such as "
                + "\(Key("h", .leftAlt, hyper: false).label) or \(Key("x", [.cmd, .ctrl], hyper: false).label). "
                + "Left and right count apart, and Pilot takes the combo in every app."
        }

        /// A sublayer's heading names the modifiers, so its rows show the key alone.
        public var keysAlone: Bool { if case .layer = self { true } else { false } }

        public func holds(_ key: Key?) -> Bool {
            switch self {
            case .layer(let s): key.map { $0.hyper && $0.modifiers == s.modifiers } ?? false
            case .otherHyper: key.map { $0.hyper && Sublayer(modifiers: $0.modifiers) == nil } ?? false
            case .plain: key.map { !$0.hyper } ?? false
            case .unbound: key == nil
            }
        }
    }

    /// An action as the page names it; the app passes registered actions and the ones made from the app picker.
    public struct ActionInfo: Sendable {
        public var id: String, label: String, module: String
        /// The menu row's icon when its id alone does not say (a script command's).
        public var icon: MenuIcon?
        /// More words the menu's search matches (Action's keywords).
        public var keywords: String?
        public init(id: String, label: String, module: String, icon: MenuIcon? = nil, keywords: String? = nil) {
            self.id = id; self.label = label; self.module = module; self.icon = icon; self.keywords = keywords
        }
    }

    /// `actions` with `rows` among them, an action already listed (a bound script or extension command) replaced by its
    /// row so it wears its icon.
    public static func adding(_ rows: [ActionInfo], to actions: [ActionInfo]) -> [ActionInfo] {
        let ids = Set(rows.map(\.id))
        return actions.filter { !ids.contains($0.id) } + rows
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        /// The key alone, "T", where the heading names the modifiers; elsewhere the whole trigger, "Left Alt+V".
        public var key: String?
        public var label: String, module: String
        /// Sven set it, so it can be reset.
        public var custom: Bool
        /// What a plain combo takes from macOS or from typing (PlainComboShadow).
        public var warning: String?
        public init(id: String, key: String?, label: String, module: String, custom: Bool, warning: String? = nil) {
            self.id = id; self.key = key; self.label = label; self.module = module; self.custom = custom; self.warning = warning
        }
    }

    /// Every action the page lists: the registered ones, then the app and URL binds the store keeps, made from the
    /// picker or set by the active preset, named by `info`; one left with no key stays listed under Not bound, so it
    /// can be bound again.
    public static func actions(registered: [ActionInfo], store: BindStore, info: (String) -> ActionInfo?) -> [ActionInfo] {
        let known = Set(registered.map(\.id))
        let own = Set(store.actions).subtracting(known)
        return registered + own.sorted().compactMap(info)
    }

    /// The rows under `tab`, by module and label (the hold-Hyper overlay's page).
    public static func rows(store: BindStore, actions: [ActionInfo], tab: Tab) -> [Row] {
        rows(store: store, actions: actions, tab: tab) { _ in true }
    }

    /// The rows under `tab` whose action, module or whole key passes `test`, by module and label; a key shows alone
    /// where the heading names its modifiers.
    private static func rows(store: BindStore, actions: [ActionInfo], tab: Tab, test: ([String]) -> Bool) -> [Row] {
        actions.compactMap { a -> Row? in
            let key = store.trigger(for: a.id)
            guard tab.holds(key) else { return nil }
            if !test([a.label, a.module, key?.label ?? ""]) { return nil }
            return Row(id: a.id, key: key.map { tab.keysAlone ? KeyNames.name(for: $0.keyCode) : $0.label }, label: a.label,
                       module: a.module, custom: store.isCustom(a.id), warning: key.flatMap(PlainComboShadow.warning))
        }
        .sorted { ($0.module, $0.label) < ($1.module, $1.label) }
    }

    /// One section of the page: a layer's heading and its rows.
    public struct Section: Identifiable, Equatable, Sendable {
        public var tab: Tab
        public var rows: [Row]
        public var id: Tab { tab }
    }

    /// The page as one list (card agent-bo-95422785): a section per layer, in Tab.sections order, so every action is in
    /// exactly one. `only` narrows it to one section; a search ignores `only` and keeps each hit under its own layer. A
    /// section with no rows is left out, except one with an explanation when nothing is searched, so the page can say it.
    /// Keys show alone under a sublayer's heading and whole where the heading does not name the modifiers.
    public static func sections(store: BindStore, actions: [ActionInfo], only: Tab? = nil, search: String = "") -> [Section] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let tabs = query.isEmpty ? only.map { [$0] } ?? Tab.sections : Tab.sections, filter = FuzzyRanker.Filter(query)
        func found(_ test: ([String]) -> Bool) -> [Section] {
            tabs.compactMap { tab in
                let rows = rows(store: store, actions: actions, tab: tab, test: test)
                let keepEmpty = tab.explanation != nil && query.isEmpty
                return rows.isEmpty && !keepEmpty ? nil : Section(tab: tab, rows: rows)
            }
        }
        return filter.search(found)
    }

    /// The editor's warning when `key` is taken by another action; nil when it is free, already this action's, or held by
    /// `old`, the bind being edited.
    public static func clash(store: BindStore, actions: [ActionInfo], key: Key, for action: String, from old: String? = nil) -> String? {
        guard let other = store.clash(key, for: action, from: old) else { return nil }
        let name = label(other, in: actions)
        return "\(key.label) already runs \(name). Replace leaves \(name) with no key."
    }

    /// The key `action` gives up when it is bound to `key`: one action holds one key (BindStore.assign), so binding one
    /// that already has a key frees that key, which the editor's Move here names. Nil when it has none or is on `key`.
    public static func moving(store: BindStore, action: String, to key: Key) -> Key? {
        store.trigger(for: action).flatMap { $0 == key ? nil : $0 }
    }

    /// The log line for a bind written to binds.json, token redacted: the action on its key, the action Replace left with
    /// no key, the bind the editor took it from (`old`), and the key the move freed (`moving`).
    public static func bindLog(_ action: String, on key: Key?, left other: String? = nil, from old: String? = nil, freed: Key? = nil) -> String {
        let left = other.map { ", \($0) left with no key" } ?? ""
        let moved = old.map { $0 == action ? "" : ", moved from \($0)" } ?? ""
        let off = freed.map { ", moved off \($0.label)" } ?? ""
        return LinkToken.redact("\(action) on \(key?.label ?? "no key")\(left)\(moved)\(off)")
    }

    /// Why Reset was refused: another action holds the default's key.
    public static func refusal(_ error: BindStore.BindError, actions: [ActionInfo]) -> String {
        switch error {
        case .triggerTaken(let key, let other):
            "\(key.label) is taken by \(label(other, in: actions)); give that a new key first."
        }
    }

    private static func label(_ id: String, in actions: [ActionInfo]) -> String { actions.first { $0.id == id }?.label ?? id }
}
