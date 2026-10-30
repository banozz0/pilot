import AppKit
import Carbon.HIToolbox
import PilotCore
import SwiftUI

/// First-run onboarding (stories 1, 2, 40, 94, 103 and 104; wireframe zu046xD_ceo; Permissions and Extras, Sven
/// 2026-10-28): Welcome picks the Hyper key, Permissions' rows tick themselves once a second (PilotCore's Onboarding),
/// Extras picks what to download, and Try it ticks on a hold and on Hyper+Space. Opens by itself while Accessibility is
/// missing or a run is unfinished (OnboardingWindow).
struct OnboardingView: View {
    @Environment(Engine.self) private var engine
    @Environment(\.dismissWindow) private var dismiss
    @State private var model: OnboardingModel
    @State private var confirming: LayerKeyChange?

    private let look: Look
    /// Permissions' and Extras' list scrolls inside this height, so the window fits a 13-inch screen.
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
        return InstrumentOnboarding(model: model, confirming: $confirming, finish: { model.finish(); dismiss(id: "onboarding") })
            .styled(.onboarding, look: look)
            .pilotTheme(look: look)
            .background(canvas)
            .containerBackground(canvas, for: .window)
            .background { DarkWindow(dark: tokens.dark) }
    }
}

/// Onboarding's steps in Toybox, inside its style: they and the window behind them take the style's colours.
private struct OnboardingSteps: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine
    @Environment(\.dismissWindow) private var dismiss
    let model: OnboardingModel
    @State private var confirming: LayerKeyChange?
    /// Permissions' folded group, open.
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .welcome: welcome
            case .permissions: permissions
            case .extras: extras
            case .tryIt: tryIt
            }
        }
        .padding(24)
        .frame(width: 520)
        // The app window's look (card agent-bo-95422728): the style's, dark or light whatever the Mac's appearance, title
        // bar too.
        .buttonStyle(.pilot)
        .styleLayout()
        // The content's own background, and the window's behind the title bar (a Window scene only).
        .background(ink.background)
        .containerBackground(ink.background, for: .window)
        .background { DarkWindow(dark: ink.style.dark) }
    }

    private var welcome: some View {
        @Bindable var settings = engine.settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Pilot").font(ink.display(26))
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

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeading(text: "set up pilot · \(OnboardingModel.Step.permissions.counted) · permissions")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Onboarding.Need.allCases, id: \.self) { need in
                        if need == .whenUsed {
                            Button { showAll.toggle() } label: {
                                Label("\(need.title) (\(Onboarding.Row.rows(need).count))", systemImage: showAll ? "chevron.down" : "chevron.right")
                                    .font(ink.ui(12.5, .medium)).foregroundStyle(ink.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        if need != .whenUsed || showAll {
                            if need != .whenUsed { PanelHeading(text: need.title) }
                            Card { ForEach(Onboarding.Row.rows(need), id: \.self) { grant($0) } }
                        }
                    }
                }
            }
            .frame(height: OnboardingView.scrollHeight)
            if let problem = model.problem { FinePrint(text: problem, color: ink.red) }
            HStack {
                FinePrint(text: Onboarding.continueNote)
                Spacer()
                Button("Continue") { model.go(.extras) }.keyboardShortcut(.defaultAction).disabled(!Onboarding.canContinue(model.status))
                    .buttonStyle(.pilotPrimary)
            }
        }
    }

    private func grant(_ row: Onboarding.Row) -> some View {
        CardRow {
            TitledText(title: row.title, detail: row.detail(model.status))
            Spacer()
            if Onboarding.isDone(row, model.status) {
                Chip(text: "done", color: ink.green)
            } else {
                Button(model.button(row)) { model.act(row) }
            }
        }
    }

    private var extras: some View {
        let extras = model.extras
        return VStack(alignment: .leading, spacing: 10) {
            PanelHeading(text: "set up pilot · \(OnboardingModel.Step.extras.counted) · extras, all optional")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Update and Clean first, each with the helpers it runs (Q555); Homebrew's one Terminal run after Clean.
                    ForEach(OnboardingExtras.Feature.allCases, id: \.self) { feature in
                        PanelHeading(text: "\(feature.title) · \(feature.short)")
                        Card {
                            if let line = feature.line {
                                CardRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(line).font(ink.ui(12.5)).foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true)
                                        if let later = extras.later(feature) { FinePrint(text: later, color: ink.warnText) }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            ForEach(feature.items, id: \.self) { item($0) }
                        }
                        if feature == .clean, let command = extras.brewCommand {
                            Card {
                                CardRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        FinePrint(text: OnboardingExtras.terminalNote)
                                        Text(command).font(ink.mono(11)).foregroundStyle(ink.text2).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    PanelHeading(text: "Voice")
                    Card {
                        if let on = extras.speechOnMac {
                            CardRow { TitledText(title: "Dictation model", detail: "\(on.name) is on this Mac"); Spacer(); Chip(text: "done", color: ink.green) }
                        } else {
                            ForEach(OnboardingExtras.speechChoices, id: \.self) { choice in speech(choice) }
                        }
                        item(.voices)
                    }
                    PanelHeading(text: "AI and agents")
                    Card {
                        CardRow {
                            VStack(alignment: .leading, spacing: 8) {
                                TitledText(title: AIProviderPick.title, detail: AIProviderPick.detail)
                                AIProviderPick()
                            }
                            Spacer(minLength: 0)
                        }
                        item(.command)
                    }
                    PanelHeading(text: "Images")
                    Card { item(.upscaler) }
                    PanelHeading(text: "Pilot")
                    Card {
                        CardRow {
                            TitledText(title: "Extensions", detail: OnboardingExtras.extensionsDetail)
                            Spacer()
                            Button("Browse…") { OnboardingExtras.browseExtensions() }
                        }
                        item(.recommendApps)
                        item(.launchAtLogin)
                    }
                }
            }
            .frame(height: OnboardingView.scrollHeight)
            .onAppear { extras.load() }
            HStack {
                FinePrint(text: extras.footNote)
                Spacer()
                Button("Skip all") { model.startTryIt(extras: false) }
                Button("Continue") { model.startTryIt() }.keyboardShortcut(.defaultAction).buttonStyle(.pilotPrimary)
            }
        }
    }

    /// A dictation model to pick, or Skip.
    private func speech(_ choice: SpeechChoice?) -> some View {
        let on = model.extras.speech == choice
        return Button { model.extras.speech = choice } label: {
            CardRow {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? ink.accent : ink.muted).accessibilityHidden(true)
                TitledText(title: OnboardingExtras.speechTitle(choice), detail: OnboardingExtras.speechDetail(choice))
                Spacer()
                if choice == OnboardingExtras.recommendedSpeech { Chip(text: "recommended", color: ink.accent) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// An extra: its tick, or that it is on this Mac already.
    private func item(_ item: OnboardingExtras.Item) -> some View {
        CardRow {
            TitledText(title: item.title, detail: item.detail)
            Spacer()
            if model.extras.onMac.contains(item) {
                Chip(text: "on this Mac", color: ink.green)
            } else {
                if let chip = item.chip { Chip(text: chip, color: ink.accent) }
                Toggle(item.title, isOn: model.extras.binding(item))
                    .toggleStyle(.pilotSwitch)
            }
        }
    }

    private var tryIt: some View {
        let key = engine.settings.layerKeys.label
        return VStack(alignment: .leading, spacing: 10) {
            PanelHeading(text: "set up pilot · \(OnboardingModel.Step.tryIt.counted)")
            Card {
                prompt("Hold \(key) for a moment", "your binds appear while you hold it", done: model.tryIt.held)
                prompt("Now press \(key) + Space", "opens the Pilot menu: apps, files, windows, install", done: model.tryIt.menuOpened)
            }
            let lines = model.extras.progress
            if !lines.isEmpty {
                PanelHeading(text: "In the background")
                Card {
                    ForEach(lines, id: \.title) { line in
                        CardRow { Text(line.title); Spacer(); Text(line.state).font(ink.mono(11.5)).foregroundStyle(ink.muted) }
                    }
                }
            }
            HStack {
                FinePrint(text: "Pilot is in the menu bar, showing the workspace number")
                Spacer()
                Button("Finish") { model.finish(); dismiss(id: "onboarding") }.keyboardShortcut(.defaultAction).buttonStyle(.pilotPrimary)
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
/// instead of the app window. A run not finished opens it again at the next launch, at the step it reached: Full Disk
/// Access's and Screen Recording's Quit & Reopen restart Pilot mid-Permissions.
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

    static func closed() { window = nil }

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

/// What onboarding sees, read once a second while Permissions shows, and what each row's button does. Nothing runs
/// until its button is pressed: the old tools through the On/off switch, the shortcuts through Shortcut conflicts'
/// backup, the extras through Continue.
@Observable @MainActor
final class OnboardingModel {
    enum Step: String, CaseIterable {
        case welcome, permissions, extras, tryIt

        var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
        /// "step 2 of 4", Toybox's heading.
        var counted: String { "step \(number) of \(Self.allCases.count)" }
    }

    var step = Step.welcome
    private(set) var status = Onboarding.Status()
    var tryIt = Onboarding.TryIt(menuOpens: 0)
    let extras = OnboardingExtras()
    private(set) var problem: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var opened = Date()
    @ObservationIgnored private weak var engine: Engine?
    /// One off-main probe at a time: a slow pgrep never piles up.
    @ObservationIgnored private var probing = false

    func start(_ engine: Engine) {
        self.engine = engine
        opened = Date()
        if let resume = OnboardingWindow.takeResume() { step = resume }
        if step == .tryIt { tryIt = Onboarding.TryIt(menuOpens: PilotMenu.shared.opens) }
        log.notice("onboarding: shown at \(self.step.rawValue, privacy: .public)")
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A step's button: the step, kept so a relaunch (Full Disk Access's or Screen Recording's Quit & Reopen) opens there.
    func go(_ next: Step) {
        // Moving on closes the helper beside Settings: a grant may show only after Pilot reopens.
        PermissionDragPanel.close()
        step = next
        OnboardingWindow.reached(next)
    }

    /// Extras' Continue: the picks start, then Try it, which counts only what happens from here: a hold, and the menu
    /// opening after this moment.
    func startTryIt(extras run: Bool = true) {
        if run { extras.start(self) }
        tryIt = Onboarding.TryIt(menuOpens: PilotMenu.shared.opens)
        go(.tryIt)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Welcome closing takes the helper beside Settings with it.
        PermissionDragPanel.close()
    }

    func finish() {
        OnboardingWindow.finished()
        log.notice("onboarding: finished after \(Int(Date().timeIntervalSince(self.opened))) s")
    }

    private func refresh() {
        guard let engine else { return }
        if step == .tryIt && !tryIt.menuOpened { tryIt.see(menuOpens: PilotMenu.shared.opens) }
        guard step == .permissions else { return }
        engine.gate.check()
        var s = status
        s.accessibility = engine.gate.isTrusted
        s.fullDiskAccess = FileIndex.hasFullDiskAccess()   // the index's first walk waits for the menu to open
        MicrophoneGrant.shared.refresh()
        s.microphone = MicrophoneGrant.shared.isGranted
        s.clashes = ShortcutConflicts.shared.clashes(binds: engine.binds.store.binds).count
        if s != status { status = s }
        guard !probing else { return }
        probing = true
        Task {
            async let answer = Task.detached { Self.mayControlSystemEvents() }.value
            let grants = await OnboardingGrants.shared.read(), events = await answer
            probing = false
            var s = status
            s.systemEvents = Onboarding.systemEvents(answer: events, last: s.systemEvents)
            grants?.apply(to: &s)
            if s != status { status = s }
        }
    }

    func button(_ row: Onboarding.Row) -> String { row == .conflicts ? "Turn off" : "Allow" }

    func act(_ row: Onboarding.Row) {
        guard let engine else { return }
        problem = nil
        log.notice("onboarding: \(row.title, privacy: .public)")
        // Another row's Allow moves on: the helper beside Settings goes, and its own row's Allow shows it again.
        PermissionDragPanel.close()
        switch row {
        case .accessibility: engine.gate.request()
        case .systemEvents: SystemModule.systemEvents("count processes")   // macOS asks once; the row ticks after
        case .fullDiskAccess:
            SystemModule.openFullDiskAccess()
            PermissionDragPanel.show(.fullDiskAccess)
        case .microphone: Task { await MicrophoneGrant.shared.ask() }   // macOS asks once; after that, the Privacy pane
        case .conflicts:
            do { try ShortcutConflicts.shared.switchOff(binds: engine.binds.store.binds) } catch { problem = error.localizedDescription }
        case .screenRecording, .inputMonitoring, .notifications, .bluetooth, .location, .calendars: OnboardingGrants.shared.ask(row, engine: engine)
        }
    }

    /// Recommend apps (C5), the same switch as Defaults' and Install's.
    func recommend(_ on: Bool) {
        Recommendations.shared.show = on
        log.notice("onboarding: recommend apps \(on ? "on" : "off", privacy: .public)")
    }

    /// The same setting as Settings › General, so the two never disagree.
    func launchAtLogin(_ on: Bool) {
        Engine.shared?.settings.launchAtLogin = on
        if let failure = LoginItem.shared.problem { problem = "Launch at login: \(failure)" }
        log.notice("onboarding: launch at login \(LoginItem.shared.status == .enabled ? "on" : "off", privacy: .public)")
    }

    /// Asks TCC without a prompt; Onboarding.systemEvents reads the answer.
    nonisolated private static func mayControlSystemEvents() -> Int32 {
        var target = AEAddressDesc()
        let id = "com.apple.systemevents"
        _ = id.withCString { AECreateDesc(typeApplicationBundleID, $0, id.utf8.count, &target) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }
}
