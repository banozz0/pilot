import PilotCore
import SwiftUI

// The Kit's Instrument branches for a settings page (card agent-bo-95423181, batch 4; ADR 0008): the page's column level
// with the toolbar's inset, a panel with its title on a 44 pt header over a hairline, a heading over a group, a glyph on
// a raised tile, the on/off card, a block's title and the notice row. The Kit's parts (KitPage, PageBody, Tile, KitBlock,
// CalmHeading, SwitchCard) call these when the surface draws in Instrument.

/// A page's column under the frame's toolbar: its intro line, then the blocks `spacing` apart, 28 pt in at each side as
/// the toolbar's title.
struct InstrumentPage<Content: View>: View {
    @Environment(\.style) private var style
    /// False on a More tab: its blocks keep their rows one under the other.
    @Environment(\.blockRowColumns) private var rowColumns
    var intro: String?
    /// The intro's ⓘ: what its one line leaves out.
    var info: String?
    var spacing: CGFloat = 0
    /// The blocks in columns once the page is wide (PageFlow); else one stack.
    var flow = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                if let intro {
                    IntroLine(info: info) {
                        Text(intro).styleText(\.body).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A block a turn while the part is built ahead (Staged); PageFlow told how many there will be, so the
                // blocks drawn first already stand where they will once the rest arrive.
                if flow {
                    Group(subviews: content) { blocks in
                        PageFlow(column: KitPage<EmptyView>.column(.instrument), gap: style.density.padding, spacing: spacing, total: blocks.count) {
                            // Only the page's own flowing blocks may stand their rows in columns (BlockRowColumns).
                            Staged {
                                ForEach(blocks) { block in
                                    block.environment(\.blockRowColumns, rowColumns != false && block.containerValues.pageFlows && !block.containerValues.pageWide)
                                }
                            }
                        }
                    }
                } else {
                    Staged { content }
                }
            }
            .padding(.horizontal, style.density.page).padding(.top, style.density.padding).padding(.bottom, style.density.page)
            // Home's measure in a big window, centred (wide-pages).
            .pageMeasure(side: style.density.page)
        }
        // What a part leaves to the page (a row's title, a field's words, a system control's tint) in the style, not the
        // theme pilotTheme() put at the window's root; the tint quiet, since the signal colour means Hyper.
        .foregroundStyle(style.color(\.text))
        .font(style.font(\.body))
        .tint(style.color(\.text2))
    }
}

/// A page's blocks top to bottom, built as they scroll into view: only the ones on screen as the page opens (page-perf).
/// Once a link, the search, a ring or the page itself (`asked`) wants a block or a row this visit, it is built whole from
/// then on, as a lazy stack cannot scroll to what it has not built yet.
struct PageStack<Content: View>: View {
    @Environment(\.blockLanding) private var landing
    @Environment(\.landingRing) private var ring
    var spacing: CGFloat = 0
    /// The page's own wish to scroll to a block (Look's section).
    var asked = false
    @ViewBuilder var content: Content
    /// Set in the pass that first sees the wish, so no later pass, once the landing is cleared, goes lazy again.
    @State private var whole = Whole()
    final class Whole { var yes = false }

    var body: some View {
        if asked || landing?.place != nil || ring != nil { whole.yes = true }
        return Group {
            if whole.yes {
                VStack(alignment: .leading, spacing: spacing) { Staged { content } }
            } else {
                // A block a pass in a part built a piece at a time (Staged), so a first visit draws its top first
                // (page-frames: Look's first visit was one 100 to 130 ms frame).
                LazyVStack(alignment: .leading, spacing: spacing) { Staged { content } }
            }
        }
    }
}

/// A block: InstrumentPanel (its glyph, title and what sits at its right on a 44 pt header over a hairline), its note,
/// then its content inset as the header; without a title, the content alone on the panel.
struct InstrumentBlock<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    var title: String?
    var symbol: String?
    var note: String?
    /// Takes the height its row gives it, so blocks side by side end level.
    var fill = false
    /// Whether it builds its content a row a turn (Staged); KitBlock's BlockRowColumns does that itself.
    var staged = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        if let title {
            InstrumentPanel(title: title, symbol: symbol, stretch: fill) {
                trailing.font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
            } content: { inner }
        } else {
            inner.frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading).styleSurface(\.card)
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            // A row a turn while the part is built ahead (Staged); in view the block comes whole, so it never grows under
            // what is drawn beside and below it. Rows stand in columns once the block is wide (wide-pages).
            if staged { Staged(inView: false) { content } } else { content }
        }
        .padding(.horizontal, style.density.padding).padding(.vertical, InstrumentKitPage.blockPadding)
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
    }
}

/// A KitBlock's children: a block of rows (every child a BlockRow, two or more) stands them in columns once it is wide
/// enough for two rows side by side, each as wide as a page column's row (wide-pages: Update beside Clean, Open with's
/// ten Apps for keys in three columns in a big window); the columns draw the rules, none over a column's top row. Only on
/// a page's own flowing block (`blockRowColumns`). Any other block draws the children KitBlock read, a row a turn while
/// the part is built ahead (Staged), so its rows are built once, as before; a block in columns builds them again told
/// to draw no rule of their own, as a row keeps the environment it was first read in.
struct BlockRowColumns<Content: View>: View {
    @Environment(\.style) private var style
    @Environment(\.blockRowColumns) private var on
    /// The block's children as KitBlock read them, and what each is (BlockRow's container value).
    let children: SubviewsCollection
    let kinds: [BlockRowKind?]
    @ViewBuilder var content: Content

    var body: some View {
        if on == true, let count = Self.rows(kinds) {
            RowColumns(least: KitPage<EmptyView>.column(.instrument) - style.density.padding * 2, gap: style.density.padding * 2,
                       firsts: kinds.map { $0 == .first }) {
                Staged(inView: false) { content.environment(\.blockRowRule, false) }
                ForEach(0..<count, id: \.self) { _ in InstrumentRule() }
            }
        } else {
            Staged(inView: false) { ForEach(children) { $0 } }
        }
    }

    /// How many rows a block holds when every child is one and there are two or more; nil for any other block.
    static func rows(_ kinds: [BlockRowKind?]) -> Int? {
        kinds.count >= 2 && kinds.allSatisfy { $0 != nil } ? kinds.count : nil
    }
}

/// BlockRowColumns' rows in as many columns as fit at `least` wide and they fill, top to bottom then the next column,
/// split so the tallest column is as short as it can be; then a rule over each row but a column's top one (and the
/// first row, as BlockRow's `first`). Its subviews are the rows built so far (all but while staged), then one rule for
/// each of the block's rows.
struct RowColumns: Layout {
    var least: CGFloat
    var gap: CGFloat
    /// Each row's `first`: no rule over it.
    var firsts: [Bool]

    /// The rows' frames at the width they were last laid at: a block is asked its size, then placed, at one width, and
    /// each row is measured once for both (a first visit's cost, page-first).
    struct Cache { var width: CGFloat = -1; var frames: [CGRect] = [] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func frames(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [CGRect] {
        if cache.width != width { cache = Cache(width: width, frames: arrange(width, subviews)) }
        return cache.frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? least
        let frames = frames(width, subviews, &cache)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    /// The rows built so far: the subviews before the rules.
    private func built(_ subviews: Subviews) -> Int { max(0, min(firsts.count, subviews.count - firsts.count)) }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = built(subviews), rules = subviews.count - firsts.count
        let frames = frames(bounds.width, subviews, &cache)
        for (i, frame) in frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
        // The rules: over a row unless it is first or tops a column; none for a row not built yet.
        for i in 0..<firsts.count where rules + i < subviews.count {
            let frame = i < rows ? frames[i] : .zero
            let shown = i < rows && !firsts[i] && !(frame.minY == 0 && frame.minX > 0)
            subviews[rules + i].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                      proposal: ProposedViewSize(width: shown ? frame.width : 0, height: 1))
        }
    }

    /// The rows' frames: their columns' count from the width, then the split.
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        let rows = built(subviews)
        guard rows > 0 else { return [] }
        let columns = max(1, min(rows, Int((width + gap) / (least + gap))))
        let side = columns == 1 ? width : (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let heights = (0..<rows).map { subviews[$0].sizeThatFits(ProposedViewSize(width: side, height: nil)).height }
        let starts = Self.split(heights, columns: columns)
        var frames: [CGRect] = []
        for (c, start) in starts.enumerated() {
            let end = c + 1 < starts.count ? starts[c + 1] : rows
            var y: CGFloat = 0
            for i in start..<end {
                frames.append(CGRect(x: CGFloat(c) * (side + gap), y: y, width: side, height: heights[i]))
                y += heights[i]
            }
        }
        return frames
    }

    /// Where each column starts: the rows in order, cut into at most `columns` runs whose tallest is the shortest it can
    /// be (the least height every run fits under, found by halving), each run then ending nearest its even share of
    /// what is left, so ten like rows stand 4, 3, 3 rather than 4, 4, 2.
    static func split(_ heights: [CGFloat], columns: Int) -> [Int] {
        func cuts(under most: CGFloat, from start: Int = 0) -> [Int] {
            var starts = [start], sum: CGFloat = 0
            for i in start..<heights.count {
                if sum + heights[i] > most && sum > 0 { starts.append(i); sum = 0 }
                sum += heights[i]
            }
            return starts
        }
        var low = heights.max() ?? 0, high = heights.reduce(0, +)
        for _ in 0..<24 where high - low > 0.5 {
            let mid = (low + high) / 2
            if cuts(under: mid).count <= columns { high = mid } else { low = mid }
        }
        var starts = [0], i = 0
        for c in 0..<max(0, columns - 1) {
            let rest = heights[i...].reduce(0, +), share = rest / CGFloat(columns - c)
            var sum: CGFloat = 0
            while i < heights.count, sum + heights[i] <= high,
                  sum == 0 || abs(sum + heights[i] - share) <= abs(sum - share) || cuts(under: high, from: i).count > columns - c - 1 {
                sum += heights[i]
                i += 1
            }
            guard i < heights.count else { break }
            starts.append(i)
        }
        return starts
    }
}

/// A heading over a group of blocks: the panel title's face, its note quiet under it.
struct InstrumentHeading<Trailing: View>: View {
    @Environment(\.style) private var style
    let title: String
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                Spacer()
                trailing.font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
            }
            if let note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.top, 22).padding(.bottom, 10)
    }
}

/// A block's title beside its glyph, with a quiet note: Stats' blocks and the Menu bar page's Readings.
struct InstrumentTitle: View {
    @Environment(\.style) private var style
    let title: String
    let symbol: String
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(\.text3))
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
            if let note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .lineLimit(1).fixedSize()
        .frame(minHeight: InstrumentKitPage.titleHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A page's on/off card (the Menu bar page's top bar): its glyph, whether it is on as the title, what it does, and the
/// switch's button.
struct InstrumentSwitchCard: View {
    @Environment(\.style) private var style
    let symbol: String
    let title: String
    let isOn: Bool
    let busy: Bool
    let detail: String
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            InstrumentAppIcon(bundle: nil, symbol: symbol, size: InstrumentKitPage.tile)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
                Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(isOn ? "Switch off" : "Switch on", action: toggle).buttonStyle(InstrumentButtonStyle()).disabled(busy)
        }
        .padding(style.density.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .styleSurface(\.card)
    }
}

/// The page parts' measures.
enum InstrumentKitPage {
    /// A notice row's least height (a panel header's), a block's inset above and below its content, a title's least
    /// height, and a big glyph tile.
    static let header: CGFloat = 44, blockPadding: CGFloat = 14, titleHeight: CGFloat = 24, tile: CGFloat = 30
    /// The least column width two blocks share a row at (Setup's two columns').
    static let pairWidth: CGFloat = 880
}

/// Two blocks side by side once the page is `InstrumentKitPage.pairWidth` wide, ending level (a block with `fill` takes
/// the row's height); one over the other narrower (card agent-bo-95423181, batch 6: no page a column of half-empty rows).
/// `level` false lays two columns that each keep their own height, for blocks too unlike to share rows.
struct InstrumentPair<Left: View, Right: View>: View {
    @Environment(\.style) private var style
    var level = true
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @State private var wide = true

    var body: some View {
        // One layout that switches, so the columns keep their identity as the page crosses the width.
        let side = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: style.density.padding)) : AnyLayout(VStackLayout(spacing: 0))
        let stretch = level && wide
        // Level, each column takes the row's height (the pair is as tall as the taller); else each keeps its own, so a
        // block with `fill` does not stretch to the other column's foot.
        side {
            VStack(spacing: 0) { left }.fixedSize(horizontal: false, vertical: !level)
                .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .top)
            VStack(spacing: 0) { right }.fixedSize(horizontal: false, vertical: !level)
                .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: stretch)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width >= InstrumentKitPage.pairWidth } action: { wide = $0 }
    }
}

extension View {
    /// A notice row (Home's problems, the Menu bar page's hidden items): its eyebrow, line and fix inset on the panel
    /// colour under a hairline, the signal's 2 pt tick at its left edge, the card's corner.
    func instrumentNotice() -> some View { modifier(InstrumentNoticeFace()) }
}

private struct InstrumentNoticeFace: ViewModifier {
    @Environment(\.style) private var style

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        content
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .frame(minHeight: InstrumentKitPage.header)
            .background(style.color(\.panel), in: shape)
            .overlay(alignment: .leading) { style.color(\.accent).frame(width: 2) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
    }
}

/// The Kit's slider in Instrument: InstrumentMeter's track and share (the signal is Hyper's), a knob on its ring; `x` is
/// the value's place along the track `width` long.
struct InstrumentSliderFace: View {
    @Environment(\.style) private var style
    let x: CGFloat
    let width: CGFloat

    var body: some View {
        InstrumentMeter(share: x / width)
        Circle().fill(style.color(\.knob)).frame(width: 14, height: 14)
            .overlay { Circle().strokeBorder(style.color(\.line2)) }
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .offset(x: x - 7)
    }
}

/// Nothing yet, in Instrument: what is missing in the title face, the line that fixes it quiet under it with its keys,
/// and the one action as the inverse button; no picture, as mockup A decorates nothing.
struct InstrumentEmpty: View {
    @Environment(\.style) private var style
    let title: String
    var line: String?
    var keys: [String] = []
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
            if line != nil || !keys.isEmpty {
                HStack(spacing: 5) {
                    ForEach(keys, id: \.self) { Kbd(text: $0) }
                    if let line { Text(line).styleText(\.body).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if let action { Button(action.title, action: action.run).buttonStyle(InstrumentButtonStyle(kind: .primary)).padding(.top, 7) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
