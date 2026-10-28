#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home edit mode, seam 2 (spec home-edit, T3): Home drawn offscreen in the app window at the four window sizes, in edit
/// mode, measured; the drop slots built from what it drew. Checks 7 and 8 of the spec's notes. It sets Look.shared, so it
/// runs inside SharedLook, one suite at a time.
extension SharedLook {
@MainActor
@Suite("HomeSlots", .serialized)
struct HomeSlotsTests {
    typealias Place = HomeEditSession.Place

    /// The least window, the default, a laptop's and a tiled half of an ultrawide (Sven, Q57).
    static let sizes = [NSSize(width: 760, height: 520), NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900),
                        NSSize(width: 1720, height: 1440)]

    /// A Home in every lane: the clipboard an icon, Workspaces and Most used cards, the keyboard large and This Mac a lone
    /// medium after it.
    static var mix: HomeLayout { layout([("workspaces", .small), ("clipboard", .icon), ("keyboard", .large), ("mostUsed", .small), ("thisMac", .medium)]) }

    static func layout(_ rows: [(String, HomeLayout.Size)]) -> HomeLayout {
        var layout = HomeLayout(rows: [])
        for (id, size) in rows {
            layout.set(id, shown: true)
            layout.set(id, size: size)
        }
        return layout
    }

    /// Edit mode as a view of the app reads it, so turning it on changes a tree already drawn, as Home's will.
    @Observable @MainActor
    final class Editing { var edit: HomeNowEdit? }

    struct Host: View {
        let editing: Editing
        let model: AppWindowModel
        let engine: Engine
        let sources: HomeSources

        var body: some View {
            AppWindowView(model: model).environment(engine).environment(\.homeSources, sources).environment(\.homeEdit, editing.edit)
        }
    }

    /// Home in the app window, offscreen, its layout in `store`, edit mode on while `edit` is set.
    @MainActor
    final class Page {
        let store: HomeLayoutStore
        let frames = HomeFrames()
        let window: NSWindow
        private let editing = Editing()

        init(_ layout: HomeLayout, editing: Bool = true) throws {
            testApp()
            store = HomeLayoutStore(defaults: try #require(UserDefaults(suiteName: testSuite())))
            store.save(layout)
            var sources = HomeSources()
            sources.lastCopied = { nil }
            sources.recentCopies = { [] }
            sources.pages = { [] }
            sources.layout = { [store] in store }
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            model.go(AppPlace(.home))
            self.editing.edit = editing ? HomeNowEdit(frames: frames) : nil
            window = AppWindowController.makeWindow(content: NSHostingView(rootView: Host(editing: self.editing, model: model,
                                                                                         engine: try SharedLook.HomeRenders.engine(), sources: sources)))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            settle()
        }

        var edit: HomeNowEdit? {
            get { editing.edit }
            set { editing.edit = newValue; settle() }
        }

        func resize(_ size: NSSize) {
            window.setContentSize(size)
            settle()
        }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            PanelTestSupport.pump(0.1)
        }

        var drawn: HomeFrames.Drawn { get throws { try #require(frames.drawn) } }
        func rect(_ key: HomeFrames.Key) throws -> CGRect { try #require(frames.rects[key], "\(key) not measured") }
        func slots(carrying id: String) -> HomeSlots { HomeSlots(frames, carrying: id, size: store.layout.size) }
    }

    /// Every place the lanes as drawn offer a carried block: in front of each other block of its lane and at its end, and
    /// beside each medium left alone on a board two blocks across.
    static func places(_ drawn: HomeFrames.Drawn, carrying carried: String, layout: HomeLayout, trailing: Bool = true) -> [Place] {
        let lanes = drawn.lanes
        let rows = lanes.board.map { $0.filter { $0 != carried } }.filter { !$0.isEmpty }
        return lanes.icons.filter { $0 != carried }.map { .icons(before: $0) } + [.icons(before: nil)]
            + lanes.column.filter { $0 != carried }.map { .column(before: $0) } + [.column(before: nil)]
            + rows.map { .board(before: $0[0]) } + [.board(before: nil)]
            + (drawn.shape.across == 2 ? rows.filter { $0.count == 1 && layout.size(of: $0[0]) == .medium }.map { .beside($0[0], trailing: trailing) } : [])
    }

    /// Check 7 for one carried block: one slot a place, each at the size its lane gives; the slots never overlap, keep to
    /// the window's width and are found where they are; every block shown lies in a slot of its own lane, the carried one
    /// in the slot that leaves it where it is.
    static func check(_ page: Page, carrying carried: String, trailing: Bool = true, _ where_: String) throws {
        let drawn = try page.drawn, layout = page.store.layout
        let built = page.slots(carrying: carried), slots = built.slots
        let places = slots.map(\.place)
        #expect(Set(places).count == places.count, "\(where_): a place with two slots: \(places)")
        #expect(Set(places) == Set(Self.places(drawn, carrying: carried, layout: layout, trailing: trailing)), "\(where_): \(places)")
        let carriedSize = layout.size(of: carried)
        for slot in slots {
            let size: HomeLayout.Size = switch slot.place {
            case .icons: .icon
            case .column: .small
            case .beside: .medium
            case .board: carriedSize == .large ? .large : .medium
            }
            #expect(slot.size == size, "\(where_): \(slot.place) gives \(slot.size)")
            for rect in slot.area {
                #expect(rect.width > 0.5 && rect.height > 0.5 && rect.minX >= 0 && rect.maxX <= page.window.frame.width, "\(where_): \(slot.place) at \(rect)")
                #expect(built.slot(at: CGPoint(x: rect.midX, y: rect.midY))?.place == slot.place, "\(where_): \(slot.place) not found at \(rect)")
                for other in slots where other.place != slot.place {
                    for b in other.area {
                        let both = rect.intersection(b)
                        #expect(both.isNull || both.width * both.height < 0.5, "\(where_): \(slot.place) overlaps \(other.place)")
                    }
                }
            }
        }
        let lanes = drawn.lanes
        let lane: [String: String] = Dictionary(uniqueKeysWithValues: lanes.icons.map { ($0, "icons") } + lanes.column.map { ($0, "column") }
            + lanes.board.flatMap { $0 }.map { ($0, "board") })
        for id in lane.keys {
            let rect = try page.rect(.block(id)), center = CGPoint(x: rect.midX, y: rect.midY)
            let slot = try #require(built.slot(at: center), "\(where_): \(id) lies in no slot")
            let found = switch slot.place { case .icons: "icons"; case .column: "column"; case .board, .beside: "board" }
            #expect(found == lane[id], "\(where_): \(id) lies in \(slot.place)")
            if id == carried {
                var put = layout
                put.put(carried, at: slot.place, listed: layout.resolved(extensions: []).map(\.id))
                #expect(HomeLayout.lanes(put.shown(extensions: []), size: put.size, across: drawn.shape.across) == lanes, "\(where_): its own spot moves \(carried) to \(slot.place)")
            }
        }
    }

    static func inStyle(_ style: PilotStyle = .instrument, _ body: () throws -> Void) rethrows {
        let look = Look.shared
        let saved = (look.style, look.themeID)
        defer { (look.style, look.themeID) = saved }
        (look.style, look.themeID) = (style, style == .toybox ? "toybox" : "nightwatch")
        try body()
    }

    @Test("Check 7: at every window size, in both styles, each place a block can go has one slot at the size it gives, carrying any block")
    func everySize() throws {
        for style in [PilotStyle.instrument, .toybox] {
            try Self.inStyle(style) {
                let page = try Page(Self.mix)
                defer { page.window.close() }
                for size in Self.sizes {
                    page.resize(size)
                    #expect(page.window.contentRect(forFrameRect: page.window.frame).size == size, "the window refused \(size)")
                    // 760 and 1000 stack the column over the board; 1440 and 1720 put it beside (spec notes, Window sizes).
                    let shape = try page.drawn.shape
                    #expect(shape.wide == (size.width >= 1440), "\(style) \(size): \(shape)")
                    for carried in ["clipboard", "workspaces", "mostUsed", "keyboard", "thisMac"] {
                        try Self.check(page, carrying: carried, "\(style) \(size) carrying \(carried)")
                    }
                    // The places spelled out once, apart from Self.places: the board is two across at every size.
                    #expect(Set(page.slots(carrying: "workspaces").slots.map(\.place)) == [
                        .icons(before: "clipboard"), .icons(before: nil), .column(before: "mostUsed"), .column(before: nil),
                        .board(before: "keyboard"), .board(before: "thisMac"), .board(before: nil), .beside("thisMac", trailing: true),
                    ])
                }
            }
        }
    }

    @Test("Check 7: an empty lane is a well with one slot; the default Home has no icons, yet the icon row takes a drop")
    func emptyLanes() throws {
        try Self.inStyle {
            let page = try Page(.standard)
            defer { page.window.close() }
            for size in Self.sizes {
                page.resize(size)
                _ = try page.rect(.well(.icons))
                try Self.check(page, carrying: "keyboard", "default \(size)")
            }
            // Everything on the board: the column and its icon row are wells.
            page.store.save(Self.layout([("keyboard", .large), ("workspaces", .medium), ("thisMac", .large)]))
            for size in Self.sizes {
                page.resize(size)
                _ = (try page.rect(.well(.icons)), try page.rect(.well(.column)))
                try Self.check(page, carrying: "workspaces", "board only \(size)")
            }
        }
    }

    @Test("Check 7: the lanes hold their shape while a block is carried: the page taken at pick-up stays, its emptied lanes wells")
    func held() throws {
        try Self.inStyle {
            let page = try Page(Self.layout([("workspaces", .small), ("keyboard", .large)]))
            defer { page.window.close() }
            page.resize(NSSize(width: 1440, height: 900))
            let shape = try page.drawn.shape
            #expect(shape.wide)
            // Picked up and hovered on the board, the only card leaves the column: held, the column stays beside the board.
            page.edit?.held = shape
            page.store.save(Self.layout([("keyboard", .large), ("workspaces", .medium)]))
            page.settle()
            #expect(try page.drawn.shape == shape)
            let well = try page.rect(.well(.column)), board = try page.rect(.lane(.board))
            #expect(well.maxX < board.minX, "the column's well \(well) is not beside the board \(board)")
            try Self.check(page, carrying: "keyboard", "held")
            // Dropped, the shape is the page's again: the board takes the page under the greeting.
            page.edit?.held = nil
            #expect(try page.drawn.shape.wide == false)
        }
    }

    @Test("Check 8: edit mode turned on in a Home already drawn measures it; a lone medium's empty half is a slot beside it")
    func loneMedium() throws {
        try Self.inStyle {
            let page = try Page(Self.mix, editing: false)
            defer { page.window.close() }
            #expect(page.frames.rects.isEmpty, "measured at rest")
            for size in Self.sizes {
                page.resize(size)
                page.edit = HomeNowEdit(frames: page.frames)
                let board = try page.rect(.lane(.board)), medium = try page.rect(.block("thisMac"))
                // At rest it spans the board; edit mode may draw it at half width (Q55): it starts the board either way.
                #expect(abs(medium.minX - board.minX) < 1, "\(size): the lone medium at \(medium.minX) on a board at \(board.minX)")
                let beside = page.slots(carrying: "workspaces").slots.first { $0.place == .beside("thisMac", trailing: true) }
                let shape = try page.drawn.shape
                if shape.across == 2 {
                    let half = (board.width - shape.gap) / 2
                    #expect(beside?.area == [CGRect(x: board.maxX - half, y: medium.minY, width: half, height: medium.height)], "\(size): \(String(describing: beside))")
                    #expect(beside?.size == .medium)
                } else {
                    #expect(beside == nil, "\(size): one block across, yet a slot beside")
                }
                page.edit = nil
            }
        }
    }

    // MARK: Drag and drop (T5)

    /// Home in the app window in its own edit mode, as ⌘E starts it, offscreen: the mode a drag on the page goes through.
    /// Points go in as the page's drag gesture hands them, global; the page's space is turned into it by its measured origin.
    @MainActor
    final class Editor {
        let store: HomeLayoutStore
        let window: NSWindow
        let watch = HomeEditWatch()

        init(_ layout: HomeLayout, size: NSSize) throws {
            testApp()
            store = HomeLayoutStore(defaults: try #require(UserDefaults(suiteName: testSuite())))
            store.save(layout)
            var sources = HomeSources()
            sources.lastCopied = { nil }
            sources.recentCopies = { [] }
            sources.pages = { [] }
            sources.layout = { [store] in store }
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            model.go(AppPlace(.home))
            window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
                .environment(try SharedLook.HomeRenders.engine()).environment(\.homeSources, sources)
                .environment(\.homeStart, HomePage.Start(editing: true)).environment(\.homeEditWatch, watch)))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.setContentSize(size)
            settle()
        }

        func settle(_ seconds: Double = 0.2) {
            window.contentView?.layoutSubtreeIfNeeded()
            PanelTestSupport.pump(seconds)
        }

        /// Pumps until `done`, a second at most: a slot counts after an 80 ms rest, and the page then makes room.
        func until(_ done: () -> Bool) {
            let end = Date.now + 1
            while !done(), Date.now < end { settle(0.05) }
            settle(0.4)
        }

        var mode: HomeEditMode { get throws { try #require(watch.mode, "not in edit mode") } }
        var session: HomeEditSession { get throws { try mode.session } }
        var frames: HomeFrames { get throws { try #require(mode.frames, "edit mode has no frames") } }
        func rect(_ key: HomeFrames.Key) throws -> CGRect { try #require(frames.rects[key], "\(key) not measured") }

        /// A point of the page's space as the drag gesture gives it.
        func global(_ point: CGPoint) throws -> CGPoint {
            let origin = try #require(frames.origin, "the page's origin not measured")
            return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        }

        func center(_ id: String) throws -> CGPoint {
            let rect = try rect(.block(id))
            return try global(CGPoint(x: rect.midX, y: rect.midY))
        }

        /// The middle of a place's slot while `id` is carried, global.
        func slot(_ place: Place) throws -> CGPoint {
            let lift = try #require(mode.carrying, "nothing carried")
            let area = try #require(lift.slots.slots.first { $0.place == place }?.area.first, "no slot \(place) carrying \(lift.id)")
            return try global(CGPoint(x: area.midX, y: area.midY))
        }
    }

    @Test("A block dragged to another lane: the page makes room after the pointer rests, the lanes hold their shape, the drop takes the lane's size and the slot's order; nothing is saved before Done")
    func dragAcrossLanes() throws {
        try Self.inStyle {
            for size in Self.sizes {
                let editor = try Editor(Self.mix, size: size)
                defer { editor.window.close() }
                let session = try editor.session, mode = try editor.mode
                let shape = try #require(try editor.frames.drawn?.shape)
                // The clipboard tab, picked up and carried onto the board's end.
                let start = try editor.center("clipboard")
                mode.drag(from: start, to: CGPoint(x: start.x + 6, y: start.y + 6))
                #expect(session.carried == "clipboard", "\(size): no pick-up")
                let end = try editor.slot(.board(before: nil))
                mode.drag(from: start, to: end)
                // A new slot counts only once the pointer rests in it.
                #expect(session.target == nil, "\(size): the slot counted at once")
                editor.until { session.target == .board(before: nil) }
                #expect(session.target == .board(before: nil), "\(size): no slot after the rest")
                // The page drew the drop's preview: the carried tab is a medium well on the board, in the shape taken at pick-up.
                let drawn = try #require(try editor.frames.drawn)
                #expect(drawn.shape == shape, "\(size): the page restructured under the pointer")
                #expect(drawn.lanes.board.last == ["clipboard"] || drawn.lanes.board.last?.contains("clipboard") == true, "\(size): \(drawn.lanes.board)")
                let well = try editor.rect(.block("clipboard")), board = try editor.rect(.lane(.board))
                #expect(board.insetBy(dx: -1, dy: -1).contains(well) && well.width > HomeLayout.Size.tab * 2, "\(size): the well at \(well) on a board at \(board)")
                mode.release()
                #expect(session.carried == nil)
                #expect(session.draft.size(of: "clipboard") == .medium, "\(size): dropped on the board, yet \(session.draft.size(of: "clipboard"))")
                #expect(session.draft.shown(extensions: []).last == "clipboard", "\(size): \(session.draft.shown(extensions: []))")
                #expect(editor.store.layout == Self.mix, "\(size): saved before Done")
                // Into the column, released before the rest: it drops where the pointer is, small, before Most used.
                editor.settle(0.5)
                let back = try editor.center("clipboard")
                mode.drag(from: back, to: CGPoint(x: back.x + 6, y: back.y))
                mode.drag(from: back, to: try editor.slot(.column(before: "mostUsed")))
                mode.release()
                let shown = session.draft.shown(extensions: [])
                #expect(session.draft.size(of: "clipboard") == .small && shown.firstIndex(of: "clipboard")! + 1 == shown.firstIndex(of: "mostUsed")!, "\(size): \(shown)")
                // ⌘Z steps back over both drops.
                mode.undo()
                mode.undo()
                #expect(session.draft == Self.mix, "\(size): undo did not give the entry back")
                editor.settle(0.5)
            }
        }
    }

    @Test("A carried block goes back unchanged off every slot and on Escape, which leaves edit mode on; the rest of that drag moves nothing")
    func putBack() throws {
        try Self.inStyle {
            let editor = try Editor(Self.mix, size: NSSize(width: 1440, height: 900))
            defer { editor.window.close() }
            let session = try editor.session, mode = try editor.mode
            let start = try editor.center("workspaces")
            mode.drag(from: start, to: CGPoint(x: start.x, y: start.y + 8))
            mode.drag(from: start, to: CGPoint(x: start.x - 5_000, y: start.y - 5_000))
            mode.release()
            #expect(session.draft == Self.mix && !session.canUndo, "off every slot it moved")
            editor.settle(0.5)
            // Escape while carrying over a slot: back where it was, still editing; the drag goes on moving nothing.
            mode.drag(from: start, to: CGPoint(x: start.x, y: start.y + 10))
            let slot = try editor.slot(.board(before: "keyboard"))
            mode.drag(from: start, to: slot)
            editor.until { session.target != nil }
            #expect(mode.escape() == false, "Escape while carrying ended edit mode")
            #expect(session.carried == nil && session.draft == Self.mix)
            mode.drag(from: start, to: CGPoint(x: slot.x + 20, y: slot.y))
            mode.release()
            #expect(session.carried == nil && session.draft == Self.mix && !session.canUndo, "the escaped drag still dropped")
            // It flies back and fades, then is gone.
            editor.until { mode.lift == nil }
            #expect(mode.lift == nil, "the floating block stayed")
        }
    }

    @Test("The tray both ways: a block dropped on the edit bar hides, its place and size kept; dragged back out of the tray it shows where it is dropped, at that slot's size")
    func tray() throws {
        try Self.inStyle {
            for size in [NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900)] {
                let editor = try Editor(Self.mix, size: size)
                defer { editor.window.close() }
                let session = try editor.session, mode = try editor.mode
                let bar = try #require(try editor.frames.bar, "\(size): the edit bar not measured")
                let tray = CGPoint(x: bar.midX, y: bar.midY)
                let start = try editor.center("workspaces")
                mode.drag(from: start, to: CGPoint(x: start.x + 6, y: start.y))
                mode.drag(from: start, to: tray)
                #expect(mode.overTray, "\(size): the bar at \(bar) did not take the block")
                mode.release()
                #expect(!session.draft.shown(extensions: []).contains("workspaces") && session.draft.size(of: "workspaces") == .small, "\(size): \(session.draft)")
                editor.settle(0.5)
                // Out of the tray onto the board's end: shown there, medium.
                mode.dragHidden("workspaces", from: tray, to: CGPoint(x: tray.x, y: tray.y - 6))
                #expect(session.carried == "workspaces", "\(size): the tray chip lifted nothing")
                mode.dragHidden("workspaces", from: tray, to: try editor.slot(.board(before: nil)))
                editor.until { session.target == .board(before: nil) }
                mode.release()
                #expect(session.draft.shown(extensions: []).last == "workspaces" && session.draft.size(of: "workspaces") == .medium, "\(size): \(session.draft)")
                editor.settle(0.5)
            }
        }
    }

    @Test("Check 8 drawn: in edit mode a lone medium takes half the board, its empty half a well beside it")
    func loneMediumHalf() throws {
        try Self.inStyle {
            for size in Self.sizes {
                let editor = try Editor(Self.mix, size: size)
                defer { editor.window.close() }
                let shape = try #require(try editor.frames.drawn?.shape)
                let board = try editor.rect(.lane(.board)), medium = try editor.rect(.block("thisMac"))
                // Its frame is measured under edit mode's 0.98 scale, about its centre.
                let half = shape.across == 2 ? (board.width - shape.gap) / 2 : board.width
                #expect(abs(medium.width - half * HomeMotion.enterScale) < 2 || abs(medium.width - half) < 2, "\(size): the lone medium is \(medium.width) wide, half is \(half)")
            }
        }
    }

    @Test("Check 8: a medium of a pair picked up leaves its partner alone, with a slot in the half it left")
    func pair() throws {
        try Self.inStyle {
            let page = try Page(Self.layout([("workspaces", .small), ("keyboard", .medium), ("thisMac", .medium)]))
            defer { page.window.close() }
            for size in Self.sizes.dropFirst(2) {
                page.resize(size)
                #expect(try page.drawn.lanes.board == [["keyboard", "thisMac"]])
                try Self.check(page, carrying: "thisMac", trailing: true, "\(size) carrying the right one")
                try Self.check(page, carrying: "keyboard", trailing: false, "\(size) carrying the left one")
                let keyboard = try page.rect(.block("keyboard"))
                let left = page.slots(carrying: "keyboard").slot(at: CGPoint(x: keyboard.midX, y: keyboard.midY))
                #expect(left?.place == .beside("thisMac", trailing: false))
            }
        }
    }
}
}
#endif
