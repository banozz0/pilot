import Foundation
import PilotCore
import Testing

/// Placing items on the top bar (card agent-bo-95423017; the Menu bar page's strip since Q185): a drop on the bar maps to
/// a side and an index, an item lands there or joins the bar, and a pilot://bar link does the same.
@Suite("Bar editing")
struct BarEditingTests {
    /// Sven's bar.items with the focused app on in the top bar: the mockup's set, left Pilot, Workspaces and the focused
    /// app, centre the timer and the clock, right other apps, the readings, the keyboard layout and Volume.
    static func mockup() throws -> BarSettings {
        var s = try JSONDecoder().decode(BarSettings.self, from: Data(BarItemsTests.svensItems.utf8))
        s.set(.focusedApp, on: true)
        s.set(.focusedApp, placement: .both)
        // The bar drops' items join a saved layout switched on (Bar drops T4); the mockup predates them.
        for kind in [BarKind.terminal, .askAI] { s.set(kind, on: false) }
        return s
    }

    /// The bar's slots as a 1080 point wide strip draws them: each side's slots 6 apart, 40 wide, the readings 60.
    static func drawn(_ s: BarSettings, width: Double = 1080) -> BarDrop {
        func side(_ side: TopBarSide, from start: Double) -> [BarDrop.Slot] {
            var x = start
            return s.slots(in: .topBar, topBarOn: true, side: side).map { slot in
                let w: Double = slot.kind.group == .readings ? 60 : 40
                defer { x += w + 6 }
                return BarDrop.Slot(kind: slot.kind, minX: x, maxX: x + w)
            }
        }
        let right = s.slots(in: .topBar, topBarOn: true, side: .right).map { $0.kind.group == .readings ? 66.0 : 46 }.reduce(0, +)
        return BarDrop(sides: [.left: side(.left, from: 6), .centre: side(.centre, from: 497), .right: side(.right, from: width - 6 - right + 6)],
                       width: width, height: 30)
    }

    @Test("A drop just right of the focused app lands on the left after it; a drop on the clock lands in the centre")
    func resolver() throws {
        let s = try Self.mockup()
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kind) == [.pilot, .workspaces, .focusedApp])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .centre).map(\.kind) == [.timer, .clock])
        let drop = Self.drawn(s)
        // The focused app spans 98 to 138.
        let after = try #require(drop.target(x: 142, y: 15, dragging: .cpu))
        #expect(after.side == .left && after.index == 3)
        #expect(after.caret > 138 && after.caret < 150)
        // The clock spans 543 to 583.
        #expect(drop.target(x: 560, y: 15, dragging: .cpu)?.side == .centre)
    }

    @Test("An empty side still takes a drop at its place, and a drop under the bar is off it")
    func emptySide() throws {
        var s = try Self.mockup()
        for kind in [BarKind.timer, .clock] { s.set(kind, on: false) }
        let drop = Self.drawn(s)
        #expect(drop.zone(.centre) == 510...570)
        #expect(drop.target(x: 540, y: 10, dragging: .cpu) == BarDrop.Target(side: .centre, index: 0, caret: 540))
        #expect(drop.target(x: 540, y: 60, dragging: .cpu) == nil)
        // Before Pilot's icon is after it: Pilot leads the left side.
        #expect(drop.target(x: 2, y: 10, dragging: .cpu)?.index == 1)
    }

    @Test("Placing an item puts it on that side before the slot at that index, without itself; Pilot stays first on the left")
    func place() throws {
        var s = try Self.mockup()
        let left = { s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kind) }
        s.place(.cpu, on: .left, at: 3)
        #expect(s.entry(.cpu).side == .left)
        #expect(left() == [.pilot, .workspaces, .focusedApp, .cpu])
        s.place(.cpu, on: .left, at: 2)
        #expect(left() == [.pilot, .workspaces, .cpu, .focusedApp])
        // Its own place does not count: index 3 of the others is after the focused app again.
        s.place(.cpu, on: .left, at: 3)
        #expect(left() == [.pilot, .workspaces, .focusedApp, .cpu])
        // Past the end is last; the right side keeps its order otherwise.
        let right = s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kind)
        s.place(.otherApps, on: .right, at: 99)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kind) == right.dropFirst() + [.otherApps])
        let before = s
        s.place(.pilot, on: .right, at: 0)
        #expect(s == before)
        // A negative index (pilot://bar takes any) is first, even on a side with nothing else (Moody z7v89ylaTdE).
        s.place(.clock, on: .centre, at: -1)
        s.place(.timer, on: .centre, at: -1)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .centre).map(\.kind) == [.timer, .clock])
        s.place(.timer, on: .right, at: 0)
        s.place(.clock, on: .centre, at: -1)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .centre).map(\.kind) == [.clock])
    }

    @Test("Adding to the top bar switches the item on there; removing switches it off; Pilot stays")
    func addAndRemove() throws {
        var s = try Self.mockup()
        // Graphics is off and placed in the macOS menu bar only: added, it is in both and on the left after Workspaces.
        s.add(.graphics, on: .left, at: 2)
        #expect(s.entry(.graphics).on && s.entry(.graphics).placement == .both)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kind) == [.pilot, .workspaces, .graphics, .focusedApp])
        // The battery, top bar only, keeps its placement.
        s.add(.battery, on: .right, at: 0)
        #expect(s.entry(.battery).placement == .topBar && s.slots(in: .topBar, topBarOn: true, side: .right).first?.kind == .battery)
        s.apply(.remove, on: .graphics)
        #expect(!s.entry(.graphics).on)
        let before = s
        s.apply(.remove, on: .pilot)
        s.add(.pilot, on: .centre, at: 0)
        #expect(s == before)
    }

    @Test("pilot://bar links move, add and remove an item, or open edit mode; an unknown item or side does nothing")
    func route() throws {
        let link = { (query: String) in BarRoute(URL(string: "pilot://bar?\(query)")!) }
        #expect(link("move=cpu&side=left&index=2") == .move(.cpu, side: .left, index: 2))
        #expect(link("add=graphics&side=right") == .add(.graphics, side: .right, index: nil))
        #expect(link("remove=heat") == .remove(.heat))
        #expect(link("edit=1") == .edit)
        #expect(link("move=toaster&side=left") == nil)
        #expect(link("move=cpu&side=middle") == nil)
        #expect(link("") == nil)

        var s = try Self.mockup()
        try #require(link("move=cpu&side=left&index=2")).apply(to: &s)
        #expect(s.entry(.cpu).side == .left)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kind) == [.pilot, .workspaces, .cpu, .focusedApp])
        // No side keeps the item's own, no index is last.
        try #require(link("add=graphics")).apply(to: &s)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).last?.kind == .graphics)
        try #require(link("remove=heat")).apply(to: &s)
        #expect(!s.entry(.heat).on)
    }

    @Test("The spacer takes a width of its own, saved and drawn, within 4 to 600 points; a style pick or reset gives back its own (Sven on build 21)")
    func stretchedSpacer() throws {
        var s = try Self.mockup()
        s.set(.spacer, on: true)
        s.set(.spacer, style: .fixed)
        #expect(BarParts.parts(s.entry(.spacer), BarInputs()) == [.space(14)])
        s.setSpacer(width: 120.3)
        #expect(s.entry(.spacer).width == 120 && BarParts.parts(s.entry(.spacer), BarInputs()) == [.space(120)])
        let saved = try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(s))
        #expect(saved.entry(.spacer).width == 120, "the stretched width is not saved")
        s.set(.spacer, style: .flexible)
        #expect(s.entry(.spacer).width == nil && BarParts.parts(s.entry(.spacer), BarInputs()) == [.space(40)])

        // pilot://bar?spacer=<points> stretches it as the drag does; reset gives back its style's width.
        let link = try #require(BarRoute(URL(string: "pilot://bar?spacer=200")!))
        #expect(link == .spacer(200))
        link.apply(to: &s)
        #expect(s.entry(.spacer).width == 200)
        try #require(BarRoute(URL(string: "pilot://bar?spacer=reset")!)).apply(to: &s)
        #expect(s.entry(.spacer).width == nil)
        #expect(BarRoute(URL(string: "pilot://bar?spacer=wide")!) == nil)
    }

    @Test("Taking the Group off the bar takes the readings it gathers with it, rather than coming apart into one item per reading; put back, it is empty, an outline on the page's strip (Sven on build 52, 2425)")
    func removeGroup() throws {
        var s = try Self.mockup()
        // The Extensions item joins a saved layout on, last on the right; off here, the mockup's right side as it was.
        s.set(.extensions, on: false)
        s.set(.group, placement: .both)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kind) == [.otherApps, .group, .volume, .keyboardLayout])
        s.remove(slot: .group)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kind) == [.otherApps, .volume, .keyboardLayout])
        #expect([BarKind.group, .cpu, .memory, .storage, .heat].allSatisfy { !s.entry($0).on })
        s.add(.group, on: .right, at: 1)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kind) == [.otherApps, .volume, .keyboardLayout])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right, emptyGroups: true).map(\.kind) == [.otherApps, .group, .volume, .keyboardLayout])
        #expect(s.entry(.group).on && [BarKind.cpu, .memory, .network].allSatisfy { !s.entry($0).on })
        // A plain item goes as it always did; Pilot never does; a link's remove is a drag's.
        s.remove(slot: .keyboardLayout)
        #expect(!s.entry(.keyboardLayout).on)
        s.remove(slot: .pilot)
        #expect(s.entry(.pilot).on)
        try #require(BarRoute(URL(string: "pilot://bar?remove=group")!)).apply(to: &s)
        #expect(!s.entry(.group).on && !s.entry(.cpu).on)
    }

    @Test("A nudge moves an item one place along its side, past a side's end into the next side's near end, never before Pilot or off the bar's ends")
    func nudge() throws {
        var s = try Self.mockup()
        s.set(.extensions, on: false)
        let side = { (side: TopBarSide) in s.slots(in: .topBar, topBarOn: true, side: side).map(\.kind) }
        #expect(side(.right) == [.otherApps, .cpu, .memory, .storage, .heat, .volume, .keyboardLayout])
        s.nudge(.keyboardLayout, by: -1)
        #expect(side(.right) == [.otherApps, .cpu, .memory, .storage, .heat, .keyboardLayout, .volume])
        s.nudge(.keyboardLayout, by: 1)
        #expect(side(.right).last == .keyboardLayout)
        // Past the right end: nowhere to go.
        s.nudge(.keyboardLayout, by: 1)
        #expect(side(.right).last == .keyboardLayout)
        // Past the right side's start: last in the centre, then on to the left side's end.
        s.nudge(.otherApps, by: -1)
        #expect(side(.centre) == [.timer, .clock, .otherApps] && side(.right).first == .cpu)
        for _ in 0..<3 { s.nudge(.otherApps, by: -1) }
        #expect(side(.left) == [.pilot, .workspaces, .focusedApp, .otherApps])
        for _ in 0..<5 { s.nudge(.otherApps, by: -1) }
        #expect(side(.left) == [.pilot, .otherApps, .workspaces, .focusedApp])
        // Rightwards past the left side's end it starts the centre.
        for _ in 0..<3 { s.nudge(.otherApps, by: 1) }
        #expect(side(.centre).first == .otherApps)
        let before = s
        s.nudge(.pilot, by: 1)
        #expect(s == before)
    }
}
