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

    @Test("Own sizes side by side (Columns' build): one flat row, each tile moved to the far right in turn so they read in order, equal widths")
    func columns() {
        #expect(LayoutPreset.sideBySide(workspace: "2", windows: [7, 8])
                == [.flatten(workspace: "2"), .setRootLayout(workspace: "2", "h_tiles"), .move(id: 7, .right), .move(id: 8, .right),
                    .balanceSizes(workspace: "2")])
        #expect(LayoutPreset.sideBySide(workspace: "2", windows: [7, 8, 9]).filter { if case .move = $0 { true } else { false } }.count == 6)
    }

    @Test("Rows: one flat column, top to bottom")
    func rows() {
        #expect(LayoutPreset.rows.commands(workspace: "2", windows: [7, 8, 9])
                == [.flatten(workspace: "2"), .setRootLayout(workspace: "2", "v_tiles")] + Self.order([7, 8, 9], .down)
                + [.balanceSizes(workspace: "2")])
    }

    /// Layouts round 1's tiles on a 3440 × 1440 screen, gapless, `[x, y, width, height]` by open order, each count as the
    /// pick page (~/pages/pilot-layouts-round1.html) draws it at a tenth.
    static func tiles(_ preset: LayoutPreset, _ n: Int) -> [[Double]] {
        preset.tiles(n, in: CGRect(x: 0, y: 0, width: 3440, height: 1440)).map { [$0.minX, $0.minY, $0.width, $0.height].map { (Double($0) * 10).rounded() / 10 } }
    }

    /// Sven's split (Q231) keeps halving from 6 (Q232 B), the newest tile along its longer side; centred
    /// main puts the rest either side, right first. Each is one engine arrange, no moves; the open order survives a close
    /// and follows a swap, though the split reads 1, 2, 5, 3, 4.
    @Test("Main + stack and centred main: the pick page's tiles at 1 to 6 windows, the main always centred, one arrange, open order kept")
    func mainStack() {
        let main: [Double] = [0, 0, 1720, 1440], whole: [Double] = [0, 0, 3440, 1440]
        #expect(Self.tiles(.mainStack, 1) == [whole])
        #expect(Self.tiles(.mainStack, 2) == [main, [1720, 0, 1720, 1440]])
        #expect(Self.tiles(.mainStack, 3) == [main, [1720, 0, 1720, 720], [1720, 720, 1720, 720]])
        #expect(Self.tiles(.mainStack, 4) == [main, [1720, 0, 1720, 720], [1720, 720, 860, 720], [2580, 720, 860, 720]])
        #expect(Self.tiles(.mainStack, 5) == [main, [1720, 0, 860, 720], [1720, 720, 860, 720], [2580, 720, 860, 720], [2580, 0, 860, 720]])
        #expect(Self.tiles(.mainStack, 6) == [main, [1720, 0, 860, 720], [1720, 720, 860, 720], [2580, 720, 860, 720], [2580, 0, 430, 720],
                                              [3010, 0, 430, 720]])
        // Centred main keeps its main in the middle half from the first window (Sven, 2026-11-14).
        #expect(Self.tiles(.centred, 1) == [[860, 0, 1720, 1440]])
        #expect(Self.tiles(.centred, 2) == [[860, 0, 1720, 1440], [2580, 0, 860, 1440]])
        #expect(Self.tiles(.centred, 3) == [[860, 0, 1720, 1440], [2580, 0, 860, 1440], [0, 0, 860, 1440]])
        #expect(Self.tiles(.centred, 6) == [[860, 0, 1720, 1440], [2580, 0, 860, 480], [0, 0, 860, 720], [2580, 480, 860, 480], [0, 720, 860, 720],
                                            [2580, 960, 860, 480]])
        #expect(LayoutPreset.mainStack.commands(workspace: "1", windows: [1, 2, 3]) == [.arrange(workspace: "1", .mainStack, windows: [1, 2, 3])])
        #expect(AeroCommand.arrange(workspace: "1", .centred, windows: [4, 5]).arguments == ["arrange", "--workspace", "1", "centred", "4", "5"])
        let size = CGSize(width: 3440, height: 1440)
        #expect(LayoutPreset.mainStack.tree(5, in: size)?.reading == [0, 1, 4, 2, 3])
        let five = [1, 2, 3, 4, 5], built = LayoutPreset.mainStack.reading(of: five, in: size)
        #expect(built == [1, 2, 5, 3, 4])
        #expect(LayoutPreset.openOrder(five, built: built, reading: [1, 2, 5, 3, 4]) == five)
        #expect(LayoutPreset.openOrder(five, built: built, reading: [1, 5, 3, 4]) == [1, 3, 4, 5])
        #expect(LayoutPreset.openOrder(five, built: built, reading: [1, 2, 3, 5, 4]) == [1, 2, 5, 4, 3])
        #expect(LayoutPreset.openOrder([1, 2, 3], built: LayoutPreset.centred.reading(of: [1, 2, 3], in: size), reading: [3, 1, 2, 7]) == [1, 2, 3, 7])
        #expect(LayoutPreset.mainStack.growth(adding: 4, in: size)! == (1, true))
        #expect(LayoutPreset.centred.growth(adding: 2, in: size) == nil)
    }

    @Test("Grid: two side by side, then columns of two, 2×2 for four, the odd one alone; one arrange")
    func grid() {
        #expect(Self.tiles(.grid, 2) == [[0, 0, 1720, 1440], [1720, 0, 1720, 1440]])
        #expect(Self.tiles(.grid, 3) == [[0, 0, 1720, 720], [0, 720, 1720, 720], [1720, 0, 1720, 1440]])
        #expect(Self.tiles(.grid, 4) == [[0, 0, 1720, 720], [0, 720, 1720, 720], [1720, 0, 1720, 720], [1720, 720, 1720, 720]])
        #expect(LayoutPreset.grid.commands(workspace: "1", windows: [1, 2, 3, 4]) == [.arrange(workspace: "1", .grid, windows: [1, 2, 3, 4])])
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
        #expect(LayoutPreset.sideBySide(workspace: "3", windows: [5])
                == [.flatten(workspace: "3"), .setRootLayout(workspace: "3", "h_tiles"), .balanceSizes(workspace: "3")])
        #expect(LayoutPreset.sideBySide(workspace: "3", windows: []).isEmpty)
    }

    /// Cycle layout (workspaces.cycleLayout) and the bar's click walk this order (layouts round 1, Q235): Rows is out of
    /// it, still in the editor; stage after scrolling (ADR 0015). Dwindle and Columns went (Sven, 2026-11-14).
    @Test("The cycle: main + stack, centred main, grid, scrolling, stage, and round again; none or rows start at main + stack")
    func cycle() {
        #expect(LayoutPreset.allCases.map(\.label) == ["Main + stack", "Centred main", "Rows", "Grid", "Scrolling", "Stage"])
        #expect(LayoutPreset.next(after: nil) == .mainStack && LayoutPreset.next(after: .rows) == .mainStack)
        var walked: [LayoutPreset] = []
        var preset: LayoutPreset? = nil
        for _ in 0..<6 { preset = LayoutPreset.next(after: preset); walked.append(preset!) }
        #expect(walked == [.mainStack, .centred, .grid, .scrolling, .stage, .mainStack])
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
                        "7": WorkspaceLayout(preset: .scrolling, auto: true)])
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
        // Columns and Dwindle went (2026-11-14): a stored one reads as Scrolling and Main + stack.
        #expect(try JSONDecoder().decode([LayoutPreset].self, from: Data(#"["columns","dwindle"]"#.utf8)) == [.scrolling, .mainStack])
        #expect(String(decoding: try JSONEncoder().encode(LayoutPreset.scrolling), as: UTF8.self) == #""scrolling""#)
    }

    @Test("Where a release falls in each preset's tiles: main + stack's main and grid side by side, rows top to bottom, grid by pairs")
    func dropOrder() {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(LayoutPreset.mainStack.dropOrder([1, 2], inserting: 9, at: CGPoint(x: 500, y: 10), in: area) == [1, 9, 2])
        #expect(LayoutPreset.rows.dropOrder([1, 2], inserting: 9, at: CGPoint(x: 10, y: 100), in: area) == [9, 1, 2])
        // Grid of three: 1 over 2 on the left, 3 alone on the right; the lower half of 1 goes between 1 and 2.
        #expect(LayoutPreset.grid.dropOrder([1, 2, 3], inserting: 9, at: CGPoint(x: 100, y: 300), in: area) == [1, 9, 2, 3])
        #expect(LayoutPreset.grid.dropOrder([1, 2, 3], inserting: 9, at: CGPoint(x: 1100, y: 100), in: area) == [1, 2, 3, 9])
        #expect(LayoutPreset.mainStack.dropOrder([], inserting: 9, at: .zero, in: area) == [9])
    }
}
