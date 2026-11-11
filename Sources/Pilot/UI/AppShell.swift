import AppKit
import PilotCore
import SwiftUI

/// The app window's frame (C3 page map, Sven 2026-10-10; areas 2026-10-11): the pages in their areas, a page's parts as
/// tabs, in the picked style's frame. Cmd+1 to 8 open the areas and Cmd+, Pilot (Hyper+1 to 9 stay the tiler's
/// workspaces, as the tap owns Hyper everywhere); Ctrl+Tab steps through an area's pages, Cmd+Shift+] and [ through a
/// page's tabs; Cmd+F searches.
struct AppWindowView: View {
    @Bindable var model: AppWindowModel
    /// The Look the frame draws by; tests pass their own.
    var look: Look = .shared
    @Environment(Engine.self) private var engine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let editing = model.editingWorkspace != nil
        // The window's frame is a surface of its own; each page under it is another (PageView).
        WindowLayout(model: model, look: look).styled(.window, look: look)
            // The page under the workspace editor is inert: no clicks, Tab focus or page keys (Esc and Return are the
            // popup's), hidden from VoiceOver.
            .disabled(editing)
            .blur(radius: editing ? 1.5 : 0)
            .accessibilityHidden(editing)
            .background { PageKeys(model: model).disabled(editing) }
            .overlay {
                if let edited = model.editingWorkspace {
                    WorkspacePopup(edited: edited) { model.editingWorkspace = nil }.id(edited.id)
                }
            }
            .animation(reduceMotion ? nil : Kit.change, value: model.editingWorkspace?.id)
            .environment(\.editWorkspace) { model.editingWorkspace = EditedWorkspace(name: $0) }
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

/// The picked style's frame around the page, in the Window layout picked on Look. Direction 1, the rail: ToyFrame and
/// InstrumentFrame; direction 2, toolbar tabs: TabsFrame, one frame for both styles.
private struct WindowLayout: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    var look: Look = .shared

    var body: some View {
        switch (look.windowShape, style.kind) {
        case (.tabs, _): TabsFrame(model: model) { PageView(model: model) }
        case (_, .toybox): ToyFrame(model: model) { PageView(model: model) }
        case (_, .instrument): InstrumentFrame(model: model)
        }
    }
}

/// Cmd+1 to 8 for the areas and Cmd+, for Pilot, each on its first page (the window's own Cmd+, wins over the main
/// menu's Open Pilot while it is key); Ctrl+Tab for the next page in the area, in Extensions each extension's page;
/// Cmd+Shift+] and [ for the page's next and previous tab (P36); Cmd+F asks the frame's search to take the keyboard.
private struct PageKeys: View {
    @Bindable var model: AppWindowModel

    var body: some View {
        ZStack {
            ForEach(AppArea.allCases, id: \.self) { area in
                Button(area.title) { model.go(AppPlace(area.pages[0])) }.keyboardShortcut(KeyEquivalent(area.key), modifiers: .command)
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
    }

    /// A page that reads on a repeat takes `model.live`; one that reads once as it shows takes `model.onScreen`.
    @ViewBuilder private var page: some View {
        let section = model.section(of: model.page)
        switch model.page {
        case .home:
            HomePage(onScreen: model.live, searching: !model.query.trimmingCharacters(in: .whitespaces).isEmpty, clashes: model.conflictCount,
                     editBind: { model.editBind = $0; model.go(AppPlace(.binds)) }, openExtension: { model.goExtensionPage($0) }) { model.go($0) }
        case .binds:
            if section == .bindsMore {
                BindsMorePage(search: model.query) { model.editBind = $0; model.go(AppPlace(.binds)) }
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
        case .tiling: TilingSettingsView(more: section == .tilingMore)
        // The menu bar lane's page (card agent-bo-95422913).
        case .menuBar: MenuBarPage(onScreen: model.live)
        case .look: LookPage(more: section == .lookMore, section: section == .wallpaper ? section : nil, focus: model.wallpaperFocus) { model.sections[.look] = nil }
        case .widgets: WidgetsPage()
        case .system: SetupPage(onScreen: model.onScreen, section: $model.setupSection)
        case .activity: ActivityPage(onScreen: model.live)
        case .upkeep:
            if section == .reports { ReportsPage(open: model.reportPick).onDisappear { model.reportPick = nil } }
            else { UpkeepPage { id in model.go(AppPlace(.reports)); model.reportPick = id } }
        case .stats: StatsPage(onScreen: model.live) { model.go($0) }
        case .clipboard: ClipboardSettingsView(more: section == .clipboardMore)
        case .captures:
            if section == .captureHistory { CaptureHistoryPage() } else { CapturesPage(recording: section == .recording, more: section == .capturesMore) }
        case .snippets: SnippetsSettingsView()
        case .notes: NotesPage(onScreen: model.onScreen)
        case .files:
            switch section {
            case .fileSearch: KitPage { FileSearchBlock(settings: .shared) }
            case .duplicates: DuplicatesView()
            case .folders: FolderDesignsView()
            default: ConvertPage()
            }
        case .install:
            switch section {
            case .webApps: WebAppsSettingsView()
            case .installMore: InstallMorePage()
            default: CataloguePage(category: model.catalogueCategory, search: InstallSearcher.search)
            }
        case .openWith: OpenWithPage(more: section == .openWithMore)
        case .configs: if section == .agents { InstructionsPage() } else { ConfigsPage() }
        case .repos: ReposPage(start: .init(repo: model.repoPick)).id(model.repoOpens)
        case .fonts: FontsPage(getMore: { model.go(AppPlace(.catalogue)); model.catalogueCategory = CataloguePage.fonts })
        case .general: GeneralPage(more: section == .pilotMore)
        case .ai:
            switch section {
            case .aiSetup: AISetupPage()
            case .aiMore: AISetupPage(more: true)
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
