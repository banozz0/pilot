import PilotCore
import SwiftUI

/// Launcher › Your menu (story 152, task N6; on Defaults until C3): the Hyper+Space root's rows in Sven's order, each with a switch that shows
/// it before typing, and a drag onto another row to move it there; the picked row (the first until a click picks
/// another) shows up and down arrows, and VoiceOver moves any row (simplify-pages T15: hover-only controls are a don't,
/// DESIGN.md). Reset brings today's root back. A hidden branch still answers a search by its name. The More rows
/// switched on stand among them and move the same way; their switch turns them off (Sven 2026-10-20). An ⓘ only where
/// a row's name can't say what it holds (Sven's Q3).
struct MenuRootBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: MenuRootSettings
    /// The row whose arrows show, by id so it follows a move; nil or gone (an extra switched off under More rows) is the first.
    @State private var picked: String?

    static let note = "The rows Hyper+Space lists before you type, in your order. A hidden row still comes up when you type its name."

    /// What a root branch holds, for its ⓘ: only the branches whose names don't say it; the rest show none (Sven's Q3).
    static let holds: [MenuBranch: String] = [
        .learn: "Your keybindings, to look one up or run it.",
        .trigger: "Captures, emoji, the colour picker, clipboard, stickers and GIFs, translate, reminders, snippets, notes and AI.",
        .clean: "Mole's clean of caches and leftovers, previewed first, and Disk usage.",
    ]

    var body: some View {
        let list = settings.root.rows()
        let pick = list.first { $0.id == picked }?.id ?? list.first?.id
        KitBlock(title: "What the menu shows first", symbol: "list.bullet", note: Self.note) {
            if !settings.root.isDefault() {
                Button("Reset to default") { withAnimation(Kit.change) { settings.reset() } }.buttonStyle(.pilot)
            }
        } content: {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                let on = row.id == pick
                BlockRow(first: i == 0) { self.row(row, at: i, of: list.count, picked: on) }
                    .background { if on { KitRowBackground(selected: true).padding(.horizontal, -8) } }
                    .contentShape(.rect)
                    // A click anywhere on the row picks it, its switch's too.
                    .simultaneousGesture(TapGesture().onEnded { if !on { picked = row.id } })
                    .accessibilityAction(named: "Move \(row.title) up") { move(row, to: i - 1) }
                    .accessibilityAction(named: "Move \(row.title) down") { move(row, to: i + 1) }
                    .draggable(row.id) { Text(row.title).padding(4) }
                    .dropDestination(for: String.self) { dropped, _ in
                        guard let moved = list.first(where: { $0.id == dropped.first }) else { return false }
                        move(moved, to: i)
                        return true
                    }
            }
        }
    }

    private func row(_ row: MenuRoot.Row, at i: Int, of count: Int, picked on: Bool) -> some View {
        let shown = settings.root.isShown(row)
        // The pick is KitRow's: Toybox's sun takes the row's ink on it (ink.rowLit), Instrument's raised row keeps its colours.
        return HStack(spacing: 10) {
            GripDots().foregroundStyle(ink.rowQuiet(on)).frame(width: 14).help("Drag to move")
            MenuRowIcon(row: row, on: on).font(ink.ui(12.5)).frame(width: 18)
            Text(row.title).foregroundStyle(ink.rowLit(on, shown ? ink.text : ink.muted))
            if let holds = row.branch.flatMap({ Self.holds[$0] }) {
                InfoMark(text: holds + " The switch shows it before you type.").foregroundStyle(ink.rowQuiet(on))
            }
            Spacer()
            if on {
                IconButton(symbol: "chevron.up", label: "Move \(row.title) up", size: 22, glyph: 11, tint: ink.rowLit(on, ink.text2)) { move(row, to: i - 1) }
                    .disabled(i == 0).kitDimmed(i > 0)
                IconButton(symbol: "chevron.down", label: "Move \(row.title) down", size: 22, glyph: 11, tint: ink.rowLit(on, ink.text2)) { move(row, to: i + 1) }
                    .disabled(i == count - 1).kitDimmed(i < count - 1)
            }
            Toggle("Show \(row.title)", isOn: Binding(get: { shown }, set: { show in withAnimation(Kit.change) { settings.root.show(row, show) } }))
                .labelsHidden().toggleStyle(.pilotSwitch)
        }
    }

    /// Past either end does nothing.
    private func move(_ row: MenuRoot.Row, to index: Int) {
        guard settings.root.rows().indices.contains(index) else { return }
        withAnimation(Kit.change) { settings.root.move(row, to: index) }
    }
}

/// A root row's icon: a branch's in its colour, an extra's that opens a branch too (Notes) the same; any other extra's
/// own symbol. Your menu's rows and the preview beside them draw it; on a picked row it takes the row's ink.
struct MenuRowIcon: View {
    @Environment(\.ink) private var ink
    let row: MenuRoot.Row
    let on: Bool

    var body: some View {
        let branch: MenuBranch? = switch row {
        case .branch(let b): b
        case .extra(let e): if case .branch(let b) = e.target { b } else { nil }
        }
        Image(systemName: branch?.look.symbol ?? row.extra?.symbol ?? "circle")
            .foregroundStyle(ink.rowLit(on, branch.map { ink.module($0.look.colour) } ?? ink.text))
    }
}

/// Launcher's preview (simplify-pages T26, the prototype's Hyper+Space shows): the root as the menu lists it before you
/// type, from the same `shownRows()` the menu reads, so a switch or a move on Your menu changes it at once. One drawing
/// whatever Look's menu layout: a prompt line, the rows under `go to`, the first current, and the status line's keys.
struct MenuRootPreview: View {
    @Environment(\.ink) private var ink
    let settings: MenuRootSettings

    /// The rows the preview has room for beside Your menu; the menu itself scrolls to the rest.
    static let maxRows = 10
    static let width: CGFloat = 250

    var body: some View {
        let rows = settings.root.shownRows().prefix(Self.maxRows)
        let frame = RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous)
        KitBlock(title: "Hyper+Space shows", symbol: "eye") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("❯").foregroundStyle(ink.accent)
                    Text("Search").foregroundStyle(ink.muted)
                }
                .font(ink.mono(12)).padding(.horizontal, 12).frame(height: 32)
                ClassicHeading(title: "go to", height: 22)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    let current = i == 0
                    HStack(spacing: 9) {
                        MenuRowIcon(row: row, on: current).font(ink.ui(11)).frame(width: 16)
                        Text(row.title).font(ink.ui(12)).foregroundStyle(ink.rowLit(current, ink.text)).lineLimit(1)
                    }
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background { if current { KitRowBackground(selected: true).padding(.horizontal, 4) } }
                }
                Text("↵ open · ⌘K actions").font(ink.mono(10.5)).foregroundStyle(ink.muted)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 26, alignment: .trailing)
            }
            .padding(.vertical, 4)
            // MiniDesktop's well, so the pages' previews read alike.
            .background(ink.well)
            .clipShape(frame)
            .overlay { frame.strokeBorder(ink.line2, lineWidth: 1) }
            .padding(.vertical, 10)
            .animation(Kit.change, value: rows.map(\.id))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hyper+Space lists " + rows.map(\.title).joined(separator: ", "))
        }
        .frame(width: Self.width)
    }
}

/// Launcher › More rows (Sven 2026-10-20; on More from simplify-pages T15 until pages round 4): the rows the root can list among its branches, each off until its
/// switch is on, then last in What the menu shows first, to move there: a branch that lives deeper, opened where it lives (Notes in
/// Actions), an action with no branch, run at once (Dictation), a page of Pilot's window (Stats), or the Files view.
/// `pilot set menu.extra.<id>` flips the same switch; the Ring menu's Pilot ring lists the ones on, in that list's order.
struct MenuExtrasBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: MenuRootSettings

    static let note = "Rows Hyper+Space can list too, off until you switch them on. One switched on joins What the menu shows first, to move there."

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
