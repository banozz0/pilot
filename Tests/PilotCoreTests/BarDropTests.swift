import CoreGraphics
import PilotCore
import Testing

/// Where a bar drop sits (spec Bar drops T2, Q89): one centred under the bar, both side by side, Terminal left, the pair
/// centred; sizes capped on narrow screens; with the bar off it hangs from the visible top.
@Suite("Bar drop placement")
struct BarDropTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 1100)
    static let visible = CGRect(x: 0, y: 80, width: 1440, height: 990)
    static let bar = CGRect(x: 0, y: 1038, width: 1440, height: 32)

    @Test("Nothing open, no frames")
    func noneOpen() {
        #expect(BarDropPlacement.frames(open: [], screen: Self.screen, visible: Self.visible, bar: Self.bar).isEmpty)
    }

    @Test("One open drop is centred under the bar, 760 by 560, either kind")
    func oneCentred() {
        for kind in BarDropKind.paired {
            let frames = BarDropPlacement.frames(open: [kind], screen: Self.screen, visible: Self.visible, bar: Self.bar)
            #expect(frames.count == 1)
            #expect(frames[kind] == CGRect(x: 340, y: 1038 - 560, width: 760, height: 560))
        }
    }

    @Test("Both open: Terminal left, Ask AI right, 12 apart, the pair centred")
    func bothSideBySide() {
        let frames = BarDropPlacement.frames(open: [.askAI, .terminal], screen: Self.screen, visible: Self.visible, bar: Self.bar)
        let terminal = try! #require(frames[.terminal]), ask = try! #require(frames[.askAI])
        // (1440 - 48 - 12) / 2 = 690 each.
        #expect(terminal == CGRect(x: 24, y: 478, width: 690, height: 560))
        #expect(ask == CGRect(x: 726, y: 478, width: 690, height: 560))
        #expect(ask.minX - terminal.maxX == BarDropPlacement.gap)
        #expect((terminal.minX + ask.maxX) / 2 == Self.screen.midX)
    }

    @Test("One of two closing puts the other back in the centre")
    func closingOneRecentres() {
        let frames = BarDropPlacement.frames(open: [.terminal], screen: Self.screen, visible: Self.visible, bar: Self.bar)
        #expect(frames[.terminal]?.midX == Self.screen.midX && frames[.askAI] == nil)
    }

    @Test("A 3440 pt ultrawide keeps both at 760, centred on its own middle, on a display right of the main one")
    func ultrawide() {
        let screen = CGRect(x: 1440, y: 0, width: 3440, height: 1440)
        let visible = CGRect(x: 1440, y: 0, width: 3440, height: 1415)
        let bar = CGRect(x: 1440, y: 1383, width: 3440, height: 32)
        let frames = BarDropPlacement.frames(open: [.terminal, .askAI], screen: screen, visible: visible, bar: bar)
        let terminal = try! #require(frames[.terminal]), ask = try! #require(frames[.askAI])
        #expect(terminal.width == 760 && ask.width == 760 && terminal.height == 560)
        #expect(terminal.minX == screen.midX - 766 && ask.maxX == screen.midX + 766)
        #expect(terminal.maxY == bar.minY)
    }

    @Test("A 1080 pt portrait display caps both drops to fit with the edges and the gap")
    func portrait() {
        let screen = CGRect(x: -1080, y: 0, width: 1080, height: 1920)
        let visible = CGRect(x: -1080, y: 0, width: 1080, height: 1895)
        let one = BarDropPlacement.frames(open: [.askAI], screen: screen, visible: visible, bar: nil)
        #expect(one[.askAI]?.width == 760 && one[.askAI]?.midX == screen.midX)
        let both = BarDropPlacement.frames(open: [.terminal, .askAI], screen: screen, visible: visible, bar: nil)
        let terminal = try! #require(both[.terminal]), ask = try! #require(both[.askAI])
        // (1080 - 48 - 12) / 2 = 510 each, 24 from each edge.
        #expect(terminal.width == 510 && ask.width == 510)
        #expect(terminal.minX == screen.minX + 24 && ask.maxX == screen.maxX - 24)
    }

    @Test("A narrow screen caps one drop at its width less the edges")
    func narrowOne() {
        let screen = CGRect(x: 0, y: 0, width: 700, height: 900)
        let frames = BarDropPlacement.frames(open: [.terminal], screen: screen, visible: screen, bar: nil)
        #expect(frames[.terminal] == CGRect(x: 24, y: 360, width: 652, height: 540))
    }

    @Test("With the bar off a drop hangs from the visible frame's top, under the menu bar")
    func barOff() {
        let frames = BarDropPlacement.frames(open: [.terminal], screen: Self.screen, visible: Self.visible, bar: nil)
        #expect(frames[.terminal]?.maxY == Self.visible.maxY)
    }

    @Test("A short screen caps the height at 60% of the visible height")
    func shortScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 675)
        let frames = BarDropPlacement.frames(open: [.askAI], screen: screen, visible: visible, bar: nil)
        #expect(frames[.askAI]?.height == 405)
    }
}
