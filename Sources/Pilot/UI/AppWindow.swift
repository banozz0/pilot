import AppKit
import Observation
import PilotCore
import PilotTiler
import SwiftUI

/// Which page the window shows (the page shown last, Home the first time) and which part of each merged page (section 7
/// of design round 4, card agent-bo-95422892).
@Observable @MainActor
final class AppWindowModel {
    private let defaults: UserDefaults
    var page: AppPage {
        didSet { if page != oldValue { defaults.set(page.rawValue, forKey: Self.lastPageKey) } }
    }
    /// The part picked on each merged page; a page not in here shows its first.
    var sections: [AppPage: AppSection] = [:]
    /// Binds' conflicts, shown as a sheet over the page.
    var showsConflicts = false
    /// What the search holds.
    var query = ""
    /// Cmd+F asks the frame's search for the keyboard by counting up.
    var searchRequests = 0
    /// The search asked for where no page list shows (Home, a narrow window): the list shows for it until a pick or Escape.
    var searchOpen = false
    /// How many macOS shortcuts clash with a bind, plus Pilot's defaults left without their key: Binds' count, read when the
    /// binds change.
    var conflictCount = 0
    /// The System section a key or a link asked for; System scrolls there and clears it.
    var setupSection: SetupSection?
    /// The extension a link or a stopped run asked for (card agent-bo-95423247); Extensions scrolls there and clears it.
    var extensionFocus: String?
    /// The extension whose page shows in place of the Extensions page (story 161); any other place clears it.
    var extensionPage: String?
    /// The run Reports opens on, from Update & Clean's Open report; leaving Reports or going anywhere else clears it.
    var reportPick: String?
    /// The category Install's catalogue opens on, from Fonts' Get more fonts; going anywhere else clears it.
    var catalogueCategory: String?
    /// The repo Apps › Repos opens on, from a Repos widget's row; going anywhere else clears it. `repoOpens` counts the
    /// opens, so a second open of the same repo starts the page on it again.
    var repoPick: String?
    var repoOpens = 0
    /// The Wallpaper row Look lights, from the desktop's Wallpaper settings…; going anywhere else clears it.
    var wallpaperFocus: WallpaperBlock.Focus?
    /// The action whose bind editor Binds opens (the menu's Set Hyper bind, card agent-bo-95422968); Binds clears it.
    var editBind: String?
    /// The row whose alias editor Launcher › Aliases opens (the menu's Set alias…, card agent-bo-95423037); Aliases clears it.
    var editAlias: Alias?
    /// The workspace whose editor popup shows over the window (mockup E, card agent-bo-95422980).
    var editingWorkspace: EditedWorkspace?
    /// Whether the window shows on screen now: open and not hidden, minimised or covered.
    var onScreen = false
    /// Whether the window is key, the one typed into.
    var isKey = false
    /// On screen and key: the pages' repeating reads (This Mac, Activity, Stats, the bar preview, an extension's page)
    /// run only then, so a window left open behind other apps redraws nothing under its glass (Sven, 2026-10-17).
    var live: Bool { onScreen && isKey }
    private static let lastPageKey = "appWindow.page"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        // A page saved before the cut opens where it went; a developer page saved while the switch was on, its area's first.
        let saved = defaults.string(forKey: Self.lastPageKey).flatMap { AppPlace.named($0)?.page } ?? .home
        page = saved.isDeveloper && !DeveloperPages.on ? saved.area.shown.first ?? .home : saved
    }

    /// The part of `page` showing now: the one picked, else its first (a page's own content is nil).
    func section(of page: AppPage) -> AppSection? {
        sections[page] ?? page.firstSection
    }

    /// Shows `place`: its page, and its part (conflicts open as a sheet over Binds).
    func go(_ place: AppPlace) {
        extensionPage = nil
        reportPick = nil
        catalogueCategory = nil
        repoPick = nil
        wallpaperFocus = nil
        searchOpen = false
        page = place.page
        if let section = place.section {
            if section.opensAsSheet { showsConflicts = true } else { sections[place.page] = section }
        } else if place.page.hasOwnContent {
            sections[place.page] = nil
        }
    }

    /// Whether the sidebar marks `page` picked: not Extensions while one of its extensions' pages shows (story 161).
    func shows(_ page: AppPage) -> Bool { page == self.page && extensionPage == nil }

    /// The name over the page: an extension page's emoji and title, else the page's.
    var title: String {
        guard let id = extensionPage else { return page.title }
        return ExtensionPages.shared.entries.first { $0.id == id }?.label ?? id
    }

    /// The page's tabs; an extension page has none.
    var tabs: [(value: AppSection?, title: String)] { extensionPage == nil ? page.tabs : [] }

    /// Shows extension `id`'s page (story 161), under the Extensions page in the sidebar.
    func goExtensionPage(_ id: String) {
        go(AppPlace(.extensions))
        extensionPage = id
    }

    /// Shows Apps › Repos on repo `name`, as a Repos widget's row opens it.
    func goRepo(_ name: String) {
        go(AppPlace(.repos))
        repoPick = name
        repoOpens += 1
    }

    /// Opens the Extensions list on extension `id`'s row: an extension with nothing to show as a page.
    func focusExtension(_ id: String) {
        go(AppPlace(.extensions))
        extensionFocus = id
    }

    /// ⌃Tab: the next page in the area, round to the first; in Extensions, Installed then each extension that opens a
    /// page, as the sidebar lists them.
    func nextPage(entries: [ExtensionPages.Link] = ExtensionPages.shared.pageEntries) {
        guard page.area == .extensions, !entries.isEmpty else { return go(AppPlace(AppArea.next(after: page, developer: DeveloperPages.on))) }
        let at = extensionPage.flatMap { id in entries.firstIndex { $0.id == id } }
        let next = at.map { $0 + 1 } ?? 0
        if next < entries.count { goExtensionPage(entries[next].id) } else { go(AppPlace(.extensions)) }
    }

    /// ⌘⇧] and ⌘⇧[ (P36, design q267 A): the open page's next or previous tab, round to the first or the last; nothing on
    /// a page without tabs.
    func stepPart(by step: Int) {
        let parts = tabs.map(\.value)
        guard parts.count > 1 else { return }
        let at = parts.firstIndex(of: section(of: page)) ?? 0
        sections[page] = parts[(at + step + parts.count) % parts.count]
    }

    /// Binds' clash count: what ShortcutConflicts finds for `binds`, and the default keys another action holds
    /// (`refused`), read when the binds change.
    func refreshConflicts(binds: [Key: String], refused: Int = 0, conflicts: ShortcutConflicts = .shared) {
        conflictCount = conflicts.clashes(binds: binds).count + refused
    }

    /// Opens a System Settings pane the search found (Q131); a seam for the tests.
    var openPane: (SystemPane) -> Void = { SystemModule.pane($0.id) }

    /// The search's Return: the first place it finds, else the first System Settings pane, as the list orders them.
    func goToFirstResult() {
        if let first = AppPlace.search(query, developer: DeveloperPages.on).first { go(first) }
        else if let pane = SettingsSearch.panes(query).first { openPane(pane) }
        else { return }
        query = ""
    }
}

/// Pilot's app window (story 40, card agent-bo-95422748): one real Mac window, its eleven pages, opened from the
/// dropdown, Cmd+, the Hyper+Space menu, a pilot://open link or a second launch. Pilot has a Dock icon and a Cmd+Tab
/// entry only while it is open (DockIcon); Cmd+W closes it and Pilot keeps running; Cmd+Q quits Pilot.
@MainActor
final class AppWindowController: NSObject {
    static let shared = AppWindowController()

    let model = AppWindowModel()
    private(set) var window: NSWindow?
    /// Seams for the tests: the real ones switch the app's activation policy and quit.
    var applyDockIcon: (DockIcon) -> Void = { NSApp.setActivationPolicy($0 == .dock ? .regular : .accessory) }
    var quit: () -> Void = { NSApp.terminate(nil) }
    /// The windows the Dock rule counts (counts). A seam so a test counts only its own: the runner's other suites open and
    /// close theirs meanwhile, which closed and kept the icon under a test's window (full runs, 2026-10-11).
    var countsWindow: (NSWindow) -> Bool = { AppWindowController.counts($0) }

    static let size = NSSize(width: 1000, height: 660), minSize = NSSize(width: 760, height: 520)

    /// Whether the screen is locked now; a seam for the tests.
    var screenLocked: () -> Bool = { ScreenEvents.isLocked() }
    private var lockedOpen = LockedOpen()
    private var unlockObserver: NSObjectProtocol?
    var waitsForUnlock: Bool { unlockObserver != nil }

    /// Opens the window, or brings it forward, at `place`; with none, on the page shown last (Home the first time). On a
    /// locked screen it waits for the unlock, since the tiler never tiles a window made while locked (LockedOpen).
    /// `editBind` opens Binds' editor on that action (the menu's Set Hyper bind, card agent-bo-95422968), `editAlias`
    /// Launcher › Aliases' editor on that row (Set alias…, card agent-bo-95423037).
    func open(_ place: AppPlace? = nil, setup: SetupSection? = nil, extension focus: String? = nil, editBind: String? = nil, editAlias: Alias? = nil) {
        // A developer page while the Developer switch is off (a link, a bind) opens General, where the switch is.
        let place = place.map { $0.page.isDeveloper && !DeveloperPages.on ? AppPlace(.general) : $0 }
        // System's section (Hyper+Ctrl+A, B and W, card agent-bo-95422805) and the bind to edit, kept through a locked
        // screen's wait.
        if place?.page == .system, let setup { model.setupSection = setup }
        if place?.page == .extensions, let focus { model.extensionFocus = focus }
        if place?.page == .binds, let editBind { model.editBind = editBind }
        if place?.section == .aliases, let editAlias { model.editAlias = editAlias }
        guard case .show(let page) = lockedOpen.request(place, screenLocked: screenLocked()) else {
            log.notice("app window waits for the screen to unlock")
            if unlockObserver == nil {
                unlockObserver = DistributedNotificationCenter.default().addObserver(
                    forName: ScreenEvents.unlocked, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screenUnlocked() }
                }
            }
            return
        }
        stopWaiting()
        show(page)
    }

    /// The unlock notification: the open that waited shows now, without asking the session again, which may still
    /// read locked for a moment.
    func screenUnlocked() {
        stopWaiting()
        guard case .show(let page)? = lockedOpen.unlocked() else { return }
        log.notice("app window: screen unlocked, opening")
        show(page)
    }

    func open(_ page: AppPage, setup: SetupSection? = nil) { open(AppPlace(page), setup: setup) }

    /// Opens the window on extension `id`'s page (story 161): the bar item's Open page, its Extensions detail's.
    func openExtensionPage(_ id: String) {
        open(AppPlace(.extensions))
        model.goExtensionPage(id)
    }
    func open(_ section: AppSection) { open(AppPlace(section)) }

    /// Opens the window on Apps › Repos at repo `name`: a Repos widget's row.
    func openRepo(_ name: String) {
        open(AppPlace(.repos))
        model.goRepo(name)
    }

    /// Opens the window on Look › Wallpaper, `focus`'s row lit: the desktop's Hyper + right-click › Wallpaper settings….
    func openWallpaper(_ focus: WallpaperBlock.Focus) {
        open(AppPlace(.wallpaper))
        model.wallpaperFocus = focus
    }

    private func stopWaiting() {
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        unlockObserver = nil
    }

    private func show(_ place: AppPlace?) {
        guard let engine = Engine.shared else { return log.error("app window: no engine") }
        if let place { model.go(place) }
        // The sidebar's extension pages, read as the window opens (story 161).
        Task { await ExtensionPages.shared.reload() }
        present(NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        WindowFocus.bringForward()
        log.notice("app window open on \(self.model.page.rawValue, privacy: .public)")
    }

    /// Shows the window with `content`, made at the first open after a close and kept while open; the Dock icon arrives
    /// first so the window opens as a regular app's.
    func present(_ content: @autoclosure () -> NSView) {
        applyDockIcon(.dock)
        if window == nil {
            let w = Self.makeWindow(content: content())
            w.onQuit = { [weak self] in self?.quit() }
            if let autosaveName {
                if !w.setFrameUsingName(autosaveName) { w.center() }
                w.setFrameAutosaveName(autosaveName)
            }
            window = w
            followLook()
            // On screen as occlusion and moves say (the tiler parks a window on a hidden workspace by moving it off
            // screen, which changes no occlusion); key as the window says.
            windowObservers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.occlusionChanged() }
                }
            } + [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.isKey = name == NSWindow.didBecomeKeyNotification }
                }
            }
        }
        let shown = window?.isVisible == true
        window?.makeKeyAndOrderFront(nil)
        if !shown { TilerOwnWindows.shown() }
        occlusionChanged()
    }

    /// Restyles the window whenever the theme or the material changes, for as long as Pilot runs; every other window of
    /// Pilot's (Welcome, the panels) takes the theme's light or dark controls. Started once, with the window.
    private func followLook() {
        guard let window else { return }
        Self.applyLook(.shared, to: window)
        for other in NSApp.windows where other !== window { other.appearance = Theme.appearance }
        // One watch at a time: a close leaves its watch waiting, and the next open would add a second, one more per open.
        guard !followingLook else { return }
        followingLook = true
        withObservationTracking { _ = (Look.shared.layers, Look.shared.style, Look.shared.theme, Look.shared.glassBlur) } onChange: { [weak self] in
            Task { @MainActor in
                self?.followingLook = false
                self?.followLook()
            }
        }
    }
    private var followingLook = false

    /// The window as `look` says (design round 4, card agent-bo-95422890): Solid is opaque in the theme's ground; Glass
    /// is macOS 26's Liquid Glass (NSGlassEffectView) tinted with the ground at the ground layer's strength (Transparency,
    /// round 15), in Blur's style (the tint alone at Off); Reduce transparency and Transparency 0 % make it Solid. The style grounds it in its canvas, dark or
    /// light as its theme is; Toybox's window stays opaque whatever the material (Sven, 2026-10-08).
    static func applyLook(_ look: Look, to window: NSWindow) {
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        window.appearance = NSAppearance(named: tokens.dark ? .darkAqua : .aqua)
        let ground = NSColor(Color(tokens.colors.canvas))
        let material = look.windowMaterial
        window.isOpaque = material == .solid
        window.backgroundColor = material == .solid ? ground : .clear
        (window.contentView as? MaterialBackdrop)?.show(material, tint: look.glassTint(on: .window), blur: look.glassBlur)
    }

    /// The frame every open shares, and the renders: the theme's ground, the title bar hidden over the sidebar, the
    /// content on a MaterialBackdrop that the material goes behind.
    static func makeWindow(content: NSView, size: NSSize = size, minSize: NSSize = minSize) -> PilotWindow {
        let w = PilotWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        w.title = "Pilot"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = Theme.appearance
        w.backgroundColor = Theme.windowBackground
        w.minSize = minSize
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.contentView = MaterialBackdrop(content: content)
        return w
    }

    /// Any of Pilot's own windows closing (this one, Welcome) checks the rule again, so the icon goes with the last.
    private func watchCloses() {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let closing, self.countsWindow(closing) else { return }
                let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && self.countsWindow($0) }
                self.applyDockIcon(DockIcon.policy(openWindows: others.count))
                log.notice("window closed, \(others.count) other windows open")
                self.release(closing)
            }
        }
    }
    private var closeObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    /// The window closed: it goes with its SwiftUI tree, every page's views, pictures and observers, which a closed
    /// window kept in memory for as long as Pilot ran (2026-10-10, idle RAM 164 MB against 45). The next open makes it
    /// again where it was (its frame is autosaved), on the page shown last (the model stays).
    private func release(_ closing: NSWindow) {
        guard closing === window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        window = nil
        model.isKey = false
        occlusionChanged()
        // On the run loop's next pass, once the close is done with it: the window and its tree go with the last reference.
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { closing.contentView = nil } }
    }

    /// The window's place on screen changed, so the model hears when it stops showing.
    func occlusionChanged() {
        model.onScreen = window.map {
            Self.onScreen(visible: $0.isVisible, unoccluded: $0.occlusionState.contains(.visible), frame: $0.frame,
                          screens: NSScreen.screens.map(\.frame))
        } ?? false
    }

    /// Shown, not covered, and not parked off screen by the tiler, which leaves only a sliver of a hidden workspace's
    /// window on a screen.
    static func onScreen(visible: Bool, unoccluded: Bool, frame: NSRect, screens: [NSRect]) -> Bool {
        visible && unoccluded && screens.contains { $0.intersection(frame).width >= 100 && $0.intersection(frame).height >= 100 }
    }

    /// A window the Dock rule counts: a titled one of Pilot's own, not a panel (menu, HUD, clipboard).
    private static func counts(_ window: NSWindow) -> Bool { !(window is NSPanel) && window.styleMask.contains(.titled) }

    override init() {
        super.init()
        watchCloses()
    }

    /// Where the window's size and place are kept between opens; the tests keep none.
    var autosaveName: String? = "PilotAppWindow"
}

/// Cmd+W closes the window and Cmd+Q quits Pilot, whatever the main menu holds (Sven, 2026-10-04).
final class PilotWindow: NSWindow {
    var onQuit: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.type == .keyDown, flags == .command {
            switch event.charactersIgnoringModifiers {
            case "w": performClose(nil); return true
            case "q": onQuit(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A window's or a panel's content with its material behind it: nothing for Solid, an NSGlassEffectView for Glass (card
/// agent-bo-95422890) in Look's Blur's style, or at Blur Off a plain view in the glass's tint.
final class MaterialBackdrop: NSView {
    let content: NSView
    /// The material's view behind the content, nil when Solid.
    private(set) var effect: NSView?
    private let cornerRadius: CGFloat

    /// `cornerRadius` rounds the material to a panel's corners; a window's own frame rounds it otherwise. The material
    /// stays live whether or not its window is key (Sven, 2026-10-17: it went solid as the window lost focus).
    init(content: NSView, cornerRadius: CGFloat = 0) {
        self.content = content
        self.cornerRadius = cornerRadius
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ material: WindowMaterial, tint: NSColor, blur: GlassBlur = Look.shared.glassBlur) {
        let blur = material == .solid ? nil : blur
        // Light and Full are one glass view in two styles; Solid, Off and glass swap the view.
        if blur.map({ $0 != .off }) != effect.map({ $0 is NSGlassEffectView }) {
            effect?.removeFromSuperview()
            effect = blur.map(makeEffect)
        }
        if let glass = effect as? NSGlassEffectView, let style = blur?.effectStyle {
            if glass.tintColor != tint { glass.tintColor = tint }
            if glass.style != style { glass.style = style }
        } else if let layer = effect?.layer, layer.backgroundColor != tint.cgColor {
            layer.backgroundColor = tint.cgColor
        }
    }

    private func makeEffect(_ blur: GlassBlur) -> NSView {
        let view: NSView
        if blur == .off {
            view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
        } else {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            view = glass
        }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: content)
        return view
    }
}

/// General's Developer switch as the window, the searches and `pilot open` read it (AppPage.isDeveloper, Pilot 1.0.2, Sven
/// Q715): the app's own settings, off where there are none (a test).
@MainActor enum DeveloperPages {
    static var on: Bool { PilotSettings.live?.developer ?? false }
    static let help = "Developer pages: Configs, Agents and Repos, for people who live in config files and repos."
}

extension AppArea {
    /// Its pages the window lists now: the developer pages only while the switch is on.
    @MainActor var shown: [AppPage] { pages(developer: DeveloperPages.on) }
}

extension MenuRoot {
    /// The root Hyper+Space and the Ring menu list now: the Config row only while the Developer switch is on.
    @MainActor var listed: MenuRoot {
        guard !DeveloperPages.on else { return self }
        var root = self
        root.extras.remove("config")
        return root
    }
}
