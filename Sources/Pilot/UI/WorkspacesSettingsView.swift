import AppKit
import SwiftUI
import PilotCore

/// Workspaces in the editor's look (card agent-bo-95423003, Sven 2026-10-07: "i explicitly said how it should look so i
/// can customise each workspace ... why is half the screen empty"; simplify-pages T18): Add and Delete (Sven 2026-10-17:
/// Delete takes the picked one), the workspaces in one compact row of nine (Sven's Q37), each a small screen of its apps
/// in their spots over its number, and under them the picked one in the editor itself: its name, the preview whose spots
/// take an app, the layout pictures with the apps that always land there, a preset and its window snapshot under them
/// (back from More, Sven's round 3 notes on build 2300), and what opens there with its two rules (back from More, Sven
/// 2026-11-11, after 2276). More edits the same pick: while it is Scrolling, that layout's centre mode and column rules,
/// the window shelf's pictures (from Tiling, Sven 2026-11-11,
/// after 2276), each workspace's monitor and the swipe between them (Sven's Q207 page map, from Tiling). Every change saves at once
/// (Sven 2026-10-17, no Save button). Gaps, the always-float lists and the Pilot block sit under Tiling. Every rule change
/// saves the Pilot block's settings and reloads the tiler.
struct WorkspacesSettingsView: View {
    @Environment(Engine.self) private var engine
    /// The More tab (simplify-pages T18), editing the workspace picked on the front.
    var more = false

    var body: some View {
        WorkspacesBody(block: engine.pilotBlock, layouts: engine.layouts, presets: engine.presets, snapshots: engine.snapshots,
                       list: engine.workspaceList, focused: engine.observers.tiler.focused, settings: engine.settings,
                       monitors: engine.workspaceMonitors, more: more)
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
    /// The More tab (simplify-pages T18): the picked workspace's Scrolling rules, the window shelf, the monitors and the
    /// swipe. One view with the front, so the pick carries over.
    var more = false
    /// The workspace picked; a render starts it on another to show More editing it.
    @State var picked: String? = nil
    @State private var drafts = WorkspacePageDrafts()

    static let intro = "Each workspace's name, layout and apps."
    static let introInfo = "Pick one, then click its screen to put apps in it; every change saves at once."

    var body: some View {
        let names = list?.names ?? Workspaces.all
        let name = [picked, focused].compactMap { $0 }.first(where: names.contains) ?? names[0]
        Group {
            if more { moreTab(name) } else { front(name, names: names) }
        }
        .savesWhenResting(drafts) { drafts.edited.forEach(save) }
    }

    /// The front: Add and Delete, the workspaces in one compact row (Sven's Q37), and the picked one's name, layout, apps
    /// in their spots, rules, preset, snapshot and what opens there.
    private func front(_ name: String, names: [String]) -> some View {
        KitLanding { FillScroll {
            VStack(alignment: .leading, spacing: 14) {
                IntroLine(info: Self.introInfo) { Text(Self.intro).font(ink.ui(13.5)).foregroundStyle(ink.text2) }
                if let list {
                    ListRow(list: list, picked: name, title: presets.contents.title(for: name)) { added in
                        withAnimation(Kit.change) { picked = added }
                    } deleted: {
                        drafts.revert(name)
                        withAnimation(Kit.change) { picked = nil }
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    ForEach(names, id: \.self) { workspace in
                        WorkspaceCard(name: workspace, title: presets.contents.title(for: workspace), draft: draft(workspace),
                                      picked: workspace == name, onScreen: workspace == focused,
                                      snapshot: snapshots.saved[workspace] != nil) {
                            withAnimation(Kit.change) { picked = workspace }
                        }
                    }
                }
                // Its row keeps its height; the editor under it takes what is left.
                .fixedSize(horizontal: false, vertical: true)
                editor(name).frame(maxHeight: .infinity)
                problems
            }
            .padding(.horizontal, ink.pageInset).padding(.top, ink.pageTop(6)).padding(.bottom, 28)
        } }
    }

    /// More's index. A row added to or moved off a block changes its count here; Scrolling's holds its 3 rules only while
    /// the picked layout is Scrolling, and a render without the monitor or swipe stores leaves those out.
    static let entries = [
        MoreEntry(id: .workspaceScrolling, symbol: "rectangle.split.3x1.fill", controls: 3),
        MoreEntry(id: .windowShelf, symbol: "rectangle.stack", controls: 4),
        MoreEntry(id: .workspaceMonitors, symbol: "display.2", controls: 1),
        MoreEntry(id: .workspaceSwipe, symbol: "hand.draw", controls: 1),
    ]

    /// More (simplify-pages T18): the Scrolling place (the picked workspace's rules while its layout is Scrolling, else a
    /// line saying so), the window shelf, each workspace's monitor and the swipe.
    private func moreTab(_ name: String) -> some View {
        // Scrolling's rules only while the picked workspace's layout is Scrolling (Sven 2026-10-30), as the editor shows it.
        let scrolling = draft(name).layout == .scrolling
        let drawn = Self.entries
            .filter { ($0.id != .workspaceMonitors || monitors != nil) && ($0.id != .workspaceSwipe || settings != nil) }
            .map { $0.id == .workspaceScrolling && !scrolling ? MoreEntry(id: $0.id, symbol: $0.symbol, controls: 0) : $0 }
        return KitMore(entries: drawn) {
            // Scrolling's rules only while its layout is Scrolling; else one line says so, so its words and links land.
            Group {
                if scrolling {
                    WorkspaceScrollingBlock(block: block, given: start.apps?.map { (name: $0.name, bundle: $0.bundle) })
                } else {
                    KitBlock(title: AppSection.workspaceScrolling.title, symbol: "rectangle.split.3x1.fill") {
                        BlockRow(first: true) {
                            FinePrint(text: "The Scrolling layout's rules show here once \(presets.contents.title(for: name))'s layout is Scrolling, picked on the Workspaces tab.")
                        }
                    }
                }
            }
            .moreBlock(.workspaceScrolling)
            ShelfSettingsBlock().moreBlock(.windowShelf)
            if let monitors {
                WorkspaceMonitorsBlock(monitors: monitors, displays: displays, names: presets.contents).moreBlock(.workspaceMonitors)
            }
            if let settings { WorkspaceSwipeBlock(settings: settings).moreBlock(.workspaceSwipe) }
            problems
        }
    }

    /// The picked workspace's editor.
    private func editor(_ name: String) -> some View {
        WorkspaceEditorPanel(workspace: name, presets: presets, draft: binding(name), mode: .page(extras: extras(name)),
                             start: start) {
            presets.remove(from: name)
            if presets.lastError == nil { drafts.revert(name) }
        }
        .id(name)
    }

    @ViewBuilder private var problems: some View {
        if let error = block.lastError ?? list?.lastError ?? snapshots.lastError ?? monitors?.lastError {
            FinePrint(text: error, color: ink.red)
        }
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

/// One of the workspaces' compact row of nine (Sven's Q37, simplify-pages T18): a small screen of its apps where its
/// layout puts them over its number, its name in its tip; the picked one lit, the one on screen marked.
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

    private var toybox: Bool { ink.style.kind == .toybox }
    /// A display's width over its height, and the widest a card grows when few workspaces share the row.
    static let screenShape: CGFloat = 16 / 10
    static let widest: CGFloat = 150

    /// Its name, then what the dot and the mark say: on screen now, a window snapshot saved.
    private var tip: String {
        ([title] + (onScreen ? ["on screen now"] : []) + (snapshot ? ["window snapshot saved"] : [])).joined(separator: ", ")
    }

    var body: some View {
        let radius = ink.blockRadius
        Button(action: pick) {
            VStack(spacing: 4) {
                // A screen's shape, so each layout's drawing reads (Sven, 2026-11-11, after 2276: 34 pt tall squashed it).
                screen.aspectRatio(WorkspaceCard.screenShape, contentMode: .fit)
                HStack(spacing: 4) {
                    Text(name).font(ink.ui(12, .semibold)).foregroundStyle(picked && toybox ? ink.onAccent : ink.text)
                    if onScreen { Circle().fill(ink.green).frame(width: 5, height: 5).accessibilityHidden(true) }
                    if snapshot { Image(systemName: "camera.viewfinder").font(ink.ui(9)).foregroundStyle(ink.muted).accessibilityHidden(true) }
                }
            }
            .padding(6)
            .frame(maxWidth: Self.widest)
            .background(picked && toybox ? ink.accent : picked && !ink.isInstrument ? ink.selected : hovered ? ink.text.opacity(0.04) : .clear,
                        in: .rect(cornerRadius: radius - ink.style.depth.card.outline))
            .blockSurface()
            // Toybox fills its pick with the sun; the others wear their focus (Instrument's the signal's ring).
            .focusBorder(on: picked && !toybox, radius: radius)
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help(tip)
        .onHover { hovered = $0 }
        .animation(Kit.change, value: hovered)
        .accessibilityLabel("\(tip), key \(name), \(summary)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var summary: String {
        let apps = draft.apps.count
        let how = draft.layout?.label ?? WorkspaceEditor.ownSizes
        return apps == 0 ? "\(how), no apps yet" : "\(how), \(apps) app\(apps == 1 ? "" : "s")"
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
