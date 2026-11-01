import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// Story 161: the top bar's Extensions item (ExtensionBar asks every bar item placed, one at a time, each on its pace, 60 s at the most
/// often, and only while held; the bar draws their texts, amber on a warn), an extension's page (its model asks, keeps
/// the last blocks over a failure, says an unset setting) and the app window's way to it (the sidebar marks it, any
/// other place leaves it). Folders are temporary; the runs are fakes, so no program starts.
@MainActor
@Suite("Extension surfaces in Pilot")
struct ExtensionSurfaceTests {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000) }

    /// An extension `id` with a bar item and a page, both every `every` s, and a required setting when `required`.
    static func write(_ id: String, title: String, every: Int = 120, page: Bool = true, required: Bool = false, in dir: URL) throws {
        let prefs = required ? #", "preferences": [{"name": "token", "type": "text", "title": "Token", "required": true}]"# : ""
        let surfaces = page ? #"{"bar": {"command": "bar", "every": \#(every)}, "page": {"command": "bar", "every": \#(every)}}"#
            : #"{"bar": {"command": "bar", "every": \#(every)}}"#
        try ExtensionCatalogueModelTests.write(#"{"id": "\#(id)", "title": "\#(title)", "icon": "📊", "surfaces": \#(surfaces)\#(prefs), "commands": [{"name": "bar", "title": "Bar", "mode": "no-view", "hidden": true, "run": "run"}]}"#,
                                               as: id, in: dir)
    }

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-surfaces-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appending(path: "Extensions"), withIntermediateDirectories: true)
        return dir
    }

    static func storage(_ dir: URL) -> ExtensionStorage {
        ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: ExtensionsModuleTests.FakeKeychain())
    }

    @Test("The bar lists every item by title and asks every one placed, past the old six (Sven on build 52), each answer or problem kept; a second round within the pace asks nothing")
    func barRounds() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        let names = [("a", "Alpha"), ("b", "Bravo"), ("c", "Charlie"), ("d", "Delta"), ("e", "Echo"), ("f", "Foxtrot"), ("g", "Golf")]
        for (id, title) in names { try Self.write(id, title: title, in: exts) }
        try Self.write("h", title: "Hotel", required: true, in: exts)
        let asked = Mutex<[String]>([]), clock = Clock()
        let bar = ExtensionBar(folder: exts, storage: Self.storage(dir), now: { clock.now }) { surface, _ in
            asked.withLock { $0.append(surface.command.id.extension) }
            return surface.command.id.extension == "b" ? .error("did not answer in 2 s") : .bar(Extension.BarAnswer(text: "\(surface.command.id.extension) 52%", tone: .warn))
        }
        let wait = await bar.round()
        #expect(asked.withLock { $0 } == ["a", "b", "c", "d", "e", "f", "g"], "every one placed, by title; Hotel's unset setting is said, not run")
        #expect(bar.items.map(\.id) == ["a", "b", "c", "d", "e", "f", "g", "h"] && bar.items[1].problem == "did not answer in 2 s" && bar.items[1].answer == nil)
        #expect(bar.items[6].problem == nil && bar.items[6].answer?.text == "g 52%", "the seventh shows")
        #expect(bar.items[7].answer == nil && bar.items[7].problem != nil)
        #expect(bar.faces(in: .menuBar).map(\.text) == ["a 52%", "c 52%", "d 52%", "e 52%", "f 52%", "g 52%"] && wait == 120)
        clock.now += 30
        #expect(await bar.round() == 90)
        #expect(asked.withLock { $0.count } == 7, "nothing is due yet")
        clock.now += 90
        await bar.round()
        #expect(asked.withLock { $0.count } == 14)
    }

    @Test("An item turned off is no longer asked and keeps what it last said; the rest, lazygit past GitHub too, still are (Sven, build 21: Git renamed lazygit sorted past GitHub)")
    func barRoom() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        let names = [("ai-usage", "AI usage"), ("battery", "Battery"), ("clock", "Clock"), ("disk", "Disk"), ("ghostex", "Ghostex sessions"), ("github", "GitHub"), ("git", "lazygit")]
        for (id, title) in names { try Self.write(id, title: title, in: exts) }
        let asked = Mutex<[String]>([]), clock = Clock()
        let bar = ExtensionBar(folder: exts, storage: Self.storage(dir), now: { clock.now }) { surface, _ in
            asked.withLock { $0.append(surface.command.id.extension) }
            return .bar(Extension.BarAnswer(text: surface.command.id.extension))
        }
        var off: Set<String> = []
        bar.shows = { id, _ in !off.contains(id) }
        await bar.round()
        let all = ["ai-usage", "battery", "clock", "disk", "ghostex", "github", "git"]
        #expect(asked.withLock { $0 } == all && bar.items.map(\.id) == all && bar.faces(in: .menuBar).map(\.text) == all)
        off = ["github"]
        clock.now += 120
        await bar.round()
        #expect(Array(asked.withLock { $0 }.dropFirst(all.count)) == all.filter { $0 != "github" }, "the one turned off is not asked")
        #expect(bar.faces(in: .menuBar).map(\.text) == all.filter { $0 != "github" })
        #expect(bar.items[5].problem == nil && bar.items[5].answer?.text == "github", "the one turned off keeps what it last said")
    }

    @Test("Twelve bar items on the fastest pace cost at most twelve short runs a minute, never two at once")
    func barCost() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        for index in 0..<12 { try Self.write("x\(index)", title: "X\(index)", every: 1, in: exts) }
        let runs = Mutex(0), running = Mutex((now: 0, most: 0)), clock = Clock()
        let bar = ExtensionBar(folder: exts, storage: Self.storage(dir), now: { clock.now }) { _, _ in
            runs.withLock { $0 += 1 }
            running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            try? await Task.sleep(for: .milliseconds(5))
            running.withLock { $0.now -= 1 }
            return .bar(Extension.BarAnswer(text: "x"))
        }
        // Ten minutes on the bar's own waits.
        var elapsed = 0
        while elapsed < 600 {
            let wait = await bar.round()
            #expect(wait >= 60)
            clock.now += Double(wait)
            elapsed += wait
        }
        #expect(runs.withLock { $0 } == 12 * 10, "every one asked each minute, no more")
        #expect(running.withLock { $0.most } == 1, "one run at a time")
    }

    @Test("A bar item never asks more often than once a minute, and an unset setting is said, not run")
    func barFloorAndSettings() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        try Self.write("fast", title: "Fast", every: 1, in: exts)
        try Self.write("needy", title: "Needy", required: true, in: exts)
        let asked = Mutex(0)
        let bar = ExtensionBar(folder: exts, storage: Self.storage(dir), run: { _, _ in asked.withLock { $0 += 1 }; return .bar(Extension.BarAnswer(text: "x")) })
        #expect(await bar.round() == 60)
        #expect(asked.withLock { $0 } == 1 && bar.items.first { $0.id == "needy" }?.problem == "Needy needs Token set first.")
    }

    @Test("Start runs a round and stop ends the loop; the items keep their last answers")
    func startStop() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write("a", title: "Alpha", in: dir.appending(path: "Extensions"))
        let bar = ExtensionBar(folder: dir.appending(path: "Extensions"), storage: Self.storage(dir), run: { _, _ in .bar(Extension.BarAnswer(text: "ok")) })
        bar.start()
        #expect(bar.isRunning)
        // Generous: a full parallel run keeps the main actor busy.
        let deadline = Date().addingTimeInterval(60)
        while bar.faces(in: .menuBar).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        bar.stop()
        #expect(!bar.isRunning && bar.faces(in: .menuBar).map(\.text) == ["ok"])
    }

    @Test("An extension's run asks its bar item again at once, not at its next turn (Sven on build 23: to-do's count lagged)")
    func barAsk() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write("a", title: "Alpha", in: dir.appending(path: "Extensions"))
        let count = Mutex(0)
        // The nap between rounds never ends by itself: a second answer can only come from the ask.
        let bar = ExtensionBar(folder: dir.appending(path: "Extensions"), storage: Self.storage(dir), run: { _, _ in
            .bar(Extension.BarAnswer(text: "\(count.withLock { $0 += 1; return $0 })"))
        }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        bar.start()
        #expect(try await SystemSamplerTests.wait { bar.faces(in: .menuBar).map(\.text) == ["1"] })
        bar.ask("a")
        #expect(try await SystemSamplerTests.wait { bar.faces(in: .menuBar).map(\.text) == ["2"] }, "asked, not left to its pace")
        bar.stop()
        #expect(!bar.isRunning)
    }

    @Test("The top bar's Extensions item draws each extension placed there as its own target, and hides with none; a saved layout gains it on")
    func barItem() throws {
        var i = BarInputs()
        let entry = BarSettings.defaults.entry(.extensions)
        #expect(entry.on && entry.placement == .topBar && entry.side == .right && BarKind.extensions.topBarOnly)
        #expect(BarParts.parts(entry, i) == nil && BarTooltip.text(.extensions, i) == "No extension shows anything here")
        let ai = ExtensionBarFace(id: "ai", title: "AI", answer: Extension.BarAnswer(text: "52%", tone: .fine))
        let ci = ExtensionBarFace(id: "ci", title: "CI", answer: Extension.BarAnswer(text: "2 red", tone: .alert))
        i.extensionBars = [ai, ci]
        let parts = try #require(BarParts.parts(entry, i))
        #expect(parts == [.extensionItem(ai), .extensionItem(ci)])
        #expect(BarParts.targets([parts], click: .popover).map(\.click) == [.extension("ai"), .extension("ci")], "each its own popover")
        #expect(BarTooltip.text(.extensions, i) == "AI · 52% · CI · 2 red")
        // A layout saved before the item existed.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BarSettings.defaults)) as! [String: Any]
        old["entries"] = (old["entries"] as! [[String: Any]]).filter { $0["kind"] as? String != "extensions" }
        let read = try JSONDecoder().decode(BarSettings.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(read.entry(.extensions).on && read.entry(.extensions).placement == .topBar)
    }

    @Test("A page asks its command, keeps its blocks over a later failure with the failure said, and says an unset setting")
    func pageModel() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        try Self.write("usage", title: "Usage", every: 30, in: exts)
        try Self.write("needy", title: "Needy", required: true, in: exts)
        try Self.write("barred", title: "Barred", page: false, in: exts)
        let fail = Mutex(false)
        let run: @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome = { surface, _ in
            #expect(surface.kind == .page)
            return fail.withLock { $0 } ? .error("did not answer in 5 s") : .blocks([.markdown("hi")])
        }
        let model = ExtensionPageModel(id: "usage", folder: exts, storage: Self.storage(dir), run: run)
        await model.refresh()
        #expect(model.blocks == [.markdown("hi")] && model.problem == nil && model.every == 30 && model.updated != nil)
        fail.withLock { $0 = true }
        await model.refresh()
        #expect(model.blocks == [.markdown("hi")] && model.problem == "Usage did not answer in 5 s")
        let needy = ExtensionPageModel(id: "needy", folder: exts, storage: Self.storage(dir), run: run)
        await needy.refresh()
        #expect(needy.needsSettings && needy.problem == "Needy needs Token set first." && needy.blocks == nil)
        let gone = ExtensionPageModel(id: "gone", folder: exts, storage: Self.storage(dir), run: run)
        await gone.refresh()
        #expect(gone.gone)
        let found = Extension.find(in: exts).extensions
        #expect(ExtensionPages.links(found).map(\.id) == ["needy", "usage"], "Home's blocks: only the ones with a page, by title")
        // The sidebar lists every one (Sven 2026-10-16: Now playing was missing); a bar item alone opens as a page.
        #expect(ExtensionPages.entries(found).map(\.id) == ["barred", "needy", "usage"] && ExtensionPages.entries(found).allSatisfy(\.opens))
    }

    @Test("An extension with only a bar item shows its popover as its page, at a page's pace; one with neither opens no page")
    func barOnlyPage() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        try Self.write("barred", title: "Barred", every: 300, page: false, in: exts)
        try ExtensionCatalogueModelTests.write(#"{"id": "plain", "title": "Plain", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                                               as: "plain", in: exts)
        let run: @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome = { surface, _ in
            #expect(surface.kind == .popover && surface.command.name == "bar")
            return .blocks([.markdown("playing")])
        }
        let model = ExtensionPageModel(id: "barred", folder: exts, storage: Self.storage(dir), run: run)
        await model.refresh()
        #expect(!model.gone && model.blocks == [.markdown("playing")] && model.every == 300)
        let found = Extension.find(in: exts).extensions
        #expect(ExtensionPages.entries(found).map(\.opens) == [true, false])
        // Its sidebar row: no page, so Installed opens on its card.
        let window = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        window.focusExtension("plain")
        #expect(window.page == .extensions && window.extensionPage == nil && window.extensionFocus == "plain")
    }

    @Test("⌃Tab in Extensions steps Installed, then each extension that opens a page, round to Installed; elsewhere the area's pages")
    func nextPage() throws {
        let window = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let entries = [ExtensionPages.Link(id: "a", title: "A", icon: nil), ExtensionPages.Link(id: "b", title: "B", icon: nil)]
        window.go(AppPlace(.extensionCatalogue))
        window.nextPage(entries: entries)
        #expect(window.extensionPage == "a")
        window.nextPage(entries: entries)
        #expect(window.extensionPage == "b")
        window.nextPage(entries: entries)
        #expect(window.page == .extensions && window.extensionPage == nil)
        window.go(AppPlace(.workspaces))
        window.nextPage(entries: entries)
        #expect(window.page == .tiling)
    }

    @Test("The window shows an extension's page under Extensions: the sidebar marks it, not Extensions, its tabs go; any other place leaves it")
    func windowPlace() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let model = AppWindowModel(defaults: defaults)
        model.go(AppPlace(.extensionCatalogue))
        model.goExtensionPage("usage")
        #expect(model.page == .extensions && model.extensionPage == "usage" && model.section(of: .extensions) == nil)
        #expect(!model.shows(.extensions) && model.tabs.isEmpty && model.title.hasSuffix("usage"))
        model.go(AppPlace(.extensions))
        #expect(model.extensionPage == nil && model.shows(.extensions) && model.tabs.isEmpty)
        model.goExtensionPage("usage")
        model.go(AppPlace(.binds))
        #expect(model.extensionPage == nil && model.shows(.binds))
    }
}
