#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Look page (card agent-bo-95422896): a theme card's press picks its theme. The real page is drawn offscreen on a Look of its own (a fake Ghostty, its own defaults), and clicked where it draws the words, as a mouse would (offscreen SwiftUI builds no accessibility
/// tree to press).
@MainActor
@Suite("Look page")
struct LookPageTests {
    func look() -> (Look, LookTests.FakeGhostty) {
        let ghostty = LookTests.FakeGhostty()
        return (Look(themes: LookTests.themes, ghostty: ghostty, defaults: LookTests.defaults()), ghostty)
    }

    /// `view` hosted in a borderless window that is never shown; the window stays open while `body` runs.
    func hosted(_ view: some View, height: CGFloat = 900, _ body: (NSView) throws -> Void) throws {
        testApp()
        let host = NSHostingView(rootView: view)
        host.frame.size = CGSize(width: 1000, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // On the window list but far off every screen: SwiftUI takes clicks only in a window that is on it. A borderless
        // window never becomes key, so nothing of Sven's loses focus and nothing shows.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        PanelTestSupport.pump()
        host.layoutSubtreeIfNeeded()
        try body(host)
    }

    /// Clicks the middle of the words `label` where the page draws them: found by reading the page back with Vision,
    /// then a mouse down and up sent to the window, as a click arrives. False when the words are not on the page.
    /// Vision reads a row's ⓘ into its label's line ("Border width ©"), so a label is matched as a line's start.
    static func click(_ label: String, in host: NSView) throws -> Bool {
        let text = try recognisedText(in: try #require(snapshot(host, scale: 2)))
        guard let box = text.first(where: { Self.reads($0.text, label) })?.box, let window = host.window else { return false }
        let size = host.bounds.size
        let local = CGPoint(x: box.midX * size.width, y: host.isFlipped ? (1 - box.midY) * size.height : box.midY * size.height)
        let point = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            PanelTestSupport.pump(0.05)
        }
        PanelTestSupport.pump(0.2)
        return true
    }

    /// Whether Vision's `line` is the words `label`, alone or with the ⓘ beside them read as one more mark.
    static func reads(_ line: String, _ label: String) -> Bool { line == label || line.hasPrefix(label + " ") && line.count <= label.count + 2 }

    /// Every run, without reading words: a theme card takes a mouse press as a click, and the page is drawn for a Look
    /// twice, then with another theme picked, the other style and Glass on, so each choice is seen to change the page.
    /// Clicking the page's own cards and switches, and reading the border's width, need Vision: the opt-in tests below.
    @Test("A theme card is pressed by a mouse click")
    func cardPress() throws {
        var picks = 0
        let card = ThemeCard(theme: try #require(PilotTheme.designed.first), picked: false) { picks += 1 }.frame(width: 220, height: 110)
        try hosted(card) { (host: NSView) throws in
            let window = try #require(host.window)
            let point = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
                PanelTestSupport.pump(0.05)
            }
        }
        #expect(picks == 1)
    }

    /// Menu Rail and Classic T9, menu-morph T4: the Hyper+Space menu tiles, Line (the default, Q165), Classic and Rail, each a
    /// third of the picker's width; a mouse click on a tile writes `look.menuLayout`, saved under its key.
    @Test("A click on a Hyper+Space menu tile writes look.menuLayout")
    func menuLayoutClick() throws {
        let defaults = LookTests.defaults()
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: defaults)
        #expect(look.menuLayout == .line, "Line is not the default")
        let picker = MenuLayoutPicker(look: look).frame(width: 600).pilotTheme(look: look)
        try hosted(picker, height: 220) { (host: NSView) throws in
            let window = try #require(host.window)
            @MainActor func click(at share: CGFloat) throws {
                let point = host.convert(CGPoint(x: host.bounds.width * share, y: host.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                    PanelTestSupport.pump(0.05)
                }
                PanelTestSupport.pump(0.2)
            }
            try click(at: 0.84)
            #expect(look.menuLayout == .rail)
            #expect(defaults.string(forKey: "look.menuLayout") == "rail")
            try click(at: 0.5)
            #expect(look.menuLayout == .classic)
            #expect(defaults.string(forKey: "look.menuLayout") == "classic")
            try click(at: 0.16)
            #expect(look.menuLayout == .line)
            #expect(defaults.string(forKey: "look.menuLayout") == "line")
        }
    }

    @Test("The page draws the picked theme, the style and the Glass switch")
    func pageDrawsChoices() throws {
        func page(_ change: (Look) -> Void = { _ in }) throws -> some View {
            let (look, _) = look()
            change(look)
            // Its own wallpaper store and no screens: each page read this Mac's wallpapers on its own, off the main actor,
            // so under the full run one page could have its rows when another had not yet (2026-10-11).
            return LookPage(look: look, wallpaper: WallpaperSettings(defaults: UserDefaults(suiteName: testSuite())!), screens: [])
                .frame(width: 1000, height: CGFloat(height)).clipped().pilotTheme(look: look)
        }
        // Tall enough that the Glass switch shows under the style picker (story 137), the theme cards and their window
        // pictures.
        let height = 1600
        // One render in one main-actor turn, so every page sees the same moment and no other suite runs between; a gap
        // between pages, as a page drew some of its neighbour's edge without one.
        let pages = [try page(), try page(), try page { $0.pick("garnet") }, try page { $0.style = .toybox }, try page { $0.glass = true },
                     try page { $0.menuLayout = .rail }]
        let gap = 200
        let view = VStack(spacing: CGFloat(gap)) { ForEach(pages.indices, id: \.self) { pages[$0] } }
        let rep = try #require(snapshot(drawing: view, scale: 1))
        let data = try #require(rep.bitmapData), row = rep.bytesPerRow
        // Pixels that differ from the first page's. The same Look's glyphs land up to about 200 pixels apart from one page
        // to the next (the theme names shrink to fit); a switch flipped moves over 1,100.
        func differing(_ i: Int) -> Int {
            let a = UnsafeRawPointer(data).bindMemory(to: UInt32.self, capacity: height * row / 4)
            let b = UnsafeRawPointer(data + i * (height + gap) * row).bindMemory(to: UInt32.self, capacity: height * row / 4)
            return (0..<height * row / 4).count { a[$0] != b[$0] }
        }
        #expect(differing(1) < 500, "the same Look draws differently")
        for (i, change) in ["theme", "style", "Glass switch", "Hyper+Space menu"].enumerated() {
            #expect(differing(i + 2) > 500, "the \(change) draws nothing new")
        }
    }

    /// Opt-in: Vision finds the words to click on the main actor and, on a loaded Mac, stalls it for minutes (e5rt
    /// errors), starving every other suite; `cardPress` and `pageDrawsChoices` stand in for it in every run.
    @Test("A theme card's press picks its theme and restyles Ghostty",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func picks() throws {
        let (look, ghostty) = look()
        // Tall enough for the rows under the style picker (story 137).
        let page = LookPage(look: look).frame(width: 1000, height: 1600).pilotTheme(look: look)
        try hosted(page, height: 1600) { (host: NSView) throws in
            #expect(look.themeID == PilotTheme.defaultID)
            #expect(try Self.click("Garnet", in: host), "no Garnet card on the page")
            #expect(look.themeID == "garnet")
            #expect(ghostty.written.last?.theme?.id == PilotTheme.named("garnet")?.source)
        }
    }

    /// Menu Rail and Classic T9 on the page: Hyper+Space menu with its Rail tile (tagged Default) and Classic's, and a
    /// click on Classic's name picks it. A Vision read, so it runs only with PILOT_LIVE=1; `menuLayoutClick` and
    /// `pageDrawsChoices` stand in for it in every run.
    @Test("The page shows Hyper+Space menu, and Classic's tile picks Classic", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func menuLayoutOnPage() throws {
        let (look, _) = look()
        let page = LookPage(look: look).frame(width: 1000, height: 1600).pilotTheme(look: look)
        try hosted(page, height: 1600) { (host: NSView) throws in
            let words = try recognisedText(in: try #require(snapshot(host, scale: 2))).map(\.text)
            for label in ["Hyper+Space menu", "Rail", "Default", "Classic"] {
                #expect(words.contains { Self.reads($0, label) || $0.hasPrefix(label + " ") }, "no \(label) on the page: \(words)")
            }
            #expect(look.menuLayout == .rail)
            #expect(try Self.click("Classic", in: host), "no Classic tile on the page")
            #expect(look.menuLayout == .classic)
        }
    }

    /// Tiling's Focused window block (page map, Sven 2026-10-17), drawn on its own for `look`.
    func focusedWindow(_ look: Look) -> some View {
        FocusedWindowBlock(look: look).padding(20).frame(width: 1000, height: 760, alignment: .top).pilotTheme(look: look)
    }

    /// Card agent-bo-95422950's row, now on Tiling's Focused window block: the border, its width and its switch.
    @Test("Focused window shows the border and its width", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func border() throws {
        let (look, _) = look()
        look.windowBorderWidth = 3
        try hosted(focusedWindow(look), height: 760) { (host: NSView) throws in
            let words = try recognisedText(in: try #require(snapshot(host, scale: 2))).map(\.text)
            #expect(words.contains { Self.reads($0, "Border on the focused window") }, "no border row on the page: \(words)")
            // Vision may read the stepper's arrows into the same line ("3 pt *").
            #expect(words.contains { $0.hasPrefix("3 pt") }, "no border width on the page: \(words)")
            #expect(look.windowBorder)
            #expect(try Self.click("Border on the focused window", in: host))
            #expect(!look.windowBorder)
        }
    }

    @Test("Renders: the border's colour row with Custom picked (Sven, 2026-10-10)")
    func borderColourRender() throws {
        guard ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] != nil else { return }
        let (look, _) = look()
        look.windowBorderColour = .custom(0xC62828)
        try StripStyleTests.write(try rendered(focusedWindow(look), wait: 0.8), "look-border")
    }
}
#endif
