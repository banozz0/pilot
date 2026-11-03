import AppKit
import Clipboard
import PilotCore
import SwiftUI

// Home on its grid (P91, model A, Sven Q746/Q747): every block on whole cells of 23 columns, drawn in the class its points
// pick (Widget.SizeClass, the desktop widgets' rule) or its Layout keeps. Both styles draw this page; each hands it its
// own forms for the blocks it draws its own way (today's Large: the keyboard, This Mac, the workspace map…).

/// The page: what needs you across the top, then the grid; Edit Home at the foot, and in edit mode its bar pinned to the
/// window's foot instead and the cells dotted. The page is at least the window's height; taller, it scrolls. A 0.5 s hold
/// on empty page enters edit mode; in edit mode a drag on a block carries it, a drag on its corner brackets or edge grips
/// resizes it, the others making room, and a block held near the page's top or bottom edge scrolls it.
struct HomeNowPage<Notices: View, Own: View>: View {
    @Environment(\.homeEdit) private var edit
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let parts: HomeParts
    /// The page's margin.
    var side: CGFloat = 28
    @ViewBuilder let notices: Notices
    /// A block in the style's own form at its size (its Large, and Toybox's Pilot card).
    @ViewBuilder let own: (String, CGSize) -> Own
    /// The page fits the window whole, measured.
    @State private var fits = true
    /// Where the page has scrolled to: a held block near an edge moves it.
    @State private var scroll = ScrollPosition(edge: .top)

    var body: some View {
        GeometryReader { window in
            let inner = max(0, window.size.width - 2 * side)
            // In edit mode the bar takes the window's foot, and the page fits or scrolls above it.
            let height = window.size.height - (parts.editMode == nil ? 0 : HomeEditBar.room)
            ScrollView {
                HomeFill(height: height) { page(inner: inner, height: height) }
                    .frame(width: window.size.width)
                    .onGeometryChange(for: Bool.self) { $0.size.height <= height + 0.5 } action: { fits = $0 }
            }
            // A page that fits neither scrolls nor shows a scroller.
            .scrollIndicators(fits ? .never : .automatic)
            .scrollDisabled(fits)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in edit?.frames.scroll = geometry }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let mode = parts.editMode {
                    HomeEditBar(parts: parts, mode: mode).transition(.opacity)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { edit?.frames.bar = $0 }
                }
            }
            .onGeometryChange(for: CGRect?.self) { edit == nil ? nil : $0.frame(in: .global) } action: { if let rect = $0 { edit?.frames.window = rect } }
            // The carried block, over the page and the edit bar, under the pointer.
            .overlay(alignment: .topLeading) {
                if let mode = parts.editMode, let edit { HomeCarryLayer(mode: mode, frames: edit.frames) { lifted($0, mode) } }
            }
            .task(id: parts.editMode?.scrolling ?? 0) { await autoScroll() }
        }
        .background(Theme.windowFill(style.color(\.canvas)))
    }

    /// While a held block is near an edge, the page scrolls that way at the speed the mode asks, within its ends.
    private func autoScroll() async {
        guard let mode = parts.editMode, mode.scrolling != 0, let frames = edit?.frames else { return }
        var last = ContinuousClock.now
        while !Task.isCancelled, mode.scrolling != 0 {
            guard (try? await Task.sleep(for: .milliseconds(16))) != nil else { return }
            let now = ContinuousClock.now, seconds = (now - last) / .seconds(1)
            last = now
            guard let geometry = frames.scroll else { continue }
            let least = -geometry.contentInsets.top
            let most = max(least, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
            let y = min(most, max(least, geometry.contentOffset.y + mode.scrollSpeed * seconds))
            if abs(y - geometry.contentOffset.y) > 0.1 { scroll.scrollTo(y: y) }
        }
    }

    /// The carried block as the pointer holds it: drawn as at pick-up, at its size then; a tray chip as its chip.
    @ViewBuilder private func lifted(_ lift: HomeEditMode.Lift, _ mode: HomeEditMode) -> some View {
        if lift.fromTray {
            Chip(text: parts.title(lift.id), symbol: "plus")
        } else if !lift.resizing, let inner = edit?.frames.inner {
            block(lift.id, HomeGrid.sizeClass(lift.start, inner: inner, pin: parts.pin(lift.id)), lift.frame.size)
        }
    }

    private func page(inner: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            notices
            grid(inner: inner, height: height)
            if parts.editMode == nil { HomeEditFoot(parts: parts) }
        }
        .padding(.horizontal, side).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A hold on empty page (a block's own hold looks at where it is held) enters edit mode.
        .contentShape(.rect)
        .gesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 4).onEnded { _ in parts.beginEdit(byHold: true) },
                 including: parts.editMode == nil ? .all : .subviews)
        // In edit mode a drag that starts on a block carries it; its handles, chip and ✕ keep their own.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { parts.editMode?.drag(from: $0.startLocation, to: $0.location) }
            .onEnded { _ in parts.editMode?.release() },
                 including: parts.editMode == nil ? .subviews : .all)
        .coordinateSpace(.named(HomeFrames.space))
        // Where the page lies on screen, again as it scrolls under a held block, which then finds the cells now under it.
        .onGeometryChange(for: CGPoint?.self) { edit == nil ? nil : $0.frame(in: .global).origin } action: { origin in
            guard let origin else { return }
            edit?.frames.origin = origin
            parts.editMode?.aim()
        }
        .onChange(of: edit.map { _ in parts.cells }, initial: true) { _, cells in
            if let cells {
                edit?.frames.cells = cells
                parts.editMode?.frames = edit?.frames
            }
        }
        // Edit mode hears Reduce Motion, and the keyboard starts on the first block (its ring shows once a key is pressed).
        .onChange(of: EditStart(mode: parts.editMode.map(ObjectIdentifier.init), reduce: reduceMotion), initial: true) {
            guard let mode = parts.editMode else { return }
            mode.reduceMotion = reduceMotion
            if mode.focus == nil { mode.focus = HomeLayout.reading(parts.cells).first }
        }
    }

    /// The blocks on their cells, in reading order; in edit mode the cells dotted under them, a few rows past the last,
    /// and where a held block lands outlined over them.
    private func grid(inner: CGFloat, height: CGFloat) -> some View {
        let cells = parts.cells
        return HomeGridLayout {
            ForEach(HomeLayout.reading(cells), id: \.self) { id in
                if let cell = cells[id] {
                    let rect = HomeGrid.rect(cell, inner: inner)
                    let drawn = HomeGrid.sizeClass(cell, inner: inner, pin: parts.pin(id))
                    block(id, drawn, rect.size)
                        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                        // A block never draws outside its cells, but for the solid foot under a Toybox card.
                        .clipShape(HomeCellClip(foot: style.kind == .toybox ? HomeCellClip.toyFoot : 0))
                        .homeFrame(.block(id), edit)
                        .homeEditable(id, parts, drawn: drawn, wide: rect.width > 170)
                        .homeCell(cell)
                }
            }
        }
        .frame(width: inner, alignment: .topLeading)
        .background(alignment: .topLeading) {
            if edit != nil { HomeCellDots(inner: inner, rows: (cells.values.map(\.maxY).max() ?? 0) + 4) }
        }
        .overlay(alignment: .topLeading) { if let mode = parts.editMode { HomeSnapLayer(mode: mode, parts: parts, inner: inner) } }
        .homeFrame(.grid, edit)
        // The edit chrome on a block's top edge may reach over the one above.
        .zIndex(1)
    }

    /// A block in the class it draws: a Strip its one line and a Square its figure (every block alike, the keyboard's
    /// Square its small board); Wide the lists folded to the block (today's Small) and an extension's first figures; Large
    /// the style's own form (today's Large) and an extension's whole page. A widget's tile picks its own class by its size;
    /// the greeting is its card at every size but a Strip.
    @ViewBuilder private func block(_ id: String, _ drawn: Widget.SizeClass, _ size: CGSize) -> some View {
        let builtIn = HomeLayout.Block(rawValue: id)
        if let widget = parts.widget(id) {
            HomeWidgetBlock(widget: widget, parts: parts)
        } else if drawn == .strip {
            HomeStripBlock(id: id, parts: parts)
        } else if builtIn == .greeting {
            HomeGreetingCard(parts: parts, rows: Int(((size.height + HomeGrid.gap) / HomeGrid.pitch).rounded()))
        } else if drawn == .square {
            if builtIn == .keyboard { HomeMiniBoard(parts: parts) } else { HomeSquareBlock(id: id, parts: parts) }
        } else if let ext = HomeLayout.extensionID(id) {
            HomeExtensionBlock(id: ext, parts: parts, drawn: drawn, width: size.width)
        } else if drawn == .wide, builtIn != .pilot, let card = HomeSmallBlock(id: id, parts: parts) {
            card
        } else {
            own(id, size)
        }
    }
}

/// What edit mode is told by the page as it begins or Reduce Motion changes.
private struct EditStart: Equatable {
    let mode: ObjectIdentifier?
    let reduce: Bool
}

/// A block's clip: its cells' frame, and `foot` points below it for the solid foot a Toybox card draws under itself.
struct HomeCellClip: Shape {
    var foot: CGFloat = 0
    /// Toybox's card foot, within the 8 pt between rows.
    static let toyFoot: CGFloat = 6

    func path(in rect: CGRect) -> Path { Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + foot)) }
}

/// The page at least the window's height, taller when its blocks need it.
struct HomeFill: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let page = subviews.first else { return .zero }
        let own = page.sizeThatFits(ProposedViewSize(width: proposal.width, height: 0))
        return CGSize(width: proposal.width ?? own.width, height: max(own.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - The greeting

/// The greeting block: the date, the greeting by the hour and what Hyper and the tiler are doing, or what needs you, as
/// much of it as its cells hold.
struct HomeGreetingCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let parts: HomeParts
    /// The rows of cells it takes.
    var rows = 3

    var body: some View {
        // As much as its cells hold: two rows the line, three the binds too, one just the date and the greeting.
        content(line: rows >= 2, binds: rows >= 3)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .styleSurface(\.card)
            .accessibilityElement(children: .combine)
    }

    private func content(line showLine: Bool, binds showBinds: Bool) -> some View {
        let tiler = engine.observers.tiler
        let line = HomeGreeting.line(hyperOn: engine.hyperSwitch.isOn, problems: parts.problems, layerKey: engine.settings.layerKeys.label,
                                     workspace: tiler.focused, tiler: tiler.tilerName)
        return HStack(alignment: .top, spacing: 14) {
            if style.kind == .toybox { PilotMark(size: 46) }
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.everyMinute) { context in
                    let date = context.date
                    VStack(alignment: .leading, spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(ink.ui(11.5, .medium)).foregroundStyle(ink.muted)
                        Text(HomeGreeting.hello(at: date))
                            .font(ink.display(style.kind == .toybox ? 24 : 21)).foregroundStyle(ink.text)
                            .lineLimit(1).minimumScaleFactor(0.8).accessibilityAddTraits(.isHeader)
                    }
                }
                if showLine {
                    // Two rows hold one line of it, three or more three lines.
                    Text(line).font(ink.ui(12.5)).foregroundStyle(parts.problems.isEmpty ? ink.text2 : ink.warnText)
                        .lineLimit(rows >= 3 ? 3 : 1).truncationMode(.tail)
                }
                if showBinds {
                    let binds = engine.binds.store.binds.count
                    Text("\(binds) \(ToyHome.bindsLine(binds: binds, clashes: parts.clashes))").font(ink.ui(11.5))
                        .foregroundStyle(parts.clashes > 0 ? ink.warnText : ink.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension HomeGreeting {
    /// The person's first name, as the greeting says it.
    static let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()

    /// "Morning, Sven.": the greeting by the hour of `date`.
    static func hello(at date: Date) -> String { "\(ToyHome.greeting(Calendar.current.component(.hour, from: date))), \(firstName)." }
}

// MARK: - Small blocks

/// A block's Wide card (today's Small: its list folded to the block), the same in every style; nil leaves it to the style
/// (the Pilot block).
struct HomeSmallBlock: View {
    private enum Form { case workspaces, keyboard, mostUsed, clipboard, thisMac, page(String), widget(HomeWidget) }
    private let form: Form
    private let parts: HomeParts

    init?(id: String, parts: HomeParts) {
        switch HomeLayout.Block(rawValue: id) {
        case .workspaces?: form = .workspaces
        case .keyboard?: form = .keyboard
        case .mostUsed?: form = .mostUsed
        case .clipboard?: form = .clipboard
        case .thisMac?: form = .thisMac
        case .greeting?, .pilot?, .quickActions?: return nil
        case nil:
            if let ext = HomeLayout.extensionID(id) { form = .page(ext) }
            else if let widget = parts.widget(id) { form = .widget(widget) }
            else { return nil }
        }
        self.parts = parts
    }

    var body: some View {
        Group {
            // Each fills its cells, its list folded to them.
            switch form {
            case .workspaces: HomeWorkspaceRows(parts: parts, rows: nil, fill: true)
            case .keyboard: HomeMiniBoard(parts: parts)
            case .mostUsed: HomeMostUsedRows(parts: parts, rows: nil, fill: true)
            case .clipboard: HomeClipRows(parts: parts, rows: nil, fill: true)
            case .thisMac: HomeMacRows(fill: true)
            case .page(let ext): HomeExtensionBlock(id: ext, parts: parts, drawn: .wide)
            case .widget(let widget): HomeWidgetBlock(widget: widget, parts: parts)
            }
        }
    }
}

/// A list's row height in the style: Toybox's rows are a step taller for its rounder face.
@MainActor
enum HomeRow {
    static func height(_ style: PilotStyle) -> CGFloat { style == .toybox ? 34 : 30 }
}

/// Where a list's "N more" goes: the list's own page, with the key that opens it.
struct HomeMore {
    let title: String
    var key: Key?
    let open: () -> Void
}

/// A list in its card: as many rows as the card holds (`rows` fixed, else fitted to the height it is given, none when
/// not even one fits), the last that fits "N more" when some are left (HomeFold); none, its empty line.
struct HomeFoldList<Row: View>: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let total: Int
    /// The rows drawn so far, which the fold never passes.
    var available: Int?
    let rows: Int?
    let more: HomeMore
    var empty = "Nothing yet."
    @ViewBuilder let row: (Int) -> Row
    @State private var fits = 3

    var body: some View {
        let height = HomeRow.height(style.kind)
        // The most lines it can draw: every row, or as many as are read.
        let cap = min(total, available ?? total)
        let lines = min(cap, rows ?? cap)
        // Fitted to a block too short for a row, it draws none and goes on measuring.
        let fold = rows == nil && fits == 0 ? (shown: 0, more: 0) : HomeFold.rows(total: total, fits: min(rows ?? fits, max(1, cap)))
        if total == 0 {
            Text(empty).font(ink.ui(12)).foregroundStyle(ink.muted).frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(0..<fold.shown, id: \.self) { i in line(first: i == 0) { row(i) } }
                if fold.more > 0 { line(first: fold.shown == 0) { HomeMoreRow(count: fold.more, more: more) } }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(minHeight: rows == nil ? 0 : CGFloat(lines) * height, idealHeight: CGFloat(lines) * height,
                   maxHeight: CGFloat(lines) * height, alignment: .top)
            .onGeometryChange(for: Int.self, of: { HomeFold.fits(height: $0.size.height, row: height, least: 0) }) { fits = $0 }
            .clipped()
        }
    }

    private func line(first: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 9) { content() }
            .frame(maxWidth: .infinity, minHeight: HomeRow.height(style.kind), maxHeight: HomeRow.height(style.kind), alignment: .leading)
            .overlay(alignment: .top) { if !first { ink.line.frame(height: style.kind == .toybox ? 1.5 : 1).opacity(style.kind == .toybox ? 0.5 : 1) } }
    }
}

/// The last row of a folded list: how many more, and its page with the key that opens it.
struct HomeMoreRow: View {
    @Environment(\.ink) private var ink
    let count: Int
    let more: HomeMore

    var body: some View {
        Button(action: more.open) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.right").font(ink.system(9.5, weight: .bold)).frame(width: 16)
                Text("\(count) more").font(ink.ui(12, .semibold)).foregroundStyle(ink.text2)
                Text("· \(more.title)").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                Spacer(minLength: 4)
                if let key = more.key { HomeKeys(trigger: key) }
            }
            .foregroundStyle(ink.muted)
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help("\(count) more: \(more.title)")
        .accessibilityLabel("\(count) more, \(more.title)")
    }
}

/// A plain row's parts: a lead (icon, number or emoji), its words, and a quiet figure at the end.
private struct HomeLine<Lead: View>: View {
    @Environment(\.ink) private var ink
    let title: String
    var detail: String?
    var trailing: String?
    var strong = false
    @ViewBuilder let lead: Lead

    var body: some View {
        lead.frame(width: 16, height: 16)
        HStack(spacing: 6) {
            Text(title).font(ink.ui(12.5, strong ? .medium : .regular)).foregroundStyle(ink.text).layoutPriority(1)
            if let detail { Text(detail).font(ink.ui(11.5)).foregroundStyle(ink.muted) }
        }
        .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 4)
        if let trailing { Text(trailing).font(ink.mono(11)).monospacedDigit().foregroundStyle(ink.muted).lineLimit(1).fixedSize() }
    }
}

/// Workspaces as rows: its number, its apps, "here" on the one you are on; a click goes there.
struct HomeWorkspaceRows: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    let parts: HomeParts
    let rows: Int?
    var fill = false

    var body: some View {
        let tiler = engine.observers.tiler
        let cells = tiler.homeCells
        Tile(title: "Workspaces", symbol: HomeLayout.Block.workspaces.symbol, fill: fill) {
            Text(tiler.focused == nil ? "stopped" : "\(tiler.windows.count) windows").font(ink.ui(11.5)).foregroundStyle(ink.muted)
        } content: {
            if tiler.focused == nil {
                Text("Tiling is stopped; your binds still work.").font(ink.ui(12)).foregroundStyle(ink.muted)
            } else {
                HomeFoldList(total: cells.count, rows: rows, more: HomeMore(title: "Open Workspaces") { parts.go(AppPlace(.workspaces)) }) { i in
                    let cell = cells[i], here = cell.name == tiler.focused
                    Button { tiler.go(cell.name, from: "home") } label: {
                        HomeLine(title: cell.apps.isEmpty ? "empty" : cell.apps.joined(separator: ", "), trailing: here ? "here" : nil) {
                            Text(cell.name).font(ink.mono(11.5, weight: .medium)).foregroundStyle(here ? ink.accentInk : ink.text2)
                                .frame(width: 18, height: 18)
                                .background(here ? ink.selection : ink.well, in: .rect(cornerRadius: ink.radius(4), style: .continuous))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.kitPress)
                    .help("Go to workspace \(cell.name)")
                    .accessibilityLabel("Workspace \(cell.name)\(here ? ", here" : ""): \(cell.apps.joined(separator: ", "))")
                }
            }
        }
    }
}

/// Today's most pressed binds: its keys, its name and its count; "N more" opens Activity.
struct HomeMostUsedRows: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    let parts: HomeParts
    let rows: Int?
    var fill = false

    var body: some View {
        let now = Date()
        let top = engine.today.top(40, now: now)
        Tile(title: "Most used", symbol: HomeLayout.Block.mostUsed.symbol, fill: fill) {
            Text("\(engine.today.total(now: now)) presses").font(ink.ui(11.5)).foregroundStyle(ink.muted)
        } content: {
            HomeFoldList(total: top.count, rows: rows, more: HomeMore(title: "Open Activity") { parts.go(AppPlace(.activity)) },
                         empty: "Hold \(engine.settings.layerKeys.label) and press a key; it counts here.") { i in
                let row = top[i]
                HomeLine(title: engine.action(row.action)?.label ?? row.action, trailing: "\(row.count)") {
                    Image(systemName: "flame").font(ink.system(10)).foregroundStyle(ink.muted)
                }
                .help(engine.binds.store.trigger(for: row.action).map { "\(HomeKeys.cap($0)): \(engine.action(row.action)?.label ?? row.action)" } ?? "")
            }
        }
    }
}

/// The newest copies: the kind's symbol (a colour its swatch), the words and how long ago; a click opens the clipboard.
struct HomeClipRows: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    let parts: HomeParts
    let rows: Int?
    var fill = false
    @State private var clips: [StoredClip] = []

    var body: some View {
        let kept = max(parts.copy?.count ?? 0, clips.count)
        Tile(title: "Clipboard", symbol: HomeLayout.Block.clipboard.symbol, fill: fill) {
            Text("\(kept) kept").font(ink.ui(11.5)).foregroundStyle(ink.muted)
        } content: {
            TimelineView(.everyMinute) { context in
                HomeFoldList(total: kept, available: clips.count, rows: rows,
                             more: HomeMore(title: "Open Clipboard", key: engine.binds.store.trigger(for: "apps.clipboard")) {
                                 engine.action("apps.clipboard")?.run()
                             },
                             empty: "What you copy shows here, newest first.") { i in
                    let clip = clips[i]
                    Button { engine.action("apps.clipboard")?.run() } label: {
                        HomeLine(title: Snippet.firstLine(String(clip.title.prefix(200))) ?? "", trailing: InstrumentClips.ago(context.date.timeIntervalSince(clip.copiedAt))) {
                            if let swatch = clip.swatch {
                                RoundedRectangle(cornerRadius: 3).fill(Color(hex: swatch)).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: clip.kind.symbol).font(ink.system(10)).foregroundStyle(ink.muted)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.kitPress)
                    .help(clip.title)
                    .accessibilityLabel("\(clip.kind.label): \(clip.title)")
                }
            }
        }
        // Read only while it is on Home, as the window shows.
        .task(id: parts.onScreen) { clips = Array(parts.sources.recentCopies().prefix(InstrumentClips.most)) }
    }
}

/// This Mac's four readings as rows: CPU, memory, free disk and the temperature, as many as its block holds.
struct HomeMacRows: View {
    @Environment(\.ink) private var ink
    var fill = false
    @State private var fits = 4
    private var shown: Int { fill ? min(4, fits) : 4 }

    var body: some View {
        let system = SystemSampler.shared
        let values = system.latestValues, raw = system.latest
        let gib = Double(1 << 30)
        let readings: [(String, String, String)] = [
            ("cpu", "CPU", values?.cpu.map { StatsFormat.percent($0) + "%" } ?? "–"),
            ("memorychip", "Memory", raw.map { String(format: "%.1f / %d GB", Double($0.memory.used) / gib, Int((Double($0.memory.total) / gib).rounded())) } ?? "–"),
            ("internaldrive", "Disk free", raw?.slow.disk.map { StatsFormat.bytes(Double($0.available)) } ?? "–"),
            ("thermometer.medium", "Temperature", values?.heat.map { StatsFormat.whole($0) + "°C" } ?? "–"),
        ]
        Tile(title: "This Mac", symbol: HomeLayout.Block.thisMac.symbol, fill: fill) {
            if let chip = raw?.slow.machine?.chip { Text(chip).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1) }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(readings.prefix(shown).enumerated()), id: \.offset) { i, reading in
                    HStack(spacing: 9) {
                        HomeLine(title: reading.1, trailing: reading.2) {
                            Image(systemName: reading.0).font(ink.system(10)).foregroundStyle(ink.muted)
                        }
                    }
                    .frame(height: HomeRow.height(ink.style.kind))
                    .overlay(alignment: .top) { if i > 0 { ink.line.frame(height: 1) } }
                    .accessibilityElement(children: .combine)
                }
            }
            // As many readings as its block holds, CPU first: the frame gives way to one row, so it measures the height the
            // block has left.
            .frame(maxWidth: .infinity, minHeight: fill ? HomeRow.height(ink.style.kind) : nil, maxHeight: fill ? .infinity : nil, alignment: .top)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fits = HomeFold.fits(height: $0, row: HomeRow.height(ink.style.kind), least: 1) }
        }
    }
}
