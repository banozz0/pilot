import Foundation

/// A drag on the Workspaces page (Sven, 2026-11-15: "i should be able to swap and move apps in workspaces just by left
/// click dragging them in the workspaces page"), and `pilot workspace move`, which makes the same change. An app a
/// workspace holds, dropped on another workspace, moves there; dropped on another app's tile, the two trade places,
/// across two workspaces or within one. The page draws each workspace's preset and a switch lays the preset out, pulling
/// each of its apps' windows in (WorkspacePresetApply), so a drop changes the presets, moves the app's rule along when it
/// sent the app to the workspace it left, and moves its windows there live: one window of each app trading places in the
/// tiler's tree, the rest moved by id.
public struct WorkspaceAppDrop: Equatable, Sendable {
    public enum Kind: String, Sendable { case move, swap }

    public let kind: Kind
    /// Each workspace the drop changes, with its draft to save as the editor does.
    public var drafts: [String: WorkspacePresetDraft]
    /// The app rules the drop changes, each as it now reads: one that sent a dragged app to the workspace it left now
    /// sends it where it went.
    public var rules: [PilotBlock.AppRule]
    /// The tiler calls that carry the windows along.
    public var commands: [AeroCommand]

    public struct Refused: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// `app`, which workspace `from` holds, dropped on workspace `to`, on the tile of `onto` when given. `draft` reads a
    /// workspace's draft as the page has it; `windows` is the tiler's list, `rules` the Pilot block's app rules.
    public static func plan(app: String, from: String, to: String, onto: String? = nil, draft: (String) -> WorkspacePresetDraft,
                            windows: [AeroWindow], rules: [PilotBlock.AppRule]) throws(Refused) -> WorkspaceAppDrop {
        var source = draft(from)
        guard let i = source.apps.firstIndex(where: { $0.bundleId == app }) else { throw Refused("workspace \(from) holds no \(app)") }
        let moved = source.apps[i]
        func carried(_ bundle: String, on workspace: String) -> [AeroWindow] { Self.carried(bundle, on: workspace, windows) }
        func ruled(_ bundle: String, from: String, to: String) -> [PilotBlock.AppRule] {
            rules.contains(.init(appId: bundle, workspace: from)) ? [.init(appId: bundle, workspace: to)] : []
        }

        guard let onto else {
            guard to != from else { throw Refused("\(moved.name) is on workspace \(from) already") }
            var target = draft(to)
            source.remove(at: i)
            // Already there: it only leaves the workspace it came from.
            if !target.contains(app) {
                target.add(bundleId: app, name: moved.name)
                target.setAtLogin(moved.atLogin, at: target.apps.count - 1)
            }
            return WorkspaceAppDrop(kind: .move, drafts: [from: source, to: target], rules: ruled(app, from: from, to: to),
                                    commands: carried(app, on: from).map { .moveWindow(id: $0.id, toWorkspace: to) })
        }
        guard onto != app else { throw Refused("\(moved.name) dropped on itself") }

        // Within one workspace: the two trade spots, and a tiled window of each trades places.
        if to == from {
            guard let j = source.apps.firstIndex(where: { $0.bundleId == onto }) else { throw Refused("workspace \(from) holds no \(onto)") }
            source.replace(at: j, bundleId: app, name: moved.name)
            let pair = [carried(app, on: from), carried(onto, on: from)].map { $0.first { !$0.isFloating } }
            let commands: [AeroCommand] = if let a = pair[0], let b = pair[1] { [.swapWindows(id: a.id, with: b.id)] } else { [] }
            return WorkspaceAppDrop(kind: .swap, drafts: [from: source], rules: [], commands: commands)
        }

        // Across two: each takes the other's spot, its percent and At login going with it.
        var target = draft(to)
        guard let j = target.apps.firstIndex(where: { $0.bundleId == onto }) else { throw Refused("workspace \(to) holds no \(onto)") }
        let other = target.apps[j]
        guard !target.contains(app) else { throw Refused("workspace \(to) holds \(moved.name) already") }
        guard !source.contains(onto) else { throw Refused("workspace \(from) holds \(other.name) already") }
        source.replace(at: i, bundleId: onto, name: other.name)
        source.setAtLogin(other.atLogin, at: i)
        target.replace(at: j, bundleId: app, name: moved.name)
        target.setAtLogin(moved.atLogin, at: j)
        var going = carried(app, on: from), coming = carried(onto, on: to)
        var commands: [AeroCommand] = []
        // One tiled window each trades places in the tree, so each lands where the other was; the rest move by id.
        if let a = going.firstIndex(where: { !$0.isFloating }), let b = coming.firstIndex(where: { !$0.isFloating }) {
            commands.append(.swapWindows(id: going.remove(at: a).id, with: coming.remove(at: b).id))
        }
        commands += going.map { .moveWindow(id: $0.id, toWorkspace: to) } + coming.map { .moveWindow(id: $0.id, toWorkspace: from) }
        return WorkspaceAppDrop(kind: .swap, drafts: [from: source, to: target],
                                rules: ruled(app, from: from, to: to) + ruled(onto, from: to, to: from), commands: commands)
    }

    /// A row of Always lands here dropped on another workspace: its rule sends the app there now, and its windows on the
    /// workspace it left go along.
    public static func rule(app: String, from: String, to: String, windows: [AeroWindow]) throws(Refused) -> WorkspaceAppDrop {
        guard to != from else { throw Refused("\(app) always lands on workspace \(from) already") }
        return WorkspaceAppDrop(kind: .move, drafts: [:], rules: [.init(appId: app, workspace: to)],
                                commands: carried(app, on: from, windows).map { .moveWindow(id: $0.id, toWorkspace: to) })
    }

    /// The windows a drop carries: the app's on the workspace it leaves, minimized and pinned ones left alone.
    private static func carried(_ bundle: String, on workspace: String, _ windows: [AeroWindow]) -> [AeroWindow] {
        windows.filter { $0.bundleId == bundle && $0.workspace == workspace && !$0.isMinimized && !$0.isPinned }
    }
}
