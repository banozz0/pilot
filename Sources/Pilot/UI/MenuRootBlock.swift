import PilotCore
import SwiftUI

/// Launcher › Your menu (story 152, task N6; on Defaults until C3): the Hyper+Space root's rows in Sven's order, each with a switch that shows
/// it before typing, up and down arrows, and a drag onto another row to move it there; Reset brings today's root back.
/// A hidden branch still answers a search by its name. The More rows switched on stand among them and move the same
/// way; their switch turns them off (Sven 2026-10-20). Each row's ⓘ says what it holds (page map, Sven 2026-10-17:
/// every row has one).
struct MenuRootBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: MenuRootSettings

    static let note = "The rows Hyper+Space lists before you type, in your order. A hidden row still comes up when you type its name."

    /// What each root branch holds, for its ⓘ; a branch without a line says what the switch does.
    static let holds: [MenuBranch: String] = [
        .apps: "Every app on this Mac, to open or bring forward.",
        .learn: "Your keybindings, to look one up or run it.",
        .trigger: "Captures, emoji, the colour picker, clipboard, stickers and GIFs, translate, reminders, snippets, notes and AI.",
        .install: "Apps and tools to install, by category, Homebrew's search and web apps.",
        .remove: "The apps and tools Pilot can remove.",
        .update: "Update all, and the apps and tools with an update waiting.",
        .clean: "Mole's clean of caches and leftovers, previewed first, and Disk usage.",
        .config: "Your config files, to open one in your editor.",
        .extensions: "Your extensions' commands, and the catalogue to add more.",
        .system: "Power, sound, Wi-Fi and Bluetooth, the display, Focus and fixes.",
    ]

    static func info(_ branch: MenuBranch) -> String {
        (holds[branch] ?? "A row of Hyper+Space's root.") + " The switch shows it before you type."
    }

    var body: some View {
        let list = settings.root.rows()
        KitBlock(title: "Root rows", symbol: "list.bullet", note: Self.note) {
            if !settings.root.isDefault() {
                Button("Reset to default") { withAnimation(Kit.change) { settings.reset() } }.buttonStyle(.pilot)
            }
        } content: {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                BlockRow(first: i == 0) { self.row(row, at: i, of: list.count) }
                    .draggable(row.id) { Text(row.title).padding(4) }
                    .dropDestination(for: String.self) { dropped, _ in
                        guard let moved = list.first(where: { $0.id == dropped.first }) else { return false }
                        move(moved, to: i)
                        return true
                    }
            }
        }
    }

    private func row(_ row: MenuRoot.Row, at i: Int, of count: Int) -> some View {
        let shown = settings.root.isShown(row)
        return HStack(spacing: 10) {
            GripDots().foregroundStyle(ink.muted).frame(width: 14).help("Drag to move")
            icon(row).font(ink.ui(12.5)).frame(width: 18)
            Text(row.title).foregroundStyle(shown ? ink.text : ink.muted)
            InfoMark(text: row.branch.map(Self.info) ?? row.extra.map(MenuExtrasBlock.info) ?? "")
            Spacer()
            IconButton(symbol: "chevron.up", label: "Move \(row.title) up", size: 22, glyph: 11) { move(row, to: i - 1) }
                .disabled(i == 0).kitDimmed(i > 0)
            IconButton(symbol: "chevron.down", label: "Move \(row.title) down", size: 22, glyph: 11) { move(row, to: i + 1) }
                .disabled(i == count - 1).kitDimmed(i < count - 1)
            Toggle("Show \(row.title)", isOn: Binding(get: { shown }, set: { on in withAnimation(Kit.change) { settings.root.show(row, on) } }))
                .labelsHidden().toggleStyle(.pilotSwitch)
        }
    }

    private func move(_ row: MenuRoot.Row, to index: Int) { withAnimation(Kit.change) { settings.root.move(row, to: index) } }

    /// A branch's icon in its colour, an extra that opens a branch too (Notes); any other extra's own symbol.
    private func icon(_ row: MenuRoot.Row) -> some View {
        let branch: MenuBranch? = switch row {
        case .branch(let b): b
        case .extra(let e): if case .branch(let b) = e.target { b } else { nil }
        }
        return Image(systemName: branch?.look.symbol ?? row.extra?.symbol ?? "circle")
            .foregroundStyle(branch.map { ink.module($0.look.colour) } ?? ink.text)
    }
}

/// Launcher › Your menu › More rows (Sven 2026-10-20): the rows the root can list among its branches, each off until its
/// switch is on, then last in Root rows, to move there: a branch that lives deeper, opened where it lives (Notes in
/// Trigger), an action with no branch, run at once (Dictation), a page of Pilot's window (Stats), or the Files view.
/// `pilot set menu.extra.<id>` flips the same switch; the Ring menu's Pilot ring lists the ones on, in Root rows' order.
struct MenuExtrasBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: MenuRootSettings

    static let note = "Rows Hyper+Space can list too, off until you switch them on. One switched on joins Root rows, to move there."

    var body: some View {
        let extras = MenuRoot.extraRows
        KitBlock(title: "More rows", symbol: "plus.rectangle.on.rectangle", note: Self.note) {
            ForEach(Array(extras.enumerated()), id: \.element.id) { i, extra in
                BlockRow(first: i == 0) { row(extra) }
            }
        }
    }

    private func row(_ extra: MenuRoot.Extra) -> some View {
        let on = settings.root.extras.contains(extra.id)
        return HStack(spacing: 10) {
            Image(systemName: extra.symbol).font(ink.ui(12.5)).foregroundStyle(on ? ink.text : ink.muted).frame(width: 18)
            Text(extra.title).foregroundStyle(on ? ink.text : ink.muted)
            InfoMark(text: Self.info(extra))
            Spacer()
            Toggle("Show \(extra.title)", isOn: Binding(get: { on }, set: { new in withAnimation(Kit.change) { settings.root.show(extra: extra.id, new) } }))
                .labelsHidden().toggleStyle(.pilotSwitch)
        }
    }

    /// Where the row lives today, or what it runs.
    static func info(_ extra: MenuRoot.Extra) -> String {
        switch extra.target {
        case .branch(let b) where b.parent == nil: "\(b.title), which a search at the root finds by name. The switch lists it at the root."
        case .branch(let b): "\(b.title), which also lives in \(b.parent?.title ?? "the menu"). The switch lists it at the root."
        case .searchFiles: "Opens the Files view, to search files by name. The switch lists it at the root."
        case .openPage(let place): "Opens Pilot's \(place.page.title) page. The switch lists it at the root."
        default: "Runs \(extra.title) at once. The switch lists it at the root."
        }
    }
}
