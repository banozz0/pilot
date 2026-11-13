import AppKit
import Observation
import OSLog
import PilotCore
import PilotTiler

let log = Logger(subsystem: "dev.banozz.pilot", category: "engine")

/// User settings the engine reads, in UserDefaults; the binds live in the bind store (Binds).
@Observable @MainActor
final class PilotSettings {
    private let defaults: UserDefaults
    /// The login item Launch at login drives; a fake in the tests.
    private let loginItem: LoginItem

    init(defaults: UserDefaults = .pilot(), loginItem: LoginItem = .shared) {
        self.defaults = defaults
        self.loginItem = loginItem
        // "layerKeys" since more than one key can be Hyper (Sven 2026-10-12); before it, one key under "layerKey".
        layerKeys = LayerKey.parse(defaults.stringArray(forKey: "layerKeys") ?? defaults.string(forKey: "layerKey").map { [$0] } ?? [])
            ?? [.capsLock]
        quickTapEscape = defaults.object(forKey: "quickTapEscape") as? Bool ?? true
        keySwaps = KeySwap.parse(defaults.stringArray(forKey: Self.keySwapsKey) ?? [])
        dictationKey = defaults.string(forKey: Self.dictationKeyKey).flatMap(DictationKey.init(rawValue:)) ?? .off
        dictationKeyMode = defaults.string(forKey: Self.dictationKeyModeKey).flatMap(DictationKeyMode.init(rawValue:)) ?? .toggle
        overlayMode = defaults.string(forKey: "overlayMode").flatMap(OverlayPage.Mode.init(rawValue:)) ?? .every
        overlayPicks = Set(defaults.stringArray(forKey: "overlayPicks") ?? [])
        overlayDelay = HoldOverlay.clamped(delay: defaults.object(forKey: "overlay.delay") as? Double ?? HoldOverlay.delay)
        overlayEnabled = defaults.object(forKey: "overlay.enabled") as? Bool ?? true
        showPublicIP = defaults.bool(forKey: "system.publicIP")
        dragModifier = defaults.string(forKey: "windows.dragModifier").flatMap(DragModifier.init(rawValue:)) ?? .default
        bindNudges = defaults.object(forKey: "general.bindNudges") as? Bool ?? true
        // Off for a new install. Once, an install that ran before the switch existed (onboarding left its key) starts on, so
        // Configs stays where it was (Sven's Mac among them); saved at once, so it never asks again.
        let developer = defaults.object(forKey: Self.developerKey) as? Bool ?? (defaults.object(forKey: OnboardingWindow.unfinishedKey) != nil)
        defaults.set(developer, forKey: Self.developerKey)
        self.developer = developer
        swipeWorkspaces = defaults.bool(forKey: "windows.swipeWorkspaces")
        brightnessKeys = defaults.object(forKey: "displays.brightnessKeys") as? Bool ?? true
        translatePair = TranslatePair(defaults: defaults)
        // Notes written in Application Support before Pilot's own folder moved to Documents (task N1) stay where they are.
        notesReopenMinutes = (defaults.object(forKey: Self.notesReopenKey) as? Int).map(NotesReopen.clamped) ?? NotesReopen.standard
        notesPinned = defaults.bool(forKey: Self.notesPinnedKey)
        notesFolder = NotesFolder.kept(saved: defaults.string(forKey: "notes.folder"))
        if notesFolder != nil { defaults.set(notesFolder, forKey: "notes.folder") }
        if defaults.isApp { Self.live = self }
    }

    /// Stored, not computed over UserDefaults: Observation tracks only stored properties, and on 2026-10-05 a computed one
    /// left the pages' onChange silent, so a new key waited for the next launch (card agent-bo-95422775).
    /// Each alone is Hyper, Caps Lock first, never empty.
    private(set) var layerKeys: [LayerKey]
    /// The engine re-arms the tap and Pilot's key mapping (Caps Lock's F18, the swaps) here, so a layer-key change takes
    /// effect at once.
    @ObservationIgnored var onLayerKeyChange: () -> Void = {}
    /// The engine hands the running tap the new quick-tap rule here; the Caps Lock remap does not change with it.
    @ObservationIgnored var onQuickTapChange: () -> Void = {}

    /// The one way the layer keys change: saved, logged old to new with its source, and applied by the engine. None
    /// left is refused, so Hyper always has a key.
    func setLayerKeys(_ keys: [LayerKey], from source: LayerKeySource) {
        let old = layerKeys
        guard let keys = LayerKey.ordered(keys), keys != old else { return }
        layerKeys = keys
        defaults.set(keys.map(\.rawValue), forKey: "layerKeys")
        log.notice("\(LayerKey.changeLine(old, keys, source), privacy: .public)")
        onLayerKeyChange()
    }
    /// Quick notes' folder, picked on the Notes or Pilot page (card agent-bo-95423042, task N1); nil is Pilot's own
    /// (NotesFolder.pilotDefault).
    var notesFolder: String? {
        didSet { defaults.set(notesFolder, forKey: "notes.folder") }
    }
    /// How long after the notes panel hides its key opens it back on the note left, in minutes; 0 is always Scratch
    /// (NotesReopen, Sven 2026-11-12).
    var notesReopenMinutes: Int {
        didSet { defaults.set(notesReopenMinutes, forKey: Self.notesReopenKey) }
    }
    static let notesReopenKey = "notes.reopenMinutes"
    /// The notes panel pinned on screen (NotesPanel.pinned, Sven 2026-11-12).
    var notesPinned: Bool {
        didSet { defaults.set(notesPinned, forKey: Self.notesPinnedKey) }
    }
    static let notesPinnedKey = "notes.pinned"
    /// Translate's two languages, picked on Setup's Keyboard part and read by the menu on each translation (card
    /// agent-bo-95423002).
    var translatePair: TranslatePair {
        didSet { translatePair.save(to: defaults) }
    }
    /// Update lists casks that update themselves too (off unless Sven turns it on in the Update branch).
    var updateSelfUpdatingCasks: Bool {
        get { defaults.bool(forKey: "update.selfUpdatingCasks") }
        set { defaults.set(newValue, forKey: "update.selfUpdatingCasks") }
    }
    /// Binds › Swap keys (Q406): pairs of keys swapped at the HID level while Pilot runs. Stored like layerKeys, so a
    /// change reaches the mapping at once.
    var keySwaps: [KeySwap] {
        didSet {
            guard keySwaps != oldValue else { return }
            defaults.set(keySwaps.map(\.word), forKey: Self.keySwapsKey)
            onKeySwapsChange()
        }
    }
    @ObservationIgnored var onKeySwapsChange: () -> Void = {}
    static let keySwapsKey = "binds.keySwaps"
    /// On unless switched off: a tap of the layer key is Escape, as Karabiner's rule did. Stored like layerKey, so a change
    /// reaches the running tap at once (card agent-bo-95422776).
    var quickTapEscape: Bool {
        didSet {
            defaults.set(quickTapEscape, forKey: "quickTapEscape")
            onQuickTapChange()
        }
    }
    /// Voice › Dictation key (Q224): off until picked; a tap of it, or its hold, runs dictation. Stored like quickTapEscape,
    /// so a change reaches the running tap at once.
    var dictationKey: DictationKey {
        didSet {
            defaults.set(dictationKey.rawValue, forKey: Self.dictationKeyKey)
            onDictationKeyChange()
        }
    }
    var dictationKeyMode: DictationKeyMode {
        didSet {
            defaults.set(dictationKeyMode.rawValue, forKey: Self.dictationKeyModeKey)
            onDictationKeyChange()
        }
    }
    /// The engine hands the running tap the new dictation key here.
    @ObservationIgnored var onDictationKeyChange: () -> Void = {}
    static let dictationKeyKey = "dictation.tapKey", dictationKeyModeKey = "dictation.tapMode"
    /// What the hold-Hyper overlay lists (story 56); every bind until changed. The overlay reads it on each hold; stored so
    /// Settings › General shows the mode in use (card agent-bo-95422776).
    var overlayMode: OverlayPage.Mode {
        didSet { defaults.set(overlayMode.rawValue, forKey: "overlayMode") }
    }
    /// How long Hyper is held before the overlay shows (Sven, 2026-10-19): a tenth a step in HoldOverlay.delayRange, read
    /// at each press; the engine hands the tap the quick tap's window that follows from it.
    var overlayDelay: TimeInterval {
        didSet {
            if overlayDelay != HoldOverlay.clamped(delay: overlayDelay) { overlayDelay = HoldOverlay.clamped(delay: overlayDelay) }
            defaults.set(overlayDelay, forKey: "overlay.delay")
            onOverlayDelayChange()
        }
    }
    @ObservationIgnored var onOverlayDelayChange: () -> Void = {}
    /// On unless switched off (Sven, 2026-10-30, Q587): off, holding Hyper never shows the overlay; read at each press.
    /// The quick tap's window still follows overlayDelay, so a tap is Escape as before.
    var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: "overlay.enabled") }
    }
    /// Off until switched on on Home: This Mac's public IP is the one reading that calls the internet (card agent-bo-95422831).
    var showPublicIP: Bool {
        didSet { defaults.set(showPublicIP, forKey: "system.publicIP") }
    }
    /// The key held to move (left drag) or resize (right drag) the window under the mouse (card agent-bo-95422930).
    var dragModifier: DragModifier {
        didSet {
            defaults.set(dragModifier.rawValue, forKey: "windows.dragModifier")
            onDragModifierChange()
        }
    }
    /// On unless switched off: a hint names the bind after a mouse open or a menu pick (card agent-bo-95422934).
    var bindNudges: Bool {
        didSet { defaults.set(bindNudges, forKey: "general.bindNudges") }
    }
    /// The engine hands the running mouse tap the new modifier here.
    @ObservationIgnored var onDragModifierChange: () -> Void = {}
    /// General's Developer switch (Pilot 1.0.2, Sven Q715): Configs, its Agents tab, and Repos show only while it is on
    /// (AppPage.isDeveloper); DeveloperPages reads it.
    var developer: Bool {
        didSet { defaults.set(developer, forKey: Self.developerKey) }
    }
    static let developerKey = "general.developer"
    /// The app's own settings, on its own defaults; never a test's, so a test's switch shows nowhere else.
    static weak var live: PilotSettings?
    /// Off until switched on: a three-finger sideways swipe moves between workspaces (card agent-bo-95422973).
    var swipeWorkspaces: Bool {
        didSet {
            defaults.set(swipeWorkspaces, forKey: "windows.swipeWorkspaces")
            onSwipeWorkspacesChange()
        }
    }
    /// The engine starts or stops the gesture tap here.
    @ObservationIgnored var onSwipeWorkspacesChange: () -> Void = {}

    /// The keyboard's own brightness keys change the focused window's screen through Pilot (Setup › Displays, card
    /// agent-bo-95423314); on at first. Off, macOS gets them as before.
    var brightnessKeys: Bool {
        didSet { defaults.set(brightnessKeys, forKey: "displays.brightnessKeys") }
    }
    /// On unless switched off: Pilot is a login item (story 40; ClipBook's open at login, card agent-bo-95422770). A change
    /// applies at once, from Settings › General or onboarding.
    static let launchAtLoginDefault = true
    var launchAtLogin: Bool {
        get { defaults.object(forKey: "launchAtLogin") as? Bool ?? Self.launchAtLoginDefault }
        set {
            defaults.set(newValue, forKey: "launchAtLogin")
            loginItem.apply(newValue)
        }
    }
    /// At launch: the login item matches the setting.
    func applyLaunchAtLogin() { loginItem.apply(launchAtLogin) }
    /// The actions "My own pick" lists, switched on in Binds › Overlay or the Binds editor. One set for every preset: a
    /// pick is an action, which shows with the key the active preset gives it. Stored, so Binds › Overlay's switches follow.
    var overlayPicks: Set<String> {
        didSet { defaults.set(overlayPicks.sorted(), forKey: "overlayPicks") }
    }
    /// Binds › Overlay's switch: the overlay turns to My own pick, from `shown` (what it shows now) with `action` in or out.
    func showInOverlay(_ action: String, _ on: Bool, shown: Set<String>) { pickOverlay(OverlayPage.picks(switching: action, on: on, shown: shown)) }
    /// The overlay lists `picks` alone (My own pick).
    func pickOverlay(_ picks: Set<String>) {
        overlayPicks = picks
        overlayMode = .pick
    }
}

struct Press: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let key: Key
    let action: String?
    let app: String
    var line: String { "\(key.label) → \(action ?? "unbound") in \(app)" }
}

/// Composition root: gate, tap, observers, secure input, the registry. One instance, owned by the app.
@Observable @MainActor
final class Engine {
    /// The one instance, so the app delegate can stop the tap and undo the Caps Lock remap at quit.
    private(set) static weak var shared: Engine?

    let settings = PilotSettings()
    let gate = AccessibilityGate()
    let observers = EngineObservers()
    let secureInput = SecureInputMonitor()
    let pilotSwitch: PilotSwitch
    let pilotBlock: PilotBlockStore
    /// Each workspace's Monitor pick (N7).
    let workspaceMonitors: WorkspaceMonitorStore
    let workspaceList: WorkspaceList
    let rescue: WindowRescue
    let snapshots: WorkspaceSnapshots
    let layouts: WorkspaceLayouts
    let presets: WorkspacePresets
    let topBar: TopBarController
    /// Pilot's dock (spec pilot-dock): off by default.
    let dock: DockController
    /// Bind hints (card agent-bo-95422934).
    @ObservationIgnored private(set) lazy var nudger = BindNudger(engine: self)
    /// The Window shelf on Stage workspaces (ADR 0015), its first place under the top bar's room and the outer gap.
    @ObservationIgnored private(set) lazy var shelf = WindowShelf(tiler: observers.tiler, tiling: { [tilingSwitch] in tilingSwitch.isOn },
                                                                  top: { [pilotBlock] name in
        let block = pilotBlock.block
        return CGFloat((block.topBar.first { $0.monitor == name }?.height ?? 0) + (block.gapsOn ? block.gaps.outer : 0))
    })
    /// What the bar items draw from, for the macOS menu bar and the top bar alike (card agent-bo-95422911).
    let barSources: BarSources
    /// The dropdown's Tiling switch, kept here because the dropdown is made anew each time it opens.
    let tilingSwitch: TilingSwitch
    /// The Hyper key's switch (card agent-bo-95422986), on at every launch.
    let hyperSwitch: SessionSwitch
    /// The dropdown's Dictation switch, kept here so off then on brings back the key it had.
    @ObservationIgnored private(set) lazy var dictationSwitch = DictationKeySwitch(settings: settings)
    private(set) var registry = ActionRegistry()
    let binds = Binds()
    private let tap: HyperTap
    /// Lock keyboard for cleaning (Part 04): the tap takes every key until Esc held 3 s, Unlock or 2 minutes.
    let keyboardLock: KeyboardLockController
    /// Alt+drag (card agent-bo-95422930), armed with the binds while its modifier is not Off.
    private let mouseTap: MouseDragTap
    /// Swipe between workspaces (card agent-bo-95422973), armed with the binds while it is on.
    private let swipe = SwipeWorkspaces()
    /// Hyper+scroll steps through workspaces (Omarchy ideas T2), armed with the binds, on only while Hyper is down.
    private let hyperScroll: HyperScroll
    /// A mouse's extra buttons as binds (Q184): Binds › Mouse's Learn, and the taps a mouse bind needs.
    let mouseButtons: MouseButtons
    /// The Ring menu (P74): the rings, and the one open while its trigger is held.
    let rings = RingController(store: RingStore())

    /// Bitwarden's unlock: no key reaches Pilot while Sven types his master password into bw (card agent-bo-95422814).
    func pauseKeyboard() { tap.pause(); log.notice("tap paused") }
    func resumeKeyboard() { tap.resume(); log.notice("tap resumed") }
    private let overlay = HyperOverlay()
    /// The actions holding Hyper shows now on any sublayer (Binds › Overlay's switches).
    func overlayShown() -> Set<String> {
        OverlayPage.shown(store: binds.store, actions: bindActions, mode: settings.overlayMode, presses: pressCounts?.counts ?? [:],
                          picks: settings.overlayPicks)
    }
    private let windowBorder = WindowBorderController()
    private let dropZone = DropZone()
    private let gapHandles = GapHandles()
    /// How often each bind ran, for the overlay's most used (story 56); never sent anywhere. Nil when the file could not
    /// be read: nothing is counted or written, so it is never wiped.
    @ObservationIgnored private var pressCounts: PressCounts?
    /// The next write of the counts, a moment after the last press rather than one per keystroke.
    @ObservationIgnored private var pressSave: DispatchWorkItem?
    /// Today's presses for Home (card agent-bo-95422992): its count, most used and presses by hour; saved with the counts.
    private(set) var today = TodayPresses() { didSet { if (today.day != nil) != pressed { pressed.toggle() } } }
    /// A press has been counted (today's file holds a day): Home's Most used waits for it (simplify-pages T3). Its own
    /// property, so Home redraws once when it flips, not on every press as reading `today` would.
    private(set) var pressed = false
    @ObservationIgnored private let todayFile = DayFile<TodayPresses>("presses-today")

    private(set) var hyperHeld = false
    /// Held actions by the key that ran them, ended when it comes up.
    @ObservationIgnored private var held: [Key: @MainActor () -> Void] = [:]
    private(set) var presses: [Press] = []
    private(set) var lastError: String?
    /// Pilot's key mapping set as last written (Caps Lock to F18, the swaps), empty when none is.
    @ObservationIgnored private(set) var mappingWritten: [KeyMappingEntry] = []
    /// The UserKeyMapping entries Pilot did not write, as last read: Binds › Swap keys refuses a swap on their keys.
    private(set) var foreignMapping: [KeyMappingEntry] = []

    init() {
        tap = HyperTap(layer: HyperLayer(layerKeys: settings.layerKeys, quickTapEscape: settings.quickTapEscape))
        keyboardLock = KeyboardLockController(tap: tap)
        mouseTap = MouseDragTap(modifier: { [settings] in settings.dragModifier }, layer: tap, tiler: observers.tiler)
        hyperScroll = HyperScroll(layer: tap)
        mouseButtons = MouseButtons(tap: tap)
        pilotSwitch = PilotSwitch()
        pilotBlock = PilotBlockStore(tiler: observers.tiler)
        workspaceMonitors = WorkspaceMonitorStore(tiler: observers.tiler, block: pilotBlock)
        workspaceList = WorkspaceList(tiler: observers.tiler, block: pilotBlock, monitors: workspaceMonitors)
        rescue = WindowRescue(tiler: observers.tiler)
        snapshots = WorkspaceSnapshots(observers: observers)
        layouts = WorkspaceLayouts(observers: observers)
        presets = WorkspacePresets(observers: observers)
        presets.onSave = { [layouts] workspace, preset, auto in layouts.set(workspace, layouts.layout(workspace).saving(preset, auto: auto)) }
        // Deleting a workspace closes its number (Sven's Q233): what is tied to a number follows it.
        workspaceList.follow(presets: presets, layouts: layouts, snapshots: snapshots, wallpaper: .shared)
        workspaceList.closeGaps()
        tilingSwitch = TilingSwitch(observers.tiler)
        hyperSwitch = SessionSwitch { [tap] on in tap.setHyper(on); log.notice("Hyper key \(on ? "on" : "off", privacy: .public)") }
        barSources = BarSources(readings: BarReadings(sound: SetupSound(audio: CoreAudioSystem())), observers: observers, sampler: .shared,
                                keepAwake: .shared, timer: .shared, pilotTitle: { Engine.shared?.menuBarTitle ?? "–" },
                                pilotAlert: { Engine.shared?.gate.isTrusted == false }, dropdown: { Engine.shared?.dropdown ?? PilotDropdown.none })
        topBar = TopBarController(writeBars: { [pilotBlock] in try await pilotBlock.writeTopBar($0) },
                                  screens: { [strips = UserDefaults.pilot()] in TopBarScreens.measure(strips) }, panels: TopBarWindows(sources: barSources, store: .shared))
        // Items placed in both leave the macOS menu bar while the top bar is on (card agent-bo-95422910).
        BarItemsStore.shared.isTopBarOn = { [topBar] in topBar.isOn }
        topBar.switched = { BarItemsStore.shared.topBarSwitched($0) }
        let dockWindow = DockWindow()
        dock = DockController(writeRoom: { [pilotBlock] in try await pilotBlock.writeDock($0) }, panels: dockWindow)
        dockWindow.draw(dock, observers: observers, sources: barSources)
        ExtensionBar.shared.shows = { BarItemsStore.shared.shows(extension: $0, in: $1) }
        registerActions()
        wireRings()
        _ = DriveModule.catalogue   // read now, never on the first press of a catalogue bind inside the tap
        binds.onChange = { [unowned self] in armMouseButtons() }
        let myBinds = MyBinds.preset(registry: registry.defaults)
        AbilitySettings.shared.seed(existingUser: FileManager.default.fileExists(atPath: Binds.url.path))
        // A mouse button whose action is not on this Mac (Sven's own Now Playing extension) stays free: a bind there would
        // take the button and run nothing. An extension's id always builds an action, so its command is looked up too.
        binds.load(presets: [.pilot: PilotDefault.binds, .myBinds: myBinds, .empty: PilotDefault.scratch], actions: Array(registry.actions.keys)) { [unowned self] in
            let installed = Extension.find(in: Extension.folder).extensions
            return PilotDefault.mouse.filter { _, id in
                action(id) != nil && (Extension.command(inAction: id) == nil || Extension.command(inAction: id, in: installed) != nil)
            }
        }
        // rings.json from before version 4, or none: Mouse 4's hold opens This window, once (Q194).
        if rings.store.upgraded, rings.store.lastError == nil, binds.lastError == nil { binds.addRingHold() }
        for id in Set(PilotDefault.binds.keys).union(MyBinds.extras.keys) where action(id) == nil {
            log.error("binds: a preset names \(LinkToken.redact(id), privacy: .public), which no action has")
        }
        // Pilot owns every Hyper key (card agent-bo-95422751): a key with a bind runs it, whatever the preset. App binds
        // (story 143) stay in binds.json but are not acted on while per-app binds are parked (parked/per-app-binds).
        tap.isBound = { [unowned self] key in binds.store.action(for: key) != nil }
        // A new layer key takes effect at once, from whichever page changed it.
        settings.onLayerKeyChange = { [unowned self] in settingsChanged() }
        settings.onKeySwapsChange = { [unowned self] in if tap.isRunning { applyLayerKey() } }
        settings.onQuickTapChange = { [unowned self] in tap.update(layerKeys: settings.layerKeys, quickTapEscape: settings.quickTapEscape) }
        settings.onDragModifierChange = { [unowned self] in armPointerTaps() }
        settings.onDictationKeyChange = { [unowned self] in tap.update(dictationKey: settings.dictationKey, mode: settings.dictationKeyMode) }
        settings.onDictationKeyChange()
        settings.onOverlayDelayChange = { [unowned self] in tap.update(quickTapWindow: HoldOverlay.quickTapWindow(delay: settings.overlayDelay)) }
        settings.onOverlayDelayChange()
        settings.onSwipeWorkspacesChange = { [unowned self] in armPointerTaps() }
        let stepWorkspace = { [unowned self] (fire: WorkspaceSwipe.Fire) in _ = action(fire == .next ? "workspaces.next" : "workspaces.previous")?.run() }
        swipe.onSwipe = stepWorkspace
        hyperScroll.onStep = stepWorkspace
        // Spec scrolling-layout T12: Hyper + a sideways scroll is Hyper+← → a step at a time, so a strip moves a column.
        hyperScroll.onSideways = { [unowned self] fire in _ = action(fire == .next ? "windows.focusRight" : "windows.focusLeft")?.run() }
        do { pressCounts = try PressCountStore.standard.load() } catch {
            log.error("presses: \(PressCountStore.standard.url.path, privacy: .public) not read, not counting: \(String(describing: error), privacy: .public)")
        }
        do { today = try todayFile.load(or: TodayPresses()) } catch {
            log.error("presses: \(self.todayFile.url.path, privacy: .public) not read: \(String(describing: error), privacy: .public)")
        }
        // init runs no didSet: a day saved before this launch counts as pressed.
        pressed = today.day != nil
        overlay.rows = { [unowned self] page in
            OverlayPage.rows(store: binds.store, actions: bindActions, sublayer: page, mode: settings.overlayMode,
                             presses: pressCounts?.counts ?? [:], picks: settings.overlayPicks)
        }
        overlay.delay = { [unowned self] in settings.overlayDelay }
        overlay.enabled = { [unowned self] in settings.overlayEnabled }
        tap.onModifiers = { [unowned self] held in overlay.modifiers(held) }
        tap.onKey = { [unowned self] in overlay.key() }
        tap.onTyped = { SnippetLibrary.shared.keywords.typed($0, $1()) }
        tap.onLayerChange = { [unowned self] down in
            // The page Shift or Ctrl already held names, read once as the layer goes down.
            overlay.layer(down: down, held: tap.layer.sublayer(flags: CGEventSource.flagsState(.hidSystemState).rawValue))
            hyperHeld = down
            hyperScroll.hyper(down)
            mouseTap.hyper(down)
            SelectionTools.shared.hyper(down)
            log.debug("Hyper \(down ? "on" : "off", privacy: .public)")
        }
        tap.onRun = { [unowned self] key, autorepeat in
            guard let id = binds.store.action(for: key), let action = self.action(id) else { return }
            if autorepeat && !action.repeats { return }
            record(key, action: action.label)
            if !autorepeat { countPress(id) }
            if let hold = action.hold {
                held[key] = { hold(false) }
                hold(true)
            } else {
                action.run()
            }
        }
        tap.onRelease = { [unowned self] key in held.removeValue(forKey: key)?() }
        // The same actions the dictation binds run (Q224).
        tap.onDictationKey = { [unowned self] decision in
            switch decision {
            case .toggle: action(DictationModule.toggleID)?.run()
            case .hold(let down): action(DictationModule.holdID)?.hold?(down)
            case .none, .arm: break
            }
        }
        tap.clickedWithin = HyperTap.hidClickedWithin
        tap.onEscape = { TilerDrag.escape() }
        // Esc cancels Pilot's own take as its pill's ✕ does, the words kept for Undo.
        let dictation = PilotDictation.shared
        dictation.onLive = { [unowned self] in tap.cancelsDictationOnEscape = $0 }
        tap.onDictationEscape = { dictation.cancel() }
        // Esc or Return ends a scrolling capture and keeps what it caught, whichever app is in front; after the tap's
        // callback, as ending hides its panels.
        ScrollCapture.onWatching = { [weak tap] capture in tap?.endScrollCapture = capture.map { capture in { Task { capture.end() } } } }
        tap.onUnbound = { [unowned self] key, autorepeat in
            guard !autorepeat else { return }
            record(key, action: nil)
        }
        tap.onPaste = { ClipboardHistory.shared.pasted() }
        tap.onBrightness = { [unowned self] in ScreenBrightness.key($0, switchOn: settings.brightnessKeys) }
        tap.onToggleCapsLock = {
            // Off the tap callback: the IOHIDSystem round trip is no work for the hot path.
            DispatchQueue.main.async {
                if let on = CapsLockRemap.toggleCapsLockState() { log.notice("Shift+Caps Lock: Caps Lock \(on ? "on" : "off", privacy: .public)") }
                else { log.error("Shift+Caps Lock: could not reach IOHIDSystem") }
            }
        }
        tap.isLayerKeyDown = HyperTap.hidKeyState
        keyboardLock.secureInput = { [unowned self] in secureInput.isActive }
        secureInput.onChange = { [unowned self] on in
            if on { tap.mayHaveLostRelease(); keyboardLock.secureInputCameOn() }
            tap.setSecureInput(on)
        }
        tap.onTapDisabled = { [unowned self] reason in
            // Keys went past the tap meanwhile, so the overlay may have missed its closing key.
            overlay.key()
            log.error("tap disabled by macOS (\(reason, privacy: .public)), re-enabled")
        }
        gate.onGranted = { [unowned self] in start() }
        pilotSwitch.onBinds = { [unowned self] on in on ? armBinds() : disarmBinds() }
        Self.shared = self
    }

    /// Called from didFinishLaunching, never from init: init runs inside SwiftUI's first graph update, where a new
    /// hosting view (a HUD tip) aborts the app. Trusted: everything starts. Not trusted: onboarding asks, and the
    /// grant starts it.
    func launch() {
        secureInput.onTip = { text in
            log.notice("secure input: \(text, privacy: .public)")
            HUD.tip(text, seconds: 5)
        }
        secureInput.start()
        tap.setSecureInput(secureInput.isActive)
        settings.applyLaunchAtLogin()
        SnippetLibrary.shared.start()
        // Made now so a script can read it before its first link (LinkToken).
        if (try? LinkToken.standard.value()) == nil { log.error("link token: could not write \(LinkToken.standard.url.path, privacy: .public)") }
        if gate.isTrusted { start() } else { gate.startPolling() }
        // Reminders need no Accessibility either; one missed while Pilot was off shows now.
        ReminderScheduler.shared.start()
        // The bar needs no Accessibility: it comes back at launch if it was left on.
        topBar.start()
        dock.start()
        // The speech model in use, compiled for a new pilot-dictate a minute in, so the first dictation after an update
        // does not wait minutes (SpeechModel.prepareInBackground); with no model, or one this helper already prepared,
        // nothing. Then the takes a quit left while the model loaded, written down into Recent takes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            Task {
                await SpeechModels.shared.prepareIfStale()
                PilotDictation.shared.collectKept(audio: true)
            }
        }
        // Read aloud's Kokoro the same way, after it, so the two never load at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { Task { await KokoroModel.shared.prepareIfStale() } }
    }

    /// Once, when Accessibility is granted: the observers and the clipboard run whatever the switch says.
    private func start() {
        guard !started else { return }
        started = true
        // The key tap before everything else (lean audit: about 0.14 s sooner): a key pressed while the rest starts waits
        // in the tap for its bind rather than reaching the front app. The tap's callback runs on this main run loop, so
        // no bind runs before start() returns; the pointer taps wait for the observers and the desktop they act on.
        let keysArmed = armKeys()
        observers.onFocusedWindow = { [windowBorder] in
            windowBorder.update($0)
            DefocusController.shared.update($0)
        }
        windowBorder.start()
        DefocusController.shared.start()
        TilerDropZone.show = { [dropZone] in dropZone.update($0, below: $1) }
        mouseTap.outline = { [dropZone] in dropZone.update($0, below: nil) }
        mouseTap.openFiles = { FileActionsMenu.open($0, at: $1) }
        mouseTap.widgets = .init(over: { WidgetDesk.shared.over($0) }, grab: { WidgetDesk.shared.grab(at: $0, resize: $1) }, drag: { WidgetDesk.shared.drag(to: $0) },
                                 drop: { WidgetDesk.shared.drop() }, menu: { WidgetDesk.shared.openMenu(at: $0) },
                                 cancel: { WidgetDesk.shared.cancelGrab() })
        WidgetDesk.shared.shownChanged = { [mouseTap] in mouseTap.widgetsShown = $0 }
        TilerGaps.show = { [gapHandles] in gapHandles.update($0) }
        observers.start()
        startTiler()
        // The desktop's widgets (ADR 0016): nothing is armed while none is placed.
        WidgetDesk.shared.askTrust = { id in
            // Read first: the page may be open on an older read that does not know this widget.
            WidgetsPageModel.shared.reload()
            WidgetsPageModel.shared.asking = id
            AppWindowController.shared.open(AppPlace(.widgets))
        }
        // Remove from Home (its right-click) and a desktop widget's menu: the Widgets page acts and says so.
        WidgetDesk.shared.removePlacement = { WidgetsPageModel.shared.remove(id: $0) }
        WidgetDesk.shared.placementMenu = { id in let menu = WidgetsPageModel.shared.menu(for: id); return (WidgetFolder.sections(id) + menu.sections, menu.checked) }
        // Edit widget from its right-click: the Widgets page opens on that placement's sheet.
        WidgetDesk.shared.editPlacement = { id in
            WidgetsPageModel.shared.reload()
            WidgetsPageModel.shared.editing = id
            AppWindowController.shared.open(AppPlace(.widgets))
        }
        WidgetDesk.shared.start(tiler: observers.tiler)
        shelf.start()
        nudger.start()
        presets.start()
        // Look › Wallpaper per workspace (Q333): a switch puts a workspace's own image, or the screen's own again, on its screen.
        observers.tiler.onWorkspaceShown = { workspace, previous, display in
            WallpaperSwitch.workspaceShown(workspace, after: previous, display: display)
        }
        WallpaperSettings.shared.shownWorkspace = { [tiler = observers.tiler] display in tiler.perMonitor.first { $0.displayUUID == display }?.workspace }
        pilotBlock.carryYabaiFloats()
        ClipboardHistory.shared.start()
        log.notice("engine started, layer keys \(self.settings.layerKeys.rawValues, privacy: .public)")
        if keysArmed { armPointerTaps() }
    }
    private var started = false

    /// The tap and the layer key, only while the on/off switch is on.
    private func armBinds() {
        if armKeys() { armPointerTaps() }
    }

    /// The key tap and the layer key; false when they were left as they are (not started, already on, or switched off).
    private func armKeys() -> Bool {
        guard started, !tap.isRunning else { return false }
        guard pilotSwitch.isOn else { log.notice("binds not armed: Pilot is switched off"); return false }
        applyLayerKey()
        do { try tap.start(); log.notice("tap installed") } catch { lastError = "Could not install the keyboard tap."; log.error("tap creation failed") }
        return true
    }

    /// The mouse tap runs while the binds are armed, on all the time with a drag modifier picked and else only while
    /// Hyper is held (Hyper + right-click on a file, story 199); the swipe's while it is on; Defocus's shake tap, the
    /// Hyper+scroll tap and the selection pill's with the binds.
    private func armPointerTaps() {
        mouseTap.dragging = settings.dragModifier != .off
        if tap.isRunning { mouseTap.start() } else { mouseTap.stop() }
        hyperScroll.arm(tap.isRunning)
        // Hyper+drag moves windows when Hyper is the drag modifier, so the pill's tap stays off then.
        SelectionTools.shared.arm(tap.isRunning && settings.dragModifier != .hyper, layer: tap)
        swipe.update(on: tap.isRunning && settings.swipeWorkspaces)
        DefocusController.shared.arm(tap.isRunning)
        armMouseButtons()
    }

    private func armMouseButtons() {
        mouseButtons.arm(running: tap.isRunning, binds: binds.store.mouseBinds)
    }

    /// The switch's off, and quit: no tap, Caps Lock is Caps Lock again (or whatever Karabiner makes it) and swapped
    /// keys are themselves.
    private func disarmBinds() {
        tap.stop()
        armPointerTaps()
        if !mappingWritten.isEmpty, CapsLockRemap.apply([], over: CapsLockRemap.current, own: ownMapping) { mappingWritten = [] }
    }

    /// Pilot's tiler with Pilot's settings: at launch, and Home's and the dropdown's Restart. Windows a crash left off
    /// screen come back first, once no other tiler runs (card agent-bo-95422999, AC5).
    func startTiler() {
        Task { [tiler = observers.tiler, pilotBlock, rescue] in
            await tiler.startEngine({ tiler.tilerSettings(pilotBlock.block) }, beforeStart: { rescue.bringBackQuietly() })
        }
    }

    func quit() {
        // Every window the engine parked goes back on screen.
        shelf.stop()
        observers.tiler.stopEngine()
        disarmBinds()
        if pressSave != nil { savePresses() }
    }

    /// The tap is installed: Hyper and every bind work.
    var bindsArmed: Bool { tap.isRunning }

    /// The `n` actions run most of all time, most first, ties by name (TodayPresses.top's order); from the counts the
    /// overlay's most used reads, empty when their file could not be read.
    func topPresses(_ n: Int) -> [(action: String, count: Int)] {
        (pressCounts?.counts ?? [:]).sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(n).map { ($0.key, $0.value) }
    }

    /// Home's Needs you, as Home and the dropdown list it.
    var homeProblems: [HomeProblems.Problem] {
        HomeProblems.list(accessibilityGranted: gate.isTrusted, secureInput: secureInput.holder, tilerRunning: observers.tiler.isAnswering,
                          lastError: lastError)
    }

    #if DEBUG
    /// The renders' sample presses, newest first.
    func seedPresses(_ list: [(Key, String)]) {
        presses = list.map { Press(time: .now, key: $0.0, action: $0.1, app: "Finder") }
    }

    /// The renders' day of presses, in place of the one saved on this Mac.
    func seedToday(_ presses: TodayPresses) { today = presses }
    #endif

    /// Settings changed: re-arm the tap and Pilot's key mapping.
    func settingsChanged() {
        tap.update(layerKeys: settings.layerKeys, quickTapEscape: settings.quickTapEscape)
        if tap.isRunning { applyLayerKey() }
    }

    private var ownMapping: Set<KeyMappingEntry> { KeyMappingEntry.pilotOwned(written: mappingWritten, swaps: settings.keySwaps) }

    /// The layer keys' conflict tip, and Pilot's one mapping set written: Caps Lock to F18 (a modifier layer key needs
    /// none) and the swaps. Never fights another tool's mapping.
    private func applyLayerKey() {
        let keys = settings.layerKeys
        let mapping = CapsLockRemap.current, own = ownMapping
        if RemapConflict.exists(layerKeys: keys, userKeyMapping: mapping, own: own) {
            let text = RemapConflict.tip(for: keys)
            log.notice("conflict: \(text, privacy: .public)")
            HUD.tip(text)
        }
        let foreign = mapping.filter { !own.contains($0) }
        if foreign != foreignMapping { foreignMapping = foreign }
        let next = KeyMappingEntry.pilotSet(layerKeys: keys, swaps: settings.keySwaps, foreign: foreignMapping)
        for swap in settings.keySwaps {
            if let problem = swap.problem(layerKeys: keys, foreign: foreignMapping) { log.notice("swap \(swap.word, privacy: .public) not applied: \(problem, privacy: .public)") }
        }
        // Written also when a killed Pilot left a mapping behind; skipped when every keyboard holds it already.
        guard next != mappingWritten || Set(KeyMappingEntry.merged(mapping, own: own, next: next)) != Set(mapping) else { return }
        if CapsLockRemap.apply(next, over: mapping, own: own) { mappingWritten = next } else { lastError = "Could not set Pilot's key mapping." }
    }

    /// One more press of `id`; the counts are written 2 s after the last press, and at quit.
    private func countPress(_ id: String) {
        today.count(id, at: .now)
        pressCounts?.count(id)
        pressSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.savePresses() }
        pressSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: save)
    }

    private func savePresses() {
        pressSave = nil
        do { try todayFile.save(today) } catch { log.error("presses: today not written: \(String(describing: error), privacy: .public)") }
        guard let counts = pressCounts else { return }
        do { try PressCountStore.standard.save(counts) } catch { log.error("presses: not written: \(String(describing: error), privacy: .public)") }
    }

    private func record(_ key: Key, action: String?) {
        let app = observers.focusedApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let press = Press(time: .now, key: key, action: action, app: app)
        presses.insert(press, at: 0)
        if presses.count > 50 { presses.removeLast() }
        // A key with no bind does nothing, so it logs only at debug level.
        if action == nil { log.debug("\(LinkToken.redact(press.line), privacy: .public)") } else { log.notice("\(LinkToken.redact(press.line), privacy: .public)") }
    }

    private func registerActions() {
        // The engine's own actions. Other modules register theirs the same way: id, label, default key, tier.
        // The cheat sheet is the menu's Learn → Keybindings, every bind, Return runs one (story 27).
        try? registry.register(Action(id: "engine.sheet", label: "Keybindings", module: .engine, defaultKey: Key("c")) {
            PilotMenu.shared.toggle(branch: .keybindings)
        })
        try? registry.register(Action(id: "engine.openWindow", label: "Open Pilot", module: .engine) {
            AppWindowController.shared.open()
        })
        TopBarController.register(into: &registry, bar: topBar)
        // Unbound by default. Off, only a plain-combo bind of it still fires, so turning Hyper back on never needs Hyper.
        try? registry.register(Action(id: "engine.hyper", label: "Hyper key on or off", module: .engine) { [unowned self] in
            hyperSwitch.toggle()
        })
        // General's and Home's buttons, so the pilot command reaches them (CLI W2): unbound.
        try? registry.register(Action(id: "engine.restartTiler", label: "Restart Pilot's tiler", module: .engine) { [unowned self] in
            startTiler()
        })
        try? registry.register(Action(id: "engine.grantAccessibility", label: "Grant Accessibility", module: .engine) { [unowned self] in
            gate.request()
        })
        KeyboardLockController.register(into: &registry, lock: keyboardLock)
        try? registry.register(Action(id: "system.openFullDiskAccess", label: "Open Full Disk Access settings", module: .system) {
            SystemModule.openFullDiskAccess()
        })
        // The dropdown's Tiling switch, one action a side so a run never flips it blind.
        for on in [true, false] {
            try? registry.register(Action(id: on ? "engine.tilingOn" : "engine.tilingOff", label: on ? "Turn tiling on" : "Turn tiling off",
                                          module: .engine) { [unowned self] in
                if tilingSwitch.tiling != on { tilingSwitch.toggle() }
            })
        }
        try? registry.register(Action(id: "engine.support", label: "Support Pilot", module: .engine) {
            NSWorkspace.shared.open(GeneralPage.supportURL)
        })
        // Send feedback (card agent-bo-95423195): unbound; the menu finds both by "feedback".
        for kind in Feedback.Kind.allCases {
            try? registry.register(Action(id: kind.actionID, label: kind.label, module: .engine, keywords: "feedback") { [unowned self] in
                SendFeedback.open(kind, layerKeys: settings.layerKeys)
            })
        }
        WindowsModule.register(into: &registry, observers: observers)
        WorkspacesModule.register(into: &registry, tiler: observers.tiler, block: pilotBlock, layouts: layouts)
        WindowRescue.register(into: &registry, rescue: rescue)
        WorkspaceSnapshots.register(into: &registry, snapshots: snapshots)
        WorkspacePresets.register(into: &registry, presets: presets)
        AppsModule.register(into: &registry)
        CapturesModule.register(into: &registry)
        DriveModule.register(into: &registry)
        ScriptsModule.register(into: &registry)
        ExtensionsModule.register(into: &registry)
        SystemModule.register(into: &registry)
        DictationModule.register(into: &registry)
        RingsModule.register(into: &registry, rings: rings)
        GhosttyBridge.register(into: &registry)
        NotesPanel.register(into: &registry)
        QuickAIActions.register(into: &registry)
        ReadAloud.register(into: &registry)
        SelectionTools.register(into: &registry)
        AIChatPanel.register(into: &registry)
        TerminalDrop.register(into: &registry)
        CursorEffects.register(into: &registry)
    }

    /// Posts a layer key plus one key into the HID stream, as a keyboard would, and lets the tap handle it.
    /// Only the trusted app can post; a terminal without Accessibility has its events dropped silently. Needs the link
    /// token (LinkToken): a press can fire a bind that runs a command, or post a key into the app in front.
    func testPress(_ url: URL) {
        let value = url.queryValue
        guard LinkToken.standard.matches(value("token")) else { return Self.refuseLink("press", value("key") ?? "") }
        // nil is layer=chord: cmd+ctrl+alt posted with the key, as the Keychron knob sends it, and no layer key;
        // layer=plain posts the key with only its modifiers, a plain combo (story 51).
        let word = value("layer") ?? ""
        let plain = word == "plain"
        let layer: LayerKey? = word == "chord" || plain ? nil : LayerKey(pressWord: word) ?? .capsLock
        let tapOnly = value("tap") == "1"
        guard ensureFrontmost(value("app")) else { return }
        let (modifiers, sublayer) = Self.sublayer(value)
        let shift = sublayer & KeyEvent.shiftMask != 0
        guard tapOnly || KeyNames.code(for: value("key") ?? "") != nil else { log.error("press: unknown key"); return }
        let key = KeyNames.code(for: value("key") ?? "") ?? 0
        func layerKey(down: Bool) {
            guard let layer else { return }
            if let side = layer.side {
                Post.events([KeyEvent(kind: .flagsChanged, keyCode: layer.keyCode, flags: down ? KeyEvent.flags(for: side) : 0)], own: false, pause: 15_000)
            } else {
                // tap=1&shift=1 is Shift+Caps Lock.
                Post.events([KeyEvent(kind: down ? .keyDown : .keyUp, keyCode: layer.keyCode, flags: shift && tapOnly ? KeyEvent.shiftMask : 0)],
                            own: false, pause: 15_000)
            }
        }
        let label = Key(keyCode: key, modifiers: modifiers, hyper: !plain).label
        log.notice("press: posting \(layer?.rawValue ?? (plain ? "plain" : "chord"), privacy: .public) + \(tapOnly ? "tap" : label, privacy: .public)")
        layerKey(down: true)
        if !tapOnly {
            // Pressed and released as a keyboard does (KeyEvent.keystroke), so a chord or a modifier never stays held.
            let held: Modifiers = layer == nil && !plain ? modifiers.union([.ctrl, .alt, .cmd]) : modifiers
            Post.events(KeyEvent.keystroke(key, modifiers: held), own: false, pause: 15_000)
        }
        usleep(30_000)
        layerKey(down: false)
    }

    /// Activates the app the URL names and waits for it to be frontmost. False (and a log line) when another
    /// app holds focus: a test never lands on the wrong window.
    private func ensureFrontmost(_ name: String?) -> Bool {
        guard let name else { return true }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name || $0.bundleIdentifier == name }) else {
            log.error("press: \(name, privacy: .public) is not running, skipped"); return false
        }
        app.activate()
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
            usleep(50_000)
        }
        log.error("press: \(name, privacy: .public) did not come to the front, skipped")
        return false
    }

    /// pilot://run?action=windows.close[&app=Finder] runs one action by id, bypassing the tap. Picker actions work
    /// unbound: action=apps.open:com.apple.Notes, action=apps.web:https://chatgpt.com or a drive route,
    /// action=drive.menu:com.apple.finder:File > New Finder Window (URL-encoded). A command, a keystroke, a non-web URL, or
    /// Wi-Fi, Bluetooth, shut down, restart, sleep, log out or a lock (ControlGate.Ask.cutting) also needs the link token
    /// (LinkToken), so a link on a web page cannot run one.
    func runAction(_ url: URL) {
        let value = url.queryValue
        guard let id = value("action"), let action = action(id) else { log.error("run: unknown action"); return }
        guard LinkToken.standard.allows(id, token: value("token")) else { return Self.refuseLink("run", id) }
        guard ensureFrontmost(value("app")) else { return }
        log.notice("run: \(LinkToken.redact(id), privacy: .public)")
        action.run()
    }

    private static func refuseLink(_ verb: String, _ id: String) {
        log.error("\(verb, privacy: .public): refused \(LinkToken.redact(id), privacy: .public): needs &token= from \(LinkToken.standard.url.path, privacy: .public)")
    }

    /// A URL's shift, ctrl, alt and cmd: =1 either side, the sublayer held with the layer key (story 50); =left or
    /// =right one side, for a plain combo (story 51). With the event flags a press posts, device bits included.
    private static func sublayer(_ value: (String) -> String?) -> (modifiers: Modifiers, flags: UInt64) {
        let modifiers = [(Modifiers.leftShift, Modifiers.rightShift, "shift"), (.leftCtrl, .rightCtrl, "ctrl"),
                         (.leftAlt, .rightAlt, "alt"), (.leftCmd, .rightCmd, "cmd")].reduce(into: Modifiers()) { held, m in
            switch value(m.2) {
            case "1": held.formUnion([m.0, m.1])
            case "left": held.formUnion(m.0)
            case "right": held.formUnion(m.1)
            default: break
            }
        }
        return (modifiers, KeyEvent.flags(for: modifiers))
    }

    /// The Binds editor's Record: the next Hyper key, or plain combo, comes to `done` instead of running; nil stops
    /// listening. `onlyHyper` leaves every other key to run or type as usual (the bind hint's wait, story 122).
    func recordKey(onlyHyper: Bool = false, _ done: ((Key) -> Void)?) {
        tap.captureNext = done
        tap.captureOnlyHyper = done != nil && onlyHyper
    }

    /// The Binds board while its window is in front: every Hyper key comes to `pick`, a bound one running too (T48);
    /// nil stops.
    func pickKeys(_ pick: ((Key) -> Void)?) { tap.picking = pick }

    /// pilot://bind?action=windows.close&key=x[&shift=1][&ctrl=1][&alt=1][&cmd=1] binds an action under Hyper, or with
    /// &plain=1 as a plain combo (alt=left, alt=right or alt=1 for either side, the same for the others), refused with a log line when
    /// another holds the key; &unbind=1 leaves it with no key, &reset=1 puts its default back, action=all&reset=1 resets
    /// every bind; pilot://bind?preset=pilot (or myBinds, or a preset's id) switches the preset. The Binds screen's changes, without hands.
    /// Binding a command, a keystroke, a non-web URL, or Wi-Fi, Bluetooth, shut down, restart, sleep, log out or a lock
    /// (ControlGate.Ask.cutting) to a key also needs the link token (LinkToken).
    func bind(_ url: URL) {
        let value = url.queryValue
        if let name = value("preset") {
            guard let preset = binds.store.preset(id: name) else { return log.error("bind: unknown preset \(name, privacy: .public)") }
            return binds.use(preset)
        }
        guard let id = value("action") else { return log.error("bind: no action") }
        do {
            if value("reset") == "1" { return id == "all" ? binds.resetAll() : try binds.reset(id) }
            guard action(id) != nil else { return log.error("bind: unknown action \(LinkToken.redact(id), privacy: .public)") }
            if value("unbind") == "1" { return clearKey(id) }
            guard LinkToken.standard.allows(id, token: value("token")) else { return Self.refuseLink("bind", id) }
            guard let code = KeyNames.code(for: value("key") ?? "") else { return log.error("bind: unknown key") }
            let key = Key(keyCode: code, modifiers: Self.sublayer(value).modifiers, hyper: value("plain") != "1")
            guard key.hyper || !key.modifiers.isDisjoint(with: [.ctrl, .alt, .cmd]) else {
                return log.error("bind: a plain combo needs cmd, ctrl or alt")
            }
            try binds.set(id, to: key)
        } catch {
            // Binds logged the refusal.
        }
    }

    /// Leaves `id` with no key, as pilot://bind's &unbind=1: a page's × on a bound key (Abilities, an extension's command).
    func clearKey(_ id: String) {
        do { try binds.set(id, to: nil) } catch {
            // Binds logged the refusal.
        }
    }

    /// Every action the Binds screen and the menu list (BindsPage.actions), less go and move for a removed workspace and
    /// the optional abilities not added (Abilities.isListed).
    var bindActions: [BindsPage.ActionInfo] { allBindActions.filter { isListed($0.id) } }

    /// Every action, the optional abilities not added included: Launcher › Abilities' More abilities offers those.
    var allBindActions: [BindsPage.ActionInfo] {
        let kept = observers.tiler.workspaces
        // A ring made since launch lists beside the registered ones.
        let rings = rings.store.rings.rings.map(\.openID).filter { registry.actions[$0] == nil }.compactMap { action($0).map(Self.info) }
        return BindsPage.actions(registered: registry.sorted.map(Self.info) + rings, store: binds.store) { action($0).map(Self.info) }
            .filter { !Workspaces.isRemoved(action: $0.id, kept: kept) }
    }

    func isListed(_ id: String) -> Bool {
        let abilities = AbilitySettings.shared
        return Abilities.isListed(id, bound: binds.store.trigger(for: id) != nil, added: abilities.added, has: abilities.has)
    }

    /// The bind editor's actions: the Binds screen's, and `id` when the menu's Cmd+K Set Hyper bind picked an action that
    /// is not bound yet (a script, a config), so the editor names it (Moody f0FISQ2s1B4).
    func bindActions(including id: String?) -> [BindsPage.ActionInfo] { bindActions(including: id.map { [$0] } ?? []) }

    /// The Binds screen's actions and each of `ids` they lack: Binds › Mouse's binds, a route the AI picked among them.
    func bindActions(including ids: [String]) -> [BindsPage.ActionInfo] {
        let actions = bindActions
        let listed = Set(actions.map(\.id))
        return actions + Set(ids).subtracting(listed).sorted().compactMap { action($0).map(Self.info) }
    }

    private static func info(_ a: Action) -> BindsPage.ActionInfo { .init(id: a.id, label: a.label, module: a.module.rawValue, keywords: a.keywords) }

    /// A registered action, or one the Binds screen made from the app or URL picker or a drive route, built once: its label asks
    /// LaunchServices, too slow for every press inside the tap.
    /// An imported bind not turned on yet (story 58) keeps its name and does nothing, from the tap, the menu or pilot://run.
    func action(_ id: String) -> Action? {
        guard let action = lookup(id) else { return nil }
        return binds.store.isDisabled(id) ? switchedOff(action) : action
    }

    private func switchedOff(_ action: Action) -> Action {
        let id = action.id
        return action.with { log.notice("binds: \(LinkToken.redact(id), privacy: .public) is switched off; turn it on in Export and import") }
    }

    private func lookup(_ id: String) -> Action? {
        // A quicklink is built each time, never kept: an answer's id holds the words searched (card agent-bo-95423030).
        if let link = QuicklinksModule.dynamic(id) { return link }
        // So is a script run the root answered: its id holds the values typed (card agent-bo-95423048).
        if ScriptCommand.arguments(inAction: id) != nil { return ScriptsModule.dynamic(id) }
        // And an extension command's keyword answer: its id holds the text typed.
        if Extension.input(inAction: id) != nil { return ExtensionsModule.dynamic(id) }
        // A ring (P74): built each time from the rings as they are, so one made or renamed after launch shows.
        if let ring = RingsModule.dynamic(id, rings: rings) { return ring }
        if let action = registry.actions[id] ?? dynamicActions[id] { return action }
        // A settings row's pane or window place (SettingsSearch, Q131).
        if let setting = SettingsActions.dynamic(id) { return setting }
        // Dress or reset the folders selected in Finder (P43).
        if let folders = FolderDesigns.dynamic(id) { return folders }
        // Named as the drive catalogue names it, "Ghostty: New window", where it holds the id.
        let action = (AppsModule.dynamic(id) ?? SystemModule.dynamic(id) ?? DriveModule.dynamic(id) ?? ConfigsModule.dynamic(id)
                      ?? ScriptsModule.dynamic(id) ?? ExtensionsModule.dynamic(id)).map { a in
            DriveModule.catalogue.label(for: id).map { Action(id: id, label: $0, module: a.module, run: a.run) } ?? a
        }
        dynamicActions[id] = action
        return action
    }
    @ObservationIgnored private var dynamicActions: [String: Action] = [:]

    /// Deletes a ring and every bind that opens it, its key and each button's hold (P74), so none is left opening another.
    /// The Pilot ring, which follows the menu, is never deleted.
    func deleteRing(_ id: String) {
        guard let ring = rings.store.rings.ring(id: id), !ring.menu else { return }
        rings.store.change { $0.rings.removeAll { $0.id == id } }
        binds.remove(ring.openID)
        for b in binds.store.mouseBinds where b.bind.action == ring.openID { binds.setMouse(b.trigger, to: nil) }
        log.notice("rings: \(LinkToken.redact(id), privacy: .public) deleted with what opened it")
    }

    /// The ring's hooks into the taps (P74): its scroll and Esc while open, the hold-bound buttons' Hold after and a media
    /// key's quick press sent on to Now Playing, and what its wedges show and run.
    private func wireRings() {
        rings.scroll = { [hyperScroll] in hyperScroll.ring($0) }
        rings.escape = { [tap] esc, close in tap.endRing = esc; tap.closeRing = close }
        rings.run = { [unowned self] id, pointer in
            guard let action = action(id) else { return log.notice("rings: \(LinkToken.redact(id), privacy: .public) is no action") }
            countPress(id)
            // A window wedge acts on the window under the pointer (Q415), focused first; with the tiler off, on the one in front.
            guard id.hasPrefix("windows."), observers.tiler.isRunning else { return action.run() }
            Task { [unowned self] in
                await focusWindow(under: pointer)
                action.run()
            }
        }
        rings.label = { [unowned self] in action($0)?.label }
        rings.keys = { [unowned self] in binds.store.trigger(for: $0)?.label }
        rings.roleApps = AppsModule.roleApps
        rings.menu = { [unowned self] in RingMenuSource(engine: self).wedges }
        let audio = CoreAudioSystem()
        rings.states = { [unowned self] in
            var on = SystemModule.switchStates()
            on["media.mute"] = audio.defaultDevice(.output).flatMap { audio.muted($0, .output) }
            on["engine.topBar"] = topBar.isOn
            on["captures.screenRecording"] = Recorder.shared.isActive
            return on
        }
        // A hold-bound media key's quick press, to macOS's own Now Playing as Pilot's media actions post it.
        tap.onReplay = { Post.media(keyType: Int32($0.keyCode - MouseKeys.media(0).keyCode)) }
        rings.store.onChange = { [unowned self] in tap.holdAfter = Double(rings.store.rings.holdAfter) / 1000 }
        rings.store.onChange()
    }

    /// Focuses the window under `pointer` (screen points, bottom-left origin) through the tiler and waits, briefly, until it
    /// is the frontmost app's focused window, which is what a window action reads. Nothing under the pointer, or that
    /// window already in front: nothing to do.
    private func focusWindow(under pointer: CGPoint) async {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: pointer.x, y: top - pointer.y)   // the window server's top-left space
        guard let target = observers.windows().first(where: { $0.frame.contains(point) }).map({ Int($0.id) }) else { return }
        let tiler = observers.tiler
        func inFront() async -> Bool { (try? await tiler.frontWindow(tiler.runner))?.id == target }
        if await inFront() { return }
        await tiler.perform("rings.focusWindow") { try await $0.run(.focusWindow(id: target)) }
        for _ in 0..<15 {
            if await inFront() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.notice("rings: the window under the pointer was not in front in time; the wedge acts on the one that is")
    }

    /// The menu-bar icon's number; the observers dump prints it too, so a live check reads what the icon shows. The
    /// timer draws its own item since card agent-bo-95422911.
    var menuBarTitle: String {
        MenuBarTitle.text(isOn: pilotSwitch.isOn, workspace: observers.tiler.focused, secureInput: secureInput.isActive)
    }

    func printObservers() {
        let s = observers.snapshot() + "\nmenu bar: \(menuBarTitle)\n" + topBar.line + "\n" + dock.line + "\n" + BarItemsStore.shared.line
        log.notice("observers:\n\(s, privacy: .public)")
        print(s)
    }
}
