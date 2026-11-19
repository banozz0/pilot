import PilotCore
import SwiftUI

// The window's shared parts: the pages row over a page that draws its own bar, the search's drop and the frame's rule.
// Toolbar tabs, the second window layout, went with the panel (pilot-ui-redesign T3): its strip is PanelTabBar now.

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
