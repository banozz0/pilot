import AppKit
import PilotCore
import SwiftUI

/// The app window's frame in Instrument: the floating panel (pilot-ui-redesign T3, round 2's shot 7c). The tab bar across
/// the top (PanelTabBar); under it the open tab's pages listed by name down the left, the tab's name over them; beside the
/// list the page under its bar, which holds its name, its parts and the search. An area of one page takes the whole width
/// (Home, Keys, Launcher, AI, Pilot). More's card and what the search finds drop over the page. Binds draws its own bar
/// (InstrumentBindsPage).
struct InstrumentFrame: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    var more = PanelMore()

    var body: some View {
        let list = !RailLayout.fullWidth(model.page.area)
        let owns = Self.pageOwnsBar(model.page, section: model.section(of: model.page))
        VStack(spacing: 0) {
            PanelTabBar(model: model, more: more)
            HStack(spacing: 0) {
                if list {
                    InstrumentPageList(model: model).frame(width: Self.listWidth).background(style.color(\.sidebar))
                    InstrumentRule(vertical: true)
                }
                VStack(spacing: 0) {
                    if !owns {
                        InstrumentToolbar(model: model, listed: list)
                        InstrumentRule()
                    }
                    PageView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                // The ground draws once: whole when solid, else at its strength over Tinted's blur, Glass's tint carrying it.
                .background(Theme.windowFill(style.color(\.canvas)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !owns && !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                WindowSearchDrop(model: model).padding(.top, PanelTabBar.height + style.points(52) - 6).padding(.trailing, 16)
            }
        }
        .overlay {
            if more.open {
                // A click beside the card closes it.
                Color.clear.contentShape(.rect).onTapGesture { more.open = false }.accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if more.open { PanelMoreMenu(model: model, more: more).padding(.top, PanelTabBar.height - 6).padding(.trailing, 40) }
        }
        .onChange(of: model.page) { more.open = false }
    }

    /// The page list's width, as drawn: Tools' six pages by name without scrolling.
    static let listWidth: CGFloat = 156
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

// MARK: - Page list

/// The Hyper key's cap: lit while Hyper is on; a click turns it on or off (the tab bar's right end).
struct InstrumentHyperCap: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// Its side: 28 pt in the panel's tab bar.
    var side: CGFloat = 44

    var body: some View {
        let on = engine.hyperSwitch.isOn
        let shape = RoundedRectangle(cornerRadius: side < 44 ? style.radii.control + 1 : style.radii.control + 3, style: .continuous)
        return Button { engine.hyperSwitch.set(!on) } label: {
            Image(systemName: "arrowshape.up").font(style.font(\.icon))
                .foregroundStyle(style.color(on ? \.accent : \.text3))
                .frame(width: side, height: side)
                .background(style.color(on ? \.accentSoft : \.raised), in: shape)
                .overlay { shape.strokeBorder(style.color(on ? \.accent : \.line)) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(on ? "Hyper is on (\(engine.settings.layerKeys.label)): turn it off" : "Hyper is off: turn it on")
        .accessibilityLabel("Hyper key").accessibilityValue(on ? "On" : "Off")
    }
}

/// The open tab's pages down the left, by name (S3 B's grouping): the tab's name and its key over them in small capitals,
/// the open page raised with a hairline, no accent. Extensions lists each extension's page under its own.
private struct InstrumentPageList: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel

    var body: some View {
        let area = model.page.area
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(area.title).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(area.keyHint).accessibilityHidden(true)
            }
            .styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1)
            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { pages(area) }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10).padding(.top, 14)
    }

    @ViewBuilder private func pages(_ area: AppArea) -> some View {
        ForEach(area.shown, id: \.self) { page in
            InstrumentPageRow(model: model, page: page)
            // Extension pages under Extensions (story 161): pages of their own, so they stay rows (P36).
            if page == .extensions { ExtensionPageRows(model: model) { InstrumentExtensionRow(link: $0, on: $1, open: $2) } }
        }
    }
}

/// A page in the list: its name, raised when open. A view of its own, so a change of the open page redraws only its row.
private struct InstrumentPageRow: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let page: AppPage

    var body: some View {
        let on = model.shows(page)
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous)
        Button { model.go(AppPlace(page)) } label: {
            Text(page.title).styleText(\.body).foregroundStyle(style.color(on ? \.text : \.text2))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { if on { shape.fill(style.color(\.raised)) } }
                .overlay { if on { shape.strokeBorder(style.color(\.line)) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
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
            InstrumentSearchField(model: model).frame(width: 180)
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
