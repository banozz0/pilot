import AppKit
import SwiftUI
import PilotCore

/// Tiling (design round 4 section 7, card agent-bo-95422897): the gaps with a live preview, the always-float lists, the
/// Alt+drag modifier (card agent-bo-95422930) and the focused window's border and Defocus (page map, Sven
/// 2026-10-17). Each workspace's monitor and the swipe between workspaces moved to the Workspaces page (Sven's Q207 page
/// map). Every block change goes to Pilot's tiler at once.
struct TilingSettingsView: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        TilingBody(block: engine.pilotBlock, settings: engine.settings)
    }
}

/// The Tiling tab on its stores, so a test draws it without an engine.
struct TilingBody: View {
    @Environment(\.ink) private var ink
    let block: PilotBlockStore
    let settings: PilotSettings
    /// The apps Always float lists; renders pass their own, the app reads them when the block appears.
    var apps: [(name: String, bundle: String)]? = nil
    @State private var installed: [(name: String, bundle: String)] = []
    @State private var appQuery = ""
    @State private var floatedFirst: Set<String> = []
    @State private var newTitle = ""
    /// The Look the Focused window block binds to; a render passes its own.
    var look: Look = .shared

    var body: some View {
        KitPage(intro: "How Pilot's tiler lays windows out: gaps, floats, the mouse and the focused window.") {
            if ink.isInstrument {
                // Instrument's two columns, rows ending level (no full-width block with one control at its far edge).
                InstrumentPair { gaps } right: { floatApps }
                InstrumentPair { mouse } right: { floatTitles }
            } else {
                gaps; floatApps; floatTitles; mouse
            }
            // Full width under the rest in both styles (page map, Sven 2026-10-17: off Look's Transparency block).
            FocusedWindowBlock(look: look)
            if let error = block.lastError { FinePrint(text: error, color: ink.red).padding(.top, 12) }
        }
    }

    private var gaps: some View {
        KitBlock(title: "Gaps", symbol: "rectangle.split.3x1", focused: true, fill: true) {
            Kbd(text: "Hyper+Shift+Backspace")
        } content: {
            GapsEditor(block: block)
        }
    }

    /// Hidden since spec scrolling-layout T8 (Sven's Q43, 2026-10-12: widths fit the window count, one glide), kept to come
    /// back; the block's scrolling keys still decode.
    private var scrolling: some View {
        KitBlock(title: "Scrolling", symbol: "rectangle.split.3x1.fill") {
            InfoMark(text: "A workspace in the Scrolling layout lays its windows out as columns on a strip, and Hyper+← → scrolls it.")
        } content: {
            ScrollingEditor(block: block)
        }
    }

    private var mouse: some View {
        @Bindable var settings = settings
        return KitBlock(title: "Mouse and motion", symbol: "cursorarrow.motionlines", fill: true) {
            let choices = HStack(spacing: 6) {
                Segments(selection: $settings.dragModifier, options: MouseDragSection.options, label: MouseDragSection.label)
                // The picked choice's own line, for the two that need one.
                if let tip = MouseDragSection.tips[settings.dragModifier] { InfoMark(text: tip) }
            }
            let label = HStack(spacing: 6) { Text(MouseDragSection.label); InfoMark(text: MouseDragSection.dragTip) }
            BlockRow(first: true) { label; Spacer(); choices }
            BlockRow {
                Toggle("Glide windows", isOn: block.binding(\.glide))
                    .toggleStyle(.pilotSwitchRow(info: "Tiled windows slide to their new place in under a fifth of a second. Reduce Motion and Low Power Mode always jump."))
            }
        }
    }

    /// Every app with its Float switch (C8): the installed and running apps, an app floated by id this Mac lacks, and a name
    /// from before C8 no app answers to. Floated first, as they were when the list loaded or the search changed, so a
    /// switch never moves its row from under the pointer.
    private var floatApps: some View {
        KitBlock(title: "Always float: apps", symbol: "macwindow.on.rectangle", fill: true) {
            Text("\(block.block.floatAppIds.count + block.block.floatApps.count)").font(ink.mono(11)).foregroundStyle(ink.muted)
        } content: {
            BlockRow(first: true) {
                Image(systemName: "magnifyingglass").font(ink.ui(11)).foregroundStyle(ink.muted).accessibilityHidden(true)
                TextField("Search apps", text: $appQuery, prompt: Text("Search apps").foregroundStyle(ink.muted)).textFieldStyle(.plain)
                InfoMark(text: "A floating app's windows keep their own size and place, out of the tiles. Matched by the app itself, whatever its name.")
            }
            let rows = FloatApps.rows(apps: apps ?? installed, block: block.block, query: appQuery, first: floatedFirst)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        BlockRow {
                            AppLabel(name: row.name, bundle: row.bundle, size: 18).lineLimit(1)
                            if row.bundle == nil { Text("by name").font(ink.ui(11)).foregroundStyle(ink.muted) }
                            Spacer()
                            Toggle("Float \(row.name)", isOn: Binding(get: { row.floats }, set: { on in block.edit { FloatApps.set(row, on: on, in: &$0) } }))
                                .labelsHidden().toggleStyle(.pilotSwitch)
                        }
                    }
                    if rows.isEmpty { BlockRow { Text("No app called \(appQuery)").foregroundStyle(ink.muted) } }
                }
            }
            .frame(height: 300)
        }
        .onAppear {
            if apps == nil { installed = AppsModule.pickableApps() }
            floatedFirst = FloatApps.floated(block.block)
        }
        .onChange(of: appQuery) { floatedFirst = FloatApps.floated(block.block) }
    }

    private var floatTitles: some View {
        KitBlock(title: "Always float: window titles", symbol: "textformat", fill: true) {
            titles
        }
    }

    /// The window titles that float whatever the app: each with a remove button, and a field that adds one. Titles are not
    /// a list Pilot can offer, so they stay typed.
    @ViewBuilder
    private var titles: some View {
        ForEach(Array(block.block.floatTitles.enumerated()), id: \.element) { i, title in
            BlockRow(first: i == 0) {
                Text(title).font(ink.mono(12.5))
                Spacer()
                Button { block.edit { $0.floatTitles.removeAll { $0 == title } } } label: { Image(systemName: "xmark").foregroundStyle(ink.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(title)")
            }
        }
        BlockRow(first: block.block.floatTitles.isEmpty) {
            TextField(Self.titlePrompt, text: $newTitle, prompt: Text(Self.titlePrompt).foregroundStyle(ink.muted)).pilotField().onSubmit(addTitle)
            InfoMark(text: "Any window whose title contains this text floats, case ignored: Google Accounts floats Google's sign-in window in any browser.")
            Button("Add", action: addTitle).buttonStyle(.pilot)
        }
    }

    static let titlePrompt = "Part of a window title, e.g. Google Accounts"

    private func addTitle() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        block.edit { $0.floatTitles.append(title) }
        newTitle = ""
    }
}

/// Tiling's Always float apps (C8): one row per app with its Float switch, and what a switch writes.
@MainActor enum FloatApps {
    struct Row: Identifiable, Equatable {
        let name: String
        /// Nil for a name from before C8 that no app on this Mac answers to, matched by name.
        let bundle: String?
        let floats: Bool
        var id: String { bundle ?? Self.id(name: name) }
        static func id(name: String) -> String { "name:" + name }
    }

    /// Every float in the block, by the row id it has.
    static func floated(_ block: PilotBlock) -> Set<String> {
        Set(block.floatAppIds + block.floatApps.map(Row.id(name:)))
    }

    /// `apps` with their switch, plus a floated id none of them has and every float name; those matching `query` (the name
    /// as the app picker matches it, or the bundle id), the ids in `first` first, then by name.
    static func rows(apps: [(name: String, bundle: String)], block: PilotBlock, query: String, first: Set<String>) -> [Row] {
        let ids = Set(block.floatAppIds), listed = Set(apps.map(\.bundle))
        let all = apps.map { Row(name: $0.name, bundle: $0.bundle, floats: ids.contains($0.bundle)) }
            + block.floatAppIds.filter { !listed.contains($0) }.map { Row(name: AppsModule.displayName($0), bundle: $0, floats: true) }
            + block.floatApps.map { Row(name: $0, bundle: nil, floats: true) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { q.isEmpty || FuzzyRanker.score(q, in: $0.name) != nil || $0.bundle?.localizedCaseInsensitiveContains(q) == true }
            .sorted { a, b in
                let fa = first.contains(a.id), fb = first.contains(b.id)
                return fa != fb ? fa : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// A switch: an app by its bundle id, a name from before C8 by its name (off drops it for good).
    static func set(_ row: Row, on: Bool, in block: inout PilotBlock) {
        if let id = row.bundle {
            block.floatAppIds.removeAll { $0 == id }
            if on { block.floatAppIds.append(id) }
        } else {
            block.floatApps.removeAll { $0 == row.name }
            if on { block.floatApps.append(row.name) }
        }
    }
}

/// Gaps on, inner and outer as sliders, and a picture of three windows at those gaps. A drag moves the picture at once and
/// changes the block once it rests, so the tiler lays out once per drag rather than once per point.
private struct GapsEditor: View {
    let block: PilotBlockStore
    @State private var inner: Double?
    @State private var outer: Double?

    var body: some View {
        let shown = (inner: inner ?? Double(block.block.gaps.inner), outer: outer ?? Double(block.block.gaps.outer))
        VStack(alignment: .leading, spacing: 0) {
            GapsPicture(inner: block.block.gapsOn ? shown.inner : 0, outer: block.block.gapsOn ? shown.outer : 0)
                .padding(.bottom, 6)
            BlockRow {
                Toggle("Gaps on", isOn: block.binding(\.gapsOn))
                    .toggleStyle(.pilotSwitchRow(info: "Inner is the room between tiled windows, outer the room at the screen's edges. Off keeps both sizes for when it is back on."))
            }
            BlockRow { DraftSlider(title: "Inner", info: "The room between tiled windows, in points.", label: "Inner gap", value: shown.inner,
                                   draft: $inner, range: 0...100) }
            BlockRow { DraftSlider(title: "Outer", info: "The room between tiled windows and the screen's edges, in points.", label: "Outer gap",
                                   value: shown.outer, draft: $outer, range: 0...100) }
        }
        .task(id: inner) { await block.settleDraft(inner, \.gaps.inner) { inner = nil } }
        .task(id: outer) { await block.settleDraft(outer, \.gaps.outer) { outer = nil } }
        .onDisappear { block.writeDraft(inner, \.gaps.inner) {}; block.writeDraft(outer, \.gaps.outer) {} }
    }

}

/// A whole-number slider row whose moves go to a draft, written once it rests (PilotBlockStore.settleDraft), with the
/// value after it.
private struct DraftSlider: View {
    @Environment(\.ink) private var ink
    let title: String
    var info: String? = nil
    let label: String
    let value: Double
    @Binding var draft: Double?
    let range: ClosedRange<Int>
    var unit = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            if let info { InfoMark(text: info) }
            Spacer()
            KitSlider(value: Binding(get: { value }, set: { draft = $0.rounded() }), range: Double(range.lowerBound)...Double(range.upperBound), step: 1, label: label)
            Text("\(Int(value))\(unit)").font(ink.mono(11.5)).foregroundStyle(ink.text2).fixedSize()
                .frame(width: unit.isEmpty ? 28 : 44, alignment: .trailing)
        }
        .accessibilityValue("\(Int(value))")
    }
}

extension PilotBlockStore {
    /// Writes a slider's resting draft 0.35 s after the last move, then lets the block's value show again: the tiler lays
    /// out once per drag rather than once per point.
    func settleDraft(_ draft: Double?, _ field: WritableKeyPath<PilotBlock, Int> & Sendable, clear: @escaping @MainActor () -> Void) async {
        guard draft != nil, (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
        writeDraft(draft, field, clear: clear)
    }

    /// Writes a draft now: after the rest, or when the page goes before the rest is over.
    func writeDraft(_ draft: Double?, _ field: WritableKeyPath<PilotBlock, Int> & Sendable, clear: @escaping @MainActor () -> Void) {
        guard let draft else { return }
        let value = Int(draft)
        if block[keyPath: field] != value { edit({ $0[keyPath: field] = value }) { _ in clear() } } else { clear() }
    }
}

/// The scrolling layout's four settings (spec scrolling-layout T4): the widths Hyper+R steps a column through (at least
/// one stays on), a new window's width, the sliver at an open screen edge (a slider, written once it rests) and the speed.
private struct ScrollingEditor: View {
    let block: PilotBlockStore
    @State private var sliver: Double?

    static let widths = PilotBlock.ColumnWidth.allCases.map { (value: $0, title: $0.title) }
    static let speeds = PilotBlock.ScrollSpeed.allCases.map { (value: $0, title: $0.title) }

    var body: some View {
        let picked = block.block.scrolling.widths, shown = sliver ?? Double(block.block.scrolling.sliver)
        VStack(alignment: .leading, spacing: 0) {
            BlockRow(first: true) {
                Text("Widths")
                InfoMark(text: "Hyper+R steps the focused column to the next of these, Hyper+Shift+R back, as shares of the screen.")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(Self.widths, id: \.value) { width in
                        let on = picked.contains(width.value)
                        Button { toggle(width.value) } label: { Chip(text: width.title, on: on) }
                            .buttonStyle(.plain).disabled(on && picked.count == 1)
                            .accessibilityLabel("Width \(width.title)").accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            BlockRow {
                Text("New window")
                InfoMark(text: "A new window opens as a column this wide, right of the focused one; no other column changes. A lone window fills the screen.")
                Spacer()
                Segments(selection: block.binding(\.scrolling.newWidth), options: Self.widths, label: "New window's width")
            }
            BlockRow {
                DraftSlider(title: "Sliver", info: "How much of a column past the screen's open edge stays showing, so you see more is there. Toward another display a column hides instead: nothing ever shows on the other screen.",
                            label: "Sliver", value: shown, draft: $sliver, range: PilotBlock.Scrolling.sliverRange, unit: " pt")
            }
            BlockRow {
                Text("Scroll speed")
                InfoMark(text: "Smooth glides 350 ms, Fast 150 ms, Instant jumps. Reduce Motion always jumps.")
                Spacer()
                Segments(selection: block.binding(\.scrolling.speed), options: Self.speeds, label: "Scroll speed")
            }
        }
        .task(id: sliver) { await block.settleDraft(sliver, \.scrolling.sliver) { sliver = nil } }
        .onDisappear { block.writeDraft(sliver, \.scrolling.sliver) {} }
    }

    /// A width on or off, kept in the widths' own order, smallest first. The last one on stays: its chip is disabled, and
    /// the edit checks again, since two quick clicks both pass the chip before either edit runs.
    private func toggle(_ width: PilotBlock.ColumnWidth) {
        block.edit { block in
            let on = block.scrolling.widths.contains(width)
            guard !on || block.scrolling.widths.count > 1 else { return }
            block.scrolling.widths = PilotBlock.ColumnWidth.allCases.filter { $0 == width ? !on : block.scrolling.widths.contains($0) }
        }
    }
}

/// A screen holding three tiled windows, the gaps at twice their share of a 1440 pt screen drawn 220 pt wide, so 10 pt still reads.
private struct GapsPicture: View {
    @Environment(\.ink) private var ink
    let inner: Double
    let outer: Double

    var body: some View {
        let scale = 220.0 / 720, i = inner * scale, o = outer * scale
        let window = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: 8)
        let stacked = window.fill(ink.selected).overlay { window.strokeBorder(ink.line2, lineWidth: 1) }
        HStack(spacing: i) {
            window.fill(ink.accent.opacity(0.28)).overlay { window.strokeBorder(ink.accent, lineWidth: 1) }
            VStack(spacing: i) { stacked; stacked }
        }
        .padding(o)
        .frame(width: 220, height: 124)
        .background(ink.background, in: screen)
        .overlay { screen.strokeBorder(ink.line, lineWidth: 1) }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.12), value: inner)
        .animation(.easeOut(duration: 0.12), value: outer)
        .accessibilityHidden(true)
    }
}

/// The Mouse block's labels and options (cards agent-bo-95422930, agent-bo-95422973), shared with their tests.
enum MouseDragSection {
    static let label = "Drag windows holding"
    static let swipeLabel = "Swipe three fingers between workspaces"
    static let dragTip = "Hold it and drag anywhere in a window to move it, right-drag to resize. Drop a tiled window on another to swap them."
    static let swipeTip = "Three fingers left or right on a trackpad for the next or previous workspace. If macOS's own swipe between Spaces moves too, set it to four fingers in System Settings › Trackpad."
    static let options = DragModifier.allCases.map { (value: $0, title: $0.label) }
    static let tips: [DragModifier: String] = [
        .fn: "Only keyboards that send Fn, like Apple's.",
        .hyper: "Pilot's layer key, the one you hold for binds. A drag with it runs no bind.",
    ]
}
