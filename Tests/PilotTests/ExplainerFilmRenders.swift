#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
import WebApps
@testable import Pilot

/// The explainer video's drawn shots beyond the launcher (SH23, rounds 4 and 5; LauncherFilmRenders has the menu): the
/// hold-Hyper overlay on the Pilot default preset a stranger gets, Binds before and after a key is given, a note filling as
/// dictation types it, Summarise's page, a file's Cmd+K and Convert to… pickers and tips, the Hyper + right-click picker,
/// the top bar for each scene's windows, Cycle layout's tips, the clipboard in depth (its tabs, a search read from an
/// image, three picks pasted one by one), the AI chat binding a key behind the Allow prompt, the terminal drop at 1920,
/// Install › Web apps before and after one is made, the capture overlay over a still of the film's own screen
/// (PILOT_FILM_STILL), and cut 3's: the bar clock's month, QR codes made and read, Quick notes from Scratch to a search
/// (a pasted picture from PILOT_FILM_PHOTO when given), folder designs from Hyper + right-click, and Lock keyboard's screen;
/// and cut 4's: Pilot's window on Workspaces, Tiling, Stats, Update & Clean and Reports, the AI chat making an extension
/// with /extension, and the video editor on a made-up recording (PILOT_FILM_RECORDING); and cut 5's, all in Dusk: Weather's item
/// in the top bar, Activity, the views earlier cuts borrowed from other render tests, Keys › Mouse, Snippets, AI › Setup and
/// Apps › Open with; and cut 6's: a tea timer in the bar, the one Extensions list, Summarise in the selection pill, Capture text's
/// tip, and Weather's popover on Glass; and for the 1.0.3 film (P89), dictation's take in the top bar; and film v4's (P89): Tiling's
/// gaps dragged and the Menu bar page as its items change, each with the film's own bar.
/// Instrument in the film's theme (`theme`), Solid (glass draws nothing offscreen), with made-up notes, files, copies and
/// windows, never this Mac's. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter ExplainerFilmRenders`
extension SharedLook {
@MainActor
@Suite("Explainer film renders")
struct ExplainerFilmRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    /// The film's theme: Void from film v2 (Sven, 2026-10-29, Q583; Dusk in the 1.0 film, Q516).
    nonisolated static let theme = "void"

    /// The folder `name` under explainer-film, the app, faces and a stranger's look ready; refuses Sven's own home.
    static func prepare(_ name: String) throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        (look.style, look.themeID, look.glass) = (.instrument, Self.theme, false)
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent("explainer-film/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("The hold-Hyper overlay on the Pilot default preset", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func overlay() throws {
        let dir = try Self.prepare("overlay")
        let rows = OverlayPage.rows(store: BindStore(defaults: PilotDefault.binds), actions: Engine().bindActions, sublayer: .hyper,
                                    mode: .every, presses: [:], picks: [])
        try #require(!rows.isEmpty)
        try InstrumentPanelsRenders.render(OverlayView(title: "Hyper", rows: rows) {}, .overlay, "overlay", in: dir)
    }

    @Test("Pilot's window on Binds, the Pilot default preset, before and after Hyper+U opens Ghostty", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func bindsWindow() throws {
        let dir = try Self.prepare("binds")
        let toml = (NSHomeDirectory() as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        let engine = Engine()
        engine.gate.seed(trusted: true)
        engine.secureInput.seed(active: false)
        try Data(#"{"version": 3, "preset": "pilot", "binds": []}"#.utf8).write(to: engine.binds.fileURL)
        engine.binds.load()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        AppWindowController.applyLook(Look.shared, to: window)
        func shoot(_ name: String) throws {
            window.setContentSize(NSSize(width: 1440, height: 900))
            model.go(AppPlace(.binds))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        try shoot("window-before")
        engine.binds.replace(AppsModule.openID(bundle: "com.mitchellh.ghostty"), with: Key("u"))
        try shoot("window-after")
    }

    static let question = "Make this polite: can't do Friday, Monday instead?"
    static let reply = "Sorry, Friday doesn't work for me after all. Could we move it to Monday? Any time that day suits me."

    @Test("Quick AI: a question typed, sent, its answer streaming in", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func quickAI() async throws {
        let dir = try Self.prepare("ai")
        let look = Look.shared
        func shot(_ model: AIChatModel, _ name: String) async throws {
            let rep = try #require(try await snapshot(rendering: AIChatPanel.content(model, look: look)))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        let typing = await AIChatPanelRenders.model([], streaming: false)
        typing.route = "Claude Code · Sonnet"
        let words = Self.question.split(separator: " ")
        for i in 0...words.count {
            typing.draft = words.prefix(i).joined(separator: " ")
            try await shot(typing, String(format: "t%02d", i))
        }
        typing.clear()
        for (i, share) in [0.25, 0.55, 0.8].enumerated() {
            let streaming = await AIChatPanelRenders.model([(Self.question, String(Self.reply.prefix(Int(Double(Self.reply.count) * share))))], streaming: true)
            streaming.route = "Claude Code · Sonnet"
            try await shot(streaming, "s\(i + 1)")
            streaming.clear()
        }
        let done = await AIChatPanelRenders.model([(Self.question, Self.reply)], streaming: false)
        done.route = "Claude Code · Sonnet"
        try await shot(done, "s4")
        done.clear()
    }

    /// The note dictation types, a few words a frame.
    static let dictated = ["", "Book the", "Book the 9:40 train", "Book the 9:40 train to Sintra,", "Book the 9:40 train to Sintra, then lunch",
                           "Book the 9:40 train to Sintra, then lunch at the market.", "Book the 9:40 train to Sintra, then lunch at the market. Ask Ana",
                           "Book the 9:40 train to Sintra, then lunch at the market. Ask Ana if she wants to come."]

    @Test("Quick notes filling as dictation types", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func dictation() throws {
        let dir = try Self.prepare("dictation")
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-film-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        _ = try store.load()
        try Data("# Groceries\n- [ ] limes\n- [ ] coffee\n".utf8).write(to: folder.appending(path: "groceries-100002.md"))
        let id = "lisbon-weekend-100001.md"
        for (i, words) in Self.dictated.enumerated() {
            try Data("# Lisbon weekend\n\n\(words)".utf8).write(to: folder.appending(path: id))
            let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
            model.reload()
            model.open(id)
            let panel = HUD.makePanel(NotesPanelView(model: model).frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height),
                                      surface: .notes)
            defer { panel.close() }
            let content = try #require(panel.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            content.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(content, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(String(format: "n%02d.png", i)))
        }
    }

    /// Summarise's page for a web page, the blocks its main.py `page` command prints for a summarised item.
    static let summarise = #"""
    {"type": "blocks", "blocks": [
     {"type": "section", "title": "Tiling window manager", "subtitle": "en.wikipedia.org/wiki/Tiling_window_manager", "aside": "Page",
      "blocks": [{"type": "stats", "items": [{"label": "Words", "value": "2,184"}]}]},
     {"type": "buttons", "actions": [{"type": "run", "command": "save", "title": "Save as .md", "icon": "📄", "context": {"id": "a1"}},
                                     {"type": "open", "url": "https://en.wikipedia.org/wiki/Tiling_window_manager", "title": "Open link"}]},
     {"type": "section", "title": "Summary · Pilot AI", "blocks": [{"type": "markdown", "text": "- A **tiling window manager** lays windows out side by side so they never overlap, instead of letting you stack them by hand.\n- It started on Xerox's Star and on Unix desktops, and lives on today in i3, Sway, Hyprland and niri.\n- Most are driven from the keyboard: one key moves focus, another moves the window, a third changes the layout.\n- The trade-off: less dragging and hunting for windows, in exchange for learning a few keys."}]},
     {"type": "section", "title": "Ask about it", "blocks": [{"type": "input", "placeholder": "Ask about this page", "action": {"type": "run", "command": "ask", "title": "Ask"}}]},
     {"type": "section", "title": "Full text", "blocks": [{"type": "markdown", "text": "A tiling window manager organises the screen into mutually non-overlapping frames, as opposed to the more common approach of coordinate-based stacking of overlapping objects that tries to fully emulate the desktop metaphor."}]}
    ]}
    """#.replacingOccurrences(of: "\n", with: " ")

    @Test("Summarise's page as the extension sends it", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func summarisePage() async throws {
        let out = try Self.prepare("summarise")
        let dir = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        try ExtensionSurfaceTests.write("summarise", title: "Summarise", in: exts)
        let answer = ExtensionRun.surfaceAnswer(Self.summarise, kind: .page)
        guard case .blocks(let blocks, _) = answer else { Issue.record("Summarise's blocks did not read: \(answer)"); return }
        let page = ExtensionPageModel(id: "summarise", folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in .blocks(blocks) })
        await page.refresh()
        let look = Look.shared
        let view = SurfaceGround { ExtensionSurfacePage(id: "summarise", onScreen: false, model: page) { _ in }.frame(width: 900, height: 900) }
            .styled(.page(.extensions), look: look).pilotTheme(look: look)
        try writeRender(view, to: out.appendingPathComponent("page.png"), wait: 0.8)
    }

    /// Three photos in the moved home's Pictures, real files so the Files view's preview reads one.
    static func photos(home: String) throws -> [URL] {
        let folder = URL(filePath: home).appending(path: "Pictures/Lisbon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try ["IMG_2041.HEIC", "IMG_2042.HEIC", "IMG_2047.HEIC"].enumerated().map { i, name in
            let url = folder.appending(path: name)
            try ClipboardTabsRenders.png(CGSize(width: 1200, height: 900), seed: i % 2).write(to: url)
            return url
        }
    }

    @Test("A photo's Cmd+K, Convert to… and its tip; Hyper + right-click's picker", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func files() async throws {
        let dir = try Self.prepare("files")
        let home = NSHomeDirectory()
        let urls = try Self.photos(home: home)
        let thumbnails = FileThumbnails.shared
        thumbnails.make = FileThumbnailRenders.fake
        defer { thumbnails.make = FileThumbnails.quickLook }
        let built = try LineMenuRenders.built()
        let day = Date(timeIntervalSince1970: 1_791_028_800)
        func line(_ nav: MenuNavigator) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.ownKey = "Hyper+Space"
            return m
        }
        // The Files view searched for "img_20", then Cmd+K on the first photo and Down to Convert to….
        var files = MenuNavigator(entries: built)
        files.query = "img_20"
        files.show(.file)
        files.provide(.file, MenuEntries.files(urls.enumerated().map { ($0.element.path, day.addingTimeInterval(Double(-3600 * $0.offset))) }, home: home))
        try await LineMenuRenders.render(line(files), "f1-files", in: dir, wait: 1.5)
        var actions = files
        _ = actions.handle(.commandK)
        try await LineMenuRenders.render(line(actions), "f2-actions", in: dir, wait: 0.5)
        for step in 1...2 {
            _ = actions.handle(.down)
            try await LineMenuRenders.render(line(actions), "f3-actions-down\(step)", in: dir, wait: 0.4)
        }
        // Convert to…'s picker, its rows Pilot's own for these files, PNG picked.
        let options = Converter.installed().options(for: [urls[0]])
        try #require(!options.isEmpty)
        var convert = MenuNavigator(list: Convert.rows(options), title: "Convert \(urls[0].lastPathComponent) to")
        try await LineMenuRenders.render(line(convert), "f4-convert", in: dir, wait: 0.4)
        if let png = convert.rows.firstIndex(where: { $0.title.uppercased().hasPrefix("PNG") }) {
            for step in 0..<png {
                _ = convert.handle(.down)
                try await LineMenuRenders.render(line(convert), "f5-convert-down\(step + 1)", in: dir, wait: 0.3)
            }
        }
        let batch = ConvertBatch([urls[0]], to: .png)
        var outcome = ConvertBatch.Outcome()
        outcome.written = [urls[0].deletingPathExtension().appendingPathExtension("png")]
        try InstrumentPanelsRenders.render(TipView(text: "Converting \(urls[0].lastPathComponent) to PNG…", action: HUD.TipAction(title: "Cancel") {}), .hud, "f6-tip-converting", in: dir)
        try InstrumentPanelsRenders.render(TipView(text: batch.summary(outcome)), .hud, "f7-tip-done", in: dir)

        // Hyper + right-click on one photo: Pilot's actions for an image, Down to Upscale….
        let rows = FileActionsMenu.rows(FileAction.list(for: [.image]))
        var picker = MenuNavigator(list: rows, title: urls[1].lastPathComponent)
        try await LineMenuRenders.render(line(picker), "r1-picker", in: dir, wait: 0.4)
        if let upscale = picker.rows.firstIndex(where: { $0.title == FileAction.upscale.title }) {
            for step in 0..<upscale {
                _ = picker.handle(.down)
                try await LineMenuRenders.render(line(picker), "r2-picker-down\(step + 1)", in: dir, wait: 0.3)
            }
        }
    }

    /// The film's windows, in the order they open: the browser, Ghostty and Notes, each on the workspace `spaces` gives
    /// it (fewer spaces, fewer windows), all on the video's one screen.
    static func windows(_ spaces: [String]) -> String {
        let apps = [("Browser", "com.apple.Safari", "Pilot"), ("Ghostty", "com.mitchellh.ghostty", "~/code/site — zsh"),
                    ("Notes", "com.apple.Notes", "Launch week")]
        let rows = zip(apps.indices, spaces).map { i, space in
            #"{"window-id": \#(i + 1), "app-name": "\#(apps[i].0)", "app-bundle-id": "\#(apps[i].1)", "app-pid": \#(i + 1), "#
                + #""workspace": "\#(space)", "monitor-id": 1, "window-layout": "h_tiles", "window-title": "\#(apps[i].2)"}"#
        }
        return "[" + rows.joined(separator: ", ") + "]"
    }

    /// The top bar for each scene's windows (Sven's cut 1 note: no workspace lit before a window is open): none; all three
    /// on 1 (and the browser alone, then with Ghostty: cut 4's tiling); Notes moved to 2, with 1, 2 or the empty 3 in front; Ghostty sent to 2 beside Notes, with 1 or 2 in front
    /// (cut 3); and with the terminal drop open, its item lit.
    static let barStates: [(name: String, spaces: [String], focused: String, lit: Set<BarDropKind>)] = [
        ("bar-empty", [], "1", []), ("bar-b1", ["1"], "1", []), ("bar-b1-2", ["1", "1"], "1", []), ("bar-w1", ["1", "1", "1"], "1", []), ("bar-w12", ["1", "1", "2"], "1", []),
        ("bar-w12-on2", ["1", "1", "2"], "2", []), ("bar-w12-on3", ["1", "1", "2"], "3", []),
        ("bar-w1-22", ["1", "2", "2"], "1", []), ("bar-w1-22-on2", ["1", "2", "2"], "2", []),
        ("bar-w12-terminal", ["1", "1", "2"], "1", [.terminal]),
    ]

    @Test("The top bar for each scene's windows", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func bars() async throws {
        let dir = try Self.prepare("bars")
        StatsRenders.seed(SystemSampler.shared)
        let weather = try await Self.weatherBar()
        defer { try? FileManager.default.removeItem(at: weather.folder) }
        var s = BarSettings.defaults
        func item(_ kind: BarKind, _ style: BarStyle) -> BarSlot {
            s.set(kind, style: style)
            return .item(s.entry(kind))
        }
        let readings = [BarKind.cpu, .memory, .network].map { kind in s.set(kind, style: .text); return s.entry(kind) }
        // No app-in-front item: the test can only name a running app, and the video's windows are not.
        let sides: [TopBarSide: [BarSlot]] = [.left: [item(.pilot, .icon), item(.workspaces, .numbers)],
                                              .centre: [item(.terminal, .iconName), item(.askAI, .iconName)],
                                              .right: [.group(readings), .item(s.entry(.extensions)), item(.volume, .iconPercent), item(.wifi, .icon),
                                                       item(.clock, .dateTime)]]
        let monitors = try AeroMonitorWorkspace.parse(#"[{"monitor-id": 1, "monitor-name": "Studio", "workspace": "1"}]"#)
        let bar = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                              readBattery: { nil }, readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                              watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        var held: Set<BarKind> = []
        bar.hold(Set(sides.values.joined().flatMap(\.kinds)), replacing: &held)
        defer { bar.hold([], replacing: &held) }
        for state in Self.barStates {
            let windows = try AeroWindow.parse(Self.windows(state.spaces))
            let observers = EngineObservers()
            observers.tiler.seed(focused: state.focused, occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: monitors)
            var sources = BarSources(readings: bar, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                     timer: ExtensionTimer(), pilotTitle: { state.focused })
            sources.extensionBar = weather.bar
            try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: Look.shared, lights: BarDropLights(open: state.lit))
                                .frame(width: 1920, height: 32),
                            to: dir.appendingPathComponent("\(state.name).png"), wait: 0.8)
        }
        // Cut 6: the tea timer installed beside Weather, on the usual windows.
        let tea = try await Self.weatherBar(tea: true)
        defer { try? FileManager.default.removeItem(at: tea.folder) }
        let windows = try AeroWindow.parse(Self.windows(["1", "1", "2"]))
        let observers = EngineObservers()
        observers.tiler.seed(focused: "1", occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: monitors)
        var sources = BarSources(readings: bar, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), pilotTitle: { "1" })
        sources.extensionBar = tea.bar
        try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: Look.shared).frame(width: 1920, height: 32),
                        to: dir.appendingPathComponent("bar-w12-tea.png"), wait: 0.8)
        // The 1.0.3 film's dictation short (P89): a take in the top bar at its centre, the waveform alone, then with the words.
        try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: Look.shared, take: DictationOverlayRenders.barTake(.centre))
                            .frame(width: 1920, height: 32),
                        to: dir.appendingPathComponent("bar-w12-dictation.png"), wait: 0.8)
        try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: Look.shared,
                                                    take: DictationOverlayRenders.barTake(.centre, words: Self.dictated.last))
                            .frame(width: 1920, height: 32),
                        to: dir.appendingPathComponent("bar-w12-dictation-words.png"), wait: 0.8)
        // Film v4 (P89): Hyper+R recording, the bar's control counting its first seconds.
        let recorder = Recorder()
        sources.extensionBar = weather.bar
        for second in 0...4 {
            recorder.pose(.recording, elapsed: Double(second) + 0.2)
            try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: Look.shared, trailing: AnyView(RecordingControl(recorder: recorder)))
                                .frame(width: 1920, height: 32),
                            to: dir.appendingPathComponent("bar-w12-rec-\(second).png"), wait: 0.3)
        }
    }

    /// The film's tiling gaps, in points (Sven's cut 6 note: wider, so more wallpaper shows); gen.py's GO and GI match.
    static let gaps = (inner: 20, outer: 32)

    /// Weather installed from the catalogue, its bar item asked once (Sven's Q515: its icon in the bar), in a folder of its own,
    /// beside a Pomodoro and the AI usage gauge (Sven's cut 6 note: a bunch of extensions in the bar). With `tea`, cut 6's own
    /// extension too: a tea timer made with `pilot ext new --mode bar`, counting down.
    static func weatherBar(tea: Bool = false) async throws -> (bar: ExtensionBar, folder: URL) {
        let dir = try ExtensionSurfaceTests.folder()
        let exts = dir.appending(path: "Extensions")
        try ExtensionSurfaceTests.write("weather", title: "Weather", in: exts)
        try ExtensionSurfaceTests.write("pomodoro", title: "Pomodoro", page: false, in: exts)
        try ExtensionSurfaceTests.write("ai-usage", title: "AI usage", page: false, in: exts)
        if tea { try ExtensionSurfaceTests.write("tea-timer", title: "Tea timer", page: false, in: exts) }
        let bar = ExtensionBar(folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { surface, _ in
            switch surface.command.id.extension {
            case "tea-timer": .bar(Extension.BarAnswer(text: "🍵 3:42"))
            case "pomodoro": .bar(Extension.BarAnswer(text: "🍅 18:24"))
            case "ai-usage": .bar(Extension.BarAnswer(text: "", gauges: [Extension.Gauge(meters: [66, 30], icon: .claude, text: "66%")]))
            default: .bar(Extension.BarAnswer(text: "☀️ 24°"))
            }
        }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        await bar.round()
        let ids = ["weather", "pomodoro", "ai-usage"] + (tea ? ["tea-timer"] : [])
        try #require(Set(bar.faces(in: .topBar).map(\.id)) == Set(ids), "the bar's extension items: \(bar.faces(in: .topBar))")
        return (bar, dir)
    }

    /// Cycle layout's tip for each preset, as WorkspaceLayouts.cycle shows it.
    @Test("Cycle layout's tip for each preset", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func layoutTips() throws {
        let dir = try Self.prepare("layouts")
        for preset in LayoutPreset.allCases {
            try InstrumentPanelsRenders.render(TipView(text: preset.label), .hud, "tip-\(preset.rawValue)", in: dir)
        }
    }

    /// Ten copies a stranger might have, oldest first; the newest three are a contact's name, address and email.
    static func clipboardStore(at db: URL) async throws -> (ClipboardStore, picks: [Int64]) {
        let store = try ClipboardStore(path: db)
        let now = Date()
        func text(_ text: String, _ app: String?) -> ClipItem {
            ClipItem(kind: text.hasPrefix("#") ? .colour : .text, text: text,
                     contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]], sourceApp: app)
        }
        func image(_ png: Data) -> ClipItem {
            ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: png]], sourceApp: "com.apple.Preview")
        }
        let items: [ClipItem] = [
            text("Flight KM 112 · Thu 07:40, gate B12", "com.apple.mail"),
            text("Thanks! I'll send the draft tonight.", "com.apple.MobileSMS"),
            image(ClipboardTabsRenders.png(CGSize(width: 1280, height: 800), seed: 1)),
            text("git push origin main", "com.mitchellh.ghostty"),
            text("https://en.wikipedia.org/wiki/Tiling_window_manager", "com.apple.Safari"),
            text("#2BC4F0", nil),
            image(ClipboardTabsRenders.invoice()),
            text("12 Rua das Flores, 1200-195 Lisbon", "com.apple.AddressBook"),
            text("ana.ribeiro@example.com", "com.apple.AddressBook"),
            text("Ana Ribeiro", "com.apple.AddressBook"),
        ]
        var ids: [Int64] = []
        for (i, item) in items.enumerated() { ids.append(try store.add(item, at: now.addingTimeInterval(Double(-300 * (items.count - i))))) }
        try store.setPinned([ids[0], ids[1]], true)
        try store.tag([ids[0], ids[7]], with: "lisbon")
        // The invoice's words as ClipboardOCR stores them, read by the real Vision; the photo read too, with no words.
        try store.setRecognised(ids[6], await VisionText().text(in: try #require(try store.image(of: ids[6]))))
        try store.setRecognised(ids[2], "")
        return (store, [ids[9], ids[7], ids[8]])
    }

    @Test("Clipboard in depth: the tabs walked, a search that reads an image, three picks pasted one by one", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func clipboard() async throws {
        let dir = try Self.prepare("clipboard")
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-film-clipboard-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let (store, picks) = try await Self.clipboardStore(at: db)
        func shot(_ model: PanelModel, _ name: String) async throws {
            for _ in 0..<300 where model.rows.contains(where: { $0.kind == .image && model.thumbnail($0) == nil }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(try ClipboardTabsRenders.render(ClipboardPanelView(model: model, returnCopies: false)).representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(name).png"))
        }
        // Opened on All, then Tab through the kinds to Pinned.
        let walk = PanelModel(store: store)
        try await shot(walk, "w0")
        let tabs = walk.tabs
        let pinned = try #require(tabs.firstIndex(of: .kind(.pinned)))
        for i in 1...pinned {
            walk.tab = tabs[i]
            try await shot(walk, "w\(i)")
        }
        // A search typed on All: "total" is only in the invoice's picture, lit where Vision read it.
        let search = PanelModel(store: store)
        let word = "total"
        for i in 1...word.count {
            search.query = String(word.prefix(i))
            if i == word.count {
                for _ in 0..<300 where search.previewBoxes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                try #require(!search.previewBoxes.isEmpty)
            }
            try await shot(search, "s\(i)")
        }
        // Cmd+Return on the name, the email and the address, then Cmd+K's list.
        let picking = PanelModel(store: store)
        for (i, id) in picks.enumerated() {
            let row = try #require(picking.rows.firstIndex { $0.id == id })
            picking.move(row - picking.cursor)
            picking.togglePick()
            try await shot(picking, "p\(i + 1)")
        }
        try #require(picking.picked?.count == 3)
        picking.open(.actions)
        try await shot(picking, "p4-actions")
        try InstrumentPanelsRenders.render(TipView(text: "Pasting 3 one by one: ⌘V pastes the next."), .hud, "tip-sequence", in: dir)
        try InstrumentPanelsRenders.render(TipView(text: "All 3 pasted."), .hud, "tip-sequence-done", in: dir)
    }

    static let order = "Make Hyper+Y run brew upgrade"

    /// The chat binding a shell command: it reads the routes, binds, and waits there while the gate asks.
    static let binding: AIChatModel.Turn = { _, event throws(QuickAI.Failure) in
        event(.toolCall(id: "y1", command: "pilot help bind routes"))
        event(.toolResult(id: "y1", output: "drive.shell:<command>  runs a shell command", isError: false))
        event(.toolCall(id: "y2", command: "pilot bind 'drive.shell:brew upgrade' y"))
        try? await Task.sleep(for: .seconds(60))
        return AIChat.Reply("")
    }

    /// The same turn once Allow was pressed: the bind's answer, then the reply.
    static let bound: AIChatModel.Turn = { _, event throws(QuickAI.Failure) in
        event(.toolCall(id: "y1", command: "pilot help bind routes"))
        event(.toolResult(id: "y1", output: "drive.shell:<command>  runs a shell command", isError: false))
        event(.toolCall(id: "y2", command: "pilot bind 'drive.shell:brew upgrade' y"))
        event(.toolResult(id: "y2", output: #"{"action":"drive.shell:brew upgrade","custom":true,"key":"Hyper+Y","off":false}"#, isError: false))
        event(.text("Done. Hyper+Y now runs `brew upgrade`."))
        return AIChat.Reply("Done. Hyper+Y now runs `brew upgrade`.")
    }

    @Test("The AI chat changing Pilot, after an earlier question: the order typed, the Allow prompt on its shell bind, the bind made", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func aiActs() async throws {
        let dir = try Self.prepare("ai-acts")
        let look = Look.shared
        func shot(_ model: AIChatModel, _ name: String) async throws {
            let rep = try #require(try await snapshot(rendering: AIChatPanel.content(model, look: look)))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        // An earlier question in the chat, so the drop opens on a conversation.
        let prior = AIChatPanelRenders.turns[0]
        func withPrior(_ model: AIChatModel) async {
            model.send(prior.0, through: .success(AIChatPanelRenders.answers(prior.1)))
            await AIChatAgentTests.settled(model)
        }
        let typing = AIChatModel()
        typing.route = "Claude Code · Sonnet"
        await withPrior(typing)
        let words = Self.order.split(separator: " ")
        for i in 0...words.count {
            typing.draft = words.prefix(i).joined(separator: " ")
            try await shot(typing, String(format: "t%02d", i))
        }
        let asking = AIChatModel()
        asking.route = "Claude Code · Sonnet"
        asking.viewers += 1
        await withPrior(asking)
        asking.send(Self.order, acting: .success(Self.binding))
        await AIChatAgentTests.until { asking.calls[2]?.count == 2 }
        if let ask = ControlGate.Ask.run("drive.shell:brew upgrade") { Task { _ = await asking.decide(ask, program: "pilot, from claude") } }
        try #require(await AIChatAgentTests.asked(asking) != nil)
        try await shot(asking, "a1-asking")
        let done = AIChatModel()
        done.route = "Claude Code · Sonnet"
        done.viewers += 1
        await withPrior(done)
        done.send(Self.order, acting: .success(Self.bound))
        await AIChatAgentTests.settled(done)
        try await shot(done, "a2-done")
        for model in [typing, asking, done] { model.clear() }
    }

    /// The terminal drop's stand-in shell (Ghostty's Metal view draws nothing offscreen): the film's site project.
    struct Shell: View {
        @Environment(\.ink) private var ink
        static let lines: [[(String, BarDropRenders.Tint)]] = {
            let prompt: [(String, BarDropRenders.Tint)] = [("~/code/site", .path), (" main", .dim), (" ❯ ", .path)]
            // Simple, as Sven wants terminals in the film (v4): one command and its one line.
            return [prompt + [("npm run build", .plain)], [("✓", .good), (" 12 pages built in 1.84s", .plain)], prompt]
        }()

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(Self.lines.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 0) {
                        line.reduce(Text("")) { $0 + Text($1.0).foregroundStyle(colour($1.1)) }
                        if i == Self.lines.count - 1 { Rectangle().fill(ink.accent).frame(width: 7, height: 15) }
                    }
                    .font(ink.mono(12.5)).frame(height: 17)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        private func colour(_ tint: BarDropRenders.Tint) -> Color {
            switch tint {
            case .plain: ink.text
            case .path: ink.accentInk
            case .dim: ink.muted
            case .good: ink.green
            case .mark: ink.red
            }
        }
    }

    @Test("The terminal drop on the film's 1920 screen, its frame beside it", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func terminalDrop() throws {
        let dir = try Self.prepare("terminal")
        let look = Look.shared
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let bar = TopBarGeometry.frame(screen: screen, strip: 32)
        let visible = CGRect(x: 0, y: 0, width: screen.width, height: bar.minY)
        let frame = try #require(BarDropPlacement.frames(open: [.terminal], screen: screen, visible: visible, bar: bar)[.terminal])
        let shell = NSHostingView(rootView: Shell().styled(.quickAI, look: look).pilotTheme(look: look))
        shell.sizingOptions = []
        shell.frame = CGRect(origin: .zero, size: frame.size)
        // Hyper+T's key as a stranger's Pilot default labels it.
        let key = Dropdown.keyLabel(BindStore(defaults: PilotDefault.binds).trigger(for: TerminalDrop.actionID), layerKeys: [.capsLock])
        let chrome = TerminalDropChrome(shell, look: look, key: key, detail: { "zsh · ~/code/site" }, hide: {})
        chrome.frame = CGRect(origin: .zero, size: frame.size)
        let window = NSWindow(contentRect: chrome.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look.appearance(for: .quickAI)
        window.contentView = chrome
        defer { window.close() }
        chrome.layoutSubtreeIfNeeded()
        PanelTestSupport.pump(0.6)
        let rep = try #require(snapshot(chrome, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("drop.png"))
        let top = screen.height - frame.maxY
        try Data(#"{"x": \#(frame.minX), "y": \#(top), "width": \#(frame.width), "height": \#(frame.height)}"#.utf8)
            .write(to: dir.appendingPathComponent("frame.json"))
    }

    @Test("Install › Web apps before and after a web app is made", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func webApps() throws {
        let dir = try Self.prepare("webapps")
        let folder = WebAppStamper.applicationsFolder
        try #require(folder.path.hasPrefix(NSHomeDirectory()), "web apps are listed from \(folder.path), outside the moved home")
        let engine = Engine()
        engine.gate.seed(trusted: true)
        engine.secureInput.seed(active: false)
        func shoot(_ name: String) throws {
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
            defer { window.close() }
            let frame = try #require(window.contentView?.superview)
            AppWindowController.applyLook(Look.shared, to: window)
            window.setContentSize(NSSize(width: 1440, height: 900))
            model.go(AppPlace(.webApps))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        try shoot("page-before")
        // A made web app as WebAppDirectory reads one: its Info.plist in the moved home's ~/Applications.
        let spec = try WebAppSpec(name: "Wikipedia", url: "https://en.wikipedia.org")
        let app = folder.appending(path: "Wikipedia.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.appending(path: "Wikipedia.app")) }
        let plist: NSDictionary = ["CFBundleIdentifier": spec.bundleID, "CFBundleName": "Wikipedia", WebAppKey.url: "https://en.wikipedia.org"]
        try #require(plist.write(to: app.appending(path: "Info.plist"), atomically: true))
        try #require(WebAppDirectory.list().count == 1)
        try shoot("page-after")
    }

    @Test("Capture: the editor's billing page, and the overlay dragged over the film's own desktop", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func capture() throws {
        let dir = try Self.prepare("capture")
        // The page the editor opens on, for the film's browser to show before it is captured.
        let page = try #require(CaptureFixture.image())
        try #require(NSBitmapImageRep(cgImage: page).representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("billing.png"))
        // The overlay over a still of the film's screen (PILOT_FILM_STILL, 1920 x 1080), dragged from the page's top left
        // corner to its bottom right (cut 4: the page in the left tile of the film's tiled desktop, 1250 wide, under its
        // 52-point tab bar, outer gap 14).
        guard let path = Self.env["PILOT_FILM_STILL"] else { return }
        let still = try #require(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let size = CGSize(width: 1920, height: 1080)
        let grab = DisplayGrab(id: 1, frame: CGRect(origin: .zero, size: size), scale: CGFloat(still.width) / size.width, image: still)
        // Cut 7 (Sven: wider gaps): the page's corners follow the outer gap; the tile stays 1250 wide.
        let go = CGFloat(Self.gaps.outer), shift = go - 14
        let from = CGPoint(x: go, y: 32 + go + 52), to = CGPoint(x: go + 1250, y: 32 + go + 52 + 788)
        func write(_ selection: CaptureSelection, _ name: String) throws {
            let view = CaptureOverlayView(grab: grab, selection: selection, accent: CaptureOverlay.accent()) { _, _ in }
            let rep = try #require(snapshot(view, scale: 1))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        // The whole page for the editor (o), and cut 6's Capture text over the invoices table alone (t).
        for (name, from, to) in [("o", from, to), ("t", CGPoint(x: 340 + shift, y: 690 + shift), CGPoint(x: 1210 + shift, y: 860 + shift))] {
            try write(CaptureSelection(size: size, windows: [], pointer: from), "\(name)0")
            for (i, share) in [0.3, 0.65, 1.0].enumerated() {
                var drag = CaptureSelection(size: size, windows: [])
                drag.press(at: from)
                drag.move(to: CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share))
                try write(drag, "\(name)\(i + 1)")
            }
        }
    }

    /// The Line menu over `nav`, as Hyper + right-click and the pickers it opens show it.
    static func line(_ nav: MenuNavigator) -> MenuModel {
        let m = MenuModel(nav: nav)
        m.layout = .line
        m.ownKey = "Hyper+Space"
        return m
    }

    @Test("The bar clock's month over a stranger's week, and the 10th's card", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func calendar() throws {
        let dir = try Self.prepare("calendar")
        let store = ClockRenders.Store()
        let at = ClockRenders.at
        let blue = Paint(0x3380FF), green = Paint(0x4CCC66)
        // Round the bar clock's Wednesday 7 October, 21:04; the 10th is the Sintra trip the film's notes plan.
        store.events = [ClockEvent(title: "Call with Marco", start: at(7, 21, 30), end: at(7, 22, 0), colour: blue),
                        ClockEvent(title: "Design review", start: at(8, 10, 0), end: at(8, 11, 0), colour: blue),
                        ClockEvent(title: "Dentist", start: at(8, 16, 30), end: at(8, 17, 15), colour: green),
                        ClockEvent(title: "Sintra day trip", start: at(10, 0, 0), end: at(11, 0, 0), allDay: true, colour: green),
                        ClockEvent(title: "Train to Sintra", start: at(10, 9, 40), end: at(10, 10, 20), colour: green),
                        ClockEvent(title: "Lunch at the market", start: at(10, 13, 0), end: at(10, 14, 30), colour: green),
                        ClockEvent(title: "Launch week", start: at(13, 0, 0), end: at(14, 0, 0), allDay: true, colour: blue)]
        let look = Look.shared
        let canvas = Color(StyleTokens.of(look.style, theme: look.theme).colors.canvas)
        let readings = ClockRenders.sources(store).readings
        for (name, picked) in [("month", nil), ("day", at(10, 0, 0))] as [(String, Date?)] {
            let bar = BarItemsStore(defaults: UserDefaults(suiteName: testSuite())!) { [:] }
            bar.settings.clockEvents = true
            try writeRender(ClockPopover(store: bar, readings: readings, picked: picked) {}.styled(.barPopovers, look: look).pilotTheme(look: look)
                                .padding(24).background(canvas), to: dir.appendingPathComponent("\(name).png"), wait: 0.6)
        }
    }

    /// The link the browser shows, copied, and a café menu's code on a picture on the desktop.
    static let pageLink = "https://en.wikipedia.org/wiki/Tiling_window_manager"
    static let menuLink = "https://fieldandtide.example/menu"

    @Test("QR codes: Make on the copied link and Copy image's tip; a picture's code read through Hyper + right-click", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func qr() async throws {
        let dir = try Self.prepare("qr")
        try InstrumentPanelsRenders.render(QRMakeCard(text: Self.pageLink, copy: { _ in }, save: { _ in }), .hud, "make", in: dir)
        try InstrumentPanelsRenders.render(TipView(text: "Copied the QR code"), .hud, "tip-copied", in: dir)
        let code = try #require(QRCodes.image(Self.menuLink, module: 12))
        try #require(NSBitmapImageRep(cgImage: code).representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("menu-code.png"))
        // Hyper + right-click on menu.png: Pilot's actions for an image, "qr" typed, then the code's card.
        var picker = MenuNavigator(list: FileActionsMenu.rows(FileAction.list(for: [.image])), title: "menu.png")
        for (i, query) in ["", "q", "qr"].enumerated() {
            picker.query = query
            try await LineMenuRenders.render(Self.line(picker), "p\(i)", in: dir, wait: 0.3)
        }
        try InstrumentPanelsRenders.render(QRReadCard(text: Self.menuLink, subject: "From menu.png", link: QRCodes.link(Self.menuLink),
                                                      copy: {}, open: { _ in }, close: {}), .hud, "read", in: dir)
    }

    /// The note typed from Scratch, a line a frame.
    static let packing = ["# P", "# Pack for", "# Pack for Sintra", "# Pack for Sintra\n- [ ] Rain jacket",
                          "# Pack for Sintra\n- [ ] Rain jacket\n- [ ] Charger", "# Pack for Sintra\n- [ ] Rain jacket\n- [ ] Charger\n- [ ] Train tickets"]

    @Test("Quick notes: Scratch, a note typed, its format bar, a pasted picture, the list and a search", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func notes() throws {
        let dir = try Self.prepare("notes")
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-film-quick-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        _ = try store.load()
        let today = Calendar.current.startOfDay(for: .now)
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            Calendar.current.date(byAdding: DateComponents(day: -daysAgo, hour: hour, minute: minute), to: today)!
        }
        let seeded: [(id: String, text: String, edited: Date)] = [
            ("Scratch.md", "", at(0, 9, 0)),
            ("lisbon-weekend-100001.md", "# Lisbon weekend\n\n", at(0, 9, 12)),
            ("groceries-100002.md", "# Groceries\n- [ ] limes\n- [ ] coffee\n- [x] bread\n", at(0, 8, 40)),
            ("shop-ideas-100003.md", "# Ideas for the shop\nA tide table on the delivery page.\n", at(1, 18, 5)),
            ("reading-list-100004.md", "# Reading list\n- The Design of Everyday Things\n- Shape Up\n", at(2, 21, 30)),
            ("sintra-restaurants-100005.md", "# Sintra restaurants\nTascantiga, near the palace.\n", at(4, 12, 15)),
        ]
        for note in seeded {
            let url = folder.appending(path: note.id)
            try Data(note.text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: note.edited], ofItemAtPath: url.path)
        }
        let attachments = folder.appending(path: NoteAttachments.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let photo = try Self.env["PILOT_FILM_PHOTO"].map { try Data(contentsOf: URL(filePath: $0)) }
            ?? ClipboardTabsRenders.png(CGSize(width: 1200, height: 800), seed: 0)
        try photo.write(to: attachments.appending(path: "day-trip.jpg"))
        let id = "pack-for-sintra-100006.md"
        let pictured = Self.packing.last! + "\n\n![Day trip](attachments/day-trip.jpg)\n"
        // Each frame: the note's text (nil keeps Scratch), what the model does, and a selection for the format bar.
        var frames: [(name: String, text: String?, step: (NotesModel) -> Void, select: String?)] = [("t0", nil, { _ in }, nil)]
        frames += Self.packing.enumerated().map { (String(format: "t%02d", $0.offset + 1), $0.element, { _ in }, nil) }
        frames += [("format", Self.packing.last!, { _ in }, "Train tickets"), ("picture", pictured, { _ in }, nil),
                   ("list", pictured, { $0.focusList() }, nil)]
        frames += ["s", "si", "sin", "sint", "sintra"].enumerated().map { i, query in
            (String(format: "s%d", i + 1), pictured, { $0.focusList(); $0.queryField = query }, nil)
        }
        for frame in frames {
            if let text = frame.text {
                let url = folder.appending(path: id)
                try Data(text.utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: at(0, 9, 30)], ofItemAtPath: url.path)
            }
            let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
            model.reload()
            model.open(frame.text == nil ? NoteStore.scratch : id)
            frame.step(model)
            let panel = HUD.makePanel(NotesPanelView(model: model).frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height),
                                      surface: .notes)
            defer { panel.close() }
            let content = try #require(panel.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            // The caret at the note's end (or on the format bar's words) while it is typed; the list keeps its own focus.
            if frame.name != "list", !frame.name.hasPrefix("s"), let editor = NotesMarkdownRenders.editors(in: content).first(where: \.isEditable) {
                panel.makeFirstResponder(editor)
                let text = editor.string as NSString
                editor.setSelectedRange(frame.select.map { text.range(of: $0) } ?? NSRange(location: text.length, length: 0))
                editor.restyle()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            content.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(content, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(frame.name).png"))
        }
    }

    @Test("Folder designs: Hyper + right-click on a folder, Folder design…, the designs walked to Code; the folder before and after",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func folders() async throws {
        let dir = try Self.prepare("folders")
        let folder = URL(filePath: NSHomeDirectory()).appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var actions = MenuNavigator(list: FileActionsMenu.rows(FileAction.list(for: [.folder])), title: "Projects")
        try await LineMenuRenders.render(Self.line(actions), "a0", in: dir, wait: 0.4)
        let design = try #require(actions.rows.firstIndex { $0.title == FileAction.folderDesign.title })
        for step in 0..<design {
            _ = actions.handle(.down)
            try await LineMenuRenders.render(Self.line(actions), "a\(step + 1)", in: dir, wait: 0.3)
        }
        // The picker FolderDesigns.pick opens, titled with the folders' count.
        var designs = MenuNavigator(list: FolderDesignSource([folder], inGit: []).rows(), title: "1 folder")
        try await LineMenuRenders.render(Self.line(designs), "d0", in: dir, wait: 0.6)
        let code = try #require(designs.rows.firstIndex { $0.title == "Code" })
        for step in 0..<code {
            _ = designs.handle(.down)
            try await LineMenuRenders.render(Self.line(designs), "d\(step + 1)", in: dir, wait: 0.3)
        }
        // The folder's icon before and after, each at 512 px on no ground.
        for id in [FolderDesign.plain, "code"] {
            let rep = try FolderDesignsRenders.strip([(try #require(FolderDesigns.art(id)), 512)], ground: .clear, gap: 0)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("art-\(id).png"))
        }
    }

    @Test("Lock keyboard's screen at the film's 1920, Esc up and Esc held", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func keyboardLock() throws {
        let dir = try Self.prepare("lock")
        let since = Date(timeIntervalSinceReferenceDate: 783_000_000), now = since.addingTimeInterval(12)
        for (name, escape) in [("up", nil), ("held", now.addingTimeInterval(-1.5))] as [(String, Date?)] {
            let model = KeyboardLockModel(since: since, escapeSince: escape, now: { now })
            let panel = KeyboardLockController.makePanel(KeyboardLockView(model: model, glass: false) {},
                                                         frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), look: Look.shared)
            defer { panel.close() }
            let content = try #require(panel.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            content.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(content, scale: 1))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// Cut 4's video editor (Sven: no recording of his own): a made-up recording (PILOT_FILM_RECORDING, a clip of the
    /// billing page with three clicks) and its pointer track, opened as VideoEditor.open does: the zooms its clicks
    /// suggest, one picked, then stretched, then a gradient backdrop with the panel open. The preview's AVPlayerLayer is
    /// composited by the window server and draws nothing into a view snapshot, so the stage comes out empty and the film
    /// lays the recording's own frames into it.
    @Test("The video editor on a made-up recording: its zooms from the clicks, one picked and stretched, a backdrop",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_FILM_RECORDING"] != nil))
    func videoEditor() async throws {
        let dir = try Self.prepare("video")
        let source = URL(fileURLWithPath: try #require(Self.env["PILOT_FILM_RECORDING"]))
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Movies/\(source.lastPathComponent)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        let pointers = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "pilot-film-pointer")
        try FileManager.default.createDirectory(at: pointers, withIntermediateDirectories: true)
        let clicks = [(1.6, 1678.0, 594.0), (5.0, 1676.0, 752.0), (8.4, 1584.0, 326.0)].map { CursorTrack.Point(t: $0.0, x: $0.1, y: $0.2) }
        try CursorTrack(moves: [CursorTrack.Point(t: 0, x: 1500, y: 1000)] + clicks, clicks: clicks).save(for: url, in: pointers)
        let model = VideoEditorModel(url: url)
        defer { model.close() }
        await model.load(pointerFolder: pointers)
        try #require(model.loaded, "\(model.failed ?? "not loaded")")
        let look = Look.shared
        func shoot(_ name: String) throws {
            try writeRender(VideoEditorView(model: model).styled(.hud, look: look).pilotTheme(look: look).frame(width: 1280, height: 800),
                            to: dir.appendingPathComponent("\(name).png"), wait: 0.8)
        }
        try #require(!model.edit.zooms.isEmpty)
        try shoot("e1-zooms")
        let first = try #require(model.edit.zooms.first)
        model.selected = first.id
        model.show(first.start + 0.3)
        try shoot("e2-picked")
        model.stretchZoom(first.id, end: first.end + 1.2, live: false)
        try shoot("e3-stretched")
        model.setBackdrop(Backdrop(fill: .gradient([0x2BC4F0, 0x6E5BF2, 0xC6F432])))
        model.panelOpen = true
        model.selected = nil
        try shoot("e4-backdrop")
    }

    /// Cut 4's Pilot window (Sven: show the app itself): Workspaces with the film's three, Tiling at the film's gaps, Stats,
    /// Update & Clean with an Update all still going and its earlier runs, and Reports, at the film's floating
    /// window size, seeded as WindowPagesRenders seeds them (fakes; nothing reaches the tiler or the network).
    @Test("Pilot's window at the film's size: Workspaces, Tiling's gaps, Stats, Update & Clean with a run going, Reports",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func pages() throws {
        let dir = try Self.prepare("pages")
        let reports = PilotFolder.support.appending(path: "Reports")
        try? FileManager.default.removeItem(at: reports)
        let store = try ReportsPageRenders.seed(reports)
        let rows = [UpdateRow(item: .package(Package(.cask, "google-chrome")!), from: "141.0.7390.66", to: "142.0.7444.52"),
                    UpdateRow(item: .package(Package(.formula, "node")!), from: "24.9.0", to: "24.10.0")]
        _ = try store.begin(RunReport(kind: .update, title: "Update all", command: "brew upgrade --cask google-chrome && brew upgrade --formula node",
                                      started: .now, items: RunReport.update("", command: "", rows: rows, home: NSHomeDirectory()).items))
        // The film's workspaces: the browser and Ghostty on 1, Notes on 2, Music on 4.
        var presets = WorkspacePresetStore.Contents()
        let app = { (bundle: String, name: String) in WorkspacePreset.App(bundleId: bundle, name: name, percent: 50) }
        presets.assign(WorkspacePreset(name: "Work", apps: [app("com.apple.Safari", "Safari"), app("com.mitchellh.ghostty", "Ghostty")], layout: .columns), to: "1")
        presets.assign(WorkspacePreset(name: "Writing", apps: [app("com.apple.Notes", "Notes")], layout: .mainStack), to: "2")
        presets.assign(WorkspacePreset(name: "Music", apps: [app("com.apple.Music", "Music")], layout: nil), to: "4")
        try FileManager.default.createDirectory(at: WorkspacePresetStore.standard.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(WorkspacePresetStore.standard.url.path.hasPrefix(NSHomeDirectory()), "the presets would land outside the moved home")
        try WorkspacePresetStore.standard.save(presets)
        // The film's gaps on Tiling (cut 7): an edit goes to the tiler, which a render never runs, so the block takes them
        // the way a first launch does, from an AeroSpace config in the moved home's Pilot folder, removed once read.
        let carried = URL(fileURLWithPath: PilotBlockStore.path)
        try #require(carried.path.hasPrefix(NSHomeDirectory()), "the carried config would land outside the moved home")
        try FileManager.default.createDirectory(at: carried.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (i, o) = (Self.gaps.inner, Self.gaps.outer)
        try "[gaps]\ninner.horizontal = \(i)\ninner.vertical = \(i)\nouter.left = \(o)\nouter.bottom = \(o)\nouter.top = \(o)\nouter.right = \(o)\n"
            .write(to: carried, atomically: true, encoding: .utf8)
        let engine: Engine
        do {
            defer { try? FileManager.default.removeItem(at: carried) }
            engine = try HomeRenders.engine()
        }
        try #require(engine.pilotBlock.block.gaps == PilotBlock.Gaps(inner: i, outer: o), "gaps \(engine.pilotBlock.block.gaps)")
        StatsRenders.seed(SystemSampler.shared)
        ActivityMonitor.shared.seed(ActivityRenders.seeded, quitting: [])
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        AppWindowController.applyLook(Look.shared, to: window)
        func shoot(_ place: AppPlace, _ name: String) throws {
            window.setContentSize(NSSize(width: 1200, height: 780))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        try shoot(AppPlace(.tiling), "tiling")
        for (place, name) in [(AppPlace(.workspaces), "workspaces"), (AppPlace(.stats), "stats"),
                              (AppPlace(.upkeep), "upkeep"), (AppPlace(.reports), "reports"), (AppPlace(.activity), "activity")] {
            try shoot(place, name)
        }
    }

    /// Film v4 (P89, Sven's script, 2026-11-03), chapters 2 and 3 at the film's window size: Tiling's Gaps block as the
    /// Outer slider is dragged from 32 to 64 and then Inner from 20 to 8, a still per step (each step a fresh engine that
    /// reads its gaps as a first launch does, from a carried config in the moved home, its saved block cleared: an edit goes to the tiler, which a
    /// render never runs); and the Menu bar page with the top bar's strip and tray, as Volume moves to the left side, then
    /// Keep awake is added, then Wi-Fi taken off, with the film's 1920 top bar for each. The 1920 bar reads fakes; the page's strip
    /// reads the engine's own readers for the items it draws (this Mac's volume and Wi-Fi signal, never a network's name), and its
    /// clock this Mac's time. Nothing reaches the tiler.
    @Test("Film v4: Tiling's gaps dragged, and the Menu bar page as an item moves sides, one is added and one taken off",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func filmV4() async throws {
        let dir = try Self.prepare("v4")
        StatsRenders.seed(SystemSampler.shared)
        let carried = URL(fileURLWithPath: PilotBlockStore.path)
        try #require(carried.path.hasPrefix(NSHomeDirectory()), "the carried config would land outside the moved home")
        try FileManager.default.createDirectory(at: carried.deletingLastPathComponent(), withIntermediateDirectories: true)
        func engine(inner i: Int, outer o: Int) throws -> Engine {
            // A saved block wins over the carried file: each step starts from none, as a first launch.
            UserDefaults.pilot().removeObject(forKey: "pilotBlock")  // PilotBlockStore.key, private
            try "[gaps]\ninner.horizontal = \(i)\ninner.vertical = \(i)\nouter.left = \(o)\nouter.bottom = \(o)\nouter.top = \(o)\nouter.right = \(o)\n"
                .write(to: carried, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: carried) }
            let engine = try HomeRenders.engine()
            try #require(engine.pilotBlock.block.gaps == PilotBlock.Gaps(inner: i, outer: o), "gaps \(engine.pilotBlock.block.gaps)")
            return engine
        }
        func shoot(_ engine: Engine, _ place: AppPlace, _ name: String) throws {
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
            defer { window.close() }
            let frame = try #require(window.contentView?.superview)
            AppWindowController.applyLook(Look.shared, to: window)
            window.setContentSize(NSSize(width: 1200, height: 780))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        let steps = [32, 40, 48, 56, 64].map { (inner: Self.gaps.inner, outer: $0) } + [16, 12, 8].map { (inner: $0, outer: 64) }
        for (n, g) in steps.enumerated() {
            try shoot(try engine(inner: g.inner, outer: g.outer), AppPlace(.tiling), String(format: "tiling-%02d", n))
        }

        // The Menu bar page on the top bar holding the film's bar items (bars()), then the three edits a person makes by
        // dragging: Volume to the left side, Keep awake added, Wi-Fi taken off; the film's 1920 bar for each, as bars() draws it.
        let store = BarItemsStore.shared
        let before = (store.settings, store.pagePlacement)
        defer { (store.settings, store.pagePlacement) = before }
        var s = BarSettings.defaults
        for (kind, style) in [(BarKind.cpu, BarStyle.text), (.memory, .text), (.network, .text), (.volume, .iconPercent), (.wifi, .icon)] {
            s.set(kind, on: true)
            s.set(kind, style: style)
        }
        for kind in [BarKind.otherApps, .modes, .capture, .timer] { s.set(kind, on: false) }
        // As the film's bar has them (bars()): the extensions before Volume, the clock at the right end.
        s.move(.extensions, to: try #require(s.entries.firstIndex { $0.kind == .volume }))
        s.set(.clock, side: .right)
        store.pagePlacement = .topBar
        // The top bar on, as the film's desktop has it: the controller reads its switch at init and opens its windows
        // only from Engine.launch, which a render never calls.
        UserDefaults.pilot().set(try JSONEncoder().encode(TopBarSwitch(isOn: true, savedAutohide: false)), forKey: "topBar.switch")
        defer { UserDefaults.pilot().removeObject(forKey: "topBar.switch") }
        let engine = try engine(inner: Self.gaps.inner, outer: Self.gaps.outer)
        let weather = try await Self.weatherBar()
        defer { try? FileManager.default.removeItem(at: weather.folder) }
        let bar = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                              readBattery: { nil }, readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                              watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        let monitors = try AeroMonitorWorkspace.parse(#"[{"monitor-id": 1, "monitor-name": "Studio", "workspace": "1"}]"#)
        let windows = try AeroWindow.parse(Self.windows(["1", "1", "2"]))
        let observers = EngineObservers()
        observers.tiler.seed(focused: "1", occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: monitors)
        // The page's own strip shows the film's workspaces too.
        engine.observers.tiler.seed(focused: "1", occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: monitors)
        var sources = BarSources(readings: bar, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), pilotTitle: { "1" })
        sources.extensionBar = weather.bar
        var moved = s
        moved.set(.volume, side: .left)
        var added = moved
        added.set(.keepAwake, on: true)
        var edited = added
        edited.set(.wifi, on: false)
        for (name, settings) in [("menubar-a", s), ("menubar-b", moved), ("menubar-b2", added), ("menubar-c", edited)] {
            store.settings = settings
            let sides = try #require(settings.preview(.topBar).top)
            let kinds = Set(sides.values.joined().flatMap(\.kinds))
            // The page's strip reads the engine's readers, only for the items it draws (bars() holds its fakes the same way).
            var live: Set<BarKind> = []
            engine.barSources.readings.hold(kinds, replacing: &live)
            defer { engine.barSources.readings.hold([], replacing: &live) }
            try shoot(engine, AppPlace(.menuBar), name)
            var held: Set<BarKind> = []
            bar.hold(kinds, replacing: &held)
            defer { bar.hold([], replacing: &held) }
            try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: Look.shared).frame(width: 1920, height: 32),
                            to: dir.appendingPathComponent("bar-\(name).png"), wait: 0.8)
        }
    }

    /// Film v4's AI chapter (P89): what the AI can do to Pilot itself. AI › Chat in the film's 1200 by 780 window with Claude
    /// Code signed in (AIRenders' fakes): a / typed opens the Skills list (PILOT_RESOURCES=Packaging, or it is empty); the
    /// order typed a word at a time after /layouts; the agent's turn reading the setup with pilot commands, then waiting on
    /// `pilot plan apply` as its plan card asks; and the turn once Apply was pressed. Fake runner and gate: nothing runs.
    @Test("Film v4: AI › Chat's Skills, a workspace asked for with /layouts, its plan card and the plan applied",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func filmV4AI() async throws {
        let dir = try Self.prepare("v4-ai")
        let engine = try HomeRenders.engine()
        let talking = try AIRenders.settings(picked: .claudeCode)
        await talking.refreshCLIs()
        let typing = AIChatModel()
        let box = AIRenders.Box(settings: talking, chat: typing)
        var sources = AIPageSources()
        sources.send = {}
        sources.settings = { box.settings }
        sources.chat = { box.chat }
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.aiPageSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        AppWindowController.applyLook(Look.shared, to: window)
        func shot(_ name: String) throws {
            window.setContentSize(NSSize(width: 1200, height: 780))
            model.go(AppPlace(.binds))
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            model.go(AppPlace(.ai))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        typing.draft = "/"
        try shot("skills")
        let words = Self.layoutOrder.split(separator: " ")
        for i in 1...words.count {
            typing.draft = words.prefix(i).joined(separator: " ")
            try shot(String(format: "o%02d", i))
        }
        typing.draft = ""

        let plan = ControlPlan()
        for (i, draft) in Self.layoutPlan.enumerated() { _ = try plan.add(draft, request: ControlRequest(verb: "set", args: ["row\(i)", "\(i)"])) }
        let planning = AIChatModel()
        planning.route = "Claude Code · Sonnet"
        planning.viewers += 1
        planning.send(Self.layoutOrder, acting: .success(Self.layoutTurn(applied: false)))
        await AIChatAgentTests.rowOpen(planning)
        let ask = plan.ask
        Task { _ = await planning.decide(ask, program: "pilot, from claude") }
        try #require(await AIChatAgentTests.asked(planning) != nil)
        box.chat = planning
        try shot("plan")
        let done = AIChatModel()
        done.route = "Claude Code · Sonnet"
        done.viewers += 1
        done.send(Self.layoutOrder, acting: .success(Self.layoutTurn(applied: true)))
        await AIChatAgentTests.settled(done)
        box.chat = done
        try shot("done")
        for chat in [typing, planning, done] { chat.clear() }
    }

    static let layoutOrder = "/layouts Ghostty left, Safari right on 3"

    /// The layouts skill's change (Packaging/skills/layouts): workspace 3's preset, its two apps in columns.
    static let layoutPlan: [ControlPlan.Draft] = [.init("Add to workspace-presets", old: "–", new: "3: Ghostty, Safari · columns")]

    /// The agent's turn on the layouts skill: it reads what is there, plans the preset, then `pilot plan apply` waits on its
    /// card; `applied`, the same turn once Apply was pressed, with its answer and the reply.
    nonisolated static func layoutTurn(applied: Bool) -> AIChatModel.Turn {
        { _, event throws(QuickAI.Failure) in
            for (i, command) in ["pilot list workspaces", "pilot list apps",
                                 "pilot add workspace-presets --workspace 3 --apps com.mitchellh.ghostty,com.apple.Safari --layout columns --plan"].enumerated() {
                event(.toolCall(id: "l\(i)", command: command))
                event(.toolResult(id: "l\(i)", output: "{}", isError: false))
            }
            event(.text("Workspace 3 opens Ghostty on the left and Safari on the right, in columns. Here is the plan."))
            event(.toolCall(id: "apply", command: "pilot plan apply"))
            guard applied else {
                try? await Task.sleep(for: .seconds(60))
                return AIChat.Reply("")
            }
            event(.toolResult(id: "apply", output: #"{"applied":1}"#, isError: false))
            event(.text("Done. Hyper+3 now opens Ghostty and Safari side by side."))
            return AIChat.Reply("Done. Hyper+3 now opens Ghostty and Safari side by side.")
        }
    }

    /// Cut 5 (Sven's cut 4 notes, Q516: Dusk throughout): the views earlier cuts took from other render tests, drawn again
    /// here in the film's theme (the dictation pill, the selection pill and its bubble, the ring, the bind editor's picker, the
    /// capture editor's states, Weather's popover), and the new shots' own: Keys › Mouse with a side button given a job and Hyper's
    /// mouse binds, Snippets before and after one is added, and AI › Setup on your own key. Fakes throughout: no Keychain,
    /// mouse, network or this Mac's snippets.
    @Test("Cut 5's borrowed views redrawn in the film's theme, Mouse, Snippets and AI › Setup", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func dusk() async throws {
        let dir = try Self.prepare("void")
        let look = Look.shared
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        func png(_ rep: NSBitmapImageRep, _ name: String) throws {
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        func page(_ view: some View, _ name: String, width: CGFloat, height: CGFloat = 2000, on surface: StyleSurface, wait: Double = 0.6) throws {
            let ground = FilmGround { view.frame(width: width, height: height, alignment: .top) }.styled(surface, look: look).pilotTheme(look: look)
            try RestyledRenders.writeTrimmed(rendered(ground, wait: wait), from: 0, to: dir.appendingPathComponent("\(name).png"))
        }

        // Dictation's pill, listening then writing, as DictationOverlayRenders drives it, on the dark ground the film clears.
        let speech: [Double] = [0, 0.05, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 1, 0.5, 0.2, 0.35, 0.6, 0.3, 0.1, 0, 0.05, 0.2]
        for (name, writing) in [("dict-listening", false), ("dict-writing", true)] {
            let o = DictationOverlay(after: { _, _ in Watch {} }, shows: false)
            o.started(microphone: nil, words: false)
            o.levels(speech)
            if writing { o.writing() }
            try png(rendered(DictationOverlayView(overlay: o).padding(20).background(Color(white: 0.16)).pilotTheme(look: look)), name)
        }

        // The selection pill, its bubble, and the bubble with a rewrite, as SelectionBoxRenders draws them.
        try png(try #require(snapshot(drawing: SelectionPillView().padding(24).styled(.hud, look: look).pilotTheme(look: look))), "pill")
        let rewrite = "Can we move the design review to Thursday? Some of us are out Wednesday, and I'd like everyone to see the pricing options together."
        for (name, model) in [("pill-start", await SelectionBoxRenders.model([])),
                              ("pill-rewrite", await SelectionBoxRenders.model([("Make concise", SelectionPrompt.chips[2].instruction, rewrite)]))] {
            let view = SelectionBoxView(model: model).frame(width: SelectionBox.width, height: SelectionBox.height(started: model.started))
                .padding(24).styled(.quickAI, look: look).pilotTheme(look: look)
            try png(try #require(snapshot(drawing: view)), name)
            model.chat.clear()
        }

        // The ring, This window, its next-workspace wedge aimed, as RingRenders draws it.
        let engine = Engine()
        let ring = try #require(engine.rings.store.rings.rings.first)
        let controller = RingController(store: engine.rings.store)
        controller.label = { engine.action($0)?.label }
        var session = RingSession(wheel: [ring])
        session.pick(path: [], place: 1)
        try writeRender(RingView(model: controller.model(session, states: ["windows.toggleFloat": false], roles: [:])).styled(.menu, look: look)
                            .pilotTheme(look: look).padding(28), to: dir.appendingPathComponent("ring.png"))

        // Binds' editor on U: its kinds, then Ghostty picked, as BindEditorRenders' a1 and a3.
        let binds = try ToyboxBindsRenders().engine()
        binds.settings.overlayMode = .pick
        func finder(picked: String? = nil) -> BindFinder {
            let finder = BindFinder(query: "", scope: nil, picked: picked, ai: nil)
            finder.load(apps: AppsModule.installedApps(), actions: binds.bindActions)
            return finder
        }
        for (name, picked) in [("bind-a1", nil), ("bind-a3", "apps.open:com.mitchellh.ghostty")] as [(String, String?)] {
            let editor = BindEditor(action: nil, actions: binds.bindActions, startKey: Key("u"), windowHeight: 660, finder: finder(picked: picked))
            try png(BindEditorRenders.drawn(editor.environment(binds).styled(.page(.binds), look: look).pilotTheme(look: look)), name)
        }

        // The capture editor's states the film shows, as CaptureEditorRenders draws them.
        let capture = try #require(CaptureFixture.image())
        for (name, model) in CaptureEditorRenders.states(capture, tokens: tokens)
        where ["1-empty", "2-marks", "4-steps", "6-read", "8-backdrop", "9-eyedropper"].contains(name) {
            let size = EditorLayout.window(model.size, fit: 1, tokens: tokens)
            try png(CaptureEditorRenders.draw(CaptureEditorView(model: model), tokens: tokens, size: size, scale: 2), "editor-\(name)")
        }

        // Weather's popover, as its Omarchy look draws it.
        let folder = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let exts = folder.appending(path: "Extensions"), storage = ExtensionSurfaceTests.storage(folder)
        try ExtensionSurfaceTests.write("weather", title: "Weather", in: exts)
        let blocks = ExtensionSurfaceRenders.lineWeather
        let popover = ExtensionPopoverModel(id: "weather", folder: exts, storage: storage, run: { _, _, _ in .blocks(blocks) })
        await popover.open()
        let item = ExtensionBar.Item(id: "weather", title: "Weather", icon: "🌤️", hasPage: true, answer: nil, problem: nil)
        try writeRender(ExtensionPopoverView(item: item, model: popover).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
            .background(Color(tokens.colors.canvas)), to: dir.appendingPathComponent("weather-popover.png"), wait: 0.6)

        // Keys › Mouse (Sven's cut 4 note): a five-button mouse whose wheel click and Forward have jobs, and binds with Hyper held;
        // Back clicked, then given Next workspace.
        let mice = try HomeRenders.engine()
        let core = MouseKeys.Device(vendor: 1008, product: 3471, name: "HyperX Pulsefire Core")
        mice.binds.setMouse(MouseKeys.button(2), to: "media.playPause")
        mice.binds.setMouse(MouseKeys.media(17), to: "media.next", device: core, button: 5)
        mice.binds.setMouse(MouseKeys.underHyper(MouseKeys.button(2)), to: "windows.close")
        mice.binds.setMouse(MouseKeys.underHyper(MouseKeys.media(17)), to: "media.previous", device: core, button: 5)
        defer { for b in mice.binds.store.mouseBinds { mice.binds.setMouse(b.trigger, to: nil) } }
        let found = MouseButtons.Found(mice: [core], buttons: (2...4).map { MouseKeys.button($0) })
        typealias Shown = MouseButtonsBlocks.Shown
        func mouse(_ shown: Shown, _ spot: Int?, _ name: String) throws {
            try page(KitPage { MouseButtonsBlocks(shown: shown, mice: found, spot: spot) }.environment(mice), name, width: 928, on: .page(.binds))
        }
        try mouse(Shown(learn: .idle, target: nil), nil, "mouse-1-rest")
        try mouse(Shown(learn: .got(MouseKeys.button(3), device: nil), target: 4), 4, "mouse-2-back")
        mice.binds.setMouse(MouseKeys.button(3), to: "workspaces.next", button: 4)
        try mouse(Shown(learn: .idle, target: nil), 4, "mouse-3-bound")

        // Tools › Snippets (Sven's cut 4 note): three snippets, then the address added under ;addr and picked.
        let kept = [SnippetsEditorTests.commit, Snippet(name: "Greeting", keyword: ";hi", text: "Hi {argument},\n\nThanks for the quick reply."),
                    Snippet(name: "Sign-off", keyword: ";sig", text: "Best,\nAna Ribeiro")]
        let added = Snippet(name: "Address", keyword: ";addr", text: "12 Rua das Flores, 1200-195 Lisbon")
        for (name, list, picked) in [("snippets-1", kept, kept[0].id), ("snippets-2", kept + [added], added.id)] {
            let (library, store) = try SnippetsEditorTests.library(list)
            defer { try? FileManager.default.removeItem(at: store.url) }
            try page(SnippetsSettingsView(library: library, selected: picked), name, width: 793, on: .page(.snippets))
        }

        // AI › Setup on your own plan (Sven's cut 6 note): Claude Code and Codex installed but not signed in, nothing picked
        // that answers yet (ai-setup-1); then Claude Code signed in with its plan and picked, its test passed (ai-setup-2).
        // A fake Keychain, fake CLIs and no network; the CLIs are asked before the shot, so no line reads Checking….
        let claude = NSHomeDirectory() + "/.local/bin/claude", codex = "/opt/homebrew/bin/codex"
        for (name, signedIn) in [("ai-setup-1", false), ("ai-setup-2", true)] {
            let ai = AISettings(defaults: try #require(UserDefaults(suiteName: testSuite())), keys: AISettingsTests.FakeKeys(),
                                http: AISettingsTests.NoNetwork())
            ai.provider = signedIn ? .claudeCode : .anthropicAPI
            ai.checkCLI = { route in
                switch route {
                case .claudeCode: signedIn ? .signedIn(path: claude) : .signedOut(path: claude)
                case .codex: .signedOut(path: codex)
                default: .missing
                }
            }
            await ai.refreshCLIs()
            try page(AISetupPage(settings: ai, test: signedIn ? .passed : nil), name, width: 760, on: .page(.ai), wait: 1.5)
        }

        // Apps › Open with on the film's made-up defaults (FilmDefaultApps), never LaunchServices; every kind open (Sven's cut 6 note).
        let openWith = OpenWithPage(allKinds: true, kinds: DefaultAppsModel(system: FilmDefaultApps(), forget: { _ in }),
                                    editor: EditorChoice(defaults: try #require(UserDefaults(suiteName: testSuite())), installed: { _ in true }))
        try page(openWith, "open-with", width: 793, height: 3600, on: .page(.openWith))

        // Cut 6. The one Extensions list on the catalogue's test fixture: Ports installed, the rest to get. Never the network.
        let (catalogue, catalogueDir) = try ExtensionCatalogueModelTests.model()
        defer { try? FileManager.default.removeItem(at: catalogueDir) }
        await catalogue.open()
        await catalogue.install(try #require(catalogue.index?.entry("ports")))
        await catalogue.readInstalled()
        try page(ExtensionsPageView(onScreen: false, settings: await ExtensionCatalogueRenders.settings(catalogue), pick: "pomodoro").frame(height: 640),
                 "catalogue", width: 1000, on: .page(.extensions))
        // The selection pill with Summarise installed (Q481), and Capture text's tip on four lines of the billing page.
        try png(try #require(snapshot(drawing: SelectionPillView(summarise: true).padding(24).styled(.hud, look: look).pilotTheme(look: look))), "pill-summarise")
        let lines = ["Invoices", "1 Oct 2026  INV-0142  $12.00  Paid", "1 Sep 2026  INV-0131  $12.00  Paid", "1 Aug 2026  INV-0117  $12.00  Paid"]
            .map { ReadLine(text: $0, box: .zero) }
        try InstrumentPanelsRenders.render(TipView(text: CaptureText.said(lines)), .hud, "tip-capture-text", in: dir)
        // Weather's popover on Glass: no fill and no ring of its own, so the film lays the glass under it.
        let glass = (look.glass, look.transparency)
        (look.glass, look.transparency) = (true, 100)
        defer { (look.glass, look.transparency) = glass }
        try writeRender(ExtensionPopoverView(item: item, model: popover).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24),
                        to: dir.appendingPathComponent("weather-popover-glass.png"), wait: 0.6)
    }

    static let extensionOrder = "/extension list my open ports"
    nonisolated static let extensionFolder = "~/Library/Application Support/Pilot/Extensions/open-ports"
    nonisolated static let extensionReply = "Made **Open ports**: it lists each port a program listens on, with the program and its PID. "
        + "Type `open ports` in Hyper+Space. It lives in `~/Library/Application Support/Pilot/Extensions/open-ports`."

    /// The /extension skill's steps (Packaging/skills/extension), as the chat shows them: new, check, test, install.
    static let madeExtension: AIChatModel.Turn = { _, event throws(QuickAI.Failure) in
        event(.toolCall(id: "x1", command: #"pilot ext new open-ports --mode list --title "Open ports""#))
        event(.toolResult(id: "x1", output: extensionFolder, isError: false))
        event(.toolCall(id: "x2", command: "pilot ext test \(extensionFolder) --check"))
        event(.toolResult(id: "x2", output: "check passed: 1 command, list", isError: false))
        event(.toolCall(id: "x3", command: "pilot ext test \(extensionFolder)"))
        event(.toolResult(id: "x3", output: "list: 4 items in 0.21 s", isError: false))
        event(.toolCall(id: "x4", command: "pilot ext install \(extensionFolder)"))
        event(.toolResult(id: "x4", output: #"{"installed":"open-ports","commands":["Open ports"]}"#, isError: false))
        event(.text(extensionReply))
        return AIChat.Reply(extensionReply)
    }

    /// Cut 4's custom extension, made by the chat's /extension skill: the order typed, then the finished turn.
    @Test("The AI chat making an extension with /extension: the order typed, then made, tested and installed", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func makeExtension() async throws {
        let dir = try Self.prepare("extension")
        let look = Look.shared
        func shot(_ model: AIChatModel, _ name: String) async throws {
            let rep = try #require(try await snapshot(rendering: AIChatPanel.content(model, look: look)))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        let typing = AIChatModel()
        typing.route = "Claude Code · Sonnet"
        let words = Self.extensionOrder.split(separator: " ")
        for i in 0...words.count {
            typing.draft = words.prefix(i).joined(separator: " ")
            try await shot(typing, String(format: "t%02d", i))
        }
        let done = AIChatModel()
        done.route = "Claude Code · Sonnet"
        done.viewers += 1
        done.send(Self.extensionOrder, acting: .success(Self.madeExtension))
        await AIChatAgentTests.settled(done)
        try await shot(done, "done")
        for model in [typing, done] { model.clear() }
    }
}

/// The film's Mac for Apps › Open with (every kind shown since cut 7): TextEdit for text and Markdown, VS Code for code and
/// data files, Preview for pictures and PDFs, QuickTime for video, Music for audio, Archive Utility for archives, Safari for
/// web links and Mail for mail links. Never LaunchServices.
@MainActor
private final class FilmDefaultApps: DefaultAppsSystem {
    static let names = ["com.microsoft.VSCode": "Visual Studio Code", "com.apple.Safari": "Safari", "com.apple.TextEdit": "TextEdit",
                        "com.apple.Preview": "Preview", "com.apple.QuickTimePlayerX": "QuickTime Player", "com.apple.Music": "Music",
                        "com.apple.archiveutility": "Archive Utility", "com.apple.mail": "Mail"]
    static let code: Set = ["public.json", "public.yaml", "public.toml", "public.swift-source", "public.python-script",
                            "com.netscape.javascript-source", "public.shell-script", "public.c-source", "public.source-code"]
    func current(_ handler: DefaultHandler) -> String? {
        switch handler {
        case .url(let url): url.hasPrefix("mailto") ? "com.apple.mail" : "com.apple.Safari"
        case .contentType(let type):
            switch type {
            case _ where Self.code.contains(type): "com.microsoft.VSCode"
            case "com.adobe.pdf", "public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp", "public.svg-image":
                "com.apple.Preview"
            case "public.mpeg-4", "com.apple.quicktime-movie": "com.apple.QuickTimePlayerX"
            case "public.mp3", "public.mpeg-4-audio", "com.microsoft.waveform-audio", "org.xiph.flac": "com.apple.Music"
            case "public.zip-archive", "org.gnu.gnu-zip-archive", "public.tar-archive", "org.7-zip.7-zip-archive": "com.apple.archiveutility"
            default: "com.apple.TextEdit"
            }
        }
    }
    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)] { Self.names.sorted { $0.value < $1.value }.map { ($0.value, $0.key) } }
    func name(_ bundle: String) -> String { Self.names[bundle] ?? bundle }
    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws {}
}

/// A page on its style's ground, as the window's frame lays it.
private struct FilmGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
