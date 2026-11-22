#if DEBUG
import AppKit
import CoreText
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The style seam (story 137, ADR 0008, card agent-bo-95423180): a fresh install and a saved Current are Instrument; a
/// styled surface reads the style's tokens and draws dark and light apart; the five bundled faces load at their weights.
/// Drawn offscreen on a Look of its own.
extension SharedLook {
@MainActor
@Suite("Style seam")
struct StyleTests {
    @Test("A fresh install is Instrument, and a saved Current or Toybox reads as Instrument with the pick dropped")
    func saved() {
        let defaults = LookTests.defaults()
        let look = Look(inputSources: SetupKeepAwakeTests.FakeSources(), defaults: defaults)
        #expect(look.style == .instrument)
        for old in ["current", "toybox"] {
            defaults.set(old, forKey: "look.style")
            #expect(Look(inputSources: SetupKeepAwakeTests.FakeSources(), defaults: defaults).style == .instrument)
            #expect(defaults.string(forKey: "look.style") == nil, "a saved \(old) was not dropped")
        }
    }

    /// What a probe surface read from the style environment.
    final class Seen { var tokens: StyleTokens? }

    /// A surface drawn from every kind of token: the canvas, a card with the style's depth, a line of body text.
    struct Probe: View {
        @Environment(\.style) private var style
        var seen: Seen?
        var body: some View {
            seen?.tokens = style
            return VStack(spacing: 8) {
                Text("Hyper 12:04").styleText(\.body)
                Text("WORKSPACES").styleText(\.eyebrow)
                Color.clear.frame(width: 120, height: 40).styleSurface(\.card)
            }
            .padding(20)
            .background(style.color(\.canvas))
        }
    }

    /// A page hosted on `look` (its theme roles) at 1000 by 900, drawn at 1x.
    func pixels(_ view: some View, look: Look) throws -> Data {
        var data = Data()
        try LookPageTests().hosted(view.frame(width: 1000, height: 900).pilotTheme(look: look)) { host in
            let rep = try #require(snapshot(host))
            data = Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
        }
        return data
    }

    /// Two draws that should match, as PNGs in the temporary folder when they do not, so a failure shows what moved (P12);
    /// the folder for the expectation's message.
    func same(_ a: Data, _ b: Data, _ name: String, width: Int = 1000, height: Int = 900) -> String? {
        guard a != b else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-style-mismatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (data, side) in [(a, "a"), (b, "b")] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: data.count / height, bitsPerPixel: 0)
            rep.flatMap { rep in rep.bitmapData.map { data.copyBytes(to: $0, count: min(data.count, rep.bytesPerRow * height)) } }
            try? rep?.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name)-\(side).png"))
        }
        return dir.path
    }

    /// `view` hosted on `look` at 1000 by 900 and drawn at 1x once two draws a moment apart agree: a page that measures
    /// itself (the window's width, what fits its height) takes a pass or two to settle; one that never does is an issue,
    /// its last two draws saved.
    func settled(_ view: some View, look: Look, _ name: String = "page") throws -> Data {
        var data = Data(), previous = Data()
        try LookPageTests().hosted(view.frame(width: 1000, height: 900).pilotTheme(look: look)) { host in
            @MainActor func draw() throws -> Data {
                PanelTestSupport.pump(0.1)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(host))
                return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
            }
            data = try draw()
            for _ in 0..<20 {
                let next = try draw()
                if next == data { return }
                previous = data
                data = next
            }
            Issue.record("\(name) never drew the same twice in 20 passes; draws in \(same(previous, data, name) ?? "-")")
        }
        return data
    }

    /// `view` hosted on `look` once; `body` gets a draw that pumps the run loop and returns the pixels at 1x.
    func hosting(_ view: some View, look: Look, _ body: (() throws -> Data) throws -> Void) throws {
        try LookPageTests().hosted(view.frame(width: 200, height: 160).pilotTheme(look: look)) { host in
            try body {
                PanelTestSupport.pump(0.05)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(host))
                return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
            }
        }
    }

    @Test("A styled surface reads the picked style's tokens, one step bigger on a page")
    func tokens() throws {
        let (look, _) = LookPageTests().look()
        let seen = Seen()
        try hosting(Probe(seen: seen).styled(.page(.home), look: look), look: look) { draw in
            for style in PilotStyle.allCases {
                look.style = style
                _ = try draw()
                // A page's tokens are one step bigger (C3, PilotStyle.scale).
                #expect(seen.tokens == StyleTokens.of(style, theme: look.theme).scaled(PilotStyle.scale), "\(style)")
            }
        }
    }

    @Test("A styled surface draws differently in dark and light")
    func drawn() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        func pick(_ style: PilotStyle) { look.style = style }
        try hosting(Probe().styled(.page(.home), look: look), look: look) { draw in
            pick(.instrument); let instrument = try draw()
            // Instrument is dark or light with its theme (its colours are the theme's): Paper's draws light.
            pick(.instrument); look.themeID = "porcelain"; #expect(try draw() != instrument && look.style == .instrument && look.theme.id == "porcelain" && !look.theme.dark, "Instrument on Paper drew Nightwatch")
            look.themeID = PilotTheme.defaultID
        }
    }

    @Test("Every page draws")
    func pages() throws {
        let (look, _) = LookPageTests().look()
        let pages: [(AppPage, AnyView)] = [
            (.workspaces, AnyView(RestyledPagesTests.workspacesBody())), (.install, AnyView(CataloguePage())),
            (.openWith, AnyView(OpenWithPage())),
            (.menu, AnyView(RestyledPagesTests.menuPage(.quicklinks))), (.system, AnyView(SettingsPagesTests.setup())),
            (.clipboard, AnyView(SettingsPagesTests.clipboard())),
        ]
        // Drawn once settled: a search field's placeholder sat a point higher on a page's first draw under load (P12).
        for (page, view) in pages {
            look.style = .instrument
            let instrument = try settled(view.styled(.page(page), look: look), look: look, "\(page)-instrument")
            #expect(Set(instrument).count > 16, "\(page) drew a blank page")
        }
    }

    /// Home's sources as fakes: no settings, nothing changed last.
    func fakes() throws -> HomeSources { .inert }

    /// Home on an engine that never starts.
    func homePage(_ engine: Engine) throws -> some View {
        HomePage { _ in }.environment(engine).environment(\.homeSources, try fakes())
    }

    @Test("Home draws Instrument, dark and light")
    func home() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        let page = try homePage(Engine()), home = StyleSurface.page(.home)
        look.style = .instrument
        let dark = try pixels(page.styled(home, look: look), look: look)
        look.style = .instrument
        look.themeID = "porcelain"
        defer { look.themeID = PilotTheme.defaultID }
        #expect(try pixels(page.styled(home, look: look), look: look) != dark, "Instrument on a light theme drew dark")
    }

    @Test("Binds draws Instrument, dark and light; Instrument's Binds owns its bar (card agent-bo-95423181)")
    func binds() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        let page = BindsKeyboardPage(search: "") { _ in }.environment(Engine()), binds = StyleSurface.page(.binds)
        look.style = .instrument
        let dark = try settled(page.styled(binds, look: look), look: look)
        look.style = .instrument
        look.themeID = "porcelain"
        #expect(try settled(page.styled(binds, look: look), look: look) != dark, "Instrument on a light theme drew dark")
        look.themeID = PilotTheme.defaultID
        #expect(InstrumentFrame.pageOwnsBar(.binds))
        #expect(!InstrumentFrame.pageOwnsBar(.home), "every other page keeps the frame's bar")
    }

    /// Two draws of the Defaults page differed: a test process starts on overlay scroll bars and moves to legacy ones, which
    /// take the page's width, once macOS sees the mouse, so a draw on each side of the move drew a narrower page.
    @Test("Hosted pages keep the scroll bars testApp() pinned, whatever mouse is attached, however long the process has run")
    func overlayScrollers() throws {
        // The pin holds from testApp() on, overlay or not: a full run whose other targets met AppKit long enough before the
        // first testApp() starts it on legacy, which a later pin never moves (probe, 2026-10-11; W10's full run). A page
        // draws the same either way as long as the style holds, which is what two draws of one page need.
        testApp()
        #expect(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)["AppleShowScrollBars"] as? String == "WhenScrolling")
        let pinned = NSScroller.preferredScrollerStyle
        // Two pages hosted, their run loops turned 0.3 s each: long enough for macOS to tell the process about the mouse.
        // A fixed wait on purpose: what it waits for comes from outside the process, unasked (pump would end at quiet).
        try LookPageTests().hosted(CataloguePage()) { _ in RunLoop.current.run(until: .now + 0.3) }
        try LookPageTests().hosted(OpenWithPage()) { _ in RunLoop.current.run(until: .now + 0.3) }
        #expect(NSScroller.preferredScrollerStyle == pinned, "the scroll bars moved after testApp() pinned them")
        // Every test host starts the app through testApp(), which pins them.
        let dir = URL(filePath: #filePath).deletingLastPathComponent()
        let unpinned = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Snapshot.swift" }
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("_ = NSApplication" + ".shared") }.map(\.lastPathComponent)
        #expect(unpinned == [], "these start the app without testApp(): \(unpinned)")
    }

    /// A root search over a few rows, as the menu shows it.
    func menuModel() -> MenuModel {
        var nav = MenuNavigator(entries: [
            MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps, detail: "Hyper+T", detailIsKey: true),
            MenuEntry(title: "Open terminal", target: .action("apps.terminal"), home: .keybindings, detail: "Hyper+Return", detailIsKey: true),
            MenuEntry(title: "Toggle floating", target: .action("windows.toggleFloat"), home: .keybindings),
        ])
        nav.query = "te"
        return MenuModel(nav: nav)
    }

    @Test("The menu draws Instrument, dark and light (card agent-bo-95423181)")
    func menu() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        look.style = .instrument
        let dark = try pixels(MenuView(model: menuModel()).styled(.menu, look: look), look: look)
        look.style = .instrument
        look.themeID = "porcelain"
        #expect(try pixels(MenuView(model: menuModel()).styled(.menu, look: look), look: look) != dark, "Instrument on a light theme drew dark")
        look.themeID = PilotTheme.defaultID
    }

    @Test("The menu's panel in Instrument is opaque on the style's pop face with no shadow (B5, Sven 2026-10-09)")
    func menuPanel() throws {
        let (look, _) = LookPageTests().look()
        testApp()
        look.style = .instrument
        let panel = try #require(HUD.makePanel(MenuView(model: menuModel()), surface: .menu, look: look) as? KeyPanel)
        defer { panel.close() }
        #expect(NSEdgeInsetsEqual(panel.margins, NSEdgeInsetsZero), "no drawn shadow, so no margins to hold one")
        #expect(!panel.hasShadow, "the menu draws no window shadow")
        #expect((panel.contentView as? MaterialBackdrop)?.effect == nil, "Instrument's menu is opaque whatever Glass is")
        // The window is the face.
        let face = menuModel().instrumentSize
        #expect(panel.frame.width == face.width && panel.frame.height == face.height)
    }

    @Test("A window row lights its own tile on its workspace's glyph, so two windows of one app never share an icon; a bind's label reads as caps")
    func menuParts() throws {
        let windows = try AeroWindow.parse(SharedLook.InstrumentMenuRenders.windows)
        let left = try #require(InstrumentWindowGlyph.tile(of: 412, in: windows))
        let right = try #require(InstrumentWindowGlyph.tile(of: 431, in: windows))
        #expect(left != right && left.minX == 0 && abs(right.maxX - 1) < 0.0001, "three side by side: first and last thirds")
        #expect(InstrumentWindowGlyph.tile(of: 7, in: windows) == CGRect(x: 0, y: 0, width: 1, height: 1), "alone on its workspace")
        #expect(InstrumentWindowGlyph.tile(of: 999, in: windows) == nil)
        let caps = InstrumentBindKeys.caps("Hyper+Shift+Return", layerKeys: [.capsLock])
        #expect(caps.map(\.text) == ["⇪", "⇧", "↵"] && caps.map(\.hyper) == [true, false, false])
        #expect(InstrumentBindKeys.caps("Left Alt+H", layerKeys: [.rightOption]).map(\.text) == ["L⌥", "H"])
    }

    @Test("Remove's and Update's rows each wear their own glyph in Instrument (Moody vzACUY1p1lU)")
    func menuGlyphs() throws {
        for nav in [MenuBrowseRenders.remove(), MenuBrowseRenders.update()] {
            let glyphs = nav.rows.compactMap { InstrumentRowIcon.glyph($0) }
            #expect(Set(glyphs).count == glyphs.count, "\(nav.branch.map(\.rawValue) ?? "") repeats a glyph: \(glyphs)")
        }
    }

    @Test("In a list whose rows would all wear one glyph, none wears it; an app's own icon still shows; Cmd+K's actions each have their own glyph (Moody vzACUY1p1lU)")
    func menuShared() throws {
        let kill = Activity.entries(Activity.Snapshot(apps: [], background: [
            Activity.Row(kind: .process, pid: 1, name: "find", cpu: 9, memory: 2048 << 10, rights: .quitAndForce),
            Activity.Row(kind: .process, pid: 2, name: "swift", cpu: 8, memory: 2048 << 10, rights: .quitAndForce)]))
        let shared = try #require(InstrumentRowIcon.shared(kill))
        #expect(kill.allSatisfy { InstrumentRowIcon.glyph($0) == shared })
        #expect(InstrumentRowIcon.shared(MenuBrowseRenders.update().rows) == nil, "Update's rows differ")
        #expect(InstrumentRowIcon.shared(Array(kill.prefix(1))) == nil, "one row repeats nothing")
        let row = MenuEntry(title: "Finder", target: .app("com.apple.finder"))
        let copies = [RowAction.copyPath, .copyBundleID, .copyTitle, .copyID].map { $0.instrumentSymbol(on: row) }
        #expect(Set(copies).count == copies.count, "\(copies)")
    }

    @Test("Clean's wait in Instrument is as tall as what it says, not the panel's tallest (Moody vzACUY1p1lU)")
    func menuCleanWait() {
        let model = MenuModel(nav: MenuNavigator(entries: [], branch: .clean))
        #expect(model.scan != nil)
        model.waitHeight = 296
        #expect(model.instrumentSize == CGSize(width: MenuPanelSize.width, height: MenuPanelSize.lineChrome + 296))
    }

    @Test("The styles' five faces load from their bundled files at each role's weight, their OFL licence beside them")
    func faces() throws {
        DisplayFaces.directory = LookThemeTests.fonts
        for face in StyleTokens.faces {
            #expect(DisplayFaces.font(face, size: 13).familyName == face.family, "\(face.file)")
            let licence = try String(contentsOf: LookThemeTests.fonts.appending(path: "\(face.file)/OFL.txt"), encoding: .utf8)
            #expect(licence.contains("SIL OPEN FONT LICENSE"), "\(face.file) licence")
        }
        // Each weight is its own face: Geist 600 is not Geist 400 at the same size.
        let wght = { (font: NSFont) in ((CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]) ?? [:])[NSNumber(value: DisplayFaces.tag("wght"))]?.doubleValue }
        #expect(wght(DisplayFaces.font(StyleTokens.geist(600), size: 13)) == 600)
        // At the file's default instance, 400, CoreText reports no variation.
        #expect((wght(DisplayFaces.font(StyleTokens.geist(400), size: 13)) ?? 400) == 400)
    }
}
}
extension HomeSources {
    /// Home's and the window's sources for a test that hosts the window: an empty schema, so neither the search nor Jump
    /// back in's page reads (InstrumentFrame) build the app's live settings and every store behind them.
    @MainActor static var inert: HomeSources {
        var sources = HomeSources()
        let schema = SettingsSchema()
        sources.schema = { schema }
        sources.recent = { [] }
        sources.remember = { _ in }
        return sources
    }
}
#endif
