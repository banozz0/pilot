#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home edit mode, seam 2 (spec home-edit, T3; P91's grid): Home drawn offscreen in the app window at the four window
/// sizes, measured: each block on its cells, the grid stretching with the window; then edit mode driven as its drags and
/// handles drive it. Checks 7 and 8 of the spec's notes. It sets Look.shared, so it runs inside SharedLook, one suite at a
/// time.
extension SharedLook {
@MainActor
@Suite("HomeSlots", .serialized)
struct HomeSlotsTests {
    /// The least window, the default, a laptop's and a tiled half of an ultrawide (Sven, Q57).
    static let sizes = [NSSize(width: 760, height: 520), NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900),
                        NSSize(width: 1720, height: 1440)]

    static func cell(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> HomeCell { HomeCell(x: x, y: y, w: w, h: h) }

    /// A Home of every class: the clipboard a one-row Strip, Workspaces and Most used cards, the keyboard large, This Mac
    /// half the board under it.
    static var mix: HomeLayout {
        var layout = HomeLayout(rows: [])
        for (id, cell) in [("greeting", cell(0, 0, 5, 2)), ("clipboard", cell(0, 2, 5, 1)), ("workspaces", cell(0, 3, 5, 3)),
                           ("mostUsed", cell(0, 6, 5, 3)), ("keyboard", cell(5, 0, 18, 6)), ("thisMac", cell(5, 6, 9, 5))] {
            layout.set(id, shown: true)
            layout.set(id, cell: cell)
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

    /// Home in the app window, offscreen, its layout in `store`, measured while `edit` is set (no edit mode of its own, so
    /// its blocks draw at full size).
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
            // Copies kept, so Clipboard draws: it waits for one (simplify-pages T3).
            sources.lastCopied = { HomeCopy(text: "bd show agent-bo-95422987", at: Date().addingTimeInterval(-125), count: InstrumentRenders.clips.count) }
            sources.recentCopies = { InstrumentRenders.clips }
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

        func rect(_ key: HomeFrames.Key) throws -> CGRect { try #require(frames.rects[key], "\(key) not measured") }
    }

    /// Check 7 for a page as drawn: every block it drew lies on its cells' frame within the grid, the grid inside the
    /// window, no two blocks overlapping, and each found where it lies.
    static func check(_ page: Page, _ where_: String) throws {
        let grid = try page.rect(.grid), cells = page.frames.cells
        #expect(grid.minX >= 0 && grid.maxX <= page.window.frame.width + 0.5, "\(where_): the grid at \(grid)")
        #expect(HomeGrid.valid(Array(cells.values)), "\(where_): \(cells)")
        for (id, cell) in cells {
            let rect = try page.rect(.block(id)), want = HomeGrid.rect(cell, inner: grid.width).offsetBy(dx: grid.minX, dy: grid.minY)
            #expect(abs(rect.minX - want.minX) < 1 && abs(rect.minY - want.minY) < 1 && abs(rect.width - want.width) < 1 && abs(rect.height - want.height) < 1,
                    "\(where_): \(id) at \(rect), its cells \(cell) at \(want)")
            #expect(page.frames.block(at: CGPoint(x: rect.midX, y: rect.midY)) == id, "\(where_): \(id) not found where it lies")
            #expect(page.frames.cell(nearest: rect) == cell, "\(where_): \(id)'s frame snaps to \(String(describing: page.frames.cell(nearest: rect)))")
        }
    }

    static func inStyle(_ style: PilotStyle = .instrument, _ body: () throws -> Void) rethrows {
        let look = Look.shared
        let saved = (look.style, look.themeID)
        defer { (look.style, look.themeID) = saved }
        (look.style, look.themeID) = (style, style == .toybox ? "toybox" : "nightwatch")
        try body()
    }

    @Test("Check 7: at every window size, in both styles, each block draws on its cells: 23 columns that stretch with the window, none overlapping")
    func everySize() throws {
        for style in [PilotStyle.instrument, .toybox] {
            try Self.inStyle(style) {
                let page = try Page(Self.mix)
                defer { page.window.close() }
                var widths: [CGFloat] = []
                for size in Self.sizes {
                    page.resize(size)
                    #expect(page.window.contentRect(forFrameRect: page.window.frame).size == size, "the window refused \(size)")
                    #expect(page.frames.cells == Self.mix.cells(Self.mix.shown(extensions: [])), "\(style) \(size): \(page.frames.cells)")
                    try Self.check(page, "\(style) \(size)")
                    widths.append(try page.rect(.grid).width)
                }
                // Each block keeps its share of the width: the grid widens with the window, never the blocks' columns.
                #expect(widths == widths.sorted() && Set(widths).count == widths.count, "\(style): \(widths)")
            }
        }
    }

    @Test("Check 7: the default Home draws on its cells at every window size")
    func defaultCells() throws {
        try Self.inStyle {
            let page = try Page(.standard)
            defer { page.window.close() }
            for size in Self.sizes {
                page.resize(size)
                #expect(page.frames.cells == HomeLayout.standard.cells(HomeLayout.standard.shown(extensions: [])), "\(size): \(page.frames.cells)")
                try Self.check(page, "default \(size)")
            }
        }
    }

    @Test("Check 8: edit mode turned on in a Home already drawn measures it, nothing at rest")
    func measuresOnEdit() throws {
        try Self.inStyle {
            let page = try Page(Self.mix, editing: false)
            defer { page.window.close() }
            #expect(page.frames.rects.isEmpty, "measured at rest")
            for size in Self.sizes {
                page.resize(size)
                page.edit = HomeNowEdit(frames: page.frames)
                try Self.check(page, "turned on at \(size)")
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

        /// Pumps until `done`, a second at most: new cells count after an 80 ms rest, and the page then makes room.
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
            let rect = try #require(frames.frame(of: id), "\(id) not drawn")
            return try global(CGPoint(x: rect.midX, y: rect.midY))
        }

        /// Where a cell's top left lies, global.
        func corner(_ cell: HomeCell) throws -> CGPoint {
            let grid = try rect(.grid)
            let rect = HomeGrid.rect(cell, inner: grid.width)
            return try global(CGPoint(x: grid.minX + rect.minX, y: grid.minY + rect.minY))
        }

        /// One column's and one row's step, in points.
        var step: CGSize { get throws { CGSize(width: HomeGrid.cellWidth(try rect(.grid).width) + HomeGrid.gap, height: HomeGrid.pitch) } }
    }

    @Test("A block dragged: the page makes room once the pointer rests, the drop takes the cells under it at its own size, and nothing is saved before Done")
    func dragToCells() throws {
        try Self.inStyle {
            for size in Self.sizes {
                let editor = try Editor(Self.mix, size: size)
                defer { editor.window.close() }
                let session = try editor.session, mode = try editor.mode
                // Most used, picked up at its top left corner and carried onto the keyboard's right half, in view at every size.
                let start = try editor.corner(Self.cell(0, 6, 5, 3)).applying(CGAffineTransform(translationX: 4, y: 4))
                mode.drag(from: start, to: CGPoint(x: start.x + 6, y: start.y + 6))
                #expect(session.carried == "mostUsed", "\(size): no pick-up")
                let to = try editor.corner(Self.cell(14, 2, 5, 3))
                mode.drag(from: start, to: CGPoint(x: to.x + 4, y: to.y + 4))
                // New cells count only once the pointer rests on them.
                #expect(session.target == nil, "\(size): the cells counted at once")
                editor.until { session.target != nil }
                #expect(session.target == Self.cell(14, 2, 5, 3), "\(size): \(String(describing: session.target))")
                // The page drew the drop's preview: on the keyboard's upper half it wins those cells, floated to the top,
                // and the keyboard and This Mac move down out of its way.
                let preview = try editor.frames.cells
                #expect(preview["mostUsed"] == Self.cell(14, 0, 5, 3) && preview["keyboard"] == Self.cell(5, 3, 18, 6), "\(size): \(preview)")
                mode.release()
                #expect(session.carried == nil && session.draft.cell(of: "mostUsed") == Self.cell(14, 0, 5, 3), "\(size): \(String(describing: session.draft.cell(of: "mostUsed")))")
                #expect(editor.store.layout == Self.mix, "\(size): saved before Done")
                // Released before the rest: it drops where the pointer is, onto Workspaces, which moves down.
                editor.settle(0.5)
                let held = try editor.corner(Self.cell(14, 0, 5, 3)), onto = try editor.corner(Self.cell(0, 3, 5, 3))
                mode.drag(from: CGPoint(x: held.x + 10, y: held.y + 10), to: CGPoint(x: held.x + 16, y: held.y + 10))
                #expect(session.carried == "mostUsed", "\(size): picked up \(String(describing: session.carried))")
                mode.drag(from: CGPoint(x: held.x + 10, y: held.y + 10), to: CGPoint(x: onto.x + 10, y: onto.y + 10))
                mode.release()
                #expect(session.draft.cell(of: "mostUsed") == Self.cell(0, 3, 5, 3) && session.draft.cell(of: "workspaces") == Self.cell(0, 6, 5, 3),
                        "\(size): \(String(describing: session.draft.cell(of: "mostUsed"))) \(String(describing: session.draft.cell(of: "workspaces")))")
                // ⌘Z steps back over both drops.
                mode.undo()
                mode.undo()
                #expect(session.draft == Self.mix, "\(size): undo did not give the entry back")
                editor.settle(0.5)
            }
        }
    }

    @Test("A handle resizes by whole cells as the pointer goes: the block draws at its new cells, the blocks in its way move down; a resize back is no edit")
    func handles() throws {
        try Self.inStyle {
            for size in [NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900)] {
                let editor = try Editor(Self.mix, size: size)
                defer { editor.window.close() }
                let session = try editor.session, mode = try editor.mode, step = try editor.step
                // The keyboard's bottom right corner, four columns in and three rows down: 14 × 9.
                let rect = try #require(try editor.frames.frame(of: "keyboard")), corner = try editor.global(CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
                mode.resize("keyboard", edges: [.bottom, .right], from: corner, to: CGPoint(x: corner.x - 4 * step.width, y: corner.y + 3 * step.height))
                #expect(session.target == Self.cell(5, 0, 14, 9), "\(size): \(String(describing: session.target))")
                editor.settle(0.4)
                let drawn = try editor.frames.cells
                #expect(drawn["keyboard"] == Self.cell(5, 0, 14, 9) && drawn["thisMac"] == Self.cell(5, 9, 9, 5), "\(size): \(drawn)")
                // Its left edge and its right one past the grid's edges: held inside the columns, never under one cell.
                mode.resize("keyboard", edges: [.bottom, .right], from: corner, to: CGPoint(x: corner.x + 40 * step.width, y: corner.y - 40 * step.height))
                #expect(session.target == Self.cell(5, 0, 18, 1), "\(size): \(String(describing: session.target))")
                mode.resize("keyboard", edges: [.bottom, .right], from: corner, to: corner)
                mode.release()
                #expect(session.draft == Self.mix && !session.canUndo, "\(size): a resize back changed the draft")
                editor.settle(0.5)
                let left = try editor.global(CGPoint(x: rect.minX + 2, y: rect.midY))
                mode.resize("keyboard", edges: .left, from: left, to: CGPoint(x: left.x - 3 * step.width, y: left.y))
                mode.release()
                #expect(session.draft.cell(of: "keyboard") == Self.cell(2, 0, 21, 6), "\(size): \(String(describing: session.draft.cell(of: "keyboard")))")
                #expect(session.draft.cell(of: "clipboard")?.y ?? 0 >= 6, "\(size): the column's blocks in its way moved down")
                editor.settle(0.5)
            }
        }
    }

    @Test("Escape while carrying puts the block back and leaves edit mode on; the rest of that drag moves nothing")
    func putBack() throws {
        try Self.inStyle {
            let editor = try Editor(Self.mix, size: NSSize(width: 1440, height: 900))
            defer { editor.window.close() }
            let session = try editor.session, mode = try editor.mode
            let start = try editor.center("workspaces")
            mode.drag(from: start, to: CGPoint(x: start.x, y: start.y + 8))
            let far = try editor.corner(Self.cell(14, 0, 5, 3))
            mode.drag(from: start, to: far)
            editor.until { session.target != nil }
            #expect(mode.escape() == false, "Escape while carrying ended edit mode")
            #expect(session.carried == nil && session.draft == Self.mix)
            mode.drag(from: start, to: CGPoint(x: far.x + 20, y: far.y))
            mode.release()
            #expect(session.carried == nil && session.draft == Self.mix && !session.canUndo, "the escaped drag still dropped")
            // It flies back and fades, then is gone.
            editor.until { mode.lift == nil }
            #expect(mode.lift == nil, "the floating block stayed")
        }
    }

    @Test("The tray both ways: a block dropped on the edit bar hides, its cells kept; dragged back out of the tray it shows where it is dropped, at its size")
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
                #expect(!session.draft.shown(extensions: []).contains("workspaces") && session.draft.cell(of: "workspaces") == Self.cell(0, 3, 5, 3), "\(size): \(session.draft)")
                editor.settle(0.5)
                // Out of the tray onto the right of the board: shown there, at its kept size.
                let to = try editor.corner(Self.cell(14, 6, 5, 3))
                mode.dragHidden("workspaces", from: tray, to: CGPoint(x: tray.x, y: tray.y - 6))
                #expect(session.carried == "workspaces", "\(size): the tray chip lifted nothing")
                mode.dragHidden("workspaces", from: tray, to: CGPoint(x: to.x + 4, y: to.y + 4))
                editor.until { session.target != nil }
                mode.release()
                #expect(session.draft.shown(extensions: []).contains("workspaces") && session.draft.cell(of: "workspaces") == Self.cell(14, 6, 5, 3), "\(size): \(session.draft)")
                editor.settle(0.5)
            }
        }
    }
}
}
#endif
