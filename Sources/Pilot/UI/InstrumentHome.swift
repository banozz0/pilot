import AppKit

import PilotCore
import SwiftUI

/// Home in the panel (pilot-ui-redesign T6, round 2's shots 7c-home and 7c-search): the date and the greeting, Hyper's
/// state (or what needs you) beside them, one search over every setting, page and bind (⌘F), then the four switches
/// that matter, the Pilot menu's own (Dropdown.Switch.four), and Jump back in, the settings changed last with their
/// values. While the search holds words its results take the switches' place, grouped by tab path with each value;
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
                    VStack(spacing: 12) {
                        HomeSwitches()
                        HomeJumpBack(keys: sources.recent(), schema: sources.schema) { key, place in
                            if let model { model.go(place); model.ring(key) } else { go(place) }
                        }
                    }
                    .padding(.top, 14).padding(.bottom, 12)
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, Self.side).padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Home's four switches (Dropdown.Switch.four, T4's one model): Launcher, Key binds, Tiling and Clipboard, each its state
/// in mono beside its switch: the launcher's key, how many keys are bound, else on or off.
private struct HomeSwitches: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style

    var body: some View {
        let switches = engine.quickSwitches
        VStack(spacing: 0) {
            ForEach(Array(Dropdown.Switch.four.enumerated()), id: \.offset) { i, which in
                let on = switches[which].isOn
                HStack(spacing: 14) {
                    Text(which.title).styleText(\.row).foregroundStyle(style.color(\.text))
                    Spacer(minLength: 8)
                    Text(state(which, on: on)).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    Toggle(which.title, isOn: Binding(get: { on }, set: { _ in switches[which].toggle() }))
                        .labelsHidden().toggleStyle(InstrumentSwitchStyle())
                }
                .padding(.horizontal, 16).frame(height: style.points(40))
                .overlay(alignment: .top) { if i > 0 { InstrumentRule() } }
            }
        }
        .styleSurface(\.card)
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

/// Jump back in: the settings changed last, newest first, each with its tab and its value; a click opens its page and
/// rings its row. Until one changes, a line says what will show here.
private struct HomeJumpBack: View {
    @Environment(\.style) private var style
    let keys: [String]
    let schema: () -> SettingsSchema
    /// Opens a setting's page, its key to ring.
    let open: (String, AppPlace) -> Void

    /// The most it lists: what the panel holds under the switches without scrolling.
    static let most = 2

    var body: some View {
        let rows = keys.isEmpty ? [] : Self.rows(keys, schema: schema())
        VStack(alignment: .leading, spacing: 0) {
            Text("Jump back in").styleText(\.strong).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16).frame(height: style.points(40))
            if rows.isEmpty {
                Text("The settings you change show here, with their values.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .padding(.horizontal, 16).frame(height: style.points(40))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { InstrumentRule() }
            }
            ForEach(rows, id: \.key) { row in
                Button { open(row.key, row.place) } label: {
                    HStack(spacing: 6) {
                        Text(row.label).styleText(\.row).foregroundStyle(style.color(\.text))
                        Text("· \(row.place.page.area.title)").styleText(\.body).foregroundStyle(style.color(\.text3))
                        Spacer(minLength: 8)
                        Text(row.value).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 16).frame(height: style.points(40))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { InstrumentRule() }
            }
        }
        .styleSurface(\.card)
    }

    struct Row {
        let key: String
        let label: String
        let place: AppPlace
        let value: String
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
