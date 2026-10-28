import PilotCore
import SwiftUI

/// Stats (card agent-bo-95422992, mockup ErxOpOTBN8U on card agent-bo-95422987, Moody PASS): every reading this Mac gives
/// over the last 2 minutes, the last hour or today: a block per reading, each with its value now, its chart and its
/// details, and In menu bar on the ones the bar can show. Which readings the menu bar shows, and how, is picked on the
/// Menu bar page (card agent-bo-95423024), so the readings take the whole window. The intro and History sit under the
/// page's title. Laid out as the Overview (Sven's card layout, 2026-10-12: six cards, Worth a look, Right now) or Compact
/// (every block small, each in its own view).
struct StatsPage: View {
    /// Where a render starts: a range picked, the CPU chart's crosshair at a point (0 to 1).
    struct Start {
        var range = StatsRange.twoMinutes
        var hover: Double?
    }

    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    /// The window shows: the sampler reads every 2 s only then.
    let onScreen: Bool
    private let hover: Double?
    @State private var range: StatsRange
    private let views = StatsViewsStore.shared
    /// Opens another page: the Overview's chevrons and Worth a look's rows open Activity.
    private let go: (AppPlace) -> Void

    init(onScreen: Bool, start: Start = .init(), go: @escaping (AppPlace) -> Void = { _ in }) {
        self.onScreen = onScreen
        self.go = go
        hover = start.hover
        _range = State(initialValue: start.range)
    }

    static let intro = "Everything this Mac reads, over time."
    /// What the page reads while it shows: every reading and the busiest apps.
    static let needs: SystemSampler.Needs = [.rows, .processes]

    var body: some View {
        // At least the window's height: the readings take what the header leaves (Sven, 2026-10-07: the foot was empty).
        FillScroll {
            VStack(alignment: .leading, spacing: 14) {
                header
                StatsReadings(range: range, hover: hover, store: .shared, views: views, go: go).frame(maxHeight: .infinity, alignment: .top)
            }
            // The title where the window puts every other page's.
            .padding(.horizontal, ink.pageInset).padding(.top, ink.pageTop(6)).padding(.bottom, 30)
        }
        .task(id: onScreen) {
            if onScreen { await SystemSampler.shared.watch(needs: Self.needs) }
        }
        // Its own watch, so the switch never restarts the readings.
        .task(id: onScreen && engine.settings.showPublicIP) {
            if onScreen && engine.settings.showPublicIP { await SystemSampler.shared.watch(needs: [.rows, .publicIP]) }
        }
    }

    /// The intro, the machine's line and the range at the right; one under the other when the window is narrow.
    /// The window's header over it names the page (Stats drew its own title until C3, and was Activity's tab until 2026-10-10).
    private var header: some View {
        let controls = StatsControls(views: views, range: $range)
        let intro = Text(Self.intro).font(ink.ui(13.5)).foregroundStyle(ink.text2)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                intro.fixedSize()
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) { MachineLine(); controls }
            }
            VStack(alignment: .leading, spacing: 8) {
                intro.fixedSize(horizontal: false, vertical: true)
                MachineLine().padding(.top, 4)
                controls
            }
        }
    }
}

/// The page's Show (every card at once in the layout picked, none picked while they differ), its Layout, then the Range:
/// on one line where they fit, else Show over Layout and Range, else each on its own line; a name never wraps (Sven,
/// build 42: "Layo ut", "Ran ge").
struct StatsControls: View {
    @Environment(\.ink) private var ink
    let views: StatsViewsStore
    @Binding var range: StatsRange

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { show; layout; ranges }
            VStack(alignment: .leading, spacing: 8) { show; HStack(spacing: 16) { layout; ranges } }
            VStack(alignment: .leading, spacing: 8) { show; layout; ranges }
        }
    }

    private var show: some View {
        let all = Binding<StatsView?>(get: { views.views.shared }, set: { $0.map(views.setAll) })
        return named("Show", info: "Draws every card the same way at once; a card's own switch changes just that card.") { Segments(selection: all, options: StatsView.allCases.map { (Optional($0), $0.title) }, label: "Show every card as") }
    }

    private var layout: some View {
        let layout = Binding(get: { views.views.layout }, set: { views.setLayout($0) })
        return named("Layout", info: "Overview leads with six cards, Worth a look and Right now; Compact shows every reading small.") { Segments(selection: layout, options: StatsDensity.allCases.map { ($0, $0.title) }, label: "Layout") }
    }

    private var ranges: some View {
        named("Range", info: "How far back the charts reach.") { Segments(selection: $range, options: StatsRange.allCases.map { ($0, $0.title) }, label: "Range") }
    }

    private func named(_ name: String, info: String, _ control: () -> some View) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) { Text(name).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).fixedSize(); InfoMark(text: info) }
            control()
        }
    }
}

/// Where Stats' views are kept: Pilot's defaults, as JSON under `stats.views`; none saved, or one that no longer
/// decodes, reads as every card's default in the Overview.
@Observable @MainActor
final class StatsViewsStore {
    static let shared = StatsViewsStore()
    static let key = "stats.views"

    private(set) var views: StatsViews
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        views = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StatsViews.self, from: $0) } ?? StatsViews()
    }

    func set(_ view: StatsView, for card: StatsCard) { save { $0.set(view, for: card) } }

    func setAll(_ view: StatsView) { save { $0.setAll(view) } }

    func setLayout(_ layout: StatsDensity) { save { $0.layout = layout } }

    /// Back to the defaults; nothing saved, so a later default is the one read.
    func reset() {
        views = StatsViews()
        defaults.removeObject(forKey: Self.key)
    }

    private func save(_ change: (inout StatsViews) -> Void) {
        change(&views)
        if let data = try? JSONEncoder().encode(views) { defaults.set(data, forKey: Self.key) }
    }
}

/// "Apple M4 · Mac mini · macOS 26.5 · up 3 d 4 h", the chip lit; the Mac's name until the first reading.
private struct MachineLine: View {
    @Environment(\.ink) private var ink
    private static let name = ProcessInfo.processInfo.hostName

    var body: some View {
        let raw = SystemSampler.shared.latest
        let up = raw.map { " · up " + StatsFormat.duration($0.uptime) } ?? ""
        Group {
            if let machine = raw?.slow.machine {
                let rest = Text(" · \(machine.model) · macOS \(machine.macOS)" + up).foregroundStyle(ink.muted)
                Text("\(Text(machine.chip).fontWeight(.medium).foregroundStyle(ink.text2))\(rest)")
            } else {
                Text(Self.name + up).foregroundStyle(ink.muted)
            }
        }
        .font(ink.ui(12)).lineLimit(1)
    }
}

// MARK: - The menu bar's readings

extension BarKind {
    /// Its name on Stats, which calls Heat what it reads: Temperature.
    var statsTitle: String { self == .heat ? "Temperature" : title }
}
