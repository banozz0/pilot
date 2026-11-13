import Observation
import PilotCore
import SwiftUI

/// A page's More tab (simplify-pages T7, Sven's Q60 B; the designer's MoreTabRenders): the blocks its front leaves out,
/// stacked as KitPage stacks them, with an index of them beside while there are two or more and room for it. The index names each block
/// and how many controls it holds, marks the one in view as the page scrolls, and scrolls to one on a click; a link or a
/// search that lands on a block (the window's `blockLanding`) scrolls there and marks it. Each block is tagged with
/// `.moreBlock(_:)` under its place.
struct KitMore<Content: View>: View {
    @Environment(\.blockLanding) private var landing
    let entries: [MoreEntry]
    /// The narrowest the blocks go beside the index: the page's widest row still on one line (Pilot's Hold Hyper needs
    /// 620; simplify-pages T7, coordinator 2026-11-10). Narrower, the index steps aside and the blocks take the column.
    var blocks: CGFloat = 620
    @ViewBuilder var content: Content

    @State private var spy = MoreSpy()
    /// Room for the index beside blocks at least `blocks` wide; narrower (the 760 pt window), the blocks take it all.
    @State private var roomy = true

    /// The index and its inset.
    static var index: CGFloat { 206 }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                if entries.count > 1 && roomy {
                    MoreIndex(entries: entries, picked: spy.picked ?? entries.first?.id) { id in
                        spy.hold(id)
                        withAnimation(Kit.change) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                KitPage { content }
                    .coordinateSpace(.named(MoreSpy.space))
                    .environment(\.moreSpy, spy)
            }
            .onGeometryChange(for: Bool.self) { $0.size.width - Self.index >= blocks } action: { roomy = $0 }
            .onChange(of: entries.map(\.id), initial: true) { spy.order = entries.map(\.id) }
            // A link or the search: straight there, its block marked.
            .lands(landing, proxy) { spy.hold($0) }
        }
    }
}

/// One block in a More tab's index: its place, glyph and control count (its rows, a heading not counted).
struct MoreEntry: Identifiable {
    let id: AppSection
    let symbol: String
    let controls: Int
    var title: String { id.title }
}

/// The block a link or the search asked for on a More tab or a front, and how to clear it once the page has landed there;
/// the window sets it for the page (AppWindowModel.blockFocus).
struct BlockLanding {
    let place: AppSection?
    let landed: () -> Void
}

/// A page's front that a link or the search lands on a block of (Sven, 2026-11-11, after 2276; `AppSection.onFront`):
/// wraps the front's scroll view and scrolls to the block tagged `.id(place)`, as KitMore lands on a More tab.
struct KitLanding<Content: View>: View {
    @Environment(\.blockLanding) private var landing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in content.lands(landing, proxy) }
    }
}

extension View {
    /// Scrolls `proxy` to the block `landing` asks for, `first` told before, then clears it: KitMore's and KitLanding's.
    func lands(_ landing: BlockLanding?, _ proxy: ScrollViewProxy, first: @escaping (AppSection) -> Void = { _ in }) -> some View {
        onChange(of: landing?.place, initial: true) {
            guard let landing, let place = landing.place else { return }
            first(place)
            proxy.scrollTo(place, anchor: .top)
            landing.landed()
        }
    }
}

extension EnvironmentValues {
    @Entry var blockLanding: BlockLanding? = nil
    @Entry var moreSpy: MoreSpy? = nil
}

extension View {
    /// A block on a More tab under `place`: the spot a link, the search and its index scroll to, and where the index
    /// learns which block is in view. More's blocks stay one stack (Q60): the modifier hides KitBlock's PageFlow mark, so
    /// two blocks never sit side by side and cross the spy's band together.
    func moreBlock(_ place: AppSection) -> some View { modifier(MoreBlockTag(place: place)) }
}

private struct MoreBlockTag: ViewModifier {
    @Environment(\.moreSpy) private var spy
    let place: AppSection

    func body(content: Content) -> some View {
        content.id(place)
            // Only when the block's top crosses the column's top band, not on every scrolled frame.
            .onGeometryChange(for: Bool.self) { $0.frame(in: .named(MoreSpy.space)).minY <= MoreSpy.band } action: { reached in
                spy?.crossed(place, reached: reached)
            }
    }
}

/// KitMore's scroll spy: the block in view is the last, in the page's order, whose top has reached the column's top band,
/// the first before any has. A landing or a click marks its block and holds the mark through the scroll it starts: a
/// block near the foot never reaches the top, so the spy alone would mark the one above it; the first crossing after
/// the scroll lets the spy mark again.
@MainActor @Observable final class MoreSpy {
    static let space = "kit.more"
    static let band: CGFloat = 80

    private(set) var picked: AppSection?
    @ObservationIgnored var order: [AppSection] = []
    @ObservationIgnored private var reached: Set<AppSection> = []
    @ObservationIgnored private var heldUntil: ContinuousClock.Instant?

    func hold(_ place: AppSection) {
        picked = place
        heldUntil = .now + .milliseconds(400)
    }

    func crossed(_ place: AppSection, reached now: Bool) {
        if now { reached.insert(place) } else { reached.remove(place) }
        if let until = heldUntil {
            guard ContinuousClock.now >= until else { return }
            heldUntil = nil
        }
        let shown = order.last(where: reached.contains) ?? order.first
        if shown != picked { picked = shown }
    }
}

/// The index: "On More", then each block's name and control count, the one in view marked as the style marks a pick:
/// Instrument's glyph and raised surface, Toybox's selected-tab fill and no glyphs. 184 pt wide, level with the blocks.
private struct MoreIndex: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let entries: [MoreEntry]
    let picked: AppSection?
    let pick: (AppSection) -> Void

    var body: some View {
        let toy = style.kind == .toybox
        VStack(alignment: .leading, spacing: toy ? 4 : 2) {
            Text("On More").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(entries) { entry in
                let on = entry.id == picked
                Button { pick(entry.id) } label: {
                    HStack(spacing: 8) {
                        if !toy { Image(systemName: entry.symbol).font(style.font(\.icon)).frame(width: 18) }
                        Text(entry.title).font(toy ? style.toyNunito(800, 13.5) : nil).styleText(on ? \.strong : \.body).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(entry.controls)").font(ink.mono(11)).foregroundStyle(on && toy ? style.color(\.onInverse) : style.color(\.text3))
                    }
                    .foregroundStyle(on ? (toy ? style.color(\.onInverse) : style.color(\.text)) : style.color(\.text2))
                    .padding(.horizontal, 10).frame(height: style.points(toy ? 34 : 30))
                    .background {
                        if on {
                            if toy { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style.color(\.inverse)) }
                            else { Color.clear.instrumentRaised(true, fill: \.panel, radius: style.radii.control) }
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.title), \(entry.controls) controls")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(width: 184, alignment: .leading)
        .padding(.leading, toy ? Toy.gutter - 6 : style.density.page - 6)
        .padding(.top, toy ? Toy.blockGap + 6 : style.density.padding + 12)
        .accessibilityElement(children: .contain).accessibilityLabel("On More")
    }
}
