import PilotCore
import SwiftUI

/// Toybox's window frame, direction 1 (window directions, Sven 2026-10-11, design 6D3E1T482hjVZaUkgMvvDb; mockup B's
/// src/common.css .side, .nav, .rail, .hyperchip): a 76 pt rail of the areas as coloured tiles, Pilot and the Hyper
/// keycap at its foot, a 2 pt ink line; beside it the area's pages on the sunk sidebar, one row each with its state, the
/// search well over them; the page's parts are tabs in its header (P36). Home takes the whole width; a window under 900 pt
/// folds the list away and the page's header carries the area's pages too (RailLayout). Cmd+1 to 8, Cmd+, and Cmd+F stay the
/// window's (PageKeys); Cmd+F focuses the list's search, or opens the list for it.
struct ToyFrame<Page: View>: View {
    @Environment(\.style) private var style
    let model: AppWindowModel
    @ViewBuilder var page: Page
    /// The window's width, kept to the widths the rules tell apart: only crossing a line redraws the frame.
    @State private var width: Double = 1440

    var body: some View {
        let list = RailLayout.showsList(model.page, width: width, searching: model.searchOpen)
        HStack(spacing: 0) {
            ToyRail(model: model).frame(width: 76).background(style.color(\.sidebar))
            style.color(\.outline).frame(width: 2)
            if list {
                ToyPageList(model: model).frame(width: RailLayout.listWidth(width)).background(style.color(\.sidebar))
                style.color(\.outline).frame(width: 2)
            }
            VStack(spacing: 0) {
                // Binds draws its own title row with no way to its area's pages or its parts: folded, the row over it does.
                if !list && ToyLayout.ownsTitleRow(model.page, section: model.section(of: model.page)) { WindowPagesRow(model: model) }
                ToyPageHeader(model: model, listed: list)
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(style.color(\.canvas))
        .onGeometryChange(for: Double.self) { RailLayout.bucket($0.size.width) } action: { width = $0 }
        .onChange(of: model.searchRequests) { if !list { model.searchOpen = true } }
    }
}

/// The frame's layout rules beyond RailLayout's.
enum ToyLayout {
    /// Home greets you in its own hero, and Binds draws its own title row; every other page takes the frame's header,
    /// Binds › Overlay too (story 56).
    static func ownsTitleRow(_ page: AppPage, section: AppSection? = nil) -> Bool {
        page == .home || (page == .binds && section?.isPlainBindsPage != true)
    }
}

// MARK: - Rail and page list

/// The rail (`.rail`): the traffic lights' inset, Home and the areas as tiles named under them, the open one ringed in the
/// accent; Pilot and the Hyper keycap at the foot. A window too short for the names shows the tiles alone (P37: Launcher
/// made nine areas).
private struct ToyRail: View {
    @Environment(\.style) private var style
    let model: AppWindowModel

    var body: some View {
        ViewThatFits(in: .vertical) { rail(named: true); rail(named: false) }
    }

    private func rail(named: Bool) -> some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 40)   // the traffic lights sit here
            ForEach(AppArea.main, id: \.self) { item($0, named: named) }
            Spacer(minLength: 8)
            item(.pilot, named: named)
            ToyHyperChip(rail: true).padding(.top, 8).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func item(_ area: AppArea, named: Bool) -> some View {
        let on = model.page.area == area
        return Button { model.go(AppPlace(area.pages[0])) } label: {
            VStack(spacing: 4) {
                ToyTile(symbol: area.symbol, color: Toy.pageTile(area.pages[0], style), size: 36)
                    .padding(3)
                    .overlay { if on { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(style.color(\.accent), lineWidth: 3) } }
                if named { Text(area.title).font(style.toyNunito(800, 11)).foregroundStyle(style.color(on ? \.text : \.text2)).lineLimit(1) }
            }
            .frame(width: 66).contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help("\(area.title)  ⌘\(area.key)")
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The area's pages (`.side`): its name in the display face, the search well, each page with its state (its parts are
/// its header's tabs), the keys at the foot. While the search holds words, what it finds in place of the pages.
private struct ToyPageList: View {
    @Environment(\.style) private var style
    let model: AppWindowModel

    var body: some View {
        let area = model.page.area
        VStack(alignment: .leading, spacing: 0) {
            Text(area == .home ? "Search" : area.title).font(style.toyFredoka(26)).tracking(-0.26)
                .foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 12)
            ToySearchField(model: model, focusOnRequest: true).padding(.horizontal, 14).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ToySearchResults(model: model) {}
                    } else {
                        ForEach(area.shown, id: \.self) { page in
                            ToyPageRow(model: model, page: page)
                            // Extension pages under Extensions (story 161): pages of their own, so they stay rows (P36).
                            if page == .extensions { ExtensionPageRows(model: model) { ToyExtensionRow(link: $0, on: $1, rail: false, open: $2) } }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            Text(RailLayout.hint(area, rows: area == .extensions ? ExtensionPages.shared.pageEntries.count : 0)).font(style.toyNunito(700, 12)).foregroundStyle(style.color(\.text3)).lineLimit(1).minimumScaleFactor(0.85)
                .padding(.horizontal, 22).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 4])).foregroundStyle(style.color(\.line2)).frame(height: 1)
                        .padding(.horizontal, 14)
                }
        }
    }
}

/// A page in the list (`.nav a`): its name and its state with a dot (PageState); the open one a sun keycap with its edge.
/// A view of its own, so a change of state redraws only its row.
private struct ToyPageRow: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let model: AppWindowModel
    let page: AppPage
    @State private var hovering = false

    var body: some View {
        let on = model.shows(page)
        let state = PageState.of(page, engine: engine, clashes: model.conflictCount)
        Button { model.go(AppPlace(page)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(style.toyNunito(800, 14.5)).foregroundStyle(style.color(on ? \.onAccent : \.text))
                if let state {
                    HStack(spacing: 6) {
                        Circle().fill(style.color(state.on ? \.good : \.text3)).frame(width: 6, height: 6)
                        Text(state.text).font(style.toyNunito(700, 12)).foregroundStyle(style.color(on ? \.onAccent : \.text3).opacity(on ? 0.8 : 1))
                    }
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, on ? 12 : 8)
            .frame(maxWidth: .infinity, minHeight: style.points(42), alignment: .leading)
            .background {
                if on { Toy.block(style, fill: style.color(\.accent), radius: 13, edge: 4) }
                else if hovering { RoundedRectangle(cornerRadius: 13, style: .continuous).fill(style.color(\.line)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The Hyper key's switch at the sidebar's foot (`.hyperchip`): Hyper's cap, whether it is on and the layer key, the
/// switch (engine.hyperSwitch, as Home's and the dropdown's). Folded, the cap alone, which switches it.
struct ToyHyperChip: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let rail: Bool

    var body: some View {
        let on = engine.hyperSwitch.isOn
        let layerKey = engine.settings.layerKeys.label
        if rail {
            Button { engine.hyperSwitch.set(!on) } label: {
                ToyKeycap(symbol: "arrowshape.up.fill", hyper: on)
                    .padding(EdgeInsets(top: 8, leading: 8, bottom: 10, trailing: 8))
                    .background(Toy.block(style, fill: style.color(\.panel), radius: 14, edge: 4))
            }
            .buttonStyle(.kitPress)
            .help(on ? "Hyper is on (\(layerKey)): turn it off" : "Hyper is off: turn it on")
            .accessibilityRepresentation { HyperToggle() }
        } else {
            HStack(spacing: 10) {
                ToyKeycap(symbol: "arrowshape.up.fill", hyper: on).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(on ? "Hyper is on" : "Hyper is off").font(style.toyNunito(800, 13.5))
                        .foregroundStyle(style.color(\.text))
                    Text(layerKey).font(style.toyNunito(700, 12)).foregroundStyle(style.color(\.text2))
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                HyperToggle()
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            .background(Toy.block(style, fill: style.color(\.panel), radius: 16, edge: 4))
        }
    }
}

// MARK: - Search

/// The sidebar's search well: the pages and settings by name, then Binds when a bind matches; Cmd+F focuses it.
struct ToySearchField: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    /// Cmd+F focuses it (the sidebar's); the rail's panel focuses its own on appearing.
    let focusOnRequest: Bool
    var done: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold)).foregroundStyle(style.color(\.text3))
                .accessibilityHidden(true)
            TextField("Search settings", text: $model.query, prompt: Text("Search settings").foregroundStyle(style.color(\.text3)))
                .textFieldStyle(.plain).focused($focused)
                .font(style.toyNunito(700, 13.5))
                .foregroundStyle(style.color(\.text))
                .onSubmit { model.goToFirstResult(); done() }
                .onExitCommand { model.query = ""; model.searchOpen = false; focused = false; done() }
            if model.query.isEmpty {
                Text("⌘F").font(style.toyNunito(800, 11.5)).foregroundStyle(style.color(\.text3))
                    .accessibilityHidden(true)
            } else {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(style.color(\.text3)).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: style.points(36))
        .toyWell(\.panel, radius: 12)
        .overlay { if focused { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.color(\.accentEdge), lineWidth: 2) } }
        .onChange(of: model.searchRequests) { if focusOnRequest { focused = true } }
        .onAppear { if !focusOnRequest || model.searchOpen { focused = true } }
        .onChange(of: focused) { if !focused && model.query.isEmpty { model.searchOpen = false } }
    }
}

/// What the search finds: the places whose title or settings match, then Binds when a bind matches the same words, then
/// the System Settings panes (Q131), which open in System Settings.
struct ToySearchResults: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let model: AppWindowModel
    let picked: () -> Void

    var body: some View {
        let places = AppPlace.search(model.query, developer: DeveloperPages.on), panes = SettingsSearch.panes(model.query)
        let bindHits = !BindsPage.sections(store: engine.binds.store, actions: engine.bindActions, search: model.query).isEmpty
        VStack(alignment: .leading, spacing: 2) {
            ForEach(places, id: \.self) { place in row(place.path) { model.go(place); picked() } }
            if bindHits {
                row("Binds matching “\(model.query.trimmingCharacters(in: .whitespaces))”") { model.go(AppPlace(.binds)); picked() }
            }
            ForEach(panes, id: \.self) { pane in row(pane.path) { model.openPane(pane); picked() } }
            if places.isEmpty, !bindHits, panes.isEmpty {
                Text("Nothing matches").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text3))
                    .padding(10)
            }
        }
    }

    private func row(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(style.toyNunito(700, 13.5)).foregroundStyle(style.color(\.text))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(ToyRowPress())
    }
}

/// A list row's press: the hairline fill while hovered or pressed, the press scale.
private struct ToyRowPress: ButtonStyle {
    @Environment(\.style) private var style
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? style.color(\.line) : .clear, in: .rect(cornerRadius: 11, style: .continuous))
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? Kit.pressScale : 1)
            .animation(Kit.press, value: configuration.isPressed)
    }
}

// MARK: - Page header

/// The top of a page that does not draw its own: its name in Toybox's page title, its parts as a segmented keycap at
/// every width (P36), and on Binds the clashes, which open as a sheet. Narrow, the parts drop under the name.
struct ToyPageHeader: View {
    let model: AppWindowModel
    /// The page list shows beside: the area's pages are there; folded, they come here beside the parts.
    let listed: Bool

    var body: some View {
        let page = model.page
        let title = page.showsTitle
        if !ToyLayout.ownsTitleRow(page, section: model.section(of: page)) && (title || !model.tabs.isEmpty || page == .binds) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) { name(title); parts(page); Spacer(minLength: 0); clashes(page) }
                VStack(alignment: .leading, spacing: 12) {
                    name(title)
                    HStack(spacing: 12) { parts(page); Spacer(minLength: 0); clashes(page) }
                }
            }
            .padding(.horizontal, Toy.gutter).padding(.top, 24).padding(.bottom, 14)
        }
    }

    @ViewBuilder private func name(_ shown: Bool) -> some View {
        if shown {
            PageTitle(text: model.title).lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder private func parts(_ page: AppPage) -> some View {
        if !listed, page != .home, page.area.shown.count > 1 {
            ToySegments(selection: Binding(get: { model.page }, set: { model.go(AppPlace($0)) }),
                        options: page.area.shown.map { (value: $0, title: $0.title) }, label: "\(page.area.title) pages")
        }
        if !model.tabs.isEmpty {
            ToySegments(selection: Binding(get: { model.section(of: page) }, set: { model.sections[page] = $0 }),
                        options: model.tabs, label: "\(page.title) parts")
        }
    }

    @ViewBuilder private func clashes(_ page: AppPage) -> some View {
        if page == .binds {
            Button { model.showsConflicts = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Conflicts")
                    Text("\(model.conflictCount)").monospacedDigit()
                }
            }
            .buttonStyle(PilotButtonStyle(primary: model.conflictCount > 0))
            .fixedSize()
        }
    }
}

