import AppKit

import PilotCore
import SwiftUI

/// Home in the panel (pilot-ui-redesign T6, round 2's shots 7c-home and 7c-search): the date and the greeting, Hyper's
/// state (or what needs you) beside them, one search over every setting, page and bind (⌘F), then the four switches
/// that matter, the Pilot menu's own (Dropdown.Switch.four), as tiles; Jump back in, the settings changed last with their
/// values; the workspaces, today's presses and the binds pressed most (home-layout: Home fills a big window). While the search holds words its results take the switches' place, grouped by tab path with each value;
/// ↑↓ pick one, Return opens it. The switches carry the accent; the rest is neutral.
struct InstrumentHome: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.homeSources) private var sources
    /// The window: its words are the search's, so ⌘F on any tab and Home's field are one search. None in a page render.
    @Environment(AppWindowModel.self) private var model: AppWindowModel?
    @Environment(\.searchHits) private var windowHits
    let go: (AppPlace) -> Void
    @State private var ownQuery = ""
    @State private var ownHits = SearchHitsModel()
    @FocusState private var searching: Bool

    /// The panel's side margin, as drawn.
    static let side: CGFloat = 30

    var body: some View {
        let query = Binding(get: { model?.query ?? ownQuery }, set: { if let model { model.query = $0 } else { ownQuery = $0 } })
        let hits = windowHits ?? ownHits
        let typed = !query.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            head(hits: hits, typed: typed)
            field(query, hits: hits).padding(.top, 14)
            ScrollView {
                if typed {
                    SearchResultsList(hits: hits) { open($0) }.padding(.top, 12)
                } else {
                    // The switches in a row of tiles, then the cards in pairs: Jump back in beside the workspaces, today's
                    // presses beside the binds pressed most; one column and two tiles a row in a small window (home-layout).
                    let now = sources.now(.now)
                    // Built a piece at a time ahead, as every page is (Staged, PageDeck.buildAhead): the switches, then
                    // each card, so no turn waits on all of them. Today is as tall as a full Most pressed, so neither
                    // resizes the other as it lands.
                    VStack(spacing: HomeGrid.spacing) { Staged {
                        HomeSwitches()
                        HomeCardGrid { Staged {
                            HomeJumpBack(keys: sources.recent(), schema: sources.schema) { key, place in
                                if let model { model.go(place); model.ring(key) } else { go(place) }
                            }
                            HomeWorkspacesCard(open: place)
                            HomeTodayCard(now: now)
                            HomeBusiestCard(now: now, open: place)
                        } }
                    } }
                    .padding(.top, 14).padding(.bottom, 12)
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, Self.side).padding(.top, 20)
        // A big window (Sven on build 3160, a tiled window about 1700 by 1290: "a lot of open space"): the grid fills it up
        // to HomeGrid.most wide, centred past that.
        .frame(maxWidth: HomeGrid.most + Self.side * 2, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: ownQuery, initial: true) { if windowHits == nil { ownHits.refresh(ownQuery, engine: engine, schema: sources.schema) } }
        .modifier(TakesSearchKey(requests: model?.searchRequests, searching: $searching))
        .onPageArrive { if model?.searchOpen == true { searching = true } }
    }

    /// The date line and the greeting; beside them Hyper's state, what needs you, or how many settings match.
    private func head(hits: SearchHitsModel, typed: Bool) -> some View {
        let problems = HomeProblems.list(accessibilityGranted: engine.gate.isTrusted, secureInput: engine.secureInput.holder,
                                         tilerRunning: engine.tilerFine, lastError: engine.lastError)
        return HStack(alignment: .lastTextBaseline, spacing: 12) {
            TimelineView(.everyMinute) { context in
                let date = sources.now(context.date)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.stamp(date)).styleText(\.eyebrow).foregroundStyle(style.color(\.text3))
                    // The display face at the shot's 31 pt, so the switches and Jump back in fit the panel unscrolled.
                    Text(HomeGreeting.good(at: date)).font(style.font(\.display, size: 31)).tracking(-0.6).foregroundStyle(style.color(\.text))
                        .lineLimit(1).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
                }
            }
            Spacer(minLength: 8)
            if typed {
                let n = hits.hits.matches
                Text(n == 1 ? "1 setting matches" : "\(n) settings match").styleText(\.body).foregroundStyle(style.color(\.text3))
            } else if let problem = problems.first {
                let fix = HomeFix.of(problem, go: go, restartTiler: { [engine] in engine.startTiler() })
                Button { fix?.run() } label: {
                    Text(problems.count > 1 ? "\(problems.count) things need you" : problem.title).styleText(\.body)
                        .foregroundStyle(style.color(\.warn)).lineLimit(1)
                }
                .buttonStyle(.plain).disabled(fix == nil).help(fix?.title ?? problem.detail ?? problem.title)
            } else {
                Text("Hyper \(engine.hyperSwitch.isOn ? "on" : "off") · \(engine.settings.layerKeys.label)")
                    .styleText(\.body).foregroundStyle(style.color(\.text3)).lineLimit(1)
            }
        }
    }

    /// Home's search field: the panel's width, ⌘F's cap while empty, a clear button once typed in; focused, an accent ring.
    private func field(_ query: Binding<String>, hits: SearchHitsModel) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            TextField("Search settings, pages, binds", text: query,
                      prompt: Text("Search settings, pages, binds").foregroundStyle(style.color(\.text3)))
                .textFieldStyle(.plain).styleText(\.search).foregroundStyle(style.color(\.text)).focused($searching)
                .onSubmit { if let hit = hits.picked { open(hit) } }
                .searchKeys(hits)
                .onExitCommand { query.wrappedValue = ""; model?.searchOpen = false; searching = false }
            if query.wrappedValue.isEmpty {
                InstrumentKey(text: "⌘F").accessibilityHidden(true)
            } else {
                Button { query.wrappedValue = "" } label: { Image(systemName: "xmark").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(style.color(\.text3)).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(height: style.points(44))
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(searching ? \.accent : \.line), lineWidth: searching ? 1.5 : 1) }
        .contentShape(shape)
        .onTapGesture { searching = true }
    }

    /// Opens a page a card links to.
    private func place(_ place: AppPlace) {
        if let model { model.go(place) } else { go(place) }
    }

    private func open(_ hit: SearchHits.Hit) {
        if let model { model.open(hit); return }
        switch hit.target {
        case .setting(_, let place), .place(let place): go(place)
        case .bind, .pane: break
        }
        ownQuery = ""
    }

    /// "THU 19 NOV · 19:42", the eyebrow's capitals.
    static func stamp(_ date: Date) -> String {
        TopBarClockFormat.date.text(date) + " · " + TopBarClockFormat.time24.text(date)
    }
}

/// A Home card (home-layout): its eyebrow, a link to the page it glances at, then its content, on the card surface and
/// as tall as the grid gives it, its content at the top.
private struct HomeCard<Content: View>: View {
    @Environment(\.style) private var style
    let title: String
    var trailing: String?
    /// The page the eyebrow's link opens, its title the link's words.
    var page: AppPage?
    var open: (AppPlace) -> Void = { _ in }
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                InstrumentEyebrow(text: title, role: \.text2)
                if let trailing { Text(trailing).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1) }
                Spacer(minLength: 8)
                if let page {
                    Button { open(AppPlace(page)) } label: {
                        HStack(spacing: 3) {
                            // The page's name, or Open when the eyebrow already says it.
                            Text(page.title.lowercased() == title.lowercased() ? "Open" : page.title)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .styleText(\.small).foregroundStyle(style.color(\.text2)).contentShape(.rect)
                    }
                    .buttonStyle(FacePress()).help("Open \(page.title)")
                }
            }
            .padding(.horizontal, 16).frame(height: style.points(40))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .styleSurface(\.card)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Home's four switches as tiles (Dropdown.Switch.four, T4's one model; the Pilot menu's tile, home-layout): the glyph
/// in its disc, ink while on, a hairline ring while off; the name over its state in mono, the launcher's key, how many
/// keys are bound, else on or off; the switch at the end is what you click, as before.
private struct HomeSwitches: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style

    var body: some View {
        let switches = engine.quickSwitches, layerKeys = engine.settings.layerKeys
        HomeTileRow {
            ForEach(Dropdown.Switch.four, id: \.self) { which in
                let on = switches[which].isOn
                let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
                HStack(spacing: 12) {
                    Image(systemName: which.symbol(layerKeys: layerKeys))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.color(on ? \.onInverse : \.text3))
                        .frame(width: 30, height: 30)
                        .background { if on { Circle().fill(style.color(\.inverse)) } }
                        .overlay { if !on { Circle().strokeBorder(style.color(\.line2)) } }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(which.title).styleText(\.row).foregroundStyle(style.color(\.text)).lineLimit(1)
                        Text(state(which, on: on)).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle(which.title, isOn: Binding(get: { on }, set: { _ in switches[which].toggle() }))
                        .labelsHidden().toggleStyle(InstrumentSwitchStyle())
                }
                .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: style.points(58), alignment: .leading)
                .background(style.color(\.raised), in: shape)
                .overlay { shape.strokeBorder(style.color(\.line)) }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Switches")
    }

    /// "Hyper+Space", "57 bound", "off".
    private func state(_ which: Dropdown.Switch, on: Bool) -> String {
        guard on else { return "off" }
        switch which {
        case .launcher: return engine.binds.store.trigger(for: Dropdown.launcherAction)?.label ?? "no key"
        case .hyper: return "\(engine.binds.store.binds.count) bound"
        default: return "on"
        }
    }
}

/// Jump back in: the settings changed last, newest first, each its name, its page and its value; a click opens its page
/// and rings its row. Until one changes, a line says what will show here.
private struct HomeJumpBack: View {
    @Environment(\.style) private var style

    /// The most it lists: what the window's first size holds beside the workspaces, the switches and the cards under them
    /// unscrolled (HomeRecent keeps six).
    static let most = 5
    let keys: [String]
    let schema: () -> SettingsSchema
    /// Opens a setting's page, its key to ring.
    let open: (String, AppPlace) -> Void

    var body: some View {
        let rows = keys.isEmpty ? [] : Self.rows(keys, schema: schema())
        HomeCard(title: "Jump back in") {
            if rows.isEmpty {
                Text("The settings you change show here, with their values.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .padding(.horizontal, 16).frame(height: style.points(40))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { InstrumentRule() }
            }
            ForEach(rows, id: \.key) { row in
                Button { open(row.key, row.place) } label: {
                    HStack(spacing: 10) {
                        Text(row.name).styleText(\.row).foregroundStyle(style.color(\.text)).layoutPriority(1)
                        Text(row.place.page.title).styleText(\.body).foregroundStyle(style.color(\.text3))
                        Spacer(minLength: 12)
                        Text(row.value).styleText(\.mono).foregroundStyle(style.color(\.text2)).truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 16).frame(height: style.points(40))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(row.label)
                .accessibilityLabel("\(row.name), \(row.place.page.title)").accessibilityValue(row.value).accessibilityHint(row.label)
                .overlay(alignment: .top) { InstrumentRule() }
            }
        }
    }

    struct Row {
        let key: String
        let label: String
        let place: AppPlace
        let value: String
        /// The setting's name as Home lists it (`name(label:key:)`).
        var name: String { HomeJumpBack.name(label: label, key: key) }
    }

    /// The keys still in the schema, their labels, pages and values now; secrets never listed.
    @MainActor static func rows(_ keys: [String], schema: SettingsSchema) -> [Row] {
        let all = Dictionary(schema.sorted.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return keys.compactMap { key -> Row? in
            guard let setting = all[key], setting.kind != .secret, let place = AppPlace.named(setting.page),
                  let value = try? schema.get(key) else { return nil }
            return Row(key: key, label: setting.label, place: place, value: SearchHits.words(value, kind: setting.kind))
        }
        .prefix(most).map(\.self)
    }

    /// A setting's name, short enough to scan (Sven on build 3160: a row was the setting's whole sentence): its label up
    /// to the first colon or semicolon when that is short ("Top bar background"), else its key's last word in plain words
    /// ("menu.browserHistory": "Browser history", "menu.fallbacks": "Fallbacks"). The whole label is the row's help.
    static func name(label: String, key: String) -> String {
        let lead = String(label.prefix { $0 != ":" && $0 != ";" }).trimmingCharacters(in: .whitespaces)
        if lead.count <= 34 { return lead }
        let last = key.split(separator: ".").last.map(String.init) ?? key
        // A run of capitals stays one word ("recordFPS": "Record FPS").
        var words = "", previous: Character?
        for c in last {
            if c.isUppercase, previous?.isUppercase == true { words.append(c) }
            else if c.isUppercase, !words.isEmpty { words += " " + c.lowercased() }
            else { words.append(c) }
            previous = c
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// The workspaces at a glance (home-layout): each numbered tile, the focused one ringed in the signal's line, its apps'
/// icons and names; the tiler down, a line in their place. The menu's own cells (TilerService.homeCells).
private struct HomeWorkspacesCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let open: (AppPlace) -> Void

    @Environment(\.pageShown) private var shown
    @State private var held = HomeHeld()

    var body: some View {
        let (answering, cells, focused) = held.workspaces(engine, shown: shown)
        HomeCard(title: "Workspaces", trailing: answering ? nil : "Stopped", page: .workspaces, open: open) {
            if !answering {
                Text("Tiling is stopped; the workspaces come back once it restarts.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .padding(.horizontal, 16).frame(minHeight: style.points(40), alignment: .leading)
                    .overlay(alignment: .top) { InstrumentRule() }
            }
            ForEach(cells, id: \.name) { cell in
                let current = cell.name == focused
                let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
                HStack(spacing: 10) {
                    Text(cell.name).font(style.font(\.key, size: 12)).lineLimit(1)
                        .foregroundStyle(style.color(current ? \.text : cell.apps.isEmpty ? \.text3 : \.text2))
                        .frame(width: 26, height: 26)
                        .background(style.color(\.raised), in: shape)
                        .overlay { shape.strokeBorder(style.color(current ? \.accentLine : \.line), lineWidth: current ? 1.5 : 1) }
                    HStack(spacing: 3) {
                        ForEach(Array(cell.apps.prefix(4).enumerated()), id: \.offset) { _, name in
                            if let icon = cell.bundles[name].flatMap(AppsModule.icon(bundle:)) ?? AppsModule.icon(named: name) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                        }
                    }
                    Text(cell.apps.isEmpty ? "Empty" : cell.apps.joined(separator: ", ")).styleText(\.body)
                        .foregroundStyle(style.color(cell.apps.isEmpty ? \.text3 : current ? \.text : \.text2)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(height: style.points(40))
                .overlay(alignment: .top) { InstrumentRule() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Workspace \(cell.name)\(current ? ", focused" : "")")
                .accessibilityValue(cell.apps.isEmpty ? "Empty" : cell.apps.joined(separator: ", "))
            }
        }
    }
}

/// Today (home-layout): how many binds ran, and when, as a bar an hour; the hour now a step brighter. Neutral ink, so the
/// signal stays Hyper's. The engine's own count (`pilot status --part today`).
private struct HomeTodayCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.pageShown) private var shown
    let now: Date
    @State private var held = HomeHeld()

    var body: some View {
        let today = held.today(engine, shown: shown)
        let total = today.total(now: now), hours = today.hours(now: now)
        let hour = Calendar.current.component(.hour, from: now)
        HomeCard(title: "Today") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(total)").font(style.font(\.display, size: 30)).tracking(-0.6).foregroundStyle(style.color(\.text))
                    Text(total == 0 ? "No binds run yet today." : "binds run since midnight").styleText(\.body).foregroundStyle(style.color(\.text2))
                }
                HomeHourBars(hours: hours, now: hour, bar: style.color(\.text3), lit: style.color(\.text2), track: style.color(\.line))
                    .frame(minHeight: style.points(80), maxHeight: .infinity)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    ForEach(["00", "06", "12", "18"], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .styleText(\.small).foregroundStyle(style.color(\.text2)).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 14)
        }
        // A full Most pressed's height: its eyebrow and five rows.
        .frame(minHeight: style.points(40) * CGFloat(HomeBusiestCard.most + 1))
    }
}

/// What a card last read from the engine, kept while Home is hidden behind another page: a hidden Home reads nothing
/// that changes on a press or a focus change, so none redraws it (pageShown, as HeldSearch keeps a page's words); shown
/// again, it reads afresh.
@MainActor
final class HomeHeld {
    private var presses = TodayPresses()
    private var cells: (answering: Bool, cells: [OccupiedWorkspace], focused: String?) = (true, [], nil)

    func today(_ engine: Engine, shown: Bool) -> TodayPresses {
        if shown { presses = engine.today }
        return presses
    }

    func workspaces(_ engine: Engine, shown: Bool) -> (Bool, [OccupiedWorkspace], String?) {
        if shown {
            let tiler = engine.observers.tiler
            cells = (tiler.isAnswering, tiler.isAnswering ? tiler.homeCells : [], tiler.focused)
        }
        return cells
    }
}

/// The day's 24 bars in one Canvas: one view however many hours, so the card costs a first visit next to nothing.
private struct HomeHourBars: View {
    let hours: [Int]
    let now: Int
    let bar: Color, lit: Color, track: Color

    var body: some View {
        Canvas { context, size in
            let most = max(hours.max() ?? 0, 1), gap: CGFloat = 4
            let width = (size.width - gap * 23) / 24
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(track))
            for (i, count) in hours.prefix(24).enumerated() where count > 0 {
                let height = max(2, (size.height - 1) * CGFloat(count) / CGFloat(most))
                let rect = CGRect(x: CGFloat(i) * (width + gap), y: size.height - 1 - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)), with: .color(i == now ? lit : bar))
            }
        }
    }
}

/// Most pressed today (home-layout): the binds run most since midnight, each its name, its keys and its count.
private struct HomeBusiestCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let now: Date
    let open: (AppPlace) -> Void

    static let most = 5

    @Environment(\.pageShown) private var shown
    @State private var held = HomeHeld()

    var body: some View {
        let top = held.today(engine, shown: shown).top(Self.most, now: now)
        HomeCard(title: "Most pressed", page: .binds, open: open) {
            if top.isEmpty {
                Text("The binds you press most today show here.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .padding(.horizontal, 16).frame(minHeight: style.points(40), alignment: .leading)
                    .overlay(alignment: .top) { InstrumentRule() }
            }
            ForEach(Array(top.enumerated()), id: \.offset) { _, press in
                HStack(spacing: 10) {
                    Text(engine.action(press.action)?.label ?? press.action).styleText(\.row).foregroundStyle(style.color(\.text)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let trigger = engine.binds.store.trigger(for: press.action) { HomeKeys(trigger: trigger) }
                    Text("\(press.count)").styleText(\.mono).foregroundStyle(style.color(\.text2)).frame(minWidth: 26, alignment: .trailing)
                }
                .padding(.horizontal, 16).frame(height: style.points(40))
                .overlay(alignment: .top) { InstrumentRule() }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// ⌘F gives Home's field the keyboard, only while Home shows: one kept hidden behind another page never takes it
/// (page-switch-3); its own modifier, so Home hidden or shown again redraws only this.
private struct TakesSearchKey: ViewModifier {
    @Environment(\.pageShown) private var shown
    let requests: Int?
    var searching: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onChange(of: requests) { if shown { searching.wrappedValue = true } }
    }
}

// MARK: - The big window (home-layout)

/// Home's width at most, centred past it: a window across an ultrawide screen keeps its cards a readable size.
/// Below `wide` the switches go two to a row and the cards stack in one column.
enum HomeGrid {
    static let most: CGFloat = 1440
    static let wide: CGFloat = 860
    static let spacing: CGFloat = 12
}

/// The four switches as tiles: four to a row from `HomeGrid.wide`, two below it. A Layout, so the window's width picks the
/// columns as it lays out, with no state read back from the frame (a first visit builds once).
struct HomeTileRow: Layout {
    var spacing = HomeGrid.spacing

    private func columns(_ width: CGFloat, _ count: Int) -> Int { width >= HomeGrid.wide ? max(count, 1) : 2 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? HomeGrid.wide
        return CGSize(width: width, height: frames(width, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        let n = columns(width, subviews.count)
        let cell = ((width - spacing * CGFloat(n - 1)) / CGFloat(n)).rounded(.down)
        var frames: [CGRect] = [], y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: n) {
            let row = start..<min(start + n, subviews.count)
            let height = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
            for (i, _) in row.enumerated() {
                frames.append(CGRect(x: CGFloat(i) * (cell + spacing), y: y, width: cell, height: height))
            }
            y += height + spacing
        }
        return frames
    }
}

/// Home's cards in pairs, a wide one on the left and a narrow one beside it, each pair as tall as its taller card; below
/// `HomeGrid.wide`, one column in the same order.
struct HomeCardGrid: Layout {
    var spacing = HomeGrid.spacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? HomeGrid.wide
        return CGSize(width: width, height: frames(width, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = [], y: CGFloat = 0
        guard width >= HomeGrid.wide else {
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                frames.append(CGRect(x: 0, y: y, width: width, height: height))
                y += height + spacing
            }
            return frames
        }
        let left = ((width - spacing) * 0.6).rounded(.down), right = width - spacing - left
        for start in stride(from: 0, to: subviews.count, by: 2) {
            let a = subviews[start].sizeThatFits(ProposedViewSize(width: left, height: nil)).height
            let b = start + 1 < subviews.count ? subviews[start + 1].sizeThatFits(ProposedViewSize(width: right, height: nil)).height : 0
            let height = max(a, b)
            frames.append(CGRect(x: 0, y: y, width: left, height: height))
            if start + 1 < subviews.count { frames.append(CGRect(x: left + spacing, y: y, width: right, height: height)) }
            y += height + spacing
        }
        return frames
    }
}
