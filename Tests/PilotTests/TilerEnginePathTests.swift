import AppKit
import Foundation
import PilotCore
import PilotTiler
import Testing
@testable import Pilot

/// Card agent-bo-95422997, AC4, and R3 (2026-10-10): every bind Pilot sends goes to its tiler, and the Pilot block's
/// settings reach it. A fake engine, so nothing reaches a real tiler.
@MainActor
@Suite("Tiler engine path")
struct TilerEnginePathTests {
    final class FakeEngine: TilerEngineRunning {
        var commands: [AeroCommand] = []
        var applied: [TilerSettings] = []
        var layouts: [[String: WorkspaceLayout]] = []
        var arranged: [String] = []
        var isRunning = true
        /// Apply, start and the caller's own steps, in the order they ran.
        var order: [String] = []

        func run(_ command: AeroCommand) async throws -> String {
            commands.append(command)
            guard case .listWindows = command, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return "" }
            return #"[{"window-id": 7, "app-name": "Finder", "app-bundle-id": "com.apple.finder", "app-pid": \#(pid), "workspace": "1", "monitor-id": 1, "window-layout": "h_tiles", "window-title": "Test"}]"#
        }

        func events() -> AsyncStream<AeroEvent> { AsyncStream { $0.finish() } }
        func apply(_ settings: TilerSettings) async throws { applied.append(settings); order.append("apply") }
        func setLayouts(_ layouts: [String: WorkspaceLayout]) { self.layouts.append(layouts) }
        func arrange(_ workspace: String, as preset: LayoutPreset) async throws { arranged.append("\(workspace):\(preset.rawValue)") }
        func start() async throws { isRunning = true; order.append("start") }
        func stop() { isRunning = false }
    }

    /// The service on a fake engine; its not-running tip goes to `tip`, never a real HUD on the screen of whoever runs the
    /// suite (lane 1 saw a not-running tip on 2026-10-08).
    func service(_ engine: FakeEngine, tip: @escaping @MainActor (String) -> Void = { _ in },
                 otherTilerRunning: @escaping @MainActor () -> Bool = { false }) -> TilerService {
        TilerService(engine: engine, tip: tip, otherTilerRunning: otherTilerRunning)
    }

    /// R3 (2026-10-10), Moody REJECT ZXrfPhrk_1I: while the old tiler runs, its parked windows are hidden, not stranded, so
    /// neither the rescue nor the engine runs, and one tip says why; once it has quit, settings go in, the rescue runs,
    /// then the engine starts. A start on a running engine changes nothing.
    @Test("The start waits while the old tiler runs, then applies the settings, rescues and starts, in that order")
    func startWaitsForTheOldTiler() async {
        let engine = FakeEngine()
        engine.isRunning = false
        var tips: [String] = [], oldTilerRunning = true
        let tiler = service(engine, tip: { tips.append($0) }, otherTilerRunning: { oldTilerRunning })
        let settings: @MainActor @Sendable () -> TilerSettings = { TilerSettings(block: PilotBlock(), pins: [:]) }
        await tiler.startEngine(settings, beforeStart: { engine.order.append("rescue") })
        #expect(engine.order.isEmpty && !engine.isRunning)
        #expect(tips == ["AeroSpace is running: quit it and Pilot's tiler starts"])
        oldTilerRunning = false
        await tiler.startEngine(settings, beforeStart: { engine.order.append("rescue") })
        #expect(engine.order == ["apply", "rescue", "start"] && engine.isRunning)
        #expect(engine.applied == [settings()])
        await tiler.startEngine(settings, beforeStart: { engine.order.append("rescue") })
        #expect(engine.order == ["apply", "rescue", "start"], "a running engine is left as it is")
        #expect(tips.count == 1)
    }



    /// Runs bind `id` and waits until the engine has seen `count` commands, or two seconds pass.
    func press(_ id: String, _ registry: ActionRegistry, _ engine: FakeEngine, until count: Int) async throws {
        try #require(registry.actions[id]).run()
        let deadline = ContinuousClock.now + .seconds(2)
        while engine.commands.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Focus, focus display, workspace go and next run through the engine")
    func withoutWindow() async throws {
        let engine = FakeEngine()
        let tiler = service(engine)
        #expect(tiler.runner is FakeEngine)
        #expect(tiler.isRunning)
        let observers = EngineObservers(tiler: tiler)
        var registry = ActionRegistry()
        WindowsModule.register(into: &registry, observers: observers)
        WorkspacesModule.register(into: &registry, tiler: tiler, block: PilotBlockStore(tiler: tiler),
                                  layouts: WorkspaceLayouts(observers: observers))
        try await press("workspaces.go:2", registry, engine, until: 1)
        try await press("workspaces.next", registry, engine, until: 2)
        #expect(engine.commands == [.workspace("2"), .workspaceNext])
        engine.commands = []
        // A window bind asks for the front window first (list-windows --focused), then runs its command.
        try await press("windows.focusLeft", registry, engine, until: 2)
        try await press("windows.focusDisplayRight", registry, engine, until: 4)
        #expect(engine.commands.filter { if case .listWindows = $0 { false } else { true } } == [.focus(.left), .focusMonitor(.right)])
    }

    @Test("Swap, join and move to display aim at the front window through the engine")
    func withWindow() async throws {
        try #require(NSWorkspace.shared.frontmostApplication != nil)
        let engine = FakeEngine()
        var registry = ActionRegistry()
        WindowsModule.register(into: &registry, observers: EngineObservers(tiler: service(engine)))
        for id in ["windows.swapLeft", "windows.joinRight", "windows.sendToDisplayLeft"] {
            let before = engine.commands.count
            try await press(id, registry, engine, until: before + 2)
        }
        let sent = engine.commands.filter { if case .listWindows = $0 { false } else { true } }
        #expect(sent == [.swap(id: 7, .left), .joinWith(id: 7, .right), .moveToMonitor(id: 7, .left)])
    }

    @Test("Layouts reach the engine, and a picked preset is built there, not through commands")
    func layouts() async throws {
        let engine = FakeEngine()
        let layouts = WorkspaceLayouts(observers: EngineObservers(tiler: service(engine)), defaults: UserDefaults(suiteName: testSuite())!)
        layouts.set("2", WorkspaceLayout(preset: .grid, auto: true))
        let deadline = ContinuousClock.now + .seconds(1)
        while engine.arranged.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.layouts.last == ["2": WorkspaceLayout(preset: .grid, auto: true)])
        #expect(engine.arranged == ["2:grid"])
        #expect(engine.commands.isEmpty)
    }

    @Test("A block change hands the engine its settings, with the monitor pins")
    func settings() async throws {
        let engine = FakeEngine()
        let tiler = service(engine)
        var block = PilotBlock()
        block.gaps.inner = 12
        tiler.pins = ["1": .display(name: "CU34G4Z", id: "A")]
        try await tiler.settingsChanged(block)
        #expect(engine.applied == [TilerSettings(block: block, pins: ["1": .display(name: "CU34G4Z", id: "A")])])
        #expect(engine.commands.isEmpty)
    }

    @Test("A monitor pin change reaches the engine")
    func pins() async throws {
        let engine = FakeEngine()
        let tiler = service(engine)
        let defaults = UserDefaults(suiteName: testSuite())!
        let block = PilotBlockStore(tiler: tiler, defaults: defaults)
        let store = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)
        store.set(.main, for: "1")
        let deadline = ContinuousClock.now + .seconds(2)
        while engine.applied.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.pins["1"] == .main)
        #expect(engine.applied == [TilerSettings(block: block.block, pins: store.pins)])
        #expect(engine.commands.isEmpty)
    }
}
