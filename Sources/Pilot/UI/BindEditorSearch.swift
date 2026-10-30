import AppKit
import PilotCore
import SwiftUI

/// Editor A's one search (spec bind-editor, design A, Sven 2026-10-12): the field's text, the kind picked from the empty
/// list or a scope chip, the More row opened, the row highlighted and the row picked, over PilotCore's BindSearch and the
/// sources it reads once as the editor opens. A picked row's id is what Save binds, over the form's fields.
@Observable @MainActor
final class BindFinder {
    /// New words drop the AI's ask and its answer's status.
    var query: String { didSet { if query != oldValue { stopAsking() } } }
    /// The kind picked: its token in the field, its groups searched.
    var scope: BindSearch.Kind?
    /// The More row opened: its three kinds listed.
    var more = false
    var highlighted = 0
    var picked: String?
    private(set) var sources: BindSearch.Sources
    private var loaded: Bool
    /// Suggest with AI (spec ai-binds T2): nil, no row.
    var ai: AI?
    /// The AI's answer being asked for, or why there is none; nil hides the row's status.
    private(set) var asking: Asking?
    /// The card or form came from the AI: its caption says to check it before Save.
    var suggested = false
    /// The menu item the AI guessed, listed first and highlighted in its app's menus (Q128).
    var guess: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `sources` given (a test's) are kept: nothing is read; `ai` given (a test's fake) is the row's provider.
    init(query: String = "", scope: BindSearch.Kind? = nil, picked: String? = nil, sources: BindSearch.Sources? = nil, ai: AI? = nil) {
        self.query = query; self.scope = scope; self.picked = picked
        self.sources = sources ?? BindSearch.Sources()
        loaded = sources != nil
        self.ai = ai
    }

    /// The AI the row asks, injected like the sources: its provider's name while it is ready (nil hides the row), its
    /// runner on the AI page's provider and model at low effort whatever the page's effort (Q124), and whether an app
    /// opens a URL.
    struct AI {
        var provider: @MainActor () -> String?
        var runner: @MainActor () -> Result<QuickAI.Runner, QuickAI.Failure>
        var handles: @Sendable (String) -> Bool
        /// Asks a CLI route nobody has checked yet whether it is signed in, so the row can show.
        var prepare: @MainActor () async -> Void = {}

        /// The AI page's.
        @MainActor static func settings(_ settings: AISettings = .shared) -> AI {
            AI(provider: { settings.ready(settings.provider) ? settings.provider.name : nil }, runner: { settings.runner(effort: .low) },
                      handles: { URL(string: $0).flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil },
                      prepare: { if settings.provider.command != nil, settings.status(settings.provider) == .checking { await settings.refreshCLI(settings.provider) } })
        }
    }

    /// As a picker opens (the bind editor, Binds › Mouse): the sources read once, and a CLI route asked whether it is
    /// signed in, so Suggest with AI can show.
    func open(apps: @autoclosure () -> [(name: String, bundle: String)], actions: [BindsPage.ActionInfo]) {
        load(apps: apps(), actions: actions)
        if let prepare = ai?.prepare { Task { await prepare() } }
    }

    /// The longest shell answer the form shows whole; a longer one, or one of several lines, is no bind (Q125: a command
    /// is read in full before Save).
    static let shellLimit = 200

    /// The answer, a shell command the form cannot show whole refused.
    static func shown(_ got: BindAI.Suggestion) -> BindAI.Suggestion {
        guard case .form(.shell(let command)) = got, command.count > shellLimit || command.contains(where: \.isNewline) else { return got }
        return .none("The command is too long to check here")
    }

    /// The row's status while it asks, or after an answer that bound nothing.
    enum Asking: Equatable {
        case running(String), noBind(String), failed(String)

        var detail: String {
            switch self {
            case .running(let provider): "Asking \(provider)…"
            case .noBind(let why): "No bind found: \(why)"
            case .failed(let title): title
            }
        }

        var running: Bool { if case .running = self { true } else { false } }
    }

    /// Asks the AI for `text`'s action and hands an answer that binds something to `apply`; a new ask stops the one before.
    func ask(_ text: String, apply: @escaping @MainActor (BindAI.Suggestion) -> Void) {
        guard let ai, let provider = ai.provider() else { return }
        task?.cancel()
        let runner: QuickAI.Runner
        switch ai.runner() {
        case .success(let got): runner = got
        case .failure(let why): asking = .failed(why.title); return
        }
        asking = .running(provider)
        let sources = sources, handles = ai.handles, start = ContinuousClock.now
        task = Task { [weak self] in
            do throws(QuickAI.Failure) {
                let got = Self.shown(try await BindAI.suggest(text, in: sources, handles: handles, runner: runner))
                guard let self, !Task.isCancelled else { return }
                let kind = switch got { case .row: "a card"; case .form: "a form"; case .none: "no bind" }
                ailog.notice("bind AI: \(kind, privacy: .public) in \(ContinuousClock.now - start, privacy: .public)")
                self.task = nil
                if case .none(let why) = got { asking = .noBind(why) } else { asking = nil; apply(got) }
            } catch {
                guard let self, !Task.isCancelled, error != .cancelled else { return }
                ailog.notice("bind AI failed: \(error.message, privacy: .public)")
                self.task = nil
                asking = .failed(error.title)
            }
        }
    }

    /// Stops an ask in flight and clears the row's status.
    func stopAsking() {
        task?.cancel()
        task = nil
        asking = nil
    }


    /// Every source the search reads, once; Shortcuts' names come later (`provide(shortcuts:)`), focus presets stay empty
    /// (parked). `apps` is read only the first time.
    func load(apps: @autoclosure () -> [(name: String, bundle: String)], actions: [BindsPage.ActionInfo]) {
        guard !loaded else { return }
        loaded = true
        if ai == nil { ai = .settings() }
        sources = BindSearch.Sources(
            apps: apps(), browsers: Self.browsers(), actions: actions, catalogue: DriveModule.catalogue,
            scripts: ScriptCommand.actions([], with: ScriptCommand.find()), extensions: Extension.actions([], with: Extension.find().extensions),
            quicklinks: BindSearch.quicklinks(QuicklinkBook.shared.links), configs: ConfigsModule.menuRows(), soundOutputs: SystemModule.outputRows())
    }

    /// The apps that open web pages, by name, each once.
    private static func browsers() -> [(name: String, bundle: String)] {
        guard let page = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: page)
            .compactMap { url in Bundle(url: url)?.bundleIdentifier.map { (AppsModule.appName(at: url), $0) } }
            .filter { seen.insert($0.1).inserted }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// The Shortcuts app's names, read in a child once the Shortcut kind is picked.
    func provide(shortcuts: [String]) { sources.shortcuts = shortcuts }

    /// What a line picks: a kind (More holds three), or a row.
    enum Pick: Equatable { case kinds([BindSearch.Kind]), row(BindSearch.Row) }

    /// One line of the list; `heading` is the group's small capitals over its first line.
    struct Line: Identifiable, Equatable {
        var id: String
        var heading: String?
        var title: String, detail: String
        var count: String?
        var pick: Pick
        /// The AI row while it asks: a spinner for its icon.
        var busy = false
    }

    /// The list as it stands, from one search: the kinds while nothing is typed (More's three once opened), else the rows
    /// under their groups' headings, and the scope chips while a typed search spans every kind. `trigger` is the key an
    /// action holds now.
    func listing(trigger: (String) -> Key?) -> (lines: [Line], chips: [Chip]) {
        if more, scope == nil, query.trimmingCharacters(in: .whitespaces).isEmpty {
            return (Self.more.enumerated().map { i, kind in
                Line(id: "kind-\(kind)", heading: i == 0 ? "More" : nil, title: kind.title, detail: kind.example, pick: .kinds([kind]))
            }, [])
        }
        switch BindSearch.list(query, scope: scope, in: sources, suggest: ai?.provider(), trigger: trigger) {
        case .kinds(let kinds):
            return (kinds.enumerated().map { i, k in
                Line(id: "kind-\(k.title)", heading: i == 0 ? "Start with what it does" : nil, title: k.title, detail: k.example,
                     count: k.count.map { k.kinds == [.app] ? "\($0) apps" : "\($0)" }, pick: .kinds(k.kinds))
            }, [])
        case .rows(let rows):
            let lines = rows.enumerated().map { i, row in
                let status = row.id == BindAI.rowID ? asking : nil
                return Line(id: "\(row.group)-\(row.id)", heading: i == 0 || rows[i - 1].group != row.group ? row.group.title : nil,
                            title: row.title, detail: status?.detail ?? row.subtitle, pick: .row(row), busy: status?.running == true)
            }
            return (lines, scope == nil ? Self.chips(rows) : [])
        }
    }

    static let more: [BindSearch.Kind] = [.shortcut, .picker, .appURL]

    /// The scope chips under a typed search, with how many rows each holds where it lists them (All, Apps, Pilot).
    struct Chip: Identifiable, Equatable {
        var kind: BindSearch.Kind?
        var title: String
        var count: Int?
        var id: String { title }
    }

    private static func chips(_ rows: [BindSearch.Row]) -> [Chip] {
        func count(_ kind: BindSearch.Kind) -> Int { rows.filter { kind.groups.contains($0.group) }.count }
        return [Chip(kind: nil, title: "All", count: rows.filter { $0.group != .shell && $0.group != .suggest }.count),
                Chip(kind: .app, title: "Apps", count: count(.app)), Chip(kind: .action, title: "Pilot", count: count(.action)),
                Chip(kind: .web, title: "Web"), Chip(kind: .shell, title: "Shell"), Chip(kind: .menu, title: "Menu item")]
    }
}

/// What Save will do, worked out from the keys, the pick and the store before anything is written (stories 6 to 8): the
/// primary button's word, the footer's sentence and the two conflicts the sheet shows where they happen.
struct BindPlan: Equatable {
    enum Verb: String { case save = "Save", replace = "Replace", move = "Move here" }

    /// A conflict row: its bold lead, then the rest.
    struct Warning: Equatable {
        var lead: String, rest: String
    }

    var verb: Verb
    var enabled: Bool
    /// The keys, as Save's sentence names them; nil while none are pressed.
    var keys: String?
    /// What the keys will run, and whether they open it (an app or a page) or run it.
    var name: String?
    var opens: Bool
    /// The action the key is taken from (Replace).
    var holder: String?
    /// The key the move frees (Move here).
    var freed: String?

    /// `holder` holds `key` today; `freed` is the key the picked action gives up (BindsPage.moving).
    init(key: Key?, name: String?, opens: Bool, holder: String?, freed: Key?) {
        keys = key?.label
        self.name = name; self.opens = opens; self.holder = holder; self.freed = freed?.label
        enabled = key != nil && name != nil
        verb = holder != nil ? .replace : freed != nil ? .move : .save
    }

    /// The plan for binding `target` to `key` in `store`, from `old`, the bind being edited (nil for a new one): the
    /// action holding the key other than those two, and the key `target` gives up when it is not the bind being edited.
    /// `name` names an action; `holderID` is the holder's id, for the caption.
    init(store: BindStore, key: Key?, target: String?, editing old: String?, name: (String) -> String) {
        let holder = key.flatMap { store.clash($0, for: target ?? old ?? "", from: old) }
        let freed = key.flatMap { key in target.flatMap { $0 == old ? nil : BindsPage.moving(store: store, action: $0, to: key) } }
        self.init(key: key, name: target.map(name), opens: target.flatMap(AppLink.init(id:)) != nil, holder: holder.map(name), freed: freed)
        holderID = holder
    }

    var holderID: String?

    /// One sentence of what Save does, or why it is off.
    var sentence: String {
        guard let keys else { return "Press the keys first." }
        guard let name else { return "Pick what \(keys) does." }
        return "\(keys) \(opens ? "opens" : "runs") \(name)\(holder.map { ", not \($0)" } ?? "")."
    }

    /// Conflict 1, under the keys: the key is taken.
    var taken: Warning? {
        guard let keys, let holder else { return nil }
        return Warning(lead: "\(keys) runs \(holder) now.", rest: "Save gives it to \(name ?? "your pick"); \(holder) is left with no key.")
    }

    /// Conflict 2, under the pick: the action already holds another key, which saving frees.
    var moving: Warning? {
        guard let keys, let name, let freed else { return nil }
        return Warning(lead: "\(name) is on \(freed) now.", rest: "One action holds one key: saving moves it to \(keys) and frees \(freed).")
    }
}

/// What binds as BindStore does: the store itself, and Binds, which writes binds.json and logs each change.
@MainActor
protocol BindWriting {
    mutating func setBind(_ action: String, to key: Key?, from old: String?) throws(BindStore.BindError)
    mutating func replaceBind(_ action: String, with key: Key, from old: String?)
}

extension BindStore: BindWriting {
    mutating func setBind(_ action: String, to key: Key?, from old: String?) throws(BindStore.BindError) { try set(action, to: key, from: old) }
    mutating func replaceBind(_ action: String, with key: Key, from old: String?) { replace(action, with: key, from: old) }
}

extension Binds: BindWriting {
    func setBind(_ action: String, to key: Key?, from old: String?) throws(BindStore.BindError) { try set(action, to: key, from: old) }
    func replaceBind(_ action: String, with key: Key, from old: String?) { replace(action, with: key, from: old) }
}

/// The editor's writes, as its plan says: nothing while Save is off; Replace leaves the key's holder with no key; Save
/// and Move here set the bind, which frees a keyed action's old key (one action holds one key). Remove leaves the bind
/// with no key.
@MainActor
enum BindWrite {
    static func save<W: BindWriting>(_ plan: BindPlan, _ target: String, to key: Key, from old: String?, in binds: inout W)
        throws(BindStore.BindError) {
        guard plan.enabled else { return }
        if plan.verb == .replace { binds.replaceBind(target, with: key, from: old) } else { try binds.setBind(target, to: key, from: old) }
    }

    static func remove<W: BindWriting>(_ action: String, in binds: inout W) throws(BindStore.BindError) {
        try binds.setBind(action, to: nil, from: nil)
    }

    /// What Esc does next: stop Record, stop the AI's ask, clear the search, drop the kind's token, else cancel. None of
    /// them writes.
    enum Escape: Equatable { case stopRecording, stopAsking, clearSearch, clearKind, cancel }

    static func escape(recording: Bool, asking: Bool = false, query: String, scoped: Bool) -> Escape {
        recording ? .stopRecording : asking ? .stopAsking : !query.isEmpty ? .clearSearch : scoped ? .clearKind : .cancel
    }
}

extension BindEditor {
    /// The kinds the search leaves to a form of fields (BindEditorKinds); a menu item first picks its app from the list.
    static let formKinds: Set<BindSearch.Kind> = [.menu, .shell, .keys, .picker, .appURL]

    enum Stage: Equatable { case list, form(BindSearch.Kind), card }

    /// The list while nothing is picked, a kind's fields once one with a form is, else the picked card.
    var stage: Stage {
        if let kind = finder.scope, Self.formKinds.contains(kind), !(kind == .menu && bundle.isEmpty) { return .form(kind) }
        return target == nil || finder.scope != nil ? .list : .card
    }

    var plan: BindPlan { mouse.map(mousePlan) ?? BindPlan(store: engine.binds.store, key: key, target: target, editing: action, name: name(of:)) }

    /// An action's name: an app's own, the list's label, else the engine's.
    func name(of id: String) -> String {
        if let bundle = AppsModule.bundle(in: id) { return apps.first { $0.bundle == bundle }?.name ?? AppsModule.appName(bundle) ?? bundle }
        return actions.first { $0.id == id }?.label ?? engine.action(id)?.label ?? id
    }

    /// The app an action opens or acts in, for its icon.
    static func bundle(of id: String) -> String? {
        switch AppLink(id: id) {
        case .open(let bundle)?, .url(let bundle, _)?, .privateWindow(let bundle)?: return bundle
        default: break
        }
        if case .menu(let bundle, _)? = DriveRoute(id: id) { return bundle }
        return DriveCatalogue.ownAction(id) ? nil : DriveModule.catalogue.app(for: id)?.app.bundle
    }

    /// The line under the keys: Record's prompt, a plain combo's cost, whose the key is.
    func keyCaption(_ plan: BindPlan) -> String {
        if let mouse { return mouseCaption(mouse) }
        if recording { return "Press a Hyper key or a plain combo (Cmd, Ctrl or Alt + a key). esc stops." }
        guard let key else { return "Record the keys, or Choose key." }
        if !key.hyper { return "A plain combo: no Hyper. Pilot takes it in every app." }
        let store = engine.binds.store
        if let action, store.trigger(for: action) == key, store.isCustom(action) {
            return "Bound by you · " + (store.defaultTrigger(for: action).map { "Pilot default is \($0.label)." } ?? "no default.")
        }
        let layer = BindsPage.Sublayer(modifiers: key.modifiers)?.title ?? key.label.components(separatedBy: "+").dropLast().joined(separator: "+")
        let state = "\(plan.holderID == nil ? "Free" : "Taken") on \(layer)."
        return target == nil && plan.holderID == nil ? state + " Click the keys or Record to change them." : state
    }

    /// The list's rows for the window: 7 at 1000×660, 4 at the 760×520 least window.
    static func listRows(windowHeight: CGFloat) -> Int { max(4, min(7, 4 + Int((windowHeight - 520) / 46))) }

    /// Picks a line: a kind scopes the search (More opens its three), a row is the bind's action; in a menu item's
    /// scope a row is its app. Suggest with AI asks; its row is never the bind's action.
    func choose(_ pick: BindFinder.Pick) {
        switch pick {
        case .kinds(let kinds) where kinds.count > 1:
            finder.more = true
        case .kinds(let kinds):
            scope(kinds.first)
        case .row(let row) where row.id == BindAI.rowID:
            finder.ask(finder.query.trimmingCharacters(in: .whitespacesAndNewlines)) { apply($0) }
            return
        case .row(let row):
            if finder.scope == .menu, let app = row.bundle {
                bundle = app
            } else {
                finder.picked = row.id
                finder.scope = nil
                finder.more = false
                finder.suggested = false
            }
            finder.query = ""
        }
        finder.highlighted = 0
    }

    /// The AI's answer, for the person to check before Save: an action as its card, a shell command, keys or a menu item
    /// in its form, filled in (the menu's guess first among the app's own items, Q128). Nothing is saved.
    func apply(_ suggestion: BindAI.Suggestion) {
        switch suggestion {
        case .row(let row):
            choose(.row(row))
            finder.suggested = true
            return
        case .form(.shell(let command)):
            scope(.shell)
            field = command
        case .form(.keystroke(let key)):
            scope(.keys)
            keystroke = key.spelling
        case .form(.menu(let app, let path)):
            scope(.menu)
            bundle = app
            finder.guess = DriveRoute.menu(bundle: app, path: path).id
        case .form, .none:
            return
        }
        finder.query = ""
        finder.highlighted = 0
        finder.suggested = true
    }

    /// A kind's token: the search scoped to it, and a kind with a form takes the form's fields.
    func scope(_ kind: BindSearch.Kind?) {
        finder.scope = kind
        finder.picked = nil
        finder.more = false
        finder.highlighted = 0
        finder.suggested = false
        finder.guess = nil
        finder.stopAsking()
        switch kind {
        case .menu?: does = .menu; bundle = ""; menuPath = ""
        case .keys?: does = .keystroke
        case .picker?: does = .picker
        case .shell?: does = .advanced; if advanced != .shell { advanced = .shell; field = "" }
        case .appURL?: does = .advanced; if advanced != .url { advanced = .url; field = "" }
        default: does = .action; chosen = ""
        }
        searchFocused = true
    }

    /// Change on the picked card: back to the list, nothing picked.
    func change() {
        scope(nil)
        finder.query = ""
    }

    /// Esc: stops Record, then clears the search, then the kind's token, then cancels.
    func escape() {
        switch BindWrite.escape(recording: recording || recordingKeys, asking: finder.asking?.running == true, query: finder.query,
                                scoped: finder.scope != nil || finder.more) {
        case .stopRecording:
            engine.recordKey(nil)
            recording = false
            recordingKeys = false
            searchFocused = true
        case .stopAsking: finder.stopAsking()
        case .clearSearch: finder.query = ""
        case .clearKind: scope(nil)
        case .cancel: dismiss()
        }
    }

    /// What the search prompt names: the keys, or the mouse button.
    var triggerName: String? { mouse.map { $0.title(hold: mouseHolds) } ?? key?.label }

    /// As the sheet opens (Instrument): the search read, then from a key the search focused, from New bind Record.
    func open() {
        finder.open(apps: apps, actions: actions)
        if key == nil && target == nil { record() } else { Task { searchFocused = true } }
    }

    /// Choose key's pick: a key on a Hyper layer.
    func choose(key code: Int64, layer: BindsPage.Sublayer) {
        sublayer = layer
        keyCode = code
        plain = nil
        choosingKey = false
    }

    /// Reset on a bind you set: back to the preset's key; refused while another action holds that key.
    func reset() {
        guard let action else { return }
        do { try engine.binds.reset(action); dismiss() } catch { refusal = BindsPage.refusal(error, actions: actions) }
    }
}
