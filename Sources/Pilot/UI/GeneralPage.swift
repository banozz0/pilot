import AppKit
import IOKit.hid
import PilotCore
import SwiftUI

/// The Pilot page (General until simplify-pages T4): Pilot's own page as an app, the way an About and General pane open
/// in Raycast and Ice (Sven 2026-10-10: "it should be like the Pilot general app"). Its front (simplify-pages T8): who Pilot
/// is, its mark, name, version and build, whether this build is current with Check for updates, and Support; the
/// permission when it is missing (Home links here); then, back from its More (pages round 4, Sven's Q106), the Hyper key
/// with where it sits and its options, Startup, what runs, other apps' notifications, every permission Pilot asks for
/// with its fix, Pilot's data (its folder and the pilot command) and About. What the overlay shows lives on Keys ›
/// Overlay, export and import on Keys › More › Export and import, the helpers on Install › Helpers (page map, Sven
/// 2026-10-17), AI on its own page, the quick-notes folder on Notes; the on/off switch on Home and in the dropdown.
struct GeneralPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    @State private var confirming: LayerKeyChange?
    /// Read when the page shows and when Pilot comes back to the front, not on every redraw (it lists a folder).
    @State private var fullDisk: Bool?
    /// Whether the page is wide enough for two columns (`paired(width:)`), followed as the window resizes. It starts
    /// narrow: one column never runs past the page, so its width is the page's; pairs that started first ran off the page
    /// and measured themselves wide enough to stay (Instrument at 1000, C3's renders).
    @State private var wide = false
    /// The acknowledgement whose licence the sheet shows.
    @State private var licence: Acknowledgement?
    /// About's Acknowledgements, Resources listed once per page shown, not on every redraw.
    @State private var acknowledgements = Acknowledgement.list(in: Acknowledgement.directory)
    /// About's Acknowledgements are unfolded (Q455); closed whenever the page is built.
    @State private var acknowledgementsOpen: Bool
    /// The newest of Pilot's crash reports from the last week (SH12), read when About shows: Reveal crash reports waits on one.
    @State private var crash: CrashReports.Report?
    /// Data › Uninstall…'s sheet is up (Q423).
    @State private var uninstalling = false
    private let updates = PilotUpdates.shared

    /// What Pilot is, in one line under its name.
    static let tagline = "Your Mac from the keyboard: the Hyper key, tiling, workspaces and one menu for everything."
    /// Support (Sven 2026-10-10): Pilot's GitHub Sponsors page.
    static let supportURL = URL(string: "https://github.com/sponsors/banozz0")!
    /// Accessibility's ⓘ, on Needs you and on Permissions.
    static let accessibilityInfo = "Keys and windows: the Hyper key, every bind and the tiler run on it, so Pilot asks it first."

    /// The front's short blocks sit in pairs from this width up (simplify-pages T8); narrower they stack (Moody: at 760
    /// they ran off the right edge).
    static func paired(width: CGFloat) -> Bool { width >= 820 }

    /// `acknowledgementsOpen` is for the renders; the app always opens the page with the list closed.
    init(acknowledgementsOpen: Bool = false) {
        _acknowledgementsOpen = State(initialValue: acknowledgementsOpen)
    }

    var body: some View {
        let granted = engine.gate.isTrusted
        KitLanding {
            KitPage {
                header
                if !granted { needsYou }
                // Its rows run too wide for a column (Hold Hyper's).
                hyperKeys(focused: granted).id(AppSection.hyperKey)
                if wide {
                    // Two columns, each block at its own height, so none stretches to its neighbour's foot.
                    columns { startup; status.id(AppSection.status) } right: { notifications.id(AppSection.notifications) }
                } else {
                    startup; status.id(AppSection.status); notifications.id(AppSection.notifications)
                }
                permissions(granted).id(AppSection.permissions)
                data.id(AppSection.data)
                about.id(AppSection.about)
            }
            .onGeometryChange(for: Bool.self) { Self.paired(width: $0.size.width) } action: { wide = $0 }
        }
        .layerKeyConfirm($confirming, settings: engine.settings, from: .settings)
        .task { updates.countOnce() }
    }

    /// Two columns of blocks the page's gap apart, each top-aligned at its own height; from `paired(width:)`, under
    /// InstrumentPair's 880, so the front fits the window's first size in Instrument too (simplify-pages T8).
    private func columns(@ViewBuilder left: () -> some View, @ViewBuilder right: () -> some View) -> some View {
        HStack(alignment: .top, spacing: ink.isInstrument ? style.density.gap : 20) {
            VStack(alignment: .leading, spacing: 0, content: left).frame(maxWidth: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 0, content: right).frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: Pilot

    /// Pilot itself: its mark, name, version and build, what it is, then its update state, Check for updates and Support.
    private var header: some View {
        Tile {
            HStack(alignment: .center, spacing: 18) {
                mark
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Pilot").styleText(\.pageTitle).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                        Text(versionLine).font(ink.mono(11.5)).foregroundStyle(ink.muted).lineLimit(1).textSelection(.enabled)
                    }
                    Text(Self.tagline).styleText(\.body).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        // A debug build's count; Sparkle's window says what it found.
                        if updates.counts { updateChip }
                        Button("Check for updates") { updates.check() }.buttonStyle(.pilot)
                            .disabled(!updates.canCheck || updates.state == .checking)
                            .help(updates.checkHelp)
                        Button { NSWorkspace.shared.open(Self.supportURL) } label: {
                            Label("Support", systemImage: "heart").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.pilot).help("Back Pilot on GitHub Sponsors")
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .padding(.top, headerGap)
    }

    /// The header's gap under the page's title: KitBlock's per style.
    private var headerGap: CGFloat {
        switch style.kind {
        case .toybox: Toy.blockGap
        case .instrument: style.density.padding
        }
    }

    /// Pilot's mark in the style's own drawing: Toybox's keycap, Instrument's four squares.
    @ViewBuilder private var mark: some View {
        switch style.kind {
        case .toybox: PilotMark(size: 64)
        case .instrument:
            InstrumentMark(size: 34).foregroundStyle(style.color(\.text2)).frame(width: 60, height: 60).styleSurface(\.card)
        }
    }

    /// "Version 0.1.0 · build 1 · 1a2b3c4", or "development build" for a bare binary.
    private var versionLine: String {
        [Self.version, updates.shortCommit].compactMap(\.self).joined(separator: " · ")
    }

    private var updateChip: some View {
        let color: Color? = switch updates.state {
        case .current: ink.green
        case .behind: ink.yellow
        case .failed: ink.red
        case .unknown, .checking: nil
        }
        return Chip(text: updates.label, color: color)
            .help("Commits on main in \(updates.source ?? "the checkout") since this build; git-sync keeps main current")
    }

    private var needsYou: some View {
        KitBlock(title: "Needs you", symbol: "exclamationmark.triangle", focused: true) {
            BlockRow(first: true) {
                Image(systemName: "xmark.circle").foregroundStyle(ink.red).accessibilityHidden(true)
                TitledText(title: "Accessibility", detail: "Keys and windows: Pilot does nothing without it").padding(.vertical, 4)
                InfoMark(text: Self.accessibilityInfo)
                Spacer()
                Button("Grant") { engine.gate.request() }.buttonStyle(.pilotPrimary)
            }
        }
    }

    // MARK: Groups

    /// The Hyper key: where it sits (simplify-pages T8's front block, with its Change to More until pages round 4), then
    /// a switch per layer key, a quick tap, the bind hints and the hold overlay.
    private func hyperKeys(focused: Bool) -> some View {
        @Bindable var settings = engine.settings
        return KitBlock(title: "Hyper key", symbol: "command", focused: focused) {
            // Small: where the key sits, not a keyboard to read (Sven: the card was mostly empty under the picker).
            LayerKeyPicture(keys: settings.layerKeys).frame(maxWidth: LayerKeyPicture.compactWidth).frame(maxWidth: .infinity).padding(.vertical, 10)
            BlockRow {
                Text("Hyper keys")
                InfoMark(text: "Each key that is on is Hyper by itself, so Caps Lock+Space and right Command+Space both open the menu. A Control, Option or Command that is on is no longer itself; the other side still is, so only one side can be on. With left Command on, Cmd+C, Cmd+V and Cmd+Tab need right Command. Caps Lock becomes Hyper while Pilot runs and goes back to Caps Lock when it quits.")
                Spacer()
            }
            // One switch per key; the last one on stays on, so Hyper always has a key.
            ForEach(LayerKey.allCases) { key in
                BlockRow {
                    Toggle(key.label, isOn: LayerKeyConfirm.ticked(key, settings, from: .settings, asking: $confirming))
                        .toggleStyle(.pilotSwitchRow(info: key.note)).disabled(LayerKey.isLocked(key, in: settings.layerKeys))
                }
            }
            BlockRow {
                Toggle("A quick tap sends Escape", isOn: $settings.quickTapEscape)
                    .toggleStyle(.pilotSwitchRow(info: "Tap a layer key by itself and it sends Escape; held with another key, it is Hyper."))
            }
            BlockRow {
                Text("Show an app's bind after you open it")
                InfoMark(text: "After a click opens an app, or a menu pick runs something, that has a bind. At most once an hour per bind.")
                Spacer()
                Toggle("Show the bind when I use the mouse or the menu", isOn: $settings.bindNudges).toggleStyle(.pilotSwitch)
            }
            BlockRow {
                Text("Hold Hyper to see your binds")
                InfoMark(text: "Hold the Hyper key this long to see that layer's binds; Shift or Ctrl turns the page.")
                Spacer()
                // Off: the stepper dims, as the delay waits for the switch.
                overlayDelay.disabled(!settings.overlayEnabled)
                Button("Edit what shows") { AppWindowController.shared.open(AppPlace(.overlay)) }.buttonStyle(.pilot)
                Toggle("Show the overlay when I hold Hyper", isOn: $settings.overlayEnabled).toggleStyle(.pilotSwitch)
            }
        }
    }

    /// How long Hyper is held before the overlay shows (Sven, 2026-10-19), a tenth a step.
    private var overlayDelay: some View {
        @Bindable var settings = engine.settings
        let seconds = settings.overlayDelay.formatted(.number.precision(.fractionLength(1)))
        return Stepper(value: $settings.overlayDelay, in: HoldOverlay.delayRange, step: 0.1) {
            Text("\(seconds) s").font(ink.mono(11.5)).foregroundStyle(ink.text2)
        }
        .accessibilityLabel("Hold before the overlay shows").accessibilityValue("\(seconds) seconds")
    }

    /// The front's Startup: Launch at login and Run setup again.
    private var startup: some View {
        @Bindable var settings = engine.settings
        return KitBlock(title: "Startup", symbol: "power") {
            BlockRow(first: true) {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.pilotSwitchRow(info: "Pilot opens when you log in, so Hyper and your binds work from the start."))
            }
            if let problem = LoginItem.shared.problem {
                BlockRow { FinePrint(text: "Launch at login: \(problem)", color: ink.red) }
            } else if LoginItem.shared.status == .requiresApproval {
                BlockRow { Text("Waiting for your OK in System Settings › General › Login Items.").font(ink.ui(12)).foregroundStyle(ink.muted) }
            }
            // Q847: onboarding again from its first screen; nothing set up is undone, a run in progress resumes.
            BlockRow {
                Text("Setup")
                InfoMark(text: "Opens Welcome from the start: the Hyper key, Accessibility, then Set up for what is not on this Mac yet. Nothing already set up is undone; a run still going picks up where it is.")
                Spacer()
                Button("Run setup again") { OnboardingWindow.again(engine: engine) }.buttonStyle(.pilot)
            }
        }
    }

    /// Permissions: each grant Pilot asks for with its fix. Ungranted, Accessibility's one home is Needs you on the
    /// front (simplify-pages T2).
    private func permissions(_ granted: Bool) -> some View {
        KitBlock(title: "Permissions", symbol: "lock.shield") {
            if granted {
                BlockRow(first: true) {
                    Text("Accessibility")
                    InfoMark(text: Self.accessibilityInfo)
                    Spacer()
                    Chip(text: "granted", color: ink.green)
                }
            }
            BlockRow(first: !granted) {
                Text("Full Disk Access")
                InfoMark(text: "The file index: it lets the menu find files anywhere. macOS has no prompt for it: switch Pilot on in the pane.")
                Spacer()
                if fullDisk == true { Chip(text: "granted", color: ink.green) }
                else if fullDisk == nil { Chip(text: "…") }
                else { Button("Open Settings") { SystemModule.openFullDiskAccess() }.buttonStyle(.pilot) }
            }
            .task { fullDisk = FileIndex.hasFullDiskAccess() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                fullDisk = FileIndex.hasFullDiskAccess()
            }
            MicrophoneRow()
            MorePermissionRows()
        }
    }

    /// Status: whether Pilot's parts are alive.
    private var status: some View {
        KitBlock(title: "Status", symbol: "waveform.path.ecg") {
            BlockRow(first: true) {
                Text("Keyboard")
                InfoMark(text: "The part of Pilot that hears the Hyper key and runs your binds.")
                Spacer()
                engine.bindsArmed ? Chip(text: "running", color: ink.green) : Chip(text: "stopped", color: ink.muted)
            }
            BlockRow {
                Text("Password field lock")
                InfoMark(text: "A password field pauses Hyper; Pilot never works around it. On: the app macOS names as holding it.")
                Spacer()
                switch engine.secureInput.holder {
                case .app(let name)?: Chip(text: name, color: ink.yellow)
                case .quit?: Chip(text: "stuck", color: ink.red)
                case .unknown?: Chip(text: "on", color: ink.yellow)
                case nil: Chip(text: "off")
                }
            }
            BlockRow {
                Text(engine.observers.tiler.tilerName)
                InfoMark(text: "The tiler that places your windows and runs the workspaces.")
                Spacer()
                engine.observers.tiler.isAnswering ? Chip(text: "running", color: ink.green) : Chip(text: "not running", color: ink.red)
            }
        }
    }

    /// Pilot's folder and the pilot command's link; export and import of the binds is Binds' (page map, Sven 2026-10-17).
    /// The Developer switch (Q715) sits with the command's link: both are for people who live in a terminal.
    private var data: some View {
        @Bindable var settings = engine.settings
        return KitBlock(title: "Data", symbol: "folder") {
            BlockRow(first: true) {
                TitledText(title: "Pilot's folder", detail: "Binds, settings, history and snapshots, in Application Support").padding(.vertical, 4)
                InfoMark(text: "Opens the folder in Finder: what Pilot keeps of yours lives there, binds.json among it.")
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(PilotFolder.support) }.buttonStyle(.pilot)
            }
            CommandLineRow()
            BlockRow {
                Toggle("Developer pages", isOn: $settings.developer).toggleStyle(.pilotSwitchRow(info: DeveloperPages.help))
            }
            BlockRow {
                TitledText(title: "Uninstall", detail: "Speech models, caches, your data or Pilot itself, to the Trash").padding(.vertical, 4)
                InfoMark(text: "Lists everything Pilot put on this Mac with its size; nothing of another app's. Ticked items go to the Trash, where Finder can put them back.")
                Spacer()
                Button("Uninstall…") { uninstalling = true }.buttonStyle(.pilot)
            }
            TerminalPackRow()
        }
        .sheet(isPresented: $uninstalling) { UninstallSheet().pilotSheet().floating() }
    }

    // MARK: Notifications

    /// Other apps' notifications as Pilot's cards (spec notifications.html): off by default, nothing runs until it's on.
    private var notifications: some View {
        @Bindable var settings = NotificationSettings.shared
        return KitBlock(title: "Notifications", symbol: "bell") {
            BlockRow(first: true) {
                Toggle("Show other apps' notifications in Pilot", isOn: $settings.enabled)
                    .toggleStyle(.pilotSwitchRow(info: "Reads each notification macOS shows, through Accessibility, and draws a Pilot card in the bottom right, with a bell and a list of what arrived. Their words stay in memory, are never saved or sent, and macOS keeps its own copy. Do Not Disturb still silences them. It relies on how macOS builds Notification Center, so a macOS update can break it."))
            }
            BlockRow {
                Toggle("Hide macOS's own banner", isOn: $settings.hideMacBanners)
                    .toggleStyle(.pilotSwitchRow(info: "Moves Notification Center's banners off screen while a Pilot card shows. Nothing is lost: the notification is still in macOS's Notification Center. A notification Pilot can't fully handle, like a reply, keeps macOS's banner."))
                    .disabled(!settings.enabled)
            }
        }
    }

    // MARK: About

    /// Send feedback, the Acknowledgements (SH10: every third-party piece Pilot bundles or downloads, each opening its
    /// licence's full text in a sheet) and the licence.
    private var about: some View {
        KitBlock(title: "About", symbol: "info.circle") {
            // Send feedback (card agent-bo-95423195): the browser on a new issue, prefilled.
            BlockRow(first: true) {
                TitledText(title: "Send feedback", detail: "A GitHub issue with this Mac's facts filled in").padding(.vertical, 4)
                InfoMark(text: "Opens a new GitHub issue in your browser with this Mac's facts filled in; nothing is sent until you submit it.")
                Spacer()
                ForEach(Feedback.Kind.allCases, id: \.self) { kind in
                    Button(kind.label) { SendFeedback.open(kind, layerKeys: engine.settings.layerKeys) }.buttonStyle(.pilot)
                }
                // SH12 (Sven Q315): the report stays on this Mac; Finder shows it for the person to attach.
                if let crash {
                    Button("Reveal crash reports") { NSWorkspace.shared.activateFileViewerSelecting([crash.url]) }.buttonStyle(.pilot)
                        .help("\(crash.process) left a crash report on \(crash.date.formatted(date: .abbreviated, time: .shortened)). Attaching \(crash.name) to a bug report is your choice; it may hold paths from this Mac.")
                }
            }
            .task { crash = await Task.detached { CrashReports.newest() }.value }
            // Q455: one row, closed on every visit, that unfolds the list in place.
            BlockRow {
                Button { withAnimation(Kit.change) { acknowledgementsOpen.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.muted)
                            .rotationEffect(.degrees(acknowledgementsOpen ? 90 : 0))
                        TitledText(title: "Acknowledgements (\(acknowledgements.count))",
                                   detail: "What Pilot bundles or downloads, each under its own licence").padding(.vertical, 4)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(acknowledgementsOpen ? "Expanded" : "Collapsed")
                InfoMark(text: "Open the list, then click a row for its licence's full text.")
                Spacer()
            }
            if acknowledgementsOpen { ForEach(acknowledgements) { entry in
                BlockRow {
                    Button { licence = entry } label: {
                        HStack(spacing: 10) {
                            Text(entry.name)
                            Spacer()
                            Text("\(entry.what) · \(entry.licence)").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.muted)
                                .opacity(entry.files.isEmpty ? 0 : 1)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.files.isEmpty)
                }
            } }
            FinePrint(text: "Licence: MIT, free and open source. Updates arrive through Check for updates.").padding(.vertical, 8)
        }
        .sheet(item: $licence) { LicenceSheet(entry: $0).pilotSheet().floating() }
    }

    /// "0.1.0" from the bundle, "dev" for a bare binary: Instrument's sidebar foot.
    static let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// "0.1.0 · build 1" from the bundle; a bare binary has none.
    static let version: String = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        return "\(short) · build \(info?["CFBundleVersion"] as? String ?? "?")"
    }()
}


/// General › Data's Terminal row (T76): Ghostty's pack on this Mac or not, with the model rows' Download, progress and
/// Cancel, or Remove.
struct TerminalPackRow: View {
    @State private var installed = false
    @State private var failure: String?

    var body: some View {
        let downloads = ExtrasDownloads.shared
        let state = downloads.terminal.flatMap { $0 == .ready ? nil : $0 } ?? (installed ? .ready : .absent)
        BlockRow {
            TitledText(title: "Terminal", detail: failure.map { "Not removed: \($0)" }
                ?? (installed ? "On this Mac; Hyper+T opens it" : "Ghostty for Hyper+T, downloaded on its first press")).padding(.vertical, 4)
            InfoMark(text: "Remove ends its shell and deletes it; its memory comes back when Pilot quits.")
            Spacer()
            ModelStateControls(state: state, name: "the terminal", size: "\(TerminalPack.pin.megabytes) MB",
                               download: downloads.fetchTerminal, cancel: downloads.cancelTerminal) {
                Button("Remove") {
                    do { try TerminalDrop.shared.removePack(); failure = nil } catch { failure = error.localizedDescription }
                    installed = TerminalPack.isInstalled()
                }.buttonStyle(.pilot)
            }
        }
        .task { installed = TerminalPack.isInstalled() }
        .onChange(of: downloads.terminal) { _, now in if now == .ready || now == nil { installed = TerminalPack.isInstalled() } }
        ModelFailureRow(state: state)
    }
}

/// The permissions past Accessibility, Full Disk Access and the microphone, so General lists every one Pilot asks for as
/// macOS's Privacy & Security does (page map, Sven 2026-10-17): Screen Recording, Input Monitoring and System Events
/// automation. Each state is read without a prompt; its button asks, or opens Privacy & Security once macOS will not ask
/// again.
struct MorePermissionRows: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    /// Read when the rows show and when Pilot comes back to the front, as Full Disk Access is.
    @State private var screenRecording: Grant?
    @State private var inputMonitoring: Grant?
    /// System Events' last answer, kept while it sits idle (`systemEvents(answer:last:)`); nil before the first.
    @State private var systemEvents: Grant?

    /// A row's right side: granted, its ask, Privacy & Security, or not read.
    enum Grant: Equatable { case granted, ask, openSettings, notChecked }

    /// Screen Recording as Menu bar › Other apps and the Window shelf read it (ADR 0012): not read at all while Show exact
    /// menu bar items is off and the shelf has not read it (Window pictures Off, or no Stage workspace shown yet); else
    /// their checks, and the pane they open.
    static func screenRecording(exactItems: Bool, shelf: Bool = false, lacks: Bool) -> Grant {
        guard exactItems || shelf else { return .notChecked }
        return lacks ? .openSettings : .granted
    }

    /// Input Monitoring as Binds › Mouse reads it (IOHIDCheckAccess, no prompt).
    static func inputMonitoring(_ access: IOHIDAccessType) -> Grant {
        switch access {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .openSettings
        default: .ask
        }
    }

    /// AEDeterminePermissionToAutomateTarget's answer for System Events, as onboarding reads it (Onboarding.systemEvents):
    /// 0 allowed; -1743 refused, so macOS will not ask again; -600 says System Events is idle, whatever the grant, so the
    /// last answer stands; anything else (-1744) is not asked yet.
    static func systemEvents(answer: Int32, last: Grant?) -> Grant {
        switch answer {
        case 0: .granted
        case -1743: .openSettings
        case -600: last ?? .ask
        default: .ask
        }
    }

    static let screenRecordingInfo = "Menu bar › Other apps › Show exact menu bar items draws other apps' items with it, and "
        + "\(AppPlace(.windowShelf).path)'s pictures (Stills by default) show your shelved windows. Pilot reads it only for those, once a Stage workspace shows."
    static let inputMonitoringInfo = "\(AppPlace(.mouse).path) needs it to tell a media key a mouse sends from your keyboard's."
    static let systemEventsInfo = "Sleep, restart, shut down and log out go through System Events, the one app Pilot automates. "
        + "While it is idle macOS may not say, so Allow can show though it is allowed."

    static let automationPane = "com.apple.preference.security?Privacy_Automation"

    var body: some View {
        row("Screen Recording", info: Self.screenRecordingInfo, screenRecording,
            ask: { PermissionDragPanel.openScreenRecording() }, settings: { PermissionDragPanel.openScreenRecording() })
        row("Input Monitoring", info: Self.inputMonitoringInfo, inputMonitoring,
            ask: requestInputMonitoring, settings: requestInputMonitoring)
        row("Automation: System Events", info: Self.systemEventsInfo, systemEvents,
            ask: {
                // Onboarding's ask: macOS prompts once; the row reads the answer once System Events has run.
                SystemModule.systemEvents("count processes")
                Task { try? await Task.sleep(for: .seconds(2)); await probeSystemEvents() }
            },
            settings: { SystemModule.pane(Self.automationPane) })
            .task { read() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in read() }
    }

    private func row(_ title: String, info: String, _ grant: Grant?, ask: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        BlockRow {
            Text(title)
            InfoMark(text: info)
            Spacer()
            switch grant {
            case .granted?: Chip(text: "granted", color: ink.green)
            case .ask?: Button("Allow") { ask() }.buttonStyle(.pilot)
            case .openSettings?: Button("Open Settings") { settings() }.buttonStyle(.pilot)
            case .notChecked?: Chip(text: "not checked")
            case nil: Chip(text: "…")
            }
        }
    }

    /// MouseButtons' ask: macOS's prompt the first time, Privacy & Security once it was refused.
    private func requestInputMonitoring() {
        engine.mouseButtons.requestAccess()
        inputMonitoring = Self.inputMonitoring(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
    }

    private func read() {
        // Each lacksPermission is false while its switch is off, before any Screen Recording read.
        let shelf = engine.shelf.pictures
        screenRecording = Self.screenRecording(exactItems: BarItemsStore.shared.settings.exactMenuItems, shelf: shelf.mode != .off && shelf.checked,
                                               lacks: engine.barSources.readings.menuApps.pictures.lacksPermission || shelf.lacksPermission)
        inputMonitoring = Self.inputMonitoring(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
        Task { await probeSystemEvents() }
    }

    /// The TCC read runs off the main thread, as onboarding's does.
    private func probeSystemEvents() async {
        let answer = await Task.detached { ControlStatus.mayControlSystemEvents() }.value
        systemEvents = Self.systemEvents(answer: answer, last: systemEvents)
    }
}

/// Where the layer keys sit on a Mac keyboard, each lit in the accent with its sign.
struct LayerKeyPicture: View {
    @Environment(\.ink) private var ink
    let keys: [LayerKey]

    /// Each row's keys in units: the lit key's row and index by layer key.
    private static let rows: [[CGFloat]] = [
        [1.5] + Array(repeating: 1, count: 12) + [1.5],
        [1.75] + Array(repeating: 1, count: 11) + [2.25],
        [2.25] + Array(repeating: 1, count: 10) + [2.75],
        // fn, Control, Option, Command, Space, Command, Option, Control (an external keyboard's), the arrows.
        [1, 1, 1, 1.25, 5, 1.25, 1, 1, 2.5],
    ]

    /// The layer key at a row and index, if one is lit there.
    private func lit(_ row: Int, _ index: Int) -> LayerKey? {
        keys.first { key in
            switch key {
            case .capsLock: (row, index) == (1, 0)
            case .leftControl: (row, index) == (3, 1)
            case .leftOption: (row, index) == (3, 2)
            case .leftCommand: (row, index) == (3, 3)
            case .rightCommand: (row, index) == (3, 5)
            case .rightOption: (row, index) == (3, 6)
            case .rightControl: (row, index) == (3, 7)
            }
        }
    }

    /// General's width for it: the key's place, small (Sven 2026-10-10).
    static let compactWidth: CGFloat = 300

    /// Every row is 15 units wide; a gap is this share of a unit; full size is 27 pt keys.
    private static let width: CGFloat = 15, gapShare: CGFloat = 4 / 27, fullUnit: CGFloat = 27
    /// A row's width in units, its gaps included.
    private static let rowUnits = width + (width - 1) * gapShare

    var body: some View {
        // The caption sits under the keys, never over them: four keys' names wrap to two lines (P68).
        VStack(spacing: 8) {
            keyboard
            Text("\(keys.label) is Hyper while Pilot runs").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement().accessibilityLabel("\(keys.label) is the Hyper key")
    }

    private var keyboard: some View {
        // The keys scale to the column they get, never past full size (Moody: fixed keys ran off a 760 window).
        GeometryReader { frame in
            let unit = frame.size.width / Self.rowUnits, gap = unit * Self.gapShare
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Self.rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(Self.rows[r].indices, id: \.self) { i in
                            let key = lit(r, i), on = key != nil
                            let cap = RoundedRectangle(cornerRadius: ink.radius(4), style: .continuous)
                            cap.fill(on ? ink.accent : ink.keyFill)
                                .overlay {
                                    // A style's caps carry its key edge: Toybox's outline (its white caps vanish on its white
                                    // card without one), Instrument's hairline ring (its dark caps on its dark card).
                                    let depth = ink.style.depth.key
                                    if depth.outline > 0 { cap.strokeBorder(ink.outline, lineWidth: depth.outline) }
                                    else if let ring = depth.ring { cap.strokeBorder(Color(ring), lineWidth: 1) }
                                    if let key { Text(key.symbol).font(ink.ui(13 * unit / Self.fullUnit, .bold)).foregroundStyle(ink.onAccent) }
                                }
                                .frame(width: Self.rows[r][i] * unit + (Self.rows[r][i] - 1) * gap, height: unit)
                        }
                    }
                }
            }
        }
        .aspectRatio(Self.rowUnits / (4 + 3 * Self.gapShare), contentMode: .fit)
        // Never past full-size keys.
        .frame(maxWidth: Self.rowUnits * Self.fullUnit)
    }
}

/// The pilot command (ADR 0013): link it into ~/.local/bin, and say when that folder is not on the shell's PATH.
struct CommandLineRow: View {
    @Environment(\.ink) private var ink
    private let link = CommandLineLink.shared

    var body: some View {
        BlockRow {
            TitledText(title: "pilot command", detail: "Read and change Pilot from a terminal or an AI").padding(.vertical, 4)
            InfoMark(text: "Links the pilot command into ~/.local/bin, so a terminal or an AI agent can read and change Pilot's settings.")
            Spacer()
            switch link.state {
            case .linked: Chip(text: "in ~/.local/bin", color: ink.green)
            case .notLinked: Button("Link to ~/.local/bin") { link.makeLink() }.buttonStyle(.pilot)
            case .taken: Chip(text: "~/.local/bin/pilot is taken", color: ink.yellow)
            case .noCommand: Chip(text: "only in Pilot.app")
            }
        }
        .task {
            link.refresh()
            // Once a launch: the shell's PATH rarely changes while Pilot runs, and only these two states show the hint.
            if link.onPath == nil, link.state == .linked || link.state == .notLinked { await link.readPath() }
        }
        if let problem = link.problem {
            BlockRow { FinePrint(text: problem, color: ink.red) }
        } else if link.state == .taken {
            BlockRow { FinePrint(text: "Another program is ~/.local/bin/pilot; Pilot leaves it. Its own copy: \(link.command.path(percentEncoded: false))") }
        } else if link.onPath == false, link.state != .noCommand {
            BlockRow { FinePrint(text: #"~/.local/bin is not on your shell's PATH: add export PATH="$HOME/.local/bin:$PATH" to ~/.zshrc"#, color: ink.yellow) }
        }
    }
}
