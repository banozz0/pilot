import Testing
import CoreGraphics
import Foundation
@testable import PilotCore

@Suite("Workspace snapshots")
struct SnapshotTests {
    static func window(_ id: Int, _ app: String, _ title: String, layout: String = "h_tiles", workspace: String = "3") -> AeroWindow {
        AeroWindow(id: id, appName: app, bundleId: "com.apple.\(app.lowercased())", pid: Int32(id), workspace: workspace,
                   monitorId: 1, layout: layout, title: title)
    }

    static let three = AeroWorkspace(workspace: "3", rootLayout: "h_tiles")

    static let saved = Date(timeIntervalSince1970: 1_791_100_000)

    @Test("Saving keeps each window's app, title and frame, tiled windows left to right whatever order the tiler lists them in, floating ones after")
    func captureOrdersTiledByPosition() throws {
        let windows = [Self.window(1, "TextEdit", "notes"), Self.window(2, "Finder", "Downloads", layout: "floating"),
                       Self.window(3, "Finder", "Home")]
        let frames: [Int: CGRect] = [1: CGRect(x: 968, y: 33, width: 944, height: 1039),
                                     2: CGRect(x: 400, y: 300, width: 700, height: 500),
                                     3: CGRect(x: 8, y: 33, width: 952, height: 1039)]
        let snapshot = try #require(Snapshot.capture(Self.three, windows: windows, frames: frames, at: Self.saved))
        #expect(snapshot.workspace == "3")
        #expect(snapshot.layout == "h_tiles")
        #expect(snapshot.savedAt == Self.saved)
        #expect(snapshot.windows == [
            Snapshot.Window(bundleId: "com.apple.finder", appName: "Finder", title: "Home", floating: false,
                            frame: CGRect(x: 8, y: 33, width: 952, height: 1039)),
            Snapshot.Window(bundleId: "com.apple.textedit", appName: "TextEdit", title: "notes", floating: false,
                            frame: CGRect(x: 968, y: 33, width: 944, height: 1039)),
            Snapshot.Window(bundleId: "com.apple.finder", appName: "Finder", title: "Downloads", floating: true,
                            frame: CGRect(x: 400, y: 300, width: 700, height: 500)),
        ])
    }

    @Test("A vertical workspace orders its tiled windows top to bottom")
    func captureVertical() throws {
        let windows = [Self.window(1, "TextEdit", "a", layout: "v_tiles"), Self.window(2, "Finder", "b", layout: "v_tiles")]
        let frames: [Int: CGRect] = [1: CGRect(x: 8, y: 560, width: 1904, height: 512), 2: CGRect(x: 8, y: 33, width: 1904, height: 519)]
        let snapshot = try #require(Snapshot.capture(AeroWorkspace(workspace: "3", rootLayout: "v_tiles"), windows: windows, frames: frames, at: Self.saved))
        #expect(snapshot.layout == "v_tiles")
        #expect(snapshot.windows.map(\.title) == ["b", "a"])
    }

    @Test("A window Pilot cannot read a frame for is left out, and a workspace with no readable window saves nothing")
    func captureSkipsUnreadable() throws {
        let windows = [Self.window(1, "TextEdit", "a"), Self.window(2, "Finder", "b")]
        let snapshot = try #require(Snapshot.capture(Self.three, windows: windows, frames: [2: CGRect(x: 0, y: 0, width: 10, height: 10)], at: Self.saved))
        #expect(snapshot.windows.map(\.title) == ["b"])
        #expect(Snapshot.capture(Self.three, windows: windows, frames: [:], at: Self.saved) == nil)
        #expect(Snapshot.capture(Self.three, windows: [], frames: [:], at: Self.saved) == nil)
    }

    @Test("The focused workspace and its root layout come from one list-workspaces call")
    func focusedWorkspace() throws {
        #expect(AeroCommand.focusedWorkspace.arguments
                == ["list-workspaces", "--focused", "--json", "--format", "%{workspace} %{workspace-root-container-layout}"])
        // Recorded from that call on 0.21.3-Beta, 2026-10-04.
        let json = #"[{"workspace" : "1", "workspace-root-container-layout" : "h_tiles"}]"#
        #expect(try AeroWorkspace.parse(json) == [AeroWorkspace(workspace: "1", rootLayout: "h_tiles")])
    }

    // MARK: restore planning

    static func saved(_ app: String, _ title: String, floating: Bool = false, _ frame: CGRect) -> Snapshot.Window {
        Snapshot.Window(bundleId: "com.apple.\(app.lowercased())", appName: app, title: title, floating: floating, frame: frame)
    }

    /// Finder "Home" and TextEdit "notes" tiled 952 and 944 wide, Finder "Downloads" floating.
    static let snapshot = Snapshot(workspace: "3", layout: "h_tiles", savedAt: saved, windows: [
        saved("Finder", "Home", CGRect(x: 8, y: 33, width: 952, height: 1039)),
        saved("TextEdit", "notes", CGRect(x: 968, y: 33, width: 944, height: 1039)),
        saved("Finder", "Downloads", floating: true, CGRect(x: 400, y: 300, width: 700, height: 500)),
    ])

    @Test("Restore reopens each saved app that is not running, once, in saved order")
    func missingApps() {
        #expect(SnapshotRestore.missingApps(Self.snapshot, running: ["com.apple.finder"]) == ["com.apple.textedit"])
        #expect(SnapshotRestore.missingApps(Self.snapshot, running: []) == ["com.apple.finder", "com.apple.textedit"])
        #expect(SnapshotRestore.missingApps(Self.snapshot, running: ["com.apple.finder", "com.apple.textedit"]).isEmpty)
    }

    @Test("Windows match by app and title first, then by order among the app's windows left over; a saved window with none left stays unmatched")
    func matching() {
        let current = [Self.window(20, "Finder", "Documents", workspace: "1"), Self.window(21, "Finder", "Downloads", workspace: "1")]
        let plan = SnapshotRestore(Self.snapshot, current: current)
        #expect(plan.matches.map(\.window.id) == [20, 21])
        #expect(plan.matches.map(\.saved.title) == ["Home", "Downloads"])
        #expect(plan.unmatched.map(\.title) == ["notes"])
    }

    @Test("Each matched window moves to the snapshot's workspace and floats or tiles as saved; then the tree is flattened and the root layout set")
    func placeCommands() {
        let current = [Self.window(20, "Finder", "Home", layout: "floating", workspace: "1"),
                       Self.window(21, "TextEdit", "notes", workspace: "3"),
                       Self.window(22, "Finder", "Downloads", workspace: "3")]
        #expect(SnapshotRestore(Self.snapshot, current: current).placeCommands == [
            .moveWindow(id: 20, toWorkspace: "3"), .setFloating(id: 20, false),
            .setFloating(id: 22, true),
            .flatten(workspace: "3"), .setRootLayout(workspace: "3", "h_tiles"),
        ])
    }

    @Test("Tiled windows are put in saved order with the fewest moves, windows the snapshot does not know pushed to the end")
    func orderCommands() {
        let current = [Self.window(20, "Finder", "Home"), Self.window(21, "TextEdit", "notes")]
        let plan = SnapshotRestore(Self.snapshot, current: current)
        // On screen now: TextEdit, an unknown window 30, Finder.
        // Finder left twice: past 30, then past TextEdit, which is then second already.
        #expect(plan.orderCommands(current: [21, 30, 20]).commands == [.move(id: 20, .left), .move(id: 20, .left)])
        #expect(plan.orderCommands(current: [30, 21, 20]).commands == [.move(id: 20, .left), .move(id: 20, .left), .move(id: 21, .left)])
        #expect(plan.orderCommands(current: [20, 21, 30]).commands.isEmpty)
        let vertical = Snapshot(workspace: "3", layout: "v_tiles", savedAt: Self.saved, windows: Array(Self.snapshot.windows.prefix(2)))
        #expect(SnapshotRestore(vertical, current: current).orderCommands(current: [21, 20]).commands == [.move(id: 20, .up)])
    }

    /// AeroSpace 0.21.3-Beta's flat tiles, transcribed from its source (layoutRecursive.swift layoutTiles,
    /// ResizeCommand.swift run, ResizeCmdArgs.swift, MoveCommand with --boundaries-action stop): each tile owns a weight
    /// (its slot); a window is its slot less the inner gap, half of it at an outer edge; `resize` reads its last
    /// argument as "+N" add, "-N" subtract or "N" set, and spreads the slot's change evenly over every other tile; `move`
    /// swaps a window with its neighbour. Commands are read from their CLI arguments, as the tiler sees them.
    struct AeroModel {
        var order: [Int]
        var weights: [Int: CGFloat]
        var gap: CGFloat = 10
        var vertical = false
        let origin: CGFloat = 8, across = CGRect(x: 8, y: 33, width: 1904, height: 1039)

        func frames() -> [Int: CGRect] {
            var point = origin, out: [Int: CGRect] = [:]
            for (i, id) in order.enumerated() {
                let w = weights[id]!
                let share = gap - (i == 0 ? gap / 2 : 0) - (i == order.count - 1 ? gap / 2 : 0)
                let start = i == 0 ? point : point + gap / 2
                out[id] = vertical ? CGRect(x: across.minX, y: start, width: across.width, height: w - share)
                                   : CGRect(x: start, y: across.minY, width: w - share, height: across.height)
                point += w
            }
            return out
        }

        mutating func apply(_ commands: [AeroCommand]) {
            for command in commands {
                let args = command.arguments
                let id = Int(args[args.firstIndex(of: "--window-id")! + 1])!
                switch args[0] {
                case "resize":
                    let unit = args.last!, number = CGFloat(Int(unit.trimmingCharacters(in: ["+", "-"]))!)
                    let diff = unit.hasPrefix("+") ? number : unit.hasPrefix("-") ? -number : number - weights[id]!
                    for other in order where other != id { weights[other]! -= diff / CGFloat(order.count - 1) }
                    weights[id]! += diff
                case "move":
                    let at = order.firstIndex(of: id)!
                    if at > 0 { order.swapAt(at, at - 1) }
                default: Issue.record("unexpected \(args)")
                }
            }
        }
    }

    /// A snapshot of three tiled windows laid out by the model at slots 500, 900 and 504, gap 10.
    static func threeTiles(vertical: Bool = false) -> Snapshot {
        let saved = AeroModel(order: [1, 2, 3], weights: [1: 500, 2: 900, 3: 504], vertical: vertical).frames()
        return Snapshot(workspace: "3", layout: vertical ? "v_tiles" : "h_tiles", savedAt: Self.saved, windows: [
            Self.saved("Finder", "Home", saved[1]!), Self.saved("TextEdit", "notes", saved[2]!), Self.saved("Ghostty", "zsh", saved[3]!),
        ])
    }

    static let threeCurrent = [Self.window(20, "Finder", "Home"), Self.window(21, "TextEdit", "notes"), Self.window(22, "Ghostty", "zsh")]

    /// Restores into the model and returns each saved window's frame afterwards, in saved order.
    static func restored(_ snapshot: Snapshot, into model: inout AeroModel, windows: [AeroWindow] = threeCurrent) -> [CGRect] {
        let plan = SnapshotRestore(snapshot, current: windows)
        model.apply(plan.arrangeCommands(windows: windows, frames: model.frames()))
        let after = model.frames()
        return plan.matches.map { after[$0.window.id]! }
    }

    @Test("Three tiles come back in saved order at their saved widths within 2 points, though each resize spreads over the others and the gap is inside the slot")
    func arrangeThreeTiles() {
        let snapshot = Self.threeTiles()
        var model = AeroModel(order: [22, 20, 21], weights: [20: 634, 21: 635, 22: 635])
        let frames = Self.restored(snapshot, into: &model)
        #expect(model.order == [20, 21, 22])
        for (saved, now) in zip(snapshot.windows, frames) { #expect(abs(saved.frame.width - now.width) <= 2, "\(saved.title)") }
    }

    @Test("A tile that shrinks far is still reached: from equal thirds to 300, 300 and 1304, no resize is read as the wrong sign")
    func arrangeFarFromStart() {
        let saved = AeroModel(order: [1, 2, 3], weights: [1: 300, 2: 300, 3: 1304]).frames()
        let snapshot = Snapshot(workspace: "3", layout: "h_tiles", savedAt: Self.saved, windows: [
            Self.saved("Finder", "Home", saved[1]!), Self.saved("TextEdit", "notes", saved[2]!), Self.saved("Ghostty", "zsh", saved[3]!),
        ])
        var model = AeroModel(order: [20, 21, 22], weights: [20: 634, 21: 635, 22: 635])
        let frames = Self.restored(snapshot, into: &model)
        for (saved, now) in zip(snapshot.windows, frames) { #expect(abs(saved.frame.width - now.width) <= 2, "\(saved.title)") }
    }

    @Test("A matched tile not on screen is left out of the sizing, and a saved tile with no window still counts in the others' proportions")
    func arrangeWithHiddenAndMissingTiles() {
        // Saved at 400, 900, 604; TextEdit (the middle one) is not on screen now, so Finder and Ghostty share the
        // whole width 400 to 604: Finder 1904 * 400 / 1004, about 759.
        let saved = AeroModel(order: [1, 2, 3], weights: [1: 400, 2: 900, 3: 604]).frames()
        let snapshot = Snapshot(workspace: "3", layout: "h_tiles", savedAt: Self.saved, windows: [
            Self.saved("Finder", "Home", saved[1]!), Self.saved("TextEdit", "notes", saved[2]!), Self.saved("Ghostty", "zsh", saved[3]!),
        ])
        var model = AeroModel(order: [22, 20], weights: [20: 952, 22: 952])
        let plan = SnapshotRestore(snapshot, current: Self.threeCurrent)
        model.apply(plan.arrangeCommands(windows: Self.threeCurrent, frames: model.frames()))
        #expect(model.order == [20, 22])
        #expect(abs(model.weights[20]! - 759) <= 2)
        // The same with TextEdit not found at all.
        var unmatched = AeroModel(order: [22, 20], weights: [20: 952, 22: 952])
        let two = [Self.threeCurrent[0], Self.threeCurrent[2]]
        unmatched.apply(SnapshotRestore(snapshot, current: two).arrangeCommands(windows: two, frames: unmatched.frames()))
        #expect(abs(unmatched.weights[20]! - 759) <= 2)
    }

    @Test("Two tiles with a gap come back within 2 points; a vertical workspace restores heights")
    func arrangeTwoTilesAndVertical() {
        let saved = AeroModel(order: [1, 2], weights: [1: 1300, 2: 604]).frames()
        let two = Snapshot(workspace: "3", layout: "h_tiles", savedAt: Self.saved,
                           windows: [Self.saved("Finder", "Home", saved[1]!), Self.saved("TextEdit", "notes", saved[2]!)])
        var model = AeroModel(order: [20, 21], weights: [20: 952, 21: 952])
        let frames = Self.restored(two, into: &model, windows: Array(Self.threeCurrent.prefix(2)))
        for (saved, now) in zip(two.windows, frames) { #expect(abs(saved.frame.width - now.width) <= 2, "\(saved.title)") }

        let vertical = Self.threeTiles(vertical: true)
        var stack = AeroModel(order: [21, 22, 20], weights: [20: 600, 21: 700, 22: 604], vertical: true)
        let heights = Self.restored(vertical, into: &stack)
        #expect(stack.order == [20, 21, 22])
        for (saved, now) in zip(vertical.windows, heights) { #expect(abs(saved.frame.height - now.height) <= 2, "\(saved.title)") }
    }

    @Test("A tile the snapshot does not know keeps its width and goes last; the known ones share the rest in saved proportion")
    func arrangeWithUnknownTile() {
        // Saved as two tiles at slots 680 and 1224, 5 to 9.
        let saved = AeroModel(order: [1, 2], weights: [1: 680, 2: 1224]).frames()
        let snapshot = Snapshot(workspace: "3", layout: "h_tiles", savedAt: Self.saved,
                                windows: [Self.saved("Finder", "Home", saved[1]!), Self.saved("TextEdit", "notes", saved[2]!)])
        let windows = Array(Self.threeCurrent.prefix(2)) + [Self.window(30, "Zen", "news")]
        var model = AeroModel(order: [30, 21, 20], weights: [20: 600, 21: 700, 30: 604])
        _ = Self.restored(snapshot, into: &model, windows: windows)
        #expect(model.order == [20, 21, 30])
        #expect(abs(model.weights[30]! - 604) <= 2)
        // 5 to 9 of the 1300 left: 464 and 836.
        #expect(abs(model.weights[20]! - 464) <= 2 && abs(model.weights[21]! - 836) <= 2)
    }

    /// Scrolling layout spec: a column off the strip waits in the hide corner, so frames cannot give the order; the
    /// tiler lists the windows in strip order, and each column's width is its frame's, which the corner keeps.
    @Test("A scrolling workspace saves the tiler's order, not the frames', and each column's width")
    func captureScrolling() throws {
        let windows = [Self.window(1, "Finder", "Home", layout: "h_scrolling"), Self.window(2, "TextEdit", "notes", layout: "h_scrolling"),
                       Self.window(3, "Ghostty", "zsh", layout: "h_scrolling")]
        // Column 1 scrolled off toward the portrait screen, hidden in the bottom-right corner; 2 and 3 in view.
        let frames: [Int: CGRect] = [1: CGRect(x: 3439, y: 1342, width: 1133, height: 1419),
                                     2: CGRect(x: 10, y: 10, width: 1706, height: 1419),
                                     3: CGRect(x: 1726, y: 10, width: 1133, height: 1419)]
        let snapshot = try #require(Snapshot.capture(AeroWorkspace(workspace: "3", rootLayout: "h_scrolling"), windows: windows, frames: frames, at: Self.saved))
        #expect(snapshot.layout == "h_scrolling")
        #expect(snapshot.windows.map(\.title) == ["Home", "notes", "zsh"])
        #expect(snapshot.windows.map(\.frame.width) == [1133, 1706, 1133])
    }

    @Test("A scrolling workspace is restored as scrolling, ordered as the tiler lists it, each column at its saved width, no tile resizes")
    func restoreScrolling() {
        let strip = Snapshot(workspace: "3", layout: "h_scrolling", savedAt: Self.saved, windows: Self.threeTiles().windows)
        let plan = SnapshotRestore(strip, current: Self.threeCurrent)
        #expect(plan.placeCommands.suffix(2) == [.flatten(workspace: "3"), .setRootLayout(workspace: "3", "h_scrolling")])
        // Listed 22, 20, 21 whatever the frames say: Finder and TextEdit each move left once, past Ghostty.
        let listed = [Self.threeCurrent[2], Self.threeCurrent[0], Self.threeCurrent[1]]
        let frames = AeroModel(order: [20, 21, 22], weights: [20: 634, 21: 635, 22: 635]).frames()
        let widths = strip.windows.map { Int($0.frame.width.rounded()) }
        #expect(plan.arrangeCommands(windows: listed, frames: frames) == [.move(id: 20, .left), .move(id: 21, .left),
                .setColumnWidth(id: 20, points: widths[0]), .setColumnWidth(id: 21, points: widths[1]), .setColumnWidth(id: 22, points: widths[2])])
    }

    @Test("A snapshot saved with the layout scrolling replaced comes back as scrolling")
    func storedAccordionLoadsAsScrolling() throws {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"3":{"workspace":"3","layout":"v_accordion","savedAt":"2026-10-01T10:00:00Z","windows":[]},"#
                  + #""4":{"workspace":"4","layout":"v_tiles","savedAt":"2026-10-01T10:00:00Z","windows":[]},"#
                  + #""5":{"workspace":"5","layout":"h_accordion","savedAt":"2026-10-01T10:00:00Z","windows":[]}}"#).utf8).write(to: store.url)
        let loaded = try store.load()
        #expect(loaded["3"]?.layout == "h_scrolling" && loaded["5"]?.layout == "h_scrolling")
        #expect(loaded["4"]?.layout == "v_tiles")
    }

    @Test("Matching by order prefers a window already on the snapshot's workspace over one elsewhere")
    func matchingPrefersTargetWorkspace() {
        let current = [Self.window(40, "Finder", "Documents", workspace: "1"), Self.window(41, "Finder", "Desktop", workspace: "3")]
        let one = Snapshot(workspace: "3", layout: "h_tiles", savedAt: Self.saved, windows: [Self.snapshot.windows[0]])
        #expect(SnapshotRestore(one, current: current).matches.map(\.window.id) == [41])
    }

    @Test("Floating windows go back to their saved frame")
    func floatingFrames() {
        let current = [Self.window(22, "Finder", "Downloads", layout: "floating")]
        let frames = SnapshotRestore(Self.snapshot, current: current).floatingFrames
        #expect(frames.map(\.id) == [22])
        #expect(frames.map(\.frame) == [CGRect(x: 400, y: 300, width: 700, height: 500)])
    }

    @Test("Restore's commands become the tiler CLI's arguments; a move stops at the workspace's edge instead of nesting")
    func restoreArguments() {
        #expect(AeroCommand.flatten(workspace: "3").arguments == ["flatten-workspace-tree", "--workspace", "3"])
        #expect(AeroCommand.setRootLayout(workspace: "3", "v_tiles").arguments == ["layout", "--workspace", "3", "--root", "v_tiles"])
        #expect(AeroCommand.move(id: 9521, .left).arguments == ["move", "--window-id", "9521", "--boundaries-action", "stop", "left"])
    }

    // MARK: the store

    static func tempStore() -> SnapshotStore {
        SnapshotStore(url: FileManager.default.temporaryDirectory.appending(path: "pilot-snapshots-\(UUID().uuidString)/snapshots.json"))
    }

    @Test("One snapshot per workspace, kept as JSON across a reload; saving again replaces it, and delete removes it")
    func store() throws {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        #expect(try store.load().isEmpty)
        try store.save(Self.snapshot)
        let other = Snapshot(workspace: "5", layout: "h_scrolling", savedAt: Self.saved, windows: [Self.snapshot.windows[0]])
        try store.save(other)
        let again = Snapshot(workspace: "3", layout: "h_tiles", savedAt: Self.saved.addingTimeInterval(60), windows: [Self.snapshot.windows[1]])
        try store.save(again)
        #expect(try SnapshotStore(url: store.url).load() == ["3": again, "5": other])
        try store.delete(workspace: "5")
        #expect(try store.load() == ["3": again])
    }

    @Test("A file Pilot cannot read is never overwritten by the next save")
    func storeKeepsUnreadableFile() throws {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.save(Self.snapshot) }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "not json")
    }

    // MARK: the keys

    @Test("The bind store seeds Hyper+Ctrl+S as save and Hyper+Ctrl+Shift+S as restore, and a press of each reaches its action")
    @MainActor func keys() throws {
        var ran: [String] = []
        var registry = ActionRegistry()
        try Snapshot.register(into: &registry, save: { ran.append("save") }, restore: { ran.append("restore") })
        let store = BindStore(defaults: registry.defaults)
        #expect(store.action(for: Key("s", .ctrl)) == "workspaces.saveSnapshot")
        #expect(store.action(for: Key("s", [.ctrl, .shift])) == "workspaces.restoreSnapshot")

        // Caps Lock held, then S with Ctrl, then S with Ctrl and Shift, run as the engine does: trigger → store → action.
        var layer = HyperLayer(layerKey: .capsLock)
        let bound = { (key: Key) in store.action(for: key) != nil }
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound)
        for flags in [KeyEvent.ctrlMask, KeyEvent.ctrlMask | KeyEvent.shiftMask] {
            guard case .run(let key, _) = layer.handle(.init(kind: .keyDown, keyCode: Key("s").keyCode, flags: flags), isBound: bound),
                  let id = store.action(for: key) else { Issue.record("no bind for flags \(flags)"); continue }
            registry.actions[id]?.run()
        }
        #expect(ran == ["save", "restore"])
    }
}
