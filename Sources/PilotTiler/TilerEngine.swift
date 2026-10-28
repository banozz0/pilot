import AppKit
import PilotCore

/// The engine is not running, so it took no call: it was never started, or another tiler kept it off.
public struct TilerNotRunning: Error, Sendable {}

/// Another tiler's app, which Pilot's engine was ported from and replaced (ADR 0011). While it runs the engine stays off:
/// two tilers would fight over every window (vault Own tiler spike, Risks). Pilot never quits it; Sven does.
public enum OtherTiler {
    public static let bundleId = "bobko.aerospace"
    public static let name = "AeroSpace"

    @MainActor public static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
}

public struct OtherTilerRunning: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "\(OtherTiler.name) is running: quit it and Pilot's tiler starts" }
}

/// Set by the first start: the global observers are added once, and only a started engine takes the tiling switch's on.
@MainActor var tilerStarted = false

/// The engine ran the call and it did nothing: no such window, no neighbour that way, a layout it cannot take.
public struct TilerCallRefused: AeroCallRefusal, Equatable, Sendable, CustomStringConvertible {
    public let command: [String]
    public var description: String { "The own tiler refused: \(command.joined(separator: " "))" }
}

/// The tiler (card agent-bo-95422997, AC2): each AeroCommand Pilot sends runs as its typed call inside one session
/// (model refreshed before and after, then laid out) within the fault boundary. A listing answers in the ported CLI's
/// `--json --format` shape, so AeroWindow and AeroWorkspace parse it.
@MainActor
public struct InProcessTiler: TilerRunning {
    /// One call as one session: runLightSession in Pilot; tests pass the harness's `run`, since layout needs real AX.
    typealias Session = @MainActor (_ name: String, _ body: @MainActor () async throws -> String) async throws -> String
    private let session: Session
    private let otherTilerRunning: @MainActor () -> Bool

    public init() {
        self.init { name, body in try await runLightSession(.pilotCall(name), .forceRun, body: body) }
    }

    init(session: @escaping Session,
         otherTilerRunning: @escaping @MainActor () -> Bool = { OtherTiler.isRunning }) {
        self.session = session
        self.otherTilerRunning = otherTilerRunning
    }

    public var isRunning: Bool { isTilerEnabled }

    @discardableResult
    public func run(_ command: AeroCommand) async throws -> String {
        // The tiling switch turns a started engine back on; every other call waits for that.
        guard isRunning || (command == .enable(true) && tilerStarted) else { throw TilerNotRunning() }
        return try await session(command.arguments.first ?? "") { try await perform(command) }
    }

    /// Pilot's launch (card agent-bo-95422999): the ported initAppBundle without its server, config file or CLI. Settings
    /// and layouts arrive before it (apply, setLayouts); the first refresh registers every window, each on the workspace
    /// it was on before the relaunch (windowHomes), else on the one its monitor shows, then the session lays them out.
    public func start() async throws {
        guard !otherTilerRunning() else { throw OtherTilerRunning() }
        guard !isRunning else { return }
        if !tilerStarted {
            GlobalObserver.initObserver()
            windowSlots = WindowSlots(file: WindowSlots.standardFile) // card agent-bo-95423036
            windowHomes = WindowHomes(file: WindowHomes.standardFile) // Q437: each window back on its workspace
            // Pilot's own app is refreshed with the rest from now on, whatever its activation policy (OwnApp)
            _ = try await MacApp.getOrRegister(.current)
            Workspace.garbageCollectUnusedWorkspaces()
            _ = Workspace.all.first?.focusWorkspace()
            tilerStarted = true
        }
        await setTilerEnabled(true)
        await runHeavyCompleteRefreshSession(.startup, assumeCancellable: false, layoutWorkspaces: false)
        _ = try await session("startup") { "" }
    }

    /// Pilot's quit: the engine leaves every window alone and puts each back on screen (the port's beforeTermination).
    public func stop() {
        guard isRunning else { return }
        isTilerEnabled = false
        shownDesktop = nil
        try? endPreview {} // a drag under way never lands: its live swap goes back, its drop zone goes
        draggedWindowId = nil
        cancelledDragWindowId = nil
        gapDrag = nil
        publishGaps()
        unparkAllWindows()
    }

    /// Pilot's settings changed (AC4): its block, as TilerSettings, becomes the engine's settings; a running engine lays
    /// out again in the same session, a workspace just pinned moved to its monitor.
    public func apply(_ settings: TilerSettings) async throws {
        guard isRunning else { config = settings; return }
        _ = try await session("reload-config") { config = settings; showPinnedWorkspacesOnTheirMonitors(); return "" }
    }

    /// Pilot's workspace layouts (AC3): each workspace with a preset keeps it here, and one on auto is rebuilt before layout
    /// once a window comes or goes. A workspace already arranged keeps its window order.
    public func setLayouts(_ layouts: [String: WorkspaceLayout]) {
        arrangements = layouts.reduce(into: [:]) { kept, entry in
            guard let preset = entry.value.preset else { return }
            kept[entry.key] = WorkspaceArrangement(preset, auto: entry.value.auto, order: arrangements[entry.key]?.order ?? [])
        }
    }

    /// Builds `workspace` as `preset` now, the focused window first, then the rest as the tree reads.
    public func arrange(_ workspace: String, as preset: LayoutPreset) async throws {
        guard isRunning else { throw TilerNotRunning() }
        _ = try await session("layout-preset") {
            guard let target = Workspace.existing(byName: workspace) else { throw TilerCallRefused(command: [workspace]) }
            let tiled = try target.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
            let first = focus.windowOrNil.map(\.windowId).flatMap { tiled.contains($0) ? [$0] : nil } ?? []
            try target.arrange(WorkspaceArrangement(preset, auto: arrangements[workspace]?.auto ?? false,
                                                    order: first + tiled.filter { !first.contains($0) }))
            return ""
        }
    }

    /// The engine's events as AeroEvents, starting with the current state while it runs (the top bar's focused workspace
    /// before the first switch).
    public func events() -> AsyncStream<AeroEvent> {
        let events = tilerEvents(sendInitial: isRunning)
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await event in events { if let event = AeroEvent(event) { continuation.yield(event) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AeroEvent {
    init?(_ event: TilerEvent) {
        switch event {
            case .focusChanged(_, let workspace): self = .focusChanged(workspace: workspace)
            case .focusedMonitorChanged(let workspace, let monitorId): self = .focusedMonitorChanged(monitorId: monitorId, workspace: workspace)
            case .workspaceChanged(let workspace, let previous): self = .focusedWorkspaceChanged(workspace: workspace, previous: previous)
            case .windowDetected(_, let workspace?, _, _): self = .windowDetected(workspace: workspace)
            case .windowDetected(_, nil, _, _): return nil
        }
    }
}
