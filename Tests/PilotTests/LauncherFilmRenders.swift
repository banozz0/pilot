#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The explainer video's launcher frames (SH23, round 4): the Hyper+Space menu as Line draws it in the film's theme (Void for film v2), solid, one
/// still per typed prefix of a query, so a composition can play the typing key by key (an offscreen panel catches only
/// the morph's first 50 ms, so the video replays LineMorph's timings between the stills); the clipboard panel that
/// Return opens, its pick moving down; the first look in five looks (cut 3); cut 4's file search
/// (a typo, the Files view and its filters), Update and Clean while they read and with their rows, and the extension the chat
/// made, opened; the top bar at 1920 wide, the video's screen; and film v4's (P89): an app's menu items found by typing, and
/// Cmd+K on an app's row. Built from LineMenuRenders' rows and windows, never this Mac's. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter LauncherFilmRenders`
extension SharedLook {
@MainActor
@Suite("Launcher film renders")
struct LauncherFilmRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Each sequence: its folder and the query typed one character at a time.
    static let sequences: [(name: String, query: String)] = [("clip", "clip"), ("calc", "22 km to mi"), ("notes", "notes"), ("cycle", "cycle"),
                                                              ("tz", "time in tokyo"), ("tr", "tr buenos días"),
                                                              ("colour", "#2bc4f0"), ("qn", "quick notes"), ("qr", "make qr"),
                                                              ("lock", "lock keyboard"), ("music", "music"), ("miss", "obsidian"),
                                                              ("typo", "invocie"), ("wall", "next wallpaper"), ("update", "update"),
                                                              ("clean", "clean"), ("stats", "stats"), ("ports", "open ports"),
                                                              ("gaps", "gaps"), ("summ", "summarise"), ("ctext", "capture text"),
                                                              ("ql", "gh pilot"), ("fix", "fix"), ("aloud", "read aloud")]

    /// Cut 3's "make it yours": the menu's first look in Instrument and Toybox, dark and light.
    static let looks: [(PilotStyle, String)] = [(.instrument, "void"), (.instrument, "porcelain"), (.instrument, "dracula"),
                                                (.toybox, "toybox-night"), (.toybox, "toybox")]

    @Test("The launcher's typed frames, the morph probe and the 1920 top bar", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme, glass) = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = (style, theme, glass) }
        // The film's look, Instrument in ExplainerFilmRenders.theme; glass draws nothing offscreen, so Solid.
        (look.style, look.themeID, look.glass) = (.instrument, ExplainerFilmRenders.theme, false)
        let root = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("launcher-film")
        let built = try LineMenuRenders.built()
        // The film's browser and Ghostty, open before Notes is.
        let windows = try AeroWindow.parse(ExplainerFilmRenders.windows(["1", "1"]))
        let day = Date(timeIntervalSince1970: 1_791_028_800)
        // Cut 4: an app's name lists its own commands right under it, above the offers (L19's catalogue, Q831); the extension the chat made is
        // installed by the time "open ports" is typed; the stats cards read a seeded sampler, never this Mac.
        let commands = try LineMenuRenders.withCommands(built)
        let ports = MenuEntry(title: "Open ports", target: .action("ext.open-ports.list"), home: nil, detail: "Open ports",
                              keywords: "ports listen network", icon: .command(emoji: "🔌"))
        // Summarise from the catalogue, installed: its list command at the root (pilot-extensions, summarise 1.1.0).
        let summarise = MenuEntry(title: "Summarise", target: .action("ext.summarise.summarise"), home: nil, detail: "Summarise",
                                  keywords: "summary youtube page document", icon: .command(emoji: "📝"))
        let sampler = SystemSampler()
        StatsRenders.seed(sampler)
        StatsStrip.sampler = sampler
        func model(_ query: String, entries: [MenuEntry]? = nil) -> MenuModel {
            var nav = MenuNavigator(entries: entries ?? built)
            nav.query = query
            nav.provide(.window, MenuEntries.windows(windows, excluding: nil))
            nav.provide(.answer, RootAnswers.entries(for: query, now: day))
            // Translate's answer once the words are typed, the card LineMenuRenders shows (Apple's Translation runs on the Mac, not here).
            if query == "tr buenos días" { nav.provide(.answer, home: .translate, [AnswerCardRenders.translation]) }
            nav.provideSettings(query)
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.windows = windows
            m.ownKey = "Hyper+Space"
            return m
        }
        for sequence in Self.sequences {
            let dir = root.appendingPathComponent(sequence.name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let chars = Array(sequence.query)
            let entries = sequence.name == "music" ? commands : sequence.name == "ports" ? built + [ports]
                : sequence.name == "summ" ? built + [summarise] : built
            for i in 0...chars.count {
                try await LineMenuRenders.render(model(String(chars[..<i]), entries: entries), String(format: "k%02d", i), in: dir, wait: 0.3)
            }
        }

        try await Self.files(built, windows: windows, in: root.appendingPathComponent("files"))
        try await Self.upkeep(built, in: root.appendingPathComponent("upkeep"))
        try await Self.ports(in: root.appendingPathComponent("ports-list"))
        try await Self.summariseList(in: root.appendingPathComponent("summarise-list"))
        try await Self.emoji(built, in: root.appendingPathComponent("emoji"))

        let looks = root.appendingPathComponent("looks")
        try FileManager.default.createDirectory(at: looks, withIntermediateDirectories: true)
        for (s, theme) in Self.looks where PilotTheme.named(theme) != nil {
            (look.style, look.themeID) = (s, theme)
            try await LineMenuRenders.render(model(""), "\(s.rawValue)-\(theme)", in: looks, wait: 0.4)
        }
        (look.style, look.themeID) = (.instrument, ExplainerFilmRenders.theme)

        // Cut 6: the menu on Glass, its root and an app's search; offscreen Glass draws no material, so the film lays it under.
        let onGlass = root.appendingPathComponent("glass")
        try FileManager.default.createDirectory(at: onGlass, withIntermediateDirectories: true)
        let transparency = look.transparency
        (look.glass, look.transparency) = (true, 100)
        try await LineMenuRenders.render(model(""), "root", in: onGlass, wait: 0.4)
        try await LineMenuRenders.render(model("music", entries: commands), "music", in: onGlass, wait: 0.4)
        (look.glass, look.transparency) = (false, transparency)

        // Return on Clipboard history: the panel it opens, then Down twice, over copies a stranger might have.
        let clips = root.appendingPathComponent("clipboard")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-film-clips-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try Self.store(at: db)
        let panelModel = PanelModel(store: store)
        for step in 0...2 {
            if step > 0 { panelModel.move(1) }
            try #require(try ClipboardTabsRenders.render(ClipboardPanelView(model: panelModel, returnCopies: false)).representation(using: .png, properties: [:]))
                .write(to: clips.appendingPathComponent(String(format: "c%02d.png", step)))
        }

        // The top bar across the video's 1920-point screen, seeded as InstrumentTopBarRenders seeds it.
        StatsRenders.seed(SystemSampler.shared)
        let observers = EngineObservers()
        let barWindows = try AeroWindow.parse(InstrumentTopBarRenders.windows)
        observers.tiler.seed(focused: "1", occupied: OccupiedWorkspace.list(barWindows), windows: barWindows,
                             perMonitor: try AeroMonitorWorkspace.parse(InstrumentTopBarRenders.monitors))
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            observers.seed(focusedApp: finder, windowTitle: "Downloads")
        }
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { nil }, readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                                   watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        let sources = BarSources(readings: readings, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), pilotTitle: { "1" })
        let sides = InstrumentTopBarRenders.sides()
        var held: Set<BarKind> = []
        readings.hold(Set(sides.values.joined().flatMap(\.kinds)), replacing: &held)
        defer { readings.hold([], replacing: &held) }
        try writeRender(InstrumentTopBarRenders.Bar(sides: sides, sources: sources, look: look).frame(width: 1920, height: 32),
                        to: root.appendingPathComponent("bar-1920.png"), wait: 0.8)
    }

    /// Film v4 (P89, Sven's script, 2026-11-03): the launcher's depth. "new tab" typed with the browser in front, its own
    /// menu items listed (a made-up browser's menu bar, never this Mac's), then Cmd+K on Ghostty's row and Down through
    /// its actions; each still a key, as `render` makes the typed frames.
    @Test("Film v4: an app's menu items found by typing, and Cmd+K on an app's row walked down", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func filmV4() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme, glass) = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = (style, theme, glass) }
        (look.style, look.themeID, look.glass) = (.instrument, ExplainerFilmRenders.theme, false)
        let root = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("launcher-film")
        let built = try LineMenuRenders.built()
        let windows = try AeroWindow.parse(ExplainerFilmRenders.windows(["1", "1"]))
        let browser = [
            MenuItemNode(title: "File", enabled: true, children: [
                MenuItemNode(title: "New Tab", enabled: true, char: "T", modifiers: 0),
                MenuItemNode(title: "New Window", enabled: true, char: "N", modifiers: 0),
                MenuItemNode(title: "New Private Window", enabled: true, char: "N", modifiers: 1),
                MenuItemNode(title: "Close Tab", enabled: true, char: "W", modifiers: 0),
            ]),
            MenuItemNode(title: "View", enabled: true, children: [MenuItemNode(title: "Show All Tabs", enabled: true, char: "\\", modifiers: 1)]),
            MenuItemNode(title: "History", enabled: true, children: [MenuItemNode(title: "Reopen Closed Tab", enabled: true, char: "T", modifiers: 1)]),
            MenuItemNode(title: "Window", enabled: true, children: [MenuItemNode(title: "Move Tab to New Window", enabled: true)]),
        ]
        let items = MenuItemSearch.entries(browser, bundle: "com.apple.Safari", app: "Safari")
        func nav(_ query: String) -> MenuNavigator {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.provide(.window, MenuEntries.windows(windows, excluding: nil))
            nav.provide(.menuItem, items)
            return nav
        }
        for (name, query) in [("menuitems", "new tab"), ("appk", "ghostty")] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let chars = Array(query)
            for i in 0...chars.count {
                try await LineMenuRenders.render(Self.line(nav(String(chars[..<i])), windows: windows), String(format: "k%02d", i), in: dir, wait: 0.3)
            }
        }
        // Cmd+K on Ghostty's row (running, so Quit and Force quit too), then Down through the list.
        let dir = root.appendingPathComponent("appk")
        var actions = nav("ghostty")
        _ = actions.handle(.commandK)
        try await LineMenuRenders.render(Self.line(actions, windows: windows), "a00", in: dir, wait: 0.5)
        for step in 1...5 {
            _ = actions.handle(.down)
            try await LineMenuRenders.render(Self.line(actions, windows: windows), String(format: "a%02d", step), in: dir, wait: 0.3)
        }
    }

    static func line(_ nav: MenuNavigator, windows: [AeroWindow] = []) -> MenuModel {
        let m = MenuModel(nav: nav)
        m.layout = .line
        m.windows = windows
        m.ownKey = "Hyper+Space"
        return m
    }

    /// Cut 4's file search (Sven: how far it goes): "invocie", a typo, as the index forgives it (pilot-files, typo.rs: the
    /// index is not running offscreen, so its hits are given here as it answers them), in the Files view with the first
    /// invoice's preview; then `kind:pdf`, then `from:mail`. Real files in the moved home, so the preview pane reads one.
    static func files(_ built: [MenuEntry], windows: [AeroWindow], in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let home = NSHomeDirectory()
        let invoices = URL(fileURLWithPath: home).appending(path: "Documents/Invoices")
        try FileManager.default.createDirectory(at: invoices, withIntermediateDirectories: true)
        for (name, total) in [("Invoice INV-0142.pdf", "€1,240.00"), ("Invoice INV-0131.pdf", "€980.00")] {
            try Self.invoicePDF(name.replacingOccurrences(of: ".pdf", with: ""), total: total, to: invoices.appending(path: name))
        }
        let template = URL(fileURLWithPath: home).appending(path: "Documents/Templates/invoice-template.pages")
        try FileManager.default.createDirectory(at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("template".utf8).write(to: template)
        let day = Date(timeIntervalSince1970: 1_791_028_800)
        let pdfs = [FileSearch.Hit(path: invoices.appending(path: "Invoice INV-0142.pdf").path, edited: day.addingTimeInterval(-86_400), from: "mail.google.com"),
                    FileSearch.Hit(path: invoices.appending(path: "Invoice INV-0131.pdf").path, edited: day.addingTimeInterval(-2_678_400), from: "mail.google.com")]
        let other = [FileSearch.Hit(path: template.path, edited: day.addingTimeInterval(-9_000_000), from: nil)]
        // The root search for the typo, Down to its Search files row: Return opens the Files view on it.
        var root = MenuNavigator(entries: built)
        root.query = "invocie"
        for _ in 0..<3 { _ = root.handle(.down) }
        try await LineMenuRenders.render(Self.line(root, windows: windows), "f0-search-files", in: dir, wait: 0.3)
        for (name, query, hits) in [("f1-typo", "invocie", pdfs + other), ("f2-kind", "invocie kind:pdf", pdfs), ("f3-from", "invocie kind:pdf from:mail", pdfs)] {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.show(.file)
            nav.provide(.file, MenuEntries.files(hits, home: home))
            try await LineMenuRenders.render(Self.line(nav, windows: windows), name, in: dir, wait: 1.5)
        }
    }

    /// A one-page invoice, drawn as a PDF, for the preview pane.
    static func invoicePDF(_ title: String, total: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let big = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 30, weight: .semibold)]
        let small = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray]
        NSAttributedString(string: "Northwind", attributes: big).draw(at: CGPoint(x: 56, y: 760))
        NSAttributedString(string: title, attributes: small).draw(at: CGPoint(x: 56, y: 730))
        for (i, line) in ["Design retainer, October", "Illustrations, 4", "VAT 18%"].enumerated() {
            NSAttributedString(string: line, attributes: small).draw(at: CGPoint(x: 56, y: 640 - CGFloat(i) * 30))
        }
        NSAttributedString(string: "Total due  \(total)", attributes: big).draw(at: CGPoint(x: 56, y: 500))
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()
    }

    /// Cut 4's Update and Clean (Sven: they keep running, and the menu shows how far): each branch while it reads, then
    /// its rows, version to version for Update, what Mole would remove for Clean; the tips when the menu was closed.
    static func upkeep(_ built: [MenuEntry], in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = [UpdateRow(item: .macOS(label: "macOS Tahoe 26.1-25B78", title: "macOS Tahoe 26.1", restart: true), from: "26.0.1", to: "26.1"),
                    UpdateRow(item: .appStore(id: "497799835", name: "Xcode"), from: "26.0", to: "26.1"),
                    UpdateRow(item: .package(Package(.cask, "google-chrome")!), from: "141.0.7390.66", to: "142.0.7444.52"),
                    UpdateRow(item: .package(Package(.formula, "node")!), from: "24.9.0", to: "24.10.0"),
                    UpdateRow(item: .package(Package(.formula, "ffmpeg")!), from: "8.0", to: "8.0.1"),
                    UpdateRow(item: .npm("@anthropic-ai/claude-code", prefix: "/opt/homebrew"), from: "2.0.1", to: "2.0.5")]
        var update = MenuNavigator(entries: built, branch: .update)
        try await LineMenuRenders.render(Self.line(update), "u0-reading", in: dir, wait: 0.5)
        update.provide(.package, home: .update, UpdateList.entries(rows, includeSelfUpdating: true, masInstalled: true, recommend: false))
        try await LineMenuRenders.render(Self.line(update), "u1-rows", in: dir, wait: 0.5)
        var clean = MenuNavigator(entries: built, branch: .clean)
        try await LineMenuRenders.render(Self.line(clean), "c0-reading", in: dir, wait: 0.5)
        let preview = CleanPreview.parse("➤ Browsers\n  → Safari cache · 1.20GB dry\n  → Chrome cache · 1.73GB dry\n➤ Developer tools\n"
            + "  → Xcode DerivedData · 4.20GB dry\n  → npm cache · 820MB dry\n➤ System\n  → Logs · 310MB dry\n\nPotential space: 8.26GB | Items: 5")
        clean.provide(.action, home: .clean, CleanMenu.entries(preview, mole: true))
        try await LineMenuRenders.render(Self.line(clean), "c1-rows", in: dir, wait: 0.5)
        // Return on Update all, then on Clean: InstallModule.confirm's two rows, what will run under the first.
        if let command = UpdateList.all(rows, includeSelfUpdating: true) {
            let confirm = MenuNavigator(list: [MenuEntry(title: "Update all", target: .action("install.go"), detail: command),
                                               MenuEntry(title: "Cancel", target: .action("install.cancel"))], title: nil)
            try await LineMenuRenders.render(Self.line(confirm), "u2-confirm", in: dir, wait: 0.5)
        }
        let cleanConfirm = MenuNavigator(list: [MenuEntry(title: "Clean", target: .action("install.go"), detail: Mole.clean),
                                                MenuEntry(title: "Cancel", target: .action("install.cancel"))], title: nil)
        try await LineMenuRenders.render(Self.line(cleanConfirm), "c2-confirm", in: dir, wait: 0.5)
        if let tip = UpdateList.tip(rows, includeSelfUpdating: true, showing: false) {
            try InstrumentPanelsRenders.render(TipView(text: tip), .hud, "tip-update", in: dir)
        }
        if let tip = CleanMenu.tip(preview, showing: false) { try InstrumentPanelsRenders.render(TipView(text: tip), .hud, "tip-clean", in: dir) }
    }

    /// Summarise opened from the menu (Sven's cut 4 note: show the link going in): empty, it offers the copied link; with the
    /// link pasted in its search, the row its program prints for a typed page (pilot-extensions, summarise main.py, summarise).
    static func summariseList(in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-film-summarise")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"summarise","title":"Summarise","icon":"📝","commands":[{"name":"summarise","title":"Summarise","mode":"list","filter":"self","run":"main.py"}]}"#.utf8)
            .write(to: folder.appending(path: Extension.manifestName))
        try Data("#!/usr/bin/python3\n".utf8).write(to: folder.appending(path: "main.py"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "main.py").path)
        let command = try Extension(folder: folder).commands[0]
        let link = ExplainerFilmRenders.pageLink, short = "en.wikipedia.org/wiki/Tiling_window_manager"
        func row(_ id: String, _ title: String, _ subtitle: String, _ icon: String) -> String {
            #"{"id":"\#(id)","title":"\#(title)","subtitle":"\#(subtitle)","icon":"\#(icon)","actions":[{"type":"run","command":"fetch","title":"Summarise","context":{"source":"\#(link)"}}]}"#
        }
        for (name, query, item) in [("s0-copied", "", row("clipboard", "Summarise the copied link", short, "🔗")),
                                    ("s1-pasted", link, row("typed", "Summarise \(short)", "Web page", "📝"))] {
            guard case .items(let items) = ExtensionRun.answer(#"{"type":"list","items":["# + item + "]}") else { throw CancellationError() }
            var nav = MenuNavigator(list: [], title: "Summarise", live: true)
            nav.query = query
            nav.replaceList(ExtensionList.entries(items, of: command))
            try await LineMenuRenders.render(Self.line(nav), name, in: dir, wait: 0.5)
        }
    }

    /// Trigger › Emoji's grid with a stranger's most used, as LineMenuRenders' L12 draws it.
    static func emoji(_ built: [MenuEntry], in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let emoji = try EmojiSearch.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/emoji.json")))
        var picks = Frecency()
        let day = Date(timeIntervalSince1970: 1_791_028_800)
        for (i, e) in ["🚀", "😂", "❤️", "🔥", "✅", "🙌", "👍", "🎉", "😭", "🙏", "👀", "✨", "🤔", "😅", "💯", "😎", "👏", "🤝", "🍕", "☕️"].enumerated() {
            picks.record("emoji:\(e)", at: day.addingTimeInterval(Double(i) * 60))
        }
        var nav = MenuNavigator(entries: built, branch: .emoji)
        nav.provide(.emoji, home: .emoji, EmojiGrid.entries(for: "", in: emoji, picks: picks))
        let m = Self.line(nav)
        m.frontApp = "Messages"
        try await LineMenuRenders.render(m, "grid", in: dir, wait: 0.5)
    }

    /// The extension the chat made, opened: Open ports' list as its program prints it.
    static func ports(in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-film-open-ports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"open-ports","title":"Open ports","icon":"🔌","commands":[{"name":"list","title":"Open ports","mode":"list","run":"main.py"}]}"#.utf8)
            .write(to: folder.appending(path: Extension.manifestName))
        try Data("#!/usr/bin/python3\n".utf8).write(to: folder.appending(path: "main.py"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "main.py").path)
        let command = try Extension(folder: folder).commands[0]
        func item(_ port: Int, _ program: String, _ pid: Int, _ icon: String) -> String {
            #"{"id":"\#(port)","title":"\#(program)","subtitle":"localhost:\#(port) · PID \#(pid)","icon":"\#(icon)","accessory":{"text":"\#(port)"},"#
                + #""actions":[{"type":"copy","text":"http://localhost:\#(port)","title":"Copy address"},{"type":"open","url":"http://localhost:\#(port)","title":"Open in browser"}]}"#
        }
        let line = #"{"type":"list","items":["# + [item(3000, "node", 7700, "🟢"), item(5432, "postgres", 412, "🐘"), item(4321, "astro", 7812, "🚀"),
                                                       item(11434, "ollama", 980, "🦙")].joined(separator: ",") + "]}"
        guard case .items(let items) = ExtensionRun.answer(line) else { throw CancellationError() }
        var nav = MenuNavigator(list: [], title: "Open ports", live: true)
        nav.replaceList(ExtensionList.entries(items, of: command))
        try await LineMenuRenders.render(Self.line(nav), "p1-list", in: dir, wait: 0.5)
    }

    /// Seven copies, newest first: a reply, a colour, a picture, a link, a command, an address and a flight.
    static func store(at db: URL) throws -> ClipboardStore {
        let store = try ClipboardStore(path: db)
        let now = Date()
        let texts: [(String, String?)] = [
            ("Flight KM 112 · Thu 07:40, gate B12", "com.apple.mail"),
            ("hello@example.com", "com.apple.mail"),
            ("git push origin main", "com.mitchellh.ghostty"),
            ("https://en.wikipedia.org/wiki/Tiling_window_manager", "com.apple.Safari"),
            ("#C6F432", nil),
            ("Thanks! I'll send the draft tonight.", "com.apple.MobileSMS"),
        ]
        for (i, (text, app)) in texts.enumerated() {
            let item = ClipItem(kind: text.hasPrefix("#") ? .colour : .text, text: text,
                                contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]], sourceApp: app)
            _ = try store.add(item, at: now.addingTimeInterval(Double(-600 * (texts.count - i))))
        }
        let shot = ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: ClipboardTabsRenders.png(CGSize(width: 1280, height: 800), seed: 0)]],
                            sourceApp: "com.apple.Preview")
        _ = try store.add(shot, at: now.addingTimeInterval(-200))
        return store
    }
}
}
#endif
