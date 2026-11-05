import AppKit
import Carbon.HIToolbox
import PilotCore
import SwiftUI

/// First-run onboarding (stories 1, 2, 40, 94, 103 and 104; Onboarding 1.1, variant C, Sven 2026-11-04, Q841-Q843): four
/// screens under one step rail. Hyper picks the key, Access waits for Accessibility alone, Set up runs everything or what
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
            if look.style == .instrument {
                instrument
            } else {
                OnboardingSteps(model: model).styled(.onboarding, look: look).pilotTheme(look: look)
            }
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

/// Onboarding's steps in Toybox, inside its style: they and the window behind them take the style's colours. The same
/// rail, screens and parts as Instrument's (Onboarding 1.1), in Toybox's look.
private struct OnboardingSteps: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine
    @Environment(\.dismissWindow) private var dismiss
    @Bindable var model: OnboardingModel
    @State private var confirming: LayerKeyChange?
    @State private var more = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingRail(step: model.step)
            switch model.step {
            case .welcome: welcome
            case .permissions: access
            case .extras: setUp
            case .tryIt: tryIt
            }
        }
        .padding(24)
        .frame(width: 560)
        // The app window's look (card agent-bo-95422728): the style's, dark or light whatever the Mac's appearance, title
        // bar too.
        .buttonStyle(.pilot)
        .styleLayout()
        // The content's own background, and the window's behind the title bar (a Window scene only).
        .background(ink.background)
        .containerBackground(ink.background, for: .window)
        .background { DarkWindow(dark: ink.style.dark) }
    }

    private func title(_ text: String) -> some View { Text(text).font(ink.display(26)) }

    private var welcome: some View {
        @Bindable var settings = engine.settings
        return VStack(alignment: .leading, spacing: 12) {
            title("Welcome to Pilot")
            Text("Pilot makes this Mac work like Omarchy.").font(ink.ui(15, .medium)).foregroundStyle(ink.text2)
            Text("Pilot runs on one key, called Hyper. Holding it is like pressing a combination of modifier keys at once, so every Hyper shortcut is free of clashes. Pick which key is Hyper.")
                .foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            Card {
                ForEach(Onboarding.hyperChoices) { key in
                    let on = settings.layerKeys.contains(key)
                    Button { LayerKeyConfirm.pick([key], settings, from: .onboarding, asking: $confirming) } label: {
                        CardRow {
                            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(on ? ink.accent : ink.muted).accessibilityHidden(true)
                            TitledText(title: key.label, detail: Onboarding.hyperDetail(key))
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .layerKeyConfirm($confirming, settings: settings, from: .onboarding)
            Button("Continue") { model.go(.permissions) }.keyboardShortcut(.defaultAction).buttonStyle(.pilotPrimary)
        }
    }

    /// Access: Accessibility, the one grant Pilot waits for; the rest are named for later, with no buttons here.
    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Allow Accessibility")
            Text(OnboardingModel.accessAbout).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
            Card {
                CardRow {
                    TitledText(title: "Accessibility", detail: Onboarding.Row.accessibility.detail(model.status))
                    Spacer()
                    if model.status.accessibility {
                        Chip(text: "allowed", color: ink.green)
                    } else {
                        Button("Allow") { model.allowAccessibility() }
                    }
                }
            }
            PanelHeading(text: "Later, from Settings · \(OnboardingModel.later.count)")
            Card {
                ForEach(OnboardingModel.laterGroups, id: \.title) { group in
                    CardRow { TitledText(title: group.title, detail: group.names) }
                }
            }
            HStack {
                FinePrint(text: OnboardingModel.ticksItself)
                Spacer()
                Button("Continue") { model.go(.extras) }.keyboardShortcut(.defaultAction).disabled(!Onboarding.canContinue(model.status))
                    .buttonStyle(.pilotPrimary)
            }
        }
    }

    /// Set up: the fork, Pick by hand, or the run in its place.
    private var setUp: some View {
        let setup = model.setup
        return VStack(alignment: .leading, spacing: 12) {
            switch setup.phase {
            case .fork:
                title("How should Pilot set up?")
                SetupFork(setup: setup)
                HStack {
                    FinePrint(text: setup.asksForMacLogin ? OnboardingModel.passwordNote : OnboardingModel.undoAfter)
                    Spacer()
                    Button("Skip setup") { model.startTryIt() }
                }
            case .pick:
                title("Pick by hand")
                ScrollView { SetupPickList(setup: setup) }.frame(height: OnboardingView.scrollHeight)
                HStack {
                    FinePrint(text: setup.picked.contains(.homebrew) ? OnboardingModel.passwordNote : OnboardingModel.pickNote)
                    Spacer()
                    Button("Back") { setup.phase = .fork }
                    Button("Set up these") { setup.start(Array(setup.picked)) }.keyboardShortcut(.defaultAction)
                        .disabled(setup.picked.isEmpty).buttonStyle(.pilotPrimary)
                }
            case .run:
                title(setup.title)
                ScrollView { SetupRunList(setup: setup) }.frame(maxHeight: OnboardingView.scrollHeight)
                if let problem = setup.problem { FinePrint(text: problem, color: ink.red) }
                HStack {
                    FinePrint(text: OnboardingModel.undoNote)
                    Spacer()
                    Button("Continue") { model.startTryIt() }.keyboardShortcut(.defaultAction).buttonStyle(.pilotPrimary)
                }
            }
        }
        .onAppear { if setup.phase != .run { setup.load() } }
    }

    private var tryIt: some View {
        let key = engine.settings.layerKeys.label
        return VStack(alignment: .leading, spacing: 12) {
            title("Try it")
            Card {
                prompt("Hold \(key)", "your binds appear while you hold it", done: model.tryIt.held)
                if let files = model.filesKey(engine) {
                    prompt("Press \(key) + \(files)", "Pilot Files opens: the key you just set", done: model.filesOpened)
                }
                prompt("Press \(key) + Space", "the Pilot menu", done: model.tryIt.menuOpened)
            }
            PanelHeading(text: "The other permissions")
            Card { CardRow { GrantWalkPanel(walk: model.walk) } }
            Button { more.toggle() } label: {
                Label("More, if you want", systemImage: more ? "chevron.down" : "chevron.right").font(ink.ui(12.5, .medium)).foregroundStyle(ink.muted)
            }
            .buttonStyle(.plain)
            if more { Card { OnboardingMore() } }
            HStack {
                FinePrint(text: "Pilot is in the menu bar")
                Spacer()
                Button("Finish") { model.finish(); dismiss(id: "onboarding"); OnboardingWindow.close() }.keyboardShortcut(.defaultAction).buttonStyle(.pilotPrimary)
            }
        }
    }

    private func prompt(_ title: String, _ detail: String, done: Bool) -> some View {
        CardRow {
            TitledText(title: title, detail: detail)
            Spacer()
            if done { Chip(text: "done", color: ink.green) } else { Chip(text: "waiting", color: ink.muted) }
        }
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

    /// Finish: closes whichever window holds Welcome, the scene's or Run setup again's.
    static func close() { window?.close() }

    /// Welcome to the front; false when it is not open.
    @discardableResult static func bringForward() -> Bool {
        guard let window, window.isVisible || window.isMiniaturized else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// The menu bar's Allow for Accessibility (Sven, 2026-10-28, Q1): Welcome while it is open, else General's permissions.
    static func openPermissions() {
        if !bringForward() { AppWindowController.shared.open(.permissions) }
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
    /// The four screens. The raw values are the saved resume points from 1.0 (`onboarding.step`), kept so a run cut off
    /// mid-way resumes; on screen they read Hyper, Access, Set up, Try it.
    enum Step: String, CaseIterable {
        case welcome, permissions, extras, tryIt

        var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

        var title: String {
            switch self {
            case .welcome: "Hyper"
            case .permissions: "Access"
            case .extras: "Set up"
            case .tryIt: "Try it"
            }
        }
    }

    var step = Step.welcome
    private(set) var status = Onboarding.Status()
    var tryIt = Onboarding.TryIt(menuOpens: 0)
    /// Pilot Files came forward since Try it showed.
    private(set) var filesOpened = false
    let setup: OnboardingSetup
    /// Try it's Allow the rest (T58): nothing read until it starts.
    let walk: GrantWalk
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var opened = Date()
    @ObservationIgnored private weak var engine: Engine?

    static let accessAbout = "The one grant Pilot waits for: it reads the Hyper key and moves windows. System Settings opens beside this window; switch Pilot on there."
    static let passwordNote = "Homebrew asks your Mac's password once, in Terminal."
    /// Says what Undo cannot do (reviewer, T54): it puts back what was there before Set up, over any change since, and
    /// Homebrew keeps what it installed with a helper.
    static let undoNote = "Undo puts back what was there before Set up, even over a change you made since; removing a helper leaves what Homebrew brought with it, such as ffmpeg's libraries. Open a group to undo one line."
    static let pickNote = "Each row says what it gives. Nothing changes until you press Set up these."
    static let undoAfter = "Every change can be undone after."
    static let ticksItself = "This step ticks itself"

    /// Access's "Later, from Settings": the recommended and optional grants by name. The when-used ones stay with the
    /// features that ask for them.
    static let later = Onboarding.Row.rows(.recommended) + Onboarding.Row.rows(.optional)
    static let laterGroups: [(title: String, names: String)] = [Onboarding.Need.recommended, .optional].map { need in
        (need.title, Onboarding.Row.rows(need).map(\.short).joined(separator: " · "))
    }

    /// `setup` and `walk` are the renders' seams; Pilot's are the shared run and the Mac's own grants.
    init(setup: OnboardingSetup = .shared, walk: GrantWalk = GrantWalk()) {
        self.setup = setup
        self.walk = walk
    }

    func start(_ engine: Engine) {
        self.engine = engine
        opened = Date()
        if let resume = OnboardingWindow.takeResume() { step = resume }
        if step == .tryIt { resetTryIt() }
        log.notice("onboarding: shown at \(self.step.rawValue, privacy: .public)")
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A step's button: the step, kept so a relaunch opens there.
    func go(_ next: Step) {
        // Moving on closes the helper beside Settings that Accessibility's Allow shows.
        PermissionDragPanel.close()
        step = next
        OnboardingWindow.reached(next)
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

    /// Try it's Hyper+F row: the Files key's own key, shown only while it opens Pilot Files; nil otherwise.
    func filesKey(_ engine: Engine) -> String? {
        guard setup.system.picks.picks[.files] == AppRolePicks.pilot || setup.ledger[.filesKey]?.state == .done,
              let trigger = engine.binds.store.trigger(for: "apps.files") else { return nil }
        return HomeKeys.caps(trigger, space: "Space").last
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Welcome closing ends Allow the rest and takes the helper beside Settings with it.
        walk.stop()
        PermissionDragPanel.close()
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
        engine.gate.check()
        if status.accessibility != engine.gate.isTrusted { status.accessibility = engine.gate.isTrusted }
    }

    func allowAccessibility() {
        log.notice("onboarding: allow accessibility")
        engine?.gate.request()
    }
}
