import AppKit

/// A Homebrew tool's path: /opt/homebrew on Apple silicon, /usr/local on Intel.
public enum Homebrew {
    public static func cli(_ tool: String, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"].first(where: isExecutable)
    }

    /// Homebrew's prefix, the folder its brew is in the bin of; nil when Homebrew is not installed.
    public static var prefix: String? { cli("brew").map { URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().path } }
}

/// One call to Pilot's tiler (ADR 0011), in the command words of the CLI its engine was ported from; `arguments` is
/// that text form, which logs and refusals print.
public enum AeroCommand: Equatable, Sendable {
    case workspace(String)
    case workspaceNext
    case workspacePrevious
    case workspaceBackAndForth
    /// Moves a window by id, so the move never lands on whichever window the tiler happens to focus. Follow goes along
    /// to the workspace and focuses the window there (spec omarchy-ideas T7); without it you stay where you are.
    case moveWindow(id: Int, toWorkspace: String, follow: Bool = false)
    case listWindows(WindowScope)
    case listVisibleWorkspaces
    /// The focused workspace with its root layout, which a snapshot keeps (story 69).
    case focusedWorkspace
    /// The workspace on the monitor under the pointer, where a dragged window was released (card agent-bo-95422861).
    case mouseWorkspace
    /// Several commands in one call, run in order inside one session: a layout preset's rebuild, with no other event
    /// between steps. An argument holding anything but plain characters is single-quoted.
    indirect case eval([AeroCommand])
    /// The tiling switch: off, the tiler puts the windows of hidden workspaces back on screen and leaves every window alone.
    case enable(Bool)
    /// Tiled window keys (stories 8, 9, 11 and 67). A command that can name its window does, for the same reason
    /// as moveWindow; focus and focus-monitor act on the tiler's focus, which the caller checks first.
    case focus(Direction)
    /// Window search (story 76): focuses one window by id, switching to its workspace.
    case focusWindow(id: Int)
    /// Every window on the workspace in turn, depth first, wrapping around: Omarchy's Alt+Tab.
    case focusRing(next: Bool)
    /// The service mode as plain actions (Sven, 2026-10-05): join a group, equal sizes, close the rest. Close others
    /// acts on the tiler's focus, like focus.
    case joinWith(id: Int, Direction)
    case balanceSizes(workspace: String)
    case closeAllButCurrent
    /// Show desktop (Sven, 2026-10-26): the focused workspace's windows into the hide corner, or back as they were.
    case toggleDesktop
    case swap(id: Int, Direction)
    case resize(id: Int, Axis, by: Int)
    case flipSplit(id: Int)
    case toggleScrolling(workspace: String)
    /// The scrolling layout's column keys (spec scrolling-layout, T2): the window's column steps to the next width in the
    /// settings' list, or the one before; the strip centres the window's column. Outside a strip the tiler refuses them.
    case cycleColumnWidth(id: Int, forward: Bool)
    case centreColumn(id: Int)
    /// T10: the window's column full width and back; the window out of its column's stack into a column of its own.
    case maximiseColumn(id: Int)
    case leaveStack(id: Int)
    /// A snapshot's restore (spec scrolling-layout, T3): the window's column back to the width it was saved at, in points.
    case setColumnWidth(id: Int, points: Int)
    case focusMonitor(Direction)
    case moveToMonitor(id: Int, Direction)
    /// Floating windows (stories 6, 7, 65, 66): float or tile one window; Pilot then places a floated one through AX.
    case setFloating(id: Int, Bool)
    /// Pop out (spec omarchy-ideas T1): on floats the window and pins it, so it follows every workspace its monitor
    /// shows; off unpins it and tiles it where you are.
    case setPinned(id: Int, Bool)
    /// Snapshot restore (story 71): flatten the workspace, set its root layout, order tiles with moves that stop at the
    /// workspace's edge (the default would wrap the window in a new container); sizes go through `resize`.
    case flatten(workspace: String)
    case setRootLayout(workspace: String, String)
    case move(id: Int, Direction)
    /// The Window shelf's click on a minimized window (ADR 0015, Q690): macOS restores it onto the workspace it was
    /// minimized from, and it takes the focus, so that workspace's stage.
    case unminimize(id: Int)

    public enum Axis: String, Sendable { case width, height }

    public enum WindowScope: Equatable, Sendable {
        /// `minimized`: every window macOS holds minimized, each with the workspace it was minimized from.
        case all, focused, workspace(String), minimized

        var arguments: [String] {
            switch self {
            case .all: ["--all"]
            case .focused: ["--focused"]
            case .workspace(let name): ["--workspace", name]
            case .minimized: ["--minimized"]
            }
        }
    }

    public var arguments: [String] {
        switch self {
        case .listWindows(let scope): ["list-windows"] + scope.arguments + ["--json", "--format", AeroWindow.format]
        case .focusedWorkspace: ["list-workspaces", "--focused", "--json", "--format", "%{workspace} %{workspace-root-container-layout}"]
        case .mouseWorkspace: ["list-workspaces", "--monitor", "mouse", "--visible", "--json", "--format", "%{workspace} %{workspace-root-container-layout}"]
        case .listVisibleWorkspaces: ["list-workspaces", "--monitor", "all", "--visible", "--json", "--format", "%{workspace} %{monitor-id} %{monitor-name}"]
        case .eval(let commands): ["eval", commands.map { $0.arguments.map(Self.quoted).joined(separator: " ") }.joined(separator: "; ")]
        case .enable(let on): ["enable", on ? "on" : "off"]
        case .workspace(let name): ["workspace", name]
        case .workspaceNext: ["workspace", "--wrap-around", "next"]
        case .workspacePrevious: ["workspace", "--wrap-around", "prev"]
        case .workspaceBackAndForth: ["workspace-back-and-forth"]
        case .moveWindow(let id, let workspace, let follow):
            ["move-node-to-workspace", "--window-id", String(id)] + (follow ? ["--focus-follows-window"] : []) + [workspace]
        case .focus(let d): ["focus", d.rawValue]
        case .focusWindow(let id): ["focus", "--window-id", String(id)]
        case .focusRing(let next): ["focus", next ? "dfs-next" : "dfs-prev", "--boundaries-action", "wrap-around-the-workspace"]
        case .joinWith(let id, let d): ["join-with", "--window-id", String(id), d.rawValue]
        case .balanceSizes(let workspace): ["balance-sizes", "--workspace", workspace]
        case .closeAllButCurrent: ["close-all-windows-but-current"]
        case .toggleDesktop: ["show-desktop"]
        case .swap(let id, let d): ["swap", "--window-id", String(id), d.rawValue]
        case .resize(let id, let axis, let step): ["resize", "--window-id", String(id), axis.rawValue, step < 0 ? "\(step)" : "+\(step)"]
        case .flipSplit(let id): ["layout", "--window-id", String(id), "horizontal", "vertical"]
        case .toggleScrolling(let workspace): ["layout", "--workspace", workspace, "--root", "tiles", "scrolling"]
        case .cycleColumnWidth(let id, let forward): ["column-width", "--window-id", String(id), forward ? "next" : "prev"]
        case .centreColumn(let id): ["center-column", "--window-id", String(id)]
        case .maximiseColumn(let id): ["column-width", "--window-id", String(id), "maximise"]
        case .leaveStack(let id): ["leave-stack", "--window-id", String(id)]
        case .setColumnWidth(let id, let points): ["column-width", "--window-id", String(id), String(points)]
        case .focusMonitor(let d): ["focus-monitor", "--wrap-around", d.rawValue]
        case .moveToMonitor(let id, let d): ["move-node-to-monitor", "--window-id", String(id), "--focus-follows-window", "--wrap-around", d.rawValue]
        case .setFloating(let id, let on): ["layout", "--window-id", String(id), on ? "floating" : "tiling"]
        case .setPinned(let id, let on): ["pin", "--window-id", String(id), on ? "on" : "off"]
        case .flatten(let workspace): ["flatten-workspace-tree", "--workspace", workspace]
        case .setRootLayout(let workspace, let layout): ["layout", "--workspace", workspace, "--root", layout]
        case .move(let id, let d): ["move", "--window-id", String(id), "--boundaries-action", "stop", d.rawValue]
        case .unminimize(let id): ["unminimize", "--window-id", String(id)]
        }
    }
}

extension AeroCommand {
    /// One argument as the CLI's shell read it: plain as is, else in single quotes.
    static func quoted(_ argument: String) -> String {
        let plain = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:/+=%{}".unicodeScalars.contains($0)
        }
        return plain ? argument : "'\(argument)'"
    }
}

/// A JSON array a `list-… --json` call answers.
public protocol AeroListing: Decodable {}

extension AeroListing {
    public static func parse(_ json: String) throws -> [Self] {
        try JSONDecoder().decode([Self].self, from: Data(json.utf8))
    }
}

/// One window as `list-windows --json` answers it. Without `--format` the JSON carries only id, app and title, so every
/// listing asks for `format`.
public struct AeroWindow: AeroListing, Equatable, Sendable {
    public let id: Int
    public let appName: String
    public let bundleId: String
    public let pid: Int32
    public let workspace: String
    public let monitorId: Int
    /// The parent container's layout: h_tiles, v_tiles, h_scrolling, h_stage or floating.
    public let layout: String
    public let title: String
    /// A pinned pop-out (spec omarchy-ideas T1); the tiler's listing carries it beside `format`'s fields.
    public var pinned: Bool? = nil
    /// On a Stage workspace (ADR 0015), off the stage in the hide corner; and the first window of the joined group it is
    /// in. The tiler's listing carries them only when set.
    public var shelved: Bool? = nil
    public var group: Int? = nil

    public var isFloating: Bool { layout == "floating" }
    public var isPinned: Bool { pinned == true }
    public var isShelved: Bool { shelved == true }
    /// macOS holds it minimized; its `workspace` is the one it was minimized from.
    public var isMinimized: Bool { layout == "macos_native_minimized" }

    public static let format = "%{window-id} %{app-name} %{app-bundle-id} %{app-pid} %{workspace} %{monitor-id} %{window-layout} %{window-title}"

    enum CodingKeys: String, CodingKey {
        case id = "window-id", appName = "app-name", bundleId = "app-bundle-id", pid = "app-pid"
        case workspace, monitorId = "monitor-id", layout = "window-layout", title = "window-title", pinned = "window-pinned"
        case shelved = "window-shelved", group = "window-group"
    }
}

/// The workspace a monitor shows, from `list-workspaces --monitor all --visible`.
public struct AeroMonitorWorkspace: AeroListing, Equatable, Sendable {
    public let monitorId: Int
    public let monitorName: String
    public let workspace: String
    public var displayUUID: String? = nil
    /// The workspace's root layout (h_tiles, v_tiles, h_scrolling, h_stage); the Window shelf shows on `h_stage`.
    public var rootLayout: String? = nil
    /// Show desktop holds its windows in the corner; set only then.
    public var showingDesktop: Bool? = nil

    public var isStage: Bool { rootLayout == "h_stage" }
    public var isShowingDesktop: Bool { showingDesktop == true }

    enum CodingKeys: String, CodingKey {
        case monitorId = "monitor-id", monitorName = "monitor-name", workspace, displayUUID = "display-uuid"
        case rootLayout = "workspace-root-container-layout", showingDesktop = "workspace-showing-desktop"
    }
}

/// A workspace and its root container's layout (h_tiles, v_tiles, h_scrolling or h_stage).
public struct AeroWorkspace: AeroListing, Equatable, Sendable {
    public let workspace: String
    public let rootLayout: String

    enum CodingKeys: String, CodingKey { case workspace, rootLayout = "workspace-root-container-layout" }
}

/// One row of the dropdown's workspace list (story 73): a workspace that has a window, with its apps.
public struct OccupiedWorkspace: Equatable, Sendable {
    public let name: String
    public let apps: [String]
    /// Each app's bundle id by its name, as the tiler listed its first window (the top bar's icons, card agent-bo-95423019).
    public let bundles: [String: String]

    public init(name: String, apps: [String], bundles: [String: String] = [:]) { self.name = name; self.apps = apps; self.bundles = bundles }

    /// Groups windows by workspace, numbered ones in number order before any named one; each app once, first seen
    /// first. Empty workspaces never appear, since no window names them.
    public static func list(_ windows: [AeroWindow]) -> [OccupiedWorkspace] {
        var apps: [String: [String]] = [:], bundles: [String: [String: String]] = [:]
        for w in windows where !(apps[w.workspace]?.contains(w.appName) ?? false) {
            apps[w.workspace, default: []].append(w.appName)
            bundles[w.workspace, default: [:]][w.appName] = w.bundleId
        }
        return apps.keys.sorted(by: ordered).map { OccupiedWorkspace(name: $0, apps: apps[$0]!, bundles: bundles[$0]!) }
    }

    /// Workspace names in display order: numbered ones in number order before any named one.
    public static func ordered(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a < b
        }
    }
}

/// One event of the tiler's stream (InProcessTiler.events).
public enum AeroEvent: Equatable, Sendable {
    case focusedWorkspaceChanged(workspace: String, previous: String?)
    case focusedMonitorChanged(monitorId: Int, workspace: String)
    case windowDetected(workspace: String)
    /// Focus moved, which is also how a closed window shows: the tiler has no window-closed event.
    case focusChanged(workspace: String)
    /// A shown Stage workspace's windows or stage changed (the Window shelf's, ADR 0015).
    case stagesChanged(workspace: String)

    /// A window opened or focus moved, rather than a workspace or monitor taking focus.
    public var isWindowEvent: Bool {
        switch self {
        case .windowDetected, .focusChanged, .stagesChanged: true
        case .focusedWorkspaceChanged, .focusedMonitorChanged: false
        }
    }

    public var workspace: String {
        switch self {
        case .focusedWorkspaceChanged(let workspace, _), .focusedMonitorChanged(_, let workspace), .windowDetected(let workspace),
             .focusChanged(let workspace), .stagesChanged(let workspace): workspace
        }
    }
}
