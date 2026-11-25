import AppKit
import PilotCore
import SwiftUI

/// The app window's frame (C3 page map, Sven 2026-10-10; areas 2026-10-11): the pages in their areas, a page's parts as
/// tabs, in the picked style's frame. Cmd+1 to 9 and 0 open the areas and Cmd+, Pilot (Hyper+1 to 9 stay the tiler's
/// workspaces, as the tap owns Hyper everywhere); Ctrl+Tab steps through an area's pages, Cmd+Shift+] and [ through a
/// page's tabs; Cmd+F searches.
struct AppWindowView: View {
    @Bindable var model: AppWindowModel
    /// The Look the frame draws by; tests pass their own.
    var look: Look = .shared
    /// More's card in the tab bar (PanelTabBar); a render passes one already open.
    var more = PanelMore()
    @Environment(Engine.self) private var engine

    var body: some View {
        // The window's frame is a surface of its own; each page under it is another (PageView).
        WindowLayout(model: model, more: more).styled(.window, look: look)
            .background { PageKeys(model: model) }
            .sheet(isPresented: $model.showsConflicts) {
                ConflictsPage().frame(width: 620, height: 460)
                    .safeAreaInset(edge: .bottom) {
                        HStack { Spacer(); Button("Done") { model.showsConflicts = false }.keyboardShortcut(.defaultAction) }.padding(14)
                    }
                    .pilotSheet()
                    .floating()
            }
            // Binds' clash count, read once per change of the binds, not per page shown.
            .task(id: engine.binds.store.binds) { model.refreshConflicts(binds: engine.binds.store.binds, refused: engine.binds.store.refused.count) }
            .pilotWindowStyles()
            .pilotTheme(look: look)
            .frame(minWidth: AppWindowController.minSize.width, minHeight: AppWindowController.minSize.height)
            .ignoresSafeArea()
    }
}

/// The frame around the page: the panel's tab bar and page list (pilot-ui-redesign T3).
private struct WindowLayout: View {
    @Bindable var model: AppWindowModel
    let more: PanelMore

    var body: some View {
        InstrumentFrame(model: model, more: more)
    }
}

/// Cmd+1 to 9 and 0 for the areas and Cmd+, for Pilot, each on its first page (the window's own Cmd+, wins over the main
/// menu's Open Pilot while it is key); Ctrl+Tab for the next page in the area, in Extensions each extension's page;
/// Cmd+Shift+] and [ for the page's next and previous tab (P36); Cmd+F asks the frame's search to take the keyboard.
private struct PageKeys: View {
    @Bindable var model: AppWindowModel

    var body: some View {
        ZStack {
            // Extensions has no key.
            ForEach(AppArea.allCases.filter { $0.key != nil }, id: \.self) { area in
                Button(area.title) { model.go(AppPlace(area.pages[0])) }.keyboardShortcut(KeyEquivalent(area.key ?? ","), modifiers: .command)
            }
            Button("Next page") { model.nextPage() }.keyboardShortcut(.tab, modifiers: .control)
            // ⌘⇧] arrives as "}" (Shift applied, as Safari's next tab declares it); "]" with ⌘⇧ never matches it.
            Button("Next part") { model.stepPart(by: 1) }.keyboardShortcut("}", modifiers: .command)
            Button("Previous part") { model.stepPart(by: -1) }.keyboardShortcut("{", modifiers: .command)
            Button("Search") { model.searchRequests += 1 }.keyboardShortcut("f", modifiers: .command)
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

/// The page itself, each on the window's cards (card agent-bo-95422728), a merged page on the part picked. Each part
/// visited stays built while the window is open (KeptPages), so a return visit shows it again instead of building it.
struct PageView: View {
    @Bindable var model: AppWindowModel
    /// More's card and the tabs' count, the window's, which each part's bar reads (PartFrame).
    let more: PanelMore
    @Environment(Engine.self) private var engine
    @Environment(\.searchHits) private var hits
    // What the window's own host sets above the page (renders set the last three), carried into each kept page's host.
    @Environment(\.homeSources) private var homeSources
    @Environment(\.aiPageSources) private var aiPageSources
    @Environment(\.lookPreviewStill) private var lookPreviewStill

    var body: some View {
        let key = Self.key(model)
        // The pages switched to most, built ahead while the window idles (PageDeck.buildAhead), each on its part picked last.
        let ahead = model.visits.likeliest(PageDeck.cap - 1, besides: model.page).map { page in
            let section = model.section(of: page)
            return PageDeck.Ahead(key: Self.key(page, section: section, extensionPage: nil), page: page, section: section)
        }
        KeptPages(key: key, model: model, more: more, ahead: ahead) { page, section, extensionPage in
            PartFrame(model: model, more: more, page: page, section: section, extensionPage: extensionPage) {
                PagePart(model: model, page: page, section: section, extensionPage: extensionPage)
            }
                .environment(model).environment(\.searchHits, hits)
                .styled(.window).pilotWindowStyles().pilotTheme()
                .environment(engine).environment(\.homeSources, homeSources).environment(\.aiPageSources, aiPageSources)
                .environment(\.lookPreviewStill, lookPreviewStill)
        }
    }

    /// Which view the page shows now, as PagePart's switch picks it: each tab is a part of its own, kept apart; what a page
    /// draws on its own body (a place on a tab, Plain combos, Wallpaper) is that tab's. A tab sharing its page's part was
    /// that part drawn again inside the switch, behind a picture of the tab left (page-frames-5: Sven's Rings → Launcher
    /// on build 3188, a return visit 178 ms to drawn; Rings → Abilities 406 ms in the probe).
    static func key(_ model: AppWindowModel) -> String {
        key(model.page, section: model.section(of: model.page), extensionPage: model.extensionPage)
    }

    static func key(_ page: AppPage, section: AppSection?, extensionPage: String?) -> String {
        if page == .extensions { return extensionPage.map { "extension." + $0 } ?? "extensions" }
        guard let section, section.isTab, section != page.firstSection else { return page.rawValue }
        return page.rawValue + "." + (section.isMore ? "more" : tabNames[section] ?? section.rawValue)
    }

    /// The tabs whose part keeps a shorter name in the log than its section's.
    private static let tabNames: [AppSection: String] = [.themeCatalogue: "catalogue", .captureHistory: "history", .aiSetup: "setup"]
}

/// The part of the page shown now, in its own host (KeptPages). The page, its part and the extension come in as the host
/// is shown, so a kept host left out of the window never turns into the page shown since.
private struct PagePart: View {
    @Bindable var model: AppWindowModel
    let page: AppPage
    let section: AppSection?
    let extensionPage: String?

    var body: some View {
        content.styled(.page(page)).modifier(PageLanding(model: model, page: page))
    }

    /// The settings each page keeps on its More tab, by their `pilot` keys (pilot-ui-redesign T16, T17, T18; S1 B).
    static let ringsOnMore: [AppPage: Set<String>] = [.voice: VoicePage.moreKeys]

    /// A page that reads on a repeat takes `model.live`; one that reads once as it shows takes `model.onScreen`. Each is
    /// false while the part is hidden (WhileShown), and Binds and Launcher keep the search they last showed (HeldSearch):
    /// only those read `pageShown`, so a part hidden or shown again redraws them alone. Menu bar's preview reads both in
    /// a view of its own (PreviewHold), so its page never redraws for them.
    @ViewBuilder private var content: some View {
        switch page {
        case .home:
            HomePage { model.go($0) }
        case .binds:
            if section == .mouse {
                // Back from System (Sven's round 3 notes on build 2300): the blocks carry the page's intro.
                KitPage { MouseButtonsBlocks() }
            } else {
                HeldSearch(model: model) {
                    BindsKeyboardPage(search: $0, startOnPlain: section == .plainCombos, editBind: model.editBind, tookEdit: { model.editBind = nil }) { model.go($0) }
                        .equatable()
                }
            }
        case .menu:
            if section == .rings {
                RingsPage { model.go($0) }
            } else {
                HeldSearch(model: model) {
                    MenuPage(section: section, search: $0, editAlias: model.editAlias, tookAlias: { model.editAlias = nil },
                             editBind: { model.editBind = $0; model.go(AppPlace(.binds)) })
                        .equatable()
                }
            }
        case .workspaces: WorkspacesSettingsView()
        // Tiling's More: the focused window's exact rows (pilot-ui-redesign T16).
        case .tiling: TilingSettingsView()
        // The menu bar lane's page (card agent-bo-95422913).
        case .menuBar: MenuBarPage(items: section == .menuBarItems)
        // Pilot's dock's own page (round 4).
        case .dock: DockPage()
        case .look where section == .themeCatalogue: ThemeCataloguePage()
        case .look: LookPage(section: section == .wallpaper ? section : nil, focus: model.wallpaperFocus) { model.sections[.look] = nil }
        case .widgets: WidgetsPage()
        case .system: WhileShown { SetupPage(onScreen: $0 && model.onScreen, section: model.setupSection, tookSection: { model.setupSection = nil }).equatable() }
        // Reports is on Update & Clean's More since the feature trim (2026-11-19): Open report goes there.
        case .upkeep: UpkeepPage { model.go($0) }
        case .clipboard: ClipboardSettingsView()
        case .captures:
            if section == .captureHistory { CaptureHistoryPage() } else { CapturesPage(recording: section == .recording) }
        case .snippets: SnippetsSettingsView(editSnippet: model.editSnippet, tookSnippet: { model.editSnippet = nil }).equatable()
        case .notes: WhileShown { NotesPage(onScreen: $0 && model.onScreen) }
        case .files:
            // File search is a place on the front (settings tidy), which the window scrolls to.
            if section == .folders { FolderDesignsView() } else { ConvertPage() }
        case .install:
            switch section {
            case .webApps: WebAppsSettingsView()
            case .installMore: InstallMorePage()
            default: CataloguePage(search: InstallSearcher.search)
            }
        case .openWith: OpenWithPage()
        case .general: GeneralPage()
        case .ai:
            switch section {
            case .aiSetup: AISetupPage()
            default: AIPage()
            }
        case .voice: VoicePage(more: section == .voiceMore)
        case .extensions:
            if let id = extensionPage {
                WhileShown { shown in ExtensionSurfacePage(id: id, onScreen: shown && model.live) { model.extensionFocus = $0; model.go(AppPlace(.extensions)) } }.id(id)
            } else {
                // One list (Q601): a link to the catalogue picks its first row once it is read.
                WhileShown { shown in ExtensionsPageView(onScreen: shown && model.onScreen, focus: $model.extensionFocus, toCatalogue: section == .extensionCatalogue,
                                   landedCatalogue: { model.sections[.extensions] = nil },
                                   editBind: { model.editBind = $0; model.go(AppPlace(.binds)) }, openPage: { model.goExtensionPage($0) }) }
            }
        }
    }
}

/// What the window asks of the part shown (a landing, a ring), never of a part kept hidden: `shown` is read first, so a
/// hidden part reads none of it and no switch elsewhere redraws it (page-switch-3).
private struct PageLanding: ViewModifier {
    @Environment(\.pageShown) private var shown
    @Bindable var model: AppWindowModel
    let page: AppPage

    func body(content: Content) -> some View {
        content
            // A block a link or the search asked for, on More (simplify-pages T7) or a front (Sven, 2026-11-11, after 2276):
            // KitMore or KitLanding lands there, then clears it.
            // Only the page shown takes them: the host being left may still update once as the switch lands.
            .environment(\.blockLanding, here(model.blockFocus).map { place in BlockLanding(place: place) { model.blockFocus = nil } })
            // The setting row a search result opened, ringed for 2 s (pilot-ui-redesign T6).
            .environment(\.landingRing, here(model.ringed))
            // A ringed setting whose row is on its page's More (pilot-ui-redesign T17): More, so the ring shows.
            .onChange(of: shown ? model.ringed : nil) {
                guard let key = model.ringed, model.page == page, PagePart.ringsOnMore[page]?.contains(key) == true,
                      let more = AppSection.more(of: page) else { return }
                model.sections[page] = more
            }
    }

    /// `value` while this part shows and is the window's page, read only then.
    private func here<T>(_ value: @autoclosure () -> T?) -> T? { shown && model.page == page ? value() : nil }
}

/// A page's view given whether its part shows (`pageShown`), for the `onScreen` and `live` it takes.
private struct WhileShown<Content: View>: View {
    @Environment(\.pageShown) private var shown
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(shown) }
}

/// A page's view given the window's search as its part last showed it: a part kept hidden keeps its words, and typing
/// on another page never redraws it.
private struct HeldSearch<Content: View>: View {
    @Environment(\.pageShown) private var shown
    let model: AppWindowModel
    @ViewBuilder let content: (String) -> Content
    @State private var held = Held()
    private final class Held { var query = "" }

    var body: some View {
        if shown { held.query = model.query }
        return content(held.query)
    }
}

/// The window's pages kept built (perf-round; Sven on combined-5, build 2962: switching pages still lagged, SwiftUI
/// building and laying out the page being 80 to 90 % of a switch, page-perf): each part visited is a host of its own,
/// kept while the window is open, and a return visit only shows it again. A part not shown stays in the window, hidden
/// (page-switch-3; Sven on combined-6, build 2995: "still a bit slow and laggy": putting a removed host back cost a
/// return visit 30 to 40 ms more), so no click, key equivalent or accessibility read reaches it and it loses the
/// keyboard as it goes; its views see `pageShown` false, and every timer, task, observer and extension session a page
/// runs stops on it (`onScreen` and `live` false, `onPageLeave`) until it shows again. Past `PageDeck.cap` the part
/// shown longest ago goes, its views disappearing as before.
struct KeptPages<Content: View>: NSViewRepresentable {
    let key: String
    /// Its picks reach the deck before SwiftUI does (PageDeck.picture).
    let model: AppWindowModel
    /// What each part's bar reads beside its page (PageDeck.chrome).
    let more: PanelMore
    /// The parts to build ahead, the likeliest first (PageDeck.buildAhead).
    var ahead: [PageDeck.Ahead] = []
    /// A part's view: its page, its part and the extension whose page it is.
    @ViewBuilder var content: (AppPage, AppSection?, String?) -> Content

    func makeNSView(context: Context) -> PageDeck {
        let deck = PageDeck()
        model.picking = { [weak deck] in deck?.picture($0) }
        deck.showing = { [weak model] in model?.live == true }
        model.screenChanged = { [weak deck] in deck?.screen(on: $0) }
        // What a part's frame (PartFrame) shows beyond its page: its picture is stale once any of it changed while hidden.
        // Not the tab picked: each part marks its own (InstrumentToolbar).
        deck.chrome = { [more] in
            "\(more.tabs) \(more.open) \(ExtensionPages.shared.entries.map(\.id))"
        }
        return deck
    }

    /// The deck takes what it is offered. Asked its fitting size instead, AppKit fills a layout engine with every kept
    /// page's constraints to answer, on every switch and again as it resumes (page-switch-4: 15 % of a switch).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageDeck, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    func updateNSView(_ deck: PageDeck, context: Context) {
        deck.show(key, root(model.page, model.section(of: model.page), model.extensionPage))
        deck.buildAhead(ahead) { root($0.page, $0.section, nil) }
    }

    private func root(_ page: AppPage, _ section: AppSection?, _ extensionPage: String?) -> AnyView {
        AnyView(content(page, section, extensionPage).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).ignoresSafeArea())
    }
}

/// KeptPages' view: the shown part's host, and the other parts kept, hidden.
final class PageDeck: NSView {
    /// How many parts stay built: 27 to 49 MB each while the window is open (page-switch-3, release), all of them gone with
    /// the window's tree when it closes.
    static let cap = 4
    private var hosts: [String: PageHost] = [:]
    /// The parts by when they showed, the one showing last.
    private(set) var order: [String] = []
    var shown: String? { order.last }

    override var isFlipped: Bool { true }

    /// Only the shown part follows the window's size; a kept one keeps the size it was shown at until it shows again.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if let shown, let host = hosts[shown], host.frame != bounds { host.frame = bounds }
    }

    /// What a part's frame shows beyond its page (KeptPages).
    var chrome: () -> String = { "" }

    /// Shows part `key`. A part not built yet is built whole in its first frame, and one half built ahead is finished
    /// there (load-lag: built in view a piece a frame, a first visit drew its top, then assembled over 20 to 35 frames and
    /// 0.3 to 1.3 s, each a whole-page layout, two to four times the main thread's time of building it whole once).
    func show(_ key: String, _ root: AnyView) {
        let host: PageHost
        // A part half built ahead is a first visit too: whole from now on.
        let half = building.removeValue(forKey: key) != nil
        let built = hosts[key] == nil || half
        if let kept = hosts[key] {
            if half { kept.stage?.step = .max }
            // A part built a piece at a time keeps its stage: without it every Staged container would be another view, built
            // again.
            kept.rootView = PageHost.root(kept.stage.map { AnyView(root.environment(\.buildStage, $0)) } ?? root, kept.slot)
            host = kept
        } else {
            host = PageHost(root)
            // Sized by this view, never by its content: no constraints, no intrinsic size to work out.
            host.sizingOptions = []
            hosts[key] = host
        }
        guard shown != key || host.superview !== self || host.isHidden else { return }
        PageSwitchTiming.showed(from: shown, to: key, first: built)
        if let shown, let old = hosts[shown], old !== host { hide(old) }
        order.removeAll { $0 == key }
        order.append(key)
        if host.frame != bounds { host.frame = bounds }
        if host.superview === self { host.isHidden = false } else { addSubview(host) }
        matchLayers()
        tellSoon()
        keep(Self.cap)
    }

    /// The window came on screen or left it (AppWindowModel.onScreen). Off it for `trimAfter`, only the part shown stays
    /// (memory-2: Sven's window, left open behind others for 27 h, held four parts, 29 MB of the 56 MB it took); back on
    /// it, building ahead refills the deck once the window is key and quiet, and a return visit to a part that went before
    /// then is a first visit again.
    func screen(on: Bool) {
        stopTrim()
        guard !on else { return armAhead() }
        guard order.count > 1 else { return }
        let timer = Timer(timeInterval: trimAfter, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.keep(1) } }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        trimTimer = timer
    }
    var trimAfter: TimeInterval = 300
    private var trimTimer: Timer?

    private func stopTrim() {
        trimTimer?.invalidate()
        trimTimer = nil
    }

    /// The `count` parts shown last stay; the rest go, the one shown longest ago first.
    private func keep(_ count: Int) {
        while order.count > count { drop(order[0]) }
    }

    private func drop(_ key: String) {
        order.removeAll { $0 == key }
        building[key] = nil
        guard let gone = hosts.removeValue(forKey: key) else { return }
        // Its tree goes with it: emptied first, so nothing the views hold keeps the host alive.
        gone.removeFromSuperview()
        gone.rootView = AnyView(EmptyView())
    }

    // MARK: Building ahead a piece at a time (page-first, page-instant)

    /// The parts built ahead not whole yet, hidden, built on while the window is quiet: each turn's main-thread time so far
    /// (the stage is the host's).
    private var building: [String: [Duration]] = [:]

    /// One pass: the container holding children back built last adds one, and the part is laid out with it.
    private func step(_ stage: BuildStage, _ host: PageHost) {
        stage.step += 1
        stage.held = false
        stage.tickets = 1
        host.layoutSubtreeIfNeeded()
        // Held back, yet no container took the piece: the one built last went (a branch not taken any more).
        if stage.held, stage.tickets == 1, !stage.holders.isEmpty { stage.holders.removeLast() }
    }

    /// Part `key`, built ahead, is whole from now on: every container shows all its children.
    private func finish(_ key: String) {
        guard let turns = building.removeValue(forKey: key), let host = hosts[key] else { return }
        host.stage?.step = .max
        if let window { host.left = left(host, in: window) }
        PageSwitchTiming.builtAhead(key, turns: turns)
    }

    /// A part to build ahead: its key, its page and part.
    struct Ahead { let key: String; let page: AppPage; let section: AppSection? }
    /// The parts to build ahead, the likeliest first, and their views.
    private var ahead: [Ahead] = []
    private var aheadRoot: (Ahead) -> AnyView = { _ in AnyView(EmptyView()) }
    /// Whether the window shows and is key: nothing is built ahead behind a closed, covered or left window.
    var showing: () -> Bool = { false }
    private var aheadTimer: Timer?
    private var aheadInput: Any?
    /// How long the window stays quiet (no switch, key, click or scroll) before the next part is built ahead.
    static let quiet: TimeInterval = 0.3
    /// What a press is: any of these waiting or arriving puts the next part off until the window is quiet again.
    private static let input: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

    /// The window's likeliest next parts (Sven, 2026-11-22, Q341 A): once the window has drawn its page and stays quiet,
    /// each is built hidden and never past `cap`, so its first visit is a return visit. A part is built a piece a run loop
    /// turn (BuildStage, Q344 B), so a press waits at most one piece; a key, click, scroll or switch puts the next piece
    /// off until the window is quiet again. A half-built part shown is finished whole (`show`). They go with the window's
    /// tree as it closes, as every kept part does.
    func buildAhead(_ parts: [Ahead], root: @escaping (Ahead) -> AnyView) {
        ahead = parts
        aheadRoot = root
        // Called as the window's views update, a switch among them: the next piece waits for the window to be quiet.
        quietAgain = true
        armAhead()
    }

    private var nextAhead: Ahead? {
        order.count < Self.cap ? ahead.first { hosts[$0.key] == nil } : nil
    }

    /// A part half built ahead, hidden, the one shown longest ago first.
    private var quietHalf: String? { order.first { building[$0] != nil && $0 != shown } }

    /// The most turns a part is built in a piece at a time.
    static let turnsMost = 400
    /// A press arrived: the next piece waits for the window to be quiet again.
    private var quietAgain = false

    private func armAhead() {
        aheadTimer?.invalidate()
        aheadTimer = nil
        let quiet = quietHalf
        guard window != nil, quiet != nil || nextAhead != nil else { return stopAhead() }
        if aheadInput == nil {
            aheadInput = NSEvent.addLocalMonitorForEvents(matching: Self.input) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.quietAgain = true
                    self.armAhead()
                }
                return event
            }
        }
        // A part half built goes on at the next turn the run loop has free; a new one after the window was quiet.
        let timer = Timer(timeInterval: quiet == nil || quietAgain ? Self.quiet : 0.001, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildNextAhead() }
        }
        quietAgain = false
        RunLoop.main.add(timer, forMode: .common)
        aheadTimer = timer
    }

    private func stopAhead() {
        aheadTimer?.invalidate()
        aheadTimer = nil
        if let aheadInput { NSEvent.removeMonitor(aheadInput) }
        aheadInput = nil
    }

    private func buildNextAhead() {
        aheadTimer = nil
        let quiet = quietHalf
        guard let window, quiet != nil || nextAhead != nil else { return stopAhead() }
        guard showing() else { stopAhead(); return waitToShow() }
        // A press already waiting goes first.
        if NSApp.nextEvent(matching: Self.input, until: .distantPast, inMode: .default, dequeue: false) != nil {
            quietAgain = true
            return armAhead()
        }
        let start = ContinuousClock.now
        let key: String
        if let quiet {
            key = quiet
        } else {
            guard let next = nextAhead else { return stopAhead() }
            let stage = BuildStage()
            let host = PageHost(AnyView(aheadRoot(next).environment(\.buildStage, stage)), shown: false)
            host.stage = stage
            host.sizingOptions = []
            // Every part, frame and all, fills the deck: built at the size it will show at.
            host.frame = bounds
            host.isHidden = true
            hosts[next.key] = host
            // Shown longest ago: the first to go past `cap`, before any part the user opened.
            order.insert(next.key, at: 0)
            addSubview(host, positioned: .below, relativeTo: nil)
            building[next.key] = []
            key = next.key
        }
        guard building[key] != nil, let host = hosts[key], let stage = host.stage else { return armAhead() }
        // This turn's piece built and drawn, then hidden before its commit, so no frame shows it and no event reaches it;
        // the keyboard stays where it was.
        let responder = window.firstResponder
        host.isHidden = false
        step(stage, host)
        host.displayIfNeeded()
        host.isHidden = true
        if window.firstResponder !== responder { window.makeFirstResponder(responder) }
        building[key]?.append(ContinuousClock.now - start)
        // Nothing held back: the part is whole, drawn at its size, so its first visit flips to it (picture). A part still
        // held back after `turnsMost` turns is finished whole in the next.
        if !stage.held || stage.step >= Self.turnsMost { finish(key) }
        armAhead()
    }

    private var waitingToShow = false

    /// The window not key yet (it becomes key a moment after it opens) or left: building ahead goes on once it is again.
    private func waitToShow() {
        guard !waitingToShow else { return }
        waitingToShow = true
        // A run loop block, not the main queue's, so a nested run loop (a test's) runs it too.
        withObservationTracking { _ = showing() } onChange: { [weak self] in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    self?.waitingToShow = false
                    self?.armAhead()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// SwiftUI shows the first part before the deck is in the window: building ahead waits for the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAhead()
            stopLeft()
            stopTrim()
        } else {
            // What a switch's frames line reads (SwitchFrames): this window's screen.
            PageSwitchTiming.deck = self
            armAhead()
        }
    }

    /// A part left: hidden and out of the keyboard's way at once; its views are told with the shown one's (`tellSoon`).
    private func hide(_ host: PageHost) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: host) { window?.makeFirstResponder(nil) }
        host.isHidden = true
        host.left = window.map { left(host, in: $0) }
    }

    /// How `host` is left: under which look and frame, where in the window and at what window size (picture).
    private func left(_ host: PageHost, in window: NSWindow) -> PageHost.Left {
        PageHost.Left(look: Self.look(host), chrome: chrome(), at: host.convert(host.bounds, to: nil), window: window.frame.size)
    }

    /// The part `picture` drew as it was left, before SwiftUI puts it back.
    private(set) var pictured: String?

    /// The first frame of a return visit (page-switch-5; Sven, 2026-11-21: "how can we make the switch instant?"): kept
    /// part `key`'s own layers, as it drew when it was left, shown in place of the part showing now and committed at once,
    /// before the model's change reaches SwiftUI. The live switch (`show`) follows in the same run loop turn, so the next
    /// event reaches the live part, never the picture, and the picture is the part itself, glass and all: nothing is
    /// captured and nothing more is held. The part carries the frame that names its page (PartFrame), so this one frame is
    /// the whole switch: the page, its tab's mark, its list and its bar (page-frame). Not while the window's size, the look
    /// or what the part's frame reads changed since it was left (the part keeps them as they were until it shows again),
    /// nor on a first visit (nothing to show yet); a part built ahead was drawn whole, so it has one.
    func picture(_ key: String) {
        guard key != shown, let host = hosts[key], host.superview === self, host.isHidden, let left = host.left,
              left.window == window?.frame.size, left.look == Self.look(host), left.chrome == chrome(),
              left.at.size == host.frame.size, let shown, let old = hosts[shown], let layer = host.layer, let oldLayer = old.layer
        else { return }
        PageSwitchTiming.began()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oldLayer.isHidden = true
        layer.isHidden = false
        CATransaction.commit()
        CATransaction.flush()
        pictured = key
        PageSwitchTiming.pictured()
        // Should SwiftUI not show `key` this turn after all, the layers go back to what their views say.
        AfterCommit.observe(repeats: false) { [weak self] in self?.matchLayers() }
    }

    /// Every kept part's layers as its view says, once a picture has done its job.
    private func matchLayers() {
        guard pictured != nil else { return }
        pictured = nil
        for host in hosts.values where host.layer?.isHidden != host.isHidden { host.layer?.isHidden = host.isHidden }
    }

    /// What a kept part was drawn under: its picture is stale once the theme, the style, the glass or the appearance change.
    private static func look(_ host: NSView) -> String {
        let look = Look.shared
        return "\(look.paletteRevision) \(look.style) \(look.glass) \(look.transparency) \(look.glassBlur) "
            + "\(look.reduceTransparency) \(look.increaseContrast) \(host.effectiveAppearance.name.rawValue)"
    }

    private var telling = false

    /// Each kept part's views learn whether they show once the switch has drawn: the part shown comes back as it was
    /// left, then resumes its reads, and the one left stops its own, a run loop turn later, so neither holds the switch.
    /// Waits for the commit (AfterCommit), then tells on the next turn: a block or a main-queue job queued now could run
    /// in this turn, before the commit. Run loop blocks, not the main queue's, so a nested run loop (a test's) runs them too.
    private func tellSoon() {
        guard !telling else { return }
        telling = true
        let main = CFRunLoopGetMain()
        AfterCommit.observe(repeats: false) { [weak self] in
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated { self?.tell() } }
            CFRunLoopWakeUp(main)
        }
        // Shown from inside the run loop's own wait (a display pass), the observer first runs on the next one.
        CFRunLoopWakeUp(main)
    }

    /// The part shown learns it shows; each part left learns it is hidden at a refresh of its own after that, so the
    /// two pages' updates never share a frame (page-frames-5: Menu bar → Look's return visit held one 40 ms turn after
    /// drawn).
    private func tell() {
        telling = false
        if let shown, let host = hosts[shown], !host.slot.shown { host.slot.shown = true }
        if leftLink == nil, !untold.isEmpty { leftLink = refreshLink(#selector(tellLeft(_:))) }
    }

    /// The parts left that still think they show.
    private var untold: [PageHost] { hosts.filter { $0.key != shown && $0.value.slot.shown }.map(\.value) }

    /// The screen's refreshes that tell the parts left, one a refresh (`tell`).
    private var leftLink: CADisplayLink?

    @objc private func tellLeft(_ link: CADisplayLink) {
        let left = untold
        left.first?.slot.shown = false
        if left.count <= 1 { stopLeft() }
    }

    private func stopLeft() {
        leftLink?.invalidate()
        leftLink = nil
    }

    /// A display link on the window's screen (the main one while the window is on none) calling `selector` each refresh.
    private func refreshLink(_ selector: Selector) -> CADisplayLink? {
        guard let window else { return nil }
        let link = window.screen != nil ? displayLink(target: self, selector: selector)
            : (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: self, selector: selector)
        link?.add(to: .main, forMode: .common)
        return link
    }
}

/// A part built a piece at a time ahead, hidden (PageDeck.buildAhead; Sven, 2026-11-22, Q344 B: "no key waits more than
/// one frame"). `inView` is the offscreen renders' model of a first visit built a frame at a time (WidePagesRenders), which
/// Pilot no longer does (load-lag: PageDeck.show).
/// Each pass the Staged container that began holding children back last shows one more, so a block is whole before the
/// next one comes and nothing drawn moves, until none holds any back. A part built whole has no stage.
@MainActor @Observable final class BuildStage {
    /// The pass the part's build is at; `.max` once it is whole.
    var step = 1
    /// Pieces this pass may still add: one, so a pass builds one child of one container.
    @ObservationIgnored var tickets = 1
    /// Whether a container held children back in the last pass: the part is not whole yet.
    @ObservationIgnored var held = false
    /// The containers holding children back, by when they began to: the last goes on first.
    @ObservationIgnored var holders: [ObjectIdentifier] = []
    /// Built in view: containers side by side show all their children at once (Staged.inView).
    @ObservationIgnored var inView = false
}

extension EnvironmentValues {
    /// The stage of the part being built ahead; nil in a part built whole.
    @Entry var buildStage: BuildStage?
}

/// `content`'s children: all of them, or in a part built a piece at a time one more on a pass this container is the last
/// to have begun holding some back (BuildStage). Staged and whole are one view, so the part never builds again once it
/// is whole.
struct Staged<Content: View>: View {
    @Environment(\.buildStage) private var stage
    /// Children added a pass: more for many small ones (a board's keys).
    var by = 1
    /// Whether it adds them a piece at a time in view too: not children side by side, which each one added would resize.
    var inView = true
    @ViewBuilder var content: Content
    /// How many children it shows, and the turn it last added one in.
    @State private var shownSoFar = Shown()
    /// `seen`: it showed in view once, so it stays whole there (its children side by side) when the part builds on below
    /// the fold a child a pass. `whole`: it showed every child once, so children that come later (rows read late) come
    /// all at once, never a piece a pass under what is drawn (page-frames-5: Launcher's rows pushed the block under them
    /// down a row at a time).
    private final class Shown { var count = 0; var turn: Int?; var seen = false; var whole = false }

    var body: some View {
        if let stage {
            Group(subviews: content) { children in
                ForEach(children.prefix(shown(of: children.count, stage))) { $0 }
            }
        } else {
            content
        }
    }

    private func shown(of count: Int, _ stage: BuildStage) -> Int {
        let so = shownSoFar
        // Whole once, whole from then on, without reading the stage: no later pass runs it again.
        if so.whole { return count }
        guard stage.step != .max else { return count }
        let id = ObjectIdentifier(so)
        if !inView, stage.inView { so.seen = true }
        if !inView && so.seen { so.count = count }
        if so.count < count {
            if !stage.holders.contains(id) { stage.holders.append(id) }
            if so.turn != stage.step, stage.tickets > 0, stage.holders.last == id {
                stage.tickets -= 1
                so.turn = stage.step
                so.count = min(count, so.count + by)
            }
        }
        if so.count < count {
            stage.held = true
        } else {
            so.whole = true
            if let at = stage.holders.lastIndex(of: id) { stage.holders.remove(at: at) }
        }
        return so.count
    }
}

/// A kept part's host: its slot says whether it shows, and no key equivalent reaches it while hidden.
final class PageHost: NSHostingView<AnyView> {
    let slot = PageSlot()
    /// How it was hidden: under which look and frame, where in the window and at what window size (PageDeck.picture).
    var left: Left?
    struct Left: Equatable { let look: String; let chrome: String; let at: NSRect; let window: NSSize }
    /// How it was built, when it was built ahead a piece at a time (BuildStage).
    var stage: BuildStage?

    /// `shown` false for a part built ahead (PageDeck.buildAhead): its views start as a hidden part's.
    convenience init(_ root: AnyView, shown: Bool = true) {
        self.init(rootView: AnyView(EmptyView()))
        slot.shown = shown
        rootView = Self.root(root, slot)
    }

    /// The part's views over its slot, which sets `pageShown` for them.
    static func root(_ content: AnyView, _ slot: PageSlot) -> AnyView { AnyView(PageSlotRoot(slot: slot, content: content)) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { isHidden ? false : super.performKeyEquivalent(with: event) }
}

/// Whether a kept part shows (PageDeck sets it; page-switch-3).
@MainActor @Observable final class PageSlot {
    var shown = true
}

/// A kept part's root: only this reads its slot, so a part hidden or shown again updates from here down.
private struct PageSlotRoot: View {
    let slot: PageSlot
    let content: AnyView
    var body: some View { content.environment(\.pageShown, slot.shown) }
}

extension EnvironmentValues {
    /// Whether the window shows this view's page: false while PageDeck keeps the page hidden (page-switch-3).
    @Entry var pageShown = true
}

extension View {
    /// `action` as this view disappears and each time its kept page is hidden behind another: what onDisappear did on a
    /// page switch while a page left the window (page-switch-3). A plain onDisappear in a page runs only as its part
    /// goes for good (past PageDeck.cap, or with the window).
    func onPageLeave(_ action: @escaping () -> Void) -> some View {
        onDisappear(perform: action).modifier(PageShownChange(shown: {}, hidden: action))
    }

    /// `action` as this view appears on its page shown and each time its kept page shows again: onAppear's twin of
    /// `onPageLeave`. A part built ahead, hidden (PageDeck.buildAhead), arrives as it first shows, so it never takes the
    /// keyboard from the page shown.
    func onPageArrive(_ action: @escaping () -> Void) -> some View {
        modifier(ShownAppear(action: action)).onPageReturn(action)
    }

    /// `action` each time this view's kept page shows again, after the switch has drawn: a one-shot read a `.task` makes
    /// as the page is built, again on each return visit, as when a removed page was put back.
    func onPageReturn(_ action: @escaping () -> Void) -> some View {
        modifier(PageShownChange(shown: action, hidden: {}))
    }
}

private struct ShownAppear: ViewModifier {
    @Environment(\.pageShown) private var pageShown
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onAppear { if pageShown { action() } }
    }
}

private struct PageShownChange: ViewModifier {
    @Environment(\.pageShown) private var pageShown
    let shown: () -> Void
    let hidden: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: pageShown) { pageShown ? shown() : hidden() }
    }
}

/// A page's name over it, in the style's page title; none in Instrument, whose toolbar names the page.
struct PageTitle: View {
    @Environment(\.ink) private var ink
    let text: String
    var body: some View {
        if ink.isInstrument { EmptyView() }
        else { Text(text).styleText(\.pageTitle).foregroundStyle(ink.text).accessibilityAddTraits(.isHeader) }
    }
}

extension AppPage {
    /// A page shows its name over it; Home greets you instead.
    var showsTitle: Bool { self != .home }
}
