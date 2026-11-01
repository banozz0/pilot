import PilotCore
import SwiftUI

/// The app window's frame in direction 2, toolbar tabs (window directions, Sven 2026-10-11, design 6D3E1T482hjVZaUkgMvvDb),
/// one frame for both styles: Home, the seven areas and Pilot as big tabs across the top, the Hyper key's cap and the
/// search beside them; under it the area's pages and the open page's parts as a row of tabs (Instrument's toolbar,
/// Toybox's page header, or the pages row over a page that draws its own bar); the page takes the whole width. Where the
/// tabs do not fit whole they drop their names. What the search finds drops down under it.
struct TabsFrame<Page: View>: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    @ViewBuilder var page: Page
    @State private var narrow = false

    var body: some View {
        let toy = style.kind == .toybox
        let owns = toy ? ToyLayout.ownsTitleRow(model.page, section: model.section(of: model.page))
            : InstrumentFrame.pageOwnsBar(model.page, section: model.section(of: model.page))
        VStack(spacing: 0) {
            AreaStrip(model: model, narrow: narrow).frame(height: AreaStrip.height(style.kind)).background(style.color(\.sidebar))
            WindowRule()
            Group {
                if owns { WindowPagesRow(model: model) }
                else if toy { ToyPageHeader(model: model, listed: false) }
                else { InstrumentToolbar(model: model, listed: false); InstrumentRule() }
            }
            .background(toy ? style.color(\.canvas) : Theme.windowFill(style.color(\.canvas)))
            page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(toy ? style.color(\.canvas) : Theme.windowFill(style.color(\.canvas)))
        }
        .overlay(alignment: .topTrailing) {
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                WindowSearchDrop(model: model).padding(.top, AreaStrip.height(style.kind) - 4).padding(.trailing, 16)
            }
        }
        .onGeometryChange(for: Bool.self) { RailLayout.narrow($0.size.width) } action: { narrow = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WindowShape.tabs.title)
    }
}

/// The strip of big tabs: the traffic lights' inset and the Hyper key's cap, the areas between it and the search, which
/// sits at the end. The areas never run under the search (the ten of P37 did at 760 pt): where they do not fit named, the
/// symbols alone, closer.
struct AreaStrip: View {
    @Environment(\.style) private var style
    let model: AppWindowModel
    /// A window under 900 pt: the search narrows.
    let narrow: Bool

    static func height(_ kind: PilotStyle) -> CGFloat { kind == .toybox ? 80 : 66 }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 72, height: 1)   // the traffic lights sit here
            if style.kind == .toybox { ToyHyperChip(rail: true).scaleEffect(0.86) } else { InstrumentHyperCap().scaleEffect(0.82) }
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) { areas(named: true); areas(named: false) }
                .accessibilityElement(children: .contain).accessibilityLabel("Areas")
            Spacer(minLength: 0)
            Group {
                if style.kind == .toybox { ToySearchField(model: model, focusOnRequest: true) } else { InstrumentSearchField(model: model) }
            }
            .frame(width: narrow ? 120 : 210)
        }
        .padding(.trailing, 16)
    }

    private func areas(named: Bool) -> some View {
        HStack(spacing: named ? 4 : 2) { ForEach(AppArea.allCases, id: \.self) { item($0, named: named) } }.fixedSize()
    }

    private func item(_ area: AppArea, named: Bool) -> some View {
        let on = model.page.area == area
        return Button { model.go(AppPlace(area.pages[0])) } label: {
            VStack(spacing: 4) {
                if style.kind == .toybox {
                    ToyTile(symbol: area.symbol, color: Toy.pageTile(area.pages[0], style), size: 34)
                        .padding(3)
                        .overlay { if on { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style.color(\.accent), lineWidth: 3) } }
                    if named { Text(area.title).font(style.toyNunito(800, 11)).foregroundStyle(style.color(on ? \.text : \.text2)) }
                } else {
                    Image(systemName: area.symbol).font(style.font(\.icon)).frame(height: 18)
                    if named { Text(area.title).styleText(\.caption) }
                }
            }
            .lineLimit(1)
            .foregroundStyle(style.color(on ? \.text : \.text3))
            .frame(width: named ? 68 : 40, height: style.kind == .toybox ? nil : 50)
            .background { if on && style.kind != .toybox { shape.fill(style.color(\.raised)) } }
            .overlay { if on && style.kind != .toybox { shape.strokeBorder(style.color(\.line)) } }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help("\(area.title)  ⌘\(area.key)")
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous) }
}

/// The area's pages and the open page's parts as tabs, over a page that draws its own bar (Binds): the tabs' second row,
/// the rail's when its list folds away. Nothing for a lone page without parts.
struct WindowPagesRow: View {
    @Environment(\.style) private var style
    let model: AppWindowModel

    var body: some View {
        if WindowPageTabs.shows(model) {
            if style.kind == .toybox {
                HStack(spacing: 0) { WindowPageTabs(model: model); Spacer(minLength: 0) }.padding(.horizontal, Toy.gutter).padding(.top, 18)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { WindowPageTabs(model: model); Spacer(minLength: 0) }
                        .padding(.horizontal, style.density.page).frame(height: style.points(44))
                    InstrumentRule()
                }
            }
        }
    }
}

/// The area's pages, then the open page's parts, each as the style's segmented tabs.
struct WindowPageTabs: View {
    @Environment(\.style) private var style
    let model: AppWindowModel

    static func shows(_ model: AppWindowModel) -> Bool { model.page.area.shown.count > 1 || !model.tabs.isEmpty }

    var body: some View {
        let page = model.page
        let pages = page.area.shown.count > 1 ? page.area.shown.map { (value: $0, title: $0.title) } : []
        let tabs = model.tabs
        let pick = Binding(get: { model.page }, set: { model.go(AppPlace($0)) })
        let part = Binding(get: { model.section(of: page) }, set: { model.sections[page] = $0 })
        HStack(spacing: 12) {
            if style.kind == .toybox {
                if !pages.isEmpty { ToySegments(selection: pick, options: pages, label: "\(page.area.title) pages") }
                if !tabs.isEmpty { ToySegments(selection: part, options: tabs, label: "\(page.title) parts") }
            } else {
                if !pages.isEmpty { InstrumentSegments(options: pages, selection: pick).fixedSize().accessibilityLabel("\(page.area.title) pages") }
                if !tabs.isEmpty { InstrumentSegments(options: tabs, selection: part).fixedSize().accessibilityLabel("\(page.title) parts") }
            }
        }
    }
}

/// What the search finds, dropped down under the field in a card over the page.
struct WindowSearchDrop: View {
    @Environment(\.style) private var style
    let model: AppWindowModel

    var body: some View {
        ScrollView {
            Group {
                if style.kind == .toybox { ToySearchResults(model: model) { model.query = "" } } else { InstrumentSearchResults(model: model) }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .frame(width: 340).frame(maxHeight: 420).fixedSize(horizontal: false, vertical: true)
        .background {
            if style.kind == .toybox { Toy.block(style, fill: style.color(\.panel), radius: 16, edge: 4) }
            else {
                RoundedRectangle(cornerRadius: style.radii.control + 4, style: .continuous).fill(style.color(\.panel))
                    .overlay { RoundedRectangle(cornerRadius: style.radii.control + 4, style: .continuous).strokeBorder(style.color(\.line)) }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Search results")
    }
}

/// The frame's rule between its chrome and the page: Instrument's hairline, Toybox's 2 pt ink line.
struct WindowRule: View {
    @Environment(\.style) private var style
    var body: some View {
        if style.kind == .toybox { style.color(\.outline).frame(height: 2) } else { InstrumentRule() }
    }
}
