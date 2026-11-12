import CoreGraphics
import Foundation

/// A workspace preset (story 108, card agent-bo-95422778): the apps a workspace holds, in order, laid out as a ready
/// layout preset or at the user's own size per app. Switching to a workspace that has one opens what is missing, pulls
/// the apps' running windows in and lays them out (WorkspacePresetApply).
public struct WorkspacePreset: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var bundleId: String
        public var name: String
        /// The app's share of the workspace's width, in percent, under own sizes; a ready layout ignores it.
        public var percent: Int
        /// Opened once per login session and moved to its workspace (WorkspaceLoginOpen, card agent-bo-95422980).
        public var atLogin = false

        public init(bundleId: String, name: String, percent: Int) { self.bundleId = bundleId; self.name = name; self.percent = percent }

        /// A preset saved before At login existed reads with it off.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleId = try c.decode(String.self, forKey: .bundleId)
            name = try c.decode(String.self, forKey: .name)
            percent = try c.decode(Int.self, forKey: .percent)
            atLogin = try c.decodeIfPresent(Bool.self, forKey: .atLogin) ?? false
        }
    }

    public var name: String
    public var apps: [App]
    /// A ready layout, or nil for own sizes: the apps side by side, left to right, each at its percent.
    public var layout: LayoutPreset?
    /// A switch here opens the apps that have no window yet; off, it only pulls running windows in and lays them out.
    public var openMissing = true

    public init(name: String, apps: [App], layout: LayoutPreset?) { self.name = name; self.apps = apps; self.layout = layout }

    /// The name a workspace's preset is saved under while it has none of its own: "Workspace 3".
    public static func unnamed(_ workspace: String) -> String { "Workspace \(workspace)" }

    /// Blank, or "Workspace" and a number: no name of its own, so the page shows the workspace's number instead.
    public static func isUnnamed(_ name: String) -> Bool {
        let words = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
        return words.isEmpty || (words.count == 2 && words[0] == "Workspace" && Int(words[1]) != nil)
    }

    /// A preset saved before open missing existed reads with it on, as it behaved.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decode([App].self, forKey: .apps)
        layout = try c.decodeIfPresent(LayoutPreset.self, forKey: .layout)
        openMissing = try c.decodeIfPresent(Bool.self, forKey: .openMissing) ?? true
    }
}

/// The presets on disk: every saved preset by name, and the one each workspace takes.
public struct WorkspacePresetStore: Sendable {
    public struct Contents: Codable, Equatable, Sendable {
        public var presets: [String: WorkspacePreset] = [:]
        /// Workspace name to preset name.
        public var workspaces: [String: String] = [:]

        public init() {}

        public func preset(for workspace: String) -> WorkspacePreset? { workspaces[workspace].flatMap { presets[$0] } }

        /// The name Sven gave the workspace, nil while it has none (Sven 2026-10-17: a named workspace shows its name alone).
        public func name(for workspace: String) -> String? {
            preset(for: workspace).map(\.name).flatMap { WorkspacePreset.isUnnamed($0) ? nil : $0 }
        }

        /// Each workspace's preset under its new number (Sven's Q233): a named preset follows its workspace; an unnamed one
        /// ("Workspace 4") takes the new number's name, so a workspace added later never saves over it; the deleted
        /// workspace's named preset stays saved to reuse, unnamed ones left over go.
        public func renumbered(_ r: WorkspaceRenumber) -> Contents {
            var next = Contents()
            next.presets = presets.filter { !WorkspacePreset.isUnnamed($0.key) }
            for (workspace, name) in r.rekeyed(workspaces) {
                guard var preset = presets[name] else { continue }
                if WorkspacePreset.isUnnamed(name) { preset.name = WorkspacePreset.unnamed(workspace) }
                next.assign(preset, to: workspace)
            }
            return next
        }

        /// What the Workspaces page calls a workspace: its name, else "Workspace 3".
        public func title(for workspace: String) -> String { name(for: workspace) ?? WorkspacePreset.unnamed(workspace) }

        /// Saves `preset` under its name, replacing one of that name, and gives it to `workspace`.
        public mutating func assign(_ preset: WorkspacePreset, to workspace: String) {
            presets[preset.name] = preset
            workspaces[workspace] = preset.name
        }

        /// The workspace keeps no preset; the preset stays saved to reuse.
        public mutating func unassign(_ workspace: String) { workspaces[workspace] = nil }

        /// Every workspace that takes the preset named `name`, in name order.
        public func workspaces(using name: String) -> [String] { workspaces.filter { $0.value == name }.map(\.key).sorted() }
    }

    /// ~/Library/Application Support/Pilot/workspace-presets.json
    public static let standard = WorkspacePresetStore(url: PilotFolder.support.appending(path: "workspace-presets.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// Empty when nothing was saved yet. A file that does not decode throws, so no save wipes it.
    public func load() throws -> Contents { try JSONFile(url: url).load(or: Contents()) }

    public func save(_ contents: Contents) throws { try JSONFile(url: url).save(contents) }
}

/// The workspace editor's working copy (card agent-bo-95422779, popup card agent-bo-95422980): every change saves at
/// once (`autosaved`); `pilot add workspace-presets` saves only once `problem` is nil.
public struct WorkspacePresetDraft: Equatable, Sendable {
    public var name: String
    public private(set) var apps: [WorkspacePreset.App]
    /// A ready layout, or nil for own sizes.
    public var layout: LayoutPreset?
    public var openMissing: Bool
    /// The workspace's auto as the editor shows it: Keep this layout as windows come and go.
    public var keepLayout: Bool

    /// A saved preset as it was, or a new one named after the workspace, empty, at own sizes; Keep this layout starts
    /// from the workspace's layout row.
    public init(_ preset: WorkspacePreset?, workspace: String, row: WorkspaceLayout? = nil) {
        name = preset?.name ?? "Workspace \(workspace)"
        apps = preset?.apps ?? []
        layout = preset?.layout
        openMissing = preset?.openMissing ?? true
        keepLayout = row?.auto ?? true
    }

    /// What saving gives the workspace's auto: own sizes are always off, since a rebuild would undo the sizes.
    public var keepsLayout: Bool { keepLayout && layout != nil }

    public var total: Int { apps.reduce(0) { $0 + $1.percent } }

    public func contains(_ bundleId: String) -> Bool { apps.contains { $0.bundleId == bundleId } }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Why Save is refused, in the words the editor shows; nil when the draft saves.
    public var problem: String? {
        if trimmedName.isEmpty { return "Name the preset" }
        if apps.isEmpty { return "Add at least one app" }
        return sizesProblem
    }

    /// Own sizes that do not add up to 100, the one draft an autosave refuses; nil with no app, or under a ready layout.
    public var sizesProblem: String? { apps.isEmpty || layout != nil || total == 100 ? nil : "Sizes add up to \(total) %, not 100 %" }

    public var preset: WorkspacePreset? {
        guard problem == nil else { return nil }
        var preset = WorkspacePreset(name: trimmedName, apps: apps, layout: layout)
        preset.openMissing = openMissing
        return preset
    }

    /// What an autosave writes for `workspace` (Sven 2026-10-17, no Save button): the draft under its name, or
    /// "Workspace 3" while it has none; a named one with no app yet keeps its name, and so does own sizes: a layout row
    /// without a preset reads back as Columns (`fresh`), so Your widths picked on an empty workspace jumped to Columns
    /// (Sven, build 2410). Nil while there is nothing a preset would hold (no app, no name, a ready layout), or while own
    /// sizes do not add up to 100.
    public func autosaved(workspace: String) -> WorkspacePreset? {
        let named = !WorkspacePreset.isUnnamed(name)
        guard named || !apps.isEmpty || layout == nil, sizesProblem == nil else { return nil }
        var preset = WorkspacePreset(name: named ? trimmedName : WorkspacePreset.unnamed(workspace), apps: apps, layout: layout)
        preset.openMissing = openMissing
        return preset
    }

    /// Adds an app not in the list yet; the sizes split evenly again.
    public mutating func add(bundleId: String, name: String) {
        guard !contains(bundleId) else { return }
        apps.append(.init(bundleId: bundleId, name: name, percent: 0))
        splitEvenly()
    }

    public mutating func remove(at index: Int) {
        apps.remove(at: index)
        splitEvenly()
    }

    public mutating func setPercent(_ percent: Int, at index: Int) { apps[index].percent = min(max(percent, 1), 100) }

    public mutating func setAtLogin(_ on: Bool, at index: Int) { apps[index].atLogin = on }

    /// A placed app clicked and another picked: the new one takes its spot and percent, At login off. One already placed
    /// trades spots with it instead.
    public mutating func replace(at index: Int, bundleId: String, name: String) {
        if let other = apps.firstIndex(where: { $0.bundleId == bundleId }) {
            guard other != index else { return }
            apps.swapAt(index, other)
            (apps[index].percent, apps[other].percent) = (apps[other].percent, apps[index].percent)
        } else {
            apps[index] = WorkspacePreset.App(bundleId: bundleId, name: name, percent: apps[index].percent)
        }
    }

    /// The Opens here list dragged, or Move up and down: the app lands at `to`, keeping its size and At login; nothing
    /// past either end.
    public mutating func move(from: Int, to: Int) {
        guard apps.indices.contains(from), apps.indices.contains(to) else { return }
        apps.insert(apps.remove(at: from), at: to)
    }

    /// The line between app `divider` and the next dragged so the first holds `percent`: only those two change, the
    /// total stays, and neither goes under 5 %.
    public mutating func resize(divider: Int, to percent: Int) {
        guard apps.indices.contains(divider), apps.indices.contains(divider + 1) else { return }
        let pair = apps[divider].percent + apps[divider + 1].percent
        let first = min(max(percent, Self.minPercent), pair - Self.minPercent)
        guard first >= Self.minPercent else { return }
        apps[divider].percent = first
        apps[divider + 1].percent = pair - first
    }

    static let minPercent = 5

    /// Where each app sits in `area` under this layout, in list order; `next` adds the spot the next app goes to, last.
    /// Own sizes are columns at their percents, the next spot an even share.
    public func tiles(in area: CGRect, next: Bool = false) -> [CGRect] { tiles(in: area, adding: next ? 1 : 0) }

    /// The same with `open` empty spots after the apps, each an even share under own sizes.
    private func tiles(in area: CGRect, adding open: Int) -> [CGRect] {
        if let layout { return layout.tiles(apps.count + open, in: area) }
        let shares = apps.map { CGFloat($0.percent) / CGFloat(max(total, 1)) * CGFloat(apps.count) } + Array(repeating: 1, count: open)
        let sum = shares.reduce(0, +)
        var x = area.minX
        return shares.map { share in
            defer { x += area.width * share / sum }
            return CGRect(x: x, y: area.minY, width: area.width * share / sum, height: area.height)
        }
    }

    /// The layout's shape while it has room: each placed app's tile, then the empty spots its picture has left (main +
    /// stack's stacked pair under the main), each of which takes the next app. Nil once the apps fill them; `preview`
    /// then draws the next app's strip.
    public func shape(in area: CGRect) -> (apps: [CGRect], open: [CGRect])? {
        let spots = LayoutPreset.spots(layout)
        guard apps.count < spots else { return nil }
        let all = tiles(in: area, adding: spots - apps.count)
        return (Array(all.prefix(apps.count)), Array(all.dropFirst(apps.count)))
    }

    /// The popup's preview (mockup E): each placed app at the size it really gets, and the next app's spot as a strip
    /// `strip` thick where that app would join: at the foot of the column it would stack into (main + stack's stack,
    /// rows, a grid's last column), else down the right as a new column; the whole area when nothing is placed. On
    /// scrolling's strip past one app, the spot is the strip's next column.
    public func preview(in area: CGRect, strip: CGFloat) -> (apps: [CGRect], next: CGRect) {
        let all = tiles(in: area, next: true)
        guard let joins = all.last, !apps.isEmpty else { return ([], area) }
        if layout == .scrolling, apps.count > 1 { return (all.dropLast(), joins) }
        if joins.height >= area.height - 0.5 {
            let (next, rest) = area.divided(atDistance: strip, from: .maxXEdge)
            return (tiles(in: rest), next)
        }
        let squeeze = (area.height - strip) / area.height
        let column = { (tile: CGRect) in abs(tile.minX - joins.minX) < 0.5 && abs(tile.maxX - joins.maxX) < 0.5 }
        let placed = tiles(in: area).map { tile in
            column(tile) ? CGRect(x: tile.minX, y: area.minY + (tile.minY - area.minY) * squeeze, width: tile.width, height: tile.height * squeeze) : tile
        }
        return (placed, CGRect(x: joins.minX, y: area.maxY - strip, width: joins.width, height: strip))
    }

    /// Where app `index` sits, in the editor's words: "main" and "stack 1"; left to right ("column 4" past three); top
    /// to bottom ("row 4" past three); a grid's "top left"; a strip's "column 4"; own sizes with the percent, "left, 55 %".
    public func place(of index: Int) -> String {
        let n = apps.count
        guard apps.indices.contains(index) else { return "" }
        func along(_ i: Int, of count: Int, _ words: [String], _ name: String) -> String {
            switch count {
            case 1: "whole screen"
            case 2: [words[0], words[2]][i]
            case 3: words[i]
            default: "\(name) \(i + 1)"
            }
        }
        let across = ["left", "middle", "right"], down = ["top", "middle", "bottom"]
        switch layout {
        case .mainStack: return index == 0 ? "main" : "stack \(index)"
        case .rows: return along(index, of: n, down, "row")
        case .columns: return along(index, of: n, across, "column")
        case .scrolling: return n == 1 ? "whole screen" : "column \(index + 1)"
        case .stage: return index == 0 ? "stage" : "shelf \(index)"
        case nil: return "\(along(index, of: n, across, "column")), \(apps[index].percent) %"
        case .grid:
            // LayoutPreset's grid: columns of two, the last alone when the count is odd.
            let columns = (n + 1) / 2, column = index / 2
            let side = columns > 1 ? along(column, of: columns, across, "column") : nil
            let height = n - 2 * column > 1 ? (index % 2 == 0 ? "top" : "bottom") : nil
            switch (side, height) {
            case let (side?, height?): return columns > 3 ? "\(side), \(height)" : "\(height) \(side)"
            case let (side?, nil): return side
            case let (nil, height?): return height
            case (nil, nil): return "whole screen"
            }
        }
    }

    /// A workspace with no preset yet (mockup E's new workspace): no name, so the field shows its example; the
    /// workspace's own layout, else Columns; Keep this layout from its auto, on when the row has no layout to keep.
    public static func fresh(workspace: String, row: WorkspaceLayout?) -> WorkspacePresetDraft {
        var draft = WorkspacePresetDraft(nil, workspace: workspace, row: row)
        draft.name = ""
        draft.layout = row?.preset ?? .columns
        draft.keepLayout = row?.preset == nil || row?.auto == true
        return draft
    }

    /// 100 shared out, the remainder to the first apps: 34, 33, 33.
    private mutating func splitEvenly() {
        guard !apps.isEmpty else { return }
        for i in apps.indices { apps[i].percent = 100 / apps.count + (i < 100 % apps.count ? 1 : 0) }
    }
}

extension WorkspaceLayout {
    /// The workspace's layout row once `preset` is saved for it: a ready layout becomes the row's preset, so Cycle layout
    /// and auto start from it, auto set to `auto` when the editor gave one. Own sizes take the row's preset off, so no
    /// auto rebuild undoes the sizes, and keep its auto: Sven's Keep this layout (Q229), back when he picks a ready layout
    /// again. Writing it off here turned the switch off by itself (Sven 2026-10-24).
    public func saving(_ preset: WorkspacePreset, auto: Bool? = nil) -> WorkspaceLayout {
        WorkspaceLayout(preset: preset.layout, auto: preset.layout == nil ? self.auto : auto ?? self.auto)
    }
}

/// Launch-or-focus by bundle id: a stopped app launches, a running one is activated, which opens a window when it has
/// none. False when no such app is installed.
@MainActor public protocol AppOpening {
    func open(bundle: String) -> Bool
}

/// Applies a workspace preset to its workspace once it is focused, in phases, checking before each that the tiler still
/// focuses that workspace (chained steps race the user and app activation, spike test 3):
/// 1. each app keeps its window already on the workspace, else one of its windows elsewhere is moved in by id, else the
///    app is opened; nothing opens for an app that has a window anywhere, so no duplicates;
/// 2. opened apps get up to `launchWait` for a window, moved in if an app rule put it elsewhere;
/// 3. one `tiler eval`: preset windows tiled, then a ready layout's commands (LayoutPreset) over the preset's
///    windows in list order and the workspace's other tiles after them; own sizes take the columns layout, then, after a
///    settle, resizes from the frames on screen so each preset tile gets its percent of the space the other tiles leave.
@MainActor
public struct WorkspacePresetApply {
    public struct Timing: Sendable {
        public var settle: Duration, poll: Duration, launchWait: Duration
        public init(settle: Duration, poll: Duration, launchWait: Duration) { self.settle = settle; self.poll = poll; self.launchWait = launchWait }
        public static let live = Timing(settle: tilerSettle, poll: .milliseconds(250), launchWait: .seconds(10))
    }

    public struct Outcome: Equatable, Sendable {
        /// Bundle ids opened, windows moved in, and bundle ids whose window never showed.
        public var opened: [String] = [], pulled = 0, missing: [String] = []
    }

    public struct LeftWorkspace: Error, CustomStringConvertible {
        public let workspace: String
        public var description: String { "workspace \(workspace) is no longer focused, preset stopped" }
    }

    let preset: WorkspacePreset
    let workspace: String
    let tiler: any TilerRunning
    let apps: any AppOpening
    /// Window frames on screen by the tiler's id (CGWindowIDs).
    let frames: @MainActor () -> [Int: CGRect]
    let timing: Timing

    public init(preset: WorkspacePreset, workspace: String, tiler: any TilerRunning, apps: any AppOpening,
                frames: @escaping @MainActor () -> [Int: CGRect], timing: Timing = .live) {
        self.preset = preset; self.workspace = workspace; self.tiler = tiler; self.apps = apps; self.frames = frames; self.timing = timing
    }

    public func run() async throws -> Outcome {
        try await requireFocus()
        let apps = unique
        var outcome = Outcome()
        var chosen: [String: Int] = [:], moves: [AeroCommand] = [], waiting: [String] = []
        let all = try await tiler.windows(.all)
        for bundle in apps.map(\.bundleId) {
            if let here = all.first(where: { $0.bundleId == bundle && $0.workspace == workspace }) {
                chosen[bundle] = here.id
            } else if let there = all.first(where: { $0.bundleId == bundle }) {
                moves.append(.moveWindow(id: there.id, toWorkspace: workspace))
                chosen[bundle] = there.id
            } else if !preset.openMissing {
                continue
            } else if self.apps.open(bundle: bundle) {
                waiting.append(bundle)
            } else {
                outcome.missing.append(bundle)
            }
        }
        if !moves.isEmpty { try await tiler.run(.eval(moves)) }
        outcome.pulled = moves.count
        outcome.opened = waiting
        // Opened apps: their first window, moved in when an app rule placed it elsewhere, once focus is still here.
        let arrival = try await Self.awaitWindows(waiting.map { ($0, workspace) }, tiler: tiler, timing: timing,
                                                  beforeMoves: requireFocus)
        chosen.merge(arrival.windows) { $1 }
        outcome.missing += arrival.missing

        // Moved and opened windows land before the layout reads them.
        if !moves.isEmpty || !outcome.opened.isEmpty { try await Task.sleep(for: timing.settle) }
        try await requireFocus()
        let here = try await tiler.windows(.workspace(workspace))
        let onWorkspace = Set(here.map(\.id))
        // The preset's windows on the workspace, in list order, with their apps' percents.
        let placed = apps.compactMap { app in chosen[app.bundleId].flatMap { onWorkspace.contains($0) ? (id: $0, percent: app.percent) : nil } }
        let ids = placed.map(\.id)
        let tile: [AeroCommand] = here.filter { $0.isFloating && ids.contains($0.id) }.map { .setFloating(id: $0.id, false) }
        let tiles = ids + here.filter { !$0.isFloating && !ids.contains($0.id) }.map(\.id)
        try await tiler.run(.eval(tile + (preset.layout ?? .columns).commands(workspace: workspace, windows: tiles)))
        guard preset.layout == nil else { return outcome }

        try await Task.sleep(for: timing.settle)
        try await requireFocus()
        let resizes = sizes(percents: Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.percent) }), tiles: tiles)
        if !resizes.isEmpty { try await tiler.run(.eval(resizes)) }
        return outcome
    }

    /// Opened apps' first windows, looked for every `poll` until `launchWait`: one that shows on another workspace is
    /// moved to its own, each poll's moves in one eval after `beforeMoves`. The windows that showed by bundle id, how
    /// many were moved, and the bundle ids still without one.
    static func awaitWindows(_ waiting: [(bundle: String, workspace: String)], tiler: any TilerRunning, timing: Timing,
                             beforeMoves: () async throws -> Void = {}) async throws -> (windows: [String: Int], moved: Int, missing: [String]) {
        var waiting = waiting, windows: [String: Int] = [:], moved = 0
        let deadline = ContinuousClock.now + timing.launchWait
        while !waiting.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: timing.poll)
            let now = try await tiler.windows(.all)
            var moves: [AeroCommand] = []
            waiting.removeAll { app in
                guard let window = now.first(where: { $0.bundleId == app.bundle }) else { return false }
                if window.workspace != app.workspace { moves.append(.moveWindow(id: window.id, toWorkspace: app.workspace)) }
                windows[app.bundle] = window.id
                return true
            }
            if !moves.isEmpty {
                try await beforeMoves()
                try await tiler.run(.eval(moves))
            }
            moved += moves.count
        }
        return (windows, moved, waiting.map(\.bundle))
    }

    /// The preset's apps, each once, in list order.
    private var unique: [WorkspacePreset.App] {
        var seen = Set<String>()
        return preset.apps.filter { seen.insert($0.bundleId).inserted }
    }

    /// Own sizes: every tile's slot on screen now, the other tiles kept, the preset's windows sharing the rest by
    /// their apps' percents.
    private func sizes(percents: [Int: Int], tiles: [Int]) -> [AeroCommand] {
        let onScreen = frames()
        let order = tiles.compactMap { id in onScreen[id].map { (id: id, frame: $0) } }.sorted { $0.frame.minX < $1.frame.minX }
        let start = TileResize.slots(order.map(\.frame), vertical: false)
        let shared = zip(order, start).compactMap { tile, slot in percents[tile.id].map { (slot: slot, part: CGFloat($0)) } }
        let space = shared.map(\.slot).reduce(0, +), parts = shared.map(\.part).reduce(0, +)
        guard parts > 0 else { return [] }
        let target = zip(order, start).map { tile, slot in percents[tile.id].map { CGFloat($0) / parts * space } ?? slot }
        return TileResize.commands(order: order.map(\.id), start: start, target: target, axis: .width)
    }

    private func requireFocus() async throws {
        guard try await tiler.focusedWorkspace()?.workspace == workspace else { throw LeftWorkspace(workspace: workspace) }
    }
}

/// At login (mockup E, card agent-bo-95422980): once per login session, every app a workspace's preset marks At login
/// that has no window yet is opened, and its first window moved to that workspace; the layout follows on the first
/// switch there (WorkspacePresetApply). A running app is left where it is.
@MainActor
public struct WorkspaceLoginOpen {
    public struct Planned: Equatable, Sendable {
        public let bundleId: String, workspace: String
    }

    /// Each At login app once, for the first workspace (in name order) whose preset has it.
    public static func plan(_ contents: WorkspacePresetStore.Contents) -> [Planned] {
        var seen = Set<String>()
        return contents.workspaces.keys.sorted(by: OccupiedWorkspace.ordered).flatMap { workspace in
            (contents.preset(for: workspace)?.apps ?? []).filter { $0.atLogin && seen.insert($0.bundleId).inserted }
                .map { Planned(bundleId: $0.bundleId, workspace: workspace) }
        }
    }

    /// Due when this login session has not opened them yet: `last` is the session start that last did, stored as seconds
    /// since 1970. No known session start opens nothing, so a Pilot rebuild never reopens apps.
    public static func due(session: Date?, last: Double?) -> Bool {
        guard let session else { return false }
        return last != session.timeIntervalSince1970
    }

    let plan: [Planned]
    let tiler: any TilerRunning
    let apps: any AppOpening
    let timing: WorkspacePresetApply.Timing

    public init(plan: [Planned], tiler: any TilerRunning, apps: any AppOpening, timing: WorkspacePresetApply.Timing = .live) {
        self.plan = plan; self.tiler = tiler; self.apps = apps; self.timing = timing
    }

    public func run() async throws -> WorkspacePresetApply.Outcome {
        var outcome = WorkspacePresetApply.Outcome()
        let running = Set(try await tiler.windows(.all).map(\.bundleId))
        let stopped = plan.filter { !running.contains($0.bundleId) }
        let opened = stopped.filter { apps.open(bundle: $0.bundleId) }
        outcome.opened = opened.map(\.bundleId)
        let arrival = try await WorkspacePresetApply.awaitWindows(opened.map { ($0.bundleId, $0.workspace) }, tiler: tiler, timing: timing)
        outcome.pulled = arrival.moved
        outcome.missing = stopped.map(\.bundleId).filter { !outcome.opened.contains($0) } + arrival.missing
        return outcome
    }
}
