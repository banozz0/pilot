import CoreGraphics
import Foundation

/// A workspace snapshot (stories 69 and 71): the one saved record per workspace of its windows. The tiler gives no
/// sizes, positions or split nesting (spike test 8), so Pilot reads the frames itself; nested splits come back flat.
/// Every frame is in Accessibility coordinates. A scrolling workspace's order is the tiler's, since a column off the
/// strip waits in the hide corner; each column's width is its frame's, which the corner keeps.
public struct Snapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let bundleId: String
        public let appName: String
        public let title: String
        public let floating: Bool
        public let frame: CGRect

        public init(bundleId: String, appName: String, title: String, floating: Bool, frame: CGRect) {
            self.bundleId = bundleId; self.appName = appName; self.title = title; self.floating = floating; self.frame = frame
        }
    }

    public let workspace: String
    /// The root container's layout: h_tiles, v_tiles, h_scrolling or h_stage.
    public let layout: String
    public let savedAt: Date
    /// Tiled windows in their layout order (left to right, or top to bottom on a vertical workspace), then floating ones.
    public let windows: [Window]

    public var isVertical: Bool { layout.hasPrefix("v_") }
    public var isScrolling: Bool { layout == "h_scrolling" }

    /// Nil when no window on the workspace has a frame Pilot could read. `windows` come in the tiler's order.
    public static func capture(_ workspace: AeroWorkspace, windows: [AeroWindow], frames: [Int: CGRect], at date: Date) -> Snapshot? {
        let read = windows.compactMap { w in
            frames[w.id].map { Window(bundleId: w.bundleId, appName: w.appName, title: w.title, floating: w.isFloating, frame: $0) }
        }
        guard !read.isEmpty else { return nil }
        let unsorted = Snapshot(workspace: workspace.workspace, layout: workspace.rootLayout, savedAt: date, windows: read)
        let tiled = read.filter { !$0.floating }
        return Snapshot(workspace: workspace.workspace, layout: workspace.rootLayout, savedAt: date,
                        windows: (unsorted.isScrolling ? tiled : tiled.sorted { unsorted.before($0.frame, $1.frame) }) + read.filter(\.floating))
    }

    /// Layout order: left to right, or top to bottom on a vertical workspace.
    func before(_ a: CGRect, _ b: CGRect) -> Bool { TileResize.before(a, b, vertical: isVertical) }

    /// The slots tiles in layout order fill along the workspace's axis, which is what `resize` sets: the tiler takes the
    /// inner gap out of each slot, half of it at an outer edge, so a slot ends halfway across the gap between windows.
    func slots(_ frames: [CGRect]) -> [CGFloat] { TileResize.slots(frames, vertical: isVertical) }
}

extension Snapshot {
    /// Scrolling replaced accordion (2026-10-12): an accordion saved before comes back as scrolling.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let layout = try c.decode(String.self, forKey: .layout)
        self.init(workspace: try c.decode(String.self, forKey: .workspace), layout: layout.hasSuffix("_accordion") ? "h_scrolling" : layout,
                  savedAt: try c.decode(Date.self, forKey: .savedAt), windows: try c.decode([Window].self, forKey: .windows))
    }
}

/// Planning a snapshot's restore. Pilot runs it in steps, reading the tiler again between them: reopen the missing
/// apps, match windows, place them (`placeCommands`), read where the tiles landed, order and size them
/// (`arrangeCommands`), then set floating frames through Accessibility.
public struct SnapshotRestore: Sendable {
    public typealias Match = (saved: Snapshot.Window, window: AeroWindow)

    public let snapshot: Snapshot
    /// Saved windows with the current window each came back as, in saved order.
    public let matches: [Match]
    /// Saved windows with no window left to match: their app opened none, or fewer than were saved.
    public let unmatched: [Snapshot.Window]

    /// Matches by app and title first, then by order among the app's windows left over, windows already on the
    /// snapshot's workspace first.
    public init(_ snapshot: Snapshot, current: [AeroWindow]) {
        self.snapshot = snapshot
        var free = current.filter { $0.workspace == snapshot.workspace } + current.filter { $0.workspace != snapshot.workspace }
        var found = [AeroWindow?](repeating: nil, count: snapshot.windows.count)
        func claim(_ same: (Snapshot.Window, AeroWindow) -> Bool) {
            for (i, saved) in snapshot.windows.enumerated() where found[i] == nil {
                if let at = free.firstIndex(where: { same(saved, $0) }) { found[i] = free.remove(at: at) }
            }
        }
        claim { $0.bundleId == $1.bundleId && $0.title == $1.title }
        claim { $0.bundleId == $1.bundleId }
        matches = zip(snapshot.windows, found).compactMap { saved, window in window.map { (saved, $0) } }
        unmatched = zip(snapshot.windows, found).filter { $1 == nil }.map(\.0)
    }

    /// The saved apps that are not running, each once, in saved order.
    public static func missingApps(_ snapshot: Snapshot, running: Set<String>) -> [String] {
        var seen = running
        return snapshot.windows.map(\.bundleId).filter { seen.insert($0).inserted }
    }

    /// Each matched window onto the workspace, floating or tiled as saved, then the tree flattened and the root set to
    /// the saved layout.
    public var placeCommands: [AeroCommand] {
        matches.flatMap { saved, window in
            (window.workspace == snapshot.workspace ? [] : [.moveWindow(id: window.id, toWorkspace: snapshot.workspace)])
                + (window.isFloating == saved.floating ? [] : [.setFloating(id: window.id, saved.floating)])
        } + [.flatten(workspace: snapshot.workspace), .setRootLayout(workspace: snapshot.workspace, snapshot.layout)]
    }

    /// Orders and sizes the tiles, given the workspace's windows once placed, in the tiler's order, and their frames on
    /// screen now. A scrolling workspace is ordered as the tiler lists it, and each column set back to its saved width.
    public func arrangeCommands(windows: [AeroWindow], frames: [Int: CGRect]) -> [AeroCommand] {
        let tiled = windows.filter { !$0.isFloating }
        if snapshot.isScrolling {
            return orderCommands(current: tiled.map(\.id)).commands
                + self.tiled.map { .setColumnWidth(id: $0.window.id, points: Int($0.saved.frame.width.rounded())) }
        }
        let tiles = tiled.compactMap { w in frames[w.id].map { (id: w.id, frame: $0) } }.sorted { snapshot.before($0.frame, $1.frame) }
        let (moves, order) = orderCommands(current: tiles.map(\.id))
        let weights = Dictionary(uniqueKeysWithValues: zip(tiles.map(\.id), snapshot.slots(tiles.map(\.frame))))
        return moves + sizeCommands(order: order, weights: weights)
    }

    private var tiled: [Match] { matches.filter { !$0.saved.floating } }

    /// Moves that put the matched tiles first, in saved order, given the tiles' ids in their order on screen now, and the
    /// order they leave. Each move swaps a window with its neighbour, so the count is the fewest that sorts them;
    /// unknown tiles end up last.
    func orderCommands(current: [Int]) -> (commands: [AeroCommand], order: [Int]) {
        let toward: Direction = snapshot.isVertical ? .up : .left
        var order = current
        var commands: [AeroCommand] = []
        for (slot, id) in tiled.map(\.window.id).enumerated() {
            guard let at = order.firstIndex(of: id), at > slot else { continue }
            commands += Array(repeating: .move(id: id, toward), count: at - slot)
            order.remove(at: at)
            order.insert(id, at: slot)
        }
        return (commands, order)
    }

    /// Resizes that bring each matched tile back to its saved slot, given the tiles in order and their slots now. Saved
    /// slots come from every saved tile, so one with no window now still counts in the others' proportions; an unknown
    /// tile keeps its slot and the matched ones on screen share the rest in saved proportion (TileResize solves the resizes).
    func sizeCommands(order: [Int], weights: [Int: CGFloat]) -> [AeroCommand] {
        let n = order.count
        let savedTiles = snapshot.windows.filter { !$0.floating }
        let slots = snapshot.slots(savedTiles.map(\.frame))
        var saved: [Int: CGFloat] = [:]
        for (was, window) in tiled where order.contains(window.id) { savedTiles.firstIndex(of: was).map { saved[window.id] = slots[$0] } }
        guard n > 1, !saved.isEmpty else { return [] }
        let free = order.filter { saved[$0] == nil }.reduce(0) { $0 + weights[$1]! }
        let total = order.reduce(0) { $0 + weights[$1]! }
        let scale = (total - free) / saved.values.reduce(0, +)
        return TileResize.commands(order: order, start: order.map { weights[$0]! },
                                   target: order.map { saved[$0].map { $0 * scale } ?? weights[$0]! },
                                   axis: snapshot.isVertical ? .height : .width)
    }

    /// Floating windows and the frame each goes back to.
    public var floatingFrames: [(id: Int, frame: CGRect)] {
        matches.filter(\.saved.floating).map { ($0.window.id, $0.saved.frame) }
    }
}

/// The snapshots on disk: one JSON file, one snapshot per workspace; saving a workspace again replaces its snapshot.
public struct SnapshotStore: Sendable {
    /// ~/Library/Application Support/Pilot/snapshots.json
    public static let standard = SnapshotStore(url: PilotFolder.support.appending(path: "snapshots.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// Snapshots by workspace; empty when nothing was saved yet. A file that does not decode throws, so no save wipes it.
    public func load() throws -> [String: Snapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try Self.decoder.decode([String: Snapshot].self, from: Data(contentsOf: url))
    }

    public func save(_ snapshot: Snapshot) throws {
        var all = try load()
        all[snapshot.workspace] = snapshot
        try write(all)
    }

    /// Every workspace's snapshot under its new number (Sven's Q233): the deleted workspace's goes.
    @discardableResult public func renumber(_ r: WorkspaceRenumber) throws -> [String: Snapshot] {
        let all = r.rekeyed(try load()).reduce(into: [String: Snapshot]()) { all, entry in
            let old = entry.value
            all[entry.key] = Snapshot(workspace: entry.key, layout: old.layout, savedAt: old.savedAt, windows: old.windows)
        }
        try write(all)
        return all
    }

    public func delete(workspace: String) throws {
        var all = try load()
        guard all.removeValue(forKey: workspace) != nil else { return }
        try write(all)
    }

    private func write(_ all: [String: Snapshot]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(all).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Snapshot {
    /// The two snapshot actions (story 69): Hyper+Ctrl+S saves the focused workspace, Hyper+Shift+Ctrl+S restores it.
    /// Their default keys seed the bind store.
    public static func register(into registry: inout ActionRegistry, save: @escaping @Sendable @MainActor () -> Void,
                                restore: @escaping @Sendable @MainActor () -> Void) throws(ActionRegistry.RegistrationError) {
        try registry.register(Action(id: "workspaces.saveSnapshot", label: "Save workspace snapshot", module: .workspaces,
                                     defaultKey: Key("s", .ctrl), run: save))
        try registry.register(Action(id: "workspaces.restoreSnapshot", label: "Restore workspace snapshot", module: .workspaces,
                                     defaultKey: Key("s", [.ctrl, .shift]), run: restore))
    }
}
