import AppKit
import Clipboard
import PilotCore
import SwiftUI

// Home, direction 2 "Now beside the board" (Sven's pick, 2026-10-12): a column of what is happening (the greeting, the
// icon tabs, then every small block as a card of rows) beside the board (medium blocks two to a row, large ones across
// it). Both styles draw this page; each hands it its own board blocks. Under the board's least width the column goes over
// the board and each list shows five rows.

/// The page: what needs you across the top, the column and the board side by side while both fit, else one over the
/// other; Edit Home at the foot, and in edit mode its bar pinned to the window's foot instead. At its least height the
/// page fills the window and the lists fold to it; taller, it scrolls. A 0.5 s hold on empty page enters edit mode; in
/// edit mode a drag on a block carries it (HomeEditMode), the page making room where it would land, and a carried block
/// held near the page's top or bottom edge scrolls it.
struct HomeNowPage<Notices: View, Board: View>: View {
    @Environment(\.style) private var style
    @Environment(\.homeEdit) private var edit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let parts: HomeParts
    /// The page's margin and the room between blocks.
    var side: CGFloat = 28
    var gap: CGFloat = 16
    @ViewBuilder let notices: Notices
    /// A board block in the style at its width, `fill` when its row takes a share of the window's height.
    @ViewBuilder let board: (String, Bool, CGFloat) -> Board
    /// The page fits the window whole, measured.
    @State private var fits = true
    /// Where the page has scrolled to: a carried block near an edge moves it.
    @State private var scroll = ScrollPosition(edge: .top)

    private static var column: CGFloat { HomeNow.column }

    var body: some View {
        GeometryReader { window in
            let inner = max(0, window.size.width - 2 * side)
            let wide = HomeNow.sideBySide(inner: inner, gap: gap)
            // In edit mode the bar takes the window's foot, and the page fits or scrolls above it.
            let height = window.size.height - (parts.editMode == nil ? 0 : HomeEditBar.room)
            ScrollView {
                HomeFill(height: height, fill: wide) { page(inner: inner) }
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

    /// While a carried block is held near an edge, the page scrolls that way at the speed the mode asks, within its ends.
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
        } else {
            switch mode.session.draft.size(of: lift.id) {
            case .icon: HomeIconTab(id: lift.id, parts: parts) { EmptyView() }
            case .small: small(lift.id, rows: nil, last: true)
            case .medium, .large: board(lift.id, true, lift.frame.width)
            }
        }
    }

    private func page(inner: CGFloat) -> some View {
        // The shape taken at pick-up holds while a block is carried.
        let (shape, lanes) = HomeNow.arrange(parts.blocks, size: parts.size, inner: inner, gap: gap, held: edit?.held ?? parts.editMode?.lift?.shape)
        let wide = shape.wide
        let boardWidth = wide ? inner - Self.column - gap : inner
        return VStack(alignment: .leading, spacing: gap) {
            notices
            if wide {
                HStack(alignment: .top, spacing: gap) {
                    column(lanes, rows: nil).frame(width: Self.column).frame(maxHeight: .infinity, alignment: .top)
                        .homeFrame(.lane(.column), edit)
                        // An icon tab's size chips may reach over the board.
                        .zIndex(1)
                    boardLane(lanes.board, width: boardWidth, fill: true, across: shape.across).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                stacked(lanes, inner: inner).homeFrame(.lane(.column), edit)
                boardLane(lanes.board, width: boardWidth, fill: false, across: shape.across)
            }
            if parts.editMode == nil { HomeEditFoot(parts: parts) }
        }
        .padding(.horizontal, side).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil, alignment: .topLeading)
        // The size chip under the pointer: the block's new frame, dashed.
        .overlay(alignment: .topLeading) { if let mode = parts.editMode, let edit { HomeSizeGhostLayer(mode: mode, frames: edit.frames, parts: parts) } }
        // A hold on empty page (a block's own hold looks at where it is held) enters edit mode.
        .contentShape(.rect)
        .gesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 4).onEnded { _ in parts.beginEdit(byHold: true) },
                 including: parts.editMode == nil ? .all : .subviews)
        // In edit mode a drag that starts on a block carries it; its chips and ✕ keep their clicks.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { parts.editMode?.drag(from: $0.startLocation, to: $0.location) }
            .onEnded { _ in parts.editMode?.release() },
                 including: parts.editMode == nil ? .subviews : .all)
        .coordinateSpace(.named(HomeFrames.space))
        // Where the page lies on screen, again as it scrolls under a carried block, which then finds the slot now under it.
        .onGeometryChange(for: CGPoint?.self) { edit == nil ? nil : $0.frame(in: .global).origin } action: { origin in
            guard let origin else { return }
            edit?.frames.origin = origin
            parts.editMode?.aim()
        }
        .onChange(of: edit.map { _ in HomeFrames.Drawn(shape: shape, lanes: lanes) }, initial: true) { _, drawn in
            if let drawn {
                edit?.frames.drawn = drawn
                parts.editMode?.frames = edit?.frames
            }
        }
        // Edit mode hears Reduce Motion, and the keyboard starts on the first block (its ring shows once a key is pressed).
        .onChange(of: EditStart(mode: parts.editMode.map(ObjectIdentifier.init), reduce: reduceMotion), initial: true) {
            guard let mode = parts.editMode else { return }
            mode.reduceMotion = reduceMotion
            if mode.focus == nil { mode.focus = HomeEditMode.order(parts.blocks, size: parts.size, across: shape.across).first }
        }
    }

    /// The column: the greeting, the icon tabs, then the small cards, the last taking what height is left so the column
    /// ends level with the board.
    private func column(_ lanes: HomeLayout.Lanes, rows: Int?) -> some View {
        HomeColumn(spacing: gap) {
            HomeGreetingCard(parts: parts)
            icons(lanes.icons)
            ForEach(Array(lanes.column.enumerated()), id: \.element) { i, id in
                small(id, rows: rows, last: i == lanes.column.count - 1).homeFrame(.block(id), edit).homeEditable(id, parts)
            }
            if lanes.column.isEmpty { well(.column, height: HomeNow.well, fill: true) }
        }
    }

    /// Under the board's width, or with an empty board: the greeting and the tabs across, then the small cards as many
    /// to a row as keep 280 pt each (HomeNow.across), five rows a list.
    private func stacked(_ lanes: HomeLayout.Lanes, inner: CGFloat) -> some View {
        let across = HomeNow.across(inner: inner, gap: gap)
        return VStack(alignment: .leading, spacing: gap) {
            HomeGreetingCard(parts: parts)
            icons(lanes.icons)
            ForEach(Array(stride(from: 0, to: lanes.column.count, by: across)), id: \.self) { start in
                let row = lanes.column[start..<min(start + across, lanes.column.count)]
                HStack(alignment: .top, spacing: gap) {
                    ForEach(row, id: \.self) {
                        small($0, rows: HomeFold.stacked, last: false).frame(maxWidth: .infinity).homeFrame(.block($0), edit).homeEditable($0, parts)
                    }
                    ForEach(0..<(across - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if lanes.column.isEmpty { well(.column, height: HomeNow.well) }
        }
    }

    @ViewBuilder private func icons(_ ids: [String]) -> some View {
        if !ids.isEmpty {
            Flow(spacing: 10) {
                ForEach(ids, id: \.self) { id in
                    HomeIconTab(id: id, parts: parts) { small(id, rows: HomeFold.stacked, last: false).frame(width: Self.column) }
                        .homeFrame(.block(id), edit).homeEditable(id, parts, tab: true)
                }
            }
        } else {
            well(.icons, height: HomeLayout.Size.tab)
        }
    }

    /// An empty lane's well, in edit mode only, `fill` taking the height left.
    @ViewBuilder private func well(_ lane: HomeSlots.Lane, height: CGFloat, fill: Bool = false) -> some View {
        if edit != nil {
            HomeWell(lane: lane, tall: height > HomeLayout.Size.tab).frame(minHeight: height, maxHeight: fill ? .infinity : height).homeFrame(.well(lane), edit)
        }
    }

    /// A small block: the column's own card for it, else the style's (the Pilot block).
    @ViewBuilder private func small(_ id: String, rows: Int?, last: Bool) -> some View {
        if let card = HomeSmallBlock(id: id, parts: parts, rows: rows, stretch: last) { card } else { board(id, false, Self.column) }
    }

    /// The board's rows: a large block across, two medium ones side by side ending level. At rest a lone medium spans the
    /// board; in edit mode it takes its half and the other half is a well a medium pairs with it in (Sven, Q55): its right,
    /// or its left while its pair there is carried (HomeSlots gives that half the slot).
    private func boardLane(_ rows: [[String]], width: CGFloat, fill: Bool, across: Int) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(rows, id: \.self) { row in
                let lone = edit != nil && across == 2 && row.count == 1 && parts.size(row[0]) == .medium
                let left = lone && parts.editMode?.lift?.slots.slots.contains { $0.place == .beside(row[0], trailing: false) } == true
                let each = row.count > 1 || lone ? (width - gap) / 2 : width
                HStack(alignment: .top, spacing: gap) {
                    ForEach(row, id: \.self) { board($0, fill, each).frame(width: each).homeFrame(.block($0), edit).homeEditable($0, parts) }
                }
                .frame(maxWidth: .infinity, alignment: left ? .trailing : .leading)
                .background(alignment: left ? .leading : .trailing) {
                    if lone { HomeWell(lane: .board, says: "A medium dropped here pairs with \(parts.title(row[0]))").frame(width: each) }
                }
                .fixedSize(horizontal: false, vertical: !fill)
            }
            if rows.isEmpty { well(.board, height: HomeNow.well, fill: fill) }
        }
        .homeFrame(.lane(.board), edit)
    }
}

/// What edit mode is told by the page as it begins or Reduce Motion changes.
private struct EditStart: Equatable {
    let mode: ObjectIdentifier?
    let reduce: Bool
}

/// Direction 2's widths.
enum HomeNow {
    /// The column's width, and the board's least: under it the keyboard's names crowd its keys.
    static let column: CGFloat = 300, boardLeast: CGFloat = 760
    /// The keyboard keeps its 75 % board whole from this width; narrower, it splits as Binds' does.
    static let wholeBoard: CGFloat = 860

    /// An empty lane's well in edit mode, the column's or the board's; the icon row's is a tab high.
    static let well: CGFloat = 120

    /// Small cards to a row when the column lies across the page: as many as keep 280 pt each, one to four.
    static func across(inner: CGFloat, gap: CGFloat) -> Int { max(1, min(4, Int((inner + gap) / (280 + gap)))) }

    /// The column beside the board while the page's inner width holds both.
    static func sideBySide(inner: CGFloat, gap: CGFloat) -> Bool { inner >= column + gap + boardLeast }

    /// The page's shape: the column beside the board (`wide`) or over it, the board one block across or two, and the gap
    /// between blocks.
    struct Shape: Equatable {
        let wide: Bool
        let across: Int
        let gap: CGFloat
    }

    /// The shape and lanes the page draws its blocks in. With nothing on the board, the column's cards spread across the
    /// page; with nothing in the column, the board takes the page under the greeting; unless a shape is `held` from pick-up
    /// (spec home-edit: the page never restructures under a carried block), where the width allows it.
    static func arrange(_ blocks: [String], size: (String) -> HomeLayout.Size, inner: CGFloat, gap: CGFloat, held: Shape?) -> (Shape, HomeLayout.Lanes) {
        let side = sideBySide(inner: inner, gap: gap)
        let across = (side ? inner - column - gap : inner) >= 2 * column + gap ? 2 : 1
        let lanes = HomeLayout.lanes(blocks, size: size, across: across)
        let wide = side && (held?.wide ?? (!lanes.board.isEmpty && !(lanes.column.isEmpty && lanes.icons.isEmpty)))
        return (Shape(wide: wide, across: across, gap: gap), lanes)
    }
}

/// An empty lane in edit mode, where a block can go: dashed, saying which size puts one there.
struct HomeWell: View {
    @Environment(\.ink) private var ink
    let lane: HomeSlots.Lane
    /// Room for its words; the icon row's well is a tab high.
    var tall = true
    /// Its own words, else its lane's.
    var says: String? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(12), style: .continuous)
        shape.fill(ink.text.opacity(0.025))
            .overlay { shape.strokeBorder(ink.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            .overlay {
                Text(says ?? words).font(ink.ui(tall ? 12 : 11.5)).foregroundStyle(ink.muted).multilineTextAlignment(.center)
                    .lineLimit(tall ? 2 : 1).padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var words: String {
        switch lane {
        case .icons: "Icon puts a block here as a tab"
        case .column: "Small puts a block here as a card"
        case .board: "Medium or Large puts a block on the board"
        }
    }
}

/// The column's cards stacked in its height: each at its least first, then the height left shared evenly up to each
/// one's whole list, the last taking what remains, so every list shows as many rows as the column holds.
struct HomeColumn: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? HomeNow.column
        let least = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: 0)).height } + gaps(subviews)
        guard let height = proposal.height else {
            return CGSize(width: width, height: subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height } + gaps(subviews))
        }
        return CGSize(width: width, height: max(least, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        let least = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: 0)).height }
        var most = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: .infinity)).height }
        if !most.isEmpty { most[most.count - 1] = .infinity }
        let heights = Self.share(bounds.height - gaps(subviews), least: least, most: most)
        var y = bounds.minY
        for (view, height) in zip(subviews, heights) {
            view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: width, height: height))
            y += height + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(0, subviews.count - 1)) }

    /// `height` shared out: each its least; then a list that the height left holds whole is shown whole, smallest first;
    /// the rest goes in even shares, none past its most.
    static func share(_ height: CGFloat, least: [CGFloat], most: [CGFloat]) -> [CGFloat] {
        var sizes = least
        var left = height - least.reduce(0, +)
        while left > 0.5 {
            let open = sizes.indices.filter { sizes[$0] < most[$0] }.sorted { most[$0] - sizes[$0] < most[$1] - sizes[$1] }
            guard let first = open.first else { break }
            let even = left / CGFloat(open.count), need = most[first] - sizes[first]
            if need > even && need <= left {
                sizes[first] = most[first]
                left -= need
                continue
            }
            for i in open {
                let add = min(even, most[i] - sizes[i])
                sizes[i] += add
                left -= add
            }
        }
        return sizes
    }
}

/// The page at least the window's height: while `fill`, at its least height when that is taller (every list at its
/// fewest rows), so the lists fold into the window; else at its own height.
struct HomeFill: Layout {
    let height: CGFloat
    let fill: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let page = subviews.first else { return .zero }
        let own = page.sizeThatFits(ProposedViewSize(width: proposal.width, height: fill ? 0 : nil))
        return CGSize(width: proposal.width ?? own.width, height: fill ? max(own.height, height) : own.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - The greeting

/// The column's head: the date, the greeting by the hour and what Hyper and the tiler are doing, or what needs you.
struct HomeGreetingCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let parts: HomeParts

    var body: some View {
        let tiler = engine.observers.tiler
        let line = HomeGreeting.line(hyperOn: engine.hyperSwitch.isOn, problems: parts.problems, layerKey: engine.settings.layerKeys.label,
                                     workspace: tiler.focused, tiler: tiler.tilerName)
        HStack(alignment: .top, spacing: 14) {
            if style.kind == .toybox { PilotMark(size: 46) }
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.everyMinute) { context in
                    let date = context.date
                    VStack(alignment: .leading, spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(ink.ui(11.5, .medium)).foregroundStyle(ink.muted)
                        Text("\(ToyHome.greeting(Calendar.current.component(.hour, from: date))), \(HomeGreeting.firstName).")
                            .font(ink.display(style.kind == .toybox ? 24 : 21)).foregroundStyle(ink.text)
                            .lineLimit(1).minimumScaleFactor(0.8).accessibilityAddTraits(.isHeader)
                    }
                }
                Text(line).font(ink.ui(12.5)).foregroundStyle(parts.problems.isEmpty ? ink.text2 : ink.warnText)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                let binds = engine.binds.store.binds.count
                Text("\(binds) \(ToyHome.bindsLine(binds: binds, clashes: parts.clashes))").font(ink.ui(11.5))
                    .foregroundStyle(parts.clashes > 0 ? ink.warnText : ink.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .styleSurface(\.card)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

extension HomeGreeting {
    /// The person's first name, as the greeting says it.
    static let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
}

// MARK: - Small blocks

/// A block's small card in the column, the same in every style; nil leaves it to the style (the Pilot block).
struct HomeSmallBlock: View {
    private enum Form { case workspaces, keyboard, mostUsed, clipboard, thisMac, page(String) }
    private let form: Form
    private let parts: HomeParts
    /// Rows a list shows; nil fits them to the card's height.
    private let rows: Int?
    /// Takes what height the column has left.
    private let stretch: Bool

    init?(id: String, parts: HomeParts, rows: Int?, stretch: Bool = false) {
        switch HomeLayout.Block(rawValue: id) {
        case .workspaces?: form = .workspaces
        case .keyboard?: form = .keyboard
        case .mostUsed?: form = .mostUsed
        case .clipboard?: form = .clipboard
        case .thisMac?: form = .thisMac
        case .pilot?, .quickActions?: return nil
        case nil:
            guard let ext = HomeLayout.extensionID(id) else { return nil }
            form = .page(ext)
        }
        self.parts = parts
        self.rows = rows
        self.stretch = stretch
    }

    var body: some View {
        Group {
            // Only the column's last card takes the height left over; the others end at their rows.
            let fill = stretch && rows == nil
            switch form {
            case .workspaces: HomeWorkspaceRows(parts: parts, rows: rows, fill: fill)
            case .keyboard: HomeMiniBoard(parts: parts)
            case .mostUsed: HomeMostUsedRows(parts: parts, rows: rows, fill: fill)
            case .clipboard: HomeClipRows(parts: parts, rows: rows, fill: fill)
            case .thisMac: HomeMacRows(fill: fill)
            case .page(let ext): HomeExtensionBlock(id: ext, parts: parts, rows: rows, fill: fill)
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

/// A list in its card: as many rows as the card holds (`rows` fixed, else fitted to the height it is given, three at
/// least), the last that fits "N more" when some are left (HomeFold); none, its empty line.
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
        let fold = HomeFold.rows(total: total, fits: min(rows ?? fits, max(1, cap)))
        if total == 0 {
            Text(empty).font(ink.ui(12)).foregroundStyle(ink.muted).frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(0..<fold.shown, id: \.self) { i in line(first: i == 0) { row(i) } }
                if fold.more > 0 { line(first: fold.shown == 0) { HomeMoreRow(count: fold.more, more: more) } }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(minHeight: CGFloat(rows == nil ? min(3, cap) : lines) * height, idealHeight: CGFloat(lines) * height,
                   maxHeight: CGFloat(lines) * height, alignment: .top)
            .onGeometryChange(for: Int.self, of: { HomeFold.fits(height: $0.size.height, row: height, least: 1) }) { fits = $0 }
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

/// This Mac's four readings as rows: CPU, memory, free disk and the temperature.
struct HomeMacRows: View {
    @Environment(\.ink) private var ink
    var fill = false

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
                ForEach(Array(readings.enumerated()), id: \.offset) { i, reading in
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
        }
    }
}
