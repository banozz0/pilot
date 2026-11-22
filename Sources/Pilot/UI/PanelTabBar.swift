import PilotCore
import SwiftUI

/// The panel's tab bar (pilot-ui-redesign T3, round 2's shot 7c): the traffic lights' inset, then `tabOrder`'s areas as
/// named tabs, an icon over each name, and More last; the window's search, then the Hyper key's cap at the right. A name never drops or shrinks
/// (S3 A's rule): the count follows the window's width (ADR 0018, Sven 2026-11-20), every area that fits a tab in the
/// fixed order, the rest in More, and no More once all fit; More is sized for the widest name it can take. Each tab is
/// measured in place, off screen, so the count is the drawn names' own. The open tab is raised with a hairline and no
/// accent, so the ring and the switches stay the one accent signal. An area opened from More names the More tab, so the
/// bar always says where you are.
struct PanelTabBar: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let more: PanelMore
    /// The area marked open: the part's own, as each kept part draws its own bar, so a switch's first frame shows the new
    /// mark with the new page (page-frame).
    let open: AppArea

    static let height: CGFloat = 64
    /// The traffic lights' inset at the left, as drawn.
    static let lights: CGFloat = 92
    /// The search field's width, as drawn, and the gap before it.
    static let search: CGFloat = 180, searchGap: CGFloat = 12
    /// Room the tabs have: the panel's width less the lights, the search, the Hyper cap (28 pt and 12 pt before it) and
    /// the 14 pt edge.
    static func room(_ width: CGFloat) -> CGFloat { width - lights - searchGap - search - 28 - 12 - 14 }
    /// The search field's right edge from the window's: the Hyper cap, its gap and the edge.
    static let searchTrailing: CGFloat = 14 + 28 + 12

    var body: some View {
        // As many tabs as the window's bar measured (PanelTabTop).
        let split = AppArea.tabs(count: more.tabs, developer: DeveloperPages.on)
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.lights, height: 1)
            Spacer(minLength: 0)
            PanelTabStrip(tabs: split.tabs, open: open, moreTitle: split.more.contains(open) ? open.title : "More",
                          moreOn: split.more.contains(open) || more.open, moreShown: !split.more.isEmpty,
                          pick: { model.go(AppPlace($0.pages[0])) }, toggleMore: { more.open.toggle() })
            Spacer(minLength: 0)
            // The window's search and the Hyper cap go here, the window's own over every part's bar (PanelTabTop).
            Color.clear.frame(width: Self.search + 12 + 28, height: 1).padding(.leading, Self.searchGap)
        }
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(style.color(\.sidebar))
        .overlay(alignment: .bottom) { InstrumentRule() }
    }
}

/// What the tab bar holds that is the same on every page, drawn by the window over each part's bar (PanelTabBar): the
/// window's search, the Hyper key's cap, and the tabs' count. The count follows the window's width (ADR 0018, Sven
/// 2026-11-20), every area that fits a tab in the fixed order, the rest in More; each tab is measured in place, off screen,
/// so the count is the drawn names' own. Kept in the window, so the search keeps its words and the keyboard across switches.
struct PanelTabTop: View {
    @Bindable var model: AppWindowModel
    let more: PanelMore
    /// The bar's width and each label's, as drawn (PanelTabMeasures).
    @State private var width: CGFloat = 0
    @State private var widths = PanelTabWidths()

    var body: some View {
        let shown = AppArea.tabs(count: .max, developer: DeveloperPages.on).tabs
        let split = AppArea.tabs(count: count(shown), developer: DeveloperPages.on)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            // The window's search on every page (Sven, 2026-11-21): Home's own search, its words and results. Cmd+F
            // focuses it on every page but Home, whose larger field takes it.
            InstrumentSearchField(model: model, takesKey: model.page != .home).frame(width: PanelTabBar.search)
            InstrumentHyperCap(side: 28).padding(.leading, 12)
        }
        .padding(.trailing, 14)
        .frame(height: PanelTabBar.height)
        // The window's width, not the strip's: a strip too wide for it would overflow and read as room.
        .frame(minWidth: 0, maxWidth: .infinity)
        .background { PanelTabMeasures(shown: shown, widths: widths) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: split.tabs.count, initial: true) { _, count in
            PanelTabs.count = count; more.tabs = count
            if split.more.isEmpty { more.open = false }
        }
    }

    /// The tabs that fit the bar now; `AppArea.tabCount` until every label is measured.
    private func count(_ shown: [AppArea]) -> Int {
        let tabWidths = self.widths.tabs, moreWidths = self.widths.more
        let widths = shown.compactMap { tabWidths[$0] }, titles = ["More"] + shown.map(\.title)
        guard width > 0, widths.count == shown.count, titles.allSatisfy({ moreWidths[$0] != nil }) else { return AppArea.tabCount }
        // More holding areas i... is as wide as the widest name among them, or "More".
        let more = shown.indices.map { i in shown[i...].map { moreWidths[$0.title] ?? 0 }.max().map { max($0, moreWidths["More"] ?? 0) } ?? 0 }
        return AppArea.tabsThatFit(widths: widths.map(Double.init), more: more.map(Double.init), spacing: PanelTabStrip.spacing,
                                   room: Double(PanelTabBar.room(width)))
    }
}

/// Each tab's label and each More name's, as drawn: a tab's by its area, More's by the name it carries.
@MainActor @Observable final class PanelTabWidths {
    var tabs: [AppArea: CGFloat] = [:]
    var more: [String: CGFloat] = [:]
}

/// Every tab and every More name the bar could draw, each alone, hidden: what the bar's count reads. A view of its own
/// whose inputs are the areas alone, never the page open, so a page switch, which redraws the bar, leaves these strips
/// as they are (page-switch-4).
private struct PanelTabMeasures: View {
    let shown: [AppArea]
    let widths: PanelTabWidths

    var body: some View {
        ZStack {
            ForEach(shown, id: \.self) { area in
                PanelTabStrip(tabs: [area], open: area, moreTitle: "", moreOn: false, moreShown: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.tabs[area] = $0 }
            }
            ForEach(["More"] + shown.map(\.title), id: \.self) { title in
                PanelTabStrip(tabs: [], open: .home, moreTitle: title, moreOn: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.more[title] = $0 }
            }
        }
        .hidden().accessibilityHidden(true)
    }
}

/// How many tabs the panel's bar shows now, for the readers away from it: the search's tab paths and `pilot open
/// --where`. `AppArea.tabCount` until a bar is measured.
@MainActor enum PanelTabs {
    static var count = AppArea.tabCount
}

/// The tabs themselves, apart from the bar so a render can measure their width at any count.
struct PanelTabStrip: View {
    @Environment(\.style) private var style
    let tabs: [AppArea]
    let open: AppArea
    /// "More", or the name of the area opened from it.
    let moreTitle: String
    let moreOn: Bool
    var moreShown = true
    var pick: (AppArea) -> Void = { _ in }
    var toggleMore: () -> Void = {}

    /// The gap between two tabs, and before More.
    static let spacing = 2.0

    var body: some View {
        // Three tabs a turn while the part is built ahead (Staged); in view all at once, as each added would move the rest.
        HStack(spacing: Self.spacing) { Staged(by: 3, inView: false) {
            ForEach(tabs, id: \.self) { area in
                Button { pick(area) } label: { label(symbol: area.symbol, on: area == open) { Text(area.title) } }
                    .buttonStyle(.kitPress)
                    .help("\(area.title)  \(area.keyHint)")
                    .accessibilityLabel(area.title)
                    .accessibilityAddTraits(area == open ? .isSelected : [])
            }
            if moreShown {
                Button(action: toggleMore) {
                    label(symbol: "square.grid.2x2", on: moreOn) {
                        HStack(spacing: 2) {
                            Text(moreTitle)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.kitPress)
                .help("More areas")
                .accessibilityLabel(moreTitle == "More" ? "More" : "More, \(moreTitle) open")
                .accessibilityAddTraits(moreOn ? .isSelected : [])
            }
        } }
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel("Tabs")
    }

    private func label<Name: View>(symbol: String, on: Bool, @ViewBuilder name: () -> Name) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous)
        return VStack(spacing: 3) {
            Image(systemName: symbol).font(style.font(\.icon)).frame(height: 18)
            name().styleText(\.caption).lineLimit(1).fixedSize()
        }
        .foregroundStyle(style.color(on ? \.text : \.text3))
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(minWidth: 54)
        .background { if on { shape.fill(style.color(\.raised)) } }
        .overlay { if on { shape.strokeBorder(style.color(\.line)) } }
        .contentShape(shape)
    }
}

/// Whether More's card is open: the panel's own state, which a render can open.
@Observable final class PanelMore {
    var open = false
    /// How many tabs the bar shows now (PanelTabs.count), so the card lists the rest.
    var tabs = AppArea.tabCount
    init(open: Bool = false) { self.open = open }
}

/// More's card, under the More tab over the page: each area that is not a tab with its pages and its key, the open one
/// raised. Picking one opens its first page and closes the card; Esc or a click beside it closes it.
struct PanelMoreMenu: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let more: PanelMore
    @FocusState private var focused: Bool

    var body: some View {
        let areas = AppArea.tabs(count: more.tabs, developer: DeveloperPages.on).more
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(areas, id: \.self) { row($0) }
            Text("The area you open takes this tab's name.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { InstrumentRule().padding(.horizontal, 4) }
                .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 350)
        .background(style.color(\.panel), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.escape) { more.open = false; return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain).accessibilityLabel("More areas")
    }

    private func row(_ area: AppArea) -> some View {
        let on = model.page.area == area
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        return Button { more.open = false; model.go(AppPlace(area.pages[0])) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(area.title).styleText(\.strong).foregroundStyle(style.color(\.text))
                    if let pages = Self.pages(area) { Text(pages).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if !area.keyHint.isEmpty { Text(area.keyHint).styleText(\.key).foregroundStyle(style.color(\.text3)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if on { shape.fill(style.color(\.raised)) } }
            .overlay { if on { shape.strokeBorder(style.color(\.line2)) } }
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .help(area.keyHint.isEmpty ? area.title : "\(area.title)  \(area.keyHint)")
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What an area holds, under its name: its pages, or a lone page's parts ("Chat · Setup"); nil when it is one plain page.
    @MainActor static func pages(_ area: AppArea) -> String? {
        let pages = area.shown
        if pages.count > 1 || pages.first?.title != area.title { return pages.map(\.title).joined(separator: " · ") }
        let parts = pages.first?.tabs.map(\.title) ?? []
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
