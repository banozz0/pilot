import AppKit
import Foundation
import PilotCore
import PilotTiler
import Testing
@testable import Pilot

/// Workspaces 1 to 9 (Sven 2026-10-09): the count Pilot keeps, its monitor pins and the tiler's settings, on a fake
/// engine and a defaults suite of the test's own, so nothing reaches a real tiler.
@MainActor
@Suite("Workspace list")
struct WorkspaceListTests {
    /// Workspace `holder` (9 unless a test says) holds windows 31 and 32; every command is recorded.
    final class FakeTiler: TilerEngineRunning {
        var holder = "9"
        var commands: [AeroCommand] = []
        var applied: [TilerSettings] = []
        var isRunning = true

        func run(_ command: AeroCommand) async throws -> String {
            commands.append(command)
            guard case .listWindows(.workspace(holder)) = command else { return "[]" }
            return "[" + [31, 32].map { #"{"window-id": \#($0), "app-name": "Zen", "app-bundle-id": "app.zen-browser.zen", "app-pid": 1, "workspace": "\#(holder)", "monitor-id": 1, "window-layout": "h_tiles", "window-title": "Tab"}"# }
                .joined(separator: ", ") + "]"
        }

        func events() -> AsyncStream<AeroEvent> { AsyncStream { $0.finish() } }
        func apply(_ settings: TilerSettings) async throws { applied.append(settings) }
        func setLayouts(_ layouts: [String: WorkspaceLayout]) {}
        func arrange(_ workspace: String, as preset: LayoutPreset) async throws {}
        func start() async throws {}
        func stop() {}
    }

    struct Setup {
        let engine: FakeTiler
        let tiler: TilerService
        let block: PilotBlockStore
        let monitors: WorkspaceMonitorStore
        let list: WorkspaceList
        let defaults: UserDefaults

        /// What the own tiler should hold: the block, `workspaces` kept, the pins as they stand.
        @MainActor func expected(_ workspaces: [String]) -> TilerSettings { TilerSettings(block: block.block, workspaces: workspaces, pins: monitors.pins) }
    }

    /// Sven's pins as N7 left them (1 and 2 on Main, 3 and 4 on the LG), saved before the list first reads them.
    static func setup(count: Int? = nil) -> Setup {
        let defaults = UserDefaults(suiteName: testSuite())!
        let lg = MonitorPin.display(name: "LG ULTRAFINE", id: "B")
        WorkspaceMonitors.save(["1": .main, "2": .main, "3": lg, "4": lg], in: defaults)
        if let count { Workspaces.save(count, in: defaults) }
        let engine = FakeTiler()
        let tiler = TilerService(engine: engine, tip: { _ in })
        let block = PilotBlockStore(tiler: tiler, defaults: defaults)
        let monitors = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)
        return Setup(engine: engine, tiler: tiler, block: block, monitors: monitors,
                     list: WorkspaceList(tiler: tiler, block: block, monitors: monitors, defaults: defaults), defaults: defaults)
    }

    func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("First launch: nine workspaces, 5 to 9 new on Main, the user's 1 to 4 pins kept, all saved; the tiler keeps the nine")
    func firstLaunch() {
        let s = Self.setup()
        #expect(s.list.names == Workspaces.all)
        #expect(Workspaces.count(in: s.defaults) == 9)
        #expect(s.monitors.workspaces == Workspaces.all)
        let lg = MonitorPin.display(name: "LG ULTRAFINE", id: "B")
        #expect(s.monitors.pins == ["1": .main, "2": .main, "3": lg, "4": lg, "5": .main, "6": .main, "7": .main, "8": .main, "9": .main])
        #expect(WorkspaceMonitors.pins(in: s.defaults, carryingFrom: "", displays: []) == s.monitors.pins)
        #expect(s.tiler.tilerSettings(s.block.block) == s.expected(Workspaces.all))
        #expect(s.tiler.tilerSettings(s.block.block) != s.expected(Workspaces.names(4)))
    }

    @Test("A count saved before is read back, and nothing is pinned again: Any stays Any")
    func savedCount() {
        let s = Self.setup(count: 6)
        #expect(s.list.names == ["1", "2", "3", "4", "5", "6"])
        #expect(s.monitors.pins["5"] == nil)
        #expect(s.tiler.homeCells.map(\.name) == ["1", "2", "3", "4"])
    }

    @Test("Remove takes the last: its windows move to the one before, it is shown if it was focused, its pin goes, the tiler drops it")
    func remove() async throws {
        let s = Self.setup()
        s.tiler.seed(focused: "9", occupied: [OccupiedWorkspace(name: "9", apps: ["Zen"])])
        s.list.remove()
        #expect(s.list.names == Workspaces.names(8) && Workspaces.count(in: s.defaults) == 8)
        #expect(s.monitors.pins["9"] == nil && s.monitors.workspaces == Workspaces.names(8))
        try await settle { s.engine.commands.contains(.workspace("8")) && !s.engine.applied.isEmpty }
        #expect(s.engine.applied.count == 1, "one apply, after the windows moved")
        #expect(s.engine.commands == [.listWindows(.workspace("9")), .moveWindow(id: 31, toWorkspace: "8"), .moveWindow(id: 32, toWorkspace: "8"), .workspace("8")])
        #expect(s.engine.applied.allSatisfy { $0 == s.expected(Workspaces.names(8)) })
    }

    @Test("Delete takes the picked one and closes its number (Q233): 4 becomes 3 and 5 becomes 4 with their pins, app rules, presets and layouts; the windows move down and the one on screen follows; Add appends")
    func deleteRenumbers() async throws {
        let s = Self.setup(count: 5)
        let observers = EngineObservers(tiler: s.tiler)
        let file = FileManager.default.temporaryDirectory.appending(path: "pilot-renumber-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let presets = WorkspacePresets(observers: observers, store: WorkspacePresetStore(url: file), defaults: s.defaults)
        let layouts = WorkspaceLayouts(observers: observers, defaults: s.defaults)
        s.list.follow(presets: presets, layouts: layouts, snapshots: nil)
        let read = WorkspacePreset(name: "Read", apps: [.init(bundleId: "a", name: "A", percent: 100)], layout: .rows)
        presets.save(read, to: "4")
        layouts.set("4", WorkspaceLayout(preset: .rows, auto: false))
        await withCheckedContinuation { done in
            s.block.edit({ $0.rules = [.init(appId: "a", workspace: "3"), .init(appId: "b", workspace: "4"), .init(appId: "c", workspace: "1")] }) { _ in done.resume() }
        }
        s.engine.holder = "4"
        s.tiler.seed(focused: "4", occupied: [OccupiedWorkspace(name: "4", apps: ["Zen"])])
        s.engine.commands = []

        s.list.remove("3")
        #expect(s.list.names == Workspaces.names(4) && Workspaces.count(in: s.defaults) == 4)
        let lg = MonitorPin.display(name: "LG ULTRAFINE", id: "B")
        #expect(s.monitors.pins == ["1": .main, "2": .main, "3": lg], "old 4's pin is 3's, old 5 had none")
        #expect(presets.contents.workspaces == ["3": "Read"] && presets.contents.name(for: "3") == "Read")
        #expect(layouts.layout("3") == WorkspaceLayout(preset: .rows, auto: false) && layouts.layouts["4"] == nil)
        try await settle { s.engine.commands.contains(.workspace("3")) && s.block.block.rules.first?.workspace == "2" }
        #expect(s.block.block.rules == [.init(appId: "a", workspace: "2"), .init(appId: "b", workspace: "3"), .init(appId: "c", workspace: "1")],
                "the deleted one's app goes where its windows went")
        #expect(s.engine.commands.filter { if case .listWindows = $0 { false } else { true } }
                == [.moveWindow(id: 31, toWorkspace: "3"), .moveWindow(id: 32, toWorkspace: "3"), .workspace("3")])
        #expect(s.engine.commands.contains(.listWindows(.workspace("5"))), "5's windows move to 4")
        #expect(s.list.add() == "5" && s.monitors.pins["5"] == .main, "Add appends, on Main")
    }

    @Test("A list an older build left with a gap closes up, its pins following")
    func closeGaps() {
        let s = Self.setup()
        Workspaces.save(kept: ["1", "2", "4"], in: s.defaults)
        let list = WorkspaceList(tiler: s.tiler, block: s.block, monitors: s.monitors, defaults: s.defaults)
        #expect(list.names == ["1", "2", "4"])
        list.closeGaps()
        #expect(list.names == ["1", "2", "3"] && Workspaces.kept(in: s.defaults) == ["1", "2", "3"])
        #expect(s.monitors.pins["3"] == .display(name: "LG ULTRAFINE", id: "B") && s.monitors.pins["4"] == nil)
    }

    @Test("Never fewer than one: removing down to one, Remove does nothing more; Home draws that one cell")
    func floor() {
        let s = Self.setup(count: 2)
        s.list.remove()
        #expect(s.list.names == ["1"] && !s.list.canRemove && s.list.canAdd)
        s.list.remove()
        #expect(s.list.names == ["1"] && Workspaces.count(in: s.defaults) == 1)
        #expect(s.tiler.homeCells.map(\.name) == ["1"])
    }

    @Test("Add makes the next number on Main, never past nine; one added back after a remove is new again")
    func add() async throws {
        let s = Self.setup(count: 3)
        s.list.add()
        #expect(s.list.names == Workspaces.names(4) && s.monitors.pins["4"] == .display(name: "LG ULTRAFINE", id: "B"), "a pinned one keeps its pin")
        s.list.remove()
        s.list.add()
        #expect(s.monitors.pins["4"] == .main)
        for _ in 0..<10 { s.list.add() }
        #expect(s.list.names == Workspaces.all && !s.list.canAdd && Workspaces.count(in: s.defaults) == 9)
        try await settle { s.engine.applied.last == s.expected(Workspaces.all) }
        #expect(s.engine.applied.last == s.expected(Workspaces.all))
    }
}
