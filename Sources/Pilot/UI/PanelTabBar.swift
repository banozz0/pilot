import PilotCore
import SwiftUI

/// The panel's tab bar (pilot-ui-redesign T3, round 2's shot 7c): the traffic lights' inset, then the first
/// `AppArea.tabCount` areas of `AppArea.tabOrder` as named tabs, an icon over each name, and More last; the Hyper key's cap at
/// the right. A name never drops or shrinks (S3 A's rule): the count is what fits 780 pt with every name on one line, the
/// More tab carrying its widest name (WindowRailRenders measures it). The open tab is raised with a hairline and no accent,
/// so the ring and the switches stay the one accent signal. An area opened from More names the More tab, so the bar always
/// says where you are.
struct PanelTabBar: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let more: PanelMore

    static let height: CGFloat = 64
    /// The traffic lights' inset at the left, as drawn.
    static let lights: CGFloat = 92
    /// Room the tabs have: the panel's width less the lights, the Hyper cap (28 pt and 12 pt before it) and the 14 pt edge.
    static func room(_ width: CGFloat) -> CGFloat { width - lights - 28 - 12 - 14 }

    var body: some View {
        let split = AppArea.tabs(developer: DeveloperPages.on), open = model.page.area
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.lights, height: 1)
            Spacer(minLength: 0)
            PanelTabStrip(tabs: split.tabs, open: open, moreTitle: split.more.contains(open) ? open.title : "More",
                          moreOn: split.more.contains(open) || more.open, moreShown: !split.more.isEmpty,
                          pick: { model.go(AppPlace($0.pages[0])) }, toggleMore: { more.open.toggle() })
            Spacer(minLength: 0)
            InstrumentHyperCap(side: 28).padding(.leading, 12)
        }
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .background(style.color(\.sidebar))
        .overlay(alignment: .bottom) { InstrumentRule() }
    }
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

    var body: some View {
        HStack(spacing: 2) {
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
        }
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
        let areas = AppArea.tabs(developer: DeveloperPages.on).more
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
