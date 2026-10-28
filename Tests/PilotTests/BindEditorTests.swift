import AppKit
import Foundation
import PilotCore
import SwiftUI
import Synchronization
import Testing
@testable import Pilot

/// Editor A (spec bind-editor, T4): what Save will do before anything is written, the one search's list and chips, the
/// sheet's size in the least window, and binds.json untouched by a cancelled editor or a refused bind.
@MainActor
@Suite("Bind editor")
struct BindEditorTests {
    static let t = Key("t"), ret = Key("return")
    static let sources = BindSearch.Sources(
        apps: [("Ghostty", "com.mitchellh.ghostty"), ("Ghostex", "dev.ghostex.app"), ("Notes", "com.apple.Notes")],
        actions: [BindsPage.ActionInfo(id: "apps.ghosttyLook", label: "Ghostty: use Pilot's look", module: "apps"),
                  BindsPage.ActionInfo(id: "windows.focusLeft", label: "Focus left", module: "windows")])

    @Test("Save's word and sentence: Save on a free key, Replace over a taken one, Move here for a keyed action, Replace when both")
    func plan() {
        let save = BindPlan(key: Self.t, name: "Ghostty", opens: true, holder: nil, freed: nil)
        #expect(save.verb == .save && save.enabled && save.sentence == "Hyper+T opens Ghostty.")
        #expect(save.taken == nil && save.moving == nil)

        let replace = BindPlan(key: Self.t, name: "Ghostty", opens: true, holder: "Terminal", freed: nil)
        #expect(replace.verb == .replace && replace.sentence == "Hyper+T opens Ghostty, not Terminal.")
        #expect(replace.taken == .init(lead: "Hyper+T runs Terminal now.", rest: "Save gives it to Ghostty; Terminal is left with no key."))

        let move = BindPlan(key: Self.t, name: "Ghostty", opens: true, holder: nil, freed: Self.ret)
        #expect(move.verb == .move && move.freed == "Hyper+Return")
        #expect(move.moving == .init(lead: "Ghostty is on Hyper+Return now.",
                                     rest: "One action holds one key: saving moves it to Hyper+T and frees Hyper+Return."))

        let both = BindPlan(key: Self.t, name: "Ghostty", opens: true, holder: "Terminal", freed: Self.ret)
        #expect(both.verb == .replace && both.taken != nil && both.moving != nil)

        let runs = BindPlan(key: Key("e", .leftAlt, hyper: false), name: "Clipboard history", opens: false, holder: nil, freed: nil)
        #expect(runs.sentence == "Left Alt+E runs Clipboard history.")
    }

    @Test("Save is off with a reason: no keys, or nothing picked")
    func off() {
        let noKeys = BindPlan(key: nil, name: "Ghostty", opens: true, holder: nil, freed: nil)
        #expect(!noKeys.enabled && noKeys.sentence == "Press the keys first.")
        let noPick = BindPlan(key: Self.t, name: nil, opens: false, holder: nil, freed: nil)
        #expect(!noPick.enabled && noPick.sentence == "Pick what Hyper+T does.")
    }

    @Test("The list holds 7 rows at 1000×660 and up, 4 at the 760×520 least window")
    func rows() {
        #expect(BindEditor.listRows(windowHeight: 660) == 7)
        #expect(BindEditor.listRows(windowHeight: 900) == 7)
        #expect(BindEditor.listRows(windowHeight: 520) == 4)
        #expect(BindEditor.listRows(windowHeight: 600) == 5)
    }

    @Test("Empty, the search lists the kinds under one heading, apps counted; More opens its three")
    func kinds() {
        let finder = BindFinder(sources: Self.sources)
        let (lines, chips) = finder.listing { _ in nil }
        #expect(chips.isEmpty)
        #expect(lines.map(\.title) == ["Open an app", "Run a Pilot action", "Open a website", "Run a shell command", "Press a menu item",
                                       "Send keys to the app in front", "More"])
        #expect(lines.first?.heading == "Start with what it does" && lines.dropFirst().allSatisfy { $0.heading == nil })
        #expect(lines.first?.count == "3 apps")
        finder.more = true
        #expect(finder.listing { _ in nil }.lines.map(\.title) == ["Shortcut", "Pick from a list", "App URL"])
    }

    @Test("gho lists Apps then Pilot actions under their headings, the shell row last, each action's key on its row; chips count them")
    func typed() throws {
        let finder = BindFinder(query: "gho", sources: Self.sources)
        let (lines, chips) = finder.listing { $0 == "apps.open:dev.ghostex.app" ? Key("g") : nil }
        #expect(lines.map(\.title) == ["Ghostty", "Ghostex", "Ghostty: use Pilot's look", "Run gho as a shell command"])
        #expect(lines.map(\.heading) == ["Apps", nil, "Pilot actions", "Or"])
        guard case .row(let ghostex) = lines[1].pick else { throw Failure("Ghostex is not a row") }
        #expect(ghostex.key == Key("g"))
        #expect(chips.map { "\($0.title)\($0.count.map { " \($0)" } ?? "")" } == ["All 3", "Apps 2", "Pilot 1", "Web", "Shell", "Menu item"])
        finder.scope = .app
        let scoped = finder.listing { _ in nil }
        #expect(scoped.lines.map(\.title) == ["Ghostty", "Ghostex"] && scoped.chips.isEmpty)
    }

    @Test("Editor A fits the least window, 760×520: 560 wide, at most 460 high, empty, typed, and with both warnings")
    func fits() throws {
        let engine = Engine()
        let (look, _) = LookPageTests().look()
        look.style = .instrument
        // Hyper+T taken by Terminal's bind, and the pick already keyed: both warnings show.
        engine.binds.replace("apps.terminal", with: Self.t)
        engine.binds.replace("windows.focusLeft", with: Key("y"))
        let editors = [("empty", BindEditor(action: nil, actions: engine.bindActions, startKey: Key("u"), windowHeight: 520, finder: BindFinder(sources: Self.sources))),
                       ("typed", BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 520,
                                            finder: BindFinder(query: "gho", sources: Self.sources))),
                       ("warned", BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 520,
                                             finder: BindFinder(picked: "windows.focusLeft", sources: Self.sources)))]
        for (name, editor) in editors {
            testApp()
            let host = NSHostingView(rootView: editor.environment(engine).styled(.page(.binds), look: look).pilotTheme(look: look))
            host.frame.size = host.fittingSize
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            PanelTestSupport.pump(0.3)
            let size = host.fittingSize
            w.close()
            #expect(size.width == 560, "\(name) is \(Int(size.width)) wide")
            #expect(size.height <= 460, "\(name) is \(Int(size.height)) high")
        }
    }

    /// A store with Terminal's default on Hyper+Return, Files' on Hyper+F, Ghostty's app bind on none.
    static func store() -> BindStore {
        BindStore(defaults: ["apps.terminal": ret, "apps.files": Key("f")], actions: ["apps.terminal", "apps.files"])
    }

    /// Save as the editor runs it: the plan from the store, then BindWrite.save on it.
    static func save(_ target: String, to key: Key, editing old: String? = nil, in store: inout BindStore) throws -> BindPlan {
        let plan = BindPlan(store: store, key: key, target: target, editing: old) { $0 }
        try BindWrite.save(plan, target, to: key, from: old, in: &store)
        return plan
    }

    @Test("Save on a free key binds it; Replace takes a held key and leaves its holder with none; Move here frees the old key; both at once")
    func writes() throws {
        let ghostty = "apps.open:com.mitchellh.ghostty"
        var store = Self.store()
        #expect(try Self.save(ghostty, to: Self.t, in: &store).verb == .save)
        #expect(store.trigger(for: ghostty) == Self.t && store.action(for: Self.t) == ghostty)

        store = Self.store()
        let replace = try Self.save(ghostty, to: Self.ret, in: &store)
        #expect(replace.verb == .replace && replace.holderID == "apps.terminal")
        #expect(store.action(for: Self.ret) == ghostty && store.trigger(for: "apps.terminal") == nil)

        store = Self.store()
        let move = try Self.save("apps.terminal", to: Self.t, in: &store)
        #expect(move.verb == .move && move.freed == "Hyper+Return")
        #expect(store.trigger(for: "apps.terminal") == Self.t && store.action(for: Self.ret) == nil)

        // Files takes Terminal's key: Terminal loses it, Files' own Hyper+F goes free.
        store = Self.store()
        let both = try Self.save("apps.files", to: Self.ret, in: &store)
        #expect(both.verb == .replace && both.freed == "Hyper+F")
        #expect(store.action(for: Self.ret) == "apps.files" && store.trigger(for: "apps.terminal") == nil && store.action(for: Key("f")) == nil)

        // Editing Terminal's bind to run Ghostty: Terminal is left with no key, no move or Replace said.
        store = Self.store()
        let edit = try Self.save(ghostty, to: Self.ret, editing: "apps.terminal", in: &store)
        #expect(edit.verb == .save && store.action(for: Self.ret) == ghostty && store.trigger(for: "apps.terminal") == nil)

        // Editing a bind's own key is no move.
        store = Self.store()
        #expect(try Self.save("apps.terminal", to: Self.t, editing: "apps.terminal", in: &store).verb == .save)
    }

    @Test("Save off writes nothing; Remove leaves the bind with no key")
    func offAndRemove() throws {
        var store = Self.store()
        let before = store.json()
        let off = BindPlan(store: store, key: Self.t, target: nil, editing: nil) { $0 }
        try BindWrite.save(off, "apps.terminal", to: Self.t, from: nil, in: &store)
        #expect(store.json() == before)
        try BindWrite.remove("apps.terminal", in: &store)
        #expect(store.trigger(for: "apps.terminal") == nil && store.action(for: Self.ret) == nil)
    }

    @Test("Esc stops Record, then the AI's ask, then clears the search, then the kind, then cancels")
    func escape() {
        #expect(BindWrite.escape(recording: true, asking: true, query: "gho", scoped: true) == .stopRecording)
        #expect(BindWrite.escape(recording: false, asking: true, query: "gho", scoped: true) == .stopAsking)
        #expect(BindWrite.escape(recording: false, query: "gho", scoped: true) == .clearSearch)
        #expect(BindWrite.escape(recording: false, query: "", scoped: true) == .clearKind)
        #expect(BindWrite.escape(recording: false, query: "", scoped: false) == .cancel)
    }

    @Test("A bind's default key is its layout's, whatever was set by hand; none for an action with no default")
    func defaultTrigger() throws {
        var store = Self.store()
        try store.set("apps.terminal", to: Self.t)
        #expect(store.isCustom("apps.terminal") && store.defaultTrigger(for: "apps.terminal") == Self.ret)
        #expect(store.defaultTrigger(for: "apps.open:com.mitchellh.ghostty") == nil)
    }

    @Test("A sound output's action takes a device UID, and still an older bind's numeric id")
    func soundOutputs() {
        #expect(SystemModule.dynamic("system.output:BuiltInSpeakerDevice") != nil)
        #expect(SystemModule.dynamic("system.output:73") != nil)
        #expect(SystemModule.dynamic("system.output:") == nil)
    }

    @Test("Cancel and a refused bind leave binds.json as it was")
    func untouched() throws {
        let engine = Engine()
        engine.binds.replace("windows.focusLeft", with: Key("y"))
        let file = engine.binds.fileURL
        let before = try Data(contentsOf: file)
        // The editor opened with a pick and the keys, then closed with nothing saved.
        testApp()
        let finder = BindFinder(query: "gho", picked: "apps.open:com.mitchellh.ghostty", sources: Self.sources)
        let editor = BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder)
        let host = NSHostingView(rootView: editor.environment(engine).styled(.page(.binds)))
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        PanelTestSupport.pump(0.3)
        // Esc through the sheet's own shortcut: the search clears first, then Esc cancels; nothing is written.
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(host.performKeyEquivalent(with: esc))
        PanelTestSupport.pump(0.1)
        #expect(finder.query.isEmpty)
        #expect(host.performKeyEquivalent(with: esc))
        PanelTestSupport.pump(0.1)
        w.close()
        PanelTestSupport.pump(0.1)
        #expect(try Data(contentsOf: file) == before)
        // A bind refused (the key is taken): nothing written.
        #expect(throws: BindStore.BindError.self) { try engine.binds.set("apps.terminal", to: Key("y")) }
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: the kind forms (T5)

    /// Zen's menu bar as AXMenuItems reads it: File's two items with keys, a disabled one, History's one.
    static let zen = "app.zen-browser.zen"
    nonisolated static let bar = [
        MenuItemNode(title: "File", enabled: true, children: [
            MenuItemNode(title: "New Window", enabled: true, char: "N", modifiers: 0),
            MenuItemNode(title: "New Private Window", enabled: true, char: "P", modifiers: 1),
            MenuItemNode(title: "Close Window", enabled: false),
        ]),
        MenuItemNode(title: "History", enabled: true, children: [MenuItemNode(title: "Reopen Closed Tab", enabled: true)]),
    ]

    /// The routes the kind forms save that run something of the user's (the task's risk).
    static let formRoutes = [DriveRoute.shell("open -g ~/Downloads"), .menu(bundle: zen, path: ["File", "New Window"]), .url("shottr://grab/window")]

    @Test("Shortcut is a search over Shortcuts' names")
    func shortcuts() {
        let finder = BindFinder(scope: .shortcut, sources: Self.sources)
        #expect(finder.listing { _ in nil }.lines.isEmpty)
        finder.provide(shortcuts: ["Morning routine", "Dark mode"])
        let lines = finder.listing { _ in nil }.lines
        #expect(Set(lines.map(\.title)) == ["Morning routine", "Dark mode"] && lines.first?.heading == "Shortcuts")
        guard case .row(let row)? = lines.first?.pick else { Issue.record("a Shortcut is no row"); return }
        #expect(DriveRoute(id: row.id) == .shortcut(row.title))
    }

    @Test("A menu's rows: its enabled items as File › New Window with their keys, filtered as typed; a path typed with > comes first")
    func menuRows() throws {
        let items = MenuItemSearch.entries(Self.bar, bundle: Self.zen)
        let all = BindEditor.menuRows(items, query: "", bundle: Self.zen)
        #expect(Set(all.map(\.path)) == ["File › New Window", "File › New Private Window", "History › Reopen Closed Tab"])
        #expect(all.first { $0.path == "File › New Window" }?.key != nil)
        #expect(all.first { $0.path == "File › New Window" }?.id == DriveRoute.menu(bundle: Self.zen, path: ["File", "New Window"]).id)
        #expect(Set(BindEditor.menuRows(items, query: "new", bundle: Self.zen).map(\.path)) == ["File › New Window", "File › New Private Window"])
        // Zen not running: no items, the typed path binds.
        let typed = BindEditor.menuRows([], query: "File > Save As", bundle: Self.zen)
        #expect(typed == [.init(id: DriveRoute.menu(bundle: Self.zen, path: ["File", "Save As"]).id, path: "Press File › Save As")])
        // A typed path that is an item lists once.
        let same = BindEditor.menuRows(items, query: "File > New Window", bundle: Self.zen)
        #expect(same.filter { $0.id == DriveRoute.menu(bundle: Self.zen, path: ["File", "New Window"]).id }.count == 1)
        #expect(BindEditor.menuRows([], query: "File >", bundle: Self.zen).isEmpty)
    }

    @Test("A running app's menu bar is read off the main thread; an app not running gives none")
    func menuReadOffMain() async throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil && $0.processIdentifier != getpid() })
        let onMain = Mutex<Bool?>(nil)
        let items = await DriveModule.menuItems(of: try #require(app.bundleIdentifier)) { _ in
            onMain.withLock { $0 = pthread_main_np() != 0 }
            return Self.bar
        }
        #expect(onMain.withLock { $0 } == false)
        #expect(items?.count == 3)
        #expect(await DriveModule.menuItems(of: "dev.banozz.not-running") { _ in Self.bar } == nil)
    }

    @Test("Run once runs the command in a login shell, off the main thread: nothing back when it ran, why when it failed")
    func runOnce() async {
        let ran = Mutex<(onMain: Bool, command: DriveRoute.Command)?>(nil)
        #expect(await DriveModule.runOnce("true") { command in
            ran.withLock { $0 = (pthread_main_np() != 0, command) }
            return ""
        } == nil)
        #expect(ran.withLock { $0?.onMain } == false)
        #expect(ran.withLock { $0?.command } == DriveRoute.shell("true").command(loginShell: DriveModule.loginShell))
        #expect(await DriveModule.runOnce("true") == nil)
        let failed = await DriveModule.runOnce("echo nope >&2; exit 3")
        #expect(failed?.contains("exited 3") == true && failed?.contains("nope") == true, "\(failed ?? "nil")")
    }

    @Test("A shell command, a menu item, keys and an App URL bind as their routes, read back whole")
    func routes() throws {
        let keys = try #require(Key(spelling: "cmd+shift+t"))
        for route in Self.formRoutes + [.keystroke(keys)] {
            var store = Self.store()
            #expect(try Self.save(route.id, to: Self.t, in: &store).verb == .save)
            #expect(store.action(for: Self.t) == route.id && DriveRoute(id: route.id) == route)
        }
    }

    @Test("Cancel from the shell, menu item and App URL forms, and a refused shell, menu or URL bind, leave binds.json as it was")
    func formsUntouched() throws {
        let engine = Engine()
        engine.binds.replace("windows.focusLeft", with: Key("y"))
        let file = engine.binds.fileURL
        let before = try Data(contentsOf: file)
        let actions = engine.bindActions
        let shell = BindFinder(scope: .shell, sources: Self.sources), menu = BindFinder(query: "new", scope: .menu, sources: Self.sources)
        let url = BindFinder(scope: .appURL, sources: Self.sources)
        let forms: [(BindFinder, BindEditor)] = [
            (shell, BindEditor(action: nil, actions: actions, startKey: Self.t, windowHeight: 660, finder: shell, does: .advanced, advanced: .shell,
                               field: "open -g ~/Downloads")),
            (menu, BindEditor(action: nil, actions: actions, startKey: Self.t, windowHeight: 660, finder: menu, does: .menu, bundle: "dev.banozz.not-running")),
            (url, BindEditor(action: nil, actions: actions, startKey: Self.t, windowHeight: 660, finder: url, does: .advanced, advanced: .url,
                             field: "shottr://grab/window")),
        ]
        for (finder, editor) in forms {
            let kind = finder.scope
            testApp()
            let host = NSHostingView(rootView: editor.environment(engine).styled(.page(.binds)))
            host.frame.size = host.fittingSize
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            PanelTestSupport.pump(0.3)
            // Esc clears the menu's search, then drops the kind, then cancels; nothing is written.
            let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            for _ in 0..<3 {
                #expect(host.performKeyEquivalent(with: esc))
                PanelTestSupport.pump(0.1)
            }
            #expect(finder.scope == nil && finder.query.isEmpty, "\(String(describing: kind))")
            w.close()
            PanelTestSupport.pump(0.1)
            #expect(try Data(contentsOf: file) == before, "\(String(describing: kind))")
        }
        // Binds refused (the key is taken): nothing written.
        for route in Self.formRoutes {
            #expect(throws: BindStore.BindError.self) { try engine.binds.set(route.id, to: Key("y")) }
        }
        #expect(try Data(contentsOf: file) == before)
    }

    /// The editor in an offscreen window, never shown, its onAppear run.
    static func hosted(_ editor: BindEditor, _ engine: Engine) -> NSWindow {
        testApp()
        let host = NSHostingView(rootView: editor.environment(engine).styled(.page(.binds)))
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        PanelTestSupport.pump(0.3)
        return w
    }

    /// Return, with `flags`, as the sheet's key equivalents get it: true when a button took it.
    static func pressReturn(_ w: NSWindow, _ flags: NSEvent.ModifierFlags = []) throws -> Bool { try press(w, "\r", code: 36, flags) }

    /// A key, with `flags`, as the sheet's key equivalents get it: true when a button took it.
    static func press(_ w: NSWindow, _ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                                  keyCode: code))
        defer { PanelTestSupport.pump(0.1) }
        return w.contentView?.performKeyEquivalent(with: event) == true
    }

    @Test("Return in the shell's focused command never saves; ⌘↵ saves it; Return in the App URL field saves")
    func returnInShell() throws {
        let engine = Engine()
        engine.binds.replace("windows.focusLeft", with: Key("y"))
        let file = engine.binds.fileURL
        let before = try Data(contentsOf: file), held = engine.binds.store.action(for: Self.t)  // Hyper+T drops the terminal by default
        let command = DriveRoute.shell("open -g ~/Downloads")
        let shell = BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660,
                               finder: BindFinder(scope: .shell, sources: Self.sources), does: .advanced, advanced: .shell, field: "open -g ~/Downloads")
        let w = Self.hosted(shell, engine)
        defer { w.close() }
        #expect(w.firstResponder is NSTextView, "the command has the keys")
        #expect(try !Self.pressReturn(w))
        #expect(try Data(contentsOf: file) == before && engine.binds.store.action(for: Self.t) == held)
        #expect(try Self.pressReturn(w, .command))
        #expect(engine.binds.store.action(for: Self.t) == command.id)

        let link = DriveRoute.url("shottr://grab/window")
        let url = BindEditor(action: nil, actions: engine.bindActions, startKey: Key("u"), windowHeight: 660,
                             finder: BindFinder(scope: .appURL, sources: Self.sources), does: .advanced, advanced: .url, field: "shottr://grab/window")
        let w2 = Self.hosted(url, engine)
        defer { w2.close() }
        #expect(try Self.pressReturn(w2))
        #expect(engine.binds.store.action(for: Key("u")) == link.id)
    }

    @Test("The menu item form never binds an edited bind's old path to the app picked after; the row picked binds")
    func menuStalePath() throws {
        let engine = Engine()
        engine.binds.replace("windows.focusLeft", with: Key("y"))
        let file = engine.binds.fileURL
        let before = try Data(contentsOf: file), held = engine.binds.store.action(for: Self.t)  // Hyper+T drops the terminal by default
        // Zen's File > New Window edited, then Press a menu item and another app (not running) picked.
        let other = "dev.banozz.not-running", finder = BindFinder(scope: .menu, sources: Self.sources)
        let editor = BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder,
                                does: .menu, bundle: other, menuPath: "File > New Window")
        let w = Self.hosted(editor, engine)
        defer { w.close() }
        #expect(try !Self.pressReturn(w, .command))
        #expect(try Data(contentsOf: file) == before && engine.binds.store.action(for: Self.t) == held)
        // Its typed path, picked, binds.
        let row = try #require(BindEditor.menuRows([], query: "File > Save As", bundle: other).first)
        finder.picked = row.id
        finder.scope = nil
        PanelTestSupport.pump(0.1)
        #expect(try Self.pressReturn(w, .command))
        #expect(engine.binds.store.action(for: Self.t) == DriveRoute.menu(bundle: other, path: ["File", "Save As"]).id)
    }

    // MARK: Suggest with AI (spec ai-binds T2)

    /// Chrome and Safari on the Mac, beside the editor's usual sources.
    static let aiSources = BindSearch.Sources(
        apps: sources.apps + [("Google Chrome", "com.google.Chrome"), ("Safari", "com.apple.Safari")],
        browsers: [("Google Chrome", "com.google.Chrome"), ("Safari", "com.apple.Safari")], actions: sources.actions)
    static let youtube = "apps.url:com.google.Chrome:https://youtube.com"

    /// A ready "Claude" whose runner answers `answer`, or `failure`.
    static func ai(_ answer: String = #"{"id": null, "reason": "-"}"#, failure: QuickAI.Failure? = nil) -> BindFinder.AI {
        BindFinder.AI(provider: { "Claude" }, runner: { failure.map { .failure($0) } ?? .success({ _, _ in answer }) }, handles: { _ in false })
    }

    /// A ready "Claude" that answers only when stopped.
    static var slow: BindFinder.AI { BindFinder.AI(provider: { "Claude" }, runner: { .success(waits) }, handles: { _ in false }) }

    @Sendable static func waits(_: QuickAI.Job, _: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String {
        try? await Task.sleep(for: .seconds(5))
        throw .cancelled
    }

    static func answer(_ id: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["id": id, "reason": "r"]), encoding: .utf8)!
    }

    /// Lets the main actor run the ask and the window redraw until `done` holds, up to two seconds: a pump alone runs
    /// inside the test's own main-actor job, so the ask's would wait.
    static func settle(until done: () -> Bool) async {
        for _ in 0..<50 where !done() {
            try? await Task.sleep(for: .milliseconds(20))
            PanelTestSupport.pump(0.02)
        }
        PanelTestSupport.pump(0.1)
    }

    /// Return in the search field, as typed: its onSubmit picks the highlighted row.
    static func submit(_ w: NSWindow) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        let root = try #require(w.contentView)
        let search = try #require(fields(root).first { $0.isEditable }, "the search field")
        w.makeFirstResponder(search)
        let editor = try #require(w.firstResponder as? NSTextView, "the search has the keys")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        PanelTestSupport.pump(0.1)
    }

    @Test("With an AI ready, a sentence only the shell row matches lists Suggest with AI first under AI; All counts neither; no AI, no row")
    func suggestRow() throws {
        let finder = BindFinder(query: "go to youtube in chrome", sources: Self.aiSources, ai: Self.ai())
        let (lines, chips) = finder.listing { _ in nil }
        #expect(lines.map(\.title) == ["Suggest with AI: go to youtube in chrome", "Run go to youtube in chrome as a shell command"])
        #expect(lines.map(\.heading) == ["AI", "Or"])
        #expect(lines.first?.detail == "Sends these words and your app names to Claude")
        #expect(chips.first?.count == 0)
        let plain = BindFinder(query: "go to youtube in chrome", sources: Self.aiSources)
        #expect(plain.listing { _ in nil }.lines.map(\.title) == ["Run go to youtube in chrome as a shell command"])
        let notReady = BindFinder(query: "go to youtube in chrome", sources: Self.aiSources,
                                  ai: BindFinder.AI(provider: { nil }, runner: { .failure(.missing) }, handles: { _ in false }))
        #expect(notReady.listing { _ in nil }.lines.count == 1)
    }

    @Test("Return on Suggest with AI: Chrome's answer folds the list to its card, the row's id never picked, binds.json untouched")
    func suggestCard() async throws {
        let engine = Engine()
        let file = engine.binds.fileURL, before = try Data(contentsOf: file), held = engine.binds.store.action(for: Self.t)
        let finder = BindFinder(query: "go to youtube in chrome", sources: Self.aiSources, ai: Self.ai(Self.answer(Self.youtube)))
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        await Self.settle { finder.picked != nil }
        #expect(finder.picked == Self.youtube)
        #expect(finder.suggested && finder.query.isEmpty && finder.asking == nil)
        #expect(try Data(contentsOf: file) == before && engine.binds.store.action(for: Self.t) == held)
        // Save is the person's: ⌘↵ binds the card's action, never the AI row.
        #expect(try Self.pressReturn(w, .command))
        #expect(engine.binds.store.action(for: Self.t) == Self.youtube)
        #expect(engine.binds.store.action(for: Self.t) != BindAI.rowID)
    }

    @Test("open youtube in chrome lists Chrome on youtube.com first, and Return picks it at once, the AI never asked")
    func localFirst() async throws {
        let engine = Engine()
        let never = BindFinder.AI(provider: { "Claude" }, runner: { Issue.record("the AI was asked"); return .failure(.missing) }, handles: { _ in false })
        let finder = BindFinder(query: "open youtube in chrome", sources: Self.aiSources, ai: never)
        #expect(finder.listing { _ in nil }.lines.map(\.title)
                == ["Open youtube.com in Google Chrome", "Suggest with AI: open youtube in chrome", "Run open youtube in chrome as a shell command"])
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        #expect(finder.picked == Self.youtube && !finder.suggested && finder.asking == nil)
    }

    @Test("A shell answer opens the Shell form with the whole command and nothing saved; ⌘↵ then binds it")
    func suggestShell() async throws {
        let engine = Engine()
        let file = engine.binds.fileURL, before = try Data(contentsOf: file)
        let command = #"osascript -e 'tell application "Finder" to empty trash'"#
        let finder = BindFinder(query: "empty the trash", sources: Self.aiSources, ai: Self.ai(Self.answer("drive.shell:" + command)))
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        await Self.settle { finder.scope == .shell }
        #expect(finder.scope == .shell && finder.suggested && finder.picked == nil)
        #expect((w.firstResponder as? NSTextView)?.string == command, "the command is in the form, in full")
        #expect(try Data(contentsOf: file) == before)
        #expect(try Self.pressReturn(w, .command))
        #expect(engine.binds.store.action(for: Self.t) == DriveRoute.shell(command).id)
    }

    @Test("A menu answer opens its app's menus with the guess first; a guess in another app, or with words typed, leads nothing (Q128)")
    func suggestMenu() async throws {
        let items = MenuItemSearch.entries(Self.bar, bundle: Self.zen)
        let real = DriveRoute.menu(bundle: Self.zen, path: ["File", "New Private Window"]).id
        let rows = BindEditor.menuRows(items, query: "", bundle: Self.zen, guess: real)
        #expect(rows.first?.id == real && rows.first?.key != nil && rows.count == 3)
        let made = DriveRoute.menu(bundle: Self.zen, path: ["Tools", "Downloads"]).id
        let guessed = BindEditor.menuRows(items, query: "", bundle: Self.zen, guess: made)
        #expect(guessed.first == .init(id: made, path: "Press Tools › Downloads") && guessed.count == 4)
        #expect(BindEditor.menuRows(items, query: "", bundle: "com.apple.Notes", guess: made).allSatisfy { $0.id != made })
        #expect(BindEditor.menuRows(items, query: "history", bundle: Self.zen, guess: made).first?.id != made)

        let engine = Engine()
        let file = engine.binds.fileURL, before = try Data(contentsOf: file)
        let finder = BindFinder(query: "new private window in zen", sources: Self.aiSources,
                                ai: Self.ai(Self.answer(made.replacingOccurrences(of: Self.zen, with: "com.apple.Safari"))))
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        await Self.settle { finder.scope == .menu }
        #expect(finder.scope == .menu && finder.guess == DriveRoute.menu(bundle: "com.apple.Safari", path: ["Tools", "Downloads"]).id)
        #expect(finder.picked == nil && finder.suggested)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("While it asks the row spins and says so; Esc stops it and keeps the sheet; no bind and a failure say why in the row")
    func suggestStates() async throws {
        let engine = Engine()
        let file = engine.binds.fileURL, before = try Data(contentsOf: file)
        let finder = BindFinder(query: "go to youtube in chrome", sources: Self.aiSources, ai: Self.slow)
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        #expect(finder.asking == .running("Claude"))
        let running = try #require(finder.listing { _ in nil }.lines.first)
        #expect(running.busy && running.detail == "Asking Claude…")
        #expect(try Self.press(w, "\u{1b}", code: 53))
        #expect(finder.asking == nil && finder.query == "go to youtube in chrome", "Esc stopped the ask, not the sheet")

        let none = BindFinder(query: "make coffee", sources: Self.aiSources, ai: Self.ai(#"{"id": null, "reason": "A key cannot make coffee"}"#))
        none.ask("make coffee") { _ in Issue.record("no bind applies nothing") }
        await Self.settle { none.asking?.running == false }
        #expect(none.listing { _ in nil }.lines.first?.detail == "No bind found: A key cannot make coffee")
        none.query = "make tea"
        #expect(none.asking == nil, "new words drop the old answer's status")
        let failed = BindFinder(query: "make coffee", sources: Self.aiSources, ai: Self.ai(failure: .noKey(.anthropicAPI)))
        failed.ask("make coffee") { _ in Issue.record("a failure applies nothing") }
        #expect(failed.listing { _ in nil }.lines.first?.detail == "No Anthropic API key set")
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("A shell answer of several lines or over 200 characters is no bind; one that fits shows whole in a box sized to it")
    func suggestShellWhole() async throws {
        #expect(BindFinder.shown(.form(.shell("ls\nrm -rf ~/x"))) == .none("The command is too long to check here"))
        #expect(BindFinder.shown(.form(.shell(String(repeating: "x", count: 201)))) == .none("The command is too long to check here"))
        #expect(BindFinder.shown(.form(.shell(String(repeating: "x", count: 200)))) == .form(.shell(String(repeating: "x", count: 200))))
        let hidden = BindFinder(query: "clean up", sources: Self.aiSources, ai: Self.ai(Self.answer("drive.shell:echo ok\nrm -rf ~/Downloads")))
        hidden.ask("clean up") { _ in Issue.record("a command with a hidden line applies nothing") }
        await Self.settle { hidden.asking?.running == false }
        #expect(hidden.asking == .noBind("The command is too long to check here"))

        // 200 characters on one line: the box holds every wrapped line, more than the usual 76 pt box shows.
        let engine = Engine()
        let command = "osascript -e 'tell application \"Finder\" to empty trash' && " + String(repeating: "echo done && ", count: 9) + "true"
        #expect(command.count <= BindFinder.shellLimit && command.count > 150)
        let finder = BindFinder(query: "empty the trash", sources: Self.aiSources, ai: Self.ai(Self.answer("drive.shell:" + command)))
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        await Self.settle { finder.scope == .shell }
        // The sheet fits its content, as the real one does.
        let host = try #require(w.contentView)
        w.setContentSize(host.fittingSize)
        PanelTestSupport.pump(0.2)
        let text = try #require(w.firstResponder as? NSTextView)
        #expect(text.string == command)
        let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + text.textContainerInset.height * 2
        let shown = try #require(text.enclosingScrollView).contentView.bounds.height
        #expect(used > 60, "the command wraps past the usual box (\(used))")
        #expect(shown >= used, "the box shows \(shown) of \(used) pt")
    }

    @Test("Suggest with AI runs at low effort whatever the AI page's effort")
    func suggestLowEffort() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bind-ai-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "claude")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(folder.path)/args'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"{}"}'
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settings = AISettings(defaults: try #require(UserDefaults(suiteName: testSuite())), keys: AISettingsTests.FakeKeys(),
                                  http: AISettingsTests.NoNetwork())
        settings.findCLI = { ClaudeCLI(path: script.path, timeout: .seconds(10)) }
        settings.provider = .claudeCode
        settings.setEffort(.high, for: .claudeCode)
        let runner = try BindFinder.AI.settings(settings).runner().get()
        _ = try await runner(.bind("Request: x")) { _ in }
        let args = try String(contentsOf: folder.appending(path: "args"), encoding: .utf8).components(separatedBy: "\n")
        #expect(args.firstIndex(of: "--effort").map { args[$0 + 1] } == "low")
    }

    @Test("Closing the sheet while it asks stops the ask")
    func suggestStopsOnClose() async throws {
        let engine = Engine()
        let finder = BindFinder(query: "go to youtube in chrome", sources: Self.aiSources, ai: Self.slow)
        let w = Self.hosted(BindEditor(action: nil, actions: engine.bindActions, startKey: Self.t, windowHeight: 660, finder: finder), engine)
        defer { w.close() }
        try Self.submit(w)
        #expect(finder.asking == .running("Claude"))
        w.contentView = NSView()
        await Self.settle { finder.asking == nil }
        #expect(finder.asking == nil)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
