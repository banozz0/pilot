import AppKit
import SwiftUI
import PilotCore

/// Workspaces in the editor's look (card agent-bo-95423003, Sven 2026-10-07: "i explicitly said how it should look so i
/// can customise each workspace ... why is half the screen empty"): the workspaces along the top (two rows past five),
/// Add and Delete over them (Sven 2026-10-17: Delete takes the picked one), each a small screen of its apps in their spots
/// under its name, and under them the picked one in the editor itself: the preview whose spots take an app, the layout
/// pictures, Opens here and its two rules, the apps that always land there and its window snapshot. Every change saves
/// at once (Sven 2026-10-17, no Save button). Under the editor, while the picked workspace is Scrolling, that layout's
/// centre mode and column rules, then each workspace's monitor and the swipe between them (Sven's Q207 page map, from Tiling). Gaps, the always-float lists
/// and the Pilot block sit under Tiling. Every rule change saves the Pilot block's settings and reloads the tiler.
struct WorkspacesSettingsView: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        WorkspacesBody(block: engine.pilotBlock, layouts: engine.layouts, presets: engine.presets, snapshots: engine.snapshots,
                       list: engine.workspaceList, focused: engine.observers.tiler.focused, settings: engine.settings,
                       monitors: engine.workspaceMonitors)
    }
}

/// The page itself on its stores, so a test draws it without an engine.
struct WorkspacesBody: View {
    @Environment(\.ink) private var ink
    let block: PilotBlockStore
    let layouts: WorkspaceLayouts
    let presets: WorkspacePresets
    let snapshots: WorkspaceSnapshots
    /// Which workspaces are kept, with Add and Delete; nil draws all nine without them.
    var list: WorkspaceList? = nil
    /// The workspace on screen: it is picked first and marked on its card.
    var focused: String?
    /// Where a render starts: the editor's hover, picker and apps.
    var start = WorkspaceEditor.Start()
    /// The swipe between workspaces; nil leaves its block out.
    var settings: PilotSettings? = nil
    /// Each workspace's Monitor pick (N7); nil leaves its block out.
    var monitors: WorkspaceMonitorStore? = nil
    /// The displays the Monitor pick offers; renders pass their own, the app reads them live.
    var displays: [ConnectedDisplay]? = nil
    @State private var picked: String?
    @State private var drafts = WorkspacePageDrafts()

    static let intro = "Each workspace's name, layout and apps. Pick one, then click its screen to put apps in it; every change saves at once."

    var body: some View {
        let names = list?.names ?? Workspaces.all
        let name = [picked, focused].compactMap { $0 }.first(where: names.contains) ?? names[0]
        // One row up to five, two past it, so nine never squeeze into slivers; a short last row keeps the cards' width.
        let perRow = names.count > 5 ? (names.count + 1) / 2 : names.count
        let rows = stride(from: 0, to: names.count, by: perRow).map { Array(names[$0..<min($0 + perRow, names.count)]) }
        FillScroll {
            VStack(alignment: .leading, spacing: 14) {
                Text(Self.intro).font(ink.ui(13.5)).foregroundStyle(ink.text2)
                if let list {
                    ListRow(list: list, picked: name, title: presets.contents.title(for: name)) { added in
                        withAnimation(Kit.change) { picked = added }
                    } deleted: {
                        drafts.revert(name)
                        withAnimation(Kit.change) { picked = nil }
                    }
                }
                VStack(spacing: 12) {
                    ForEach(rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row, id: \.self) { workspace in
                                WorkspaceCard(name: workspace, title: presets.contents.title(for: workspace), draft: draft(workspace),
                                              picked: workspace == name, onScreen: workspace == focused,
                                              snapshot: snapshots.saved[workspace] != nil) {
                                    withAnimation(Kit.change) { picked = workspace }
                                }
                            }
                            ForEach(row.count..<perRow, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                        }
                    }
                }
                // Its rows keep their height; the editor under them takes what is left.
                .fixedSize(horizontal: false, vertical: true)
                WorkspaceEditorPanel(workspace: name, presets: presets, draft: binding(name), mode: .page(extras: extras(name)),
                                     start: start) {
                    presets.remove(from: name)
                    if presets.lastError == nil { drafts.revert(name) }
                }
                .id(name)
                .frame(maxHeight: .infinity)
                // Only while the picked workspace's layout is Scrolling (Sven 2026-10-30), as the editor shows it.
                if draft(name).layout == .scrolling {
                    WorkspaceScrollingBlock(block: block, given: start.apps?.map { (name: $0.name, bundle: $0.bundle) })
                }
                if let monitors {
                    WorkspaceMonitorsBlock(monitors: monitors, displays: displays, names: presets.contents)
                }
                if let settings { WorkspaceSwipeBlock(settings: settings) }
                if let error = block.lastError ?? list?.lastError ?? snapshots.lastError ?? monitors?.lastError {
                    FinePrint(text: error, color: ink.red)
                }
            }
            .padding(.horizontal, ink.pageInset).padding(.top, ink.pageTop(6)).padding(.bottom, 28)
        }
        .savesWhenResting(drafts) { drafts.edited.forEach(save) }
    }

    private func draft(_ workspace: String) -> WorkspacePresetDraft {
        drafts.draft(workspace, saved: presets.contents.preset(for: workspace), row: layouts.layout(workspace))
    }

    /// The editor's draft; a new name (written to the draft only once its field is left or Return is pressed) saves at once.
    private func binding(_ workspace: String) -> Binding<WorkspacePresetDraft> {
        let saved = presets.contents.preset(for: workspace), row = layouts.layout(workspace)
        return Binding(get: { drafts.draft(workspace, saved: saved, row: row) }, set: { new in
            let renamed = new.name != drafts.draft(workspace, saved: saved, row: row).name
            drafts.set(new, for: workspace, saved: saved, row: row)
            if renamed { save(workspace) }
        })
    }

    /// Writes a workspace's edit (WorkspacePresets.write); the edit goes once it is written.
    private func save(_ workspace: String) {
        guard drafts.isEdited(workspace) else { return }
        if presets.write(draft(workspace), to: workspace, layouts: layouts) { drafts.revert(workspace) }
    }

    private func extras(_ workspace: String) -> WorkspacePageExtras {
        @Bindable var snapshots = snapshots
        let rules = block.block.rules
        return WorkspacePageExtras(
            workspaces: list?.names ?? Workspaces.all,
            title: presets.contents.title(for:),
            rules: rules.filter { $0.workspace == workspace }.map(\.appId),
            ruled: Set(rules.map(\.appId)),
            addRule: { bundle in block.edit { $0.rules.append(.init(appId: bundle, workspace: workspace)) } },
            removeRule: { bundle in block.edit { $0.rules.removeAll { $0.appId == bundle } } },
            moveRule: { bundle, other in
                block.edit { block in if let i = block.rules.firstIndex(where: { $0.appId == bundle }) { block.rules[i].workspace = other } }
            },
            snapshot: snapshots.saved[workspace],
            restore: { snapshots.restore(workspace) },
            deleteSnapshot: { snapshots.delete(workspace) },
            reopenApps: $snapshots.reopenApps)
    }

    /// "Zen (2 windows), Obsidian": each app once, first seen first.
    static func apps(_ snapshot: Snapshot) -> String {
        AppCounts.firstSeen(snapshot.windows.map(\.appName)).map { $0.count > 1 ? "\($0.name) (\($0.count) windows)" : $0.name }
            .joined(separator: ", ")
    }
}

/// How many workspaces there are, Add making the next number and Delete taking the picked one, not the last (Sven
/// 2026-10-17), the ones after it moving down a number (Q233); never fewer than one or more than nine.
private struct ListRow: View {
    @Environment(\.ink) private var ink
    let list: WorkspaceList
    /// The workspace picked below, which Delete takes, and what the page calls it.
    let picked: String
    let title: String
    let added: (String) -> Void
    let deleted: () -> Void

    static let info = "Add makes the next number, on the main display. Delete removes the workspace picked below: its windows move to the one before it, and each workspace after it moves down a number, taking its name, apps, snapshot and monitor along. Hyper+3 is always the third workspace."

    var body: some View {
        let n = list.count
        HStack(spacing: 8) {
            Text(n == 1 ? "1 workspace" : "\(n) workspaces").font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
            InfoMark(text: Self.info)
            Spacer(minLength: 8)
            Button {
                withAnimation(Kit.change) { if let new = list.add() { added(new) } }
            } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.pilot).disabled(!list.canAdd)
                .help(list.canAdd ? "Add a workspace, on the main display" : "Nine is the most, one per number key")
            Button {
                withAnimation(Kit.change) { list.remove(picked) }
                deleted()
            } label: { Label("Delete \(title)", systemImage: "trash").lineLimit(1) }
                .buttonStyle(PilotButtonStyle(destructive: true, ghost: true)).disabled(!list.canRemove)
                .help(list.canRemove ? "Delete \(title); its windows move to the workspace before it and the ones after it move down a number" : "At least one workspace stays")
        }
    }
}

/// One row per workspace with its Monitor pick: Any, Main or a display by the name macOS gives it (N7; on Tiling until
/// Sven's Q207 page map).
struct WorkspaceMonitorsBlock: View {
    let monitors: WorkspaceMonitorStore
    /// The displays the pick offers; renders pass their own, the app reads them live and again when one comes or goes.
    var displays: [ConnectedDisplay]? = nil
    var nicknames: DisplayNicknames = .shared
    /// The workspaces' names, so a named one's row says its name (else "Workspace 3").
    var names = WorkspacePresetStore.Contents()
    @State private var liveDisplays: [ConnectedDisplay] = []

    static let info = "A pinned workspace always opens on its monitor. While that monitor is unplugged it opens on the main one, and goes back once the monitor returns."

    var body: some View {
        let shown = displays ?? liveDisplays
        KitBlock(title: "Monitors", symbol: "display.2") {
            InfoMark(text: Self.info)
        } content: {
            ForEach(Array(monitors.workspaces.enumerated()), id: \.element) { i, workspace in
                let pick = Self.monitorChoices(pinned: monitors.pins[workspace], displays: shown, nicknames: nicknames)
                BlockRow(first: i == 0) {
                    Text(names.title(for: workspace)).lineLimit(1)
                    Spacer()
                    DropdownField(label: "\(names.title(for: workspace))'s monitor", options: pick.choices, picked: pick.picked) {
                        monitors.set($0, for: workspace)
                    }
                    .frame(width: 220)
                }
            }
        }
        .onAppear { liveDisplays = Self.connectedDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            liveDisplays = Self.connectedDisplays()
        }
    }

    /// Same OS UUIDs as monitor pins, read fresh so a reused session handle cannot borrow an old label.
    private static func connectedDisplays() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in
            WallpaperScreen.number(screen).flatMap(DisplayIdentity.uuid(for:)).map { ConnectedDisplay(name: screen.localizedName, id: $0) }
        }
    }

    /// Change only the titles; a selection still carries the original monitor pin and system name.
    static func monitorChoices(pinned: MonitorPin?, displays: [ConnectedDisplay], nicknames: DisplayNicknames)
        -> (choices: [(value: MonitorPin?, title: String)], picked: MonitorPin?) {
        let pick = WorkspaceMonitors.choices(pinned: pinned, displays: displays)
        return (pick.choices.map { choice in
            guard let value = choice.value, case .display(let name, let id) = value else { return choice }
            let unique = id.map { uuid in displays.filter { $0.id == uuid }.count <= 1 } ?? false
            let label = nicknames.label(systemName: name, displayUUID: unique ? id : nil)
            let unplugged = !displays.contains { $0.matches(value) }
            return (choice.value, label + (unplugged ? " (unplugged)" : ""))
        }, pick.picked)
    }
}

extension View {
    /// The editor's autosave (Sven 2026-10-17, no Save button): `write` runs once `value` has rested 300 ms, so a dragged
    /// size writes once it stops rather than once per point, and again as the view goes, for what is still waiting.
    func savesWhenResting<Value: Equatable>(_ value: Value, write: @escaping () -> Void) -> some View {
        task(id: value) {
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            write()
        }
        .onDisappear(perform: write)
    }
}

/// The scrolling layout's centre mode and column rules (spec scrolling-layout T9, T11; Sven via coordinator 21,
/// 2026-10-20): under the editor while the picked workspace's layout is Scrolling (Sven 2026-10-30), while Tiling's
/// Scrolling block stays hidden (Q43).
/// A rule added here changes nothing until its width or focus does.
struct WorkspaceScrollingBlock: View {
    @Environment(\.ink) private var ink
    let block: PilotBlockStore
    /// The apps Add offers, as a render passes them; nil reads the Mac's once the block shows.
    var given: [(name: String, bundle: String)]? = nil
    @State private var apps: [(name: String, bundle: String)] = []

    static let info = "For workspaces in the Scrolling layout: where the strip puts the column you focus, and apps whose column keeps its own width or whose new windows leave focus where it was."
    static let centres = PilotBlock.CentreMode.allCases.map { (value: $0, title: $0.title) }
    static let widths: [(value: PilotBlock.ColumnWidth?, title: String)] = [(nil, "Automatic")] + PilotBlock.ColumnWidth.allCases.map { ($0, $0.title) }

    var body: some View {
        let rules = block.block.scrolling.apps, ruled = Set(rules.map(\.appId)), shown = given ?? apps
        KitBlock(title: "Scrolling", symbol: "rectangle.split.3x1.fill") {
            InfoMark(text: Self.info)
        } content: {
            BlockRow(first: true) {
                Text("Centre the focused column").lineLimit(1)
                Spacer()
                Segments(selection: block.binding(\.scrolling.centre), options: Self.centres, label: "Centre the focused column")
            }
            ForEach(rules, id: \.appId) { rule in
                let name = shown.first { $0.bundle == rule.appId }?.name ?? AppsModule.displayName(rule.appId)
                BlockRow {
                    AppLabel(name: name, bundle: rule.appId, size: 18).lineLimit(1)
                    Spacer()
                    DropdownField(label: "\(name)'s column width", options: Self.widths, picked: rule.width) { width in
                        edit(rule.appId) { $0.width = width }
                    }
                    .frame(width: 130)
                    Text("Takes focus").font(ink.ui(12)).foregroundStyle(ink.muted)
                    Toggle("\(name) takes focus", isOn: Binding(get: { rule.focus }, set: { on in edit(rule.appId) { $0.focus = on } }))
                        .labelsHidden().toggleStyle(.pilotSwitch)
                    Button { block.edit { $0.scrolling.apps.removeAll { $0.appId == rule.appId } } } label: {
                        Image(systemName: "xmark").foregroundStyle(ink.muted)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(name)'s rule")
                }
            }
            BlockRow {
                AppPickerField(bundle: nil, name: "Add an app", label: "Add a column rule", compact: true, symbol: "plus") {
                    ForEach(shown.filter { !ruled.contains($0.bundle) }, id: \.bundle) { app in
                        Button { block.edit { $0.scrolling.apps.append(.init(appId: app.bundle)) } } label: { AppMenuItem(name: app.name, bundle: app.bundle) }
                    }
                }
                .frame(width: 220)
                Spacer()
            }
        }
        .task { if given == nil, apps.isEmpty { apps = AppsModule.pickableApps() } }
    }

    private func edit(_ app: String, _ change: @escaping @MainActor (inout PilotBlock.ColumnRule) -> Void) {
        block.edit { block in
            if let i = block.scrolling.apps.firstIndex(where: { $0.appId == app }) { change(&block.scrolling.apps[i]) }
        }
    }
}

/// The three-finger swipe between workspaces (card agent-bo-95422973; on Tiling until Sven's Q207 page map).
struct WorkspaceSwipeBlock: View {
    let settings: PilotSettings

    var body: some View {
        @Bindable var settings = settings
        KitBlock(title: "Swipe", symbol: "hand.draw") {
            BlockRow(first: true) {
                Toggle(isOn: $settings.swipeWorkspaces) { Text(MouseDragSection.swipeLabel).fixedSize(horizontal: false, vertical: true) }
                    .toggleStyle(.pilotSwitchRow(info: MouseDragSection.swipeTip))
            }
        }
    }
}

/// One workspace along the top: a small screen of its apps where its layout puts them, its name (else "Workspace 3") and
/// what it holds; the picked one lit, the one on screen marked. Narrow, the screen sits over the words.
private struct WorkspaceCard: View {
    @Environment(\.ink) private var ink
    let name: String
    /// Its name, else "Workspace 3" (Sven 2026-10-17: a named workspace shows its name alone).
    let title: String
    let draft: WorkspacePresetDraft
    let picked: Bool
    let onScreen: Bool
    let snapshot: Bool
    let pick: () -> Void
    @State private var hovered = false
    @State private var wide = true

    private var toybox: Bool { ink.style.kind == .toybox }

    var body: some View {
        let radius = ink.blockRadius
        Button(action: pick) {
            Group {
                if wide {
                    HStack(spacing: 12) { screen.frame(width: 118, height: 74); words }
                } else {
                    VStack(alignment: .leading, spacing: 8) { screen.frame(height: 58); words }
                }
            }
            .padding(12)
            // Instrument's four cards stand level when one's line wraps.
            .frame(maxWidth: .infinity, maxHeight: ink.isInstrument ? .infinity : nil, alignment: ink.isInstrument ? .topLeading : .leading)
            .background(picked && toybox ? ink.accent : picked && !ink.isInstrument ? ink.selected : hovered ? ink.text.opacity(0.04) : .clear,
                        in: .rect(cornerRadius: radius - ink.style.depth.card.outline))
            .blockSurface()
            // Toybox fills its pick with the sun; the others wear their focus (Instrument's the signal's ring).
            .focusBorder(on: picked && !toybox, radius: radius)
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .onHover { hovered = $0 }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 250 } action: { wide = $0 }
        .animation(Kit.change, value: hovered)
        .accessibilityLabel("\(title), key \(name), \(summary)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var summary: String {
        let apps = draft.apps.count
        let how = draft.layout?.label ?? WorkspaceEditor.ownSizes
        return apps == 0 ? "\(how), no apps yet" : "\(how), \(apps) app\(apps == 1 ? "" : "s")"
    }

    /// The card's own line: Instrument's short enough to sit whole beside the screen at 1440 ("Main + stack · empty").
    private var shown: String {
        guard ink.isInstrument else { return summary }
        let apps = draft.apps.count, how = draft.layout?.label ?? WorkspaceEditor.ownSizes
        // The dot keeps to the layout's name, so a wrapped line never starts with it.
        return "\(how)\u{00A0}· \(apps == 0 ? "empty" : "\(apps)\u{00A0}app\(apps == 1 ? "" : "s")")"
    }

    private var words: some View {
        // On Toybox's sun-filled pick the words are the ink on the sun.
        let sun = picked && toybox
        let text = sun ? ink.onAccent : ink.text, text2 = sun ? ink.onAccent.opacity(0.8) : ink.text2, muted = sun ? ink.onAccent.opacity(0.66) : ink.muted
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(ink.ui(13, .semibold)).foregroundStyle(text).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if onScreen { Circle().fill(ink.green).frame(width: 6, height: 6).help("On screen now").accessibilityLabel("on screen") }
            }
            HStack(spacing: 6) {
                // Instrument's wraps to a second line before it would cut (a narrow window's cards).
                Text(shown).font(ink.ui(11.5)).foregroundStyle(text2).lineLimit(ink.isInstrument ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: ink.isInstrument)
                if snapshot { Image(systemName: "camera.viewfinder").font(ink.ui(10)).foregroundStyle(muted).help("Window snapshot saved") }
            }
        }
    }

    /// The workspace in miniature, in its layout (Sven 2026-10-30): its apps' tiles with their icons, then the layout's
    /// empty spots dashed, as the editor's preview draws them. Scrolling's strip is drawn as the preview draws it: three
    /// columns whole, the rest peeking in at the right edge.
    private var screen: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(6), style: .continuous)
        return GeometryReader { g in
            let area = CGRect(origin: .zero, size: g.size).insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: 4)
            let inner = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - 4)
            let layout = draft.shape(in: inner) ?? (draft.tiles(in: inner), [])
            let tile = RoundedRectangle(cornerRadius: ink.radius(3), style: .continuous)
            ForEach(Array(zip(draft.apps, layout.apps).enumerated()), id: \.offset) { i, pair in
                let r = pair.1.insetBy(dx: 1.5, dy: 1.5)
                tile.fill(picked ? ink.accent.opacity(0.22) : ink.tile)
                    .overlay { tile.strokeBorder(ink.outline, lineWidth: 1.5) }
                    .overlay {
                        if min(r.width, r.height) >= 18 {
                            AppGlyph(bundles: [pair.0.bundleId], symbol: "app.dashed", size: min(18, min(r.width, r.height) - 6))
                        }
                    }
                    .frame(width: max(0, r.width), height: max(0, r.height))
                    .offset(x: r.minX, y: r.minY)
            }
            ForEach(layout.open.indices, id: \.self) { k in
                let r = layout.open[k].insetBy(dx: 1.5, dy: 1.5)
                tile.strokeBorder(picked ? ink.accent.opacity(0.6) : ink.line3, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: max(0, r.width), height: max(0, r.height))
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .background(ink.well, in: shape)
        .overlay(alignment: .top) { ink.text.opacity(0.05).frame(height: 4).clipShape(shape) }
        .overlay { shape.strokeBorder(ink.outline, lineWidth: ink.stroke) }
        .accessibilityHidden(true)
    }
}
