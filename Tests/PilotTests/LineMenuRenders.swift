#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Hyper+Space menu as Line draws it (menu-morph T1, vault Projects/Pilot/specs/menu-morph.html), Tokyo Night and Porcelain,
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

    @Test("Line's root is Classic's at 431 wide, as tall as its screen holds; a search, a branch and a list are 750 and fit their rows")
    func sizes() async throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let root = try #require(states["L1-root"])
        #expect(root.atRoot)
        #expect(root.instrumentSize.width == MenuPanelSize.lineRootWidth)
        #expect(root.instrumentSize.height <= MenuPanelSize.classicTallest)
        // Classic's root at Line's 36 pt rows: the branches under their rule heading, no recents (Sven 2026-10-20).
        let drawn = MenuPanelSize.lineChrome + CGFloat(root.nav.rows.count) * MenuPanelSize.lineRow + MenuPanelSize.classicRootHeading
        #expect(drawn <= root.instrumentSize.height + 0.5, "\(drawn) > \(root.instrumentSize.height)")
        // Every Go to row shows on Sven's screen (T36); an 800 pt screen caps the root at its room, the rest scrolls.
        let roomy = try #require(states["L1d-root-1440"]), small = try #require(states["L1e-root-800"])
        #expect(roomy.nav.rows.count == 17, "\(roomy.nav.rows.map(\.title))")
        let all = MenuPanelSize.lineChrome + 17 * MenuPanelSize.lineRow + MenuPanelSize.classicRootHeading
        #expect(roomy.instrumentSize.height == all && all > MenuPanelSize.classicTallest, "\(roomy.instrumentSize.height) vs \(all)")
        let smallRoom = try #require(small.room)
        #expect(small.instrumentSize.height == smallRoom && smallRoom < all && smallRoom < 800 - 33, "\(small.instrumentSize.height)")
        // Typing shrinks it back to the search's rows.
        let typed = MenuModel(nav: { var nav = roomy.nav; nav.query = "qr"; return nav }())
        typed.room = roomy.room
        #expect(!typed.atRoot && typed.instrumentSize.height < all, "\(typed.instrumentSize.height)")
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
        // Activity lists its rows (Q399).
        let activity = try #require(states["L27-activity"])
        #expect(activity.nav.rows.map(\.section) == ["Apps", "Apps", "Apps", "Background", "Background", "Background"])
        #expect(activity.nav.rows.first?.title == "Google Chrome" && activity.headings.count == 2)
        // T42: "generate password" finds Password generator, a typo away; Generate a password, with no default key since
        // the trim (Q263), is listed only once added on Abilities. cb's row alone
        // searching the words, chat's question alone, kill's words searching Activity.
        let bw = try #require(states["L31-bw-generate-password"]).nav.rows.map(\.title)
        #expect(!bw.contains("Generate a password") && bw.contains("Password generator"), "\(bw)")
        let cb = try #require(states["L33-cb-invoice"]).nav.rows
        #expect(cb.count == 1 && cb[0].target == .action("apps.clipboard") && cb[0].subtitle == "“invoice”", "\(cb.map(\.title))")
        #expect(try #require(states["L34-chat-whats-up"]).nav.rows.map(\.target) == [.ask("what's up")])
        let kill = try #require(states["L35-kill-chrome"]).nav
        #expect(kill.branch == .activity && kill.query == "chrome" && kill.rows.first?.title == "Google Chrome", "\(kill.rows.map(\.title))")
    }

    @Test("An answer is a card in the list's top slot with room for it, its Ask row under it (tr's alone, T40); Cmd+K lists the row's actions")
    func cards() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        for name in ["L3-calculator", "L4-colour", "L5-translate"] {
            let model = try #require(states[name])
            let rows = model.nav.rows, alone = name == "L5-translate"
            try #require(rows.count >= (alone ? 1 : 2), "\(name): \(rows.map(\.title))")
            #expect(model.answerCard(rows[0], at: 0) != nil, "\(name)")
            // tr's answer is the whole list, no Ask or search rows (T40).
            #expect(alone ? rows.allSatisfy(\.isAnswer) : rows[1].title == "Ask AI", "\(name): \(rows.map(\.title))")
            let card: CGFloat = name == "L4-colour" ? 118 + 8 + 16 + 24 : 158
            #expect(MenuPanelSize.lineChrome + MenuPanelSize.instrumentHeading + card + 10 + (alone ? 0 : MenuPanelSize.lineRow) <= model.instrumentSize.height, "\(name)")
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

    @Test("Line renders in Tokyo Night and Porcelain, frames L1–L35", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
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
        for themeID in ["tokyo-night", "porcelain"] {
            look.themeID = themeID
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
                .appendingPathComponent("menu-line-\(themeID == "tokyo-night" ? "dark" : "light")")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let thumbnails = FileThumbnails.shared
            thumbnails.make = FileThumbnailRenders.fake
            defer { thumbnails.make = FileThumbnails.quickLook }
            for (name, model) in try Self.states() where only.map(name.contains) ?? true {
                try await Self.render(model, name, in: dir, wait: name == "L11-files" ? 1.5 : 0.3)
            }
        }
    }

    /// `model` in the panel Pilot shows Line in (its own face, PilotMenu.makePanel), drawn after `wait` seconds off the main
    /// actor: the Files view's preview pane reads its file in a task, which needs the main actor free.
    static func render(_ model: MenuModel, _ name: String, in dir: URL, wait: Double) async throws {
        let panel = PilotMenu.makePanel(model)
        defer { panel.close() }
        // At the size the panel takes, as PilotMenu sizes it.
        PilotMenu.fit(panel, face: model.instrumentSize)
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

    /// The menu's rows, with Notes among the apps, so a search for "notes" finds an app.
    static func built() throws -> [MenuEntry] {
        let engine = Engine()
        return MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("Ghostex", "com.madda.ghostex.host"), ("Finder", "com.apple.finder"),
                   ("Notes", "com.apple.Notes"), ("TextEdit", "com.apple.TextEdit"), ("Bitwarden", "com.bitwarden.desktop")],
            // Generate a password as Bitwarden's ability added: a new install's Easy holds no key for it (T11), so a
            // fresh Engine no longer lists it on its own (Classic's Hyper+Shift+P did).
            actions: engine.bindActions(including: ["apps.generatePassword"]),
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
        // More rows (Sven 2026-10-20): Files, Notes and Activity switched on, Files moved over Apps, the others after System.
        var extras = MenuRoot(extras: ["files", "notes", "activity"])
        if let files = extras.rows().first(where: { $0.extra?.id == "files" }) { extras.move(files, to: 0) }
        states.append(("L1c-root-extras", model(MenuNavigator(entries: built, root: extras))))
        // Sven's 17 Go to rows (T36, 2026-11-04): the root grows to show them all on his 1440 pt screen, and scrolls past
        // an 800 pt one's height. Each screen's visible height is less its menu bar (33 pt).
        let tall = MenuRoot(extras: ["files", "notes", "activity", "qr", "reminders", "translate", "capture"])
        for (name, visible) in [("L1d-root-1440", 1440.0 - 33), ("L1e-root-800", 800.0 - 33)] {
            let m = model(MenuNavigator(entries: built, root: tall))
            let panel = PilotMenu.makePanel(m)
            m.room = PilotMenu.room(visible: visible, margins: (panel as? KeyPanel)?.margins ?? NSEdgeInsetsZero)
            panel.close()
            states.append((name, m))
        }

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
        // T37: the emoji picker's alias and a word at the root lists the emoji it finds, best first.
        var em = MenuNavigator(entries: built, aliases: Aliases(Alias.starters))
        em.query = "em funny"
        em.provide(.emoji, EmojiSearch.entries(for: try #require(em.emojiWords), in: emoji))
        states.append(("L29-em-funny", model(em)))
        // T40: an inline answer's word, its answers alone, the translation first though the quicklink's answer came first.
        var tr = MenuNavigator(entries: built + MenuEntries.quicklinks(Quicklink.shipped))
        tr.query = "tr hello"
        tr.provide(.answer, RootAnswers.entries(for: tr.query, now: .now, links: Quicklink.shipped))
        tr.provide(.answer, home: .translate, [MenuEntry(title: "hola", target: .copy("hola"), home: .translate,
                                                         detail: "English → Spanish · Return copies", isAnswer: true)])
        states.append(("L30-tr-hello", model(tr)))
        // T40: an app's alias and words, that app's actions alone, best first; its menu bar read once the words are typed.
        func node(_ menu: String, _ items: [String]) -> MenuItemNode {
            MenuItemNode(title: menu, enabled: true, children: items.map { MenuItemNode(title: $0, enabled: true) })
        }
        let aliased = Aliases(Alias.starters + [Alias(key: "app:com.bitwarden.desktop", alias: "bw", title: "Bitwarden"),
                                                Alias(key: "app:com.madda.ghostex.host", alias: "gx", title: "Ghostex")])
        for (name, query, bundle, app, bar) in [
            ("L31-bw-generate-password", "bw generate password", "com.bitwarden.desktop", "Bitwarden",
             [node("File", ["New item", "New folder"]), node("View", ["Search vault", "Password generator"]), node("Account", ["Lock all vaults"])]),
            ("L32-gx-new-terminal", "gx new terminal", "com.madda.ghostex.host", "Ghostex",
             [node("Shell", ["New Terminal Session", "New Terminal Tab", "Split Right", "Close Terminal"]), node("Window", ["New Window", "Minimize"])]),
        ] {
            var nav = MenuNavigator(entries: built, aliases: aliased)
            nav.query = query
            nav.provide(.menuItem, MenuItemSearch.entries(bar, bundle: bundle, app: app))
            states.append((name, model(nav)))
        }

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

        // P38: a command's words list the apps' commands; an app's name lists its own right under it, above Ask AI (Q831).
        let commands = try Self.withCommands(built)
        for (name, query) in [("L18-commands", "today"), ("L19-app-commands", "music")] {
            var nav = MenuNavigator(entries: commands)
            nav.query = query
            if name == "L19-app-commands" {
                let titles = nav.rows.map(\.title), ask = titles.firstIndex(of: "Ask AI") ?? titles.count
                #expect(titles.first == "Music" && titles[1..<ask].contains("Music: Favourite This Song"), "\(titles)")
            }
            states.append((name, model(nav)))
        }

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

        // Hyper+Space › Activity, a screen of its own (Q399): seeded rows, never this Mac's.
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
        // T42: an action's alias and words acts on them: clipboard history's row searching them, the question alone, and
        // Kill a process's alias opening Activity searching them, as the panel moves it there.
        let actioned = Aliases(Alias.starters + [Alias(key: "action:system.killProcess", alias: "kill", title: "Kill a process"),
                                                 Alias(key: "action:ai.chat", alias: "chat", title: "AI chat")])
        for (name, query) in [("L33-cb-invoice", "cb invoice"), ("L34-chat-whats-up", "chat what's up"), ("L35-kill-chrome", "kill chrome")] {
            var nav = MenuNavigator(entries: built, aliases: actioned)
            nav.query = query
            if let spot = nav.scopedBranch {
                nav.go(to: spot)
                nav.provide(.action, home: .activity, Activity.screenEntries(snapshot))
            }
            let shown = model(nav)
            shown.activityRead = true
            states.append((name, shown))
        }
        return states
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
