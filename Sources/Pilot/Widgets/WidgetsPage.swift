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

    /// "On the desktop twice", "Not on the desktop"; one saved on Home not counted (Home draws no widgets now).
    func placed(_ id: String) -> Int { placements.count { $0.widget == id && !$0.onHome } }

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

    /// A desktop widget's menu (its right-click, or a Hyper+right click): Edit widget and Remove from desktop under its
    /// title, then the workspaces it may show on, the one it shows on checked.
    func menu(for id: String) -> (sections: [(title: String, items: [(title: String, run: () -> Void)])], checked: Set<String>) {
        reload()
        guard let placement = placements.first(where: { $0.id == id }) else { return ([], []) }
        let all = "All workspaces"
        let shows: [(title: String, run: () -> Void)] = [(all, { self.show(placement, on: nil) })]
            + workspaces(keeping: placement.workspace).map { name in ("Workspace \(name)", { self.show(placement, on: name) }) }
        return ([(widget(placement.widget)?.title ?? placement.widget,
                  [("Edit widget…", { self.desk.editPlacement(id) }), ("Remove from desktop", { self.remove(placement) })]),
                 ("Shows on", shows)],
                [placement.workspace.map { "Workspace \($0)" } ?? all])
    }

    /// Takes a placement off by its id (the desktop's right-click Remove).
    func remove(id: String) {
        reload()
        if let placement = placements.first(where: { $0.id == id }) { remove(placement) }
    }

    func remove(_ placement: Widget.Placement) {
        save(store.placements().filter { $0.id != placement.id }, done: "Taken off the desktop.")
    }

    /// Add on the Widgets page's map (Q252 B): a new placement on `display`'s first free cells, nearest its room's top
    /// left, at the widget's own size in whole cells, Snap to grid on or off; its id, so the page picks it. `displays` are
    /// the ones the page shows, `display` alone when none are given.
    @discardableResult func add(_ widget: Widget, on display: WidgetsDisplay, among displays: [WidgetsDisplay]? = nil) -> String {
        var all = store.placements()
        let grid = Widget.Grid(area: display.room)
        let others = all.filter { display.holds($0, among: displays ?? [display]) }.map { $0.frame(on: display.frame) }
        var placement = Widget.Placement.new(widget, after: all.count, screen: display.uuid)
        placement.screenIdentity = display.identity
        let start = CGRect(x: display.room.minX, y: display.room.minY, width: widget.size.width, height: widget.size.height)
        if let cell = grid.pack(others + [start]).last { placement.land(on: grid.rect(cell), screen: display.frame) }
        all.append(placement)
        let on = placement.workspace.map { "workspace \($0)" } ?? "an empty workspace"
        save(all, done: "\(widget.title) is on \(display.name); it shows on \(on) or with Show desktop.")
        return placement.id
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
        do { try store.save(WidgetDesk.placed(placements)); note = done } catch { note = "Not saved: \(error.localizedDescription)" }
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

/// Look's Widgets page (T20; the desktop map, Sven 2026-11-15, Q252 B): the main display drawn small with each widget
/// where it sits on the grid, Snap to grid on the map; a click on one shows its own settings under the map, saved as
/// they are set; and every widget to add in a list, Add putting it on the map's first free cells. Trust this widget, Duplicate to edit, Show folder, Uninstall
/// and Import (a folder or .zip, or one dropped on the page) as before. Each widget's own CPU and memory are not shown:
/// a page's WebContent process is not Pilot's to attribute.
struct WidgetsPage: View {
    @Environment(\.ink) private var ink
    @Bindable var model: WidgetsPageModel
    /// False in a render: nothing is read, and the model's rows are drawn as they are.
    var reads = true
    /// Each widget's preview, read as the page opens (a render hands its own, filled).
    var previews: WidgetPreviews = .shared
    /// The displays the map may draw; nil reads the Mac's (a render hands its own).
    var displays: [WidgetsDisplay]?
    @Bindable private var snap = WidgetSnap.shared
    @State private var selected: String?
    @State private var displayID: String?

    init(model: WidgetsPageModel = .shared, reads: Bool = true, previews: WidgetPreviews = .shared, displays: [WidgetsDisplay]? = nil,
         selected: String? = nil) {
        self.model = model; self.reads = reads; self.previews = previews; self.displays = displays
        _selected = State(initialValue: selected)
    }

    static let intro = "Your desktop as it is. Click a widget to change it, or add one from the list."
    static let introInfo = "Widgets show on an empty workspace, or while Show desktop holds the windows out. On the desktop, Hyper+drag moves one and Hyper+right-drag resizes it, on whole cells of the grid while Snap to grid is on; a right-click (or a Hyper+right click) opens its menu. A widget from elsewhere arrives locked: it runs nothing until you trust it."
    static let snapInfo = "Desktop widgets move and resize a whole cell at a time, so their edges and gaps line up; the grid shows faintly while you drag one. Turned on, the ones already there go to the nearest free cells."

    var body: some View {
        let shown = displays ?? WidgetsDisplay.live()
        let display = shown.first { $0.id == displayID } ?? shown.first
        KitPage(intro: Self.intro, info: Self.introInfo) {
            if let note = model.note { Text(note).font(ink.ui(12)).foregroundStyle(ink.text2).padding(.top, 6) }
            VStack(alignment: .leading, spacing: 10) {
                header(shown, display)
                if let display {
                    WidgetsMap(display: display, placements: model.placements.filter { display.holds($0, among: shown) }, widget: model.widget,
                               snap: snap.on, selected: $selected)
                }
            }
            .padding(.top, 8)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    inspector.frame(minWidth: 400, maxWidth: .infinity, alignment: .topLeading)
                    list(display, shown).frame(width: 290)
                }
                VStack(alignment: .leading, spacing: 20) {
                    inspector
                    list(display, shown)
                }
            }
            .padding(.top, 16).padding(.bottom, 20)
        }
        .task {
            guard reads else { return }
            model.reload()
            // Each widget's preview, in the style and Glass of the moment, before it is added.
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

    /// The display and its size (a menu with more than one), Snap to grid.
    private func header(_ shown: [WidgetsDisplay], _ display: WidgetsDisplay?) -> some View {
        HStack(spacing: 12) {
            if let display {
                if shown.count > 1 {
                    Menu("\(display.name) · \(display.size)") {
                        ForEach(shown) { one in Button("\(one.name) · \(one.size)") { displayID = one.id; selected = nil } }
                    }
                    .fixedSize()
                } else {
                    Text("\(display.name) · \(display.size)").font(ink.ui(11.5)).foregroundStyle(ink.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text("Snap to grid").font(ink.ui(12.5)).foregroundStyle(ink.text).fixedSize()
                InfoMark(text: Self.snapInfo)
                Toggle("Snap to grid", isOn: $snap.on).toggleStyle(.pilotSwitch).labelsHidden()
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if let placement = model.placements.first(where: { $0.id == selected && !$0.onHome }), let widget = model.widget(placement.widget) {
            WidgetsInspector(model: model, placement: placement, widget: widget, previews: previews)
        } else {
            Text("Click a widget on the map to change it.")
                .font(ink.ui(12)).foregroundStyle(ink.text2)
        }
    }

    private func list(_ display: WidgetsDisplay?, _ shown: [WidgetsDisplay]) -> some View {
        WidgetsAddList(model: model) { widget in
            if let display { selected = model.add(widget, on: display, among: shown) }
            else { model.add(widget) }
        }
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
