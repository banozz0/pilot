#if DEBUG
import AppKit
import Clipboard
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pages that fill the window (card agent-bo-95423004; Sven, 2026-10-07: "this half empty screen is nearly on all
/// pages/panels fix all of them"): what each page lists once it shows everything it has, not one short block.
@MainActor
@Suite("Fill pages")
struct FillPagesTests {
    static func entries() throws -> [CatalogueEntry] { try InstallCatalogue.parse(Data(contentsOf: RestyledPagesTests.shipped)) }

    @Test("An empty search shows every category as its own section with all its entries, and no Suggested (Sven 2026-10-09)")
    func catalogueSections() throws {
        let entries = try Self.entries()
        let sections = CataloguePage.sections(entries, query: "", category: nil)
        #expect(sections.map(\.title) == InstallCatalogue.categories(entries))
        #expect(sections.map(\.entries.count).reduce(0, +) == entries.count)
    }

    /// Sven 2026-10-09: Recommend apps is the whole catalogue of quick installs; off, Install is its search alone.
    @Test("With Recommend apps off the catalogue lists nothing: no category, no search match, no chosen category")
    func catalogueWithoutRecommendations() throws {
        let entries = try Self.entries()
        let first = try #require(entries.first)
        #expect(CataloguePage.sections(entries, query: "", category: nil, recommend: false).isEmpty)
        #expect(CataloguePage.sections(entries, query: first.name, category: nil, recommend: false).isEmpty)
        #expect(CataloguePage.sections(entries, query: "", category: first.category, recommend: false).isEmpty)
    }

    @Test("Only an app wearing its category's glyph shows its initial; a tool keeps its terminal, a font its glyph")
    func catalogueLetters() throws {
        let entries = try Self.entries()
        let tool = try #require(entries.first { $0.method.package?.kind == .formula })
        let font = try #require(entries.first { $0.category == "Fonts" })
        let app = try #require(entries.first { $0.method.package?.kind == .cask && $0.category != "Fonts" && MenuIcon.catalogue($0).symbol == MenuIcon.category($0.category).symbol })
        #expect(CataloguePage.letter(tool) == nil)
        #expect(CataloguePage.letter(font) == nil)
        #expect(CataloguePage.letter(app) == String(app.name.prefix(1)))
    }

    @Test("Clean's glyphs match whole words: Archives is not Arc's cache, Login items are not logs; plurals still match")
    func cleanWholeWords() {
        let browser = MenuIcon.clean(title: "Arc cache", section: "").symbol, logs = MenuIcon.clean(title: "System logs", section: "").symbol
        #expect(MenuIcon.clean(title: "Archives", section: "").symbol != browser)
        #expect(MenuIcon.clean(title: "Login items", section: "").symbol != logs)
        #expect(MenuIcon.clean(title: "Downloads", section: "").symbol == "arrow.down.circle")
        #expect(MenuIcon.clean(title: "App leftovers", section: "").symbol == "app.badge")
        #expect(MenuIcon.clean(title: "Xcode DerivedData", section: "").symbol == "hammer")
    }

    @Test("A category chip shows that category alone; a search its matches alone")
    func catalogueNarrowed() throws {
        let entries = try Self.entries()
        let one = CataloguePage.sections(entries, query: "", category: "Browsers")
        #expect(one.map(\.title) == ["Browsers"] && one[0].entries.allSatisfy { $0.category == "Browsers" })
        let found = CataloguePage.sections(entries, query: "ghostty", category: nil)
        #expect(found.count == 1 && found[0].entries.map(\.name) == ["Ghostty"])
        #expect(CataloguePage.sections(entries, query: "zzzz", category: nil).first?.entries.isEmpty == true)
    }

    @Test("Web apps recommends 10 to 16 well-known sites, each its own https site with its own 128 px icon shipped, marked once made")
    func webAppIdeas() throws {
        let ideas = WebAppIdea.all
        #expect((10...16).contains(ideas.count))
        #expect(Set(ideas.map(\.host)).count == ideas.count && Set(ideas.map(\.id)).count == ideas.count)
        #expect(ideas.allSatisfy { URL(string: $0.link)?.scheme == "https" })
        // Scripts/webapp-icons.swift fetched each from the site; build-app.sh ships the folder.
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packaging/webapp-icons")
        for idea in ideas {
            let rep = try #require(NSImage(contentsOf: folder.appending(path: "\(idea.id).png"))?.representations.first, "\(idea.id) has no icon")
            #expect(rep.pixelsWide == 128 && rep.pixelsHigh == 128, "\(idea.id)")
        }
        let shipped = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }
        #expect(Set(shipped) == Set(ideas.map { "\($0.id).png" }))
        let youtube = try #require(ideas.first { $0.name == "YouTube" })
        #expect(youtube.isMade(hosts: ["youtube.com"]) && !youtube.isMade(hosts: ["github.com"]))
    }

    @Test("Clipboard's Recent reads the newest copies first, at most the count asked, and says how many are kept")
    func clipboardRecent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(path: dir.appendingPathComponent("clips.sqlite"))
        for i in 0..<5 { _ = try store.add(.plainText("copy \(i)", sourceApp: "com.apple.Safari"), at: Date(timeIntervalSince1970: Double(1000 + i))) }
        let history = ClipboardHistory(defaults: UserDefaults(suiteName: testSuite())!, store: store)
        #expect(history.recent().prefix(3).map(\.text) == ["copy 4", "copy 3", "copy 2"])
        #expect(history.newest()?.count == 5)
        #expect(ClipboardHistory(defaults: UserDefaults(suiteName: testSuite())!).recent().isEmpty)
    }

    @Test("Setup shows every part at once, so which one a link opened draws the same page")
    func setupShowsAll() throws {
        let pages = RestyledPagesTests()
        #expect(try pages.pixels(SettingsPagesTests.setup(open: .sound)) == pages.pixels(SettingsPagesTests.setup(open: .keyboard)))
    }

    @Test("Setup draws a device as what it is, by its name")
    func setupDeviceGlyphs() {
        #expect(SetupGlyph.device("AirPods Pro") == "airpods")
        #expect(SetupGlyph.device("MX Master 3S") == "computermouse")
        #expect(SetupGlyph.device("Keychron K2") == "keyboard")
        #expect(SetupGlyph.device("MacBook Speakers") == "laptopcomputer")
        #expect(SetupGlyph.device("LG HDR 4K") == "tv")
        #expect(SetupGlyph.device("MacBook Microphone", input: true) == "laptopcomputer")
        #expect(SetupGlyph.device("Scarlett 2i2", input: true) == "mic")
        #expect(SetupGlyph.device("Scarlett 2i2") == "hifispeaker")
        #expect(SetupGlyph.device("Apple Watch") == "applewatch")
        #expect(SetupGlyph.device("Sven's iPhone") == "iphone")
    }

    /// The share of the rows in the window's bottom fifth that draw more than one flat colour, `page` drawn at
    /// 1000 × 900: a page that stops halfway leaves those rows the bare background and scores 0.
    static func footInk(_ page: some View) async throws -> Double {
        let rows = try await inkedRows(page, columns: 0..<1)
        let foot = rows[Int(Double(rows.count) * 0.8)...]
        return Double(foot.filter { $0 }.count) / Double(foot.count)
    }

    /// Whether each row, but the bottom 12 px, draws more than one flat colour between the `columns` fractions of the
    /// width, `page` drawn at 1000 × 900.
    static func inkedRows(_ page: some View, columns: Range<Double>) async throws -> [Bool] {
        let (look, _) = LookPageTests().look()
        testApp()
        let host = NSHostingView(rootView: page.frame(width: 1000, height: 900).pilotTheme(look: look))
        host.frame.size = CGSize(width: 1000, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        PanelTestSupport.pump()
        host.layoutSubtreeIfNeeded()
        return inked(try #require(snapshot(host)), columns: columns)
    }

    /// Whether each row of `rep`, but the bottom 12 px, draws more than one flat colour between the `columns` fractions.
    static func inked(_ rep: NSBitmapImageRep, columns: Range<Double>) -> [Bool] {
        guard let data = rep.bitmapData else { return [] }
        let wide = rep.pixelsWide
        let left = Int(Double(wide) * columns.lowerBound), right = min(wide, Int(Double(wide) * columns.upperBound))
        return (0..<rep.pixelsHigh - 12).map { y in
            let row = data + y * rep.bytesPerRow
            return (left + 1..<right).contains { x in (0..<3).contains { row[x * 4 + $0] != row[left * 4 + $0] } }
        }
    }

    /// The longest run of rows `inked` calls blank, as a share of them.
    static func longestBlank(_ rows: [Bool]) -> Double {
        var longest = 0, run = 0
        for inked in rows { run = inked ? 0 : run + 1; longest = max(longest, run) }
        return Double(longest) / Double(max(1, rows.count))
    }

    @Test("A config card's preview is the file's first lines that say something: blank lines skipped, secrets as dots")
    func configHead() {
        let text = "\n# Ghostty\n\nfont-size = 14   \napi_key = abc123\ntheme = nightwatch\nwindow-padding-x = 8\n"
        #expect(AppConfigs.head(text, 3) == ["# Ghostty", "font-size = 14", "api_key = ••••••"])
        #expect(AppConfigs.head(text, 9).count == 5)
        #expect(AppConfigs.head("\n\n", 4).isEmpty)
    }

    @Test("A growing card grid shares the window's spare height among its rows, so Stats' charts reach the foot")
    func cardGridGrows() async throws {
        func grid(grow: Bool) -> some View {
            CardGrid(minimum: 200, stretch: true, grow: grow) {
                ForEach(0..<6, id: \.self) { _ in Color.clear.frame(minHeight: 40).border(Color.red) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        #expect(try await Self.footInk(grid(grow: true)) > 0.9)
        #expect(try await Self.footInk(grid(grow: false)) < 0.1)
    }

    @Test("Clean, Update and Remove show what comes next while their list is read, each kind of row with its own glyph, until the read fails")
    func scans() throws {
        for (branch, heading) in [(MenuBranch.clean, "Mole is previewing what it would remove"), (.update, "Pilot is checking for updates"),
                                  (.remove, "Pilot is finding what can be removed")] {
            let model = MenuModel(nav: MenuNavigator(entries: [], branch: branch))
            let scan = try #require(model.scan, "\(branch)")
            #expect(scan.heading == heading)
            #expect(scan.steps.count == 3)
            let kinds = scan.kinds
            #expect(Set(kinds.map(\.icon.symbol)).count == kinds.count, "\(branch): two kinds share a glyph")
            model.failed(in: branch, "The list could not be read.")
            #expect(model.scan == nil, "\(branch)")
        }
        var typed = MenuNavigator(entries: [], branch: .update)
        typed.query = "zed"
        #expect(MenuModel(nav: typed).scan == nil, "a filter typed in Update says nothing matches, not that it is checking")
        #expect(MenuModel(nav: MenuNavigator(entries: [], branch: .snippets)).scan == nil)
        // The kinds follow the tools this Mac has: no bun, no bun globals; macOS updates need nothing.
        let update = MenuScan.update.kinds(on: ["brew", "npm"]).map(\.title)
        #expect(update == ["Homebrew formulae", "Homebrew casks", "macOS updates", "npm globals"])
    }

    @Test("Install scans while only its Searching row lists; the first result ends it and the selection is the panel's, not the scan's")
    func installScan() throws {
        let q = try #require(InstallSearch.Query("raycast"))
        var nav = MenuNavigator(entries: [], branch: .install)
        nav.query = "raycast"
        nav.provide(.package, home: .homebrew, MenuEntries.searching(q, waiting: [.homebrew, .appStore, .github, .tools]))
        let model = MenuModel(nav: nav)
        let scan = try #require(model.scan)
        #expect(scan.line == "Searching Homebrew, App Store, GitHub, Package tools… Return searches the web meanwhile.")
        #expect(Set(scan.kinds.map(\.icon.symbol)).count == scan.kinds.count)
        #expect(model.nav.selected.map(MenuEntries.isSearching) == true, "Return still searches the web while it scans")
        #expect(model.footerCommands.contains { $0.key == "↵" && $0.label == "Search the web" }, "the foot says what Return does")
        // The first answer, before any source has results, adds the "Add npm to search more" hint: still scanning.
        model.nav.provide(.package, home: .homebrew, MenuEntries.found([], query: q, waiting: [.homebrew, .appStore, .github, .tools], hint: .npm))
        #expect(model.scan != nil, "\(model.nav.rows.map(\.title))")
        #expect(model.nav.selected.map(MenuEntries.isSearching) == true)
        let brew = InstallSearch.Group(source: .homebrew, results: [
            InstallSearch.Result(title: "raycast", via: "Homebrew", source: .homebrew, method: .download(URL(string: "https://example.com/r.dmg")!))])
        model.nav.provide(.package, home: .homebrew, MenuEntries.found([brew], query: q, waiting: [.appStore, .github, .tools], hint: .npm))
        #expect(model.scan == nil)
        #expect(model.nav.selected?.title == "raycast", "Return takes the first result")
    }

    @Test("Clean's waiting screen carries Mole's live line under its heading (card agent-bo-95423026: 3004 had dropped it)", .pilotFocus)
    func cleanWaitingLine() throws {
        let model = MenuModel(nav: MenuNavigator(entries: [], branch: .clean))
        let panel = PanelTestSupport.open(MenuView(model: model))
        defer { panel.close() }
        // SwiftUI builds its accessibility tree only for an assistive client; this says one is here.
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        PanelTestSupport.pump()
        let shown = Self.labels(in: try #require(panel.contentView)).joined(separator: " | ")
        #expect(shown.contains("Mole is previewing what it would remove"))
        #expect(shown.contains(CleanMenu.waiting(CleanModule.previewer.progress)), "\(shown)")
    }

    /// Every accessibility label under `root`; SwiftUI's nodes answer the selectors without declaring the protocol.
    static func labels(in root: AnyObject) -> [String] {
        [root.accessibilityLabel?()].compactMap { $0 ?? nil } + (root.accessibilityChildren?() ?? []).flatMap { labels(in: $0 as AnyObject) }
    }

    @Test("The layer key's keyboard fits its column, scaled down when narrow and never past its full size (Moody: at 760 it ran off the edge)")
    func layerKeyFits() {
        testApp()
        let picture = NSHostingController(rootView: LayerKeyPicture(keys: [.capsLock, .rightCommand]).pilotTheme())
        #expect(picture.sizeThatFits(in: CGSize(width: 300, height: 2000)).width <= 300)
        #expect(picture.sizeThatFits(in: CGSize(width: 2000, height: 2000)).width <= 462)
    }

    @Test("Setup's keyboard boards read the layout in use with Shift and with Option held: 1 types !, Option changes the letters")
    func heldBoards() {
        func legends(_ held: KeyboardCaptions.Held) -> [Int64: String] {
            Dictionary(KeyboardCaptions.read(held).full.spots.compactMap { s in s.code.map { ($0, s.legend) } }, uniquingKeysWith: { a, _ in a })
        }
        let plain = legends(.none), shift = legends(.shift), option = legends(.option)
        #expect(plain[18] == "1" && shift[18] == "!", "1 key: \(plain[18] ?? "nil") / \(shift[18] ?? "nil")")
        #expect(plain.filter { option[$0.key] != $0.value }.count > 20)
        // ⌥A types å on Latin layouts: the Option board shows what it types, not a capital.
        #expect(option[0].map { $0 == $0.lowercased() } == true, "⌥A drew \(option[0] ?? "nil")")
    }

    @Test("The Pilot page's blocks sit in pairs only where two columns have room; narrower, one under the other")
    func pilotPairs() {
        // PageFlow's columns under KitPage, in Instrument (its gap is the density's padding, 18).
        #expect(PageFlow.columns(980, column: KitPage<EmptyView>.column(.instrument), gap: 18) == 2)
        #expect(PageFlow.columns(740, column: KitPage<EmptyView>.column(.instrument), gap: 18) == 1)
    }
}
#endif
