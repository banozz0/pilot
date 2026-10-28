#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Hyper+Space menu as Line draws it (menu-morph T1, vault Projects/Pilot/specs/menu-morph.html), Lagoon and Porcelain,
/// through HUD.makePanel as Pilot shows it, from the real model: the root, a search for "notes" across apps, windows,
/// actions and settings with its Search files row, the Files view, the calculator, colour and translation cards, Cmd+K,
/// Ask Quick AI, System's switches, every window Tab lists, no match, and apps' commands (P38). Sizes are checked always;
/// the pictures are opt-in:
/// `CFFIXED_USER_HOME=/tmp/pilot-rh PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter LineMenuRenders`
extension SharedLook {
@MainActor
@Suite("Line menu renders")
struct LineMenuRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Line's root is Classic's at 431 wide inside 650; a search, a branch and a list are 750 and fit their rows")
    func sizes() async throws {
        let states = try await Dictionary(uniqueKeysWithValues: Self.states() + Self.speedStates())
        let root = try #require(states["L1-root"])
        #expect(root.atRoot && root.layout == .line)
        #expect(root.instrumentSize.width == MenuPanelSize.lineRootWidth)
        #expect(root.instrumentSize.height <= MenuPanelSize.classicTallest)
        // Classic's root at Line's 36 pt rows: the branches under their rule heading, no recents (Sven 2026-10-20).
        let drawn = MenuPanelSize.lineChrome + CGFloat(root.nav.rows.count) * MenuPanelSize.lineRow + MenuPanelSize.classicRootHeading
        #expect(drawn <= root.instrumentSize.height + 0.5, "\(drawn) > \(root.instrumentSize.height)")
        for (name, model) in states where !model.atRoot {
            #expect(model.instrumentSize.width == MenuPanelSize.width, "\(name)")
            #expect(model.instrumentSize.height <= MenuPanelSize.classicTallest, "\(name)")
        }
        // The search lists apps, windows, actions and settings, and offers Search files (files are asked only in the Files
        // view, L11, card agent-bo-95422968).
        let notes = try #require(states["L2-notes"])
        let kinds = Set(notes.nav.rows.map(\.kind))
        #expect(kinds.isSuperset(of: [.app, .window, .action, .setting]), "\(kinds)")
        #expect(notes.nav.rows.contains { $0.target == .searchFiles })
        let files = try #require(states["L11-files"])
        #expect(files.nav.rows.allSatisfy { $0.kind == .file })
        // The Files view previews the selected file beside the list, at the full height (file search v2).
        #expect(files.previewsFile && files.instrumentSize.height == MenuPanelSize.line(.wide, rows: 0, headings: 0, full: true).height)
        #expect(notes.instrumentSize.height >= MenuPanelSize.lineChrome + CGFloat(min(notes.nav.rows.count, 8)) * MenuPanelSize.lineRow)
        // Typing stats puts the Mac's cards above the rows, with room for them; the Stats page is still a row (P42).
        let stats = try #require(states["L24-stats"])
        #expect(stats.statsCards && stats.nav.rows.contains { $0.title == "Stats" }, "\(stats.nav.rows.map(\.title))")
        #expect(stats.instrumentSize.height >= MenuPanelSize.lineChrome + StatsStrip.room + MenuPanelSize.lineRow)
        // Stats' screen draws its cards in the list's place, at their own height (Q400); Activity lists its rows (Q399).
        let screen = try #require(states["L28-stats"])
        #expect(screen.showsStats && screen.instrumentSize.height == MenuPanelSize.lineChrome + MenuStatsScreen.height)
        let activity = try #require(states["L27-activity"])
        #expect(activity.nav.rows.map(\.section) == ["Apps", "Apps", "Apps", "Background", "Background", "Background"])
        #expect(activity.nav.rows.first?.title == "Google Chrome" && activity.headings.count == 2)
        // The speed test takes the list's place at its own height, whatever the branch lists (P41).
        for name in ["L20-speed-running", "L21-speed-result", "L22-speed-failed", "L23-speed-root"] {
            let model = try #require(states[name])
            let test = try #require(model.speedTest)
            #expect(model.instrumentSize.height == MenuPanelSize.lineChrome + SpeedTestView.height(test), "\(name)")
        }
    }

    @Test("An answer is a card in the list's top slot with room for it, its Ask row under it; Cmd+K lists the row's actions")
    func cards() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        for name in ["L3-calculator", "L4-colour", "L5-translate"] {
            let model = try #require(states[name])
            let rows = model.nav.rows
            try #require(rows.count >= 2, "\(name): \(rows.map(\.title))")
            #expect(model.answerCard(rows[0], at: 0) != nil, "\(name)")
            #expect(rows[1].title == "Ask AI", "\(name)")
            let card: CGFloat = name == "L4-colour" ? 118 + 8 + 16 + 24 : 158
            #expect(MenuPanelSize.lineChrome + MenuPanelSize.instrumentHeading + card + 10 + MenuPanelSize.lineRow <= model.instrumentSize.height, "\(name)")
        }
        let actions = try #require(states["L6-actions"])
        #expect(actions.nav.actions?.visible.first?.title == "Open")
        #expect(actions.instrumentSize.height == MenuPanelSize.line(.wide, rows: 0, headings: 0, full: true).height)
    }

    @Test("Line's search line is JetBrains Mono 20; its rows keep Instrument's face")
    func face() {
        let tokens = StyleTokens.unstyled.scaled(PilotStyle.scale)
        let line = LineMenu.face(tokens)
        guard case .bundled(let face) = line.type.search.face else { Issue.record("the search line is the system's"); return }
        #expect(face.family == "JetBrains Mono" && line.type.search.size == 20)
        #expect(line.type.row == tokens.type.row && line.type.caption == tokens.type.caption)
    }

    @Test("Line renders in Lagoon and Porcelain, frames L1–L28, and Stats' screen in Toybox", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]
        // The Files view's notes, real in the moved home, so the preview pane (FilePreviewPane) reads their first lines.
        for (path, text) in Self.notesFiles(home: home) {
            try FileManager.default.createDirectory(at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        for themeID in ["lagoon", "porcelain"] {
            look.themeID = themeID
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
                .appendingPathComponent("menu-line-\(themeID == "lagoon" ? "dark" : "light")")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let thumbnails = FileThumbnails.shared
            thumbnails.make = FileThumbnailRenders.fake
            defer { thumbnails.make = FileThumbnails.quickLook }
            for (name, model) in try await Self.states() + Self.speedStates() where only.map(name.contains) ?? true {
                try await Self.render(model, name, in: dir, wait: name == "L11-files" ? 1.5 : 0.3)
            }
        }
        // Toybox draws Stats' cards in its own frame (Q400).
        look.style = .toybox
        let toy = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menu-toybox")
        try FileManager.default.createDirectory(at: toy, withIntermediateDirectories: true)
        for (name, model) in try Self.states() where name == "L28-stats" && (only.map(name.contains) ?? true) {
            try await Self.render(model, name, in: toy, wait: 0.3)
        }
    }

    /// `model` in the panel Pilot shows Line in (its own face, PilotMenu.makePanel), drawn after `wait` seconds off the main
    /// actor: the Files view's preview pane reads its file in a task, which needs the main actor free.
    static func render(_ model: MenuModel, _ name: String, in dir: URL, wait: Double) async throws {
        let panel = PilotMenu.makePanel(model)
        defer { panel.close() }
        // At the size the panel takes in the style drawn, as PilotMenu sizes it.
        PilotMenu.fit(panel, face: Look.shared.style == .instrument ? model.instrumentSize : model.toyboxSize)
        let content = try #require(panel.contentView)
        try await Task.sleep(for: .seconds(wait))
        // The menu is typed into, so its caret sits after the text; a field that took the keyboard selected it all.
        if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The menu's rows as RailMenuRenders builds them, with Notes among the apps, so a search for "notes" finds an app.
    static func built() throws -> [MenuEntry] {
        let engine = Engine()
        return MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("Ghostex", "com.madda.ghostex.host"), ("Finder", "com.apple.finder"),
                   ("Notes", "com.apple.Notes"), ("TextEdit", "com.apple.TextEdit"), ("Bitwarden", "com.bitwarden.desktop")],
            actions: engine.bindActions,
            store: BindStore(defaults: ["apps.terminal": Key("return"), AppsModule.openID(bundle: "com.madda.ghostex.host"): Key("g"),
                                        "system.lock": Key("escape"), "system.darkMode": Key("d", shift: true),
                                        "captures.menu": Key("c", .ctrl), "apps.emoji": Key("e", .ctrl)]),
            roleApps: ["apps.terminal": "com.mitchellh.ghostty"], menu: AppsModule.menuID, openID: AppsModule.openID(bundle:),
            running: ["com.mitchellh.ghostty", "com.apple.finder", "com.apple.Notes"],
            switches: ["system.darkMode": true, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false, "system.wifi": true])
    }

    /// Every state, named for its frame.
    static func states() throws -> [(String, MenuModel)] {
        let windows = try AeroWindow.parse(Self.windows)
        let built = try built()
        let day = Date(timeIntervalSince1970: 1_791_028_800), home = NSHomeDirectory()
        func model(_ nav: MenuNavigator) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.windows = windows
            m.ownKey = "Hyper+Space"
            m.waiting = MenuModel.waiting(updates: 3, clean: "2.1 GB")
            return m
        }
        func withWindows(_ nav: inout MenuNavigator) { nav.provide(.window, MenuEntries.windows(windows, excluding: nil)) }
        func answer(_ query: String) -> MenuNavigator {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.provide(.answer, RootAnswers.entries(for: query, now: day))
            return nav
        }
        var states: [(String, MenuModel)] = [("L1-root", model(MenuNavigator(entries: built)))]
        // More rows (Sven 2026-10-20): Files, Notes and Stats switched on, Files moved over Apps, the others after System.
        var extras = MenuRoot(extras: ["files", "notes", "stats"])
        if let files = extras.rows().first(where: { $0.extra?.id == "files" }) { extras.move(files, to: 0) }
        states.append(("L1c-root-extras", model(MenuNavigator(entries: built, root: extras))))

        var notes = MenuNavigator(entries: built)
        notes.query = "notes"
        withWindows(&notes)
        notes.provide(.file, MenuEntries.files([(home + "/Library/Application Support/Pilot/Notes/2026-10-16.md", day),
                                                (home + "/Documents/Projects/Pilot/Meeting notes.md", day.addingTimeInterval(-172_800)),
                                                (home + "/code/pilot/Packaging/release-notes.md", day.addingTimeInterval(-432_000))], home: home))
        notes.provideSettings("notes")
        states.append(("L2-notes", model(notes)))

        states.append(("L3-calculator", model(answer("22 km to mi"))))
        states.append(("L4-colour", model(answer("#2bc4f0"))))
        var translate = MenuNavigator(entries: built)
        translate.query = "tr buenos días"
        translate.provide(.answer, home: .translate, [AnswerCardRenders.translation])
        states.append(("L5-translate", model(translate)))

        var actions = notes
        _ = actions.handle(.commandK)
        states.append(("L6-actions", model(actions)))

        states.append(("L7-ask", model(answer("ask regex to match a hex colour"))))

        var system = MenuNavigator(entries: built, branch: MenuLayout.system("Power"))
        for _ in 0..<6 where system.selected?.target != .action("system.keepAwake") { _ = system.handle(.down) }
        states.append(("L8-system", model(system)))

        var tabWindows = MenuNavigator(entries: built)
        withWindows(&tabWindows)
        for _ in 0..<2 { _ = tabWindows.handle(.tab) }
        states.append(("L9-tab-windows", model(tabWindows)))

        var files = MenuNavigator(entries: built)
        files.query = "notes"
        files.show(.file)
        files.provide(.file, MenuEntries.files([(home + "/Library/Application Support/Pilot/Notes/2026-10-16.md", day),
                                                (home + "/Documents/Projects/Pilot/Meeting notes.md", day.addingTimeInterval(-172_800)),
                                                (home + "/code/pilot/Packaging/release-notes.md", day.addingTimeInterval(-432_000))], home: home))
        states.append(("L11-files", model(files)))

        var none = MenuNavigator(entries: built)
        none.query = "zzqxv"
        states.append(("L10-no-match", model(none)))

        // P39: Trigger › Emoji's grid, the most used two lines over the categories (P52); "heart"'s one block; ⌘P's list.
        let emoji = try EmojiSearch.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/emoji.json")))
        var picks = Frecency()
        let picked = ["🚀", "😂", "❤️", "🔥", "✅", "🙌", "👍", "🎉", "😭", "🙏", "👀", "💀", "✨", "🤔", "😅", "💯", "🥲", "😎", "🫡", "👏", "🤝", "🍕"]
        // The first four picked three, two, two and two times, so the count leads; the rest once, the newest first.
        let counts = [3, 2, 2, 2]
        for (i, e) in picked.enumerated() {
            for _ in 0..<(counts.indices.contains(i) ? counts[i] : 1) { picks.record("emoji:\(e)", at: day.addingTimeInterval(Double(i) * 60)) }
        }
        func grid(_ query: String, chip: ChipMenu? = nil) -> MenuModel {
            var nav = MenuNavigator(entries: built, branch: .emoji)
            nav.query = query
            nav.provide(.emoji, home: .emoji, EmojiGrid.entries(for: query, in: emoji, picks: picks))
            let m = model(nav)
            m.frontApp = "Messages"
            m.chip = chip
            return m
        }
        states.append(("L12-emoji", grid("")))
        states.append(("L13-emoji-heart", grid("heart")))
        var categories = ChipMenu.emojiCategories(EmojiGrid.categories(in: emoji), mostUsed: 20, picked: nil)
        categories.select(4)
        states.append(("L14-emoji-categories", grid("", chip: categories)))

        // P40: Translate's line, its panes before text and with a translation, and Tab to To with its list filtered.
        func translating(_ text: String?, chip: ChipMenu? = nil) -> MenuModel {
            var nav = MenuNavigator(entries: built, branch: .translate)
            if let text {
                nav.query = "Can we move the design review to Thursday at 3?"
                nav.provide(.answer, home: .translate, [MenuEntry(title: text, target: .copy(text), home: .translate,
                                                                  detail: "English → Spanish · Return copies", isAnswer: true)])
            }
            let m = model(nav)
            m.frontApp = "Notes"
            m.translateSource = text == nil ? nil : "en"
            m.chip = chip
            m.chipFocus = chip == nil ? nil : 2
            return m
        }
        states.append(("L15-translate-empty", translating(nil)))
        states.append(("L16-translate", translating("¿Podemos mover la revisión de diseño al jueves a las 3?")))
        var languages = TranslateLanguages.menu(from: false, shown: "es", installed: ["en", "es", "fr", "de"])
        languages.query = "ja"
        states.append(("L17-translate-to", translating("¿Podemos mover la revisión de diseño al jueves a las 3?", chip: languages)))

        // P38: a command's words list the apps' commands; an app's name lists its own under it.
        let commands = try Self.withCommands(built)
        for (name, query) in [("L18-commands", "today"), ("L19-app-commands", "music")] {
            var nav = MenuNavigator(entries: commands)
            nav.query = query
            states.append((name, model(nav)))
        }

        // Typing stats (P42): the five cards from a seeded sampler, never this Mac's.
        let sampler = SystemSampler()
        SharedLook.StatsRenders.seed(sampler)
        StatsStrip.sampler = sampler
        var stats = MenuNavigator(entries: built)
        stats.query = "stats"
        stats.provideSettings("stats")
        states.append(("L24-stats", model(stats)))

        // P43: Finder's selection rows at a root search for "folder", and the design picker over four folders, one in a git
        // repository. The folders are named, never made: nothing of Sven's is read.
        let folders = ["Projects", "Documents/Design", "Documents/Invoices", "code/pilot"]
            .map { URL(filePath: "/pilot-render-folders").appending(path: $0, directoryHint: .isDirectory) }
        var selection = MenuNavigator(entries: built)
        selection.provide(.selection, FolderDesigns.rows(folders))
        selection.query = "folder"
        selection.provideSettings("folder")
        states.append(("L25-folders", model(selection)))
        var designs = MenuNavigator(list: [], title: "4 folders", live: true)
        designs.replaceList(FolderDesignSource(folders, inGit: [folders[3]]).rows())
        for _ in 0..<4 { _ = designs.handle(.down) }
        states.append(("L26-folder-designs", model(designs)))

        // Hyper+Space › Activity and › Stats, screens of their own (Q399, Q400): seeded rows, and the readings seeded for
        // L24, never this Mac's.
        let helper = Activity.Row(kind: .process, pid: 812, name: "Google Chrome Helper (Renderer)", cpu: 14, memory: 410_000 << 10, rights: .quitAndForce)
        let snapshot = Activity.Snapshot(apps: [
            Activity.Row(kind: .app, pid: 801, name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", cpu: 38.2,
                         memory: 3_100_000 << 10, rights: .quitAndForce, children: [helper, helper, helper]),
            Activity.Row(kind: .app, pid: 640, name: "Ghostty", bundlePath: "/Applications/Ghostty.app", cpu: 6.1, memory: 820_000 << 10, rights: .quitAndForce),
            Activity.Row(kind: .app, pid: 402, name: "Finder", bundlePath: "/System/Library/CoreServices/Finder.app", cpu: 0.4,
                         memory: 120_000 << 10, rights: .quitAndForce),
        ], background: [
            Activity.Row(kind: .process, pid: 155, name: "WindowServer", cpu: 9.3, memory: 410_000 << 10, rights: .none(.macOS)),
            Activity.Row(kind: .process, pid: 2210, name: "pilot-files", cpu: 1.2, memory: 90_000 << 10, rights: .quitAndForce),
            Activity.Row(kind: .process, pid: 388, name: "mds_stores", cpu: 0.8, memory: 60_000 << 10, rights: .quitOnly),
        ])
        var activity = MenuNavigator(entries: built, branch: .activity)
        activity.provide(.action, home: .activity, Activity.screenEntries(snapshot))
        let activityModel = model(activity)
        activityModel.activityRead = true
        states.append(("L27-activity", activityModel))
        states.append(("L28-stats", model(MenuNavigator(entries: built, branch: .stats))))
        return states
    }

    /// The Speed test view over System › Connections (P41): measuring with a live reading, a result with six runs before
    /// it, and a run that failed. Nothing measures: each run's networkQuality is faked.
    static func speedStates() async throws -> [(String, MenuModel)] {
        let built = try built()
        let runs = try DayFile<[SpeedTest.Result]>(url: URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-speedruns-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: runs.url) }
        let day = Date().addingTimeInterval(-6 * 86_400)
        try runs.save([412, 398, 405, 188, 420, 401].enumerated().map { i, down in
            SpeedTest.Result(reading: .init(download: down, upload: 37.9, responsiveness: 1180), at: day.addingTimeInterval(Double(i) * 86_400), seconds: 19)
        })
        func model(_ test: SpeedTest, root: Bool = false) -> MenuModel {
            var nav = MenuNavigator(entries: built, branch: root ? nil : MenuLayout.system("Connections"))
            if root { nav.query = "speed" }
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.speedTest = test
            return m
        }
        let json = #"{"dl_throughput":412000000,"ul_throughput":38600000,"responsiveness":1240,"interface_name":"en0","start_date":"2026-10-18 14:01:43.000","end_date":"2026-10-18 14:02:02.000"}"#
        let running = SpeedTest(live: { live in
            live(.init(download: 286.4, upload: 31.2, responsiveness: 842))
            try await Task.sleep(for: .seconds(600))
            return ""
        }, history: runs, clock: { Date().addingTimeInterval(-8) }, say: { _ in })
        running.start()
        let done = SpeedTest(live: { _ in json }, history: runs, say: { _ in })
        _ = await done.start()?.value
        struct Down: Error {}
        let failed = SpeedTest(measure: { throw Down() }, say: { _ in })
        _ = await failed.start()?.value
        // The live reading lands on the main actor after the run starts; the run then waits, never ending in the test.
        try await Task.sleep(for: .milliseconds(50))
        // L23: opened from a root search for "speed", where the foot says where Sven is rather than the kinds.
        return [("L20-speed-running", model(running)), ("L21-speed-result", model(done)), ("L22-speed-failed", model(failed)),
                ("L23-speed-root", model(done, root: true))]
    }

    /// The shipped drive catalogue's commands (P38), with Calendar, Reminders and Music on the Mac.
    static func withCommands(_ built: [MenuEntry]) throws -> [MenuEntry] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/drive-catalogue.json")
        let apps = [("Calendar", "com.apple.iCal"), ("Reminders", "com.apple.reminders"), ("Music", "com.apple.Music")]
        return MenuEntries.commands(built + apps.map { MenuEntry(title: $0.0, target: .app($0.1), home: .apps) },
                                    catalogue: try DriveCatalogue(json: Data(contentsOf: file)), installed: Set(apps.map(\.1)))
    }

    /// The three notes the search and the Files view list, with words for the preview pane.
    static func notesFiles(home: String) -> [(String, String)] {
        [(home + "/Library/Application Support/Pilot/Notes/2026-10-16.md", "# Friday\n\n- Line menu: picked (Q165)\n- Morph timings: 200 ms out, 160 back\n- Ask Moody to review typing\n"),
         (home + "/Documents/Projects/Pilot/Meeting notes.md", "# Shippers Club\n\nShip the menu first, then capture.\n"),
         (home + "/code/pilot/Packaging/release-notes.md", "# Pilot 0.9\n\n- The Line menu\n- File search v2\n")]
    }

    /// Windows a search for "notes" finds two of, the rest as InstrumentMenuRenders lists them.
    static let windows = """
    [{"window-id": 412, "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "app-pid": 2, "workspace": "3", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "~/notes — zsh"},
     {"window-id": 418, "app-name": "Zen", "app-bundle-id": "app.zen-browser.zen", "app-pid": 4, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Raycast — styles.refero.design"},
     {"window-id": 7, "app-name": "Ghostex", "app-bundle-id": "com.madda.ghostex.host", "app-pid": 1, "workspace": "2", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "notes round 2"}]
    """
}
}
#endif
