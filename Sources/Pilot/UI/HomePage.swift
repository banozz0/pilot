import AppKit
import Clipboard
import PilotCore
import SwiftUI

/// Home, on its grid (HomeNowPage; P91, model A), its blocks the person's own (story 167): HomeLayout's shown blocks on
/// their cells, by default the greeting, Workspaces, Clipboard and Most used down the left and the Hyper keyboard and This
/// Mac beside them; edit mode, on Home itself (spec home-edit), moves, sizes and hides them and adds an installed
/// extension's page back from its tray. Instrument and Toybox each hand the page their own board
/// blocks. Pilot is the whole app, so Home has no Pilot switch; its switch is the Hyper key's (engine.hyperSwitch, Sven 2026-10-07). Every block reads
/// what it shows itself, so a press or a reading redraws only that block.
struct HomePage: View {
    /// Where a render starts: a key clicked on the board.
    struct Start {
        var picked: Int64?
        /// Edit mode on, on the saved layout.
        var editing = false
    }

    @Environment(Engine.self) private var engine
    @Environment(\.homeSources) private var sources
    /// Edit mode as the page is told from outside (a test's), while Home's own is off.
    @Environment(\.homeEdit) private var outerEdit
    /// A start handed down the window (a test's or a render's), else the one given.
    @Environment(\.homeStart) private var givenStart
    @Environment(\.homeEditWatch) private var watch
    /// Instrument and Toybox draw their own Home (InstrumentHome, card agent-bo-95423181; ToyHome, card agent-bo-95423182).
    @Environment(\.style) private var style
    /// The app window shows: This Mac samples and the window list refreshes only then.
    let onScreen: Bool
    /// The window's search holds words: its Return finds a page, so no Home button holds Return then.
    let searching: Bool
    /// Binds' clashes, as the window counts them: the greeting shows them.
    let clashes: Int
    /// Change key: Binds with that action's editor open.
    let editBind: (String) -> Void
    /// Opens an extension's page.
    let openExtension: (String) -> Void
    let go: (AppPlace) -> Void
    @State private var picked: Int64?
    /// Edit mode, while it is on: the page draws its draft; Done saves it, Escape, Cancel and leaving Home throw it away.
    @State private var editing: HomeEditMode?
    /// Where the page measures itself in edit mode (HomeFrames).
    @State private var frames = HomeFrames()
    @State private var pageModels = HomePageModels()
    /// Edit mode on appear (a render's start).
    private let start: Start
    @State private var copy: HomeCopy?
    /// The Hyper binds' names, kinds and pictures, read again only when the binds or the workspace names change.
    @State private var binds: HomeBinds?

    init(onScreen: Bool, searching: Bool = false, clashes: Int = 0, start: Start = .init(), editBind: @escaping (String) -> Void = { _ in },
         openExtension: @escaping (String) -> Void = { _ in }, go: @escaping (AppPlace) -> Void) {
        self.onScreen = onScreen
        self.searching = searching
        self.clashes = clashes
        self.editBind = editBind
        self.openExtension = openExtension
        self.go = go
        _picked = State(initialValue: start.picked)
        self.start = start
    }

    /// What This Mac reads while Home shows.
    static let readings: Set<MenuBarStats.Stat> = [.cpu, .ram, .disk, .sensors]
    /// How often the window list is read again while Home shows, so titles stay fresh.
    static let windowsEvery = Duration.seconds(15)

    /// The cells Home draws `blocks` at. Toybox's Pilot block, drawn only while something needs you, takes the top of the
    /// board when it has no cells of its own, the others moving down.
    static func cells(_ home: HomeLayout, blocks: [String], shown: [String]) -> [String: HomeCell] {
        let pilot = HomeLayout.Block.pilot.rawValue
        guard blocks.contains(pilot), !shown.contains(pilot), home.cell(of: pilot) == nil else { return home.cells(blocks) }
        var layout = home
        let size = HomeLayout.size(of: pilot)
        layout.set(pilot, cell: HomeCell(x: 5, y: 0, w: size.w, h: size.h))
        return layout.cells(blocks, subject: pilot)
    }

    var body: some View {
        let problems = HomeProblems.list(accessibilityGranted: engine.gate.isTrusted, secureInput: engine.secureInput.holder,
                                         tilerRunning: engine.observers.tiler.isAnswering,
                                         lastError: engine.lastError)
        // In edit mode Done holds Return.
        let held = editing != nil ? .none : HomeReturn.target(picked: picked != nil, problems: problems, searching: searching)
        let pages = sources.pages(), widgets = sources.widgets()
        let home = editing?.session.preview ?? sources.layout().layout
        let beyond = HomeLayout.beyond(pages: pages.map(\.id), widgets: widgets.map(\.id))
        let shown = home.shown(extensions: beyond)
        let blocks = HomeLayout.drawn(shown, style: style.kind, needsYou: !problems.isEmpty)
        let parts = HomeParts(problems: problems, held: held, picked: $picked, copy: copy, binds: binds ?? HomeBinds(engine: engine),
                              blocks: blocks,
                              pages: pages, pageModel: { [pageModels, sources] in pageModels.model($0, make: sources.page) }, onScreen: onScreen,
                              editing: $editing, searching: searching,
                              go: go, editBind: editBind, openExtension: openExtension, sources: sources, restartTiler: { [engine] in engine.startTiler() },
                              cells: Self.cells(home, blocks: blocks, shown: shown), pin: home.layout(of:),
                              style: style.kind, clashes: clashes, widgets: widgets)
        Group {
            if style.kind == .toybox { ToyHome(parts: parts) } else { InstrumentHome(parts: parts) }
        }
        .environment(\.homeEdit, editing != nil ? HomeNowEdit(frames: frames) : outerEdit)
        .onChange(of: BindsRead(binds: engine.binds.store.binds, presets: engine.presets.contents), initial: true) {
            binds = HomeBinds(engine: engine)
        }
        .onAppear {
            if let code = givenStart?.picked { picked = code }
            let start = givenStart ?? start
            guard start.editing, editing == nil else { return }
            editing = HomeEditMode(session: parts.newSession())
        }
        // Leaving Home throws an edit away (Sven, 2026-10-12: only Done saves).
        .onDisappear { editing = nil }
        .onChange(of: editing.map(ObjectIdentifier.init), initial: true) { watch?.mode = editing }
        // Escape puts Most used back.
        .onExitCommand { if picked != nil { picked = nil } }
        // The newest copy on appear and each time the window shows again; This Mac reads only while it shows.
        .task(id: onScreen) {
            copy = sources.lastCopied()
            guard onScreen else { return }
            await SystemSampler.shared.watch(stats: Self.readings)
        }
        .task(id: onScreen) {
            guard onScreen else { return }
            while !Task.isCancelled {
                await engine.observers.tiler.refreshOccupied()
                try? await Task.sleep(for: Self.windowsEvery, tolerance: Self.windowsEvery / 10)
            }
        }
    }
}

/// What Home's binds are read from: the Hyper binds and the workspace names their keys show.
private struct BindsRead: Equatable {
    let binds: [Key: String]
    let presets: WorkspacePresetStore.Contents
}

// MARK: - What Home reads beyond the engine

/// The newest copy: its words on one line, when, and how many the history keeps.
struct HomeCopy: Equatable, Sendable {
    let text: String
    let at: Date
    let count: Int
}

/// What Home reads beyond the engine and the sampler, a seam the renders fill: the clipboard's newest copy and the
/// installed extensions' pages, each asked as its own page asks.
struct HomeSources: Sendable {
    /// The time Home's page bar reads, given the clock's: the clock's own in the app; a render pins it so Home agrees
    /// with the top bar drawn beside it (P89's film).
    var now: @MainActor @Sendable (Date) -> Date = { $0 }
    var lastCopied: @MainActor @Sendable () -> HomeCopy? = {
        ClipboardHistory.shared.newest().map { HomeCopy(text: $0.clip.title, at: $0.clip.copiedAt, count: $0.count) }
    }
    /// The installed extensions with a page, each a block Edit Home offers.
    var pages: @MainActor @Sendable () -> [ExtensionPages.Link] = { ExtensionPages.shared.links }
    /// Where Home's blocks are kept.
    var layout: @MainActor @Sendable () -> HomeLayoutStore = { .shared }
    /// What asks an extension's page for its Home block.
    var page: @MainActor @Sendable (String) -> ExtensionPageModel = { ExtensionPageModel(id: $0) }
    /// An extension's bar item's text, the figure its icon tab shows first.
    var barText: @MainActor @Sendable (String) -> String? = { ExtensionBar.shared.text(for: $0) }
    /// Instrument's Clipboard panel and Toybox's Clipboard block (cards agent-bo-95423181, 95423182): the newest kept copies, newest first; none while the
    /// history is not running.
    var recentCopies: @MainActor @Sendable () -> [StoredClip] = { ClipboardHistory.shared.recent() }
    /// The widgets placed on Home, with the tiles the desk feeds while Home draws them.
    var widgets: @MainActor @Sendable () -> [HomeWidget] = { WidgetDesk.shared.homeWidgets() }
    /// A Home widget's tile is drawn in the window on screen, or no longer: its feed starts or stops, its page ended.
    var drawWidget: @MainActor @Sendable (String, Bool) -> Void = { WidgetDesk.shared.drawnOnHome($0, $1) }
}

extension EnvironmentValues {
    @Entry var homeSources = HomeSources()
    /// An extension block asks its page: not in an icon tab's hover card, whose tab asks.
    @Entry var homeBlockAsks = true
    /// Where Home starts when it shows, handed down the window (a test or a render); nil is the page's own.
    @Entry var homeStart: HomePage.Start? = nil
}

// MARK: - Return

/// Which of Home's buttons holds Return (gap G4, Sven 2026-10-07): a hint shown on a button always works. The key
/// inspector's main button while a key is clicked, else the first problem's that has one; none while the window's
/// search holds words, whose Return finds a page.
enum HomeReturn: Equatable {
    case none, key, problem(Int)

    static func target(picked: Bool, problems: [HomeProblems.Problem], searching: Bool) -> HomeReturn {
        if searching { return .none }
        if picked { return .key }
        return problems.firstIndex(where: \.hasFix).map { .problem($0) } ?? .none
    }
}

extension HomeProblems.Problem {
    /// Home has a button for it: Pilot's tiler restarts from Home, the rest open the page that fixes them; Pilot's own
    /// error has none.
    var hasFix: Bool { kind == .tiler || place != nil }
}

/// A button that holds Return while Home shows when `holdsReturn`; a style that draws `hint` beside it reads the same
/// flag, so neither shows without the other.
struct ReturnButton: View {
    let title: String
    var holdsReturn: Bool
    var style = PilotButtonStyle()
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(style)
            .keyboardShortcut(holdsReturn ? .defaultAction : nil)
    }

    static let hint = "↵"
}

// MARK: - The parts every block shares

/// What the page hands its blocks: the problems, which button holds Return, the clicked key, the newest copy, the blocks
/// to draw and the ways out of Home.
@MainActor
struct HomeParts {
    let problems: [HomeProblems.Problem]
    let held: HomeReturn
    let picked: Binding<Int64?>
    let copy: HomeCopy?
    let binds: HomeBinds
    /// The blocks to draw, in order (HomeLayout.drawn).
    let blocks: [String]
    /// The installed extensions with a page.
    let pages: [ExtensionPages.Link]
    /// An extension block's model, kept by extension id.
    let pageModel: (String) -> ExtensionPageModel
    /// The window shows: an extension block asks only then.
    let onScreen: Bool
    /// Home's edit mode, nil at rest (HomeParts.editMode).
    let editing: Binding<HomeEditMode?>
    /// The window's search holds words: its Return finds a page, so Done does not hold Return then.
    let searching: Bool
    let go: (AppPlace) -> Void
    let editBind: (String) -> Void
    let openExtension: (String) -> Void
    let sources: HomeSources

    /// Restarts Pilot's tiler.
    let restartTiler: @MainActor () -> Void
    /// Each drawn block's cells on Home's grid (HomeLayout.cells).
    var cells: [String: HomeCell] = [:]
    /// The class a block's Layout keeps, nil for Auto.
    var pin: (String) -> Widget.SizeClass? = { _ in nil }
    /// The style Home draws in: edit mode packs only the blocks it draws.
    var style: PilotStyle? = nil
    /// Binds' clashes, as the window counts them: the greeting says them.
    var clashes = 0
    /// The widgets placed on Home (HomeWidgetBlock draws each).
    var widgets: [HomeWidget] = []

    /// The rows past Pilot's own blocks, as HomeLayout takes them: the extension pages by id, Home's widgets by row.
    var beyond: [String] { HomeLayout.beyond(pages: pages.map(\.id), widgets: widgets.map(\.id)) }

    /// The Home widget a row draws, if it is one.
    func widget(_ row: String) -> HomeWidget? { widgets.first { $0.row == row } }

    func fix(_ problem: HomeProblems.Problem) -> (title: String, run: @MainActor () -> Void)? {
        HomeFix.of(problem, go: go, restartTiler: restartTiler)
    }

    func holdsReturn(_ i: Int) -> Bool { held == .problem(i) }

    /// A key clicked on Instrument's or Toybox's Home board: Binds' editor on its bind, or Binds for a free key.
    func openKey(_ code: Int64) {
        if let action = binds.bound[code]?.first { editBind(action) } else { go(AppPlace(.binds)) }
    }
}

/// A problem's button (`hasFix` says which have one): Pilot's tiler restarts here (card agent-bo-95423025), the rest open
/// the page that fixes them.
@MainActor
enum HomeFix {
    static func of(_ problem: HomeProblems.Problem, go: @escaping (AppPlace) -> Void,
                   restartTiler: @escaping @MainActor () -> Void) -> (title: String, run: @MainActor () -> Void)? {
        switch (problem.kind, problem.place) {
        case (.tiler, _): ("Restart Pilot's tiler", restartTiler)
        case (_, let place?): ("Open \(place.title)", { go(place) })
        case (_, nil): nil
        }
    }
}

/// The line beside the Hyper switch, as Toybox's greeting says it.
@MainActor
enum HomeGreeting {
    /// The line beside the Hyper switch: first what the switch is, so it never reads as another's, then what needs you
    /// (its button follows), else what the layer key and tiling do.
    /// `tiler` names the tiler (TilerService.tilerName).
    static func line(hyperOn: Bool, problems: [HomeProblems.Problem], layerKey: String, workspace: String?, tiler: String) -> String {
        "Hyper is \(hyperOn ? "on" : "off"). " + rest(hyperOn: hyperOn, problems: problems, layerKey: layerKey, workspace: workspace, tiler: tiler)
    }

    private static func rest(hyperOn: Bool, problems: [HomeProblems.Problem], layerKey: String, workspace: String?, tiler: String) -> String {
        if problems.count > 1 { return "\(problems.count) things need you." }
        if let problem = problems.first {
            switch problem.kind {
            case .tiler: return "\(problem.title), so nothing tiles."
            case .accessibility: return "Accessibility is not granted, so Pilot sees no keys."
            case .secureInput: return "\(problem.title), so Hyper waits."
            case .error: return problem.title.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "."
            }
        }
        guard hyperOn else { return HyperToggle.offWords(layerKey: layerKey) }
        return "\(layerKey) is your Hyper key; \(tiler) is tiling workspace \(workspace ?? "–")."
    }
}

// MARK: - Shared parts

/// A bind's keys: one cap with the layer key's sign and the key.
struct HomeKeys: View {
    @Environment(Engine.self) private var engine
    let key: String
    /// False for a plain combo, which shows its own keys.
    var hyper = true

    var body: some View {
        let symbol = engine.settings.layerKeys.symbol
        Kbd(text: hyper ? "\(symbol) \(key)" : key)
    }

    /// A trigger's key as a cap shows it: "↵" for Return, "␣" for Space, "Esc", "⌫", the sublayer's signs before it ("⇧N").
    static func cap(_ key: Key) -> String {
        key.hyper ? caps(key).joined() : key.label
    }

    /// A Hyper trigger's sublayer signs, then its key as a cap shows it; `space` names Space.
    static func caps(_ key: Key, space: String = "␣") -> [String] {
        let name = KeyNames.name(for: key.keyCode)
        let signs = [(Modifiers.shift, "⇧"), (.ctrl, "⌃"), (.alt, "⌥"), (.cmd, "⌘")].filter { !key.modifiers.isDisjoint(with: $0.0) }.map(\.1)
        return signs + [["Return": "↵", "Space": space, "Escape": "Esc", "Delete": "⌫"][name] ?? name]
    }
}

extension HomeKeys {
    /// A trigger as its caps: the layer key's and the key's, or a plain combo's own.
    init(trigger: Key) { self.init(key: Self.cap(trigger), hyper: trigger.hyper) }
}

/// The Hyper key's switch (engine.hyperSwitch, the dropdown's too): off, the layer key does what macOS says and plain
/// combos still run; on again at every launch.
struct HyperToggle: View {
    @Environment(Engine.self) private var engine
    var body: some View {
        Toggle("Hyper key", isOn: Binding(get: { engine.hyperSwitch.isOn }, set: { engine.hyperSwitch.set($0) }))
            .toggleStyle(.pilotSwitch)
            .help(engine.hyperSwitch.isOn ? "Turn the Hyper key off" : "Turn the Hyper key on")
    }

    /// What Hyper off leaves the layer key doing, as Home's line and the Pilot block say it.
    static func offWords(layerKey: String) -> String { "\(layerKey) does what macOS says; plain combos still run." }
}
