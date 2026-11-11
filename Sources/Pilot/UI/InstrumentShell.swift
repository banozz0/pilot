import AppKit
import PilotCore
import SwiftUI

/// The app window's frame in Instrument, direction 1 (window directions, Sven 2026-10-11, design 6D3E1T482hjVZaUkgMvvDb):
/// a 72 pt rail of the areas with Pilot and the Hyper key at its foot; beside it the area's pages, one row each with its
/// state, the search over them; over the page a toolbar with its name and its parts as tabs (Home adds the date, the
/// Hyper switch and Open menu). Home takes the whole width. A window under 900 pt folds the list away and the toolbar
/// carries the area's pages too (RailLayout). Binds draws its own bar (InstrumentBindsPage).
struct InstrumentFrame: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    /// The window's width, measured: kept to the widths the rules tell apart, so only crossing a line redraws the frame.
    @State private var width: Double = 1440

    var body: some View {
        let list = RailLayout.showsList(model.page, width: width, searching: model.searchOpen)
        HStack(spacing: 0) {
            InstrumentRail(model: model).frame(width: 72).background(style.color(\.sidebar))
            InstrumentRule(vertical: true)
            if list {
                InstrumentPageList(model: model).frame(width: RailLayout.listWidth(width)).background(style.color(\.sidebar))
                InstrumentRule(vertical: true)
            }
            VStack(spacing: 0) {
                if !Self.pageOwnsBar(model.page, section: model.section(of: model.page)) {
                    InstrumentToolbar(model: model, listed: list)
                    InstrumentRule()
                } else if !list {
                    // Binds' own bar has no way to its area's pages or its parts: the row over it carries them.
                    WindowPagesRow(model: model)
                }
                PageView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // The ground draws once: whole when solid, else at its strength over Tinted's blur, Glass's tint carrying it.
            .background(Theme.windowFill(style.color(\.canvas)))
        }
        .onGeometryChange(for: Double.self) { RailLayout.bucket($0.size.width) } action: { width = $0 }
        // Cmd+F where no list shows opens it for the search.
        .onChange(of: model.searchRequests) { if !list { model.searchOpen = true } }
    }
}

extension InstrumentFrame {
    /// Binds draws its own bar in Instrument: its tabs and controls are the page's state. Binds › Mouse and More are plain pages
    /// under the frame's bar, whose tabs lead back to the keyboard (story 56).
    static func pageOwnsBar(_ page: AppPage, section: AppSection? = nil) -> Bool {
        page == .binds && section?.isPlainBindsPage != true
    }
}

/// The bar over a page in Instrument: its title, then what the page keeps there, 52 pt high (the frame's toolbar and
/// Binds' own).
struct InstrumentPageBar<Content: View>: View {
    @Environment(\.style) private var style
    let title: String
    /// Its sides; the style's page margin unless the page narrows its own.
    var side: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title).styleText(\.pageTitle).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
            content
        }
        .lineLimit(1)
        .padding(.horizontal, side ?? style.density.page).frame(height: style.points(52))
    }
}

// MARK: - Rail and page list

/// The rail: the traffic lights' inset, Home and the areas, Pilot and the Hyper key at its foot; the open page's area
/// raised with a tick in the signal colour at the rail's edge. A window too short for the areas' names drops them (P37:
/// Launcher made nine).
private struct InstrumentRail: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel

    var body: some View {
        ViewThatFits(in: .vertical) { rail(named: true); rail(named: false) }
    }

    private func rail(named: Bool) -> some View {
        VStack(spacing: 4) {
            Color.clear.frame(height: 48)   // the traffic lights sit here
            ForEach(AppArea.main, id: \.self) { item($0, named: named) }
            Spacer(minLength: 8)
            item(.pilot, named: named)
            InstrumentHyperCap().padding(.top, 10).padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private func item(_ area: AppArea, named: Bool) -> some View {
        let on = model.page.area == area
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        return Button { model.go(AppPlace(area.pages[0])) } label: {
            VStack(spacing: 4) {
                Image(systemName: area.symbol).font(style.font(\.icon)).frame(height: 18)
                if named { Text(area.title).styleText(\.caption).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .foregroundStyle(style.color(on ? \.text : \.text3))
            .frame(width: 58, height: named ? 50 : 36)
            .background { if on { shape.fill(style.color(\.raised)) } }
            .overlay { if on { shape.strokeBorder(style.color(\.line)) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) { if on { Capsule().fill(style.color(\.accent)).frame(width: 2, height: 18).offset(x: -6) } }
        .help("\(area.title)  ⌘\(area.key)")
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The Hyper key's cap: lit while Hyper is on; a click turns it on or off (the rail's foot, the tabs' strip).
struct InstrumentHyperCap: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style

    var body: some View {
        let on = engine.hyperSwitch.isOn
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 3, style: .continuous)
        return Button { engine.hyperSwitch.set(!on) } label: {
            Image(systemName: "arrowshape.up").font(style.font(\.icon))
                .foregroundStyle(style.color(on ? \.accent : \.text3))
                .frame(width: 44, height: 44)
                .background(style.color(on ? \.accentSoft : \.raised), in: shape)
                .overlay { shape.strokeBorder(style.color(on ? \.accent : \.line)) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(on ? "Hyper is on (\(engine.settings.layerKeys.label)): turn it off" : "Hyper is off: turn it on")
        .accessibilityLabel("Hyper key").accessibilityValue(on ? "On" : "Off")
    }
}

/// The area's pages beside the rail: its name, the search, each page with its state (its parts are its header's tabs),
/// the keys at the foot. While a search holds words, what it finds in place of the pages.
private struct InstrumentPageList: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel

    var body: some View {
        let area = model.page.area
        VStack(alignment: .leading, spacing: 0) {
            Text(area == .home ? "Search" : area.title).styleText(\.pageTitle).foregroundStyle(style.color(\.text))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            InstrumentSearchField(model: model).padding(.horizontal, 10).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty { pages(area) } else { InstrumentSearchResults(model: model) }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Text(RailLayout.hint(area, rows: area == .extensions ? ExtensionPages.shared.pageEntries.count : 0)).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
                .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .overlay(alignment: .top) { InstrumentRule() }
        }
    }

    @ViewBuilder private func pages(_ area: AppArea) -> some View {
        ForEach(area.shown, id: \.self) { page in
            InstrumentPageRow(model: model, page: page)
            // Extension pages under Extensions (story 161): pages of their own, so they stay rows (P36).
            if page == .extensions { ExtensionPageRows(model: model) { InstrumentExtensionRow(link: $0, on: $1, open: $2) } }
        }
    }
}

/// A page in the list: its name, its state under it with a dot (PageState), raised when open. A view of its own, so a
/// change of state redraws only its row.
private struct InstrumentPageRow: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let page: AppPage

    var body: some View {
        let on = model.shows(page)
        let state = PageState.of(page, engine: engine, clashes: model.conflictCount)
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        Button { model.go(AppPlace(page)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).styleText(\.body).fontWeight(.medium).foregroundStyle(style.color(on ? \.text : \.text2))
                if let state {
                    HStack(spacing: 6) {
                        Circle().fill(style.color(state.on ? \.accent : \.line3)).frame(width: 5, height: 5)
                        Text(state.text).styleText(\.caption).foregroundStyle(style.color(\.text3))
                    }
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: style.points(36), alignment: .leading)
            .background { if on { shape.fill(style.color(\.raised)) } }
            .overlay { if on { shape.strokeBorder(style.color(\.line)) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Search

/// The window's search field: the pages, settings and System Settings panes by name; Cmd+F focuses it, Escape empties it.
/// The page list's, and the tabs' strip's.
struct InstrumentSearchField: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    @FocusState private var searching: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            TextField("Search settings", text: $model.query, prompt: Text("Search settings").foregroundStyle(style.color(\.text3)))
                .textFieldStyle(.plain).styleText(\.body).foregroundStyle(style.color(\.text)).focused($searching)
                .onSubmit { model.goToFirstResult() }
                .onExitCommand { model.query = ""; model.searchOpen = false; searching = false }
            if model.query.isEmpty {
                Text("⌘F").styleText(\.key).foregroundStyle(style.color(\.text3))
            } else {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(style.color(\.text3)).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).frame(height: style.points(30))
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
        .onChange(of: model.searchRequests) { searching = true }
        .onAppear { if model.searchOpen { searching = true } }
        .onChange(of: searching) { if !searching && model.query.isEmpty { model.searchOpen = false } }
    }
}

/// What the search finds: places whose title or settings match, then Binds when a bind matches the same words, then the
/// System Settings panes (Q131), which open in System Settings.
struct InstrumentSearchResults: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let model: AppWindowModel

    var body: some View {
        let places = AppPlace.search(model.query, developer: DeveloperPages.on), panes = SettingsSearch.panes(model.query)
        let bindHits = !BindsPage.sections(store: engine.binds.store, actions: engine.bindActions, search: model.query).isEmpty
        VStack(alignment: .leading, spacing: 2) {
            ForEach(places, id: \.self) { place in
                InstrumentListRow(title: place.path) { model.go(place); model.query = "" }
            }
            if bindHits {
                InstrumentListRow(title: "Binds matching “\(model.query.trimmingCharacters(in: .whitespaces))”") {
                    model.go(AppPlace(.binds)); model.query = ""
                }
            }
            ForEach(panes, id: \.self) { pane in
                InstrumentListRow(title: pane.path) { model.openPane(pane); model.query = "" }
            }
            if places.isEmpty, !bindHits, panes.isEmpty {
                Text("Nothing matches").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(10)
            }
        }
    }
}

/// A line of the list: a search result.
private struct InstrumentListRow: View {
    @Environment(\.style) private var style
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).styleText(\.body).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: style.points(28), alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar

struct InstrumentToolbar: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.homeSources) private var sources
    @Bindable var model: AppWindowModel
    /// The page list shows beside: the area's pages are there, not here. The page's parts are here at every width.
    let listed: Bool

    var body: some View {
        let page = model.page
        InstrumentPageBar(title: model.title) {
            if page == .home {
                TimelineView(.everyMinute) { context in
                    Text(Self.stamp(sources.now(context.date))).styleText(\.mono).foregroundStyle(style.color(\.text3))
                }
            }
            if !listed, page.area.shown.count > 1 { areaPages(page.area).padding(.leading, 8) }
            if !model.tabs.isEmpty { tabs(page).padding(.leading, 8) }
            Spacer(minLength: 8)
            if page == .home {
                HStack(spacing: 9) {
                    Text("Hyper").styleText(\.body).foregroundStyle(style.color(\.text2))
                    Toggle("Hyper key", isOn: Binding(get: { engine.hyperSwitch.isOn }, set: { engine.hyperSwitch.set($0) }))
                        .toggleStyle(InstrumentSwitchStyle())
                        .help(engine.hyperSwitch.isOn ? "Turn the Hyper key off" : "Turn the Hyper key on")
                }
                .padding(.trailing, 6)
                Button { engine.action(AppsModule.menuID)?.run() } label: {
                    InstrumentKeyedLabel(title: "Open menu", trigger: engine.binds.store.trigger(for: AppsModule.menuID))
                }
                .buttonStyle(InstrumentButtonStyle())
            }
        }
    }

    /// A merged page's parts as a segmented control on a sunk track, the picked one raised, with ⌘⇧]'s hint beside it
    /// while it fits (P36); tighter where the bar is too narrow for them whole, never cut.
    private func tabs(_ page: AppPage) -> some View {
        let options = page.tabs.map { ($0.value, $0.title) }
        let selection = Binding(get: { model.section(of: page) }, set: { model.sections[page] = $0 })
        func segments(tight: Bool = false) -> InstrumentSegments<AppSection?> {
            InstrumentSegments(options: options, selection: selection, tight: tight)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                segments().fixedSize()
                Text(RailLayout.partsHint).styleText(\.key).foregroundStyle(style.color(\.text3)).fixedSize().accessibilityHidden(true)
            }
            segments().fixedSize()
            segments(tight: true).fixedSize()
            segments(tight: true)
        }
        .accessibilityLabel("\(page.title) parts")
    }

    /// Folded (no list beside): the area's pages as a segmented control, so every page stays a click away.
    private func areaPages(_ area: AppArea) -> some View {
        let options = area.shown.map { (value: $0, title: $0.title) }
        let selection = Binding(get: { model.page }, set: { model.go(AppPlace($0)) })
        return ViewThatFits(in: .horizontal) {
            InstrumentSegments(options: options, selection: selection).fixedSize()
            InstrumentSegments(options: options, selection: selection, tight: true)
        }
        .accessibilityLabel("\(area.title) pages")
    }

    /// "Thu 8 Oct · 09:41".
    static func stamp(_ date: Date) -> String {
        TopBarClockFormat.date.text(date) + " · " + TopBarClockFormat.time24.text(date)
    }
}
