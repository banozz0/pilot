import AppKit
import Observation
import OSLog
import PilotCore
import SwiftUI

let mlog = Logger(subsystem: "dev.banozz.pilot", category: "menu")

/// The Hyper+Space menu (stories 20, 74, 76 and 77, wireframe wo-nZ-ZEKkY sections 1, 2, 5 to 7): a non-activating
/// panel (makePanel says why) with one search field over MenuNavigator's tree. Apps come from the application folders as the app picker lists
/// them, actions from the registry; windows from the tiler as the menu opens and files from Pilot's file index as Sven types
/// arrive after it shows. Styled as the app window is (PanelStyle, card agent-bo-95422727).
@MainActor
final class PilotMenu {
    static let shared = PilotMenu()
    private var panel: NSPanel?
    /// How many times the menu has opened since launch: onboarding's Try it ticks when it grows.
    private(set) var opens = 0
    private var model: MenuModel?
    private var keyMonitor: Any?
    /// The default browser and its engine for Search the web (WebSearchReader), and what it was read for: read again only
    /// when the default browser or its settings file changed.
    private var webSearch: WebSearchReader.Choice?
    private var webSearchStamp: String?
    /// Keeps the window at the face's size, and Line's union while it morphs (MenuSizer).
    private var sizer: MenuSizer?
    /// Line: Escape out of Cmd+K's actions gave the search field the keyboard back with its text selected; the next key
    /// that goes on to the field collapses the selection to a caret after the text first (beforeTyping).
    private var caretPending = false
    private var resignObserver: NSObjectProtocol?
    /// The app Sven was in: an action runs on its windows, so it gets focus back first.
    private var previousApp: NSRunningApplication?
    /// Set while the panel is a picker (`pick`): Return hands the row here instead of running it.
    private var onPick: ((MenuEntry) -> Void)?
    /// A picker closed without a pick (Escape, a click away); and whether its rows may be logged by title: not for
    /// Bitwarden's logins (card agent-bo-95422814).
    private var onCancel: (() -> Void)?
    private var logPicks = true
    /// What fills a live picker while it is open (pick(live:)).
    private var source: (any MenuSource)?
    /// Install's search for the current text, started once typing pauses (InstallSearcher, N9).
    private var installSearch: Task<Void, Never>?
    /// Search rows are listed, so leaving the search clears them; otherwise a keystroke leaves the model untouched.
    private var installShown = false
    /// The GIFs folder's pictures, read each time Stickers and GIFs opens.
    private var stickerFiles: [StickerFile] = []
    /// GIPHY in Stickers and GIFs (story 164): its key, read off the main thread as the branch opens; what the last
    /// search found for which text, with where its next page starts; the search under way, and the next page's.
    private var giphyKey = GiphyKeyState.reading
    private var giphyFound: (query: String, kind: Giphy.Kind, gifs: [WebGIF], next: Int?)?
    private var giphySearch: Task<Void, Never>?
    private var giphyPage: Task<Void, Never>?
    /// Activity's reads while it shows (watchActivity).
    private var activityWatch: Task<Void, Never>?
    /// The translation for the current text in the Translate branch, started once typing pauses (Translate).
    private var translation: Task<Void, Never>?
    /// Apple's on-device translator, one translation at a time, the newest text winning; kept so its model stays warm.
    private let translator = TranslateRunner(translator: AppleTranslator())
    /// The exchange rates the calculator answers money with (RatesStore, card agent-bo-95423047).
    private var rates: RateState?
    /// Remove's rows, kept between menus until Homebrew's folders change (InstallModule.removeStamp).
    private var removeRows: (stamp: [Date?], rows: [RemoveRow])?
    private var removeLoad: Task<Void, Never>?
    /// Whether the kept rows' sizes were all measured; a closed menu cuts a measure short.
    private var measured = false
    /// The Scripts folder's scripts, read as the menu opens; the root's answers fill their arguments from them.
    private var scripts: [ScriptCommand] = []
    /// The Extensions folder's extensions, read as the menu opens; the root's answers find a command's keyword in them.
    private var extensions: [Extension] = []
    /// Update's rows, kept between menus (InstallModule.updates).
    private var updateRows: [UpdateRow]? { InstallModule.updates.current }
    /// How many updates Update's last read listed, and when: the Rail's Waiting shows it for an hour, since Update's rows
    /// are read only when Update opens.
    private var updatesSeen: (count: Int, at: Date)?
    /// The wait for Update's check; a closed menu drops what it brings, and the check carries on (UpdateChecker).
    private var updateLoad: Task<Void, Never>?
    /// Whether the App Store's command line was there as Update opened; without it Update offers Install mas.
    private var masInstalled = true
    /// The switches read again after Space flipped one (toggle); a newer flip replaces it, so a burst reads once.
    private var switchRead: Task<Void, Never>?
    /// The wait for Clean's preview; a closed menu drops what it brings, and Mole's run carries on (CleanPreviewer).
    private var cleanLoad: Task<Void, Never>?
    /// Update lists casks that update themselves only when this is on (PilotSettings).
    private var includeSelfUpdating: Bool {
        get { Engine.shared?.settings.updateSelfUpdatingCasks ?? false }
        set { Engine.shared?.settings.updateSelfUpdatingCasks = newValue }
    }
    /// Where the picks live; a test gives its own.
    var frecencyStore = FrecencyStore.standard
    /// The picks so far (story 75), read from disk once; nil when the file does not read, so a pick never overwrites it.
    private(set) lazy var frecency: Frecency? = {
        do { return try frecencyStore.load() } catch {
            mlog.error("menu: frecency not read, ranking without it: \(error, privacy: .public)")
            return nil
        }
    }()

    /// Runs after the tap callback returns: listing the apps reads every bundle, too slow for the tap. `branch` opens
    /// the menu inside it (Omarchy's apps menu).
    func toggle(branch: MenuBranch? = nil) {
        DispatchQueue.main.async { self.toggleNow(branch: branch) }
    }

    /// The branch on screen, nil when the menu is closed or at its root: Clean's rows say a preview ended, so no tip
    /// is needed then (card agent-bo-95423002).
    var branch: MenuBranch? { model?.nav.branch }

    /// Where the menu stood while one of its rows runs (card agent-bo-95423020): a picker or the clipboard panel that row
    /// opens, at once or from a task it starts, reads it, so Escape there reopens the menu one level up, not nothing.
    @TaskLocal static var origin: MenuNavigator.Spot?
    /// Where a picker opens in place of the menu's own spot, in AppKit's coordinates: the pointer, for Hyper + right-click
    /// on a file (story 199), and so for a picker one of its rows opens (Convert to…, Open With…).
    @TaskLocal static var anchor: CGPoint?

    /// A picker over `rows` in the same panel, e.g. the lazygit repos: Return closes it and hands the row to `then`.
    func pick(_ rows: [MenuEntry], title: String? = nil, logTitles: Bool = true, cancelled: (() -> Void)? = nil,
              then: @escaping (MenuEntry) -> Void) {
        let back = Self.origin, at = Self.anchor
        DispatchQueue.main.async {
            if self.panel != nil { self.close(restoreFocus: false) }
            self.show(MenuNavigator(list: rows, title: title, back: back), pick: then, at: at)
            self.onCancel = cancelled
            self.logPicks = logTitles
            mlog.notice("menu: picker \(title ?? "", privacy: .public) shown, \(rows.count) rows")
        }
    }

    /// A picker whose rows `source` fills as Sven types (an extension's list, card agent-bo-95423243): it opens empty
    /// under `title`, the source hears the search, the empty one first, its rows reach the picker while it is open, and
    /// it is closed with the picker, however that closes.
    func pick(live title: String, source: any MenuSource) {
        let back = Self.origin, at = Self.anchor
        DispatchQueue.main.async {
            if self.panel != nil { self.close(restoreFocus: false) }
            self.show(MenuNavigator(list: [], title: title, back: back, live: true), at: at)
            self.logPicks = false
            self.attach(source, search: true)
            mlog.notice("menu: live picker \(title, privacy: .public) shown")
        }
    }

    /// `source` fills the open live picker: its rows replace the picker's, it hears the search (asked now when `search`).
    private func attach(_ source: any MenuSource, search: Bool) {
        guard let model else { return source.close() }
        self.source = source
        source.show = { [weak model] in model?.nav.replaceList($0) }
        model.onQuery = { source.search($0) }
        if search { source.search(model.nav.query) }
    }

    /// What the live picker's source made of a pick (card agent-bo-95423244): close the panel and run, push a view in
    /// it, or nothing (the error row).
    private func follow(_ pick: MenuPick) {
        switch pick {
        case .close(let then):
            // The app Sven was in comes back first, so a paste or a Pilot action lands there (Moody ZLUB3C6kGZU).
            let previous = previousApp
            close(restoreFocus: true)
            runWhenFrontmost(previous, "extension action", then)
        case .push(let title, let next):
            guard let model, let current = source else { return next.close() }
            current.show = { _ in }
            var nav = MenuNavigator(list: [], title: title, live: true)
            nav.query = next.opening
            model.push(nav, over: current)
            attach(next, search: true)
            mlog.notice("menu: pushed \(title, privacy: .public)")
        case .stay: break
        case .keep(let clear, let back, let run):
            if back { _ = pop() }
            guard let model, let shown = source else { return }
            let ran = run()
            Task { [weak self, weak model] in
                await ran?.value
                // Sven may have gone on to another view or closed the menu meanwhile.
                guard let self, let model, self.source === shown, self.model === model else { return }
                // Emptied, the list is asked at once below, Pilot's filter too; the newer ask cancels the search's.
                if clear { model.nav.query = "" }
                let at = model.nav.selection
                let kept = await shown.refresh(keeping: model.nav.selected)
                guard self.source === shown else { return }
                // A row that moved within its section stays selected (⌥↑); otherwise the place does, so Return walks
                // down the list (To-do: done, then the next).
                model.nav.point(at: kept.flatMap { t in model.nav.rows.firstIndex { $0.id == t } } ?? min(at, max(model.nav.rows.count - 1, 0)))
            }
        }
    }

    /// Escape in a pushed view: its source stops and the view under it comes back as it was, its search kept; false when
    /// nothing was pushed.
    private func pop() -> Bool {
        guard let model, let below = model.pop() else { return false }
        source?.close()
        attach(below, search: false)
        mlog.notice("menu: back to \(model.nav.title ?? "the list", privacy: .public)")
        return true
    }

    /// The menu again where `spot` stood: Escape in a picker or the clipboard panel a menu row opened.
    func reopen(_ spot: MenuNavigator.Spot) {
        if panel != nil { close(restoreFocus: false) }
        // Back from a cancelled confirm nothing ran, so Update's kept rows hold and the row Sven was on is listed at once.
        toggleNow(branch: spot.branch)
        model?.nav.go(to: spot)
        mlog.notice("menu: back to \(spot.branch?.rawValue ?? "the root", privacy: .public)")
    }

    private func toggleNow(branch: MenuBranch?) {
        if panel != nil { close(restoreFocus: true); return }
        guard let engine = Engine.shared else { return }
        scripts = ScriptCommand.find()
        let found = Extension.find()
        for broken in found.broken { mlog.error("menu: extension folder \(broken.folder, privacy: .public) skipped: \(broken.problem.reason, privacy: .public)") }
        extensions = found.extensions
        let entries = Self.entries(engine, scripts: scripts, extensions: extensions)
        var nav = MenuNavigator(entries: entries, branch: branch, frecency: frecency ?? Frecency(), favourites: FavouriteBook.shared.rows,
                                aliases: AliasBook.shared.aliases, root: MenuRootSettings.shared.root)
        nav.fileFilters.hidden = FileSearchSettings.shared.showHidden
        show(nav)
        model?.onFileQuery = { [weak self] in self?.searchFiles($0) }
        model?.onQuery = { [weak self] in
            self?.searchEmoji($0)
            self?.provideEmojiGrid($0)
            self?.model?.nav.provideSettings($0)
            self?.searchStickers($0)
            self?.searchGiphy($0)
            self?.answer($0)
            self?.searchInstall($0)
            self?.translate($0)
            self?.provideSnippets($0)
        }
        model?.onBranch = { [weak self] in self?.branchOpened($0) }
        model?.onRowShown = { [weak self] in self?.moreGiphy(near: $0) }
        readWebSearch()
        model?.recent = MenuModel.recent(entries, picks: frecency ?? Frecency())
        let updates = updatesSeen.flatMap { $0.at.timeIntervalSinceNow > -3600 ? $0.count : nil }
        model?.waiting = MenuModel.waiting(updates: updates, clean: CleanModule.previewer.ready?.total)
        branchOpened(branch)
        provideWindows(engine)
        provideMenuItems(listed: entries)
        provideFinderSelection()
        refreshRates()
        // The file index reads its saved index now, so it answers by the time Sven reaches the Files view.
        FileIndex.shared.start()
        // Reads new images' words into the text index, at most once in 5 minutes.
        ImageTextReader.shared.menuOpened()
        Task.detached(priority: .utility) { _ = Self.emoji }
        let apps = entries.count(where: { $0.kind == .app }), running = entries.count(where: \.running)
        let at = model.map { m in "\(m.nav.branch == nil ? "root" : m.nav.path.map(\.rawValue).joined(separator: "/")) (\(m.nav.rows.count) rows), " } ?? ""
        mlog.notice("menu shown \(at, privacy: .public)\(apps) apps (\(running) running), \(entries.count - apps) actions, over \(self.previousApp?.bundleIdentifier ?? "?", privacy: .public)")
    }

    /// `at`: the panel's top left (place(at:)) in place of the menu's own spot.
    private func show(_ nav: MenuNavigator, pick: ((MenuEntry) -> Void)? = nil, at: CGPoint? = nil) {
        opens += 1
        previousApp = NSWorkspace.shared.frontmostApplication
        onPick = pick
        let model = MenuModel(nav: nav)
        model.layerKeys = Engine.shared?.settings.layerKeys ?? [.capsLock]
        model.ownKey = Engine.shared?.binds.store.trigger(for: AppsModule.menuID)?.label
        model.frontApp = previousApp?.localizedName
        model.translatePair = Engine.shared?.settings.translatePair ?? .standard
        model.openEmojiCategories = { [weak self, weak model] in
            guard let self, let model else { return }
            model.chip = .emojiCategories(EmojiGrid.categories(in: Self.emoji), mostUsed: EmojiGrid.mostUsed(in: Self.emoji, picks: frecency ?? Frecency()).count,
                                          picked: model.emojiCategory)
        }
        model.onClick = { [weak self] in _ = self?.apply($0, from: $1) }
        // Toybox keeps its own menu (ToyMenu); Instrument draws the Rail or Classic as Look says.
        model.layout = Look.shared.style == .toybox ? .classic : Look.shared.menuLayout
        model.goTo = MenuRootSettings.shared.root.shown()
        self.model = model
        let p = Self.makePanel(model)
        panel = p
        caretPending = false
        sizer = MenuSizer(panel: p, model: model)
        if let at { place(at: at) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        }
        // While the Cmd+K actions show, their filter keeps the keyboard.
        keyMonitor = HUD.showSearchPanel(p, handle: { [weak self] code, flags, characters in self?.handle(code, flags, characters) == true },
                                         keepsSearch: { [weak self] in self?.model?.nav.actions == nil },
                                         beforeTyping: { [weak self] in self?.beforeTyping() }, log: { mlog.notice("menu: \($0, privacy: .public)") })
        mlog.notice("menu: panel key \(p.isKeyWindow)")
    }

    /// The panel's top left at `point`, as a context menu opens, kept on that point's screen: moved left as far as its
    /// width needs and up as far as the tallest list does, since it grows down from its top edge (MenuSizer).
    private func place(at point: CGPoint) {
        guard let panel, let f = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else { return }
        let tallest = MenuPanelSize.instrument(.wide, rows: 0, headings: 0, full: true).height
        let x = min(max(point.x, f.minX), f.maxX - panel.frame.width)
        panel.setFrameTopLeftPoint(CGPoint(x: x, y: min(max(point.y, f.minY + tallest), f.maxY)))
    }

    /// The file of the row under `point` (AppKit's coordinates) while the menu is open, never the keyboard's selection;
    /// nil over any other row, a heading or a gap. Hyper + right-click asks it from the mouse tap, so it reads only the
    /// model.
    func file(at point: CGPoint) -> URL? {
        guard let panel, let model, panel.frame.contains(point), case .file(let path)? = model.underPointer,
              model.nav.rows.contains(where: { $0.target == .file(path) }) else { return nil }
        return URL(filePath: path)
    }

    /// The panel resized round a face of `face`, its top edge and centre put.
    static func fit(_ panel: NSPanel, face: CGSize) {
        let size = PopSurface.window(face, (panel as? KeyPanel)?.margins ?? NSEdgeInsetsZero)
        let f = panel.frame
        guard f.size != size else { return }
        panel.setFrame(CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// The menu's panel takes the keyboard without activating Pilot, as the clipboard panel does: it is key at once and
    /// its search field gets the letters. An activating panel waited on Pilot's activation, which is asynchronous (and
    /// cooperative since macOS 14), so the panel was not key when it showed and typed letters fell through, while the
    /// local monitor still saw Return and the arrows (card agent-bo-95422762).
    static func makePanel(_ model: MenuModel) -> NSPanel {
        // Line draws its own face, which morphs inside the window (LineMorph); the others take the panel's.
        HUD.makePanel(MenuView(model: model), surface: .menu, ownFace: model.layout == .line && Look.shared.style == .instrument)
    }

    /// The apps as the app picker lists them and the actions as the Binds screen does (MenuEntries); an app runs when
    /// it is in runningApplications as the menu opens, with a window or without.
    static func entries(_ engine: Engine, scripts: [ScriptCommand], extensions: [Extension]) -> [MenuEntry] {
        let roleApps = AppsModule.roleApps()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let installed = Extension.menu(extensions, catalogue: ExtensionCatalogueMenu.actionID), apps = AppsModule.installedApps()
        let built = MenuEntries.build(apps: apps, actions: Extension.actions(ScriptCommand.actions(engine.bindActions, with: scripts), with: extensions),
                                 store: engine.binds.store, roleApps: roleApps, menu: AppsModule.menuID, openID: AppsModule.openID(bundle:),
                                 running: running, extras: [MenuLayout.system("Sound"): SystemModule.outputRows(excluding: HiddenRows.shared.ids[.soundOutput] ?? []),
                                                         .config: ConfigsModule.menuRows()].merging(installed.extras) { mine, _ in mine },
                                 branches: installed.branches,
                                 switches: SystemModule.switchStates(), fills: ScriptCommand.fills(scripts))
        // Each app's own commands (P38), from the drive catalogue.
        return MenuEntries.commands(built, catalogue: DriveModule.catalogue, installed: Set(apps.map(\.bundle))) + InstallModule.menuEntries()
            + MenuEntries.quicklinks(QuicklinkBook.shared.links)
    }

    /// Every window on every workspace, read once as the menu opens (the tiler's `list-windows --all`).
    private func provideWindows(_ engine: Engine) {
        guard let model else { return }
        let runner = engine.observers.tiler.runner
        Task { [weak self] in
            do {
                let windows = try await runner.windows(.all)
                guard self?.model === model else { return }
                model.windows = windows
                model.nav.provide(.window, MenuEntries.windows(MenuEntries.byWorkspace(windows), excluding: Bundle.main.bundleIdentifier))
                mlog.notice("menu: \(windows.count) windows listed")
            } catch {
                mlog.error("menu: windows not listed, \(error, privacy: .public)")
            }
        }
    }

    /// The menu items of the app Sven was in (MenuItemSearch, card agent-bo-95423046), read off the main thread as the
    /// menu opens, so typing finds them; never Pilot's own. A drive route already listed as a bound action keeps its one row.
    private func provideMenuItems(listed: [MenuEntry]) {
        guard let model, let app = previousApp, let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier, started = Date()
        let bound = Set(listed.compactMap { if case .action(let id) = $0.target, id.hasPrefix("drive.menu:") { id } else { nil } })
        Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                MenuItemSearch.entries(AXMenuItems.read(pid: pid), bundle: bundle, except: bound)
            }.value
            guard let self, self.model === model else { return }
            model.nav.provide(.menuItem, rows)
            mlog.notice("menu: \(rows.count) menu items for \(bundle, privacy: .public) in \(Int(-started.timeIntervalSinceNow * 1000)) ms")
        }
    }

    /// Dress selected folders and Reset folder icons while Finder is in front with folders selected (P43), the selection
    /// read off the main thread.
    private func provideFinderSelection() {
        guard let model, previousApp?.bundleIdentifier == DesktopIcons.finder else { return }
        Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { FolderDesigns.rows(FolderDesigns.finderSelection()) }.value
            guard self?.model === model else { return }
            model.nav.provide(.selection, rows)
        }
    }

    /// Files whose name holds the search, from Pilot's file index, best first; only in the Files view (Search files
    /// picked, or Tab to Files; card agent-bo-95422968), from the second typed character (MenuNavigator.fileQuery), with
    /// its filters (N5). Each keystroke or filter step there replaces the search before it. Under the name hits, images
    /// whose words hold the search, from the text index (Homy-style Files), which answers while the helper is stopped.
    private func searchFiles(_ ask: FileSearch.Ask?) {
        guard let model else { return }
        guard let ask else {
            FileIndex.shared.cancel()
            return model.nav.provide(.file, [])
        }
        FileIndex.shared.search(ask) { [weak self] files in
            guard let self, self.model === model else { return }
            guard let files else { return model.nav.provide(.file, [MenuEntries.allowFullDiskAccess(search: ask.text)]) }
            // More than are listed, so the filters still leave ten.
            let text = ImageTextReader.shared.search(ask.text, limit: FileSearch.textHits * 4).map { ($0.path, $0.modified, $0.words) }
            let rows = MenuEntries.files(files, text: text, ask: ask, home: NSHomeDirectory())
            model.nav.provide(.file, rows)
            mlog.notice("menu: \(files.count) files and \(rows.count - files.count) by their words for \"\(ask.text, privacy: .public)\"\(ask.filters == FileFilters() ? "" : " filtered", privacy: .public)")
        }
    }

    /// Emoji whose name or a keyword starts with each typed word, at the root only (EmojiSearch, card agent-bo-95422931).
    private func searchEmoji(_ query: String) {
        guard let model else { return }
        model.nav.provide(.emoji, model.nav.branch == nil ? EmojiSearch.entries(for: query, in: Self.emoji) : [])
    }
    /// Trigger › Emoji's grid (P39): the most used (P52), then gemoji's categories, or what the words find; only the category
    /// ⌘P picked.
    private func provideEmojiGrid(_ query: String) {
        guard let model, model.nav.branch == .emoji else { return }
        // Most used repeats emoji the categories hold: only Line's grid draws cells by place; another layout's list
        // keys its rows by target, so it gets none.
        let picks = model.hasLineChips ? frecency ?? Frecency() : Frecency()
        model.nav.provide(.emoji, home: .emoji, EmojiGrid.entries(for: query, in: Self.emoji, picks: picks, category: model.emojiCategory))
    }

    /// A sum, a conversion, money, a time zone or a date (Calculator, cards agent-bo-95422933 and agent-bo-95423047) or a
    /// reminder (Reminders, card agent-bo-95422935) typed at the root answers as the first row (RootAnswers); Ask AI and
    /// Search the web follow every root search's best match (MenuNavigator.fallbacks).
    private func answer(_ query: String) {
        guard let model else { return }
        model.nav.provide(.answer, model.nav.branch == nil
                          ? RootAnswers.entries(for: query, now: .now, links: QuicklinkBook.shared.links, scripts: scripts,
                                                extensions: extensions, rates: rates) : [])
    }

    /// The default browser's engine for the Search the web row, read off the main thread; the row names it once read.
    private func readWebSearch() {
        let browser = WebSearchReader.defaultBrowser(), known = webSearchStamp, kept = webSearch
        Task { [weak self] in
            let (stamp, choice) = await Task.detached(priority: .userInitiated) { () -> (String, WebSearchReader.Choice) in
                let stamp = WebSearchReader.stamp(browser: browser)
                if stamp == known, let kept { return (stamp, kept) }
                return (stamp, WebSearchReader.read(browser: browser))
            }.value
            guard let self, let model = self.model else { return }
            self.webSearch = choice
            self.webSearchStamp = stamp
            model.nav.webVia = choice.via
        }
    }

    /// The cached rates at once, then fetched again when they are 12 hours old; a sum typed meanwhile is answered again.
    private func refreshRates() {
        Task { [weak self] in
            self?.rates = await RatesStore.standard.state
            let fresh = await RatesStore.standard.refresh()
            guard let self, fresh != rates else { return }
            rates = fresh
            mlog.notice("menu: rates from \(fresh?.rates.date ?? "nowhere", privacy: .public)\(fresh?.offline == true ? ", offline" : "")")
            if let query = model?.nav.query { answer(query) }
        }
    }
    /// Inside Trigger → Stickers and GIFs (card agent-bo-95423130): the GIFs folder's pictures read as the branch opens,
    /// narrowed by what is typed.
    private func searchStickers(_ query: String) {
        guard let model, model.nav.branch == .stickers else { return }
        var rows = Stickers.entries(for: query, files: stickerFiles)
        // GIPHY's rows, once the key is read: its answer for this very text, or the row that asks for a key.
        switch giphyKey {
        case .reading: break
        case .missing, .refused: rows.append(Giphy.keyRow(refused: giphyKey == .refused, query: query))
        case .ready:
            if let found = giphyFound, found.query == Self.typed(query), found.kind == model.giphyKind {
                rows += Giphy.entries(found.gifs, query: query)
            }
        }
        model.nav.provide(.sticker, home: .stickers, rows)
    }
    enum GiphyKeyState: Equatable { case reading, missing, refused, ready(String) }
    private static func typed(_ query: String) -> String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// GIPHY's GIFs or stickers (the bar's tab) for the text in Stickers and GIFs (story 164), trending before anything is
    /// typed, once typing pauses for 0.3 s: the search, then every new preview, before the rows show, so none lands bare. A
    /// newer keystroke, leaving the branch or closing the menu cancels it and its requests; no key, nothing asked.
    private func searchGiphy(_ query: String) {
        giphySearch?.cancel()
        guard let model, model.nav.branch == .stickers, case .ready = giphyKey else { return }
        let typed = Self.typed(query), kind = model.giphyKind
        guard giphyFound?.query != typed || giphyFound?.kind != kind else { return }
        giphyPage?.cancel()
        giphySearch = fetchGiphy(typed, kind: kind, offset: 0)
    }

    /// GIPHY's next page once the list is scrolled to within `Giphy.pageAhead` rows of its end (row `index` shown), up
    /// to `Giphy.most` results: appended after the shown ones, a GIF already listed left out, the selection kept.
    private func moreGiphy(near index: Int) {
        guard let model, model.nav.branch == .stickers, index >= model.nav.rows.count - Giphy.pageAhead,
              let found = giphyFound, let next = found.next, found.query == Self.typed(model.nav.query), found.kind == model.giphyKind,
              giphyPage == nil else { return }
        giphyPage = fetchGiphy(found.query, kind: found.kind, offset: next)
    }

    /// One page of GIPHY's answer, then every new preview, before the rows show, so none lands bare; the first page
    /// (`offset` 0) after typing pauses for 0.3 s replaces what was found, a later one is added to it; a later one that
    /// fails ends the paging, so scrolling never asks again.
    private func fetchGiphy(_ typed: String, kind: Giphy.Kind, offset: Int) -> Task<Void, Never>? {
        guard let model, case .ready(let key) = giphyKey else { return nil }
        let rating = PilotFolders.shared.giphyRating
        return Task { [weak self] in
            defer { if offset > 0, let self, self.model === model { giphyPage = nil } }
            if offset == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            do {
                let page = try await Giphy.search(typed, key: key, kind: kind, rating: rating, offset: offset)
                let shown = Set(offset > 0 ? self?.giphyFound?.gifs.map(\.id) ?? [] : [])
                let gifs = page.gifs.filter { !shown.contains($0.id) }
                let previews = await Giphy.previews(gifs.filter { AppsModule.webThumbnail($0.id) == nil })
                guard !Task.isCancelled, let self, self.model === model else { return }
                AppsModule.keepWebThumbnails(previews)
                // A new search drops the pages the last one was scrolled to, as closing the menu does.
                if offset == 0 { AppsModule.dropWebThumbnails(giphyFound?.gifs.dropFirst(Giphy.limit).map(\.id).filter { id in !gifs.contains { $0.id == id } } ?? []) }
                giphyFound = (typed, kind, (offset > 0 ? giphyFound?.gifs ?? [] : []) + gifs, page.next)
                mlog.notice("menu: GIPHY lists \(gifs.count) \(kind.rawValue, privacy: .public) from \(offset) for \"\(typed, privacy: .public)\", \(previews.count) new previews")
            } catch Giphy.Failure.refused {
                guard let self, self.model === model else { return }
                giphyKey = .refused
                mlog.error("menu: GIPHY refused the key")
            } catch {
                guard !Task.isCancelled else { return }
                if offset > 0, let self, self.model === model { giphyFound?.next = nil }
                mlog.error("menu: GIPHY search failed: \(Giphy.describe(error), privacy: .public)")
                return
            }
            self?.searchStickers(model.nav.query)
        }
    }
    /// gemoji's list in Resources, read off the main thread when the menu first opens, so the first keystroke never waits.
    nonisolated private static let emoji = BundledJSON.load("emoji", log: mlog, empty: [Emoji]()) { try EmojiSearch.parse($0) }

    /// Inside Install or Search packages, once typing pauses for 0.3 s (N9): every source at once (InstallSearcher, a
    /// second or two; a repeat is cached), its rows grouped under their sources after the catalogue's own matches; a
    /// newer keystroke cancels the older search, its requests and its brew processes.
    private func searchInstall(_ query: String) {
        installSearch?.cancel()
        guard let model else { return }
        guard MenuLayout.searchesInstall(model.nav.branch), InstallSearch.Query(query) != nil else {
            if installShown { model.nav.provide(.package, home: .homebrew, []) }
            installShown = false
            return
        }
        // Searching shows at once, before the pause, so the list never says Nothing matches while sources are asked.
        let q = InstallSearch.Query(query)!
        model.nav.provide(.package, home: .homebrew, MenuEntries.searching(q, waiting: InstallSearcher.sources))
        installShown = true
        installSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Read once the typing pauses, not per keystroke.
            let hint = Helper.searchHint(installed: Helper.installed())
            // Each source's rows land as it answers, the rest still named on the Searching row.
            // A newer keystroke or a closed menu cancels this task, so a late answer lands nowhere.
            let found = await InstallSearcher.search(query) { [weak model] progress in
                await MainActor.run {
                    guard !Task.isCancelled, let model else { return }
                    model.nav.provide(.package, home: .homebrew, MenuEntries.found(progress.groups, query: q, waiting: progress.waiting, hint: hint))
                }
            }
            guard !Task.isCancelled, let found, let self, self.model === model else { return }
            let rows = MenuEntries.found(found.groups, query: found.query, hint: hint)
            model.nav.provide(.package, home: .homebrew, rows)
            mlog.notice("menu: Install's search lists \(rows.count) for \"\(query, privacy: .public)\": \(rows.prefix(3).map(\.title).joined(separator: ", "), privacy: .public)")
        }
    }

    /// Inside Trigger → Translate, or at the root after "tr " or "translate " (card agent-bo-95422932), once typing pauses
    /// for 0.25 s: Apple's on-device translation by Setup's language pair; a newer keystroke cancels the older translation.
    private func translate(_ query: String) {
        translation?.cancel()
        guard let model else { return }
        // The answer belongs to the text it translated: any change drops it, so leaving and reopening Translate, or
        // typing on, never shows (or copies) an old translation.
        model.nav.provide(.answer, home: .translate, [])
        let atRoot = model.nav.branch == nil
        if atRoot, Translate.text(after: query)?.isEmpty == true { Task { await translator.warm() } }
        // The root keeps detecting (Q291); Translate's line may have picked From, and its chips show the source.
        let from = atRoot ? nil : model.translateFrom
        guard let text = Translate.query(for: query, in: model.nav.branch) else { return model.translateSource = from }
        let pair = model.translatePair
        if !atRoot { model.translateSource = from }
        translation = Task { [weak self, translator] in
            try? await Task.sleep(for: .milliseconds(250))
            // The chips' source, read once typing pauses, as the translation reads it.
            if !atRoot, from == nil, text.count >= MenuNavigator.minimumQuery { model.translateSource = Translate.direction(for: text, pair: pair).source }
            guard !Task.isCancelled, let rows = await translator.rows(for: text, pair: pair, from: from) else { return }
            guard !Task.isCancelled, let self, self.model === model else { return }
            model.nav.provide(.answer, home: .translate, rows)
            mlog.notice("menu: translate \(text.count) characters\(atRoot ? " at the root" : ""), \(rows.first?.detail ?? "nothing", privacy: .public)")
        }
    }

    /// The providers that fill a branch as it opens: Remove's and Update's (from any of their categories too, where Escape
    /// back from a confirm lands), Clean's rows; Translate warms its model.
    private func branchOpened(_ branch: MenuBranch?) {
        // The tools a scan's kinds follow, looked for once per menu.
        if let model, model.tools == nil, branch?.browsed == .remove || branch?.browsed == .update || MenuLayout.searchesInstall(branch) {
            model.tools = MenuScan.tools()
        }
        if branch?.browsed == .remove { loadRemove() }
        if branch?.browsed == .update { loadUpdate() }
        if branch == .clean { loadClean() }
        if branch == .translate {
            model?.nav.provide(.answer, home: .translate, [])
            Task { await translator.warm() }
        }
        if branch == .emoji { provideEmojiGrid(model?.nav.query ?? "") }
        if branch == .reminders { model?.nav.provide(.action, home: .reminders, Reminders.rows(ReminderScheduler.shared.list, now: .now)) }
        if branch != .stickers { giphySearch?.cancel(); giphyPage?.cancel(); giphyPage = nil }
        if branch == .activity {
            watchActivity()
        } else {
            activityWatch?.cancel()
            activityWatch = nil
            // A force quit armed in Activity is never carried back into it.
            model?.forceArmed = nil
            model?.activityNote = nil
        }
        if branch == .stickers, let model {
            model.nav.provide(.file, home: .stickers, [Stickers.folderRow])
            searchStickers(model.nav.query)
            // The GIPHY key off the main thread, as the Keychain may be slow to answer; then trending or the search.
            giphyKey = .reading
            Task { [weak self] in
                let key = await Task.detached { Giphy.key() }.value
                guard let self, self.model === model, model.nav.branch == .stickers else { return }
                giphyKey = key.map(GiphyKeyState.ready) ?? .missing
                searchStickers(model.nav.query)
                searchGiphy(model.nav.query)
            }
            // Read off the main thread with each new picture's thumbnail, as the folder can be big; made first, so Open
            // the GIFs folder has one to show.
            let known = AppsModule.thumbnailPaths
            Task { [weak self] in
                let (files, thumbnails) = await Task.detached {
                    try? FileManager.default.createDirectory(at: Stickers.folder, withIntermediateDirectories: true)
                    let files = Stickers.files(in: Stickers.folder)
                    let thumbnails = files.filter { !known.contains($0.path) }.compactMap { f in Stickers.thumbnail(of: f.path).map { (f.path, $0) } }
                    return (files, thumbnails)
                }.value
                guard let self, self.model === model else { return }
                AppsModule.keepThumbnails(thumbnails)
                stickerFiles = files
                searchStickers(model.nav.query)
            }
        }
        if branch == .notes { model?.nav.provide(.action, home: .notes, Notes.rows(NotesPanel.shared.notes())) }
        if branch == .snippets { provideSnippets(model?.nav.query ?? "") }
        if branch == .capture { provideCaptures() }
    }

    /// The Capture branch's newest captures (CP10), read off the main thread; Return opens one in the editor.
    private func provideCaptures() {
        let folder = CaptureSettingsStore.shared.folder(.capture)
        Task { [weak self] in
            let listed = await Task.detached { CaptureFiles.recent(captures: folder, recordings: folder, limit: 10) }.value
            guard let self, self.model?.nav.branch == .capture else { return }
            self.model?.nav.provide(.file, home: .capture, CaptureFiles.menuRows(listed))
        }
    }

    /// Snippets' rows (card agent-bo-95423044), again as Sven types: one that takes an argument reads it from the search.
    private func provideSnippets(_ query: String) {
        model?.nav.provide(.snippet, home: .snippets, MenuEntries.snippets(SnippetLibrary.shared.snippets, query: query))
    }

    /// A typed keyword whose snippet takes an argument: the menu opens on Snippets with its name typed, so Sven types
    /// the argument and Return pastes it into the app he was in.
    func askArgument(for snippet: Snippet) { open(typing: "\(snippet.name) ", in: .snippets) }

    /// The menu, opened afresh in `branch` (the root by default) with `query` typed: a bound script asking for its
    /// arguments (card agent-bo-95423048) and a snippet's keyword asking for its argument.
    func open(typing query: String, in branch: MenuBranch? = nil) {
        DispatchQueue.main.async {
            if self.panel != nil { self.close(restoreFocus: false) }
            self.toggleNow(branch: branch)
            self.model?.nav.query = query
        }
    }

    /// Remove's rows, read again only when Homebrew's folders changed since the last read, then shown in the model's order;
    /// their sizes follow (card agent-bo-95423022), measured again when a closed menu cut the last measure short.
    private func loadRemove() {
        let stamp = InstallModule.removeStamp()
        guard removeLoad == nil, let model else { return showRemove() }
        if let cached = removeRows, cached.stamp == stamp {
            showRemove()
            if !measured {
                removeLoad = Task { [weak self] in await self?.measureRemove(cached.rows, stamp: stamp, for: model) }
            }
            return
        }
        removeLoad = Task { [weak self] in
            let read = await InstallModule.removeRows()
            guard !Task.isCancelled, let self, self.model === model else { return }
            guard let rows = read else {
                removeLoad = nil
                return model.failed(in: .remove, "Homebrew's list could not be read. Open Remove again to retry.")
            }
            removeRows = (stamp, rows)
            measured = false
            showRemove()
            let pilot = rows.count(where: \.pilot), needed = rows.count(where: \.needed)
            mlog.notice("menu: Remove lists \(rows.count) (\(pilot) by Pilot, \(needed) needed by others), first: \(rows.first.map(\.name) ?? "-", privacy: .public)")
            await measureRemove(rows, stamp: stamp, for: model)
        }
    }

    /// The sizes, measured while the rows show; a row Sven is on stays selected. Closing the menu cancels the walks.
    private func measureRemove(_ rows: [RemoveRow], stamp: [Date?], for model: MenuModel) async {
        let sized = await InstallModule.measure(rows)
        guard !Task.isCancelled, self.model === model, removeRows?.stamp == stamp else { return }
        removeLoad = nil
        removeRows = (stamp, sized)
        measured = true
        showRemove()
        mlog.notice("menu: Remove measured \(sized.count(where: { $0.size != nil })) of \(sized.count)")
    }

    /// Update's rows from the shared check (InstallModule.updates), kept between menus: brew outdated plain and with
    /// --greedy-auto-updates and uv's outdated tools first, then macOS, the App Store, npm, bun and cargo (story 118),
    /// all read-only. A check left running by a closed menu is joined, not run again.
    private func loadUpdate() {
        let checker = InstallModule.updates
        // Without Homebrew there is no list to read (Q556): Install Homebrew, not a check that can only fail.
        guard Helper.homebrew.path() != nil else { return model?.nav.provide(.package, home: .update, UpdateList.noHomebrew()) ?? () }
        guard updateLoad == nil, let model else { return showUpdate() }
        masInstalled = Helper.mas.path() != nil
        if checker.current != nil { seeUpdates(); showUpdate() }
        guard checker.checking || checker.current == nil else { return }
        let shown = checker.current != nil
        updateLoad = Task { [weak self] in
            if !shown {
                let read = await checker.check()
                guard !Task.isCancelled, let self, self.model === model else { return }
                guard let rows = read else {
                    updateLoad = nil
                    return model.failed(in: .update, "Homebrew's outdated list could not be read. Open Update again to retry.")
                }
                seeUpdates()
                showUpdate()
                logUpdate("Update lists", rows)
            }
            let all = await checker.checked()
            guard !Task.isCancelled, let self, self.model === model else { return }
            updateLoad = nil
            seeUpdates()
            showUpdate()
            logUpdate("Update lists all", all ?? [])
        }
    }

    private func seeUpdates() {
        updatesSeen = (UpdateList.visible(updateRows ?? [], includeSelfUpdating: includeSelfUpdating).count, .now)
    }

    private func logUpdate(_ what: String, _ rows: [UpdateRow]) {
        let shown = UpdateList.visible(rows, includeSelfUpdating: includeSelfUpdating)
        mlog.notice("menu: \(what, privacy: .public) \(shown.count): \(shown.map { "\($0.item.key) \($0.from)→\($0.to)" }.joined(separator: ", "), privacy: .public)")
    }

    private func showUpdate() {
        guard let model, let rows = updateRows else { return }
        model.nav.provide(.package, home: .update, UpdateList.entries(rows, includeSelfUpdating: includeSelfUpdating, masInstalled: masInstalled,
                                                                       recommend: Recommendations.shared.show, icons: InstallModule.catalogueIcons))
    }

    /// Return in Update: a row asks to update it with its exact command (a pinned one asks to unpin instead), Update all
    /// asks with the command for everything outdated but macOS, and the switch flips self-updating casks in or out.
    private func update(_ pick: UpdateList.Pick) {
        // Install Homebrew and Reports have no rows behind them: Update without Homebrew lists only these.
        switch pick {
        case .installHomebrew:
            close(restoreFocus: false)
            return InstallModule.install(.homebrew)
        case .reports:
            close(restoreFocus: false)
            return AppWindowController.shared.open(AppPlace(.reports))
        default: break
        }
        guard let rows = updateRows else { return }
        switch pick {
        case .selfUpdating:
            includeSelfUpdating.toggle()
            mlog.notice("menu: Update \(self.includeSelfUpdating ? "includes" : "leaves out", privacy: .public) apps that update themselves")
        case .all:
            guard let command = UpdateList.all(rows, includeSelfUpdating: includeSelfUpdating) else {
                mlog.notice("menu: Update all with nothing outdated, nothing run")
                let shown = UpdateList.visible(rows, includeSelfUpdating: includeSelfUpdating)
                return HUD.tip(shown.isEmpty ? "Everything is up to date" : "Only macOS updates or pinned formulae left; pick each one")
            }
            close(restoreFocus: false)
            let going = UpdateList.allRows(rows, includeSelfUpdating: includeSelfUpdating)
            return InstallModule.confirm("Update all", command) { InstallModule.runUpdate("Update all", command, rows: going) }
        case .installMas:
            close(restoreFocus: false)
            return InstallModule.install(.mas)
        case .row(let key):
            guard let row = rows.first(where: { $0.item.key == key }),
                  let command = UpdateList.command([row], includeSelfUpdating: true) else { return }
            close(restoreFocus: false)
            let title = "Update \(row.item.name)"
            return InstallModule.confirm(title, command) { InstallModule.runUpdate(title, command, rows: [row]) }
        case .unpin(let key):
            guard let row = rows.first(where: { $0.item.key == key }) else { return }
            close(restoreFocus: false)
            return InstallModule.unpin(row)
        case .installHomebrew, .reports: return
        }
        showUpdate()
    }

    /// Clean's rows: Mole's preview, kept between menus (CleanPreviewer), or Install Mole when it is missing (with
    /// Homebrew when that is missing too).
    private func loadClean() {
        let mole = CleanModule.mole != nil
        if !mole || CleanModule.previewer.ready != nil {
            return showClean(CleanModule.previewer.ready, mole: mole, homebrew: mole || Helper.homebrew.path() != nil)
        }
        guard cleanLoad == nil else { return }
        cleanLoad = Task { [weak self] in
            let preview = await CleanModule.previewer.preview()
            guard !Task.isCancelled, let self else { return }
            cleanLoad = nil
            guard let preview else { return model?.failed(in: .clean, "Mole's preview did not finish. Open Clean again to retry.") ?? () }
            showClean(preview, mole: true)
            mlog.notice("menu: Clean lists \(preview.items.count) items, \(preview.total ?? "no total", privacy: .public)")
        }
    }

    private func showClean(_ preview: CleanPreview?, mole: Bool, homebrew: Bool = true) {
        model?.nav.provide(.action, home: .clean, CleanMenu.entries(preview, mole: mole, homebrew: homebrew))
    }

    private func showRemove() {
        guard let model, let rows = removeRows?.rows else { return }
        model.nav.provide(.package, home: .remove, RemoveList.entries(RemoveList.sorted(rows, model.removeOrder), icons: InstallModule.catalogueIcons))
    }

    private func close(restoreFocus: Bool) {
        FileIndex.shared.cancel()
        FileThumbnails.shared.clear()
        translation?.cancel()
        installSearch?.cancel()
        installShown = false
        giphySearch?.cancel()
        giphyPage?.cancel()
        giphyPage = nil
        activityWatch?.cancel()
        activityWatch = nil
        // The pages scrolled to are dropped with the menu; the first stays, so trending opens without fetching it again.
        AppsModule.dropWebThumbnails(giphyFound?.gifs.dropFirst(Giphy.limit).map(\.id) ?? [])
        giphyFound = nil
        removeLoad?.cancel()
        removeLoad = nil
        updateLoad?.cancel()
        updateLoad = nil
        cleanLoad?.cancel()
        cleanLoad = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        sizer = nil
        panel?.orderOut(nil)
        panel = nil
        // A live picker's source and every view waiting under it stop with the panel.
        source?.close()
        source = nil
        model?.popAll().forEach { $0.close() }
        model?.speedTest = nil
        model = nil
        // A picker that closes without a pick says so; run(_:) clears this first when a row was picked.
        let cancelled = onCancel
        onCancel = nil
        logPicks = true
        onPick = nil
        if restoreFocus { previousApp?.activate() }
        mlog.notice("menu closed")
        cancelled?()
    }

    /// The menu's key for a key code, nil when the search field gets it: ← and → with Option, Command or Shift are always
    /// the field's, to move or select in the text (card agent-bo-95423021), so only plain ← goes up a branch and → opens one;
    /// plain ones with text typed come back from the navigator to the field too (Sven 2026-10-12).
    static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, numbers: Bool = false) -> MenuNavigator.Key? {
        let plainArrow = flags.isDisjoint(with: [.command, .option, .shift])
        // Line's ⌘1 to ⌘9 run the first nine rows (menu-morph T3); `numbers` is false in the Files view, which keeps them.
        if numbers, flags.contains(.command), flags.isDisjoint(with: [.shift, .option, .control]), let n = Self.digits.firstIndex(of: code) {
            return .number(n + 1)
        }
        return switch code {
        case 126: .up
        case 125: .down
        case 36, 76: flags.contains(.command) ? .commandReturn : .return
        case 53: .escape
        case 123 where plainArrow: .left
        case 124 where plainArrow: .right
        case 48: flags.contains(.shift) ? .backTab : .tab
        case 49 where flags.isDisjoint(with: [.command, .option, .control]): .space
        case 40 where flags.contains(.command): .commandK
        // ⌘1, ⌘2, ⌘3: the Files view's Kind, Where and When (N5); ⇧ steps back. ⌘⇧.: Show hidden, as Finder's.
        case 18 where flags.contains(.command): .filter(.kind, back: flags.contains(.shift))
        case 19 where flags.contains(.command): .filter(.place, back: flags.contains(.shift))
        case 20 where flags.contains(.command): .filter(.when, back: flags.contains(.shift))
        case 47 where flags.contains([.command, .shift]): .toggleHidden
        default: nil
        }
    }

    /// The key codes of 1 to 9 on the number row.
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// A key the panel's monitor offers first (HUD.searchKey): true when the menu takes it, false when it is the search
    /// field's.
    func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String? = nil) -> Bool {
        // The Speed test view takes every key, before any row's under it.
        if let model, let test = model.speedTest { return speedKey(code, flags, test, in: model) }
        // ⌘1 to ⌘9 number the rows Line draws them on: none at its root, none in the Files view, none over Cmd+K.
        let numbers = model.map { $0.layout == .line && !$0.atRoot && !$0.nav.inFiles && $0.nav.actions == nil } ?? false
        // An extension row's action key (To-do B) wins over the menu's own: ⌥↑ moves the row, never the selection.
        if let model, !flags.isDisjoint(with: [.command, .option, .control]), model.nav.actions == nil, let row = model.nav.selected,
           let index = row.ownKeys?.firstIndex(where: {
               $0?.matches(code: code, command: flags.contains(.command), option: flags.contains(.option), control: flags.contains(.control),
                           shift: flags.contains(.shift)) == true
           }) {
            return apply(.own(index, row), from: model.nav.branch)
        }
        // A chip's list (Emoji's categories, Translate's languages) takes every key while it is open (MenuChips).
        if let model, model.chip != nil { return model.chipKey(code, flags, characters) }
        if let model, model.hasLineChips, model.nav.actions == nil, chipKey(model, code, flags) { return true }
        guard let model, let key = Self.key(code, flags, numbers: numbers) else { return false }
        // At the Rail's root ↑ and ↓ walk the whole rail, its kinds over Go to's branches (Q119).
        if model.railKey(key) { return true }
        if model.nav.actions == nil, gridKey(model, key) { return true }
        // Shift+Tab flips these two-way and cycled lists as Tab does.
        let tab = key == .tab || key == .backTab
        if tab, model.nav.branch == .stickers, !model.nav.isList, model.nav.actions == nil {
            model.pickGiphy(model.giphyKind.next)
            return true
        }
        if tab, model.nav.branch?.browsed == .remove {
            model.removeOrder = model.removeOrder.next
            showRemove()
            mlog.notice("menu: Remove sorted by \(model.removeOrder.title, privacy: .public)")
            return true
        }
        if model.nav.actions == nil, activityKey(model, key) { return true }
        let before = model.nav.branch, stepped = model.nav.actions != nil
        let taken = apply(model.nav.handle(key), from: before)
        // Line: out of Cmd+K's actions the search field takes the keyboard back with its text selected (SwiftUI's focus,
        // MenuView); the next key on its way to the field puts the caret after the text first (beforeTyping).
        if stepped, model.layout == .line, self.model?.nav.actions == nil { caretPending = true }
        return taken
    }

    /// The line's chips' keys (P39, P40): ⌘P opens Emoji's categories; in Translate Tab and Shift+Tab step From, the
    /// swap and To, Return on one opens its list or swaps, Escape leaves it, ⌘S swaps, and ⌘Return pastes the translation
    /// into the app in front. Any other key leaves the chip for the text.
    private func chipKey(_ model: MenuModel, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let command = flags.contains(.command)
        switch model.nav.branch {
        case .emoji where code == 35 && command:
            model.openEmojiCategories?()
            return true
        case .translate:
            switch code {
            case 48: model.stepChip(flags.contains(.shift) ? -1 : 1)
            case 36 where command, 76 where command: pasteTranslation(model)
            case 36 where model.chipFocus != nil, 76 where model.chipFocus != nil: model.pressChip()
            case 53 where model.chipFocus != nil: model.chipFocus = nil
            case 1 where command: model.swapLanguages()
            default:
                model.chipFocus = nil
                return false
            }
            return true
        default: return false
        }
    }

    /// Activity's and Stats' keys (Q399, Q400): in Activity ⌘Return force quits the current row once pressed twice on it,
    /// and any other key but Return forgets that and the foot's note; in Stats, which lists no rows, Return opens Activity;
    /// in About Escape closes the menu.
    private func activityKey(_ model: MenuModel, _ key: MenuNavigator.Key) -> Bool {
        if model.nav.branch == .stats, !model.nav.isList, key == .return {
            model.open(.activity)
            return true
        }
        // About is a page to read, as Omarchy's is: Escape closes the menu, not back to the root (Q443).
        if model.showsAbout, key == .escape { return apply(.close, from: model.nav.branch) }
        guard model.nav.branch == .activity, !model.nav.isList else { return false }
        if key == .commandReturn {
            if case .process(let id)? = model.nav.selected?.target { quitProcess(id, force: true) }
            return true
        }
        if key != .return { model.forceArmed = nil; model.activityNote = nil }
        return false
    }

    /// Activity's rows while it shows (Q399): what the last read holds at once, then a read every 3 s, as the Activity page
    /// reads, until another branch opens or the menu closes.
    private func watchActivity() {
        guard activityWatch == nil, let model else { return }
        let monitor = ActivityMonitor.shared
        if monitor.hasRead { provideActivity(model) }
        activityWatch = Task { [weak self, weak model] in
            while !Task.isCancelled {
                await monitor.refresh()
                guard let self, let model, self.model === model, model.nav.branch == .activity, !Task.isCancelled else { return }
                self.provideActivity(model)
                try? await Task.sleep(for: ActivityMonitor.interval, tolerance: .milliseconds(300))
            }
        }
    }

    private func provideActivity(_ model: MenuModel) {
        let monitor = ActivityMonitor.shared
        model.activityRead = monitor.hasRead
        model.nav.provide(.action, home: .activity, Activity.screenEntries(monitor.snapshot, quitting: monitor.quitting))
    }

    /// Return on an Activity row asks it to quit, as the Activity page's Quit; ⌘Return forces it, the second press on the
    /// same row, since a forced app loses what it had not saved. The menu stays open on the list, which says Quitting… on
    /// the row until a read no longer lists it; a row Pilot may not quit says why in the foot instead.
    private func quitProcess(_ id: String, force: Bool) {
        guard let model else { return }
        let monitor = ActivityMonitor.shared
        guard let row = monitor.snapshot.row(id) else { model.activityNote = "That one has already quit"; return }
        if let refusal = Activity.refusal(row, force: force) { model.activityNote = refusal; return }
        if force, model.forceArmed != id {
            model.forceArmed = id
            model.activityNote = "⌘↵ again forces \(row.name) to quit; what it has not saved is lost"
            return
        }
        model.forceArmed = nil
        guard monitor.quit(row, force: force) else {
            model.activityNote = "\(row.name) is gone or not yours to quit"
            return
        }
        model.activityNote = nil
        provideActivity(model)
    }

    /// The emoji grid's keys (P39): the arrows move in two dimensions, ← and → too while text is typed; ⌘Return copies
    /// the emoji instead of typing it.
    private func gridKey(_ model: MenuModel, _ key: MenuNavigator.Key) -> Bool {
        guard model.hasLineChips, model.nav.branch == .emoji, !model.nav.rows.isEmpty else { return false }
        switch key {
        case .up, .down, .left, .right:
            if let to = EmojiGrid.move(from: model.nav.selection, key, sections: model.nav.rows.map(\.section)) { model.nav.point(at: to) }
            return true
        case .commandReturn:
            guard let row = model.nav.selected, case .emoji(let glyph) = row.target else { return true }
            record(row, from: model.nav)
            copy(glyph)
            mlog.notice("menu: copied an emoji")
            return true
        default: return false
        }
    }

    /// ⌘Return in Translate: the translation goes in where Sven was through that app's own Paste (as Quick AI's fix
    /// does, SelectionEdit.menuPaste), his clipboard back after; copied instead when the app has no Paste.
    private func pasteTranslation(_ model: MenuModel) {
        guard case .copy(let text)? = model.nav.rows.first?.target else { return }
        let previous = previousApp
        close(restoreFocus: true)
        runWhenFrontmost(previous, "translation") {
            guard let app = previous else { return SystemModule.copy(text) }
            Task {
                guard await SelectionEdit.menuPaste(app.processIdentifier, text) else {
                    SystemModule.copy(text)
                    return HUD.tip("Copied: \(app.localizedName ?? "that app") has no Paste")
                }
                mlog.notice("menu: pasted \(text.count) characters of translation into \(app.bundleIdentifier ?? "?", privacy: .public)")
            }
        }
    }

    /// Runs as a key goes on to the search field (HUD.searchKey), once after Escape out of Cmd+K: the query SwiftUI's
    /// refocus selected whole becomes a caret after it, so the letter adds instead of replacing it; a caret or part Sven
    /// put himself stays (HUD.caretToEnd).
    func beforeTyping() {
        guard caretPending else { return }
        caretPending = false
        HUD.caretToEnd(in: panel)
    }

    #if DEBUG
    /// A test's menu: `model` in `panel`, as show() would hold them, without the engine, the key monitor or the resign
    /// observer (LineKeysTests drives HUD.searchKey with handle and beforeTyping itself).
    func adopt(_ model: MenuModel, in panel: NSPanel) {
        self.model = model
        self.panel = panel
        caretPending = false
    }
    #endif

    /// What a key or a click (card agent-bo-95422994) came to; false when the key is the search field's.
    private func apply(_ outcome: MenuNavigator.Outcome, from before: MenuBranch?) -> Bool {
        guard let model else { return false }
        if model.nav.branch != before { mlog.notice("menu: \(model.nav.branch.map { "into \($0.rawValue)" } ?? "up to the root", privacy: .public)") }
        switch outcome {
        case .handled: return true
        case .ignored: return false
        case .close: if !pop() { close(restoreFocus: true) }
        case .run(let entry):
            if let source { follow(source.pick(entry, action: 0)) } else { run(entry) }
        case .own(let index, let entry): if let source { follow(source.pick(entry, action: index)) }
        case .reveal(let entry): reveal(entry)
        case .act(let action, let entry): perform(action, on: entry)
        case .preview(let entry):
            guard case .file(let path) = entry.target else { break }
            close(restoreFocus: false)
            FileActions.preview(path)
        case .back(let spot): if !pop() { reopen(spot) }
        case .toggle(let entry): toggle(entry)
        }
        return true
    }

    /// Space on a switch (S1): its action runs with the menu left open, the app Sven was in still frontmost under the
    /// non-activating panel; the row already shows its new state, and the states are read again a second later, so a
    /// refused or linked one shows the truth. A stopgap: an action cannot say when it has landed (dark mode goes through
    /// System Events), so the read waits a while instead.
    private func toggle(_ entry: MenuEntry) {
        guard case .action(let id) = entry.target, let model else { return }
        record(entry, from: model.nav)
        mlog.notice("menu: toggle \(LinkToken.redact(id), privacy: .public) with the menu open")
        Engine.shared?.action(id)?.run()
        switchRead?.cancel()
        switchRead = Task { [weak self, weak model] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let model, self?.model === model else { return }
            model.nav.switches(SystemModule.switchStates())
        }
    }

    /// Test internet speed in Line (P41): the run shows in the list's place, the menu open. A run going on (Esc left it,
    /// or the key or `pilot speedtest` started it) is joined, and one that ended since shows its result; else a run starts.
    private func showSpeedTest() {
        guard let model else { return }
        let test = SystemModule.speedTest
        model.speedTest = test
        if case .done = test.phase {} else { test.start() }
        mlog.notice("menu: speed test shown")
    }

    /// The Speed test view's keys, every other key swallowed so nothing types under it: Escape goes back to the branch
    /// (a run carries on), Return runs again once it ended, ⌘C copies the result, ⌘. stops the run.
    private func speedKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ test: SpeedTest, in model: MenuModel) -> Bool {
        let command = flags.contains(.command)
        switch code {
        case 53: model.speedTest = nil
        case 36, 76: if !test.running { test.start() }
        case 8 where command: if case .done(let result) = test.phase { copy(SpeedTest.line(result.reading)) }
        case 47 where command: test.stop()
        default: break
        }
        return true
    }

    /// A Cmd+K action the navigator leaves to the panel (card agent-bo-95422968). Uninstall and opening never get here:
    /// the navigator searches Remove for the first and picks the row for the second.
    private func perform(_ action: RowAction, on entry: MenuEntry) {
        mlog.notice("menu: \(action.rawValue, privacy: .public) on \(LinkToken.redact(entry.frecencyKey ?? "a row"), privacy: .public)")
        switch (action, entry.target) {
        case (.showInFinder, _): reveal(entry)
        case (.copyPath, .app(let bundle)): copy(AppsModule.url(forBundle: bundle)?.path)
        case (.copyPath, .file(let path)): copy(path)
        case (.openWith, .file(let path)): FileActions.openWith([URL(filePath: path)])
        case (.convert, .file(let path)): ConvertFiles.offer([URL(filePath: path)])
        case (.trash, .note(.open(let id))): NotesPanel.shared.askTrash(id)
        // A note found as a file goes as a note does: its pin and pictures with it, and never Scratch.
        case (.trash, .file(let path)):
            if let id = NotesPanel.shared.noteID(path) { NotesPanel.shared.askTrash(id) } else { FileActions.trash(path) }
        // An installed extension (story 158): asked as the catalogue asks.
        case (.uninstall, _):
            guard let id = entry.extensionID else { return }
            close(restoreFocus: false)
            ExtensionCatalogueMenu.askUninstall(id, title: entry.title)
        case (.copyBundleID, .app(let bundle)): copy(bundle)
        case (.openApp, _):
            guard let bundle = entry.app else { return }
            close(restoreFocus: false)
            AppsModule.open(bundle: bundle)
        case (.copyID, .action(let id)): copy(id)
        case (.copyTitle, _): copy(entry.title)
        case (.quit, .app(let bundle)), (.forceQuit, .app(let bundle)):
            close(restoreFocus: previousApp?.bundleIdentifier != bundle)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                _ = action == .quit ? app.terminate() : app.forceTerminate()
            }
        // The navigator changed its own copy; the book takes the one row, so a change from the pilot command stays.
        case (.favourite, _), (.unfavourite, _):
            guard let key = entry.frecencyKey else { return }
            FavouriteBook.shared.set(key, action == .favourite)
        case (.resetRanking, _):
            guard let key = entry.frecencyKey else { return }
            do { _ = try resetRanking(key) } catch { mlog.error("menu: frecency not saved: \(error, privacy: .public)") }
        case (.setBind, .app(let bundle)): editBind(AppsModule.openID(bundle: bundle))
        case (.setBind, .action(let id)): editBind(id)
        case (.setAlias, _): editAlias(entry)
        default: break
        }
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        close(restoreFocus: true)
        SystemModule.copy(text)
    }

    /// Set alias (card agent-bo-95423037): the app window on Defaults with the Aliases editor open on the row.
    private func editAlias(_ row: MenuEntry) {
        guard let key = row.frecencyKey else { return }
        close(restoreFocus: false)
        AppWindowController.shared.open(AppPlace(.aliases), editAlias: Alias(key: key, alias: "", title: row.title))
    }

    /// Set Hyper bind: the app window on Binds with the bind editor open on the action.
    private func editBind(_ action: String) {
        close(restoreFocus: false)
        AppWindowController.shared.open(AppPlace(.binds), editBind: action)
    }

    private func run(_ entry: MenuEntry) {
        if let picked = onPick {
            // A picker's row and what was typed, as `record` logs a menu pick (card agent-bo-95422756).
            if logPicks { mlog.notice("menu: picked \(entry.title, privacy: .public) for \"\(self.model?.nav.query ?? "", privacy: .public)\"") }
            else { mlog.notice("menu: picked a row") }
            onCancel = nil
            close(restoreFocus: false)
            return picked(entry)
        }
        let previous = previousApp, spot = model?.nav.spot
        if let nav = model?.nav { record(entry, from: nav) }
        Engine.shared?.nudger.picked(entry)
        Self.$origin.withValue(spot) { run(entry, previous: previous) }
    }

    /// A menu row runs with `origin` set to where the menu stood, so a picker it opens can go back there.
    private func run(_ entry: MenuEntry, previous: NSRunningApplication?) {
        switch entry.target {
        case .app(let bundle):
            close(restoreFocus: false)
            mlog.notice("menu: open \(bundle, privacy: .public) \(AppsModule.open(bundle: bundle) ? "opened" : "not installed", privacy: .public)")
        case .action("system.speedTest") where model?.layout == .line:
            showSpeedTest()
        case .action(let id):
            close(restoreFocus: true)
            runWhenFrontmost(previous, id) { Engine.shared?.action(id)?.run() }
        case .window(let id):
            close(restoreFocus: false)
            focusWindow(id)
        case .remove(.row(let key)):
            guard let row = removeRows?.rows.first(where: { $0.key == key }) else { return }
            close(restoreFocus: false)
            InstallModule.remove(row)
        case .update(let pick):
            update(pick)
        case .clean(let pick):
            if case .note = pick {} else { close(restoreFocus: false) }
            CleanModule.pick(pick)
        case .package(let key):
            close(restoreFocus: false)
            InstallModule.pick(key)
        case .file(let path) where CapturesModule.isCapture(path):
            close(restoreFocus: false)
            CapturesModule.edit(path)
        case .file(let path):
            close(restoreFocus: false)
            mlog.notice("menu: open file \(path, privacy: .public) \(NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? "opened" : "not opened", privacy: .public)")
        case .copy(let text):
            close(restoreFocus: true)
            SystemModule.copy(text)
            mlog.notice("menu: copied \(text.count) characters")
        case .emoji(let emoji):
            // Typed, not pasted, so the clipboard keeps what Sven copied.
            close(restoreFocus: true)
            runWhenFrontmost(previous, "emoji") { Post.text(emoji) }
        case .sticker(.giphy(let gif)):
            // The download starts at the pick, the paste once the app Sven was in is in front again.
            close(restoreFocus: true)
            let file = Task.detached { try await Giphy.download(gif) }
            runWhenFrontmost(previous, "gif") { StickerPaster.paste(gif, file: file) }
        case .sticker(let sticker):
            close(restoreFocus: true)
            runWhenFrontmost(previous, "sticker") { StickerPaster.paste(sticker) }
        case .reminder(.set(let seconds, let text)):
            close(restoreFocus: true)
            ReminderScheduler.shared.add(text, in: seconds)
            HUD.tip("Reminder set: \(text)")
        case .reminder(.cancel(let id)):
            ReminderScheduler.shared.cancel(id)
            branchOpened(.reminders)
        case .snippet(let pick):
            guard let snippet = SnippetLibrary.shared.snippet(pick.id) else { return }
            // Its argument is asked for first: the search takes it after the name.
            if snippet.needsArgument, pick.argument == nil { model?.nav.query = "\(snippet.name) "; return }
            close(restoreFocus: true)
            runWhenFrontmost(previous, "snippet") { SnippetLibrary.shared.paste(pick) }
        case .note(.open(let id)):
            close(restoreFocus: false)
            NotesPanel.shared.show(note: id)
        case .note(.append(let text)):
            close(restoreFocus: true)
            NotesPanel.shared.append(text)
        case .ask(let question):
            close(restoreFocus: true)
            AIChatPanel.shared.show(sending: question)
        case .calendarEvent(let event):
            // Added in place: Calendar is never opened, its access asked the first time as Show events asks it.
            close(restoreFocus: true)
            guard let calendar = Engine.shared?.barSources.readings.calendar else { return }
            Task { HUD.tip(await calendar.add(event), seconds: 3) }
        case .searchWeb(let query):
            let choice = webSearch ?? WebSearchReader.read(browser: WebSearchReader.defaultBrowser())
            close(restoreFocus: false)
            WebSearchReader.open(query, with: choice)
            mlog.notice("menu: search the web with \(choice.via, privacy: .public)")
        case .openPage(let place):
            close(restoreFocus: false)
            AppWindowController.shared.open(place)
        case .process(let id):
            quitProcess(id, force: false)
        case .allowFullDiskAccess:
            close(restoreFocus: false)
            SystemModule.openFullDiskAccess()
        case .branch, .searchFiles, .searchInstall: break
        }
    }

    /// The action acts on whatever is focused, so it runs once the app Sven was in is frontmost again (AGENTS.md: check
    /// focus first), checked every 50 ms for a second; never on another app's window.
    /// `id` names what runs in the log: an action's id, or "emoji".
    /// The wait is a task, so `origin` carries through it.
    private func runWhenFrontmost(_ app: NSRunningApplication?, _ id: String, tries: Int = 20, _ body: @escaping () -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        guard let app, front?.processIdentifier != app.processIdentifier else {
            mlog.notice("menu: run \(LinkToken.redact(id), privacy: .public) in \(front?.bundleIdentifier ?? "?", privacy: .public)")
            body()
            return
        }
        guard tries > 0 else {
            return mlog.error("menu: \(LinkToken.redact(id), privacy: .public) not run, \(app.bundleIdentifier ?? "?", privacy: .public) did not come back to the front")
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            runWhenFrontmost(app, id, tries: tries - 1, body)
        }
    }

    /// Switches to the window's workspace and focuses it, after the 0.3 s pause that lets the panel's app give up
    /// focus first (spike test 7).
    private func focusWindow(_ id: Int) {
        guard let tiler = Engine.shared?.observers.tiler else { return }
        Task {
            try? await Task.sleep(for: tilerSettle)
            await tiler.perform("menu.focusWindow:\(id)") { try await $0.run(.focusWindow(id: id)) }
        }
    }

    /// Stores the pick and logs the order it was picked from, so a ranking change shows in the log.
    private func record(_ entry: MenuEntry, from nav: MenuNavigator) {
        guard let key = entry.frecencyKey else { return }
        frecency?.record(key, at: .now)
        guard let picks = frecency else { return }
        saveFrecency(picks)
        let top = nav.rows.prefix(3).map(\.title).joined(separator: ", ")
        mlog.notice("menu: picked \(LinkToken.redact(key), privacy: .public) for \"\(nav.query, privacy: .public)\" from \(top, privacy: .public), frecency \(picks.score(key, now: .now))")
    }

    /// Reset ranking from the pilot command (CLI W4), on the menu's own copy, so its next pick saves no stale one; the
    /// picks as saved; nil when the file does not read, so nothing is saved over it.
    func resetRanking(_ key: String) throws -> Frecency? {
        guard var picks = frecency else { return nil }
        picks.forget(key)
        try frecencyStore.save(picks)
        frecency = picks
        return picks
    }

    private func saveFrecency(_ picks: Frecency) {
        do { try frecencyStore.save(picks) } catch { mlog.error("menu: frecency not saved: \(error, privacy: .public)") }
    }

    private func reveal(_ entry: MenuEntry) {
        let url: URL? = switch entry.target {
        case .app(let bundle): AppsModule.url(forBundle: bundle)
        case .file(let path): URL(fileURLWithPath: path)
        case .note(.open(let id)): NotesPanel.shared.folder.appending(path: id)
        default: nil
        }
        guard let url else { return }
        close(restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        mlog.notice("menu: show \(url.path, privacy: .public) in Finder")
    }
}

/// Keeps the menu's window at its face's size as where Sven is changes it (MenuPanelSize, card agent-bo-95422981): narrow
/// at the root, wide once he types, the top edge and the centre put so the search line never jumps (PilotMenu.fit). In
/// Line the window holds the union of the face's two sizes while the face morphs between them, then the face's own once
/// it has settled (LineMorph); Line draws its own face with no margins round it, so its window is its face.
@MainActor
final class MenuSizer {
    private weak var panel: NSPanel?
    private weak var model: MenuModel?
    /// Whether the face was at the root when the window last took its size: a change is a morph.
    private var atRoot: Bool?
    /// The morph waiting to settle, by number, so a later one supersedes it.
    private var settle = 0
    private(set) var settling = false

    init(panel: NSPanel, model: MenuModel) {
        self.panel = panel
        self.model = model
        follow()
    }

    /// The window at the face's size now, and again whenever the size changes: on the run loop's next pass, as the
    /// observation's change lands after its willSet. Run-loop work (perform, a timer), not the main queue's, so it also
    /// runs while a test pumps the run loop from inside a main-queue job.
    func follow() {
        guard let panel, let model else { return }
        let (face, root) = withObservationTracking {
            (Look.shared.style == .instrument ? model.instrumentSize : model.toyboxSize, model.atRoot)
        } onChange: { [weak self] in
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self?.follow() } }
        }
        guard model.layout == .line, Look.shared.style == .instrument else { return PilotMenu.fit(panel, face: face) }
        let morph = atRoot.map { $0 != root } ?? false
        atRoot = root
        let frames = LineMorph.window(holding: panel.frame.size, to: face, morph: morph, settling: settling,
                                      reduce: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        PilotMenu.fit(panel, face: frames.now)
        guard let size = frames.settle else { settling = false; return }
        settle += 1
        settling = true
        let number = settle
        let timer = Timer(timeInterval: LineMorph.settle(back: root), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, self.settle == number else { return }
                self.settling = false
                PilotMenu.fit(panel, face: size)
            }
        }
        // On its tick: the window keeps its clear margin only for the morph (one shot, so no repeating timer's tolerance).
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// What fills a live picker (PilotMenu.pick(live:)): it hears each search and hands its rows to `show`, which the panel
/// sets as the picker opens; Return (action 0) or a Cmd+K action on a row is its to answer; the panel closes it as the
/// picker closes.
@MainActor
protocol MenuSource: AnyObject {
    var show: ([MenuEntry]) -> Void { get set }
    func search(_ query: String)
    func pick(_ row: MenuEntry, action: Int) -> MenuPick
    func close()
    /// Asked again with the search as it stands, even when it filters nothing itself (after a run that stays, To-do B);
    /// the row that now stands for `row`, when it is still listed in its section (a row moved), else nil.
    func refresh(keeping row: MenuEntry?) async -> MenuEntry.Target?
    /// What the search holds as the view opens: an ask's text to edit.
    var opening: String { get }
}

extension MenuSource {
    func refresh(keeping row: MenuEntry?) async -> MenuEntry.Target? { nil }
    var opening: String { "" }
}

/// A live picker source's answer to a pick: close the panel then run, push a view with its own source, or nothing.
/// keep: run with the panel open (an action's `stay`), then ask the list again, its search emptied first when `clear`;
/// `back` leaves the view it was picked in first (an ask, answered).
enum MenuPick {
    case close(() -> Void), push(String, any MenuSource), stay
    case keep(clear: Bool, back: Bool, run: () -> Task<Void, Never>?)
}

@Observable @MainActor
final class MenuModel {
    /// The row the pointer is on, by its target; nil over a heading, a gap or outside the list (PointerList.under).
    @ObservationIgnored var underPointer: MenuEntry.Target?
    /// The live views under the one shown, nearest last, each with the source that fills it (card agent-bo-95423244).
    @ObservationIgnored private var below: [(nav: MenuNavigator, source: any MenuSource)] = []

    /// `nav` shown over the current view, which waits under it with `source`.
    func push(_ nav: MenuNavigator, over source: any MenuSource) {
        below.append((self.nav, source))
        // The new view's empty search must not reach the source waiting under it (Moody ZLUB3C6kGZU).
        onQuery = nil
        self.nav = nav
    }

    /// The view under the shown one back as it was; its source, or nil when nothing was pushed.
    func pop() -> (any MenuSource)? {
        guard let last = below.popLast() else { return nil }
        // The pushed view's search must not reach anyone as the old view comes back; the panel attaches its source again.
        onQuery = nil
        nav = last.nav
        return last.source
    }

    /// Every waiting view's source, the stack emptied: the panel closing.
    func popAll() -> [any MenuSource] {
        defer { below = [] }
        return below.map(\.source)
    }

    var nav: MenuNavigator {
        didSet {
            // Search to install opens Search packages with the text kept, which its providers search too.
            if nav.query != oldValue.query || nav.branch != oldValue.branch && !nav.query.isEmpty { onQuery?(nav.query) }
            if nav.query != oldValue.query || nav.only != oldValue.only || nav.branch != oldValue.branch
                || nav.fileFilters != oldValue.fileFilters, nav.fileAsk != oldValue.fileAsk { onFileQuery?(nav.fileAsk) }
            if nav.branch != oldValue.branch {
                loadFailed = nil
                onBranch?(nav.branch)
            }
        }
    }
    /// Each change to the search, for the providers that search as Sven types (emoji, answers, Homebrew).
    var onQuery: ((String) -> Void)?
    /// Each change to what the file index is asked (words and filters), nil when it is asked nothing: only the Files
    /// view asks.
    var onFileQuery: ((FileSearch.Ask?) -> Void)?
    /// Each branch opened, for the providers that fill one as it opens (Remove).
    var onBranch: ((MenuBranch?) -> Void)?
    /// A list row came into view (scrolled to, or the list drawn), by its index: Stickers and GIFs asks GIPHY for more
    /// near the end.
    var onRowShown: ((Int) -> Void)?
    /// Why the open branch's provider has no rows (a failed read); cleared when the branch changes.
    private(set) var loadFailed: String?

    /// A provider's failed read, shown only while Sven is still in its branch (Moody's 718 note).
    func failed(in branch: MenuBranch, _ why: String) { if nav.branch == branch { loadFailed = why } }
    /// A click on a row or a Cmd+K action (card agent-bo-95422994): the panel carries out what it came to, as for Return.
    var onClick: ((_ outcome: MenuNavigator.Outcome, _ before: MenuBranch?) -> Void)?
    func click(at index: Int) { let before = nav.branch; onClick?(nav.click(at: index), before) }
    func clickAction(at index: Int) { let before = nav.branch; onClick?(nav.clickAction(at: index), before) }

    /// Remove's order, which Tab changes.
    var removeOrder = RemoveList.Order.pilotFirst
    /// The list a chip in the line opened (MenuChips), drawn over the menu; it takes the keys while open.
    var chip: ChipMenu?
    /// Activity's words in the foot: why a row cannot be quit, or the force quit waiting for its second ⌘Return.
    var activityNote: String?
    /// The Activity row the first ⌘Return armed to force quit; nil when none is.
    var forceArmed: String?
    /// Activity's first read has landed, so an empty list means nothing matches, not Reading….
    var activityRead = false
    /// Emoji's category ⌘P picked (P39); nil shows them all. Kept while the menu is open.
    var emojiCategory: String?
    /// Opens Emoji's category list; the panel sets it, as it knows the list and the picks.
    var openEmojiCategories: (() -> Void)?
    /// Translate's line (P40): the chip Tab is on (0 From, 1 the swap, 2 To; nil the text), the From picked (nil is
    /// Auto, again each menu), the text's source as picked or detected, and the pair as saved.
    var chipFocus: Int?
    var translateFrom: String?
    var translateSource: String?
    var translatePair = TranslatePair.standard
    /// The app the menu opened over, by name: the foot's Paste to Messages.
    var frontApp: String?
    /// What Stickers and GIFs asks GIPHY for, which Tab or the bar's chips flip; kept for the next menu.
    var giphyKind = Giphy.Kind(rawValue: MenuModel.kindStore.string(forKey: MenuModel.kindKey) ?? "") ?? .gifs {
        didSet { Self.kindStore.set(giphyKind.rawValue, forKey: Self.kindKey) }
    }
    private static let kindStore = UserDefaults.pilot(), kindKey = "menu.giphyKind"
    /// The bar's tab picked: GIPHY asked again for what is typed.
    func pickGiphy(_ kind: Giphy.Kind) {
        guard kind != giphyKind else { return }
        giphyKind = kind
        mlog.notice("menu: GIPHY shows \(kind.rawValue, privacy: .public)")
        onQuery?(nav.query)
    }
    /// Every window as the menu opened, which Instrument's window rows draw on their workspace's glyph.
    var windows: [AeroWindow] = []
    /// The layer keys; the first one's sign leads a bind's keys in Instrument.
    var layerKeys: [LayerKey] = [.capsLock]

    /// How Instrument draws the menu (look.menuLayout): the Rail, Classic or Line. Set as the menu opens; Classic until then, so
    /// a model made elsewhere draws as it did.
    var layout = MenuLayoutStyle.classic
    /// The root's branches in Sven's order (MenuRoot), which the Rail's Go to lists wherever Sven is.
    var goTo: [MenuBranch] = MenuRoot().shown()
    /// At the Rail's root, the kind ↑ and ↓ are on (an index into MenuEntry.Kind.tabOrder); nil while they are on the
    /// navigator's rows (RailMenu's railKey, Q119).
    var railCursor: Int?
    /// The entries picked last, newest first, which the Rail's root lists as Recent.
    var recent: [MenuEntry] = []
    /// What waits beside Recent at the Rail's root (frame B1): Update with its count, Clean with its size, each only
    /// when it has something.
    var waiting: [MenuEntry] = []

    /// Stats' cards draw in the list's place (MenuStatsScreen), unless Cmd+K's actions are over it.
    var showsStats: Bool { nav.branch == .stats && !nav.isList && nav.actions == nil && scan == nil }
    /// About's cards and mark draw in the list's place (MenuAboutScreen, Q443), the same way.
    var showsAbout: Bool { nav.branch == .about && !nav.isList && nav.actions == nil && scan == nil }
    /// About's height for the displays this Mac has now.
    var aboutHeight: CGFloat { MenuAboutScreen.height(displays: NSScreen.screens.count) }

    /// Toybox's panel size for where Sven is (MenuPanelSize, card agent-bo-95422981).
    var toyboxSize: CGSize {
        let size = MenuPanelSize.toybox(shape, rows: nav.rows.count)
        // About is taller than Toybox's fixed wide panel: room for its cards under the search and over the foot.
        return showsAbout ? CGSize(width: size.width, height: max(size.height, Self.toyChrome + aboutHeight)) : size
    }
    /// Toybox's search, rule and foot around what the menu lists.
    static let toyChrome: CGFloat = 150
    /// Instrument's: as tall as what it lists or a scan's wait says, the most while Cmd+K's
    /// actions show or an extension's detail is read; in the Rail, at least as tall as its rail.
    var instrumentSize: CGSize {
        if layout == .classic { return classicSize }
        if layout == .line { return lineSize }
        let band = railBand
        if showsStats { return MenuPanelSize.rail(shape, band: band, railItems: railItems, rows: 0, headings: 0, extra: MenuStatsScreen.height) }
        if showsAbout { return MenuPanelSize.rail(shape, band: band, railItems: railItems, rows: 0, headings: 0, extra: aboutHeight) }
        if scan != nil {
            return MenuPanelSize.rail(shape, band: band, railItems: railItems, rows: 0, headings: 0, extra: waitHeight)
        }
        // The Rail's root lists its rows in the rail, beside the recents, so its rail sets the height.
        let listed = band == .root
        return MenuPanelSize.rail(shape, band: band, railItems: railItems, rows: listed ? 0 : nav.rows.count, headings: listed ? 0 : headings.count,
                                  extra: noMatch ? Self.noMatchRoom : 0, bar: showsGiphyBar ? GiphyKindBar.instrumentHeight : 0,
                                  full: nav.actions != nil || nav.shownDetail != nil)
    }

    /// Classic's (ClassicMenu): as tall as its rows, the root's under their rule heading, and
    /// an answer's card where it stands in for its row; the kinds sit in the status line.
    private var classicSize: CGSize {
        if scan != nil { return MenuPanelSize.classic(shape, rows: 0, headings: 0, extra: waitHeight) }
        if showsStats { return MenuPanelSize.classic(shape, rows: 0, headings: 0, extra: MenuStatsScreen.height) }
        if showsAbout { return MenuPanelSize.classic(shape, rows: 0, headings: 0, extra: aboutHeight) }
        let headings = headings
        let card = cardRoom(headed: headings[0] != nil, row: shape == .wide ? MenuPanelSize.classicWideRow : MenuPanelSize.classicRow)
        return MenuPanelSize.classic(shape, rows: nav.rows.count, headings: atRoot ? 0 : headings.count, root: atRoot,
                                     card: card,
                                     extra: noMatch ? Self.noMatchRoom : 0, bar: showsGiphyBar ? GiphyKindBar.instrumentHeight : 0,
                                     full: nav.actions != nil || nav.shownDetail != nil || previewsFile)
    }

    /// Line's (LineMenu): Classic's root at 431 wide, else a 750 list as tall as its rows, headings and an answer's card.
    private var lineSize: CGSize {
        if scan != nil { return MenuPanelSize.line(shape, rows: 0, headings: 0, extra: waitHeight) }
        if let speedTest { return MenuPanelSize.line(shape, rows: 0, headings: 0, extra: SpeedTestView.height(speedTest)) }
        if atRoot { return MenuPanelSize.lineRoot(rows: nav.rows.count) }
        if showsStats { return MenuPanelSize.line(shape, rows: 0, headings: 0, extra: MenuStatsScreen.height) }
        if showsAbout { return MenuPanelSize.line(shape, rows: 0, headings: 0, extra: aboutHeight) }
        // The emoji grid's cells and the translation's panes, not rows; the whole height while a chip's list is open.
        if hasLineChips, nav.actions == nil {
            let room = nav.branch == .translate ? TranslatePanes.height : nav.rows.isEmpty ? 180 : EmojiGridView.height(nav.rows)
            return MenuPanelSize.line(shape, rows: 0, headings: 0, extra: room, full: chip != nil)
        }
        let headings = headings
        let card = cardRoom(headed: headings[0] != nil, row: MenuPanelSize.lineRow) + (statsCards ? StatsStrip.room : 0)
        return MenuPanelSize.line(shape, rows: nav.rows.count, headings: headings.count, card: card, extra: noMatch ? Self.noMatchRoom : 0,
                                  bar: showsGiphyBar ? GiphyKindBar.instrumentHeight : 0, full: nav.actions != nil || nav.shownDetail != nil || previewsFile)
    }

    /// Classic's and Line's Files view shows the selected file's preview beside its list (FilePreviewPane), so it takes the
    /// full height whatever the rows: room for the pane, and no jump as results come and go. ClassicMenu and LineMenu draw
    /// the pane by this.
    var previewsFile: Bool { (layout == .classic || layout == .line) && nav.only == .file && nav.shownDetail == nil && scan == nil && !nav.rows.isEmpty }

    /// What Classic's answer card takes past the row it draws (AnswerCard): its eyebrow unless a heading is already
    /// counted, the card (a colour's swatch and ramp in their inset; 158 for the rest), its insets and a note under it.
    /// Classic's and Line's: `drawn` is the layout's row the card stands in for.
    private func cardRoom(headed: Bool, row drawn: CGFloat) -> CGFloat {
        guard let row = nav.rows.first, let card = answerCard(row, at: 0) else { return 0 }
        let face: CGFloat = if case .colour = card.kind { 118 + 8 + 16 + 24 } else { 158 }
        return (headed ? 0 : MenuPanelSize.instrumentHeading) + face + 10 + (card.note == nil ? 0 : 20) - drawn
    }

    /// What the Rail draws beside the list (MenuPanelSize.RailBand): nothing in Classic or a picker; the slim strip inside
    /// a branch or on an answer; the whole rail at the empty root and at a root search.
    var railBand: MenuPanelSize.RailBand {
        guard layout == .rail, !nav.isList else { return .none }
        if nav.branch != nil || !nav.query.isEmpty && nav.rows.first?.isAnswer == true { return .slim }
        return atRoot ? .root : .full
    }
    /// The rail's rows: the kinds, Go to's branches (at the root, the navigator's own rows) and Clipboard; a slim strip's
    /// search, branches and Clipboard.
    var railItems: Int {
        switch railBand {
        case .none: 0
        case .root: MenuEntry.Kind.tabOrder.count + nav.rows.count + 1
        case .full: MenuEntry.Kind.tabOrder.count + goTo.count + 1
        case .slim: goTo.count + 2
        }
    }

    /// The Rail's Clipboard row: Clipboard's own panel (apps.clipboard), marked as opening it.
    static let clipboard = MenuEntry(title: "Clipboard", target: .action("apps.clipboard"))

    /// The Rail's root lists as Recent the entries picked last (Frecency's picks), newest first, at most `limit`; none
    /// before any pick.
    static func recent(_ entries: [MenuEntry], picks: Frecency, limit: Int = 5) -> [MenuEntry] {
        var seen = Set<String>()
        let picked = entries.compactMap { entry -> (entry: MenuEntry, at: Date)? in
            guard entry.inSearch, let key = entry.frecencyKey, let at = picks.picks[key]?.max(), seen.insert(key).inserted else { return nil }
            return (entry, at)
        }
        return picked.sorted { $0.at > $1.at }.prefix(limit).map(\.entry)
    }

    /// The Rail's Waiting rows: Update with how many updates its last read listed, Clean with what its kept preview
    /// would free; neither when it has nothing, or was not read.
    static func waiting(updates: Int?, clean: String?) -> [MenuEntry] {
        var rows: [MenuEntry] = []
        if let updates, updates > 0 { rows.append(MenuEntry(title: MenuBranch.update.title, target: .branch(.update), detail: String(updates))) }
        if let clean, !clean.isEmpty { rows.append(MenuEntry(title: MenuBranch.clean.title, target: .branch(.clean), detail: clean)) }
        return rows
    }

    /// A rail row clicked: a kind shows as Tab reaching it does; a branch opens as Return on it does, from wherever Sven
    /// is; the search glyph goes back to the root.
    func show(_ kind: MenuEntry.Kind?) { withAnimation(nil) { nav.show(kind) } }
    func open(_ branch: MenuBranch?) {
        guard nav.actions == nil, branch != nav.branch || !nav.query.isEmpty else { return }
        nav.go(to: MenuNavigator.Spot(branch: branch))
    }
    /// A row the navigator does not list (Recent, Clipboard) clicked: it runs as Return on it would.
    func run(_ entry: MenuEntry) {
        guard nav.actions == nil else { return }
        onClick?(.run(entry), nav.branch)
    }
    /// Stickers and GIFs' GIFs | Stickers bar, over its list and not under a detail or a picker.
    var showsGiphyBar: Bool { nav.branch == .stickers && !nav.isList && nav.shownDetail == nil }
    /// How tall Instrument's scan draws at the panel's width, as it measures itself.
    var waitHeight: CGFloat = 330
    /// The menu's own bind ("Hyper+Space" as shipped), which Toybox's search line shows; nil while it has none.
    var ownKey: String?
    /// Line's Speed test view (P41), shown in the list's place over the branch it was opened from until Escape; the test
    /// knows it is shown, so it raises no alert of its own.
    var speedTest: SpeedTest? {
        didSet {
            guard oldValue !== speedTest else { return }
            oldValue?.dismiss()
            speedTest?.shown = true
        }
    }

    /// A root search that found nothing but its search offers (Search to install, Search files): Instrument says so under
    /// them, in this much room.
    var noMatch: Bool { searchingRoot && !nav.rows.isEmpty && nav.rows.allSatisfy(\.isOffer) }
    static let noMatchRoom: CGFloat = 76
    /// System or one of its sub-branches, whose rows wear their switches (Space flips them), whatever the panel's shape.
    var inSystem: Bool { !nav.isList && nav.branch?.browsed == .system }
    /// The Rail is narrow only at its empty root: every branch, a search and an answer take the wide panel (notes › Sizes).
    var shape: MenuPanelSize.Shape {
        let shape = MenuPanelSize.shape(branch: nav.branch, query: nav.query, isList: nav.isList, only: nav.only)
        return layout == .rail && (shape != .narrow || nav.branch != nil) ? .wide : shape
    }
    init(nav: MenuNavigator) { self.nav = nav }

    /// The command-line tools this Mac has, which a scan's kinds follow (MenuScan.tools); nil until a scan asks.
    var tools: Set<String>?

    /// While a list is still read the panel shows what happens next rather than one line over an empty list (MenuScan):
    /// Clean while Mole previews, Update and Remove (from any of their categories too) before their rows land, Install's
    /// search before any source answered, when its Searching row (and at most an "Add npm to search more" hint after it)
    /// is all it lists and stays the selected one.
    var scan: MenuScan? {
        guard loadFailed == nil, nav.actions == nil, nav.shownDetail == nil, !nav.isList else { return nil }
        if nav.rows.isEmpty, nav.query.isEmpty {
            if nav.branch == .clean { return .clean(CleanMenu.waiting(CleanModule.previewer.progress)) }
            if nav.branch?.browsed == .update { return .update }
            if nav.branch?.browsed == .remove { return .remove }
        }
        if MenuLayout.searchesInstall(nav.branch), let row = nav.rows.first, MenuEntries.isSearching(row),
           nav.rows.dropFirst().allSatisfy(MenuEntries.isHelperHint), let query = InstallSearch.Query(nav.query) {
            return .install(query.text, searching: row)
        }
        return nil
    }

    /// An empty list whose rows are still being read (a translation), not one that has none.
    var reading: Bool {
        loadFailed == nil && nav.branch == .translate
            && nav.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= MenuNavigator.minimumQuery
    }

    /// A kind as Tab's tabs name it: "Apps", or "All" for every kind.
    static func title(of kind: MenuEntry.Kind?) -> String { kind.map { $0.rawValue.capitalized + "s" } ?? "All" }

    /// Search packages before two characters are typed (N9).
    static let searchPrompt = "Type a name to search Homebrew, the App Store, GitHub, package tools and the web."

    /// What the menu says when it has no rows.
    var emptyText: String {
        if nav.branch == .homebrew, InstallSearch.Query(nav.query) == nil { return MenuModel.searchPrompt }
        if let loadFailed { return loadFailed }
        if nav.branch == .snippets, nav.query.isEmpty { return "No snippets yet. Add one on the Snippets page." }
        if nav.branch == .activity { return activityRead ? "Nothing running matches." : "Reading what runs on this Mac…" }
        if nav.branch == .reminders, nav.query.isEmpty { return "No reminders pending. Type “20m stretch” at the root to set one." }
        if nav.branch == .clean, nav.query.isEmpty { return CleanMenu.waiting(CleanModule.previewer.progress) }
        if nav.branch == .emoji {
            let typed = nav.query.trimmingCharacters(in: .whitespaces)
            if typed.count < MenuNavigator.minimumQuery { return emojiCategory == EmojiGrid.mostUsed ? "No emoji picked yet. The ones you paste or copy show here." : "Nothing matches." }
            return "No emoji for “\(typed)”. Try a word such as heart, party or cat."
        }
        // Card agent-bo-95422979: an empty Translate asks for text instead of reporting a miss.
        if nav.branch == .translate {
            return nav.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= MenuNavigator.minimumQuery
                ? "Translating…" : "Type to translate; the language is detected automatically."
        }
        // The Files view emptied by Search inside (N5) or Tabbed to, and Packages Tabbed to: what typing does.
        if let line = nav.emptyLine { return line }
        if nav.inFiles, nav.shownFileFilters != FileFilters(hidden: nav.fileFilters.hidden) {
            return "Nothing matches. Filters are on: ⌘1 ⌘2 ⌘3 step them, or click a chip's × to drop one."
        }
        return "Nothing matches."
    }
}

extension MenuModel {
    /// A root search: no branch, something typed or a kind Tab shows (Sven 2026-10-12), so the kind tabs show.
    var searchingRoot: Bool { nav.branch == nil && (!nav.query.isEmpty || nav.only != nil) }
    /// The root as it opens: no branch, nothing typed, no kind shown, not a picker.
    var atRoot: Bool { nav.branch == nil && !nav.isList && nav.query.isEmpty && nav.only == nil }
    /// A narrow list (the root's, Trigger's, Capture's) shows only the current row's count, key and chevron
    /// (mockup A); the wide ones keep each row's key.
    var quiet: Bool { shape == .narrow }
    /// The headings by the index of the row each sits over (MenuGroups); a kind listed whole before anything is typed has
    /// no best match to head, and every window listed whole heads its workspace (frame B2).
    var headings: [Int: MenuGroups.Group] {
        if nav.branch == nil, !nav.isList, nav.query.isEmpty, nav.only == .window { return workspaceHeadings }
        if nav.isLive || nav.branch == .activity && !nav.isList { return MenuGroups.sections(nav.rows) }
        return MenuGroups.headings(nav.rows, searching: nav.branch == nil && !nav.isList && !nav.query.isEmpty, branch: nav.branch)
    }

    /// "Workspace 2" over the first window of each workspace, as the provider lists them by workspace.
    private var workspaceHeadings: [Int: MenuGroups.Group] {
        var out: [Int: MenuGroups.Group] = [:], last: String?
        for (i, row) in nav.rows.enumerated() {
            guard case .window(let id) = row.target, let workspace = windows.first(where: { $0.id == id })?.workspace else { continue }
            if workspace != last { out[i] = .section("Workspace \(workspace)") }
            last = workspace
        }
        return out
    }

    /// The search line's count: what a typed root search found, its offers never counted ("8 results"), or what a kind Tab
    /// lists whole holds ("10 windows"); nil with nothing to count (Files and Packages before a search).
    var resultCount: String? {
        guard searchingRoot else { return nil }
        let found = nav.rows.count { !$0.isOffer }
        if !nav.query.isEmpty { return "\(found) result\(found == 1 ? "" : "s")" }
        guard found > 0, let only = nav.only else { return nil }
        return "\(found) \(only.rawValue)\(found == 1 ? "" : "s")"
    }
    var prompt: String { nav.isList || nav.branch != nil ? "Filter…" : "Search or pick…" }

    /// The list and Cmd+K's actions as the pointer drives them (card agent-bo-95422994): MenuNavigator's seams.
    func pointedRows(_ pointer: PointerTrack) -> PointerList {
        PointerList(track: pointer, name: "rows", selection: { self.nav.selection }, hover: { self.nav.point(at: $0) },
                    click: { self.click(at: $0) }, shown: { self.onRowShown?($0) }, under: { index, inside in
                        if inside { self.underPointer = self.nav.rows.indices.contains(index) ? self.nav.rows[index].target : nil }
                        else if self.nav.rows.indices.contains(index), self.underPointer == self.nav.rows[index].target { self.underPointer = nil }
                    })
    }
    func pointedActions(_ pointer: PointerTrack) -> PointerList {
        PointerList(track: pointer, name: "actions", selection: { self.nav.actions?.selection },
                    hover: { self.nav.pointAction(at: $0) }, click: { self.clickAction(at: $0) })
    }

    var footer: [KeyHint] {
        if nav.actions != nil { return [("↵", "run"), ("↑↓", "move"), ("Esc", "back")] }
        if let chip {
            let download = chip.selected?.section == TranslateLanguages.download
            return [("↵", chip.purpose == .emojiCategory ? "show" : download ? "download" : "pick"), ("Esc", "close")]
        }
        if atRoot, !nav.selectedActions.isEmpty { return baseFooter + [("⌘K", "actions")] }
        return baseFooter
    }

    /// Words in the foot that are no key: GIPHY's attribution (story 164), shown wherever its GIFs are listed.
    var footerNote: String? {
        if nav.branch == .activity, !nav.isList { return activityNote }
        return nav.branch == .stickers && nav.rows.contains { if case .sticker(.giphy) = $0.target { true } else { false } } ? Giphy.attribution : nil
    }

    /// The root's way out, against the foot's right edge (mockup A).
    var footerTrailing: [KeyHint] { atRoot && nav.actions == nil ? [("esc", "close")] : [] }

    /// Mockup C's right side, at a root search, inside a branch and under an extension's detail: what Return does to the
    /// current row, unless the left already says (Apps, Update, Clean, Remove), and Actions ⌘K when the row has any. A
    /// detail's Return is its first action, named as the extension names it.
    var footerCommands: [KeyHint] {
        guard nav.actions == nil, chip == nil, let row = nav.selected, nav.shownDetail != nil || nav.isLive || (!nav.isList && !atRoot) else { return [] }
        // A detail's Cmd+K lists its own actions, so it has them exactly when Return has a first one.
        if nav.shownDetail != nil { return row.ownActions?.first.map { [("↵", $0), ("⌘K", "Actions")] } ?? [] }
        // An extension's row, as Raycast's bar: Return's action, the second when it has a key (To-do B), then Cmd+K.
        if nav.isLive {
            guard let own = row.ownActions, let first = own.first else { return [] }
            guard own.count > 1 else { return [("↵", first)] }
            let second: [KeyHint] = (row.ownKeys?[1]).flatMap { $0 }.map { [($0.symbol, own[1])] } ?? []
            return [("↵", first)] + second + [("⌘K", "Actions")]
        }
        let actions: [KeyHint] = nav.selectedActions.isEmpty ? [] : [("⌘K", "Actions")]
        let returnShown = baseFooter.contains { $0.key == "↵" }
        let space: [KeyHint] = nav.spaceToggles ? [("Space", "Toggle")] : []
        return space + (returnShown ? [] : [("↵", row.returnLabel)]) + actions
    }

    var baseFooter: [KeyHint] {
        // Escape goes back from a pushed view as from a picker a menu row opened; otherwise it closes the panel.
        let closes = nav.back == nil && below.isEmpty
        if nav.shownDetail != nil || nav.isLive { return [("Esc", closes ? "close" : "back")] }
        if nav.isList { return [("↵", "pick"), ("Esc", closes ? "cancel" : "back")] }
        if searchingRoot, nav.inFiles { return [("Tab", "next tab"), ("⌘1 ⌘2 ⌘3", "filters")] }
        if searchingRoot { return [("Tab", "next kind"), ("⇧Tab", "previous")] }
        // → still opens the current branch; mockup A's foot leaves it out.
        if nav.branch == nil { return [("↵", "open")] }
        if nav.branch == .apps { return [("↵", "open, or focus if already open"), ("⌘↵", "show in Finder"), ("Esc", "back")] }
        if nav.branch?.browsed == .update { return [("↵", "update, asks first"), ("Esc", "back")] }
        if nav.branch == .clean { return [("↵", "on Clean asks first"), ("Esc", "back")] }
        if nav.branch?.browsed == .remove {
            return [("↵", nav.branch == .remove ? "open" : "remove, asks first"), ("Tab", "sort: \(removeOrder.title)"), ("Esc", "back")]
        }
        if nav.branch == .stickers { return [("Tab", "GIPHY \(giphyKind.next.title)"), ("Esc", "back")] }
        if nav.branch == .activity, !nav.rows.isEmpty { return [("↵", "quit"), ("⌘↵", "force quit"), ("Esc", "back")] }
        if nav.branch == .stats { return [("↵", "busiest apps"), ("Esc", "back")] }
        if nav.branch == .about { return [("Esc", "close")] }
        let paste = "paste to \(frontApp ?? "the app")"
        if nav.branch == .emoji, !nav.rows.isEmpty { return [("↵", paste), ("⌘↵", "copy"), ("Esc", "back")] }
        if nav.branch == .translate {
            guard case .copy? = nav.rows.first?.target else { return [("⇥", "languages"), ("Esc", "back")] }
            return [("↵", "copy"), ("⌘↵", paste), ("⌘S", "swap"), ("⇥", "languages")]
        }
        return [("Esc", "back")]
    }
}

struct MenuView: View {
    @Bindable var model: MenuModel
    /// The pointer the list and the Cmd+K actions follow (PointerTrack); a test passes one on its own pointer.
    @State var pointer = PointerTrack()
    @Environment(\.style) private var style
    @FocusState var searchFocused: Bool
    @FocusState var actionsFocused: Bool

    var nav: MenuNavigator { model.nav }

    /// Instrument (the Rail, RailMenu, Classic, ClassicMenu, or Line, LineMenu, as look.menuLayout says; card agent-bo-95423181) and
    /// Toybox (ToyMenu, card agent-bo-95423182) draw their own menu from the same state, keys and pointer.
    var body: some View {
        Group {
            switch style.kind {
            case .instrument:
                switch model.layout {
                case .rail: RailMenu(model: model, pointer: pointer, searchFocused: $searchFocused, actionsFocused: $actionsFocused)
                case .classic: ClassicMenu(model: model, pointer: pointer, searchFocused: $searchFocused, actionsFocused: $actionsFocused)
                case .line: LineMenu(model: model, pointer: pointer, searchFocused: $searchFocused, actionsFocused: $actionsFocused)
                }
            case .toybox: toyBody
            }
        }
        .tracksPointer(pointer)
        .onChange(of: nav.actions == nil) { if nav.actions == nil { searchFocused = true } else { actionsFocused = true } }
        .onAppear { searchFocused = true }
    }
}

/// An empty view's words: the first sentence as the line, the rest muted under it, centred (mockup A's empty view; an
/// extension's empty detail too).
struct PanelEmptyText: View {
    @Environment(\.ink) private var ink
    let text: String

    var body: some View {
        let cut = text.range(of: ". ")
        VStack(spacing: 3) {
            Text(cut.map { String(text[..<$0.lowerBound]) + "." } ?? text).font(ink.system(13.5, weight: .semibold)).foregroundStyle(Theme.text)
            if let cut { Text(text[cut.upperBound...]).font(ink.system(12)).foregroundStyle(Theme.muted) }
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
}
