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

    /// Which view the page shows now, as PagePart's switch picks it: a part that is a view of its own is kept apart, a
    /// part a page draws itself (a More tab, a landing) is that page's.
    static func key(_ model: AppWindowModel) -> String {
        key(model.page, section: model.section(of: model.page), extensionPage: model.extensionPage)
    }

    static func key(_ page: AppPage, section: AppSection?, extensionPage: String?) -> String {
        switch page {
        case .binds: section == .bindsMore ? "binds.more" : section == .mouse ? "binds.mouse" : "binds"
        case .menu: section == .rings ? "menu.rings" : "menu"
        case .tiling: section == .tilingMore ? "tiling.more" : "tiling"
        case .look: section == .themeCatalogue ? "look.catalogue" : "look"
        case .captures: section == .captureHistory ? "captures.history" : "captures"
        case .files: section == .folders ? "files.folders" : "files"
        case .install: section == .webApps ? "install.webApps" : section == .installMore ? "install.more" : "install"
        case .ai: section == .aiSetup ? "ai.setup" : "ai"
        case .extensions: extensionPage.map { "extension." + $0 } ?? "extensions"
        default: page.rawValue
        }
    }
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
    static let ringsOnMore: [AppPage: Set<String>] = [.dock: DockPage.moreKeys, .clipboard: ClipboardSettingsView.moreKeys,
                                                      .tiling: FocusedWindowMore.moreKeys, .captures: CapturesPage.moreKeys,
                                                      .voice: VoicePage.moreKeys]

    /// A page that reads on a repeat takes `model.live`; one that reads once as it shows takes `model.onScreen`. Each is
    /// false while the part is hidden (WhileShown), and Binds and Launcher keep the search they last showed (HeldSearch):
    /// only those read `pageShown`, so a part hidden or shown again redraws them alone.
    @ViewBuilder private var content: some View {
        switch page {
        case .home:
            HomePage { model.go($0) }
        case .binds:
            if section == .bindsMore {
                BindsMorePage { model.editBind = $0; model.go(AppPlace(.binds)) }
            } else if section == .mouse {
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
        case .workspaces: WorkspacesSettingsView(more: section == .workspacesMore)
        // Tiling's More: the focused window's exact rows (pilot-ui-redesign T16).
        case .tiling: if section == .tilingMore { FocusedWindowMore() } else { TilingSettingsView() }
        // The menu bar lane's page (card agent-bo-95422913).
        case .menuBar: WhileShown { MenuBarPage(onScreen: $0 && model.live) }
        // Pilot's dock's own page (round 4).
        case .dock: DockPage(more: section == .dockMore)
        case .look where section == .themeCatalogue: ThemeCataloguePage()
        case .look: LookPage(section: section == .wallpaper ? section : nil, focus: model.wallpaperFocus) { model.sections[.look] = nil }
        case .widgets: WidgetsPage()
        case .system: WhileShown { SetupPage(onScreen: $0 && model.onScreen, section: model.setupSection, tookSection: { model.setupSection = nil }).equatable() }
        // Reports is on Update & Clean's More since the feature trim (2026-11-19): Open report goes there.
        case .upkeep: UpkeepPage(more: section == .upkeepMore) { model.go($0) }
        case .clipboard: ClipboardSettingsView(more: section == .clipMore)
        case .captures:
            if section == .captureHistory { CaptureHistoryPage() } else { CapturesPage(recording: section == .recording, more: section == .capturesMore) }
        case .snippets: SnippetsSettingsView(editSnippet: model.editSnippet, tookSnippet: { model.editSnippet = nil }).equatable()
        case .notes: WhileShown { NotesPage(onScreen: $0 && model.onScreen) }
        case .files:
            // File search is a place on the front (settings tidy), which the window scrolls to.
            if section == .folders { FolderDesignsView() } else { ConvertPage() }
        case .install:
            switch section {
            case .webApps: WebAppsSettingsView()
            case .installMore: InstallMorePage()
            default: CataloguePage(query: model.installQuery ?? "", search: InstallSearcher.search)
            }
        case .openWith: OpenWithPage()
        case .fonts: FontsPage(getMore: { model.go(AppPlace(.catalogue)); model.installQuery = CataloguePage.fonts })
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
        // What a part's frame (PartFrame) shows beyond its page: its picture is stale once any of it changed while hidden.
        deck.chrome = { [weak model, more] page in
            "\(more.tabs) \(more.open) \(ExtensionPages.shared.entries.map(\.id)) \(String(describing: model?.section(of: page)))"
        }
        return deck
    }

    /// The deck takes what it is offered. Asked its fitting size instead, AppKit fills a layout engine with every kept
    /// page's constraints to answer, on every switch and again as it resumes (page-switch-4: 15 % of a switch).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageDeck, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    func updateNSView(_ deck: PageDeck, context: Context) {
        // A landing, a ring or an edit asked for waits on its block: that part is built whole.
        let whole = model.blockFocus != nil || model.ringed != nil || model.setupSection != nil || model.wallpaperFocus != nil
            || model.editBind != nil || model.editAlias != nil || model.editSnippet != nil || model.extensionFocus != nil
        deck.show(key, root(model.page, model.section(of: model.page), model.extensionPage), page: model.page, whole: whole)
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

    /// What a part's frame shows beyond its page, for `page` (KeptPages).
    var chrome: (AppPage) -> String = { _ in "" }

    /// Shows part `key`. A part not built yet is built in view a few pieces a frame (`buildInView`), unless `whole` (a
    /// landing or a ring waits on a block that would not be there yet).
    func show(_ key: String, _ root: AnyView, page: AppPage, whole: Bool = false) {
        let host: PageHost
        // A part still being built (in view, or ahead) is a first visit, and goes on being built in view.
        let built = hosts[key] == nil || building[key] != nil
        if whole, let half = building[key] { finish(key, half) }
        if let kept = hosts[key] {
            // A part built a piece at a time keeps its stage: without it every Staged container would be another view, built
            // again.
            kept.rootView = PageHost.root(kept.stage.map { AnyView(root.environment(\.buildStage, $0)) } ?? root, kept.slot)
            host = kept
        } else if whole {
            host = PageHost(root)
        } else {
            let stage = BuildStage()
            host = PageHost(AnyView(root.environment(\.buildStage, stage)))
            host.stage = stage
            building[key] = Building(stage: stage)
        }
        if hosts[key] == nil {
            // Sized by this view, never by its content: no constraints, no intrinsic size to work out.
            host.sizingOptions = []
            hosts[key] = host
        }
        host.page = page
        guard shown != key || host.superview !== self || host.isHidden else { return }
        PageSwitchTiming.showed(from: shown, to: key, first: built)
        if let shown, let old = hosts[shown], old !== host { hide(old) }
        order.removeAll { $0 == key }
        order.append(key)
        if host.frame != bounds { host.frame = bounds }
        if host.superview === self { host.isHidden = false } else { addSubview(host) }
        matchLayers()
        tellSoon()
        while order.count > Self.cap {
            // Its tree goes with it: emptied first, so nothing the views hold keeps the host alive.
            let goes = order.removeFirst()
            building[goes] = nil
            guard let gone = hosts.removeValue(forKey: goes) else { continue }
            gone.removeFromSuperview()
            gone.rootView = AnyView(EmptyView())
        }
        // Its first frame: as many pieces as fit now, the rest in the frames after.
        if let half = building[key] { buildInView(key, half, host) }
    }

    // MARK: Building a piece at a time (page-first, page-instant)

    /// A part not whole yet: its stage, and each turn's main-thread time so far.
    final class Building {
        let stage: BuildStage
        var turns: [Duration] = []
        /// When its first piece was built, for the time it took to be whole.
        let began = ContinuousClock.now
        /// Shown with all it shows drawn: the rest, below the fold, waits for the window to be quiet (`buildInView`).
        var below = false
        /// The page's scroll view, once found (`filled`).
        weak var scroll: NSScrollView?
        init(stage: BuildStage) { self.stage = stage }
    }
    /// The parts not whole yet: the one shown is built in view, the others hidden while the window is quiet.
    private var building: [String: Building] = [:]

    /// How long a frame of a part built in view may spend adding pieces: the next piece starts only within it (Sven on
    /// build 3142, "pages still lag the same": every switch was a first visit, 100 to 330 ms in one frame).
    static let frameBudget: Duration = .milliseconds(8)

    /// One frame of part `key`, shown: pieces top down, each block whole before the next (BuildStage), until the frame's
    /// budget is spent; the next frame goes on at the screen's next refresh, so each frame draws more of the page and
    /// nothing drawn moves. Once the page fills the window, what is below the fold waits for the window to be
    /// quiet (`buildNextAhead`), as a part built ahead does, and a scroll or a key finishes it at once (page-frames: on
    /// combined-13 General, Binds and Menu bar held 45 to 170 ms frames after they drew, building blocks no one saw yet).
    /// A switch away leaves the rest to `buildNextAhead`, hidden.
    private func buildInView(_ key: String, _ half: Building, _ host: PageHost) {
        let start = ContinuousClock.now
        let stage = half.stage
        stage.inView = true
        // At least a pass a frame: the first has the part's frame and the page's top, whatever they cost.
        var full = false
        repeat {
            step(stage, host)
            full = filled(half, host)
        } while stage.held && !full && ContinuousClock.now - start < Self.frameBudget && stage.step < Self.turnsMost
        half.turns.append(ContinuousClock.now - start)
        guard stage.held && stage.step < Self.turnsMost else { return finish(key, half) }
        if full {
            half.below = true
            quietAgain = true
            return armAhead()
        }
        // The next frame's pieces at the screen's next refresh: one pass a frame, the frame in between drawn and shown
        // (page-frames: passes queued on the run loop ran back to back, the screen's frames waiting on them).
        passKey = key
        if passLink == nil, let window {
            let tick = #selector(pass(_:))
            let link = window.screen != nil ? displayLink(target: self, selector: tick)
                : (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: self, selector: tick)
            link?.add(to: .main, forMode: .common)
            passLink = link
        }
    }

    /// The part built in view at the next refresh (`buildInView`), and the screen's refreshes that bring it.
    private var passKey: String?
    private var passLink: CADisplayLink?

    @objc private func pass(_ link: CADisplayLink) {
        let key = passKey
        passKey = nil
        if let key, shown == key, let half = building[key], !half.below, let host = hosts[key] { buildInView(key, half, host) }
        // None next: the link holds the deck until it goes.
        if passKey == nil { stopPass() }
    }

    private func stopPass() {
        passLink?.invalidate()
        passLink = nil
    }

    /// Whether the shown part is still built in view: its switch has not settled (SwitchFrames).
    var buildingInView: Bool { shown.flatMap { building[$0] }.map { !$0.below } == true }

    /// One pass: the container holding children back built last adds one, and the part is laid out with it.
    private func step(_ stage: BuildStage, _ host: PageHost) {
        stage.step += 1
        stage.held = false
        stage.tickets = 1
        host.layoutSubtreeIfNeeded()
        // Held back, yet no container took the piece: the one built last went (a branch not taken any more).
        if stage.held, stage.tickets == 1, !stage.holders.isEmpty { stage.holders.removeLast() }
    }

    /// Whether `event` reaches below the fold of part `host`: a scroll, a key, or a press on one of its scrollers, which
    /// drags the page.
    private func passesFold(_ event: NSEvent, _ host: PageHost?) -> Bool {
        if event.type == .scrollWheel || event.type == .keyDown { return true }
        guard event.type == .leftMouseDown, let host, event.window === window,
              let hit = host.hitTest(convert(event.locationInWindow, from: nil)) else { return false }
        return sequence(first: hit, next: \.superview).contains { $0 is NSScroller }
    }

    /// Whether part `host`'s page runs past the window: its scroll view (the widest, not the page list's) holds more than
    /// it shows.
    private func filled(_ half: Building, _ host: PageHost) -> Bool {
        if half.scroll?.isDescendant(of: host) != true {
            func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
            half.scroll = scrolls(host).max { $0.frame.width < $1.frame.width }
        }
        guard let scroll = half.scroll, let page = scroll.documentView else { return false }
        return page.frame.height > scroll.contentView.bounds.height
    }

    /// Part `key` is whole from now on: every container shows all its children.
    private func finish(_ key: String, _ half: Building) {
        half.stage.step = .max
        building[key] = nil
        guard let host = hosts[key] else { return }
        if host.isHidden, let window { host.left = left(host, in: window) }
        if half.stage.inView { PageSwitchTiming.builtInView(key, turns: half.turns, whole: ContinuousClock.now - half.began) }
        else { PageSwitchTiming.builtAhead(key, turns: half.turns) }
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
    /// off until the window is quiet again. A part left half built in view goes on the same way. A half-built part shown
    /// goes on in view. They go with the window's tree as it closes, as every kept part does.
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

    /// A part half built, hidden or shown with its fold filled (`buildInView`), the one shown longest ago first.
    private var quietHalf: String? { order.first { key in building[key].map { key != shown || $0.below } == true } }

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
                    // The page shown is cut at the fold: whole before the scroll or the key reaches it.
                    if let shown = self.shown, let half = self.building[shown], half.below, self.passesFold(event, self.hosts[shown]) {
                        self.finish(shown, half)
                        self.hosts[shown]?.layoutSubtreeIfNeeded()
                    }
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
        // The page shown, cut at the fold, goes on behind another window too: it scrolls there.
        guard showing() || quiet != nil && quiet == shown else { stopAhead(); return waitToShow() }
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
            host.page = next.page
            host.isHidden = true
            hosts[next.key] = host
            // Shown longest ago: the first to go past `cap`, before any part the user opened.
            order.insert(next.key, at: 0)
            addSubview(host, positioned: .below, relativeTo: nil)
            building[next.key] = Building(stage: stage)
            key = next.key
        }
        guard let half = building[key], let host = hosts[key] else { return armAhead() }
        if key == shown {
            // The shown part's next piece below the fold, drawn as the window draws.
            step(half.stage, host)
        } else {
            // This turn's piece built and drawn, then hidden before its commit, so no frame shows it and no event reaches
            // it; the keyboard stays where it was.
            let responder = window.firstResponder
            half.stage.inView = false
            host.isHidden = false
            step(half.stage, host)
            host.displayIfNeeded()
            host.isHidden = true
            if window.firstResponder !== responder { window.makeFirstResponder(responder) }
        }
        half.turns.append(ContinuousClock.now - start)
        // Nothing held back: the part is whole, drawn at its size, so its first visit flips to it (picture). A part still
        // held back after `turnsMost` turns is finished whole in the next.
        if !half.stage.held || half.stage.step >= Self.turnsMost { finish(key, half) }
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
            stopPass()
        } else {
            // What a switch's frames line reads (SwitchFrames): this window's screen, and whether the page shown is settled.
            PageSwitchTiming.deck = self
            armAhead()
        }
    }

    /// A part left: hidden and out of the keyboard's way at once; its views are told with the shown one's (`tellSoon`).
    private func hide(_ host: PageHost) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: host) { window?.makeFirstResponder(nil) }
        host.isHidden = true
        // A part left half built has no picture: shown again, it is built on in view (`finish` takes one once it is whole).
        host.left = host.stage.map { $0.step != .max } == true ? nil : window.map { left(host, in: $0) }
    }

    /// How `host` is left: under which look and frame, where in the window and at what window size (picture).
    private func left(_ host: PageHost, in window: NSWindow) -> PageHost.Left {
        PageHost.Left(look: Self.look(host), chrome: host.page.map(chrome) ?? "", at: host.convert(host.bounds, to: nil), window: window.frame.size)
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
              left.window == window?.frame.size, left.look == Self.look(host), left.chrome == (host.page.map(chrome) ?? ""),
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

    private func tell() {
        telling = false
        for (key, host) in hosts where host.slot.shown != (key == shown) { host.slot.shown = key == shown }
    }
}

/// A part built a piece at a time: ahead, hidden (PageDeck.buildAhead; Sven, 2026-11-22, Q344 B: "no key waits more than
/// one frame"), or in view on its first visit (PageDeck.buildInView; Sven on build 3142: "pages still lag the same").
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
    /// The stage of the part being built ahead; nil in a part built in view.
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
    private final class Shown { var count = 0; var turn: Int? }

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
        guard stage.step != .max else { return count }
        let so = shownSoFar
        let id = ObjectIdentifier(so)
        if !inView && stage.inView { so.count = count }
        if so.count < count {
            if !stage.holders.contains(id) { stage.holders.append(id) }
            if so.turn != stage.step, stage.tickets > 0, stage.holders.last == id {
                stage.tickets -= 1
                so.turn = stage.step
                so.count = min(count, so.count + by)
            }
        }
        if so.count < count { stage.held = true } else if let at = stage.holders.lastIndex(of: id) { stage.holders.remove(at: at) }
        return so.count
    }
}

/// A kept part's host: its slot says whether it shows, and no key equivalent reaches it while hidden.
final class PageHost: NSHostingView<AnyView> {
    let slot = PageSlot()
    /// How it was hidden: under which look and frame, where in the window and at what window size (PageDeck.picture).
    var left: Left?
    struct Left: Equatable { let look: String; let chrome: String; let at: NSRect; let window: NSSize }
    /// The page it shows (PageDeck.chrome).
    var page: AppPage?
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
