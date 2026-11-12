import Foundation
import PilotCore
import Testing

/// The Menu bar page's edits (card agent-bo-95422913): + or a switch per item, in the placement the page shows, and drag
/// to reorder.
@Suite("Menu bar page model")
struct MenuBarPageModelTests {
    @Test("+ in one bar adds that bar and keeps the other; out leaves the other, or turns the item off")
    func toggle() {
        var s = BarSettings.defaults
        #expect(!s.isOn(.heat, in: .menuBar))
        s.toggle(.heat, in: .menuBar)
        #expect(s.entry(.heat).on && s.entry(.heat).placement == .menuBar && s.isOn(.heat, in: .menuBar) && !s.isOn(.heat, in: .topBar))
        s.toggle(.heat, in: .topBar)
        #expect(s.entry(.heat).placement == .both && s.isOn(.heat, in: .both))
        s.toggle(.heat, in: .menuBar)
        #expect(s.entry(.heat).on && s.entry(.heat).placement == .topBar)
        s.toggle(.heat, in: .topBar)
        #expect(!s.entry(.heat).on)
        // Both: in puts it in both bars, out takes it out of both.
        s.toggle(.storage, in: .both)
        #expect(s.entry(.storage).placement == .both && s.entry(.storage).on)
        s.toggle(.storage, in: .both)
        #expect(!s.entry(.storage).on)
    }

    @Test("Pilot never leaves the menu bar; other apps never join it")
    func rules() {
        var s = BarSettings.defaults
        s.toggle(.pilot, in: .menuBar)
        #expect(s.entry(.pilot).on && s.isOn(.pilot, in: .menuBar))
        s.toggle(.otherApps, in: .menuBar)
        #expect(s.entry(.otherApps).placement == .topBar)
    }

    @Test("Pilot reads on in every placement the page shows and no switch moves it, as both bars draw it (card agent-bo-95423009)")
    func pilotOnEverywhere() throws {
        var s = try JSONDecoder().decode(BarSettings.self, from: Data(BarItemsTests.svensItems.utf8))
        for placement in BarPlacement.allCases {
            #expect(s.isOn(.pilot, in: placement), "\(placement)")
            s.toggle(.pilot, in: placement)
            #expect(s.isOn(.pilot, in: placement) && s.entry(.pilot).placement == .menuBar, "\(placement)")
        }
    }

    @Test("Dragging an item onto another puts it in that place and on that side of the top bar")
    func drag() {
        var s = BarSettings.defaults
        s.move(.timer, onto: .workspaces)
        let kinds = s.entries.map(\.kind)
        #expect(kinds.firstIndex(of: .timer)! < kinds.firstIndex(of: .workspaces)! && s.entry(.timer).side == .left)
        s.move(.timer, onto: .timer)
        #expect(s.entries.map(\.kind) == kinds)
    }

    @Test("The line over items in the top bar only names up to three, then how many more; none, or the top bar on, gives no line")
    func onlyInTopBarLine() {
        #expect(BarSettings.onlyInTopBarLine([], topBarOn: false) == nil)
        #expect(BarSettings.onlyInTopBarLine([.clock], topBarOn: true) == nil)
        #expect(BarSettings.onlyInTopBarLine([.clock], topBarOn: false) == "Clock is in the top bar only, which is off, so it shows nowhere.")
        #expect(BarSettings.onlyInTopBarLine([.heat, .volume, .clock], topBarOn: false)
            == "Heat, Volume and Clock are in the top bar only, which is off, so they show nowhere.")
        #expect(BarSettings.onlyInTopBarLine([.heat, .volume, .keyboardLayout, .clock, .timer], topBarOn: false)
            == "Heat, Volume, Keyboard layout and 2 more are in the top bar only, which is off, so they show nowhere.")
    }

    @Test("The preview draws the bars' own slots: one bar for Menu bar or Top bar, both for Both, the menu bar then keeping Pilot and what is placed in it alone (Capture's menu, Q368)")
    func preview() {
        let s = BarSettings.defaults
        #expect(s.preview(.menuBar).top == nil && s.preview(.menuBar).menu == s.slots(in: .menuBar, topBarOn: false))
        #expect(s.preview(.topBar).menu == nil && s.preview(.topBar).top?[.right] == s.slots(in: .topBar, topBarOn: true, side: .right))
        #expect(s.preview(.both).menu?.map(\.kinds) == [[.pilot], [.capture]] && s.preview(.both).top?[.left]?.map(\.kinds) == [[.pilot], [.workspaces]])
    }

    // MARK: Strip and tray (Sven, Q185, 2026-10-16)

    /// The top bar's slots as the page's strip reports them: 40 wide, 6 apart, the left from 6, the centre from 500, the
    /// right from 800, on a strip 1080 by 30.
    static func drawn(_ s: BarSettings) -> BarDrop {
        let sides = TopBarSide.allCases.map { side in
            let start: Double = [.left: 6, .centre: 500, .right: 800][side]!
            return (side, s.slots(in: .topBar, topBarOn: true, side: side).enumerated().map { i, slot in
                BarDrop.Slot(kind: slot.kind, minX: start + Double(i) * 46, maxX: start + Double(i) * 46 + 40)
            })
        }
        return BarDrop(sides: Dictionary(uniqueKeysWithValues: sides), width: 1080, height: 30)
    }

    static func kinds(_ s: BarSettings, _ side: TopBarSide) -> [BarKind] { s.slots(in: .topBar, topBarOn: true, side: side).map(\.kind) }

    @Test("The tray holds every item not on the strip by group: never Pilot, never a top-bar-only item for the menu bar; readings in the Group are on the strip; extensions' items join Extensions")
    func tray() {
        let s = BarSettings.defaults
        let menu = s.tray(.menuBar, extensions: ["weather"]).flatMap(\.items)
        #expect(!menu.contains(.kind(.pilot)) && !menu.contains(.kind(.cpu)) && !menu.contains(.kind(.group)))
        #expect(!menu.contains { $0.kind?.topBarOnly == true }, "other apps, app menus, mode lights, the drops and Extensions are the top bar's alone")
        #expect(menu.contains(.kind(.heat)) && menu.contains(.kind(.clock)), "the clock is in the top bar alone, so the menu bar's tray offers it")
        #expect(!menu.contains(.extension("weather")), "an extension's item is in the menu bar until placed")
        let top = s.tray(.topBar, extensions: ["weather"])
        #expect(!top.flatMap(\.items).contains(.kind(.clock)) && top.flatMap(\.items).contains(.kind(.heat)))
        #expect(top.first { $0.group == .extensions }?.items == [.extension("weather")])
        #expect(top.map(\.group) == BarGroup.allCases.filter { g in top.contains { $0.group == g } }, "sections in the groups' order")
        #expect(top.allSatisfy { !$0.items.isEmpty })
    }

    @Test("A drag from the tray onto the top bar strip lands where it drops: the drop's place from the strip's frames, the item in the top bar and the menu bar left as it was")
    func dropFromTray() throws {
        var s = BarSettings.defaults
        let left = Self.kinds(s, .left)
        // Just right of the second left slot (6 + 46 + 40 = 92).
        let target = try #require(Self.drawn(s).target(x: 95, y: 15, dragging: .wifi))
        #expect(target.side == .left && target.index == 2)
        let landed113 = s.drop(.kind(.wifi), on: .top(target.side, index: target.index), placement: .topBar)
        #expect(landed113)
        #expect(Self.kinds(s, .left) == Array(left.prefix(2)) + [.wifi] + left.dropFirst(2))
        #expect(s.entry(.wifi).on && s.entry(.wifi).placement == .topBar && !s.isOn(.wifi, in: .menuBar))
        #expect(!s.tray(.topBar).flatMap(\.items).contains(.kind(.wifi)))
        // A reading dropped at a place of its own lands there, out of the Group (Sven on build 2372: dragged out, it
        // stays out); dropped on the Group's outline it joins it.
        let alone = s.drop(.kind(.heat), on: .top(.left, index: 0), placement: .topBar)
        #expect(alone && Self.kinds(s, .left).contains(.heat) && !s.entry(.heat).inGroup)
        let joined = s.drop(.kind(.heat), on: .group, placement: .topBar)
        #expect(joined && s.slots(in: .topBar, topBarOn: true).first(where: \.isGroup)?.kinds.contains(.heat) == true)
    }

    @Test("A drag along the top bar strip reorders, across sides too; Pilot never moves and leads the left")
    func reorderTop() throws {
        var s = BarSettings.defaults
        let target = try #require(Self.drawn(s).target(x: 499, y: 15, dragging: .timer))
        #expect(target.side == .centre && target.index == 0)
        let landed125 = s.drop(.kind(.timer), on: .top(.centre, index: 0), placement: .topBar)
        #expect(landed125)
        #expect(Self.kinds(s, .centre).first == .timer && !Self.kinds(s, .right).contains(.timer))
        #expect(s.isOn(.timer, in: .menuBar), "a move in the top bar keeps the menu bar")
        let landed129 = s.drop(.kind(.pilot), on: .top(.right, index: 0), placement: .topBar)
        #expect(!landed129)
        let landed131 = s.drop(.kind(.workspaces), on: .top(.left, index: 0), placement: .topBar)
        #expect(landed131)
        #expect(Self.kinds(s, .left).first == .pilot)
    }

    @Test("A drag off the strip onto the tray takes it out of that bar alone; on Both it goes off; the Group takes its readings; Pilot never goes")
    func takeOff() {
        var s = BarSettings.defaults
        let took139 = s.takeOff(.kind(.timer), placement: .topBar)
        #expect(took139)
        #expect(s.entry(.timer).on && s.entry(.timer).placement == .menuBar)
        let took142 = s.takeOff(.kind(.timer), placement: .menuBar)
        #expect(took142)
        #expect(!s.entry(.timer).on)
        let took145 = s.takeOff(.kind(.timer), placement: .menuBar)
        #expect(!took145, "nothing to take off")

        var both = BarSettings.defaults
        let took149 = both.takeOff(.kind(.workspaces), placement: .both)
        #expect(took149 && !both.entry(.workspaces).on)

        var group = BarSettings.defaults
        let took153 = group.takeOff(.kind(.group), placement: .menuBar)
        #expect(took153)
        #expect(!group.isOn(.group, in: .menuBar) && [BarKind.cpu, .memory, .network].allSatisfy { !group.isOn($0, in: .menuBar) })
        #expect(group.isOn(.group, in: .topBar) && group.isOn(.cpu, in: .topBar), "the top bar keeps its Group")
        let took157 = group.takeOff(.kind(.pilot), placement: .menuBar)
        #expect(!took157 && group.entry(.pilot).on)
    }

    @Test("The menu bar strip: a drop lands before the slot under the pointer, past them last; a top-bar-only item never lands; Move left and right step one slot")
    func menuStrip() {
        var s = BarSettings.defaults
        let slots = s.slots(in: .menuBar, topBarOn: false)
        let drawn = slots.enumerated().map { i, slot in BarDrop.Slot(kind: slot.kind, minX: 600 + Double(i) * 50, maxX: 640 + Double(i) * 50) }
        let at = BarDrop.menuTarget(x: 652, slots: drawn, dragging: .wifi)
        #expect(at.index == 1 && at.caret == 645)
        let landed168 = s.drop(.kind(.wifi), on: .menu(index: at.index), placement: .menuBar)
        #expect(landed168)
        #expect(s.slots(in: .menuBar, topBarOn: false).map(\.kind) == [slots[0].kind, .wifi] + slots.dropFirst().map(\.kind))
        #expect(s.entry(.wifi).placement == .menuBar)
        #expect(BarDrop.menuTarget(x: 2000, slots: drawn, dragging: nil).index == drawn.count)
        s.placeInMenuBar(.wifi, at: .max, topBarOn: false)
        #expect(s.slots(in: .menuBar, topBarOn: false).last?.kind == .wifi)
        s.step(.wifi, by: -1, inTopBar: false, topBarOn: false)
        #expect(s.slots(in: .menuBar, topBarOn: false).dropLast().last?.kind == .wifi)
        let landed177 = s.drop(.kind(.otherApps), on: .menu(index: 0), placement: .menuBar)
        #expect(!landed177)
        let landed179 = s.drop(.kind(.wifi), on: .top(.left, index: 0), placement: .menuBar)
        #expect(!landed179, "the Menu bar page shows no top bar")
    }

    @Test("On Both, the top bar strip puts an item in both bars and the menu bar's in the menu bar alone; a drag between them moves it")
    func both() {
        var s = BarSettings.defaults
        let landed186 = s.drop(.kind(.heat), on: .top(.right, index: 0), placement: .both)
        #expect(landed186)
        #expect(s.entry(.heat).placement == .both && s.onStrip(.heat, placement: .both))
        let landed189 = s.drop(.kind(.heat), on: .menu(index: .max), placement: .both)
        #expect(landed189)
        #expect(s.entry(.heat).placement == .menuBar && s.preview(.both).menu?.contains { $0.kind == .heat } == true)
        let landed192 = s.drop(.kind(.otherApps), on: .top(.left, index: .max), placement: .both)
        #expect(landed192 && s.entry(.otherApps).placement == .topBar)
    }

    @Test("The Group dropped with no reading brings CPU, Memory and Network into that bar, so its slot draws")
    func groupFills() {
        var s = BarSettings.defaults
        let took199 = s.takeOff(.kind(.group), placement: .menuBar)
        #expect(took199)
        let landed201 = s.drop(.kind(.group), on: .menu(index: 0), placement: .menuBar)
        #expect(landed201)
        #expect(s.slots(in: .menuBar, topBarOn: false).first { $0.isGroup }?.kinds == [.cpu, .memory, .network])
    }

    @Test("An extension's item: onto the top bar it is its own slot where it drops; onto the menu bar it is its own item; back to the tray it leaves that bar")
    func extensionItems() {
        var s = BarSettings.defaults
        s.set(.extensions, on: false)
        #expect(s.tray(.topBar, extensions: ["weather"]).flatMap(\.items).contains(.extension("weather")))
        let landed211 = s.drop(.extension("weather"), on: .top(.right, index: 3), placement: .topBar)
        #expect(landed211)
        #expect(s.shows(extension: "weather", in: .topBar, topBarOn: true) && Self.items(s, .right)[3] == .extension("weather"))
        #expect(s.isOn(extension: "weather", in: .menuBar), "it keeps the menu bar it was in")
        let took215 = s.takeOff(.extension("weather"), placement: .menuBar)
        #expect(took215)
        #expect(!s.isOn(extension: "weather", in: .menuBar) && s.isOn(extension: "weather", in: .topBar))
        let took218 = s.takeOff(.extension("weather"), placement: .topBar)
        #expect(took218 && !s.extensionEntry("weather").on)
        let landed220 = s.drop(.extension("weather"), on: .menu(index: 0), placement: .menuBar)
        #expect(landed220 && s.onStrip(extension: "weather", placement: .menuBar))
        let landed222 = s.drop(.extension("weather"), on: .top(.left, index: 0), placement: .menuBar)
        #expect(!landed222)
    }

    @Test("A drag's payload reads back as the item it carries; anything else is nothing")
    func payload() {
        for item in [BarTrayItem.kind(.heat), .kind(.group), .extension("com.example.weather")] { #expect(BarTrayItem(rawValue: item.rawValue) == item) }
        #expect(BarTrayItem(rawValue: "heat") == nil && BarTrayItem(rawValue: "kind:nope") == nil && BarTrayItem(rawValue: "extension:") == nil)
    }

    // MARK: One by one (Sven on build 54)

    /// Every piece the strip for `placement` draws: each item, each reading in the Group and the Group itself, and each
    /// extension's item shown there.
    static func pieces(_ s: BarSettings, _ placement: BarPlacement, extensions: [String]) -> [BarTrayItem] {
        let preview = s.preview(placement)
        let slots = (preview.top.map { sides in TopBarSide.allCases.flatMap { sides[$0] ?? [] } } ?? []) + (preview.menu ?? [])
        let kinds = slots.flatMap { $0.isGroup ? [.group] + $0.kinds : $0.kinds }.filter { !$0.pinned && $0 != .extensions }
        return kinds.map(BarTrayItem.kind) + extensions.filter { s.onStrip(extension: $0, placement: placement) }.map(BarTrayItem.extension)
    }

    @Test("Every piece on each strip comes off on its own: an item, one reading out of the Group, one extension's item (Sven on build 54: in the top bar he could put things on but not take them off)")
    func everyPieceComesOff() {
        var base = BarSettings.defaults
        base.set(extension: "weather", on: true, placement: .both)
        base.set(extension: "stocks", on: true, placement: .both)
        for placement in BarPlacement.allCases {
            let pieces = Self.pieces(base, placement, extensions: ["weather", "stocks"])
            #expect(pieces.count > 5, "\(placement)")
            for piece in pieces {
                var s = base
                let took = s.takeOff(piece, placement: placement)
                #expect(took && !s.onStrip(piece, placement: placement), "\(piece) on \(placement)")
            }
        }
        // One reading out of the Group: the Group keeps the others.
        var s = base
        let took = s.takeOff(.kind(.cpu), placement: .topBar)
        #expect(took && s.slots(in: .topBar, topBarOn: true).first(where: \.isGroup)?.kinds == [.memory, .network])
        #expect(s.isOn(.cpu, in: .menuBar), "the menu bar keeps it")
        // One extension's item: the other stays in the top bar.
        let one = s.takeOff(.extension("weather"), placement: .topBar)
        #expect(one && s.shows(extension: "stocks", in: .topBar, topBarOn: true) && !s.shows(extension: "weather", in: .topBar, topBarOn: true))
    }

    @Test("The tray offers single items: each reading and each extension's item a chip of its own, never the Extensions item as a whole")
    func trayOneByOne() {
        var s = BarSettings.defaults
        for kind in [BarKind.cpu, .memory, .network] { s.set(kind, on: false) }
        let tray = s.tray(.topBar, extensions: ["weather", "stocks"])
        #expect(tray.first { $0.group == .readings }?.items == BarKind.allCases.filter { $0.group == .readings }.map(BarTrayItem.kind))
        #expect(tray.first { $0.group == .extensions }?.items == [.extension("weather"), .extension("stocks")])
        #expect(!tray.flatMap(\.items).contains(.kind(.extensions)))
    }

    @Test("Each extension's item dropped on the top bar lands where it drops, and moves on its own as a built-in item does (Sven, 2026-11-04: they moved as one)")
    func extensionSlotLands() throws {
        var s = BarSettings.defaults
        let first = s.drop(.extension("weather"), on: .top(.left, index: 1), placement: .topBar)
        #expect(first && Self.items(s, .left)[1] == .extension("weather"))
        let next = s.drop(.extension("stocks"), on: .top(.right, index: 0), placement: .topBar)
        #expect(next && Self.items(s, .left)[1] == .extension("weather") && Self.items(s, .right)[0] == .extension("stocks"))
        // Dragged along its side, past a built-in item, and to another side: only it moves.
        let along = s.drop(.extension("stocks"), on: .top(.right, index: 2), placement: .topBar)
        #expect(along && Self.items(s, .right)[2] == .extension("stocks") && Self.items(s, .left)[1] == .extension("weather"))
        let across = s.drop(.extension("weather"), on: .top(.centre, index: 0), placement: .topBar)
        #expect(across && Self.items(s, .centre)[0] == .extension("weather") && !Self.items(s, .left).contains(.extension("weather")))
        // Move left and right step it one place, past a side's end into the next.
        s.step(.extension("weather"), by: -1, inTopBar: true, topBarOn: true)
        #expect(Self.items(s, .left).last == .extension("weather"))
        s.step(.extension("weather"), by: 1, inTopBar: true, topBarOn: true)
        #expect(Self.items(s, .centre)[0] == .extension("weather"))
        // A drag's target counts its side without the dragged extension's item, as for a built-in one.
        let drawn = BarDrop(sides: [.right: Self.items(s, .right).enumerated().map { i, item in BarDrop.Slot(item: item, minX: Double(600 + i * 100), maxX: Double(680 + i * 100)) }],
                            width: 1000, height: 30)
        #expect(drawn.target(x: 985, y: 15, dragging: .extension("stocks"))?.index == 3)
        #expect(s.topBarPlace(.extension("stocks")).map { $0.side == .right && $0.index == 2 } == true && s.topBarPlace(.extension("nope")) == nil)
        // Its right-click menu on the bar: Move to and Remove from bar act on it alone, no style or Extensions rows.
        let menu = try #require(s.entries.first { $0.item == .extension("stocks") }).menu(BarInputs(), in: .topBar)
        #expect(menu.contains { if case .submenu("Move to", _) = $0 { true } else { false } } && menu.contains(.action("Remove from bar", .edit(.remove))))
        #expect(!menu.contains { if case .header("Style") = $0 { true } else { false } } && !menu.contains { if case .action("Show Extensions", _, _, _) = $0 { true } else { false } })
        s.apply(.move(.left), on: .extension("stocks"))
        #expect(Self.items(s, .left).last == .extension("stocks") && !Self.items(s, .right).contains(.extension("stocks")))
        s.apply(.remove, on: .extension("stocks"))
        #expect(!s.shows(extension: "stocks", in: .topBar, topBarOn: true) && s.isOn(extension: "stocks", in: .menuBar), "it keeps the macOS menu bar it was in")
        s.toggle(extension: "stocks", in: .topBar)
        // Hidden on its own: the other stays where it is.
        let took = s.takeOff(.extension("stocks"), placement: .topBar)
        #expect(took && Self.items(s, .centre)[0] == .extension("weather"))
    }

    static func items(_ s: BarSettings, _ side: TopBarSide) -> [BarTrayItem] { s.slots(in: .topBar, topBarOn: true, side: side).map(\.item) }
}
