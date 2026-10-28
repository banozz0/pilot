import PilotCore
import SwiftUI

/// The bind being edited on a Binds page; a nil action is a new bind, optionally on `startKey`.
struct BindEditing: Identifiable, Hashable {
    var action: String?
    var startKey: Key?
    var id: Self { self }
}

/// The Binds list's layers in every style.
@MainActor
enum BindsList {
    /// The sections there are, the layer picked (`only`, else `filter` while it still holds binds) and its sections. A
    /// search spans every section.
    static func list(_ store: BindStore, actions: [BindsPage.ActionInfo], only: BindsPage.Tab?, filter: BindsPage.Tab?, search: String)
        -> (tabs: [BindsPage.Tab], sections: [BindsPage.Section]) {
        // Every section, which also names the layers the filter offers; a filter on a layer that has since emptied lists
        // everything again. Only a filter or a search needs a second pass.
        let all = BindsPage.sections(store: store, actions: actions)
        let tabs = all.map(\.tab)
        let pick = only ?? filter.flatMap { tabs.contains($0) ? $0 : nil }
        let sections = !search.isEmpty ? BindsPage.sections(store: store, actions: actions, search: search)
            : pick == nil ? all : BindsPage.sections(store: store, actions: actions, only: pick)
        return (tabs, sections)
    }

    /// The keys' column of a list row whose keys name their layer, so every row's words line up (Instrument's and
    /// Toybox's lists).
    static let keyColumn: CGFloat = 150
}

extension View {
    /// Binds' sheet and asks, shared by the keyboard and the list (card agent-bo-95422894): the bind editor, Reset all,
    /// and switching layouts, each clearing the last refusal.
    func bindsDialogs(editing: Binding<BindEditing?>, switchingTo: Binding<BindStore.Preset?>,
                      confirmingResetAll: Binding<Bool>, refusal: Binding<String?>) -> some View {
        modifier(BindsDialogs(editing: editing, switchingTo: switchingTo, confirmingResetAll: confirmingResetAll, refusal: refusal))
    }
}

/// New, rename and delete for bind presets (story 149): the preset menu's rows ask, Binds' page answers (presetDialogs).
@Observable @MainActor
final class PresetAsk {
    static let shared = PresetAsk()
    enum Ask: Equatable { case new(copying: Bool), rename(BindStore.Preset), delete(BindStore.Preset) }
    var ask: Ask?
    /// The name being typed for New or Rename.
    var name = ""

    func start(_ ask: Ask) {
        name = switch ask {
        case .new(let copying): copying ? "\(Engine.shared?.binds.store.preset.title ?? "Preset") copy" : "My preset"
        case .rename(let preset), .delete(let preset): preset.title
        }
        self.ask = ask
    }
}

/// The preset menu's pick of a preset, as a submenu with the active one checked; `pick` gets another one picked.
struct PresetPicker: View {
    var title = "Preset"
    let presets: [BindStore.Preset]
    let active: BindStore.Preset
    let pick: (BindStore.Preset) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { active }, set: { if $0 != active { pick($0) } })) {
            ForEach(presets) { Text($0.title).tag($0) }
        }
        .menuRows()
    }
}

/// The preset menu's own rows: a new preset from scratch or as a copy, and Rename and Delete for one made by hand.
struct PresetMenuItems: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        let current = engine.binds.store.preset
        Divider()
        Button("New preset from scratch…") { PresetAsk.shared.start(.new(copying: false)) }
        Button("New copy of \(current.title)…") { PresetAsk.shared.start(.new(copying: true)) }
        if !current.isBuiltIn {
            Button("Rename \(current.title)…") { PresetAsk.shared.start(.rename(current)) }
            Button("Delete \(current.title)…", role: .destructive) { PresetAsk.shared.start(.delete(current)) }
        }
    }
}

/// Those rows behind one button, beside a page's preset segments.
struct PresetMoreMenu: View {
    var body: some View {
        Menu { PresetMenuItems() } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Preset options") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("New, rename or delete a preset")
    }
}

extension View {
    /// The preset asks (PresetAsk), once per page: Binds' page holds them for its keyboard and its list.
    func presetDialogs() -> some View { modifier(PresetDialogs()) }
}

private struct PresetDialogs: ViewModifier {
    @Environment(Engine.self) private var engine
    @Bindable private var asks = PresetAsk.shared

    func body(content: Content) -> some View {
        let naming = Binding(get: { if case .delete = asks.ask { false } else { asks.ask != nil } }, set: { if !$0 { asks.ask = nil } })
        let deleting = Binding(get: { if case .delete = asks.ask { true } else { false } }, set: { if !$0 { asks.ask = nil } })
        content
            .alert(title, isPresented: naming) {
                TextField("Name", text: $asks.name)
                Button("Cancel", role: .cancel) { asks.ask = nil }
                Button(isRename ? "Rename" : "Make preset") { commitName() }
            } message: {
                Text(message)
            }
            .confirmationDialog("Delete \(asks.name)?", isPresented: deleting) {
                Button("Delete", role: .destructive) {
                    if case .delete(let preset) = asks.ask { engine.binds.deletePreset(preset) }
                    asks.ask = nil
                }
            } message: {
                Text("Its keys go with it.")
            }
    }

    private var isRename: Bool { if case .rename = asks.ask { true } else { false } }

    private var title: String {
        switch asks.ask {
        case .new(let copying)?: copying ? "New copy of \(engine.binds.store.preset.title)" : "New preset from scratch"
        default: "Rename preset"
        }
    }

    private var message: String {
        switch asks.ask {
        case .new(false)?: "Starts empty but Hyper+Space, the Pilot menu."
        case .new(true)?: "Starts with every key \(engine.binds.store.preset.title) has."
        default: ""
        }
    }

    private func commitName() {
        switch asks.ask {
        case .new(let copying)?: engine.binds.addPreset(named: asks.name, copying: copying)
        case .rename(let preset)?: engine.binds.renamePreset(preset, to: asks.name)
        default: break
        }
        asks.ask = nil
    }
}

private struct BindsDialogs: ViewModifier {
    @Environment(Engine.self) private var engine
    @Binding var editing: BindEditing?
    @Binding var switchingTo: BindStore.Preset?
    @Binding var confirmingResetAll: Bool
    @Binding var refusal: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) {
                // The window behind the sheet stays main while the sheet is key: its height caps the sheet's.
                BindEditor(action: $0.action, actions: engine.bindActions(including: $0.action), startKey: $0.startKey,
                           windowHeight: NSApp.mainWindow?.contentLayoutRect.height ?? 660)
                    .floating()
            }
            .confirmationDialog("Reset every bind to its default?", isPresented: $confirmingResetAll) {
                Button("Reset all", role: .destructive) { engine.binds.resetAll(); refusal = nil }
            } message: {
                Text("Every key you set goes back to the \(engine.binds.store.preset.title) layout's default.")
            }
            .confirmationDialog("Switch layouts?", isPresented: Binding(get: { switchingTo != nil }, set: { if !$0 { switchingTo = nil } }),
                                presenting: switchingTo) { target in
                Button("Switch to \(target.title)") { engine.binds.use(target); refusal = nil }
            } message: { target in
                Text("Every key changes to the \(target.title) preset's. The keys you set in this one stay with it, and you can switch back here.")
            }
    }
}

/// Add or edit one bind (wireframe section 3): the keys, by Record (the next Hyper key or plain combo, through the tap)
/// or by picking, then what they do: any registered action, an app from the installed-app picker, a web page, an app's
/// action from the drive catalogue or "not supported" (card agent-bo-95422445), or a drive route (card agent-bo-95422444): an app's menu item by title path, a keystroke into the focused app, or the advanced
/// field's URL, Shortcuts name or shell command. Editing
/// can change both; the bind's old action is then left with no key. A key already in use shows the clash and Replace
/// before anything is saved.
struct BindEditor: View {
    @Environment(Engine.self) var engine
    @Environment(\.dismiss) var dismiss
    @Environment(\.style) var style
    /// Nil for a new bind.
    let action: String?
    let actions: [BindsPage.ActionInfo]
    /// A new bind's keys to start from: the free key clicked on Binds' keyboard (card agent-bo-95422894).
    var startKey: Key?
    /// The window the sheet hangs on: Instrument's sheet is at most its height less 60, its list rows fitted to it.
    var windowHeight: CGFloat = 660
    /// Binds › Mouse's button in place of the keys (BindEditorMouse); nil for a key.
    var mouse: MouseTrigger?
    /// Instrument's one search (BindEditorSearch): what is typed, the kind picked, the row picked.
    @State var finder = BindFinder()

    enum Does: Hashable, CaseIterable {
        case action, app, web, appAction, menu, keystroke, picker, advanced
    }
    /// The advanced field's kinds; each makes the DriveRoute its id names.
    enum Advanced: String, CaseIterable {
        case url = "URL", shortcut = "Shortcut", shell = "Shell command"

        func route(_ field: String) -> DriveRoute {
            switch self { case .url: .url(field); case .shortcut: .shortcut(field); case .shell: .shell(field) }
        }
    }
    @State var does = Does.action
    @State var chosen = ""
    @State var bundle = ""
    @State var url = ""
    @State var catalogueRoute = ""
    @State var menuPath = ""
    @State var keystroke = ""
    @State var advanced = Advanced.url
    @State var field = ""
    @State var pickerTitle = ""
    @State var pickerList = ""
    @State var pickerRun = ""
    @State var sublayer = BindsPage.Sublayer.hyper
    @State var keyCode: Int64?
    /// A plain combo, recorded or being edited, kept whole with its sides; picking a layer or a key drops it.
    @State var plain: Key?
    @State var recording = false
    /// Listed by the hold-Hyper overlay set to My own pick (story 56).
    @State var inOverlay = false
    /// Read once: listing the application folders is too slow for every render.
    @State var apps: [(name: String, bundle: String)] = []
    @State var choosingKey = false
    /// Why Reset was refused.
    @State var refusal: String?
    @FocusState var searchFocused: Bool
    /// The kind forms' (BindEditorKinds): the field with focus, Send keys' Record, Run once, and the Menu item form's app
    /// with its items, read off the main thread (nil items: the app is not running).
    @FocusState var formField: FormField?
    @State var recordingKeys = false
    @State var ranOnce: RunOnce?
    @State var menuItems: (bundle: String, items: [MenuEntry]?)?
    @State var shortcutsRead = false
    /// A mouse button's Hold picked over its Click.
    @State var holding = false

    static let keys = KeyNames.names.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }

    /// The action the keys will run; nil while none is picked.
    var target: String? {
        if let picked = finder.picked { return picked }
        switch does {
        case .action: return chosen.isEmpty ? nil : chosen
        case .app: return bundle.isEmpty ? nil : AppsModule.openID(bundle: bundle)
        case .web: return AppsModule.webID(url)
        case .appAction: return catalogueRoute.isEmpty ? nil : catalogueRoute
        // Instrument's Menu item form binds only the row picked (finder.picked); the path is an edited bind's own.
        case .menu:
            return bundle.isEmpty || finder.scope == .menu ? nil
                : DriveRoute.menu(bundle: bundle, path: menuPath.components(separatedBy: ">")).checked?.id
        case .keystroke: return Key(spelling: keystroke).map { DriveRoute.keystroke($0).id }
        case .picker:
            return DriveRoute.picker(title: pickerTitle, list: pickerList, run: pickerRun).checked?.id
        case .advanced: return advanced.route(field).checked?.id
        }
    }

    var key: Key? {
        if let mouse { return mouse.trigger(hold: mouseHolds) }
        return plain ?? keyCode.map { Key(keyCode: $0, modifiers: sublayer.modifiers) }
    }


    /// Keys and something to run.
    var ready: Bool { key != nil && target != nil }

    /// Instrument and Toybox draw their own sheets (InstrumentBindEditor, ToyBindEditor) on the same state and actions.
    var body: some View {
        Group {
            switch style.kind {
            case .instrument: instrument
            case .toybox: toybox
            }
        }
            .onAppear {
                inOverlay = action.map(engine.settings.overlayPicks.contains) ?? false
                apps = AppsModule.installedApps()
                if let mouse {
                    openMouse(mouse)
                } else if let action {
                    if let key = engine.binds.store.trigger(for: action) { show(key) }
                    pick(action)
                } else if let startKey { show(startKey) }
                if style.kind == .instrument { open() }
            }
            .onDisappear { engine.recordKey(nil) }
            .onChange(of: sublayer) { plain = nil }
            // Another app's actions: a route of the old app no longer applies.
            .onChange(of: bundle) { _, app in
                if DriveModule.catalogue.actions(for: app)?.contains(where: { $0.route == catalogueRoute }) != true { catalogueRoute = "" }
            }
            .onChange(of: keyCode) { _, code in if code != plain?.keyCode { plain = nil } }
            // Send keys' Record stops with its form; the Shortcut kind reads Shortcuts' names once, in a child.
            .onChange(of: finder.scope) { _, kind in
                if recordingKeys { stopKeystroke() }
                if kind == .shortcut, !shortcutsRead {
                    shortcutsRead = true
                    Task { finder.provide(shortcuts: await DriveModule.shortcutNames()) }
                }
            }
    }

    /// The editor's Remove: the bind loses its key.
    var removal: (title: String, run: () -> Void)? {
        if let mouse { return mouseRemoval(mouse) }
        guard let action, engine.binds.store.trigger(for: action) != nil else { return nil }
        return ("Remove key", {
            var binds = engine.binds
            do throws(BindStore.BindError) { try BindWrite.remove(action, in: &binds); dismiss() } catch { refusal = BindsPage.refusal(error, actions: actions) }
        })
    }

    func record() {
        recordingKeys = false
        recording = true
        engine.recordKey { key in show(key); recording = false }
    }

    private func show(_ key: Key) {
        plain = key.hyper ? nil : key
        keyCode = key.keyCode
        if key.hyper { sublayer = BindsPage.Sublayer(modifiers: key.modifiers) ?? .hyper }
    }

    /// Shows what the bind runs today in the Does section, so editing starts from it.
    func pick(_ action: String) {
        if let app = DriveModule.catalogue.app(for: action)?.app {
            does = .appAction
            bundle = app.bundle
            ensureListed(app.bundle, name: app.name)
            catalogueRoute = action
        } else if let app = AppsModule.bundle(in: action) {
            does = .app
            bundle = app
            ensureListed(app)
        } else if let page = AppsModule.page(in: action) {
            does = .web
            url = page
        } else if let route = DriveRoute(id: action) {
            switch route {
            case .menu(let app, let path):
                does = .menu
                bundle = app
                menuPath = path.joined(separator: DriveRoute.pathSeparator)
                ensureListed(app)
            case .keystroke(let key): does = .keystroke; keystroke = key.spelling
            case .url(let raw): does = .advanced; advanced = .url; field = raw
            case .shortcut(let name): does = .advanced; advanced = .shortcut; field = name
            case .shell(let command): does = .advanced; advanced = .shell; field = command
            case .picker(let title, let list, let run): does = .picker; pickerTitle = title ?? ""; pickerList = list; pickerRun = run
            }
        } else {
            does = .action
            chosen = action
        }
    }

    /// An app outside the application folders is still the one bound.
    private func ensureListed(_ app: String, name: String? = nil) {
        if !apps.contains(where: { $0.bundle == app }) { apps.insert((name ?? AppsModule.appName(app) ?? app, app), at: 0) }
    }

    /// As the plan says (BindWrite.save): Replace when the key is taken, the clash on screen making the other action's
    /// loss the choice made; else set, moving a keyed action. A changed action takes the key from the edited one, which
    /// is left with none. A refused write keeps the sheet open with its reason, the overlay's picks untouched.
    func save(_ key: Key) {
        guard ready, let target else { return }
        if let mouse { return saveMouse(mouse) }
        var binds = engine.binds
        do { try BindWrite.save(plan, target, to: key, from: action, in: &binds) } catch {
            return refusal = BindsPage.refusal(error, actions: actions)
        }
        var picks = engine.settings.overlayPicks
        if let action { picks.remove(action) }
        if inOverlay { picks.insert(target) }
        engine.settings.overlayPicks = picks
        dismiss()
    }
}
