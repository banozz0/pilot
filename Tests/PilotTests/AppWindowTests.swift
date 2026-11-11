import CoreAudio
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The app window on a real NSWindow (card agent-bo-95422748). The Dock and quit are seams here: the tests never change
/// the test runner's activation policy or quit it.
@MainActor
@Suite("App window frame", .serialized)
struct AppWindowFrameTests {
    private final class Spy {
        var dock: [DockIcon] = []
        var quits = 0
        /// The test's other windows (Welcome) the Dock rule counts beside the controller's own.
        var windows: [NSWindow] = []
    }

    private func controller() -> (AppWindowController, Spy) {
        testApp()
        let spy = Spy(), c = AppWindowController()
        c.autosaveName = nil
        c.applyDockIcon = { spy.dock.append($0) }
        let counts = c.countsWindow
        c.countsWindow = { [weak c] in counts($0) && ($0 === c?.window || spy.windows.contains($0)) }
        c.quit = { spy.quits += 1 }
        return (c, spy)
    }

    private func press(_ key: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        return window.performKeyEquivalent(with: event)
    }

    @Test("Every old page name opens where it went: its page, its part as the tab picked, conflicts as the sheet (card agent-bo-95422892, C3)")
    func oldPagesLand() {
        let names = ["home", "binds", "plainCombos", "conflicts", "workspaces", "snapshots", "tiling", "topBar", "webApps", "installCatalogue",
                     "configs", "defaultApps", "clipboard", "pomodoro", "setup", "general", "look", "permissions", "exportImport", "onOff", "about",
                     "pilot", "stats", "defaults", "otherApps", "abilities", "reports"]
        for name in names {
            let model = AppWindowModel(defaults: UserDefaults(suiteName: testSuite())!)
            let place = AppPlace.linked(URL(string: "pilot://open?page=\(name)")!)
            #expect(place != nil, "\(name)")
            guard let place else { continue }
            model.go(place)
            #expect(model.page == place.page, "\(name)")
            if place.section == .conflicts { #expect(model.showsConflicts && model.section(of: .binds) == nil, "\(name)") }
            // Plain combos stays, Binds opens on that sublayer; a place on a More tab opens that tab with its block asked for
            // (simplify-pages T7); every other part is the tab picked or the place scrolled to.
            else if let more = place.section?.onMore { #expect(model.section(of: place.page) == more && model.blockFocus == place.section, "\(name)") }
            // A place on a front opens the front, its block asked for (snapshots: Workspaces' front since round 3).
            else if place.section?.onFront == true { #expect(model.section(of: place.page) == nil && model.blockFocus == place.section, "\(name)") }
            else { #expect(model.section(of: place.page) == place.section ?? place.page.firstSection, "\(name)") }
            #expect(place.page.tabs.isEmpty || place.page.tabs.contains { $0.value == model.section(of: place.page) } || place.section?.isMerged == true, "\(name)")
        }
        // A page saved before the cut reopens where it went.
        let defaults = UserDefaults(suiteName: testSuite())!
        defaults.set("history", forKey: "appWindow.page")
        #expect(AppWindowModel(defaults: defaults).page == .stats)
        defaults.set("pilot", forKey: "appWindow.page")
        #expect(AppWindowModel(defaults: defaults).page == .general)
        // Going back to a page with its own content first shows that content again.
        let model = AppWindowModel(defaults: defaults)
        model.go(AppPlace(.reports))
        #expect(model.section(of: .upkeep) == .reports)
        model.go(AppPlace(.upkeep))
        #expect(model.section(of: .upkeep) == nil)
        // Update & Clean's Open report picks the run Reports opens on; going anywhere else forgets it.
        model.reportPick = "run-1"
        model.go(AppPlace(.upkeep))
        #expect(model.reportPick == nil)
    }

    @Test("The window's own keys answer before the main menu's: Cmd+, opens Pilot (not the menu's Open Pilot…), Ctrl+Tab the area's next page, Cmd+2 Keys")
    func windowKeys() throws {
        testApp()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        model.go(AppPlace(.workspaces))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(Engine())))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            let handled = window.performKeyEquivalent(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return handled
        }
        #expect(key("\t", 48, .control), "Ctrl+Tab reaches the window")
        #expect(model.page == .tiling)
        #expect(key(",", 43, .command), "the window takes Cmd+, itself")
        #expect(model.page == .general)
        #expect(key("2", 19, .command))
        #expect(model.page == .binds)
    }

    @Test("Look's Window layout swaps the shell: the rail, Toolbar tabs' strip of areas, and back")
    func layoutSwapsShell() throws {
        testApp()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        model.go(AppPlace(.menuBar))
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: LookTests.defaults())
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model, look: look).environment(Engine())))
        defer { window.close() }
        // SwiftUI builds its accessibility tree only for an assistive client; this says one is here.
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        func labels() throws -> [String] {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return FillPagesTests.labels(in: try #require(window.contentView))
        }
        look.windowShape = .rail
        let rail = try labels()
        #expect(!rail.contains("Areas") && !rail.contains(WindowShape.tabs.title) && rail.contains("Desktop"), "\(rail)")
        look.windowShape = .tabs
        let tabs = try labels()
        #expect(tabs.contains("Areas") && tabs.contains(WindowShape.tabs.title), "\(tabs)")
        look.windowShape = .rail
        #expect(!(try labels()).contains(WindowShape.tabs.title))
    }

    @Test("The model hears the window stop showing: Cmd+W leaves it off screen (card agent-bo-95422788)", .pilotFocus)
    func onScreen() {
        let (c, _) = controller()
        c.present(NSView())
        c.model.onScreen = true   // as the occlusion notice would say on a real screen
        c.window?.performClose(nil)
        #expect(!c.model.onScreen)
        // A window the tiler parked for a hidden workspace keeps a sliver on screen and still counts as off it.
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(AppWindowController.onScreen(visible: true, unoccluded: true, frame: NSRect(x: 100, y: 100, width: 920, height: 640), screens: [screen]))
        #expect(!AppWindowController.onScreen(visible: true, unoccluded: true, frame: NSRect(x: 1919, y: -639, width: 920, height: 640), screens: [screen]))
        #expect(!AppWindowController.onScreen(visible: true, unoccluded: false, frame: NSRect(x: 100, y: 100, width: 920, height: 640), screens: [screen]))
    }

    @Test("The pages' repeating reads run only while the window is on screen and key (Sven, 2026-10-17)", .pilotFocus)
    func live() throws {
        let (c, _) = controller()
        c.present(NSView())
        let window = try #require(c.window)
        c.model.onScreen = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(c.model.live)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(c.model.onScreen && !c.model.live, "shown behind another app: nothing repeats")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        window.performClose(nil)
        #expect(!c.model.isKey && !c.model.live)
    }

    @Test("On a locked screen an open makes no window and waits for the unlock (card agent-bo-95422757)")
    func lockedScreen() {
        let (c, spy) = controller()
        c.screenLocked = { true }
        c.open(.conflicts)
        #expect(c.window == nil && spy.dock.isEmpty)
        #expect(c.waitsForUnlock)
        // The unlock notification shows the window without asking the session again, which may still read locked
        // (Moody's REJECT http://localhost:8228/p/ZIMZfj0ZVog), so the open never waits for an unlock that already came.
        c.screenUnlocked()
        #expect(!c.waitsForUnlock)
    }

    @Test("Opening gives Pilot its Dock icon before the window shows; Cmd+W closes it, the icon goes, Pilot keeps running", .pilotFocus)
    func cmdW() throws {
        let (c, spy) = controller()
        c.present(NSView())
        let window = try #require(c.window)
        #expect(spy.dock == [.dock])
        #expect(window.isVisible)
        #expect(press("w", .command, in: window))
        #expect(!window.isVisible)
        #expect(spy.dock == [.dock, .menuBarOnly])
        #expect(spy.quits == 0)
        // Opening again makes the window anew and brings the icon back.
        c.present(NSView())
        let again = try #require(c.window)
        #expect(again !== window && again.isVisible)
        #expect(spy.dock == [.dock, .menuBarOnly, .dock])
        again.close()
    }

    @Test("A closed window goes with its content: a closed window kept every page's SwiftUI tree in memory (2026-10-10, idle RAM)", .pilotFocus)
    func closeReleases() throws {
        let (c, _) = controller()
        weak var content: NSView?
        weak var window: NSWindow?
        autoreleasepool {
            let view = NSView()
            content = view
            c.present(view)
            window = c.window
            window?.performClose(nil)
        }
        #expect(c.window == nil)
        for _ in 0..<3 { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        #expect(window == nil, "the closed window is gone")
        #expect(content == nil, "and its content with it")
    }

    @Test("With another window open (Welcome) the icon stays; it goes when that one closes last", .pilotFocus)
    func lastWindowCloses() throws {
        let (c, spy) = controller()
        c.present(NSView())
        let window = try #require(c.window)
        let welcome = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        welcome.isReleasedWhenClosed = false
        spy.windows = [welcome]
        welcome.orderFront(nil)
        #expect(press("w", .command, in: window))
        #expect(spy.dock == [.dock, .dock])
        welcome.close()
        #expect(spy.dock == [.dock, .dock, .menuBarOnly])
    }

    @Test("Cmd+Q quits Pilot from the window", .pilotFocus)
    func cmdQ() throws {
        let (c, spy) = controller()
        c.present(NSView())
        let window = try #require(c.window)
        #expect(press("q", .command, in: window))
        #expect(spy.quits == 1)
        #expect(window.isVisible)
        window.close()
    }

    @Test("Other Cmd keys pass on to the page: Cmd+Shift+W, Cmd+F", .pilotFocus)
    func otherKeys() throws {
        let (c, spy) = controller()
        c.present(NSView())
        let window = try #require(c.window)
        #expect(!press("w", [.command, .shift], in: window))
        #expect(!press("f", .command, in: window))
        #expect(window.isVisible && spy.quits == 0)
        window.close()
    }

    @Test("The first open lands on Home, later opens on the page shown last; a page that no longer exists falls back to Home")
    func startPage() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(AppWindowModel(defaults: defaults).page == .home)
        AppWindowModel(defaults: defaults).page = .extensions
        #expect(AppWindowModel(defaults: defaults).page == .extensions)
        defaults.set("pomodoro", forKey: "appWindow.page")
        #expect(AppWindowModel(defaults: defaults).page == .extensions, "Pomodoro's page, gone with it, reopens on Extensions")
        defaults.set("gone", forKey: "appWindow.page")
        #expect(AppWindowModel(defaults: defaults).page == .home)
    }

    @Test("The window opens at 1000 × 660, shrinks to 760 × 520, dark, titled Pilot with the title hidden")
    func frame() {
        let w = AppWindowController.makeWindow(content: NSView())
        #expect(w.frame.size == AppWindowController.size)
        #expect(w.minSize == AppWindowController.minSize)
        #expect(w.appearance?.name == .darkAqua)
        #expect(w.title == "Pilot" && w.titleVisibility == .hidden)
        #expect(w.styleMask.contains(.fullSizeContentView) && w.styleMask.contains(.closable))
    }

    @Test("The workspace editor popup takes three quarters of the window, at least 680 wide and as tall as its parts need, keeping scrim round it (card agent-bo-95422980)")
    func workspacePopupSize() {
        // Mockup E's own window: three quarters of each side.
        #expect(WorkspacePopup.size(in: CGSize(width: 990, height: 940), ideal: 620) == CGSize(width: 742.5, height: 705))
        #expect(WorkspacePopup.size(in: CGSize(width: 1440, height: 900), ideal: 640) == CGSize(width: 1080, height: 675))
        // The window as it opens: taller than three quarters for the parts, 20 pt of scrim kept above and below.
        #expect(WorkspacePopup.size(in: AppWindowController.size, ideal: 680) == CGSize(width: 750, height: 620))
        // At its least the window keeps 40 pt of scrim across, and the editor scrolls.
        #expect(WorkspacePopup.size(in: AppWindowController.minSize, ideal: 680) == CGSize(width: 680, height: 480))
    }
}

#if DEBUG   // the renders seed sample state through DEBUG-only hooks
extension SharedLook {
/// Offscreen renders of every page, for the side-by-side with the approved mockups. Opt-in, and only with the home
/// directory moved (CFFIXED_USER_HOME) so the engine reads and writes nothing of Sven's:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter PilotTests`
@MainActor
@Suite("App window renders")
struct AppWindowRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Each page renders in the window frame", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderEveryPage() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        // The Tiling page imports ~/.aerospace.toml once from the moved home; an empty one stands in for Sven's.
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        // Setup draws the fake's devices (card agent-bo-95422800): no render reads the Mac's sound devices.
        let setupLook = Look(inputSources: SetupKeepAwakeTests.FakeSources())
        SetupDevices.make = { SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: SetupWiFiTests.FakeWiFi(), displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()), look: setupLook) }
        let engine = Engine()
        engine.observers.tiler.seed(focused: "2", occupied: [
            OccupiedWorkspace(name: "1", apps: ["Ghostty", "Ghostex"]), OccupiedWorkspace(name: "2", apps: ["Zen"]),
            OccupiedWorkspace(name: "3", apps: ["Obsidian"]), OccupiedWorkspace(name: "5", apps: ["Telegram", "Vesktop"]),
            OccupiedWorkspace(name: "9", apps: ["Spotify"]),
        ])
        engine.seedPresses([(Key("return"), "Open terminal"), (Key("2"), "Go to workspace 2"), (Key("return"), "Open terminal"),
                            (Key("space"), "Pilot menu"), (Key("2"), "Go to workspace 2"), (Key("return"), "Open terminal")])
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        // The window's frame view, so the traffic lights are in the picture.
        let frame = try #require(window.contentView?.superview)
        // Every page draws on the window's cards (card agent-bo-95422728): Theme.raised in the page area, right of the
        // sidebar. A grouped Form draws its own grey (21222d) instead, so a page still on one has none.
        let raised = try #require(NSColor(Theme.raised).usingColorSpace(.sRGB))
        let want = [raised.redComponent, raised.greenComponent, raised.blueComponent].map { Int(($0 * 255).rounded()) }
        // Every page and every part of a merged one (card agent-bo-95422892), in the default style, Instrument.
        var withoutCards: [String] = []
        let places = AppPage.allCases.flatMap { page in page.tabs.isEmpty ? [AppPlace(page)] : page.tabs.map { AppPlace(page, $0.value) } }
        for (i, place) in places.enumerated() {
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            let name = place.section.map { "\(place.page.rawValue)-\($0.rawValue)" } ?? place.page.rawValue
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent(String(format: "%02d-%@.png", i, name)))
            let fromX = 207 * 2, enough = 2000
            var cards = Self.count(want, in: rep, fromX: fromX)
            // A first block taller than the window (Binds' named board, Look's theme previews) puts the
            // cards below the fold: look again at the page's foot.
            if cards < enough, let page = MenuScrollTests.scrollViews(in: frame).max(by: { $0.frame.width < $1.frame.width }),
               let document = page.documentView {
                let top = document.isFlipped ? 0 : document.bounds.maxY
                document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
                frame.layoutSubtreeIfNeeded()
                cards = Self.count(want, in: try #require(snapshot(frame, scale: 2)), fromX: fromX)
                document.scroll(NSPoint(x: 0, y: top))
            }
            // Instrument draws these as plain lists, empty on the fakes (Activity's processes, the catalogue, instructions,
            // extensions): no card to find. Configs and its Agents part read this Mac's files off the main thread, which
            // never hands back while this test holds it: ConfigsListTests draws their cards from a home of its own.
            let lists: Set = ["activity", "activity-reports", "install-catalogue", "configs", "configs-agents", "extensions"]
            if cards < enough && !lists.contains(name) { withoutCards.append(name) }
        }
        // The Binds page searched (card agent-bo-95422785): each hit under its own layer's heading.
        model.go(AppPlace(.binds))
        model.query = "tile"
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        frame.layoutSubtreeIfNeeded()
        try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("binds-search.png"))
        model.query = ""
        window.close()
        // Onboarding's four steps, in its own window as PilotApp opens it, and the window's three sheets.
        for (i, step) in [OnboardingModel.Step.welcome, .permissions, .extras, .tryIt].enumerated() {
            let model = OnboardingModel()
            model.step = step
            try Self.render(OnboardingView(model: model).environment(engine), title: "Welcome to Pilot",
                            to: dir.appendingPathComponent("onboarding-\(i + 1)-\(step).png"))
        }
        try Self.render(NewWebAppForm(), title: "", to: dir.appendingPathComponent("sheet-new-web-app.png"))
        // Two fixed readings 2 s apart (cards agent-bo-95422788 and agent-bo-95422830); PILOT_LIVE=1 SystemSamplerTests reads
        // the real ones.
        func sample(_ t: TimeInterval, cpu busy: UInt64, down: UInt64) -> SystemStats.Raw {
            SystemStats.Raw(time: t, cpu: .init(user: busy, system: 0, idle: UInt64(t * 500) - busy + 1000, nice: 0),
                            memory: .init(total: 24 << 30, pageSize: 16384, active: 700_000, inactive: 300_000, speculative: 20_000,
                                          wired: 200_000, compressed: 50_000, purgeable: 10_000, external: 120_000, pressure: .normal,
                                          swapUsed: 300 << 20, swapTotal: 1 << 30),
                            network: .init(received: down, sent: down / 20),
                            battery: nil, thermal: .nominal, uptime: 307_000 + t, gpu: 0.18)
        }
        var a = sample(0, cpu: 0, down: 0), b = sample(2, cpu: 150, down: 2_400_000)
        a.cores = Array(repeating: .init(user: 0, system: 0, idle: 100, nice: 0), count: 10)
        b.cores = (0..<10).map { .init(user: UInt64($0 * 9), system: 0, idle: 300 - UInt64($0 * 9), nice: 0) }
        b.efficiencyCores = 6
        a.diskIO = .init(read: 0, written: 0); b.diskIO = .init(read: 68_000_000, written: 3_800_000)
        a.slow.disk = .init(available: 54_000_000_000, total: 494_000_000_000)
        b.slow = a.slow
        b.slow.localIP = "192.168.0.240"
        // The longest values (card agent-bo-95422838 REJECT): never over their labels.
        b.slow.wifi = .init(channel: 149, band: "5 GHz", signal: -52, noise: -92, rate: 1201, standard: "802.11ax")
        b.slow.interface = .init(name: "en0", hardwareAddress: "d0:11:e5:ea:56:0e", dns: ["192.168.0.1", "1.1.1.1"])
        b.slow.bluetooth = [.init(name: "AirPods Pro", level: "L 90 % · R 85 % · case 40 %"), .init(name: "AirPods Pro", level: "L 70 % · R 75 %")]
        b.sensors = .init(temperatures: ["Tp01": 59.6, "Tp05": 66.2, "Te05": 54.1, "Tg0j": 52.3, "Tg0k": 56.8],
                          fans: [.init(actual: 1000, minimum: 1000, maximum: 4900)], power: 11.9)
        let ps = KillProcess.parse("1398 89.7 239776 Finder\n612 49.3 113280 WindowServer\n68138 35.2 163680 gxserver\n"
                                       + "24299 33.3 2496448 claude\n78597 12.7 632816 Google Chrome Helper (Renderer)\n1735 2.5 72272 Stats")
        let rows = SystemStats.rows(SystemStats.values(previous: a, now: b), now: b, publicIP: "203.0.113.7")
        // This Mac in the menu bar (card agent-bo-95422833): the widgets as text and as graphs, combined, and an item's
        // popover, on the fixed readings above; the choices live on the Menu bar page now.
        let menuDefaults = try #require(UserDefaults(suiteName: "pilot.renders.menubar"))
        menuDefaults.removePersistentDomain(forName: "pilot.renders.menubar")
        let menuSettings = BarItemsStore(defaults: menuDefaults) { MenuBarStatusItemsTests.svensStats }
        b.battery = .init(percent: 81, charging: false, minutesLeft: nil)
        b.slow.bluetooth = [.init(name: "AirPods Pro", level: "72 %")]
        b.sensors = .init(temperatures: ["Tp01": 52], fans: [], power: nil)
        let history = (0..<30).map { i in
            SystemStats.Values(cpu: 0.2 + 0.15 * sin(Double(i) / 3), ram: 0.7, gpu: 0.1, down: Double(i % 7) * 300_000, up: 20_000,
                               cores: nil, diskRead: nil, diskWrite: nil, heat: 48 + 6 * sin(Double(i) / 4))
        }
        // Every bar item in each of its styles (card agent-bo-95422911): the macOS menu bar's template picture on a light and
        // a dark bar, and the top bar's SwiftUI, from the same parts, on the fixed readings above.
        var inputs = BarInputs()
        inputs.pilotTitle = "2"; inputs.workspaces = ["1", "2", "4"]; inputs.focusedWorkspace = "2"; inputs.firstApp = ["2": "Zen"]
        inputs.focusedApp = "Finder"; inputs.latest = b; inputs.values = history.last; inputs.history = history; inputs.battery = b.battery
        inputs.bluetooth = b.slow.bluetooth; inputs.keepAwake = true; inputs.keepAwakeLeft = 3600; inputs.volume = 0.5; inputs.muted = false
        inputs.output = "Speakers"; inputs.keyboardLayout = "British – PC"; inputs.wifiOn = true; inputs.wifiSignal = -55
        inputs.timerCountdown = "18:42"; inputs.timerLeft = 0.75; inputs.timerTitle = "Focus"
        var catalogue = BarSettings.defaults
        let rowsOf = BarKind.allCases.filter { $0 != .otherApps && $0 != .group }.flatMap { kind in kind.styles.map { (kind, $0) } }
        let parts = rowsOf.map { kind, style -> (String, [BarPart]) in
            catalogue.set(kind, style: style)
            return ("\(kind.title) · \(style.title)", BarParts.parts(catalogue.entry(kind), inputs, clock: .time24, zone: "America/New_York") ?? [])
        }
        try Self.render(VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    Text(row.0).frame(width: 220, alignment: .leading).foregroundStyle(Theme.text2)
                    ForEach([Color(white: 0.92), Color(white: 0.16)], id: \.self) { bar in
                        Group {
                            // As macOS colours a template for the bar: black on a light one, white on a dark one.
                            if let image = StatusItemImage.image([row.1]) {
                                Image(nsImage: image).renderingMode(.template).foregroundStyle(bar == Color(white: 0.16) ? Color.white : Color.black)
                            } else { Color.clear.frame(width: 1, height: 18) }
                        }
                        .frame(width: 170, height: 24).background(bar).environment(\.colorScheme, bar == Color(white: 0.16) ? .dark : .light)
                    }
                    BarPartsView(items: [row.1], appIcon: NSRunningApplication.current.icon).frame(width: 200, height: 24, alignment: .leading)
                        .padding(.horizontal, 6).background(Theme.background)
                }
            }
        }.padding(16).pilotTheme().background(Theme.background), title: "", to: dir.appendingPathComponent("bar-items.png"))
        // Sven's menu bar as it starts after the carry-over: the group of CPU and RAM, then the timer.
        let svens = menuSettings.slots(in: .menuBar).compactMap { slot in BarParts.parts(slot, inputs, settings: menuSettings.settings).map { (slot, $0) } }
        try Self.render(HStack(spacing: 6) {
            ForEach(Array(svens.enumerated()), id: \.offset) { _, item in
                if let image = StatusItemImage.image(item.1) { Image(nsImage: image).renderingMode(.template).foregroundStyle(.black) }
            }
        }.padding(6).background(Color(white: 0.9)), title: "", to: dir.appendingPathComponent("menu-bar-image-svens.png"))
        try Self.render(StatPopover(stats: [.cpu, .ram], rows: rows, busiest: [.cpu: SystemStats.busiest(ps, by: .cpu), .ram: SystemStats.busiest(ps, by: .memory)],
                                    values: history.last, latest: b, history: history) {},
                        title: "", to: dir.appendingPathComponent("menu-bar-popover.png"))
        try Self.render(BindEditor(action: "apps.terminal", actions: engine.bindActions).environment(engine), title: "",
                        to: dir.appendingPathComponent("sheet-bind-editor.png"))
        // Sven's example (card agent-bo-95422779): Chrome 50 / Spotify 25 / X 25, own sizes.
        let example = WorkspacePreset(name: "Work", apps: [.init(bundleId: "com.google.Chrome", name: "Google Chrome", percent: 50),
                                                           .init(bundleId: "com.spotify.client", name: "Spotify", percent: 25),
                                                           .init(bundleId: "dev.banozz.pilot.webapp.x-com", name: "X", percent: 25)], layout: nil)
        // The editor is a popup in the window now (mockup E, card agent-bo-95422980): drawn alone at its size in the
        // default window, on a store in a temporary folder; RestyledRenders draws it over the page.
        let store = FileManager.default.temporaryDirectory.appending(path: "pilot-render-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let presets = WorkspacePresets(observers: EngineObservers(), store: WorkspacePresetStore(url: store.appending(path: "workspace-presets.json")))
        presets.save(example, to: "2")
        let popup = WorkspacePopup.size(in: AppWindowController.size)
        try Self.render(WorkspaceEditor(workspace: "2", presets: presets, layouts: WorkspaceLayouts(observers: EngineObservers(), defaults: UserDefaults(suiteName: testSuite())!),
                                        start: .init(apps: []), close: {})
                            .frame(width: popup.width, height: popup.height).pilotTheme().environment(engine), title: "",
                        to: dir.appendingPathComponent("popup-workspace-editor.png"))
        // One screen's top bar on the seeded workspaces (cards agent-bo-95422850 and 911), the strip's height, every item drawn
        // in a style, on the fakes' readings, a sample battery and Wi-Fi; then each popover.
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: setupLook,
                                   readBattery: { SystemStats.Battery(percent: 82, charging: true, pluggedIn: true, minutesLeft: 30) },
                                   readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 866) })
        engine.observers.seed(focusedApp: .current)
        let timer = ExtensionTimer()
        timer.startFocus()
        let sources = BarSources(readings: readings, observers: engine.observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: timer, pilotTitle: { "2" })
        let barDefaults = try #require(UserDefaults(suiteName: "pilot.renders.topbar"))
        barDefaults.removePersistentDomain(forName: "pilot.renders.topbar")
        let bar = BarItemsStore(defaults: barDefaults) { [:] }
        for kind in [BarKind.focusedApp, .keyboardLayout, .volume, .battery, .wifi, .keepAwake, .divider] { bar.settings.set(kind, on: true) }
        bar.settings.set(.volume, style: .output)
        bar.settings.set(.focusedApp, style: .iconName)
        bar.settings.set(.wifi, style: .strength)
        bar.settings.set(.otherApps, on: false)
        bar.settings.clockZone = "America/New_York"
        for kind in [BarKind.battery, .wifi, .volume, .keyboardLayout, .clock] { readings.hold(kind) }
        // Every bar view (card agent-bo-95422914), the popovers and dropdown on Solid panels: Glass draws
        // only on screen, so its look is lane 1's live check.
        typealias On = DropdownQuickSwitchesTests.Fake
        let switches = QuickSwitches(hyper: On(true), tiling: On(true), topBar: On(false), keepAwake: On(false), clipboard: On(true), dictation: On(true))
        let hyperOff = QuickSwitches(hyper: On(false), tiling: On(true), topBar: On(false), keepAwake: On(false), clipboard: On(true), dictation: On(true))
        let glass = Look.shared.glass
        Look.shared.glass = false
        timer.startFocus()
        // Over the menu bar revealing under it (card agent-bo-95423007): the front app's menus again and again across the
        // bar, so any gap between items would show one.
        try Self.render(TopBarView(screen: "CU34G4Z", sources: sources, store: bar).frame(width: 1800, height: 30)
            .background(alignment: .leading) {
                Text(String(repeating: "Finder   File   Edit   View   Go   Window   Help      ", count: 6)).lineLimit(1).fixedSize()
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black).padding(.horizontal, 12)
                    .frame(width: 1800, height: 30, alignment: .leading).background(.white)
            },
                        title: "", to: dir.appendingPathComponent("top-bar.png"))
        for kind in [BarKind.workspaces, .focusedApp, .volume, .wifi, .clock, .timer] {
            try Self.render(BarPopover(kinds: [kind], sources: sources, store: bar).pilotTheme(), title: "", to: dir.appendingPathComponent("popover-\(kind.rawValue).png"))
        }
        timer.startFocus(paused: true)
        try Self.render(TimerPopover(timer: timer).pilotTheme(), title: "", to: dir.appendingPathComponent("popover-timer-paused.png"))
        try Self.render(StatPopover(stats: [.cpu, .ram], rows: rows, busiest: [.cpu: SystemStats.busiest(ps, by: .cpu), .ram: SystemStats.busiest(ps, by: .memory)],
                                    values: history.last, latest: b, history: history) {}.pilotTheme(),
                        title: "", to: dir.appendingPathComponent("popover-readings.png"))
        // The Menu bar page's three previews (cards agent-bo-95422913 and 914).
        for placement in BarPlacement.allCases {
            try Self.render(MenuBarPage(onScreen: false, placement: placement).environment(engine).pilotTheme().frame(width: 1000, height: 1500)
                .background(Theme.background), title: "", to: dir.appendingPathComponent("menu-bar-page-\(placement.rawValue).png"))
        }
        // Pilot's dropdown, as BarPanel shows it: on Pilot's theme (card agent-bo-95422912) on fake switches: the every day, then a problem with Option held.
        engine.gate.seed(trusted: true)
        engine.secureInput.seed(active: false)
        try Self.render(PilotDropdown(switches: switches, option: false).environment(engine).pilotTheme(), title: "", to: dir.appendingPathComponent("dropdown.png"))
        // The Hyper key switched off (card agent-bo-95422986): its tile unlit, the line under the headline saying so.
        try Self.render(PilotDropdown(switches: hyperOff, option: false).environment(engine).pilotTheme(), title: "", to: dir.appendingPathComponent("dropdown-hyper-off.png"))
        engine.gate.seed(trusted: false)
        engine.secureInput.seed(active: true)
        try Self.render(PilotDropdown(switches: switches, option: true).environment(engine).pilotTheme(), title: "", to: dir.appendingPathComponent("dropdown-problem-option.png"))
        Look.shared.glass = glass
        timer.stop()
        for kind in [BarKind.battery, .wifi, .volume, .keyboardLayout, .clock] { readings.release(kind) }
        #expect(withoutCards.isEmpty, "pages not on the window's cards: \(withoutCards)")
    }

    /// A view in a titled dark window of its own size, frame and all, at Retina scale.
    /// Setup on the fakes as on screen (cards agent-bo-95422800 to 802): speakers with a slider and mute and Bluetooth not
    /// shown yet; then the TV whose volume apps may not change, and Bluetooth's Show pressed before, listing the fake's
    /// devices. Async, so the page's own Bluetooth read finishes before the picture.
    @Test("Setup renders on the fakes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderSetup() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
        testApp()
        let setupLook = Look(inputSources: SetupKeepAwakeTests.FakeSources())
        for (name, output) in [("setup-sound", AudioDeviceID(10)), ("setup-sound-fixed-volume", AudioDeviceID(12))] {
            let audio = SetupSoundTests.FakeAudio()
            audio.defaults[.output] = output
            // The second also has Wi-Fi's Show networks pressed and Location allowed, so it lists the fake's networks.
            let wifi = SetupWiFiTests.FakeWiFi()
            wifi.location = output == 12 ? .allowed : .notAsked
            let remembered = SetupBluetoothTests.defaults(shown: output == 12)
            remembered.set(output == 12, forKey: SetupWiFi.shownKey)
            let devices = SetupDevices(audio: audio, bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: wifi,
                                       displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()), look: setupLook,
                                       defaults: remembered)
            try await Self.renderSettled(SetupPage(onScreen: true, devices: devices).frame(width: 700, height: 1800).pilotTheme()
                .background(Theme.background), to: dir.appendingPathComponent("\(name).png"))
        }
        // Hyper+Ctrl+W's landing (card agent-bo-95422805): a window-sized page scrolled to Wi-Fi.
        let devices = SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: SetupWiFiTests.FakeWiFi(),
                                   displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()), look: setupLook, defaults: SetupBluetoothTests.defaults())
        try await Self.renderSettled(SetupPage(onScreen: true, section: .constant(.wifi), devices: devices).frame(width: 700, height: 520).pilotTheme()
            .background(Theme.background), to: dir.appendingPathComponent("setup-at-wifi.png"))
    }

    private static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// As `render`, but the main actor is let go before the picture, so a page's own tasks (Setup's Bluetooth list) finish.
    private static func renderSettled(_ view: some View, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        spin(0.3)
        try await Task.sleep(for: .milliseconds(300))
        spin(0.3)
        let frame = try #require(w.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:])).write(to: url)
        w.close()
    }

    private static func render(_ view: some View, title: String, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let frame = try #require(w.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:])).write(to: url)
        w.close()
    }

    /// How many pixels right of `fromX` are `rgb`, give or take 1 per channel (every 2nd pixel, every 2nd row).
    private static func count(_ rgb: [Int], in rep: NSBitmapImageRep, fromX: Int) -> Int {
        var n = 0, p = [Int](repeating: 0, count: 4)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: fromX, to: rep.pixelsWide, by: 2) {
                rep.getPixel(&p, atX: x, y: y)
                if abs(p[0] - rgb[0]) <= 1 && abs(p[1] - rgb[1]) <= 1 && abs(p[2] - rgb[2]) <= 1 { n += 1 }
            }
        }
        return n
    }
}
}
#endif
