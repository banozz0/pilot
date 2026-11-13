import PilotCore
import SwiftUI

/// Which widget's settings the Dock page has open: set by a widget's right-click Widget settings…, so the page opens on
/// that widget's row with its settings showing (round 4, Sven 2026-11-13: "customise widgets aswell").
@Observable @MainActor
final class DockPageFocus {
    static let shared = DockPageFocus()
    var editing: DockSlot?

    /// The Dock page, with `slot`'s settings open (none: the page's top).
    func open(_ slot: DockSlot?) {
        editing = slot
        AppWindowController.shared.open(.dock)
    }

    /// Whether `slot` has settings of its own: System stats' picks, or the preferences of the extension it reads.
    static func hasSettings(_ slot: DockSlot) -> Bool { slot == .widget(.system) || slot.extensionID != nil }
}

/// Settings › Desktop › Dock (round 4, Sven 2026-11-13: "maybe dock should have its own page in desktop"): the dock's
/// switch, its style (the top bar's Solid, Glass and Clear), size and magnification, then its widgets: the ones on in the
/// dock's order with Move up and Move down, the rest, and From extensions (each installed extension with a top bar item
/// no widget reads). A widget with settings opens them under its row: System stats' readings, an extension's own
/// preferences (Markets' symbols and how they show, shared with its top bar item).
struct DockPage: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine
    var focus: DockPageFocus = .shared
    var extensionBar: ExtensionBar = .shared
    /// The extensions folder it reads: the app's, or a render's.
    let folder: URL
    /// The extensions and their preferences, read as the page opens and saved as they change (the Extensions page's own
    /// model, which asks an extension's bar answer again after a save).
    @State private var prefs: ExtensionsSettings

    /// A render passes `prefs` loaded, as nothing loads before it draws.
    init(folder: URL = Extension.folder, focus: DockPageFocus = .shared, extensionBar: ExtensionBar = .shared, prefs: ExtensionsSettings? = nil) {
        self.folder = folder; self.focus = focus; self.extensionBar = extensionBar
        _prefs = State(initialValue: prefs ?? ExtensionsSettings(folder: folder))
    }

    /// The installed extensions with a top bar item no widget reads (DockWidgetSources.barExtensions), from what was read.
    private var offered: [Extension] { prefs.rows.map(\.ext).filter { $0.bar != nil && !DockWidget.extensionIDs.contains($0.id) } }

    var body: some View {
        let dock = engine.dock
        PageBody {
            SwitchCard(symbol: "dock.rectangle", name: "Dock", isOn: dock.isOn, busy: dock.busy,
                       detail: "Pilot's own dock at the foot of the main screen: your Dock's apps, the running ones and your widgets. On turns on the macOS Dock's auto-hide; off, or quitting Pilot, puts your setting back.") {
                dock.set(!dock.isOn)
            }
            if let problem = dock.problem { FinePrint(text: problem, color: ink.red) }
            TitledPanel(title: "Look") { look(dock) }
            TitledPanel(title: "Widgets") { DockWidgetList(dock: dock, offered: offered, prefs: prefs, focus: focus, extensionBar: extensionBar) }
        }
        .task { if !prefs.loaded { await prefs.load() } }
    }

    @ViewBuilder private func look(_ dock: DockController) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BlockRow(first: true) {
                Text("Style").foregroundStyle(ink.text)
                InfoMark(text: "What the dock stands on, as the top bar's Background: Solid, the theme's colour; Glass, Liquid Glass in it (Solid at 0 % Transparency); Clear, nothing, the icons and widgets straight on the wallpaper.")
                Spacer()
                Segments(selection: Binding(get: { dock.settings.style }, set: { dock.settings.style = $0 }),
                         options: TopBarBackground.allCases.map { ($0, $0.title) }, label: "Dock style")
            }
            BlockRow {
                Text("Size").foregroundStyle(ink.text)
                Spacer()
                Segments(selection: Binding(get: { dock.settings.size }, set: { dock.settings.size = $0 }),
                         options: DockSize.allCases.map { ($0, $0.rawValue.capitalized) }, label: "Dock size")
            }
            BlockRow {
                Text("Magnification").foregroundStyle(ink.text)
                InfoMark(text: "How much the icon under the pointer grows, as the macOS Dock's.")
                Spacer()
                Segments(selection: Binding(get: { dock.settings.magnify }, set: { dock.settings.magnify = $0 }),
                         options: DockMagnification.allCases.map { ($0, $0.title) }, label: "Dock magnification")
            }
        }
        .font(ink.ui(13))
    }
}

/// The dock's widgets: the ones on first, in the dock's order, then the built-in ones off, then From extensions; a switch
/// each, arrows to move one that is on, and a settings button where it has some, which opens them under its row.
struct DockWidgetList: View {
    @Environment(\.ink) private var ink
    let dock: DockController
    let offered: [Extension]
    let prefs: ExtensionsSettings
    let focus: DockPageFocus
    var extensionBar: ExtensionBar = .shared

    var body: some View {
        let on = dock.settings.widgets
        let builtIn = DockWidget.allCases.map(DockSlot.widget).filter { !on.contains($0) }
        let fromExtensions = offered.map { DockSlot.extensionItem($0.id) }.filter { !on.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((on + builtIn).enumerated()), id: \.element) { i, slot in row(slot, at: on.firstIndex(of: slot), count: on.count, first: i == 0) }
            Text("From extensions").font(ink.ui(13, .semibold)).foregroundStyle(ink.text).padding(.top, 14).padding(.bottom, 4)
            if fromExtensions.isEmpty {
                FinePrint(text: offered.isEmpty ? "No installed extension has a top bar item the widgets above do not read. Any that has one can go in the dock: the catalogue's Git, Tailscale or Ghostex, or your own."
                          : "Every installed extension with a top bar item is in the dock.")
            }
            ForEach(Array(fromExtensions.enumerated()), id: \.element) { i, slot in row(slot, at: nil, count: on.count, first: i == 0) }
        }
        .font(ink.ui(13))
    }

    @ViewBuilder private func row(_ slot: DockSlot, at: Int?, count: Int, first: Bool) -> some View {
        let open = focus.editing == slot, name = title(slot)
        VStack(alignment: .leading, spacing: 0) {
            BlockRow(first: first) {
                glyph(slot).frame(width: 18).foregroundStyle(ink.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).foregroundStyle(ink.text)
                    Text("Reads \(slot.reads)").font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
                }
                Spacer()
                if let at {
                    Button { dock.settings.move(slot, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).foregroundStyle(at == 0 ? ink.line2 : ink.text2).disabled(at == 0)
                        .accessibilityLabel("Move \(name) up")
                    Button { dock.settings.move(slot, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).foregroundStyle(at == count - 1 ? ink.line2 : ink.text2).disabled(at == count - 1)
                        .accessibilityLabel("Move \(name) down")
                }
                if DockPageFocus.hasSettings(slot) {
                    Button { focus.editing = open ? nil : slot } label: { Image(systemName: open ? "gearshape.fill" : "gearshape") }
                        .buttonStyle(.plain).foregroundStyle(open ? ink.accent : ink.text2)
                        .help("\(name) settings").accessibilityLabel("\(name) settings")
                }
                Toggle(name, isOn: Binding(get: { at != nil }, set: { show in
                    if show { try? dock.settings.add(slot) } else { try? dock.settings.remove(slot) }
                }))
                .labelsHidden().toggleStyle(.pilotSwitch)
            }
            if open { DockWidgetSettings(slot: slot, dock: dock, prefs: prefs).padding(.leading, 28).padding(.bottom, 12) }
        }
    }

    private func title(_ slot: DockSlot) -> String {
        if case .extensionItem(let id) = slot, let ext = offered.first(where: { $0.id == id }) { return ext.title }
        return DockWidgetView.title(slot, bar: extensionBar)
    }

    @ViewBuilder private func glyph(_ slot: DockSlot) -> some View {
        switch slot {
        case .widget(let widget): Image(systemName: widget.symbol)
        case .extensionItem(let id):
            if let icon = offered.first(where: { $0.id == id })?.icon, !icon.isEmpty { Text(icon) } else { Image(systemName: "puzzlepiece.extension") }
        }
    }
}

/// One widget's settings, under its row: System stats' readings (any the top bar's stats items read), or the preferences
/// of the extension it reads, drawn by the Extensions page's own form, so there is one copy of each (Markets' symbols, its
/// parts, together or in turn, shared with its top bar item).
struct DockWidgetSettings: View {
    @Environment(\.ink) private var ink
    let slot: DockSlot
    let dock: DockController
    let prefs: ExtensionsSettings

    var body: some View {
        if slot == .widget(.system) {
            stats
        } else if let id = slot.extensionID {
            if let row = prefs.rows.first(where: { $0.id == id }) {
                if row.fields.isEmpty {
                    FinePrint(text: "\(row.ext.title) has no settings.")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ExtensionSettingsForm(row: row, settings: prefs)
                        FinePrint(text: "\(row.ext.title)'s own settings: the top bar's \(row.ext.title) item shows them too.")
                    }
                }
            } else if prefs.loaded {
                FinePrint(text: "The \(id) extension is not installed.")
            }
        }
    }

    /// A switch per reading; the last one on stays.
    private var stats: some View {
        let picked = dock.settings.options.stats
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MenuBarStats.Stat.allCases.enumerated()), id: \.element) { i, stat in
                BlockRow(first: i == 0) {
                    Toggle(isOn: Binding(get: { picked.contains(stat) }, set: { on in
                        dock.settings.options.pick(on ? picked + [stat] : picked.filter { $0 != stat })
                    })) { Text(BarKind(stat).title).foregroundStyle(ink.text) }
                    .toggleStyle(.pilotSwitchRow)
                    .disabled(picked == [stat])
                }
            }
            FinePrint(text: "Any reading the top bar's stats items show; one this Mac lacks (a GPU's, a battery's) is left out of the dock.")
        }
    }
}
