import AppKit
import Observation
import OSLog
import PilotCore
import PilotTiler

let wslog = Logger(subsystem: "dev.banozz.pilot", category: "workspaces")

/// The own tiler as the service drives it (card agent-bo-95422997, AC4): InProcessTiler, a fake in tests.
@MainActor protocol TilerEngineRunning: TilerRunning {
    var isRunning: Bool { get }
    func apply(_ settings: TilerSettings) async throws
    func setLayouts(_ layouts: [String: WorkspaceLayout])
    func arrange(_ workspace: String, as preset: LayoutPreset) async throws
    func start() async throws
    func stop()
}

extension InProcessTiler: TilerEngineRunning {}

/// The one tiler connection the app shares (SPEC.md, Tiler and Observers lines; ADR 0011): Pilot's tiler, and the
/// focused workspace with the one each monitor shows, kept current by the tiler's event stream. Owned by the observers;
/// modules receive it at registration.
@Observable @MainActor
final class TilerService {
    @ObservationIgnored let engine: any TilerEngineRunning
    /// Shows the not-running line: a HUD tip in Pilot, a recorder in tests, so a suite never puts one on the screen.
    @ObservationIgnored private let tip: @MainActor (String) -> Void
    private(set) var focused: String?
    private(set) var perMonitor: [AeroMonitorWorkspace] = [] {
        didSet {
            guard !oldValue.isEmpty else { return }
            for shown in perMonitor where !oldValue.contains(where: { $0.monitorId == shown.monitorId && $0.workspace == shown.workspace }) {
                onWorkspaceShown(shown.workspace, oldValue.first { $0.monitorId == shown.monitorId }?.workspace, shown.displayUUID)
            }
        }
    }
    /// The workspaces that have windows, for the dropdown (story 73); read on each workspace change and menu open.
    private(set) var occupied: [OccupiedWorkspace] = []
    /// Every window as that read listed it: Home's Now block draws the focused workspace's windows with their titles and
    /// layout (card agent-bo-95422992).
    private(set) var windows: [AeroWindow] = []
    /// Each occupied workspace's display, the monitor its windows are on (Instrument's top bar splits off another
    /// display's); set only when it changes, so a window's new title redraws no bar.
    private(set) var workspaceMonitors: [String: Int] = [:]

    private var subscription: Task<Void, Never>?
    /// The other tiler's app (OtherTiler): its launch tips, its quit starts Pilot's tiler if that start was held back.
    private var otherTilerWatch: AppWatcher?
    /// The tiler switched to another workspace (workspace presets, WorkspacePresets); never the state the stream starts with.
    var onWorkspaceSwitched: (String) -> Void = { _ in }
    /// A monitor shows another workspace than it did, with the one it showed before and that monitor's display UUID
    /// (Look › Wallpaper per workspace); never the monitors the stream starts with.
    var onWorkspaceShown: (_ workspace: String, _ previous: String?, _ displayUUID: String?) -> Void = { _, _, _ in }
    /// The tiler answered for the first time since it started: At login opens then.
    var onConnected: () -> Void = {}

    /// The other tiler's app runs (OtherTiler); a fake in tests.
    @ObservationIgnored private let otherTilerRunning: @MainActor () -> Bool

    init(engine: any TilerEngineRunning = InProcessTiler(), tip: @escaping @MainActor (String) -> Void = { HUD.tip($0) },
         otherTilerRunning: @escaping @MainActor () -> Bool = { OtherTiler.isRunning }) {
        self.engine = engine
        self.tip = tip
        self.otherTilerRunning = otherTilerRunning
    }

    var otherTilerIsRunning: Bool { otherTilerRunning() }

    /// What modules drive.
    var runner: any TilerRunning { engine }

    /// Every workspace's layout, kept by the engine, which builds them itself.
    func layoutsChanged(_ layouts: [String: WorkspaceLayout]) { engine.setLayouts(layouts) }

    /// Pilot's launch and Restart: its settings, `beforeStart` (the quiet rescue of windows a crash left off screen),
    /// then the engine's start and its event stream. While the other tiler still runs nothing happens but one tip, since
    /// its parked windows are hidden, not stranded, and two tilers would fight over every window; the start runs once
    /// that app has quit. Pilot never quits it; one launched later only tips. A running engine only gets its stream again.
    func startEngine(_ settings: @escaping @MainActor () -> TilerSettings, beforeStart: @escaping @MainActor () -> Void = {}) async {
        if otherTilerWatch == nil {
            otherTilerWatch = AppWatcher(OtherTiler.bundleId, launched: { [weak self] _ in
                wslog.notice("tiler: \(OtherTiler.name, privacy: .public) launched")
                self?.tip("\(OtherTiler.name) started: quit it, or the two tilers fight over every window")
            }, ended: { [weak self] in
                guard let self, !engine.isRunning else { return }
                Task { await self.startEngine(settings, beforeStart: beforeStart) }
            })
        }
        if engine.isRunning { return subscribe() }
        do {
            guard !otherTilerRunning() else { throw OtherTilerRunning() }
            try await engine.apply(settings())
            beforeStart()
            try await engine.start()
            subscribe()
        } catch is OtherTilerRunning {
            wslog.notice("tiler: \(OtherTiler.name, privacy: .public) is running, start waits for its quit")
            tip(String(describing: OtherTilerRunning()))
        } catch {
            wslog.error("tiler: start failed: \(String(describing: error), privacy: .public)")
            tip("Pilot's tiler did not start: \(error)")
        }
    }

    /// Pilot's quit: every window back on screen and the event stream ended.
    func stopEngine() {
        engine.stop()
        endSubscription()
    }

    private func subscribe() {
        endSubscription()
        let runner = runner
        subscription = Task { [weak self] in
            var connected = false
            for await event in runner.events() {
                guard let self, !Task.isCancelled else { return }
                if !connected { connected = true; onConnected() }
                if event.isWindowEvent { continue }
                guard event.workspace != focused || perMonitor.isEmpty else { continue }
                let switched = focused != nil && event.workspace != focused
                focused = event.workspace
                if switched, case .focusedWorkspaceChanged = event { onWorkspaceSwitched(event.workspace) }
                wslog.notice("workspace \(event.workspace, privacy: .public) focused")
                async let visible = runner.visibleWorkspaces()
                await refreshOccupied()
                if let visible = try? await visible, visible != perMonitor { perMonitor = visible }
            }
        }
    }

    private func endSubscription() {
        subscription?.cancel()
        subscription = nil
        focused = nil
        perMonitor = []
        occupied = []
    }

    /// The tiler answers its stream: a workspace is focused. Observable, unlike isRunning.
    var isAnswering: Bool { focused != nil }

    /// Goes to a workspace, from a click in the dropdown or on Home.
    func go(_ name: String, from caller: String) {
        Task { await perform("\(caller).workspace:\(name)") { try await $0.run(.workspace(name)) } }
    }

    #if DEBUG
    /// The renders' sample workspaces, without a running tiler; `windows` for Home's Now block, `focused` nil for the
    /// tiler not answering; `perMonitor` the workspace each display shows, when given.
    func seed(focused: String?, occupied: [OccupiedWorkspace], windows: [AeroWindow] = [], perMonitor: [AeroMonitorWorkspace]? = nil) {
        self.focused = focused
        self.occupied = occupied
        self.windows = windows
        workspaceMonitors = Self.monitors(windows)
        if let perMonitor { self.perMonitor = perMonitor }
    }
    #endif

    /// Each workspace's monitor, by its first window listed.
    static func monitors(_ windows: [AeroWindow]) -> [String: Int] {
        Dictionary(windows.map { ($0.workspace, $0.monitorId) }, uniquingKeysWith: { first, _ in first })
    }

    func refreshOccupied() async {
        guard focused != nil, let listed = try? await runner.windows(.all) else { return }
        if listed != windows { windows = listed }
        let monitors = Self.monitors(listed)
        if monitors != workspaceMonitors { workspaceMonitors = monitors }
        let list = OccupiedWorkspace.list(listed)
        if list != occupied { occupied = list }
    }

    var isRunning: Bool { engine.isRunning }

    /// Each workspace's monitor pin, set by WorkspaceMonitorStore, which owns them (N7).
    var pins: [String: MonitorPin] = [:]
    /// The workspaces kept, set by WorkspaceList, which owns the count: the own tiler's persistent ones, the Monitors rows,
    /// Home's cells and which go and move binds act.
    var workspaces = Workspaces.all

    /// The tiler's settings: Pilot's block, the workspaces kept and their monitor pins.
    func tilerSettings(_ block: PilotBlock) -> TilerSettings { TilerSettings(block: block, workspaces: workspaces, pins: pins) }

    /// The Pilot block, the pins or the workspaces kept changed (PilotBlockStore, WorkspaceMonitorStore, WorkspaceList):
    /// the tiler takes them at once.
    func settingsChanged(_ block: PilotBlock) async throws { try await engine.apply(tilerSettings(block)) }

    /// Home's and the dropdown's workspace cells: the kept ones up to the four their layouts hold, then any other in use.
    var homeCells: [OccupiedWorkspace] {
        HomeWorkspaces.cells(occupied, focused: focused, atLeast: HomeWorkspaces.drawn, kept: workspaces)
    }

    /// The focused window, only once it belongs to the frontmost app: a chained step never lands on whichever window
    /// the tiler happened to focus (spike test 3).
    func frontWindow(_ runner: any TilerRunning) async throws -> AeroWindow {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = try await runner.focusedWindow(ownedBy: front) else { throw FocusNotSettled() }
        return window
    }

    struct FocusNotSettled: Error, CustomStringConvertible {
        var description: String { "The tiler's focused window is not the frontmost app's, nothing done" }
    }

    /// Runs one tiler action and logs one public line: what, in how many milliseconds, or why not.
    func perform(_ id: String, _ body: @MainActor (any TilerRunning) async throws -> Void) async {
        let t0 = ContinuousClock.now
        do {
            try await body(runner)
            wslog.notice("\(id, privacy: .public) done, \(Int((ContinuousClock.now - t0) / .milliseconds(1)), privacy: .public) ms")
        } catch where !isRunning {
            notRunning(id)
        } catch {
            wslog.error("\(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Who tiles: what rescue, the not-running tip, Home and the bar's Workspaces name.
    var tilerName: String { PilotCore.tilerName }

    private func notRunning(_ id: String) {
        let what = "\(tilerName) is not running"
        wslog.error("\(id, privacy: .public): \(what, privacy: .public)")
        tip(what)
    }

    /// Lines for the observers dump.
    var lines: [String] {
        guard let focused else { return ["workspaces: \(tilerName) not running"] }
        return ["focused workspace: \(focused)"] + perMonitor.map { "monitor \($0.monitorName): workspace \($0.workspace)" }
    }
}
