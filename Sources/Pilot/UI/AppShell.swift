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

/// The picked style's frame around the page: Instrument's is the panel's tab bar and page list (pilot-ui-redesign T3);
/// Toybox keeps its rail until the feature trim takes the style away.
private struct WindowLayout: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let more: PanelMore

    var body: some View {
        switch style.kind {
        case .toybox: ToyFrame(model: model) { PageView(model: model) }
        case .instrument: InstrumentFrame(model: model, more: more)
        }
    }
}

/// Cmd+1 to 9 and 0 for the areas and Cmd+, for Pilot, each on its first page (the window's own Cmd+, wins over the main
/// menu's Open Pilot while it is key); Ctrl+Tab for the next page in the area, in Extensions each extension's page;
/// Cmd+Shift+] and [ for the page's next and previous tab (P36); Cmd+F asks the frame's search to take the keyboard.
private struct PageKeys: View {
    @Bindable var model: AppWindowModel

    var body: some View {
        ZStack {
            // Developer has no key; its pages show only while the switch is on.
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

/// The page itself, each on the window's cards (card agent-bo-95422728), a merged page on the part picked.
struct PageView: View {
    @Bindable var model: AppWindowModel

    var body: some View {
        page.styleLayout().styled(.page(model.page))
            // A block a link or the search asked for, on More (simplify-pages T7) or a front (Sven, 2026-11-11, after 2276):
            // KitMore or KitLanding lands there, then clears it.
            .environment(\.blockLanding, BlockLanding(place: model.blockFocus) { model.blockFocus = nil })
            // The setting row a search result opened, ringed for 2 s (pilot-ui-redesign T6).
            .environment(\.landingRing, model.ringed)
            // A ringed setting whose row is on its page's More (pilot-ui-redesign T17): More, so the ring shows.
            .onChange(of: model.ringed) {
                guard let key = model.ringed, Self.ringsOnMore[model.page]?.contains(key) == true,
                      let more = AppSection.more(of: model.page) else { return }
                model.sections[model.page] = more
            }
    }

    /// The settings each page keeps on its More tab, by their `pilot` keys (pilot-ui-redesign T17, S1 B).
    static let ringsOnMore: [AppPage: Set<String>] = [.dock: DockPage.moreKeys, .clipboard: ClipboardSettingsView.moreKeys,
                                                      .captures: CapturesPage.moreKeys, .voice: VoicePage.moreKeys]

    /// A page that reads on a repeat takes `model.live`; one that reads once as it shows takes `model.onScreen`.
    @ViewBuilder private var page: some View {
        let section = model.section(of: model.page)
        switch model.page {
        case .home:
            HomePage { model.go($0) }
        case .binds:
            if section == .bindsMore {
                BindsMorePage { model.editBind = $0; model.go(AppPlace(.binds)) }
            } else if section == .mouse {
                // Back from System (Sven's round 3 notes on build 2300): the blocks carry the page's intro.
                KitPage { MouseButtonsBlocks() }
            } else {
                BindsKeyboardPage(search: model.query, startOnPlain: section == .plainCombos, editBind: $model.editBind) { model.go($0) }
            }
        case .menu:
            if section == .rings {
                RingsPage { model.go($0) }
            } else {
                MenuPage(section: section, search: model.query, editAlias: $model.editAlias) { model.editBind = $0; model.go(AppPlace(.binds)) }
            }
        case .workspaces: WorkspacesSettingsView(more: section == .workspacesMore)
        case .tiling: TilingSettingsView()
        // The menu bar lane's page (card agent-bo-95422913).
        case .menuBar: MenuBarPage(onScreen: model.live)
        // Pilot's dock's own page (round 4).
        case .dock: DockPage(more: section == .dockMore)
        case .pilotMenu: PilotMenuPage()
        case .look where section == .themeCatalogue: ThemeCataloguePage()
        case .look: LookPage(more: section == .lookMore, section: section == .wallpaper ? section : nil, focus: model.wallpaperFocus) { model.sections[.look] = nil }
        case .widgets: WidgetsPage()
        case .system: SetupPage(onScreen: model.onScreen, section: $model.setupSection)
        // Reports is on Update & Clean's More since the feature trim (2026-11-19): Open report goes there.
        case .upkeep: UpkeepPage(more: section == .upkeepMore) { model.go($0) }
        case .clipboard: ClipboardSettingsView(more: section == .clipMore)
        case .captures:
            if section == .captureHistory { CaptureHistoryPage() } else { CapturesPage(recording: section == .recording, more: section == .capturesMore) }
        case .snippets: SnippetsSettingsView(editSnippet: $model.editSnippet)
        case .notes: NotesPage(onScreen: model.onScreen)
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
        case .configs: if section == .agents { InstructionsPage() } else { ConfigsPage() }
        case .repos: ReposPage(start: .init(repo: model.repoPick)).id(model.repoOpens)
        case .fonts: FontsPage(getMore: { model.go(AppPlace(.catalogue)); model.installQuery = CataloguePage.fonts })
        case .general: GeneralPage()
        case .ai:
            switch section {
            case .aiSetup: AISetupPage()
            default: AIPage()
            }
        case .voice: VoicePage(more: section == .voiceMore)
        case .extensions:
            if let id = model.extensionPage {
                ExtensionSurfacePage(id: id, onScreen: model.live) { model.extensionFocus = $0; model.go(AppPlace(.extensions)) }.id(id)
            } else {
                // One list (Q601): a link to the catalogue picks its first row once it is read.
                ExtensionsPageView(onScreen: model.onScreen, focus: $model.extensionFocus, toCatalogue: section == .extensionCatalogue,
                                   landedCatalogue: { model.sections[.extensions] = nil },
                                   editBind: { model.editBind = $0; model.go(AppPlace(.binds)) }, openPage: { model.goExtensionPage($0) })
            }
        }
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
