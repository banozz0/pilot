import AppKit
import PilotCore
import Testing
@testable import Pilot

/// The bar drops' panels (spec Bar drops T5): one window level under the top bar's, whichever level the peek gives it,
/// under the HUDs; each drop on its BarDropPlacement frame on the display it opened on; Escape, a drop's key and clicks
/// as DropKeys says. The panels open at fixed frames on a made-up screen, no slide.
@Suite("Bar drop panel", .pilotFocus)
@MainActor
struct BarDropPanelTests {
    static let spot = BarDrops.Spot(screen: CGRect(x: 0, y: 0, width: 1440, height: 1100),
                                    visible: CGRect(x: 0, y: 80, width: 1440, height: 990),
                                    bar: CGRect(x: 0, y: 1038, width: 1440, height: 32))

    /// Drops that hang on `spot`, without the slide, deaf to clicks the test does not hand them.
    static func drops(_ spot: BarDrops.Spot = spot) -> BarDrops {
        testApp()
        let drops = BarDrops()
        drops.focused = { spot }
        drops.still = { true }
        drops.watchesClicks = false
        return drops
    }

    /// Where BarDropPlacement puts `open` on `spot`.
    static func place(_ open: Set<BarDropKind>) -> [BarDropKind: CGRect] {
        BarDropPlacement.frames(open: open, screen: spot.screen, visible: spot.visible, bar: spot.bar)
    }

    /// A blank face, counting its closes.
    static func face(_ closes: Counter? = nil) -> BarDropFace {
        BarDropFace(panel: { BarDrops.panel(NSView(frame: CGRect(origin: .zero, size: $0)), title: "drop", appearance: nil) }, closed: { closes?.count += 1 })
    }

    final class Counter { var count = 0 }

    @Test("One level under the bar's current level, following the peek, under the HUDs; with no bar, just over floating windows")
    func level() throws {
        let drops = Self.drops()
        drops.open(.askAI, face: Self.face())
        defer { drops.hideAll() }
        let panel = try #require(drops.window(.askAI))
        #expect(panel.level.rawValue == NSWindow.Level.statusBar.rawValue - 1)
        drops.barLevel = TopBarWindows.underMenuBar
        #expect(panel.level.rawValue == NSWindow.Level.mainMenu.rawValue - 2, "the peek drops the bar under the menu bar; the drop follows")
        #expect(panel.level.rawValue > NSWindow.Level.floating.rawValue && panel.level.rawValue < HUD.level.rawValue)
        drops.barLevel = TopBarWindows.aboveMenuBar
        #expect(panel.level.rawValue == NSWindow.Level.statusBar.rawValue - 1)

        var off = Self.spot
        off.bar = nil
        let bare = Self.drops(off)
        bare.open(.terminal, face: Self.face())
        defer { bare.hideAll() }
        #expect(bare.window(.terminal)?.level.rawValue == NSWindow.Level.floating.rawValue + 1)
        bare.barLevel = TopBarWindows.underMenuBar
        #expect(bare.window(.terminal)?.level.rawValue == NSWindow.Level.floating.rawValue + 1, "no bar on its screen: the peek leaves it")
    }

    @Test("Each drop sits on its T2 frame: one centred, both side by side, the other back in the centre as one closes")
    func frames() throws {
        let drops = Self.drops()
        defer { drops.hideAll() }
        drops.open(.terminal, face: Self.face())
        #expect(drops.window(.terminal)?.frame == Self.place([.terminal])[.terminal])
        drops.open(.askAI, face: Self.face())
        #expect(drops.window(.terminal)?.frame == Self.place([.terminal, .askAI])[.terminal])
        #expect(drops.window(.askAI)?.frame == Self.place([.terminal, .askAI])[.askAI])
        #expect(drops.keys.focused == .askAI, "the drop just opened has the keyboard")
        drops.close(.terminal)
        #expect(drops.window(.terminal) == nil && drops.window(.askAI)?.frame == Self.place([.askAI])[.askAI])
    }

    @Test("The drops stay on the display they opened on until both close")
    func display() {
        var spot = Self.spot
        let drops = Self.drops()
        drops.focused = { spot }
        defer { drops.hideAll() }
        drops.open(.terminal, face: Self.face())
        spot = BarDrops.Spot(screen: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                             visible: CGRect(x: 1440, y: 0, width: 1920, height: 1050), bar: nil)
        drops.open(.askAI, face: Self.face())
        #expect(drops.window(.askAI)?.frame.maxX ?? 0 <= 1440, "the second drop opens beside the first")
        drops.hideAll()
        drops.open(.askAI, face: Self.face())
        #expect(drops.window(.askAI)?.frame.minX ?? 0 >= 1440, "the next first open goes to the focused display")
    }

    @Test("Ask AI closes on one Escape, taken; the terminal's Escape passes on and a second within 0.4 s closes it too")
    func escape() async {
        let drops = Self.drops()
        let closes = Counter()
        defer { drops.hideAll() }
        drops.open(.askAI, face: Self.face(closes))
        #expect(drops.key(in: .askAI, 53, [], nil, at: 10), "Ask AI takes its Escape")
        #expect(!drops.isOpen(.askAI) && closes.count == 1)

        drops.open(.terminal, face: Self.face(closes))
        #expect(!drops.key(in: .terminal, 53, [], nil, at: 20), "the shell gets the Escape")
        #expect(!drops.key(in: .terminal, 0, [], "a", at: 20.1) && !drops.key(in: .terminal, 53, [], nil, at: 20.2))
        #expect(drops.isOpen(.terminal), "a key between two Escapes is no double")
        #expect(!drops.key(in: .terminal, 53, [], nil, at: 20.5), "the second Escape reaches the shell too")
        #expect(drops.isOpen(.terminal), "the view has the key before the drop closes")
        await Task.yield()
        for _ in 0..<50 where drops.isOpen(.terminal) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!drops.isOpen(.terminal) && closes.count == 2)
    }

    @Test("A drop's key toggles it alone; a click in a drop gives it the keyboard, on the bar leaves both, elsewhere hides both")
    func togglesAndClicks() throws {
        let drops = Self.drops()
        let closes = Counter()
        defer { drops.hideAll() }
        drops.toggle(.terminal, face: Self.face(closes))
        drops.toggle(.askAI, face: Self.face(closes))
        #expect(drops.keys.focused == .askAI)
        drops.clicked(in: drops.window(.terminal))
        #expect(drops.keys.focused == .terminal && drops.keys.open == [.terminal, .askAI])
        drops.toggle(.terminal, face: Self.face(closes))
        #expect(!drops.isOpen(.terminal) && drops.isOpen(.askAI) && drops.keys.focused == .askAI)
        drops.toggle(.terminal, face: Self.face(closes))
        drops.clicked(in: TopBarWindows.panel(NSView(), level: TopBarWindows.aboveMenuBar))
        #expect(drops.keys.open == [.terminal, .askAI], "the bar's own item decides")
        drops.clicked(in: NSWindow())
        #expect(!drops.isOpen(.terminal) && !drops.isOpen(.askAI) && closes.count == 3)
        drops.toggle(.askAI, face: Self.face(closes))
        drops.clicked(in: nil)
        #expect(!drops.isOpen(.askAI) && closes.count == 4, "a click in another app hides it")
    }
}
