import PilotCore
import SwiftUI

/// Binds › Overlay (story 56, Sven 2026-10-10: "a list of all keybinds and let me toggle"): what holding Hyper shows. The
/// mode on top, then every bind of the active preset the overlay can show, grouped by module with its key and a switch,
/// searched. A switch in Every bind or My most used turns the overlay to My own pick from what it shows now, so nothing
/// else moves; Show all goes back to Every bind, the default. Self-contained, so the layout rework can move it as is.
struct OverlayPicksPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    /// The window's search, until the page's own box is typed in.
    let search: String
    @State private var query: String

    init(search: String = "", query: String = "") {
        self.search = search
        _query = State(initialValue: query)
    }

    var body: some View {
        @Bindable var settings = engine.settings
        // From the mode and the pick, both stored settings, so a switch redraws the page.
        let shown = engine.overlayShown()
        let all = OverlayPage.choices(store: engine.binds.store, actions: engine.bindActions, shown: shown)
        let typed = query.isEmpty ? search : query
        let groups = typed.isEmpty ? all : OverlayPage.choices(store: engine.binds.store, actions: engine.bindActions, shown: shown, search: typed)
        let total = all.reduce(0) { $0 + $1.choices.count }, on = shown.count
        KitPage(intro: Self.intro(delay: settings.overlayDelay)) {
            KitBlock(title: "The overlay shows", symbol: "rectangle.grid.2x2") {
                BlockRow(first: true) {
                    Segments(selection: $settings.overlayMode, options: OverlayPage.Mode.allCases.map { ($0, $0.title) }, label: "The overlay shows")
                    InfoMark(text: "Every bind, each page's 12 most pressed, or only the binds you switch on below.")
                    Spacer(minLength: 8)
                    Text("\(on) of \(total) binds").font(ink.ui(12)).foregroundStyle(ink.muted)
                }
                BlockRow {
                    Text(Self.modeLine(settings.overlayMode)).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                    InfoMark(text: "Show all goes back to Every bind, the default; Show none starts an empty pick to switch binds on in.")
                    Spacer(minLength: 8)
                    Button("Show all") { settings.overlayMode = .every }.buttonStyle(.pilot)
                        .help("Every bind, as the overlay shows until you pick: the default")
                    Button("Show none") { settings.pickOverlay([]) }.buttonStyle(.pilot)
                        .help("Start an empty pick, then switch on the binds you want")
                }
            }
            SearchBox(prompt: "Search binds", text: $query).padding(.vertical, 8)
            if groups.isEmpty { EmptyState(title: total == 0 ? "No binds on Hyper yet" : "No bind matches", line: total == 0 ? nil : "Try another word.") }
            ForEach(groups) { group in
                KitBlock(title: Abilities.title(group.module), symbol: AbilitiesList.symbol(group.module)) {
                    ForEach(group.choices) { choice in
                        BlockRow(first: choice.id == group.choices.first?.id) {
                            Toggle(isOn: Binding(get: { choice.shown }, set: { settings.showInOverlay(choice.id, $0, shown: shown) })) {
                                HStack(spacing: 10) {
                                    Text(choice.label).foregroundStyle(ink.text).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Kbd(text: choice.key)
                                }
                            }
                            .toggleStyle(.pilotSwitchRow(info: Abilities.what(choice.id, label: choice.label)))
                            .accessibilityLabel("Show \(choice.label), \(choice.key), in the overlay")
                        }
                    }
                }
            }
        }
    }

    static func intro(delay: TimeInterval) -> String {
        "Hold Hyper \(delay.formatted()) s with no other key to see the overlay; Shift or Ctrl turns its page. "
            + "Switch on the binds it shows: one pick for every preset, each with the key the preset gives it."
    }

    /// What the mode in use means here, under the switches.
    static func modeLine(_ mode: OverlayPage.Mode) -> String {
        switch mode {
        case .every: "Every bind shows. Switch one off to start your own pick."
        case .mostUsed: "Each page shows its 12 most pressed binds. Switch one to start your own pick from these."
        case .pick: "Only the binds switched on show."
        }
    }
}
