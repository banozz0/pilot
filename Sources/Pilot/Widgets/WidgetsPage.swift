import AppKit
import Observation
import PilotCore
import SwiftUI

/// The Widgets page's state and actions (ADR 0016, T20): Pilot's ready widgets and the installed ones with their trust,
/// what is on the desktop, and the page's own changes, each made through the store and handed to the desk. Trust this
/// widget, Duplicate to edit and an import are the only places a widget's trust is written.
@Observable @MainActor
final class WidgetsPageModel {
    static let shared = WidgetsPageModel()

    @ObservationIgnored var store = WidgetStore.live
    @ObservationIgnored var desk = WidgetDesk.shared
    @ObservationIgnored var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    private(set) var installed: [Widget] = []
    private(set) var broken: [WidgetStore.Broken] = []
    private(set) var placements: [Widget.Placement] = []
    private(set) var trust: [String: Widget.Trust] = [:]
    /// Every widget the page shows, ready and installed, by id, as the last reload read them: the body reads this, never
    /// the disk.
    private(set) var byID: [String: Widget] = Dictionary(uniqueKeysWithValues: ReadyWidgets.all.map { ($0.id, $0) })
    /// The last thing the page did or why it could not, shown under its intro.
    var note: String?
    /// The widget whose Trust this widget question shows, or whose Uninstall is being confirmed; the placement whose Edit
    /// widget sheet shows.
    var asking: String?
    var editing: String?
    var uninstalling: String?
    /// The builder's sheet is up (T24).
    var building = false

    /// Reads the Widgets folder and the placements again.
    func reload() {
        (installed, broken) = store.installed()
        trust = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, store.trust(of: $0)) })
        byID = Dictionary(uniqueKeysWithValues: (ReadyWidgets.all + installed).map { ($0.id, $0) })
        placements = store.placements()
    }

    func widget(_ id: String) -> Widget? { byID[id] }

    /// "On the desktop twice", "Not on the desktop"; Home's apart.
    func placed(_ id: String, home: Bool = false) -> Int { placements.count { $0.widget == id && $0.onHome == home } }

    // MARK: Actions

    /// Add to desktop: a new placement, a step down and right from the last, at the widget's own size, on its own
    /// workspace (its widget.json's) or every one. `screen`, `x` and `y` put its top left where the desktop's Hyper +
    /// right-click › Add widget was: that display, and fractions of it.
    func add(_ widget: Widget, screen: String? = nil, x: Double? = nil, y: Double? = nil) {
        var all = store.placements()
        all.append(.new(widget, after: all.count, screen: screen, x: x, y: y))
        let on = widget.workspace.map { "workspace \($0)" } ?? "an empty workspace"
        save(all, done: "\(widget.title) is on the desktop; it shows on \(on) or with Show desktop.")
    }

    /// The one workspace a placement shows on, or every one (nil), from its row's menu (Q691).
    func show(_ placement: Widget.Placement, on workspace: String?) {
        var all = store.placements()
        guard let i = all.firstIndex(where: { $0.id == placement.id }) else { return reload() }
        all[i].workspace = workspace
        save(all, done: workspace.map { "It shows on workspace \($0) only." } ?? "It shows on every workspace.")
    }

    /// The workspaces a placement may be kept to: the tiler's, else the ones Pilot keeps; and the one it is kept to,
    /// even when the tiler no longer keeps it.
    func workspaces(keeping kept: String?) -> [String] {
        let names = Engine.shared?.workspaceList.names ?? Workspaces.kept(in: .pilot())
        return names + (kept.map { names.contains($0) ? [] : [$0] } ?? [])
    }

    /// A desktop widget's menu (its right-click, or a Hyper+right click): Edit widget, Move to Home and Remove from
    /// desktop under its title, then the workspaces it may show on, the one it shows on checked.
    func menu(for id: String) -> (sections: [(title: String, items: [(title: String, run: () -> Void)])], checked: Set<String>) {
        reload()
        guard let placement = placements.first(where: { $0.id == id }) else { return ([], []) }
        let all = "All workspaces"
        let shows: [(title: String, run: () -> Void)] = [(all, { self.show(placement, on: nil) })]
            + workspaces(keeping: placement.workspace).map { name in ("Workspace \(name)", { self.show(placement, on: name) }) }
        return ([(widget(placement.widget)?.title ?? placement.widget,
                  [("Edit widget…", { self.desk.editPlacement(id) }), ("Move to Home", { self.moveHome(placement) }),
                   ("Remove from desktop", { self.remove(placement) })]),
                 ("Shows on", shows)],
                [placement.workspace.map { "Workspace \($0)" } ?? all])
    }

    /// Move to Home: the placement leaves the desktop for Home, its own settings kept.
    func moveHome(_ placement: Widget.Placement) {
        var all = store.placements()
        guard let i = all.firstIndex(where: { $0.id == placement.id }) else { return reload() }
        (all[i].home, all[i].screen, all[i].workspace) = (true, nil, nil)
        save(all, done: "\(widget(placement.widget)?.title ?? placement.widget) is on Home now.")
    }

    /// Takes a placement off by its id (Home's right-click Remove).
    func remove(id: String) {
        reload()
        if let placement = placements.first(where: { $0.id == id }) { remove(placement) }
    }

    func remove(_ placement: Widget.Placement) {
        save(store.placements().filter { $0.id != placement.id }, done: placement.onHome ? "Taken off Home." : "Taken off the desktop.")
    }

    /// Add to Home: a new placement on Pilot's Home page, at the widget's own size, shown there at once (HomeLayout
    /// shows a new widget row); it runs only while Home draws it.
    func addHome(_ widget: Widget) {
        var all = store.placements()
        all.append(.new(widget, after: all.count, home: true))
        save(all, done: "\(widget.title) is on Home, the first page of Pilot's window; Edit Home moves and sizes it.")
    }

    /// Edit widget's Save: the placement's own settings (a password the widget's, in the Keychain) and its workspace; it
    /// alone starts over with them.
    func edit(_ placement: Widget.Placement, values: [String: JSONValue], passwords: [String: String], workspace: String?) {
        editing = nil
        guard let widget = byID[placement.widget] else { return }
        var all = store.placements()
        guard let i = all.firstIndex(where: { $0.id == placement.id }) else { return reload() }
        all[i].values = widget.own(values)
        if !placement.onHome { all[i].workspace = workspace }
        do {
            for (name, typed) in passwords where !typed.isEmpty { try store.set(.string(typed), field: name, of: widget) }
            try store.save(all)
            note = "\(widget.title) is saved."
        } catch { note = "Not saved: \(error.localizedDescription)" }
        desk.placementChanged(placement.id)
        reload()
    }

    private func save(_ placements: [Widget.Placement], done: String) {
        do { try store.save(placements); note = done } catch { note = "Not saved: \(error.localizedDescription)" }
        desk.reload()
        reload()
    }

    /// Trust this widget, after its question: full power for this folder as it is now (Q676).
    func trust(_ id: String) {
        asking = nil
        guard let widget = store.widget(id), !Widget.isReserved(id) else { return }
        // What is trusted is what the question showed: a widget.json changed since asks again.
        guard widget == byID[id] else {
            note = "\(widget.title) changed since its question showed; look at it again before trusting it."
            return reload()
        }
        do {
            try store.setTrust(.trusted, for: widget)
            note = "\(widget.title) is trusted: its command runs and its page loads."
        } catch { note = "Not trusted: \(error.localizedDescription)" }
        desk.widgetChanged(id)
        reload()
    }

    /// Duplicate to edit: a copy in the Widgets folder, made here for a ready or running widget, locked for a locked one.
    func duplicate(_ widget: Widget) {
        Task {
            do {
                let copy = try await store.duplicate(widget)
                note = "Copied to \(copy.folder.path) as \(copy.id)\(store.trust(of: copy).runs ? "" : ", locked like the one it came from")."
            } catch { note = "Not copied: \((error as? Widget.Problems)?.description ?? error.localizedDescription)" }
            reload()
        }
    }

    /// Uninstall, after its confirm: the folder to the Trash, its placements gone, its settings kept.
    func uninstall(_ id: String) {
        uninstalling = nil
        guard let widget = store.widget(id) else { return }
        do {
            try store.uninstall(widget, trash: trash)
            note = "\(widget.title) is in the Trash; its settings stay, should you install it again."
        } catch { note = "Not uninstalled: \(error.localizedDescription)" }
        desk.reload()
        reload()
    }

    /// Import a folder or a .zip (T22): refused with a link, a path leaving it or the gallery's limits; it arrives locked.
    func importFolder(_ folder: URL) {
        Task {
            do {
                let opened = try await store.open(folder)
                defer { opened.remove() }
                let widget = try await store.importFolder(opened.folder, trash: trash)
                note = "\(widget.title) is installed, locked: its card lists what it asks for until you trust it."
                desk.widgetChanged(widget.id)
            } catch { note = "Not imported: \((error as? Widget.Problems)?.description ?? error.localizedDescription)" }
            reload()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.prompt = "Import"
        panel.message = "A widget folder or .zip: widget.json and its files. It arrives locked."
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }

    func showFolder(_ widget: Widget? = nil) {
        try? FileManager.default.createDirectory(at: store.widgets, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([widget?.folder ?? store.widgets])
    }

}

/// Look's Widgets page (T20): Pilot's ready widgets, yours with their trust, and what is on the desktop and on Home, with
/// Add to desktop, Add to Home, Edit widget (each placement's own settings), Trust this widget, Duplicate to edit, Show
/// folder, Uninstall and Import (a folder or .zip, or one dropped on the page). Each widget's own
/// CPU and memory are not shown: a page's WebContent process is not Pilot's to attribute, so the row says what runs.
struct WidgetsPage: View {
    @Environment(\.ink) private var ink
    @Bindable var model: WidgetsPageModel
    /// False in a render: nothing is read, and the model's rows are drawn as they are.
    var reads = true
    /// Each card's preview, read as the page opens (a render hands its own, filled).
    var previews: WidgetPreviews = .shared

    init(model: WidgetsPageModel = .shared, reads: Bool = true, previews: WidgetPreviews = .shared) {
        self.model = model; self.reads = reads; self.previews = previews
    }

    static let intro = "Widgets on the desktop, on an empty workspace, or on Home."
    static let introInfo = "They show while Show desktop holds the windows out too. Hyper+drag moves one, Hyper+right-drag resizes it, a right-click (or a Hyper+right click) opens its menu. A widget from elsewhere arrives locked: it runs nothing until you trust it."

    var body: some View {
        KitPage(intro: Self.intro, info: Self.introInfo) {
            if let note = model.note { Text(note).font(ink.ui(12)).foregroundStyle(ink.muted).padding(.top, 6) }
            ready
            // Your widgets waits until it holds something (simplify-pages T3); New widget is on Widgets. On the desktop
            // and On Home are one Placed list (simplify-pages T19).
            if !model.installed.isEmpty || !model.broken.isEmpty { yours }
            placed
        }
        .task {
            guard reads else { return }
            model.reload()
            // Each card's preview, in the style and Glass of the moment, before it is added.
            await previews.load(ReadyWidgets.all + model.installed, store: model.store)
        }
        .onDisappear { if reads { previews.drop() } }
        // A widget folder or .zip dropped on the page imports, locked, as Import folder… does.
        .dropDestination(for: URL.self) { urls, _ in
            // Files on this Mac only: a dropped web link is no widget.
            let picked = urls.filter { $0.isFileURL && ($0.hasDirectoryPath || $0.pathExtension.lowercased() == "zip") }
            picked.forEach(model.importFolder)
            return !picked.isEmpty
        }
        .modifier(WidgetsPageSheets(model: model))
    }

    private var ready: some View {
        KitBlock(title: "Widgets", symbol: "square.grid.2x2", note: "Pilot's own, read-only and trusted; off until you add one.") {
            newWidget
        } content: {
            CardGrid(minimum: 260, spacing: 8, stretch: true) {
                ForEach(ReadyWidgets.all, id: \.id) { card($0, ready: true) }
            }
            .padding(.vertical, 10)
        }
        .pageWide()
    }

    private var yours: some View {
        KitBlock(title: "Your widgets", symbol: "folder") {
            VStack(alignment: .leading, spacing: 8) {
                CardGrid(minimum: 300, spacing: 8, stretch: true) {
                    ForEach(model.installed, id: \.id) { card($0, ready: false) }
                }
                ForEach(model.broken, id: \.folder) { broken in
                    HStack(spacing: 6) {
                        Chip(text: "doesn't read", color: ink.yellow)
                        Text("\(broken.folder): \(broken.why)").font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .pageWide()
    }

    /// Every way to a widget of your own, in one menu: the AI chat, the builder, an import, the folder.
    private var newWidget: some View {
        Menu {
            Button("Create with AI") { AIChatPanel.shared.show(typing: WidgetMaker.command + " ") }
                .help("Opens the AI chat with /widget typed: describe the widget, or paste or drop a picture of one")
            Button("New widget…") { model.building = true }.help("Pick a look and a source; no AI needed")
            Button("Import…") { model.chooseFolder() }.help("A widget folder or .zip; or drop one on this page")
            Divider()
            Button("Show folder") { model.showFolder() }
        } label: {
            Label("New widget", systemImage: "plus")
        }
        .menuStyle(.button).buttonStyle(.pilot).fixedSize()
    }

    /// Every widget placed, on the desktop first, then on Home (simplify-pages T19: were two blocks).
    private var placed: some View {
        KitBlock(title: "Placed", symbol: "macwindow",
                 note: "On the desktop, or on Home, where each runs only while Home draws it; Edit Home moves, sizes and hides those.") {
            VStack(alignment: .leading, spacing: 6) {
                if model.placements.isEmpty {
                    Text("Nothing yet: Add to desktop or Add to Home on any widget above.").font(ink.ui(12)).foregroundStyle(ink.muted)
                }
                ForEach(model.placements.filter { !$0.onHome } + model.placements.filter(\.onHome), id: \.id) { placement in
                    row(placement) {
                        Text(placement.onHome ? "On Home" : "On the desktop, at \(Int(placement.x * 100)) %, \(Int(placement.y * 100)) % of \(placement.screen == nil ? "the main display" : "its display")")
                            .font(ink.ui(11.5)).foregroundStyle(ink.muted)
                        Spacer(minLength: 6)
                        if !placement.onHome { workspacePicker(placement) }
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    /// A placement's row: its widget, what `detail` says, then Edit… and Remove.
    private func row(_ placement: Widget.Placement, @ViewBuilder detail: () -> some View) -> some View {
        HStack(spacing: 8) {
            let widget = model.widget(placement.widget)
            Text(widget?.icon ?? "🧩")
            Text(widget?.title ?? placement.widget).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text)
            detail()
            Button("Edit…") { model.editing = placement.id }.buttonStyle(.pilot).help("Edit widget: this one's own settings")
            Button("Remove") { model.remove(placement) }.buttonStyle(.pilot)
        }
    }

    /// Every workspace, or one: the workspace it is kept to stays listed even when the tiler no longer keeps it.
    private func workspacePicker(_ placement: Widget.Placement) -> some View {
        let names = model.workspaces(keeping: placement.workspace)
        return Menu(placement.workspace.map { "Workspace \($0)" } ?? "All workspaces") {
            Button("All workspaces") { model.show(placement, on: nil) }
            Divider()
            ForEach(names, id: \.self) { name in Button("Workspace \(name)") { model.show(placement, on: name) } }
        }
        .fixedSize().help("Where it shows: on every empty workspace, or on one only")
    }

    /// A widget as a card: its preview, its icon, title, what feeds it and its trust, then its buttons.
    private func card(_ widget: Widget, ready: Bool) -> some View {
        let trust = model.trust[widget.id] ?? .locked
        return VStack(alignment: .leading, spacing: 6) {
            if let tile = previews.models[widget.id] {
                WidgetPreview(widget: widget, model: tile, shot: previews.shots[widget.id])
            } else {
                WidgetPreview.ground(Look.shared.theme).frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 8) {
                Text(widget.icon).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text(widget.title).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    Text(Self.feeds(widget)).font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if ready { Chip(text: "Pilot's") }
                else if trust == .locked { Chip(text: "locked", color: ink.yellow, symbol: "lock.fill") }
                else { Chip(text: trust == .madeHere ? "made here" : "trusted", color: ink.green) }
            }
            if let description = widget.description {
                Text(description).font(ink.ui(11.5)).foregroundStyle(ink.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // Where it is placed, as chips, so a placed widget never reads as one still to add (Sven, build 3).
            let (desk, home) = (model.placed(widget.id), model.placed(widget.id, home: true))
            if desk + home > 0 {
                HStack(spacing: 6) {
                    if desk > 0 { Chip(text: desk == 1 ? "On the desktop" : "On the desktop ×\(desk)", color: ink.green, symbol: "checkmark") }
                    if home > 0 { Chip(text: home == 1 ? "On Home" : "On Home ×\(home)", color: ink.green, symbol: "checkmark") }
                }
            }
            HStack(spacing: 6) {
                Button(desk > 0 ? "Add another" : "Add to desktop") { model.add(widget) }.buttonStyle(.pilot)
                    .help(desk > 0 ? "Put another copy on the desktop, with settings of its own" : "Put it on the desktop")
                Button("Add to Home") { model.addHome(widget) }.buttonStyle(.pilot)
                if !ready, trust == .locked, WidgetAsks.runsOnShow(widget) || WidgetAsks.acts(widget) { Button("Trust this widget…") { model.asking = widget.id }.buttonStyle(.pilot) }
                Menu {
                    Button("Duplicate to edit") { model.duplicate(widget) }
                    if !ready {
                        Button("Show folder") { model.showFolder(widget) }
                        Divider()
                        Button("Uninstall…", role: .destructive) { model.uninstalling = widget.id }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .innerCard()
    }

    /// "Blocks · reading cpu, memory", "Page · command every 60 s".
    static func feeds(_ widget: Widget) -> String {
        "\(widget.draw == .html ? "Page" : "Blocks") · \(widget.data.label)"
    }
}

/// The page's questions: Trust this widget, a widget's settings, and Uninstall's confirm.
private struct WidgetsPageSheets: ViewModifier {
    @Bindable var model: WidgetsPageModel

    private struct Sheet: Identifiable { let widget: Widget; var id: String { widget.id } }
    private struct EditSheet: Identifiable { let widget: Widget, placement: Widget.Placement; var id: String { placement.id } }

    private func editSheet(_ id: String) -> EditSheet? {
        guard let placement = model.placements.first(where: { $0.id == id }), let widget = model.widget(placement.widget) else { return nil }
        return EditSheet(widget: widget, placement: placement)
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.asking.flatMap(model.widget).map(Sheet.init) }, set: { _ in model.asking = nil })) { sheet in
                WidgetTrustQuestion(widget: sheet.widget, store: model.store, trust: { model.trust(sheet.widget.id) }, cancel: { model.asking = nil })
            }
            .sheet(item: Binding(get: { model.editing.flatMap(editSheet) }, set: { _ in model.editing = nil })) { sheet in
                WidgetEditSheet(widget: sheet.widget, placement: sheet.placement, values: model.store.values(of: sheet.widget, placement: sheet.placement),
                                workspaces: model.workspaces(keeping: sheet.placement.workspace), choices: .live,
                                save: { model.edit(sheet.placement, values: $0, passwords: $1, workspace: $2) }, cancel: { model.editing = nil })
            }
            .sheet(isPresented: $model.building) {
                WidgetBuilderSheet(store: model.store, saved: { widget in
                    model.building = false
                    model.note = "\(widget.title) is in your widgets, made here: Add to desktop to see it."
                    model.reload()
                }, cancel: { model.building = false })
            }
            .confirmationDialog("Move this widget to the Trash?", isPresented: Binding(get: { model.uninstalling != nil }, set: { if !$0 { model.uninstalling = nil } })) {
                Button("Uninstall", role: .destructive) { if let id = model.uninstalling { model.uninstall(id) } }
            } message: {
                Text("Its folder goes to the Trash and it leaves the desktop. Its settings stay, should you install it again.")
            }
    }
}

/// The Trust sheet as the page opens it: what waits under the widget's id read once, off the main thread (a file and a
/// Keychain query that may wait), Trust disabled and the line saying so until the read returns.
struct WidgetTrustQuestion: View {
    let widget: Widget, store: WidgetStore
    let trust: () -> Void, cancel: () -> Void
    /// Nil while the read runs; then the line, or "" when nothing waits under the id.
    @State private var inherits: String?

    var body: some View {
        WidgetTrustSheet(widget: widget, inherits: inherits ?? "Checking what is saved under \(widget.id)…", checking: inherits == nil,
                         trust: trust, cancel: cancel)
            .task { let (store, widget) = (store, widget); inherits = await Task.detached { store.inherits(widget) ?? "" }.value }
    }
}

/// Trust this widget (Q676): everything it will be given power for, in the card's words, then Trust or Cancel.
struct WidgetTrustSheet: View {
    @Environment(\.ink) private var ink
    let widget: Widget
    /// WidgetStore.inherits: what was saved under its id before; empty or nil when nothing waits.
    var inherits: String?
    /// The line above is still being read: Trust waits for it.
    var checking = false
    let trust: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trust \(WidgetAsks.shown(widget.title))?").font(ink.ui(15, .semibold)).foregroundStyle(ink.text)
            Text("Trusted, it runs as you, as anything you run does. It came from \(WidgetAsks.shown(widget.folder.path)).")
                .font(ink.ui(12)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
            WidgetAskingView(asking: WidgetAsks.asking(widget), font: ink.ui(12))
            // Saved under this id before (an uninstalled widget's, or the one it replaced): trusting hands it over.
            if let inherits, !inherits.isEmpty { Text(inherits).font(ink.ui(12, .semibold)).foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                Button("Trust this widget", action: trust).buttonStyle(.pilotPrimary).disabled(checking)
            }
        }
        .padding(18).frame(width: 460).pilotSheet()
    }
}
