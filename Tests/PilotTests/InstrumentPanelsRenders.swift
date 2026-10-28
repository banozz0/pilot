#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The HUDs and the notes panel in Instrument (card agent-bo-95423181), dark and light, through
/// HUD.makePanel as Pilot shows them: a tip alone, with digits and its button, the rescue prompt with its switch off and
/// on, an extension's alert with buttons and with OK alone; the notes panel
/// editing, on Scratch, the list with the keyboard (a match and none), asking before the Trash and at its smallest size; the clipboard
/// panel's list, a link, a colour, picks, a search, each prompt and two empty tabs; the overlay's pages (grouped, short, three
/// columns, empty, ranked); onboarding's four steps. Opt-in like the other
/// renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter InstrumentPanelsRenders`
extension SharedLook {
@MainActor
@Suite("Instrument panels renders")
struct InstrumentPanelsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The HUDs, Quick AI and notes panels render in Instrument dark and light, every state",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID)
        defer { (look.style, look.themeID) = saved }
        look.style = .instrument
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try NotesPanelRenders.seed(folder)
        let hero = try #require(try store.load().first { $0.title == "Ship the notes panel" })

        for dark in [true, false] {
            // Instrument is dark or light as its theme is: Nightwatch dark, Paper light.
            look.themeID = dark ? "nightwatch" : "paper"
            let side = dark ? "dark" : "light"

            let hud = out.appendingPathComponent("hud-instrument-\(side)")
            try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
            try Self.render(TipView(text: "Workspace 2 saved: 3 windows"), .hud, "1-tip", in: hud)
            try Self.render(TipView(text: "Converting 2 of 5 to JPG…", action: HUD.TipAction(title: "Cancel") {}), .hud, "2-tip-progress", in: hud)
            try Self.render(TipView(text: "3 files converted to JPG", action: HUD.TipAction(title: "Reveal") {}), .hud, "3-tip-done", in: hud)
            try Self.render(ExtensionAlertView(alert: ExtensionTimerTests.alert), .hud, "6-alert", in: hud)
            try Self.render(ExtensionAlertView(alert: ExtensionTimerTests.plainAlert), .hud, "7-alert-ok", in: hud)

            let notes = out.appendingPathComponent("notes-instrument-\(side)")
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            for state in ["1-editing", "2-scratch", "3-list", "4-list-none", "5-trash", "6-smallest"] {
                let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
                model.reload()
                model.open(state == "2-scratch" ? NoteStore.scratch : hero.id)
                switch state {
                case "3-list":
                    model.focusList()
                    model.queryField = "pan"
                    model.stepList(1)
                    try #require(model.selectedNote?.title == "Spanish: ser vs estar")
                case "4-list-none": model.focusList(); model.queryField = "zzq"
                case "5-trash": model.askTrash()
                default: break
                }
                let size = state == "6-smallest" ? NotesPanel.minSize : NotesPanel.defaultSize
                try Self.render(NotesPanelView(model: model).frame(width: size.width, height: size.height), .notes, state, in: notes)
            }

            let clips = out.appendingPathComponent("clipboard-instrument-\(side)")
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            let clipStore = try InstrumentPanelsTests.clipStore()
            func clipboard(_ name: String, snippets: [Snippet] = [], _ change: (PanelModel) throws -> Void = { _ in }) throws {
                let model = PanelModel(store: clipStore, snippets: { snippets })
                try change(model)
                try Self.render(ClipboardPanelView(model: model, returnCopies: false), .clipboard, name, in: clips)
            }
            try clipboard("1-list")
            try clipboard("2-link") { $0.move(1) }
            try clipboard("3-colour") { $0.move(-9) }
            try clipboard("4-picks") { $0.move(1); $0.extend(1); $0.extend(1) }
            try clipboard("5-search") { $0.query = "pilot" }
            try clipboard("6-tag") { $0.move(2); $0.open(.tag); $0.type("o") }
            try clipboard("7-actions") { $0.move(1); $0.open(.actions) }
            try clipboard("8-edit") { $0.move(2); $0.open(.edit) }
            try clipboard("9-rename") { $0.move(2); $0.open(.rename) }
            try clipboard("10-delete-tag") { model in
                model.tab = try #require(model.tabs.first { if case .tag = $0 { true } else { false } })
                model.askDeleteTag()
            }
            try clipboard("11-empty-images") { $0.tab = .kind(.image) }
            try clipboard("12-empty-search") { $0.query = "zzq" }
            for (name, list, change) in Snippet.renderStates {
                try clipboard(name, snippets: list) { $0.tab = .kind(.snippet); change($0) }
            }

            let overlay = out.appendingPathComponent("overlay-instrument-\(side)")
            try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Self.render(OverlayView(title: "Hyper", rows: InstrumentPanelsTests.overlayRows), .overlay, "1-hyper", in: overlay)
            let shift = [("windows", "H", "Move left"), ("windows", "L", "Move right"), ("workspaces", "1", "Move to workspace 1"),
                         ("workspaces", "2", "Move to workspace 2")].map { BindsPage.Row(id: $0.2, key: $0.1, label: $0.2, module: $0.0, custom: false) }
            try Self.render(OverlayView(title: "Hyper+Shift", rows: shift), .overlay, "2-shift", in: overlay)
            let many = (0..<20).map { BindsPage.Row(id: "\($0)", key: String(UnicodeScalar(UInt8(65 + $0))), label: "Action \($0 + 1)",
                                                   module: ["apps", "windows", "system", "media"][$0 / 5], custom: false) }
            try Self.render(OverlayView(title: "Hyper+Ctrl", rows: many), .overlay, "3-three-columns", in: overlay)
            try Self.render(OverlayView(title: "Hyper+Alt", rows: []), .overlay, "4-empty", in: overlay)
            let ranked = [InstrumentPanelsTests.overlayRows[5], InstrumentPanelsTests.overlayRows[0], InstrumentPanelsTests.overlayRows[3]]
            try Self.render(OverlayView(title: "Hyper", rows: ranked), .overlay, "5-most-used", in: overlay)

            let onboarding = out.appendingPathComponent("onboarding-instrument-\(side)")
            try FileManager.default.createDirectory(at: onboarding, withIntermediateDirectories: true)
            let engine = Engine()
            for (i, step) in [OnboardingModel.Step.welcome, .permissions, .extras, .tryIt].enumerated() {
                let model = OnboardingModel()
                model.step = step
                // The view itself, not OnboardingView, so nothing starts reading the Mac's grants.
                try Self.renderWindow(InstrumentOnboarding(model: model, confirming: .constant(nil), finish: {}).environment(engine)
                    .styled(.onboarding).pilotTheme(), name: "\(i + 1)-\(step)", in: onboarding)
            }
        }
    }

    @Test("The top bar, its popovers, the Pilot dropdown, tooltip and edit mode in Instrument dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func topBar() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        (look.style, look.glass) = (.instrument, false)
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))

        // ToyboxTopBarRenders' fakes: the mockup's workspaces, Stats' readings, a focus block at 18:42, Wi-Fi, an 82 % battery.
        StatsRenders.seed(SystemSampler.shared)
        let clock = HomeRenders.Clock(), start = clock.now
        let timer = ExtensionTimer(now: { clock.now })
        timer.startFocus()
        clock.now = start.addingTimeInterval(25 * 60 - (18 * 60 + 42))
        timer.tick()
        defer { timer.stop() }
        let observers = EngineObservers()
        let windows = try AeroWindow.parse(HomeRenders.windows)
        let monitors = try JSONDecoder().decode([AeroMonitorWorkspace].self, from: Data(#"[{"monitor-id": 1, "monitor-name": "Studio", "workspace": "2"}, {"monitor-id": 2, "monitor-name": "Portrait", "workspace": "4"}]"#.utf8))
        var occupied = OccupiedWorkspace.list(windows)
        if !occupied.contains(where: { $0.name == "4" }) { occupied.append(OccupiedWorkspace(name: "4", apps: ["WhatsApp"])) }
        observers.tiler.seed(focused: "2", occupied: occupied, windows: windows, perMonitor: monitors)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first { observers.seed(focusedApp: finder) }
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { SystemStats.Battery(percent: 82, charging: false, minutesLeft: 300) },
                                   readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                                   watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        let sources = BarSources(readings: readings, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: timer, pilotTitle: { "2" })
        let sides = ToyboxTopBarRenders.sides()
        var held: Set<BarKind> = []
        readings.hold(Set(sides.values.joined().flatMap(\.kinds)), replacing: &held)
        defer { readings.hold([], replacing: &held) }
        let store = BarItemsStore.shared
        let engine = Engine()
        typealias On = DropdownQuickSwitchesTests.Fake
        let switches = QuickSwitches(hyper: On(true), tiling: On(true), topBar: On(false), keepAwake: On(true), clipboard: On(true))

        for dark in [true, false] {
            look.themeID = dark ? "nightwatch" : "paper"
            let side = dark ? "dark" : "light"
            let dir = out.appendingPathComponent("topbar-instrument-\(side)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeRender(TopBarStrip(sides: sides) { TopBarSlotView(slot: $0, screen: "Studio", sources: sources, store: store) }
                .styled(.topBar, look: look).pilotTheme(look: look).frame(width: 1440, height: 30),
                            to: dir.appendingPathComponent("1-bar-strip.png"), wait: 0.8)
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let views: [(String, AnyView)] = [
                ("2-tooltip", AnyView(BarTooltipView(text: "Workspace 2: Telegram, Zen"))),
                ("3-workspaces", AnyView(BarPopover(kinds: [.workspaces], sources: sources, store: store))),
                ("4-focused-app", AnyView(BarPopover(kinds: [.focusedApp], sources: sources, store: store))),
                ("5-sound", AnyView(BarPopover(kinds: [.volume], sources: sources, store: store))),
                ("6-wifi", AnyView(BarPopover(kinds: [.wifi], sources: sources, store: store))),
                ("7-clock", AnyView(BarPopover(kinds: [.clock], sources: sources, store: store))),
                ("8-timer", AnyView(BarPopover(kinds: [.timer], sources: sources, store: store))),
                ("9-readings", AnyView(BarPopover(kinds: [.cpu, .memory], sources: sources, store: store))),
                ("10-dropdown", AnyView(PilotDropdown(switches: switches, option: false).environment(engine))),
                ("11-dropdown-option", AnyView(PilotDropdown(switches: switches, option: true).environment(engine))),
                ("13-chip", AnyView(BarDragChip(kind: .battery, slot: sides[.right]?[4], screen: "Studio", sources: sources, store: store))),
            ]
            for (name, view) in views {
                // The bar's own parts are .topBar; its popovers and the dropdown hang in BarPanel's .barPopovers.
                let surface: StyleSurface = ["2-tooltip", "13-chip"].contains(name) ? .topBar : .barPopovers
                try writeRender(view.styled(surface, look: look).pilotTheme(look: look).padding(24).background(Color(tokens.colors.canvas)),
                                to: dir.appendingPathComponent("\(name).png"), wait: 0.5)
            }
            // Binds' bind editor, in the Binds page's style: an action's, a new bind on a free key, a plain combo's.
            let binds = out.appendingPathComponent("bind-editor-instrument-\(side)")
            try FileManager.default.createDirectory(at: binds, withIntermediateDirectories: true)
            for (name, editor) in [("1-action", BindEditor(action: "apps.terminal", actions: engine.bindActions)),
                                   ("2-new", BindEditor(action: nil, actions: engine.bindActions, startKey: Key("j"))),
                                   ("3-plain", BindEditor(action: nil, actions: engine.bindActions, startKey: Key("v", .alt, hyper: false)))] {
                try writeRender(editor.environment(engine).styled(.page(.binds), look: look).pilotTheme(look: look),
                                to: binds.appendingPathComponent("\(name).png"), wait: 0.8)
            }
        }
    }

    /// A window's content (onboarding) at its own size on the style's canvas, at Retina scale.
    static func renderWindow(_ view: some View, name: String, in dir: URL) throws {
        let look = Look.shared
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        let canvas = Color(tokens.colors.canvas)
        let host = NSHostingView(rootView: view.background(canvas))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: tokens.dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(host, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The panel as HUD.makePanel builds it for `surface`, its content drawn at Retina scale with the clear margins kept.
    static func render(_ view: some View, _ surface: StyleSurface, _ name: String, in dir: URL) throws {
        let panel = HUD.makePanel(view, surface: surface)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
}
#endif
