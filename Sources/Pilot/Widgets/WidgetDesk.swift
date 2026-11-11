import AppKit
import Observation
import OSLog
import PilotCore
import PilotTiler
import SwiftUI

/// SwiftUI has a Widget of its own; in Pilot the name is the desktop widget.
typealias Widget = PilotCore.Widget

private let widgetLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// The desktop's widgets (ADR 0016, Q589, Q592, Q668): one borderless, non-activating panel per placement at desktop-icon
/// level + 1, on every Space. A screen's widgets show while its shown workspace has no window or Show desktop holds the
/// windows out, and the screen is in use; otherwise the panel is ordered out and its command or reading pauses. Hyper+drag
/// moves one (MouseDragTap asks `grab`); otherwise clicks pass through, except on a Trust to run card or a page. An HTML
/// widget that may run gets its page (WidgetWebView), ended once it has been hidden 60 s; a locked one gets the card and
/// never a page (Q680). With no placement nothing is armed: no tiler subscription, no observer, no timer. A right-click
/// on one opens its menu: Edit widget, Remove from desktop.
///
/// Home's widgets (placements with `home`) have no panel: Home draws their tiles and pages (HomeWidgetBlock) from this
/// desk's models, each fed only while its tile is drawn on Home in the window on screen, its page ended the moment it
/// is not (a hidden or icon-sized row draws no tile, so runs nothing).
@MainActor
final class WidgetDesk: ScreenPausing {
    static let shared = WidgetDesk()

    var store = WidgetStore.live
    /// Started by the engine once Accessibility is granted; never in the sandbox host, whose engine does not launch.
    private(set) var started = false
    private weak var tiler: TilerService?
    private(set) var placements: [Widget.Placement] = []
    private var panels: [String: NSPanel] = [:]
    private var models: [String: WidgetTileModel] = [:]
    /// Each placement's page, while it has one, and the end waiting on one hidden (60 s, Q676).
    private var pages: [String: WidgetWebView] = [:]
    /// A ready desk widget's height fitted to its content, by placement, as its page last measured it.
    private var fittedHeights: [String: Double] = [:]
    /// Each placement showing an extension's page (Q697): the Extensions page's own model, which asks it and runs its buttons.
    private var extensionPages: [String: ExtensionPageModel] = [:]
    private var pageEnds: [String: DispatchWorkItem] = [:]
    /// Trust this widget on a card: Pilot's Widgets page asks the question (set by the page; a no-op until it is).
    var askTrust: (String) -> Void = { _ in }
    /// Each shown placement's feed (its command's or reading's loop), cancelled when it hides, which stops a running child.
    private var feeds: [String: Task<Void, Never>] = [:]
    /// When each placement's command last started, so showing it again within 10 s never runs it sooner (Q676).
    private var lastStarts: [String: ContinuousClock.Instant] = [:]
    /// The shown placements with nothing to feed (no reading, no command): their finished feed stays in `feeds`, so a
    /// refresh never starts it again, and status says they are not feeding.
    private var idle: Set<String> = []
    /// Each placement's last run or reading, for `pilot status --part widgets`: its kind and Pilot's own reason, never
    /// what the program printed.
    private var lastAnswers: [String: (at: Date, kind: String, error: String?)] = [:]
    /// Each screen's state by display UUID, as the last refresh read it.
    private(set) var screens: [String: Widget.ScreenState] = [:]
    /// Whether anyone can see the screen: ScreenEvents pauses the desk with This Mac's other readers (PilotApp).
    private var inUse = true
    /// The tiler's events and the screens' changes, held only while a placement exists.
    private var events: Task<Void, Never>?
    private var screenChanges: NSObjectProtocol?
    private var refreshing: Task<Void, Never>?
    /// A Hyper+drag in progress, top-left coordinates: its placement, where the press was and the panel's frame then, and
    /// for a resize (a right press, Q695) the corner it pulls, the quadrant pressed in, as a window's resize picks it.
    private var dragging: (id: String, start: CGPoint, frame: CGRect, corner: (left: Bool, top: Bool)?)?
    /// A drag's points, written at most once a frame, newest first, as a window's drag writes them (MouseDragTap).
    private var dragFrames = LatestWins<CGPoint>(interval: 1.0 / 60)
    private var lastDragPoint: CGPoint?
    /// Counts grabs, so a frame's wait from one that ended never lands on the next.
    private var drags = 0
    /// The widget `over` found under a press, waiting for `grab`.
    private var hit: (String, CGRect)?
    private var watchingTheme = false, watchingVeil = false
    /// How many tiles Home draws now of each Home placement, in the window on screen (Edit Home's carry draws a copy
    /// beside the one it hides): only a placement drawn at least once is fed and runs a page.
    private var homeDraws: [String: Int] = [:]
    private var homeDrawn: Set<String> { Set(homeDraws.keys) }
    /// The note ids a notes widget listed last, by placement: the only notes its presses may open.
    private var noteOpens: [String: Set<String>] = [:]
    /// The repos a repos widget listed last, by placement: the only repos its presses may open.
    private var repoOpens: [String: Set<String>] = [:]
    /// Edit widget on a placement: Pilot's Widgets page opens its sheet (set by the engine; a no-op until it is).
    var editPlacement: (String) -> Void = { _ in }
    /// Remove from Home: the Widgets page takes the placement off (set by the engine; a no-op until it is).
    var removePlacement: (String) -> Void = { _ in }
    /// A desktop placement's menu, its sections and the picks checked: the Widgets page builds it (set by the engine).
    var placementMenu: (String) -> (sections: [(title: String, items: [(title: String, run: () -> Void)])], checked: Set<String>) = { _ in ([], []) }
    /// Where Home's layout is kept: a widget taken off Home leaves no row there (reload).
    var homeLayout: () -> HomeLayoutStore = { .shared }
    /// Told whether any panel shows: the mouse tap watches right presses only then (the menu).
    var shownChanged: (Bool) -> Void = { _ in }

    var armed: Bool { events != nil }
    var shownCount: Int { panels.values.filter(\.isVisible).count }

    /// The engine's start: reads the placements and arms if there are any.
    func start(tiler: TilerService) {
        guard !started else { return }
        started = true
        self.tiler = tiler
        reload()
    }

    /// The placements file changed (`pilot add|remove widgets`, the Widgets page): panels follow, and the desk arms or
    /// disarms. Before the engine started it only reads.
    func reload() {
        let read = store.readPlacements()
        // A file that does not read leaves the placements as they were: nothing closes on a read that failed.
        placements = read ?? placements
        for id in Set(models.keys).subtracting(placements.map(\.id)) { close(id) }
        // A Home row is dropped only for a placement the file, read whole, no longer holds.
        if let read {
            let onHome = Set(read.filter(\.onHome).map(\.id))
            homeLayout().forget { HomeLayout.widgetID($0).map { !onHome.contains($0) } ?? false }
        }
        syncHome()
        guard started else { return }
        // A placement moved between the desktop and Home leaves its panel.
        for id in Set(panels.keys).subtracting(placements.filter { !$0.onHome }.map(\.id)) { close(id) }
        if placements.allSatisfy(\.onHome) { disarm() } else { arm(); refresh() }
    }

    private func arm() {
        guard events == nil, let tiler else { return }
        let runner = tiler.runner
        // Show desktop ended with no focus event (a Pilot window raised, a Dock click): the widgets hide again.
        showDesktopEnded = { [weak self] in self?.showDesktopChanged() }
        events = Task { [weak self] in
            // Window events too, which TilerService drops: a first window on an empty workspace hides its widgets.
            for await _ in runner.events() {
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
        screenChanges = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watchTheme()
        watchVeil()
        widgetLog.notice("widgets: armed for \(self.placements.count, privacy: .public) placements")
    }

    private func disarm() {
        events?.cancel(); events = nil
        refreshing?.cancel(); refreshing = nil
        if let screenChanges { NotificationCenter.default.removeObserver(screenChanges) }
        screenChanges = nil
        for id in Array(panels.keys) { close(id) }
        screens = [:]
        noteShown()
    }

    func pause() { inUse = false; refresh() }
    func resume() { inUse = true; refresh() }

    /// Show desktop was pressed: the tiler sends no event for it.
    func showDesktopChanged() { if armed { refresh() } }

    /// Reads each screen's shown workspace, its windows and Show desktop a moment after the last change, then shows or
    /// hides every placement.
    func refresh() {
        guard armed, let tiler else { return }
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let answering = tiler.isAnswering
            async let shown = answering ? try? await tiler.runner.visibleWorkspaces() : []
            async let listed = answering ? try? await tiler.runner.windows(.all) : []
            let visible = await shown ?? tiler.perMonitor, windows = await listed ?? []
            guard !Task.isCancelled else { return }
            let desktop = showDesktopWorkspace()
            var states: [String: Widget.ScreenState] = [:]
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                let workspace = visible.first { $0.displayUUID == uuid }?.workspace
                states[uuid] = Widget.ScreenState(inUse: inUse, tilerAnswering: answering, workspace: workspace,
                                                  windows: workspace.map { w in windows.count { $0.workspace == w } } ?? 0,
                                                  showingDesktop: workspace != nil && workspace == desktop)
            }
            screens = states
            apply()
        }
    }

    /// Shows the placements whose screen shows, on their one workspace when they have one; hides the rest. Home's are
    /// Home's.
    private func apply() {
        for placement in placements where !placement.onHome {
            let screen = Self.screen(placement.screen)
            let shows = screen?.displayUUID.flatMap { screens[$0] }.map { placement.why(on: $0).shows } ?? false
            if shows, let screen { show(placement, on: screen) } else { hide(placement.id) }
        }
        noteShown()
    }

    /// Tells the mouse tap whether a panel shows (it turns on or off only on a change).
    private func noteShown() { shownChanged(shownCount > 0) }

    /// The desktop read again, and Home's widgets fed or stopped as Home shows: the one resync after any change.
    private func resync() {
        refresh()
        syncHome()
    }

    private func show(_ placement: Widget.Placement, on screen: NSScreen) {
        let panel = panels[placement.id] ?? makePanel(placement)
        var placed = placement
        if let height = fittedHeights[placement.id] { placed.height = height }
        let frame = Self.flip(placed.frame(on: Self.flip(screen.frame)))
        // A panel under a Hyper+drag stays where the pointer has it until the drop.
        if panel.frame != frame, dragging?.id != placement.id { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        pageEnds.removeValue(forKey: placement.id)?.cancel()
        if feeds[placement.id] == nil { feeds[placement.id] = feed(placement) }
    }

    /// Ordered out, its feed cancelled: a running command is stopped with every process it started. Its page ends after
    /// 60 s hidden.
    private func hide(_ id: String) {
        feeds.removeValue(forKey: id)?.cancel()
        idle.remove(id)
        panels[id]?.orderOut(nil)
        guard pages[id] != nil, pageEnds[id] == nil else { return }
        let end = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endPage(id) } }
        pageEnds[id] = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: end)
    }

    private func close(_ id: String) {
        hide(id)
        endPage(id)
        panels.removeValue(forKey: id)?.close()
        models[id] = nil
        lastAnswers[id] = nil
        fittedHeights[id] = nil
        extensionPages[id] = nil
        noteOpens[id] = nil
        repoOpens[id] = nil
    }

    /// Fits a placement to its content's height until Sven resizes it: then his size stays (Placement.sized).
    private func fit(_ id: String, _ height: Double) {
        guard placements.first(where: { $0.id == id })?.sized != true else { return }
        let height = Widget.Size.clamp(height)
        guard abs((fittedHeights[id] ?? 0) - height) >= 2 else { return }
        fittedHeights[id] = height
        apply()
    }

    /// The size a fitted page's class follows: its placement's until Sven resizes it, then none (its live size).
    private static func fixed(_ placement: Widget.Placement) -> CGSize? {
        placement.sized == true ? nil : CGSize(width: placement.width, height: placement.height)
    }

    private func endPage(_ id: String) {
        pageEnds.removeValue(forKey: id)?.cancel()
        pages.removeValue(forKey: id)?.end()
        models[id]?.page = nil
    }

    /// A widget's trust or files changed (Trust this widget, Duplicate, an import, Uninstall, and any later surface that
    /// writes trust): each of its placements starts over, its page ended and its feed started again by the next refresh.
    /// A locked widget's feed waits idle for this.
    func widgetChanged(_ widget: String) {
        for placement in placements where placement.widget == widget { restart(placement.id) }
        resync()
    }

    private func restart(_ id: String) {
        feeds.removeValue(forKey: id)?.cancel()
        idle.remove(id)
        models[id]?.reset()
        endPage(id)
    }

    /// One placement's own settings changed (Edit widget): it alone starts over with them.
    func placementChanged(_ id: String) {
        placements = store.placements()
        restart(id)
        resync()
    }

    /// A press on a widget's button (Q697). Only a widget that may act runs one: Pilot's own, made here or trusted; a locked
    /// widget asks Trust this widget instead, whose question lists its buttons. A button of its own runs its Pilot action
    /// by id; an extension page's button does what it does on that page, the page asked again after; any other button a
    /// feed prints runs nothing, so what runs is only ever what the Trust question listed.
    private func press(_ action: Extension.Item.Action, on widget: Widget, placement id: String) {
        guard ReadyWidgets.isReady(widget.id) || store.trust(of: widget).runs else { return askTrust(widget.id) }
        // A note's row or Open, as Pilot built it for a notes widget: one of the notes it listed, opened in the panel.
        if case .notes = widget.data, case .pilot(let word) = action.kind, word.hasPrefix(WidgetNotes.openPrefix) {
            let note = String(word.dropFirst(WidgetNotes.openPrefix.count))
            guard noteOpens[id]?.contains(note) == true else { return }
            return NotesPanel.shared.show(note: note)
        }
        // A repo's row, as Pilot built it for a repos widget: one of the repos it listed.
        if widget.data == .repos, case .pilot(let word) = action.kind, word.hasPrefix(WidgetRepos.openPrefix) {
            let repo = String(word.dropFirst(WidgetRepos.openPrefix.count))
            guard repoOpens[id]?.contains(repo) == true else { return }
            return WidgetRepos.open(repo)
        }
        // A declared button by its title and its action both, so a program cannot print a button that reads as another;
        // or one Sven picked in this placement's Edit widget, as it saved it.
        // As the feed built them from this placement's saved values: checked again below, shape and registry.
        let picked = models[id]?.picked ?? []
        if case .pilot(let actionID) = action.kind,
           (widget.buttons + picked).contains(where: { $0.action == actionID && $0.title == action.title }),
           Widget.isActionID(actionID) {
            guard let run = WidgetDesk.buttonAction(actionID) else { return HUD.tip("\(widget.title): Pilot has no action \(actionID)") }
            widgetLog.notice("widget \(widget.id, privacy: .public): button runs \(actionID, privacy: .public)")
            return run.run()
        }
        guard case .extensionPage = widget.data, let page = extensionPages[id] else {
            return widgetLog.notice("widget \(widget.id, privacy: .public): a button its feed printed, not one it declares, runs nothing")
        }
        // As on the extension's page: its action runs as the extension's, then the page is asked again.
        Task { [weak self] in
            await page.change(action) { ExtensionActions.run($0, in: $1, inputs: $2) }
            self?.models[id]?.blocks = page.blocks ?? []
        }
    }

    /// A press on a Launcher tile: only Pilot's own widget's, and only a row this placement's Edit widget saved, as the
    /// feed drew it; it runs as its Hyper+Space row does.
    private func launch(_ key: String, on widget: Widget, placement id: String) {
        guard ReadyWidgets.isReady(widget.id), widget.menuField != nil, models[id]?.tiles.contains(where: { $0.key == key }) == true else { return }
        WidgetLauncher.run(key)
    }

    /// The buttons picked in Edit widget, each titled by its action's name, those Pilot has now.
    static func picked(_ value: JSONValue?) -> [Widget.Button] {
        Widget.picks(value).compactMap { id in buttonAction(id).map { Widget.Button(title: String($0.label.prefix(24)), action: id) } }
    }

    /// What a widget's button runs: an action the registry holds as itself (none built on the fly from its id, as a folder
    /// design's or a setting's is), or a command of an extension installed now (its folder read: a press, or a check).
    static func buttonAction(_ id: String) -> Action? {
        guard let engine = Engine.shared else { return nil }
        if id.hasPrefix(Extension.prefix) {
            return Extension.command(inAction: id, in: Extension.find(in: Extension.folder).extensions) != nil ? engine.action(id) : nil
        }
        return engine.registry.actions[id] != nil ? engine.action(id) : nil
    }

    /// Pilot's theme changed: every page starts over, so it loads with the new colours from its first data (WidgetWebView
    /// sends the theme with it). Watched only while armed, once at a time.
    private func watchTheme() {
        guard armed || !homeDrawn.isEmpty, !watchingTheme else { return }
        watchingTheme = true
        withObservationTracking { _ = Look.shared.theme.id } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.watchingTheme = false
                    guard self.armed || !self.homeDrawn.isEmpty else { return }
                    for id in Array(self.pages.keys) { self.restart(id) }
                    self.resync()
                    self.watchTheme()
                }
            }
        }
    }

    /// Blur, Glass or Transparency changed: each page's veil follows at once, without starting over. Watched as watchTheme is.
    private func watchVeil() {
        guard armed || !homeDrawn.isEmpty, !watchingVeil else { return }
        watchingVeil = true
        withObservationTracking { _ = Look.shared.widgetLightTint } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.watchingVeil = false
                    guard self.armed || !self.homeDrawn.isEmpty else { return }
                    self.pages.values.forEach { $0.applyVeil() }
                    self.watchVeil()
                }
            }
        }
    }

    private func makePanel(_ placement: Widget.Placement) -> NSPanel {
        let model = WidgetTileModel()
        models[placement.id] = model
        let panel = WidgetPanel()
        // The tile takes clicks only for its card's button or its page.
        model.clicksChanged = { [weak panel, weak model] in panel?.ignoresMouseEvents = !(model?.takesClicks ?? false) }
        let tile = NSHostingView(rootView: WidgetTile(model: model) { [weak self] in self?.askTrust($0) }.styled(.hud))
        let ground = NSView()
        tile.autoresizingMask = [.width, .height]
        ground.addSubview(tile)
        panel.contentView = ground
        tile.frame = ground.bounds
        panels[placement.id] = panel
        return panel
    }

    /// A page the desktop or Home shows now for widget `id`, any placement's: the Widgets page's preview takes its picture
    /// instead of loading the page again (WidgetPreviews).
    func livePage(of id: String) -> WidgetWebView? {
        placements.lazy.filter { $0.widget == id }.compactMap { self.pages[$0.id] }.first
    }

    /// Its page, made now if it may run and has none: placed over the tile, its corners clipped to the tile's. A Home
    /// widget's is placed by Home (HomeWidgetPage).
    private func page(_ id: String, _ widget: Widget) -> WidgetWebView? {
        if let page = pages[id] { return page }
        let ground = panels[id]?.contentView
        guard let placement = placements.first(where: { $0.id == id }), ground != nil || homeDrawn.contains(id) && placement.onHome,
              let page = WidgetWebView(widget: widget, store: store, size: ground?.bounds.size ?? CGSize(width: placement.width, height: placement.height),
                                       layout: widget.layout(of: placement)) else { return nil }
        page.view.autoresizingMask = [.width, .height]
        page.view.wantsLayer = true
        page.view.layer?.cornerRadius = 18
        page.view.layer?.masksToBounds = true
        if let ground { page.view.frame = ground.bounds; ground.addSubview(page.view) }
        pages[id] = page
        // A Home page goes into the tile Home draws it in (hostPage), if one is up already.
        if ground == nil { placePage(id) }
        models[id]?.page = page.seeThrough
        // Pilot's desk widgets take their content's height, kept on the screen (Placement.frame); past it they scroll.
        // While fitted, Auto's class is its placement's size's, never the fitted height's: a smaller layout's shorter
        // page would fall into a smaller class still.
        if ReadyWidgets.isDesk(widget), ground != nil {
            page.fitted = { [weak self] height in self?.fit(id, height) }
            page.fixed = Self.fixed(placement)
        }
        return page
    }

    /// What a widget shows before its data: the Trust to run card when it would run (a page or a command) but is locked,
    /// else its page for HTML; nil when the feed draws blocks or the card shows. WidgetWebView checks trust again.
    private func ground(_ id: String, _ widget: Widget) -> WidgetWebView? {
        let locked = WidgetAsks.runsOnShow(widget) && !store.trust(of: widget).runs
        models[id]?.locked = locked ? widget : nil
        // A page made while it was trusted ends once it shows again locked (its folder replaced outside Pilot); a
        // reading- or command-fed page is checked each turn too, and the scheme answers no locked page's request.
        if locked { endPage(id) }
        return widget.draw == .html && !locked ? page(id, widget) : nil
    }

    // MARK: Feeds

    /// The placement's loop while it shows: its reading every 10 s, or its command every `every` s (10 at least, never two
    /// at once, never sooner than 10 s after the last start). widget.json and the trust record are read again before each
    /// run, so an edit runs its new argv; one that does not read (a typo, a save caught half written) waits and tries
    /// again. A locked widget shows its card and waits idle: Trust this widget restarts it (widgetChanged).
    private func feed(_ placement: Widget.Placement) -> Task<Void, Never> {
        let store = store, id = placement.id, size = Widget.Size(width: placement.width, height: placement.height)
        // widget.json (up to 2 MB) is read off the main actor.
        let read = { @concurrent () async -> Widget? in store.widget(placement.widget) }
        let unread = "No widget \(placement.widget) is installed, or its widget.json does not read: pilot widget check \(placement.widget) says why"
        return Task { [weak self] in
            guard let model = self?.models[id] else { return }
            var first = await read()
            while first == nil, !Task.isCancelled {
                model.blocks = []; model.message = unread
                self?.lastAnswers[id] = (.now, "unread", "its widget.json does not read")
                try? await Task.sleep(for: .seconds(Widget.fewestSeconds))
                first = await read()
            }
            guard let widget = first, !Task.isCancelled else { return }
            let values = widget.settings.isEmpty ? [:] : store.values(of: widget, placement: placement)
            model.show(widget, values: values)
            model.layout = widget.layout(of: placement)
            // GitHub checks' list scrolls, so its tile takes the mouse too: a panel that ignores it sends the wheel to the desktop.
            model.presses = WidgetAsks.acts(widget) || widget.data == .ci
            model.press = { [weak self] action in self?.press(action, on: widget, placement: id) }
            model.launch = { [weak self] key in self?.launch(key, on: widget, placement: id) }
            // The page or the card first; a locked widget gets the card and its feed waits idle.
            let page = self?.ground(id, widget)
            if model.locked != nil || (widget.draw == .html && page == nil) {
                self?.lastAnswers[id] = (.now, "locked", nil)
                self?.idle.insert(id)
                return
            }
            if widget.id == ReadyWidgets.folder { return await WidgetFolder.feed(model, values: values, placement: id) }
            switch widget.data {
            case .reading(let readings):
                async let held: Void = WidgetReadings.watch(readings)
                while !Task.isCancelled {
                    // A page fed by readings runs nothing but itself: its trust is read again each turn, and a lock ends it.
                    if page != nil, !store.trust(of: widget).runs {
                        model.locked = widget; self?.endPage(id); self?.idle.insert(id)
                        self?.lastAnswers[id] = (.now, "locked", nil)
                        return
                    }
                    let data = await WidgetReadings.data(readings)
                    if let page { page.send(data); WidgetPreviews.shared.remember(widget.id, page) } else { model.blocks = WidgetReadings.blocks(readings, data); model.message = nil }
                    self?.lastAnswers[id] = (.now, "reading", nil)
                    try? await Task.sleep(for: .seconds(Widget.fewestSeconds))
                }
                await held
            case .command(_, var every):
                while !Task.isCancelled {
                    if let last = self?.lastStarts[id] {
                        let wait = Duration.seconds(Widget.fewestSeconds) - (ContinuousClock.now - last)
                        if wait > .zero { try? await Task.sleep(for: wait) }
                        if Task.isCancelled { return }
                    }
                    self?.lastStarts[id] = .now
                    guard let current = await read() else {
                        model.blocks = []; model.message = unread
                        self?.lastAnswers[id] = (.now, "unread", "its widget.json does not read")
                        try? await Task.sleep(for: .seconds(Widget.every(every)))
                        continue
                    }
                    // An edit's own seconds; one that left commands for a reading shows as such the next time it shows.
                    if case .command(_, let asked) = current.data { every = asked }
                    // The runner reads the trust record and refuses a locked widget; its answer says which it was.
                    let run = await WidgetRunner.run(current, store: store, size: size, placement: placement)
                    if Task.isCancelled { return }
                    var why: String?
                    switch run.answer {
                    case _ where !run.trust.runs: model.blocks = []; model.locked = current; self?.endPage(id)
                    case .blocks(let blocks): model.blocks = blocks; model.message = nil
                    case .data(let data): if let page { page.send(data); WidgetPreviews.shared.remember(widget.id, page) } else { model.message = "It sent data, which only a page draws" }
                    // The tile shows what the program said; status keeps Pilot's reason only.
                    case .error(let reason, let said): model.message = [reason, said].compactMap { $0 }.joined(separator: ": "); why = reason
                    }
                    self?.lastAnswers[id] = (.now, run.trust.runs ? run.answer.kind : "locked", why)
                    if !run.trust.runs { self?.idle.insert(id); return }
                    try? await Task.sleep(for: .seconds(Widget.every(every)))
                }
            case .extensionPage(let extID):
                // An extension's page as its blocks, asked by the Extensions page's own model at the page's pace while it
                // shows; it only shows, so a locked widget shows it too (Q697). Its buttons are WidgetDesk.press's.
                guard let self else { return }
                let page = self.extensionPages[id] ?? ExtensionPageModel(id: extID)
                self.extensionPages[id] = page
                while !Task.isCancelled {
                    await page.refresh()
                    if Task.isCancelled { return }
                    let why = page.gone ? "No extension \(extID) with a page is installed" : page.problem
                    (model.blocks, model.message) = (page.blocks ?? [], why)
                    self.lastAnswers[id] = (.now, "extension", why)
                    try? await Task.sleep(for: .seconds(max(page.every, Widget.fewestSeconds)))
                }
            case .setting(let name):
                // One of its own settings as text (the note), read when it shows; Edit widget restarts it (placementChanged).
                let text = values[name]?.string ?? ""
                if let page { page.send(.object([name: .string(text)])); WidgetPreviews.shared.remember(placement.widget, page) } else { model.blocks = [.markdown(text.isEmpty ? "–" : text)] }
                self?.idle.insert(id)
            case .notes(let name):
                // Pilot's notes as its note setting picks them, read again only when a note or the pins change.
                let picked = values[name]?.string ?? "", folder = WidgetNotes.folder
                let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let watch = FolderWatch.start(folder, only: WidgetNotes.watched) { changed.yield() }
                defer { watch?.cancel() }
                changed.yield()
                for await _ in changes {
                    let (blocks, opens) = WidgetNotes.blocks(await WidgetNotes.read(folder), picked: picked)
                    if Task.isCancelled { return }
                    (model.blocks, model.message) = (blocks, nil)
                    self?.noteOpens[id] = opens
                    self?.lastAnswers[id] = (.now, "notes", nil)
                }
            case .repos:
                // ~/code's repos with work waiting, read as it shows (the last read, if under a minute old) and every 5
                // minutes while it does; no watcher.
                while !Task.isCancelled {
                    let repos = await WidgetRepos.read()
                    if Task.isCancelled { return }
                    (model.blocks, model.message) = (WidgetRepos.blocks(repos), nil)
                    self?.repoOpens[id] = Set(repos.filter { !$0.clean }.map(\.name))
                    self?.lastAnswers[id] = (.now, "repos", nil)
                    try? await Task.sleep(for: WidgetRepos.wait())
                }
            case .ci:
                // Each repo's latest CI run, read as it shows (the last read, if under 5 minutes old) and every 5 minutes
                // while it does (WidgetCI).
                while !Task.isCancelled {
                    let runs = await WidgetCI.read()
                    if Task.isCancelled { return }
                    (model.blocks, model.message) = (WidgetCI.blocks(runs), nil)
                    self?.lastAnswers[id] = (.now, "ci", nil)
                    try? await Task.sleep(for: WidgetCI.wait())
                }
            case .github: await WidgetGitHub.feed(model, user: WidgetGitHub.user(values[WidgetGitHub.userName])) { self?.lastAnswers[id] = (.now, "github", $0) }
            case .nowPlaying:
                // What plays, from the one watch every shown placement holds (NowPlaying); its tile draws it. Its controls
                // act, so a widget not Pilot's own needs trust first, as a press elsewhere does.
                guard ReadyWidgets.isReady(widget.id) || store.trust(of: widget).runs else { model.locked = widget; self?.idle.insert(id); return }
                model.nowPlaying = NowPlaying.shared; self?.lastAnswers[id] = (.now, "now playing", nil); await NowPlaying.shared.watch()
            case .markets(let name):
                // The symbols Edit widget picked, priced by the Markets extension every 60 s while it shows (WidgetMarkets).
                await WidgetMarkets.feed(model, values: values, symbols: name, placement: id) { self?.lastAnswers[id] = (.now, "markets", $0) }
            case .none:
                if page == nil {
                    model.message = widget.actionsField == nil && widget.menuField == nil ? widget.description
                        : model.picked.isEmpty && model.tiles.isEmpty ? "Nothing picked yet: right-click it › Edit widget to pick its tiles." : nil
                }
                self?.idle.insert(id)
            }
        }
    }

    // MARK: Home

    /// One of a Home widget's tiles is drawn, in the window on screen, or no longer (HomeWidgetBlock, each draw paired
    /// with its own release): its feed starts with the first and stops, its page ended at once, with the last, so a web
    /// widget on Home runs only while Home draws it.
    func drawnOnHome(_ id: String, _ drawn: Bool) {
        let count = (homeDraws[id] ?? 0) + (drawn ? 1 : -1)
        homeDraws[id] = count > 0 ? count : nil
        syncHome()
        if drawn { watchTheme(); watchVeil() }
    }

    /// Each Home placement fed while its tile is drawn, else stopped, its page ended at once.
    private func syncHome() {
        for placement in placements where placement.onHome {
            let id = placement.id
            if homeDrawn.contains(id) {
                if models[id] == nil { models[id] = WidgetTileModel() }
                if feeds[id] == nil { feeds[id] = feed(placement) }
            } else {
                feeds.removeValue(forKey: id)?.cancel()
                idle.remove(id)
                endPage(id)
            }
        }
    }

    /// What Home draws for its widgets: each Home placement with its tile's model, which the feed fills (its widget's
    /// title and icon among the rest), so a redraw reads no file.
    func homeWidgets() -> [HomeWidget] {
        placements.filter(\.onHome).map { placement in
            let model = models[placement.id] ?? { let made = WidgetTileModel(); models[placement.id] = made; return made }()
            return HomeWidget(placement: placement, model: model)
        }
    }

    /// Each Home page's hosts, the views Home draws it in, oldest first: the page sits in the newest, and goes back to
    /// the one before when that one goes (Edit Home's carry draws a copy over a tile it hides).
    private var pageHosts: [String: [NSView]] = [:]

    func hostPage(_ id: String, in ground: NSView) {
        pageHosts[id, default: []].append(ground)
        placePage(id)
    }

    func unhostPage(_ id: String, from ground: NSView) {
        pageHosts[id]?.removeAll { $0 === ground }
        if pageHosts[id]?.isEmpty == true { pageHosts[id] = nil }
        placePage(id)
    }

    /// The page in its newest host, filling it.
    func placePage(_ id: String) {
        guard let view = pages[id]?.view, let ground = pageHosts[id]?.last, view.superview !== ground else { return }
        view.removeFromSuperview()
        view.frame = ground.bounds
        ground.addSubview(view)
    }

    // MARK: Menu

    /// A right press, plain or with Hyper and no drag, on a shown widget (the mouse tap's, after its callback returned):
    /// its menu at the pointer, as the Widgets page builds it (WidgetsPageModel.menu).
    func openMenu(at point: CGPoint) {
        guard let id = panels.first(where: { $0.value.isVisible && Self.flip($0.value.frame).contains(point) })?.key else { return }
        let menu = placementMenu(id)
        guard !menu.sections.isEmpty else { return }
        BarMenu.pop(sections: menu.sections, checked: menu.checked)
    }

    // MARK: Hyper+drag

    /// Whether a shown widget is at `point`, from the panels' own frames (no window server call); the one found waits for
    /// `grab`, so a press walks the panels once.
    func over(_ point: CGPoint) -> Bool {
        hit = armed ? panels.lazy.filter { $0.value.isVisible }.map { ($0.key, Self.flip($0.value.frame)) }.first { $0.1.contains(point) } : nil
        return hit != nil
    }

    /// A Hyper press at `point` (top-left coordinates, from the mouse tap) on the widget `over` found: true when it is
    /// still there, which the drag then moves, or with `resize` (a right press, Q695) resizes from the corner nearest the
    /// press, as Hyper+right-drag resizes a window; the press is the tap's to keep from Finder.
    func grab(at point: CGPoint, resize: Bool = false) -> Bool {
        defer { hit = nil }
        guard armed, let (id, frame) = hit, frame.contains(point) else { return false }
        dragging = (id, point, frame, resize ? (point.x < frame.midX, point.y < frame.midY) : nil)
        (dragFrames, lastDragPoint) = (LatestWins(interval: 1.0 / 60), nil)
        drags += 1
        return true
    }

    /// The pointer moved during a grab: the panel follows, or its pulled corner does, at most once a frame.
    func drag(to point: CGPoint) {
        guard dragging != nil else { return }
        lastDragPoint = point
        dragStep(dragFrames.offer(point, now: CACurrentMediaTime()))
    }

    private func dragStep(_ step: LatestWins<CGPoint>.Step) {
        switch step {
        case .idle: break
        case .wait(let delay):
            let grab = drags
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.dragging != nil, self.drags == grab else { return }
                    self.dragStep(self.dragFrames.woke(now: CACurrentMediaTime()))
                }
            }
        case .write(let point):
            move(to: point)
            dragStep(dragFrames.written(now: CACurrentMediaTime()))
        }
    }

    /// The panel at `point` of a grab, never smaller than a widget may be.
    private func move(to point: CGPoint) {
        guard let dragging, let panel = panels[dragging.id] else { return }
        let dx = point.x - dragging.start.x, dy = point.y - dragging.start.y
        var frame = dragging.frame
        if let corner = dragging.corner {
            // A resized page's class follows its size from the first step.
            pages[dragging.id]?.fixed = nil
            let width = Widget.Size.clamp(frame.width + (corner.left ? -dx : dx)), height = Widget.Size.clamp(frame.height + (corner.top ? -dy : dy))
            if corner.left { frame.origin.x = frame.maxX - width }
            if corner.top { frame.origin.y = frame.maxY - height }
            frame.size = CGSize(width: width, height: height)
            panel.setFrame(Self.flip(frame), display: false)
        } else {
            frame.origin = CGPoint(x: frame.minX + dx, y: frame.minY + dy)
            panel.setFrameOrigin(Self.flip(frame).origin)
        }
    }

    /// A grab whose release went by unseen (the mouse tap saw the next press of its button first): the panel goes back
    /// where it was, nothing saved and no menu opened.
    func cancelGrab() {
        guard let held = dragging else { return }
        dragging = nil
        lastDragPoint = nil
        panels[held.id]?.setFrame(Self.flip(held.frame), display: false)
        refix(held.id)
        widgetLog.notice("widgets: a grab of \(held.id, privacy: .public) ended unseen; cancelled")
    }

    /// The grab let go: the placement keeps its new place, as a fraction of the screen it landed on, and a resize its new
    /// size, which a desk widget's fitting then leaves alone.
    func drop() {
        guard let held = dragging else { return }
        // A Hyper right press let go where it went down (within a click's slop) is a click: the panel goes back as it was
        // and the widget's menu opens, nothing saved.
        let clicked = held.corner != nil
            && (lastDragPoint.map { hypot($0.x - held.start.x, $0.y - held.start.y) <= MouseDragTap.clickSlop } ?? true)
        if clicked { panels[held.id]?.setFrame(Self.flip(held.frame), display: false) } else if let last = lastDragPoint { move(to: last) }
        dragging = nil
        if clicked { refix(held.id); return openMenu(at: held.start) }
        guard let panel = panels[held.id], let i = placements.firstIndex(where: { $0.id == held.id }) else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        placements[i].screen = screen.displayUUID
        placements[i].move(to: Self.flip(panel.frame), on: Self.flip(screen.frame))
        // A resize that changed nothing leaves the placement fitted to its content.
        if held.corner != nil, panel.frame.size != held.frame.size {
            (placements[i].width, placements[i].height, placements[i].sized) = (panel.frame.width, panel.frame.height, true)
            fittedHeights[held.id] = nil
        }
        do { try store.save(placements) } catch { widgetLog.error("widgets: placement not saved: \(error.localizedDescription, privacy: .public)") }
    }

    /// A resize that came to nothing: a fitted page's class follows its placement's size again.
    private func refix(_ id: String) {
        guard let page = pages[id], page.fitted != nil, let placement = placements.first(where: { $0.id == id }) else { return }
        page.fixed = Self.fixed(placement)
    }

    // MARK: Status

    /// `pilot status --part widgets`: the installed widgets with their trust, each placement with whether it shows and
    /// why, and each screen's state.
    func status() -> JSONValue {
        if !started { placements = store.placements() }
        let (widgets, broken) = store.installed()
        let installed: [JSONValue] = widgets.map { widget in
            let trust = store.trust(of: widget)
            return .object(["id": .string(widget.id), "title": .string(widget.title), "draw": .string(widget.draw.rawValue),
                            "data": .string(widget.data.label), "trust": .string(trust.rawValue), "runs": .bool(trust.runs)])
        }
        let rows: [JSONValue] = placements.map { placement in
            let uuid = Self.screen(placement.screen)?.displayUUID
            let state = uuid.flatMap { screens[$0] }
            let widget = store.widget(placement.widget)
            var row: [String: JSONValue] = ["id": .string(placement.id), "widget": .string(placement.widget), "home": .bool(placement.onHome),
                                            "screen": placement.screen.map(JSONValue.string) ?? .string("main"),
                                            "workspace": placement.workspace.map(JSONValue.string) ?? .string("all"),
                                            "shown": .bool(panels[placement.id]?.isVisible ?? false),
                                            "feeding": .bool(feeds[placement.id] != nil && !idle.contains(placement.id)),
                                            "page": .bool(pages[placement.id] != nil), "card": .bool(models[placement.id]?.locked != nil),
                                            "seeThrough": models[placement.id]?.page.map(JSONValue.bool) ?? .null,
                                            "layout": .string(widget?.layout(of: placement)?.rawValue ?? "auto")]
            row["why"] = .string(placement.onHome ? (homeDrawn.contains(placement.id) ? "Home draws it" : "it is on Home, which is not drawing it")
                                    : !started ? "the desk is not running (Pilot's engine has not started)"
                                    : uuid == nil ? "its screen is not connected" : state.map { placement.why(on: $0).reason } ?? "not read yet")
            // Its settings as it runs with them (its own over its widget's, no password), and the buttons it builds from
            // an actions setting's picks, those Pilot has.
            if let widget, !widget.settings.isEmpty {
                let values = store.values(of: widget, placement: placement)
                row["settings"] = .object(values)
                if let field = widget.actionsField { row["buttons"] = .array(Self.picked(values[field.name]).map { .string($0.line) }) }
                if let field = widget.menuField { row["tiles"] = .array(WidgetLauncher.tiles(values[field.name]).map { .string("\($0.title) → \($0.key)") }) }
            }
            if let last = lastAnswers[placement.id] {
                row["last"] = .object(["at": .string(last.at.ISO8601Format()), "answer": .string(last.kind), "error": last.error.map(JSONValue.string) ?? .null])
            }
            return .object(row)
        }
        let states: [JSONValue] = screens.sorted { $0.key < $1.key }.map { uuid, s in .object(["screen": .string(uuid), "workspace": s.workspace.map(JSONValue.string) ?? .null, "windows": .number(Double(s.windows)),
                            "showDesktop": .bool(s.showingDesktop), "inUse": .bool(s.inUse), "shows": .bool(s.shows), "why": .string(s.why.reason)])
        }
        return .object(["running": .bool(started), "armed": .bool(armed), "folder": .string(store.widgets.path),
                        "installed": .array(installed), "broken": .array(broken.map { .object(["folder": .string($0.folder), "why": .string($0.why)]) }),
                        "placements": .array(rows), "panelsShown": .number(Double(shownCount)), "pages": .number(Double(pages.count)),
                        "homeDrawn": .number(Double(homeDrawn.count)),
                        "screens": .array(states)])
    }

    // MARK: Geometry

    /// The screen a placement names, the main one for nil; nil when that display is not connected.
    static func screen(_ uuid: String?) -> NSScreen? {
        guard let uuid else { return NSScreen.screens.first }
        return NSScreen.screens.first { $0.displayUUID == uuid }
    }

    /// An AppKit frame (bottom-left origin) in top-left coordinates, and back.
    static func flip(_ frame: CGRect) -> CGRect { WindowGeometry.flip(frame, primaryHeight: Screens.primaryHeight) }
}

/// A Home placement as Home draws it, with its tile's model, which the desk feeds while Home draws it.
struct HomeWidget: Identifiable, Sendable {
    let placement: Widget.Placement
    let model: WidgetTileModel
    var id: String { placement.id }
    /// Its row in Home's layout.
    var row: String { HomeLayout.widgetRow(placement.id) }
    /// Its widget's title once fed, else its id.
    @MainActor var title: String { model.title.isEmpty ? placement.widget : model.title }
}

/// A widget's panel: borderless, never key, below every window and above the desktop's icons, on every Space, out of
/// Cmd+Tab and Mission Control's shuffle; the mouse passes through (Hyper+drag is the mouse tap's).
private final class WidgetPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
