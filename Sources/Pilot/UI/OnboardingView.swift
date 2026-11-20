import AppKit
import Carbon.HIToolbox
import PilotCore
import SwiftUI

/// First-run onboarding (stories 1, 2, 40, 94, 103 and 104; Onboarding 1.1, variant C, Sven 2026-11-04, Q841-Q843): five
/// screens under one step rail. Hyper picks the key, Access waits for Accessibility alone, Keys picks a preset (T12), Set up runs everything or what
/// is picked by hand with progress and undo (OnboardingSetup), and Try it ticks on a hold, Hyper+F and Hyper+Space. Opens
/// by itself while Accessibility is missing or a run is unfinished (OnboardingWindow).
struct OnboardingView: View {
    @Environment(Engine.self) private var engine
    @Environment(\.dismissWindow) private var dismiss
    @State private var model: OnboardingModel
    @State private var confirming: LayerKeyChange?

    private let look: Look
    /// Set up's lists scroll inside this height, so the window fits a 13-inch screen.
    static let scrollHeight: CGFloat = 470

    /// `model` is the renders' seam, to show a later step; Pilot opens on a fresh one. `look` stands in for the shared
    /// Look in tests.
    init(model: OnboardingModel = OnboardingModel(), look: Look = .shared) {
        _model = State(initialValue: model)
        self.look = look
    }

    var body: some View {
        Group {
            instrument
        }
        .background { WelcomeWindow() }
        .onAppear { model.start(engine) }
        .onDisappear { model.stop(); OnboardingWindow.closed() }
        .onChange(of: engine.hyperHeld) { if engine.hyperHeld && model.step == .tryIt { model.tryIt.held = true } }
    }

    /// Instrument's (ADR 0008): its own window in the style's canvas, dark or light, title bar too.
    private var instrument: some View {
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        let canvas = Color(tokens.colors.canvas)
        return InstrumentOnboarding(model: model, confirming: $confirming, finish: { model.finish(); dismiss(id: "onboarding"); OnboardingWindow.close() })
            .styled(.onboarding, look: look)
            .pilotTheme(look: look)
            .background(canvas)
            .containerBackground(canvas, for: .window)
            .background { DarkWindow(dark: tokens.dark) }
    }
}

/// The Welcome window while it is open (Sven's first run, 2026-10-28: "only show the welcome landing page, not the actual
/// Pilot app until onboarding is done"). Opened at launch it comes to the front, and a second launch brings it forward
/// instead of the app window. A run not finished opens it again at the next launch, at the step it reached, and Set up's
/// run where it stands (OnboardingSetup's saved ledger).
@MainActor
enum OnboardingWindow {
    private static weak var window: NSWindow?
    /// Set only when Welcome opens by itself at launch, so the renders' windows never come forward.
    private static var raiseWhenOpened = false
    /// The step an unfinished run reached, taken once by the model that opens at launch.
    private static var resume: OnboardingModel.Step?
    static let unfinishedKey = "onboarding.unfinished", stepKey = "onboarding.step"
    /// The model on screen, for `pilot status --part onboarding` (T12): its step, else the saved resume point.
    static weak var shown: OnboardingModel?

    /// Whether Welcome opens by itself at this launch: Accessibility is missing, or a run is unfinished. A Mac set up
    /// before the key existed never wrote it, so it stays quiet.
    static func opensAtLaunch(_ defaults: UserDefaults = .pilot()) -> Bool {
        let unfinished = defaults.bool(forKey: unfinishedKey)
        guard !AXIsProcessTrusted() || unfinished else { return false }
        defaults.set(true, forKey: unfinishedKey)
        if unfinished { resume = defaults.string(forKey: stepKey).flatMap(OnboardingModel.Step.init) }
        raiseWhenOpened = true
        return true
    }

    static func reached(_ step: OnboardingModel.Step, _ defaults: UserDefaults = .pilot()) { defaults.set(step.rawValue, forKey: stepKey) }

    static func takeResume() -> OnboardingModel.Step? {
        defer { resume = nil }
        return resume
    }

    static func finished(_ defaults: UserDefaults = .pilot()) {
        defaults.set(false, forKey: unfinishedKey)
        defaults.removeObject(forKey: stepKey)
    }

    static func opened(_ w: NSWindow) {
        window = w
        guard raiseWhenOpened else { return }
        raiseWhenOpened = false
        DispatchQueue.main.async { bringForward() }
    }

    static func closed() { window = nil; hosted = nil }

    /// Run setup again's own window (Q847), held until it closes: the Welcome scene opens only through SwiftUI's
    /// openWindow, which Settings' AppKit-hosted page cannot reach.
    private static var hosted: NSWindow?

    /// Settings › General's Run setup again (Sven, 2026-11-04, Q847): onboarding from its first screen, marked unfinished
    /// so a quit reopens it; Set up's run in progress resumes, else its fork shows afresh. Nothing is undone. An open
    /// Welcome only comes forward.
    static func again(engine: Engine, _ defaults: UserDefaults = .pilot()) {
        // An open Welcome only comes forward: its run and step stay as they are (reviewer, T54).
        if bringForward() { return }
        defaults.set(true, forKey: unfinishedKey)
        defaults.removeObject(forKey: stepKey)
        OnboardingSetup.shared.again()
        log.notice("onboarding: run setup again")
        let host = NSHostingView(rootView: OnboardingView().environment(engine))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Pilot"
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.center()
        hosted = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Access's Allow: Welcome to its screen's left edge, out from under System Settings, which opens near the middle.
    static func moveAside() {
        guard let window, let screen = window.screen?.visibleFrame else { return }
        window.setFrameOrigin(CGPoint(x: screen.minX + 24, y: window.frame.minY))
    }

    /// Finish: closes whichever window holds Welcome, the scene's or Run setup again's.
    static func close() { window?.close() }

    /// Welcome to the front; false when it is not open.
    @discardableResult static func bringForward() -> Bool {
        guard let window, window.isVisible || window.isMiniaturized else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// The menu bar's Allow for Accessibility (Sven, 2026-10-28, Q1): Welcome while it is open, else Pilot's front, whose
    /// Needs you holds Accessibility's Grant until it is granted (simplify-pages T8).
    static func openPermissions() {
        if !bringForward() { AppWindowController.shared.open(AppPlace(.general)) }
    }
}

/// Hands the window holding it to OnboardingWindow.
private struct WelcomeWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() { if let window { OnboardingWindow.opened(window) } }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}

/// Gives the window holding it Pilot's appearance (dark for a dark palette), title bar included, without touching Pilot's other windows.
private struct DarkWindow: NSViewRepresentable {
    /// The style's dark or light.
    let dark: Bool
    final class View: NSView {
        var dark = true
        override func viewDidMoveToWindow() { apply() }
        func apply() {
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            if let window, window.appearance?.name != name { window.appearance = NSAppearance(named: name) }
        }
    }
    func makeNSView(context: Context) -> View { let view = View(); view.dark = dark; return view }
    func updateNSView(_ view: View, context: Context) { view.dark = dark; view.apply() }
}

/// Onboarding's state (Onboarding 1.1, T54): the step, Accessibility read once a second while Access shows, and Try
/// it's ticks. Set up's run is OnboardingSetup's, which outlives the window. Nothing on Access but Accessibility is read:
/// the other grants are named for later and asked in Settings › Permissions, at a feature's first use, or by Try it's
/// Allow the rest (ADR 0012).
@Observable @MainActor
final class OnboardingModel {
    /// The five screens. The raw values are the saved resume points from 1.0 (`onboarding.step`), kept so a run cut off
    /// mid-way resumes; on screen they read Hyper, Access, Keys, Set up, Try it. Keys (pilot-ui-redesign T12) comes
    /// before Set up, as Set up B's drawing has it (Q264), so Try it shows the picked keys.
    enum Step: String, CaseIterable {
        case welcome, permissions, keys, extras, tryIt

        var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

        var title: String {
            switch self {
            case .welcome: "Hyper"
            case .permissions: "Access"
            case .keys: "Keys"
            case .extras: "Set up"
            case .tryIt: "Try it"
            }
        }
    }

    var step = Step.welcome
    private(set) var status = Onboarding.Status()
    var tryIt = Onboarding.TryIt(menuOpens: 0)
    /// Try it's "More, if you want", open.
    var showsMore = false
    /// Access's Allow was pressed, and System Settings is running since: its three steps follow them.
    var accessAsked = false
    var settingsOpen = false
    /// Each Hyper choice's warning, worked out once: binds do not change during onboarding, and a label lookup walks every
    /// action source.
    @ObservationIgnored private var breaks: [LayerKey: String?] = [:]
    /// The attached keyboards' vendor ids, read once, as Hyper first shows: which Hyper keys this Mac has.
    @ObservationIgnored lazy var keyboards = BluetoothPower.keyboardVendors()
    func hyperChoices(_ current: [LayerKey]) -> [LayerKey] { Onboarding.hyperChoices(keyboards: keyboards, current: current) }
    func hyperBreaks(_ key: LayerKey, _ engine: Engine) -> String? {
        if let known = breaks[key] { return known }
        let line = Onboarding.hyperBreaks(key, bound: engine.boundLabel)
        breaks[key] = line
        return line
    }
    /// More's place in Try it's scroll (TryItScroll), which opening it scrolls to.
    static let moreID = "onboarding.more"
    /// Pilot Files came forward since Try it showed.
    private(set) var filesOpened = false
    let setup: OnboardingSetup
    /// Try it's Allow the rest (T58): nothing read until it starts.
    let walk: GrantWalk
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var opened = Date()
    @ObservationIgnored private weak var engine: Engine?

    /// Hyper's screen's head and line (Sven's critique, 2026-11-18, option B): ricing first, then the launcher.
    static let welcomeTitle = "Rice your Mac.", welcomeLine = "A launcher that does the rest."
    /// What Hyper is, in two short lines (Sven, 2026-11-19: shorter and plainer; option A of two).
    static let hyperAbout = "Pick one key to be Hyper. Hold it and press another key to run a Pilot shortcut."
    static let accessAbout = "One switch in System Settings, and Pilot is ready."
    /// What Accessibility lets Pilot do, and the one thing it never sees: each a fact of the code (the tap, the window
    /// binds, the menu's key; password fields are blind to the tap).
    static let accessCan = ["read the Hyper key and run your binds", "snap or move a window when you press its key", "open the launcher on Hyper+Space"]
    static let accessNever = "It never sees password fields: macOS hides them from it."
    /// The later grants in one line (B): the first two named, the rest counted.
    static var laterLine: String {
        let names = later.map(\.short)
        return "Later, only when a feature needs it: " + names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and \(names.count - 2) more." : ".")
    }
    static let passwordNote = "Homebrew asks your Mac's password once, in Terminal."
    /// Says what Undo cannot do (reviewer, T54): it puts back what was there before Set up, over any change since, and
    /// Homebrew keeps what it installed with a helper.
    static let undoNote = "Undo puts back what was there before Set up, even over a change you made since; removing a helper leaves what Homebrew brought with it, such as ffmpeg's libraries. Open a group to undo one line."
    static let pickNote = "Each row says what it gives. Nothing changes until you press Set up these."
    static let undoAfter = "Every change can be undone after."
    static let ticksItself = "This step ticks itself"

    /// The recommended and optional grants, which Access's later line names (`laterLine`). The when-used ones stay with
    /// the features that ask for them.
    static let later = Onboarding.Row.rows(.recommended) + Onboarding.Row.rows(.optional)

    /// `setup` and `walk` are the renders' seams; Pilot's are the shared run and the Mac's own grants.
    init(setup: OnboardingSetup = .shared, walk: GrantWalk = GrantWalk()) {
        self.setup = setup
        self.walk = walk
    }

    func start(_ engine: Engine) {
        self.engine = engine
        opened = Date()
        if let resume = OnboardingWindow.takeResume() { step = resume }
        setup.loadKeys(engine.binds.store)
        OnboardingWindow.shown = self
        if step == .tryIt { resetTryIt() }
        log.notice("onboarding: shown at \(self.step.rawValue, privacy: .public)")
        refresh()
        // A second start (the same model shown again) replaces the first timer rather than leaving it running.
        self.timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A step's button: the step, kept so a relaunch opens there.
    func go(_ next: Step) {
        // Moving on closes the helper beside Settings that Accessibility's Allow shows.
        PermissionDragPanel.close(reason: "onboarding moved to \(next.rawValue)")
        step = next
        OnboardingWindow.reached(next)
    }

    /// Keys' Continue: the picked preset becomes the active one, then Set up.
    func useKeys() {
        if let engine { setup.useKeys(engine.binds) }
        go(.extras)
    }

    /// Set up's Continue or Skip: Try it, which counts only what happens from here: a hold, the menu opening and Pilot
    /// Files coming forward after this moment.
    func startTryIt() {
        resetTryIt()
        go(.tryIt)
    }

    private func resetTryIt() {
        tryIt = Onboarding.TryIt(menuOpens: PilotMenu.shared.opens)
        filesOpened = false
        filesAtStart = Self.filesShown()
    }

    @ObservationIgnored private var filesAtStart = 0

    /// Pilot Files windows on screen: one more than at Try it's start, or one in front, ticks its row.
    private static func filesShown() -> Int { NSApp.windows.count { $0.title == "Pilot Files" && $0.isVisible } }

    /// Try it's demo is done: Hyper held, Pilot Files opened (when its row shows) and the menu opened (when its row
    /// shows). The whole tab then says so at once, with the rail's step ticked (Sven, 2026-11-19).
    func demoDone(_ engine: Engine) -> Bool {
        tryIt.held && (menuKey(engine) == nil || tryIt.menuOpened) && (filesKey(engine) == nil || filesOpened)
    }

    /// Demo done's line: what the user did, Pilot Files and the menu only when their rows showed.
    func demoLine(_ engine: Engine) -> String {
        let opened = [filesKey(engine).map { _ in "Pilot Files" }, menuKey(engine).map { _ in "the menu" }].compactMap { $0 }
        return opened.isEmpty ? "You held Hyper." : "You held Hyper and opened \(opened.joined(separator: " and "))."
    }

    /// Try it's Hyper+Space row: the key that opens the Pilot menu; nil when none does, as after a Scratch pick (no keys
    /// at all; the menu bar icon still opens Pilot, pilot-key-presets' rules), and the row is left out.
    func menuKey(_ engine: Engine) -> String? {
        engine.binds.store.trigger(for: "apps.launcher").flatMap { HomeKeys.caps($0, space: "Space").last }
    }

    #if DEBUG
    /// The renders' seam: Try it's demo done, as after a hold, Hyper+F and Hyper+Space.
    func seedDemoDone() {
        tryIt = Onboarding.TryIt(menuOpens: -1)
        tryIt.held = true
        tryIt.see(menuOpens: 0)
        filesOpened = true
    }
    #endif

    /// Try it's Hyper+F row: the Files key's own key, shown only while it opens Pilot Files; nil otherwise.
    func filesKey(_ engine: Engine) -> String? {
        guard setup.system.picks.picks[.files] == AppRolePicks.pilot || setup.ledger[.filesKey]?.state == .done,
              let trigger = engine.binds.store.trigger(for: "apps.files") else { return nil }
        return HomeKeys.caps(trigger, space: "Space").last
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if OnboardingWindow.shown === self { OnboardingWindow.shown = nil }
        // Welcome closing ends Allow the rest and takes the helper beside Settings with it.
        walk.stop()
        PermissionDragPanel.close(reason: "Welcome closed")
    }

    func finish() {
        OnboardingWindow.finished()
        log.notice("onboarding: finished after \(Int(Date().timeIntervalSince(self.opened))) s")
    }

    private func refresh() {
        guard let engine else { return }
        if step == .tryIt {
            if !tryIt.menuOpened { tryIt.see(menuOpens: PilotMenu.shared.opens) }
            if !filesOpened, filesKey(engine) != nil {
                let shown = Self.filesShown()
                if shown > filesAtStart || NSApp.keyWindow?.title == "Pilot Files" { filesOpened = true }
            }
        }
        guard step == .permissions else { return }
        if accessAsked, settingsOpen != PermissionDragPanel.settingsRunning { settingsOpen.toggle() }
        engine.gate.check()
        if status.accessibility != engine.gate.isTrusted { status.accessibility = engine.gate.isTrusted }
    }

    /// Allow: macOS's prompt and the Accessibility pane, without the floating helper (Access shows Pilot's icon to drag),
    /// and Welcome moved to the screen's left edge, out from under Settings, so the icon can be dragged across.
    func allowAccessibility() {
        log.notice("onboarding: allow accessibility")
        accessAsked = true
        OnboardingWindow.moveAside()
        engine?.gate.request(panel: false)
    }
}
