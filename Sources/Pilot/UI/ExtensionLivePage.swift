import AppKit
import Observation
import PilotCore
import SwiftUI

/// A Raycast extension's page running one of its view commands live (T30), as Hyper+Space runs it: the same session
/// (ExtensionListSession over the command's host), the same navigator ranking its rows and holding Cmd+K's actions, and
/// the same picks: Return presses the selected row's first action, Cmd+K lists them all, a push opens its view over this
/// one (Escape goes back), a form opens in its own panel (ExtensionFormPanel), a press that changes the list is drawn as
/// the host answers. Its host runs only while the page shows: leaving the page, or the window going away, stops it, as a
/// kept page stops its timers (9ca2f84); showing it again starts the command afresh.
@Observable @MainActor
final class ExtensionLivePageModel {
    let ext: Extension
    /// The command it runs: the first live one unless Sven picked another.
    private(set) var command: Extension.Command
    /// The shown view's rows, search, selection and Cmd+K actions.
    var nav: MenuNavigator
    /// Why the command can't run now (a required setting unset, its folders); nil while it runs.
    private(set) var problem: String?
    /// The views under the shown one, nearest last, each with its source.
    @ObservationIgnored private var below: [(nav: MenuNavigator, source: any MenuSource)] = []
    @ObservationIgnored private var source: (any MenuSource)?
    @ObservationIgnored private let storage: ExtensionStorage
    /// A start under way: a second one while it reads the inputs waits for it instead of starting the command twice.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// Makes the command's session; a test's stand-in.
    @ObservationIgnored var session: (Extension, Extension.Command, ExtensionRun.Inputs) -> any MenuSource = { ExtensionListSession($0, $1, inputs: $2) }

    /// The commands a page can run live: a Raycast extension's views with no argument to type (an argument's command
    /// opens in Hyper+Space, where its keyword takes the words; a menu-bar command is its bar item).
    nonisolated static func commands(of ext: Extension) -> [Extension.Command] {
        ext.commands.filter { $0.runtime == .raycast && $0.mode == .list && !$0.hidden && $0.keyword == nil }
    }

    /// The commands its page offers to open in Hyper+Space instead: the rest of its commands Hyper+Space lists.
    nonisolated static func elsewhere(of ext: Extension) -> [Extension.Command] {
        let live = Set(commands(of: ext).map(\.name))
        return ext.commands.filter { $0.runtime == .raycast && !$0.hidden && !live.contains($0.name) }
    }

    /// nil when `ext` has no command a page can run live.
    init?(_ ext: Extension, storage: ExtensionStorage = ExtensionStorage()) {
        guard let first = Self.commands(of: ext).first else { return nil }
        self.ext = ext
        self.storage = storage
        command = first
        nav = MenuNavigator(list: [], live: true)
    }

    /// Views pushed over the command's own.
    var depth: Int { below.count }
    var running: Bool { source != nil }

    /// Starts the command's host, unless it runs or is starting.
    func start() async {
        if let starting { return await starting.value }
        guard source == nil else { return }
        let task = Task {
            var why: String?
            guard let inputs = await ExtensionsModule.inputs(for: ext, command: command, storage: storage, hud: { why = $0 }) else {
                problem = why ?? "\(ext.title) can't run here."
                return
            }
            guard !Task.isCancelled else { return }
            problem = nil
            dlog.notice("extension page: \(self.command.actionID, privacy: .public) runs live")
            attach(session(ext, command, inputs), search: true)
        }
        starting = task
        await task.value
        starting = nil
    }

    /// The page went away: every view's source stops, the host with the bottom one; the next start begins afresh.
    func stop() {
        starting?.cancel()
        guard let source else { return }
        source.close()
        below.reversed().forEach { $0.source.close() }
        below = []
        self.source = nil
        nav = MenuNavigator(list: [], live: true)
        dlog.notice("extension page: \(self.command.actionID, privacy: .public) stopped")
    }

    /// Runs `command` in place of the one shown.
    func choose(_ command: Extension.Command) async {
        guard command.name != self.command.name else { return }
        stop()
        self.command = command
        await start()
    }

    /// The search field's text: the shown view hears it, as Hyper+Space's does.
    var query: String {
        get { nav.query }
        set {
            guard newValue != nav.query else { return }
            nav.query = newValue
            source?.search(newValue)
        }
    }

    /// A key in the search field, as the panel's key monitor hands it to the navigator; false when the field keeps it.
    func handle(_ key: MenuNavigator.Key) -> Bool {
        follow(nav.handle(key))
    }

    /// The action `index` of `row` (0 is Return's), as a pick would press it.
    func action(_ index: Int, for row: MenuEntry) -> Extension.Item.Action? { (source as? ExtensionListSession)?.action(index, for: row) }

    /// A click on row `index` is Return on it; on Cmd+K's action `index`, that action.
    func click(_ index: Int) { _ = follow(nav.click(at: index)) }
    func clickAction(_ index: Int) { _ = follow(nav.clickAction(at: index)) }

    /// A detail's own button: its action among the detail's, pressed as Cmd+K's would be.
    func runDetail(_ action: Extension.Item.Action) {
        guard let row = nav.selected, let index = nav.shownDetail?.actions.firstIndex(where: { $0.kind == action.kind }) else { return }
        _ = follow(.own(index, row))
    }

    private func follow(_ outcome: MenuNavigator.Outcome) -> Bool {
        switch outcome {
        case .ignored: return false
        case .run(let row): follow(source?.pick(row, action: 0))
        case .own(let index, let row): follow(source?.pick(row, action: index))
        // Escape: back from a pushed view; the command's own view stays, as the page is its home.
        case .close, .back: _ = pop()
        default: break
        }
        return true
    }

    /// What the session made of a pick, as PilotMenu.follow does with the panel left where it is.
    private func follow(_ pick: MenuPick?) {
        guard let pick else { return }
        switch pick {
        case .close(let then): then()
        case .push(let title, let next):
            guard let current = source else { return next.close() }
            detach(current)
            below.append((nav, current))
            nav = MenuNavigator(list: [], title: title, live: true)
            nav.query = next.opening
            attach(next, search: true)
        case .stay: break
        case .keep(let clear, let back, let run):
            if back { _ = pop() }
            guard let shown = source else { return }
            let ran = run()
            Task { [weak self] in
                await ran?.value
                guard let self, self.source === shown else { return }
                if clear { query = "" }
                let kept = await shown.refresh(keeping: nav.selected)
                guard self.source === shown, let kept, let at = nav.rows.firstIndex(where: { $0.id == kept }) else { return }
                nav.point(at: at)
            }
        }
    }

    /// Back from a pushed view: its source stops (the host goes back a view) and the one under it shows as it was.
    private func pop() -> Bool {
        guard let last = below.popLast() else { return false }
        source?.close()
        nav = last.nav
        attach(last.source, search: false)
        (last.source as? ExtensionListSession)?.redraw()
        return true
    }

    private func attach(_ next: any MenuSource, search: Bool) {
        source = next
        next.show = { [weak self] in self?.nav.replaceList($0) }
        if let list = next as? ExtensionListSession {
            list.showEmpty = { [weak self] in self?.nav.emptyView = $0 }
            list.showSearch = { [weak self] in self?.nav.query = $0 }
            list.showChrome = { [weak self] in self?.nav.chrome = $0 }
            if nav.chrome == nil { nav.chrome = list.openingChrome }
        }
        if search { next.search(nav.query) }
    }

    private func detach(_ old: any MenuSource) {
        old.show = { _ in }
        (old as? ExtensionListSession)?.showEmpty = { _ in }
        (old as? ExtensionListSession)?.showSearch = { _ in }
        (old as? ExtensionListSession)?.showChrome = { _ in }
    }
}

/// The live page (T30): its search over the shown view's rows, the selected one raised; Cmd+K's actions over the list;
/// a detail, an empty view or a pushed view in its place; the keys at its foot. The header (ExtensionSurfacePage's)
/// stays above it.
struct ExtensionLivePage: View {
    @Environment(\.ink) private var ink
    @Bindable var model: ExtensionLivePageModel
    /// The window shows the page: only then does its command run.
    let onScreen: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
            ink.line.frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ink.line.frame(height: 1)
            foot
        }
        .task(id: onScreen) {
            guard onScreen else { return model.stop() }
            await model.start()
            focused = true
        }
        .onDisappear { model.stop() }
    }

    private var search: some View {
        HStack(spacing: 10) {
            if model.depth > 0 {
                IconButton(symbol: "chevron.left", label: "Back", size: 24, glyph: 11) { _ = model.handle(.escape) }
            }
            // A Raycast view's search bar placeholder as Raycast's (T31); a Detail has none.
            TextField(model.nav.isRaycast ? MenuModel.placeholder(model.nav) : model.nav.title ?? "Search \(model.command.title)", text: $model.query)
                .textFieldStyle(.plain).font(ink.ui(14)).foregroundStyle(ink.text).focused($focused)
                .onKeyPress(phases: .down) { press in key(press) }
            let commands = ExtensionLivePageModel.commands(of: model.ext)
            if commands.count > 1 {
                Picker("Command", selection: Binding(get: { model.command.name }, set: { name in
                    if let picked = commands.first(where: { $0.name == name }) { Task { await model.choose(picked) } }
                })) {
                    ForEach(commands, id: \.name) { Text($0.title).tag($0.name) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal, ink.pageInset).padding(.vertical, 10)
    }

    /// The navigator's keys, as the panel's key monitor maps them (PilotMenu.key); any other key is typed.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        let key: MenuNavigator.Key? = switch press.key {
        case .upArrow: .up
        case .downArrow: .down
        case .return: command ? .commandReturn : .return
        case .escape: .escape
        case "k" where command: .commandK
        default: nil
        }
        guard let key else { return .ignored }
        return model.handle(key) ? .handled : .ignored
    }

    @ViewBuilder private var content: some View {
        let nav = model.nav
        if let problem = model.problem {
            EmptyState(title: "Can't run", line: problem)
        } else if let detail = nav.shownDetail {
            ExtensionDetailView(detail: detail, act: model.runDetail).padding(ink.pageInset)
        } else if let menu = nav.actions {
            actions(menu)
        } else if let empty = nav.emptyView {
            // Its actions ride the one row kept behind it (T28), so Return and Cmd+K press them.
            RaycastEmptyView(view: empty)
        } else if nav.rows.isEmpty {
            Text(model.running ? "\(model.command.title) is loading…" : "Starting \(model.command.title)…")
                .font(ink.ui(13)).foregroundStyle(ink.muted).padding(ink.pageInset)
        } else if nav.chrome?.showsDetail == true {
            // A Raycast List that shows details, as Hyper+Space draws it (T31).
            RaycastListWithDetail(detail: nav.selected?.sideDetail) { rows(nav) }
        } else {
            rows(nav)
        }
    }

    /// The rows as Hyper+Space draws a Raycast list (T31): Raycast's section headings, each row's icon, title, subtitle
    /// and accessories (InstrumentMenuRow).
    private func rows(_ nav: MenuNavigator) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nav.rows.enumerated()), id: \.offset) { index, row in
                        if let section = row.section, index == 0 || nav.rows[index - 1].section != section {
                            RaycastSectionHeader(title: section, subtitle: row.sectionSubtitle)
                                .padding(.horizontal, 12).padding(.top, index == 0 ? 4 : 12).padding(.bottom, 6)
                        }
                        InstrumentMenuRow(row: row, on: index == nav.selection, quiet: false, system: false, best: false, query: nav.query,
                                          alias: nil, layerKeys: [], tile: nil, window: nil, height: MenuPanelSize.lineRow)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { model.click(index) }
                    }
                }
                .padding(.horizontal, ink.pageInset - 8).padding(.vertical, 8)
            }
            .onChange(of: nav.selection) { reader.scrollTo(nav.selection) }
        }
    }

    private func actions(_ menu: RowActionsMenu) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions · \(menu.row.title)").font(ink.ui(11, .semibold)).foregroundStyle(ink.muted).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(Array(menu.visible.enumerated()), id: \.offset) { index, choice in
                Text(choice.title).font(ink.ui(13, index == menu.selection ? .semibold : .regular)).foregroundStyle(ink.text)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 30)
                    .background { if index == menu.selection { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink.line) } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickAction(index) }
            }
        }
        .padding(.horizontal, ink.pageInset - 8).padding(.vertical, 10)
    }

    /// As Raycast's: the command's icon and the view's navigation title, then Return's action on the selected row, Cmd+K,
    /// and Escape once a view is pushed.
    private var foot: some View {
        let nav = model.nav
        let first = nav.actions == nil ? nav.selected?.ownActions?.first : "Run"
        return HStack(spacing: 14) {
            RaycastFootPlace(chrome: nav.chrome, title: nav.title ?? model.command.title).font(ink.ui(11.5))
            Spacer()
            if let first { hint("↵", first) }
            if nav.actions != nil || !nav.selectedActions.isEmpty { hint("⌘K", nav.actions == nil ? "Actions" : "Close") }
            if model.depth > 0 || nav.actions != nil { hint("Esc", "Back") }
        }
        .padding(.horizontal, ink.pageInset).frame(height: 32)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(ink.mono(11)).foregroundStyle(ink.text2)
            Text(label).font(ink.ui(11.5)).foregroundStyle(ink.muted)
        }
    }
}
