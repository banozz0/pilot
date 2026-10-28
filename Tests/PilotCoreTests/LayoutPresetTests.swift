import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// Layout presets (story 107, card agent-bo-95422736): each preset as the tiler commands that build it, the cycle,
/// the per-workspace store and when auto re-applies. Pure: nothing here moves a window.
@Suite("Layout presets")
struct LayoutPresetTests {
    /// Every window moved to the far end in order, so the tiles read in that order.
    static func order(_ ids: [Int], _ d: Direction) -> [AeroCommand] {
        ids.flatMap { id in Array(repeating: AeroCommand.move(id: id, d), count: ids.count - 1) }
    }

    @Test("Columns: one flat row, each tile moved to the far right in turn so they read in order, equal widths")
    func columns() {
        #expect(LayoutPreset.columns.commands(workspace: "2", windows: [7, 8])
                == [.flatten(workspace: "2"), .setRootLayout(workspace: "2", "h_tiles"), .move(id: 7, .right), .move(id: 8, .right),
                    .balanceSizes(workspace: "2")])
        #expect(LayoutPreset.columns.commands(workspace: "2", windows: [7, 8, 9]).filter { if case .move = $0 { true } else { false } }.count == 6)
    }

    @Test("Rows: one flat column, top to bottom")
    func rows() {
        #expect(LayoutPreset.rows.commands(workspace: "2", windows: [7, 8, 9])
                == [.flatten(workspace: "2"), .setRootLayout(workspace: "2", "v_tiles")] + Self.order([7, 8, 9], .down)
                + [.balanceSizes(workspace: "2")])
    }

    /// Moody's REJECT http://localhost:8228/p/vYVjANm3a1s: joining window 4 to the stack nests it, and the tiler's
    /// opposite-orientation normalization turns the inner pair sideways; a window moved left into a container goes inside
    /// it (MoveCommand.deepMoveIn), so the stack stays one column.
    @Test("Main + stack: the first window, then 2 and 3 joined into a column beside it, each later window moved into it; equal sizes make it 50 %")
    func mainStack() {
        #expect(LayoutPreset.mainStack.commands(workspace: "1", windows: [1, 2, 3, 4, 5])
                == [.flatten(workspace: "1"), .setRootLayout(workspace: "1", "h_tiles")] + Self.order([1, 2, 3, 4, 5], .right)
                + [.joinWith(id: 3, .left), .move(id: 4, .left), .move(id: 5, .left), .balanceSizes(workspace: "1")])
        #expect(!LayoutPreset.mainStack.commands(workspace: "1", windows: [1, 2]).contains { if case .joinWith = $0 { true } else { false } })
    }

    @Test("Grid: windows paired into columns, 2×2 for four, the odd one alone")
    func grid() {
        #expect(LayoutPreset.grid.commands(workspace: "1", windows: [1, 2, 3, 4]).filter { if case .joinWith = $0 { true } else { false } }
                == [.joinWith(id: 2, .left), .joinWith(id: 4, .left)])
        #expect(LayoutPreset.grid.commands(workspace: "1", windows: [1, 2, 3]).filter { if case .joinWith = $0 { true } else { false } }
                == [.joinWith(id: 2, .left)])
    }

    /// Scrolling layout spec: every window a column on the strip, each at its own width; equal sizes mean nothing there.
    @Test("Scrolling: one flat strip, each column moved to the far right in turn so they read in order, no balance")
    func scrolling() {
        #expect(LayoutPreset.scrolling.commands(workspace: "2", windows: [7, 8, 9])
                == [.flatten(workspace: "2"), .setRootLayout(workspace: "2", "h_scrolling")] + Self.order([7, 8, 9], .right))
        #expect(LayoutPreset.scrolling.commands(workspace: "2", windows: [7]) == [.flatten(workspace: "2"), .setRootLayout(workspace: "2", "h_scrolling")])
        #expect(LayoutPreset.scrolling.label == "Scrolling")
    }

    /// The editor's strip: three columns whole at a third each, a lone window the whole screen, each column past the
    /// third peeking in at the right edge.
    @Test("Scrolling's picture: a lone window whole, columns a third wide, the fourth and fifth 8 % peeks at the right edge")
    func scrollingTiles() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(LayoutPreset.scrolling.tiles(1, in: area) == [area])
        #expect(LayoutPreset.scrolling.tiles(2, in: area).map(\.width) == [1000 / 3, 1000 / 3])
        let five = LayoutPreset.scrolling.tiles(5, in: area)
        #expect(five.map(\.width) == [280, 280, 280, 80, 80])
        #expect(five.map(\.minX) == [0, 280, 560, 840, 920])
        #expect(five.allSatisfy { $0.height == 600 })
        // However many, the peeks share a quarter at most: every column keeps a width.
        let twenty = LayoutPreset.scrolling.tiles(20, in: area)
        #expect(twenty.allSatisfy { $0.width > 0 } && abs(twenty.last!.maxX - 1000) < 0.001)
    }

    @Test("One window needs no moves; no window needs nothing")
    func few() {
        #expect(LayoutPreset.grid.commands(workspace: "3", windows: [5])
                == [.flatten(workspace: "3"), .setRootLayout(workspace: "3", "h_tiles"), .balanceSizes(workspace: "3")])
        #expect(LayoutPreset.columns.commands(workspace: "3", windows: []).isEmpty)
    }

    /// Cycle layout (workspaces.cycleLayout) walks this order; scrolling comes last, where its predecessor was.
    @Test("The cycle: main + stack, columns, rows, grid, scrolling, and round again; a workspace with none starts at main + stack")
    func cycle() {
        #expect(LayoutPreset.allCases.map(\.label) == ["Main + stack", "Columns", "Rows", "Grid", "Scrolling"])
        #expect(LayoutPreset.next(after: nil) == .mainStack)
        var walked: [LayoutPreset] = []
        var preset: LayoutPreset? = nil
        for _ in 0..<6 { preset = LayoutPreset.next(after: preset); walked.append(preset!) }
        #expect(walked == [.mainStack, .columns, .rows, .grid, .scrolling, .mainStack])
    }

    @Test("A rebuild is one tiler eval: the commands in order, separated by ;, an argument with a space quoted")
    func eval() {
        #expect(AeroCommand.eval([.flatten(workspace: "2"), .joinWith(id: 3, .left)]).arguments
                == ["eval", "flatten-workspace-tree --workspace 2; join-with --window-id 3 left"])
        #expect(AeroCommand.eval([.workspace("my work")]).arguments == ["eval", "workspace 'my work'"])
    }

    @Test("Keep this layout: a saved row keeps the user's off and on through a save and a load; a row without the switch reads on")
    func keepDefaultsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        defaults.set(Data(#"{"2":{"preset":"grid","auto":false},"3":{"preset":"rows","auto":true},"7":{"preset":"columns"}}"#.utf8), forKey: WorkspaceLayout.key)
        let old = WorkspaceLayout.load(defaults)
        #expect(old == ["2": WorkspaceLayout(preset: .grid, auto: false), "3": WorkspaceLayout(preset: .rows, auto: true),
                        "7": WorkspaceLayout(preset: .columns, auto: true)])
        WorkspaceLayout.save(old, to: defaults)
        #expect(WorkspaceLayout.load(defaults) == old)
    }

    @Test("Each workspace keeps its preset and auto switch across launches; a broken store reads as none")
    func stored() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(WorkspaceLayout.load(defaults).isEmpty)
        let layouts = ["1": WorkspaceLayout(preset: .mainStack, auto: true), "3": WorkspaceLayout(preset: .grid, auto: false)]
        WorkspaceLayout.save(layouts, to: defaults)
        #expect(WorkspaceLayout.load(defaults) == layouts)
        defaults.set(Data("nope".utf8), forKey: WorkspaceLayout.key)
        #expect(WorkspaceLayout.load(defaults).isEmpty)
    }

    /// Acceptance check 7: one value that fails to decode would drop every workspace's layout, so the layout scrolling
    /// replaced reads as scrolling, in the layouts and in a saved preset.
    @Test("A stored accordion layout loads as scrolling, and every other workspace keeps its layout")
    func storedAccordionLoadsAsScrolling() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        defaults.set(Data(#"{"1":{"preset":"mainStack","auto":true},"4":{"preset":"accordion","auto":true},"5":{"preset":"grid","auto":false},"6":{"auto":false}}"#.utf8),
                     forKey: WorkspaceLayout.key)
        #expect(WorkspaceLayout.load(defaults) == ["1": WorkspaceLayout(preset: .mainStack, auto: true), "4": WorkspaceLayout(preset: .scrolling, auto: true),
                                                   "5": WorkspaceLayout(preset: .grid, auto: false), "6": WorkspaceLayout(preset: nil, auto: false)])
        let preset = try JSONDecoder().decode(WorkspacePreset.self, from: Data(#"{"name":"Read","apps":[],"layout":"accordion"}"#.utf8))
        #expect(preset.layout == .scrolling)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LayoutPreset.self, from: Data(#""fan""#.utf8)) }
        #expect(String(decoding: try JSONEncoder().encode(LayoutPreset.scrolling), as: UTF8.self) == #""scrolling""#)
    }

    @Test("Where a release falls in each preset's tiles: columns split side by side, rows top to bottom, grid by pairs")
    func dropOrder() {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(LayoutPreset.columns.dropOrder([1, 2, 3], inserting: 9, at: CGPoint(x: 500, y: 10), in: area) == [1, 9, 2, 3])
        #expect(LayoutPreset.rows.dropOrder([1, 2], inserting: 9, at: CGPoint(x: 10, y: 100), in: area) == [9, 1, 2])
        // Grid of three: 1 over 2 on the left, 3 alone on the right; the lower half of 1 goes between 1 and 2.
        #expect(LayoutPreset.grid.dropOrder([1, 2, 3], inserting: 9, at: CGPoint(x: 100, y: 300), in: area) == [1, 9, 2, 3])
        #expect(LayoutPreset.grid.dropOrder([1, 2, 3], inserting: 9, at: CGPoint(x: 1100, y: 100), in: area) == [1, 2, 3, 9])
        #expect(LayoutPreset.mainStack.dropOrder([], inserting: 9, at: .zero, in: area) == [9])
    }
}
