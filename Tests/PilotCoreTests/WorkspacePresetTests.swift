import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// Workspace presets (story 108, card agent-bo-95422778): the store, and applying a preset on a switch against a fake
/// tiler and a fake app opener. Nothing here runs Pilot's real tiler or launches an app.
@Suite("Workspace presets")
@MainActor
struct WorkspacePresetTests {
    static func window(_ id: Int, _ app: String, workspace: String, layout: String = "h_tiles") -> AeroWindow {
        SnapshotTests.window(id, app, "\(app) \(id)", layout: layout, workspace: workspace)
    }

    static func app(_ name: String, _ percent: Int = 50) -> WorkspacePreset.App {
        WorkspacePreset.App(bundleId: "com.apple.\(name.lowercased())", name: name, percent: percent)
    }

    /// The tiler as the apply sees it: its window list, the focused workspace, and every command sent, an eval's
    /// commands kept as one entry.
    @MainActor final class FakeTiler: TilerRunning {
        var windows: [AeroWindow]
        var focused: String
        /// The tiler's focused window, and the workspace on the monitor under the pointer, for a layout rebuild
        /// (LayoutDropTests).
        var focusedWindow: Int?
        var mouseWorkspace: String?
        /// The workspaces on screen; by default the focused one and the pointer's.
        var visible: [String]?
        var sent: [AeroCommand] = []
        /// Runs once per command, after it is recorded: a test moves focus away mid-apply.
        var onCommand: (AeroCommand) -> Void = { _ in }

        init(windows: [AeroWindow], focused: String) { self.windows = windows; self.focused = focused }

        func events() -> AsyncStream<AeroEvent> { AsyncStream { $0.finish() } }

        func run(_ command: AeroCommand) async throws -> String {
            sent.append(command)
            defer { onCommand(command) }
            switch command {
            case .focusedWorkspace:
                return Self.json([["workspace": focused, "workspace-root-container-layout": "h_tiles"]])
            case .listVisibleWorkspaces:
                let shown = visible ?? Array(Set([focused, mouseWorkspace ?? focused])).sorted()
                return Self.json(shown.enumerated().map { ["workspace": $1, "monitor-id": $0 + 1, "monitor-name": "M\($0 + 1)"] })
            case .mouseWorkspace:
                return Self.json([["workspace": mouseWorkspace ?? focused, "workspace-root-container-layout": "h_tiles"]])
            case .listWindows(let scope):
                let listed = switch scope {
                case .all: windows
                case .workspace(let name): windows.filter { $0.workspace == name }
                case .focused: windows.filter { $0.id == focusedWindow }
                }
                return Self.json(listed.map { w in
                    ["window-id": w.id, "app-name": w.appName, "app-bundle-id": w.bundleId, "app-pid": Int(w.pid),
                     "workspace": w.workspace, "monitor-id": w.monitorId, "window-layout": w.layout, "window-title": w.title]
                })
            case .moveWindow(let id, let workspace, _):
                windows = windows.map { $0.id == id ? WorkspacePresetTests.window(id, $0.appName, workspace: workspace, layout: $0.layout) : $0 }
                return ""
            case .eval(let commands):
                for command in commands { _ = try await run(command) }
                sent.removeLast(commands.count)
                return ""
            default:
                return ""
            }
        }

        static func json(_ rows: [[String: Any]]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        }

        var evals: [[AeroCommand]] { sent.compactMap { if case .eval(let c) = $0 { c } else { nil } } }
        /// Window moves, sent alone or inside an eval.
        var moves: [AeroCommand] { (sent + evals.flatMap { $0 }).filter { if case .moveWindow = $0 { true } else { false } } }
    }

    /// Opens an app by adding its window, on `lands` (another workspace when an app rule sends it there), or never.
    @MainActor final class FakeOpener: AppOpening {
        var opened: [String] = []
        let tiler: FakeTiler
        var lands: String?
        var nextId = 900

        init(_ tiler: FakeTiler, lands: String?) { self.tiler = tiler; self.lands = lands }

        func open(bundle: String) -> Bool {
            opened.append(bundle)
            if let lands {
                let name = bundle.replacingOccurrences(of: "com.apple.", with: "").capitalized
                tiler.windows.append(WorkspacePresetTests.window(nextId, name, workspace: lands))
                nextId += 1
            }
            return true
        }
    }

    static let quick = WorkspacePresetApply.Timing(settle: .zero, poll: .milliseconds(1), launchWait: .milliseconds(40))

    static func apply(_ preset: WorkspacePreset, _ tiler: FakeTiler, _ opener: FakeOpener,
                      frames: @escaping @MainActor () -> [Int: CGRect] = { [:] }) async throws -> WorkspacePresetApply.Outcome {
        try await WorkspacePresetApply(preset: preset, workspace: "2", tiler: tiler, apps: opener, frames: frames, timing: quick).run()
    }

    @Test("An app with a window on the workspace stays, one with a window elsewhere is moved in by id, a missing one is opened; nothing opens for an app that has any window")
    func presentElsewhereMissing() async throws {
        let tiler = FakeTiler(windows: [Self.window(10, "Finder", workspace: "2"), Self.window(11, "TextEdit", workspace: "1"),
                                                Self.window(12, "Finder", workspace: "3")], focused: "2")
        let opener = FakeOpener(tiler, lands: "2")
        let preset = WorkspacePreset(name: "Work", apps: [Self.app("Finder"), Self.app("TextEdit"), Self.app("Notes")], layout: .columns)
        let outcome = try await Self.apply(preset, tiler, opener)
        #expect(opener.opened == ["com.apple.notes"])
        #expect(tiler.moves == [.moveWindow(id: 11, toWorkspace: "2")])
        #expect(outcome.opened == ["com.apple.notes"] && outcome.pulled == 1 && outcome.missing.isEmpty)
        // Window 12, Finder's second window, stays where it is: one window per app.
        #expect(tiler.windows.first { $0.id == 12 }?.workspace == "3")
        // The ready layout, preset apps first in list order: Finder 10, TextEdit 11, Notes 900.
        #expect(tiler.evals.last == LayoutPreset.columns.commands(workspace: "2", windows: [10, 11, 900]))
    }

    @Test("A running app's window that opens on another workspace (an app rule) is moved in once it appears")
    func openedElsewhere() async throws {
        let tiler = FakeTiler(windows: [], focused: "2")
        let opener = FakeOpener(tiler, lands: "1")
        let preset = WorkspacePreset(name: "Notes", apps: [Self.app("Notes")], layout: .columns)
        _ = try await Self.apply(preset, tiler, opener)
        #expect(tiler.moves == [.moveWindow(id: 900, toWorkspace: "2")])
    }

    @Test("Two opened apps whose windows land elsewhere in the same poll are moved in by one eval, after one focus check")
    func twoOpenedElsewhere() async throws {
        let tiler = FakeTiler(windows: [], focused: "2")
        let opener = FakeOpener(tiler, lands: "1")
        let preset = WorkspacePreset(name: "Two", apps: [Self.app("Notes"), Self.app("Mail")], layout: .columns)
        _ = try await Self.apply(preset, tiler, opener)
        #expect(tiler.evals.first == [.moveWindow(id: 900, toWorkspace: "2"), .moveWindow(id: 901, toWorkspace: "2")])
        // Focus checked at the start, before the moves, and before the layout: nothing is sent alone between them.
        #expect(tiler.sent.filter { if case .focusedWorkspace = $0 { true } else { false } }.count == 3)
        #expect(!tiler.sent.contains { if case .moveWindow = $0 { true } else { false } })
    }

    @Test("An app whose window never shows within the wait is reported missing, and the others are still laid out")
    func neverShows() async throws {
        let tiler = FakeTiler(windows: [Self.window(10, "Finder", workspace: "2")], focused: "2")
        let opener = FakeOpener(tiler, lands: nil)
        let preset = WorkspacePreset(name: "Work", apps: [Self.app("Finder"), Self.app("Notes")], layout: .rows)
        let outcome = try await Self.apply(preset, tiler, opener)
        #expect(outcome.missing == ["com.apple.notes"])
        #expect(tiler.evals.last == LayoutPreset.rows.commands(workspace: "2", windows: [10]))
    }

    @Test("Other tiles on the workspace follow the preset's apps; a floating preset window is tiled, another floating window stays")
    func othersAndFloating() async throws {
        let tiler = FakeTiler(windows: [Self.window(20, "Ghostty", workspace: "2"), Self.window(10, "Finder", workspace: "2", layout: "floating"),
                                                Self.window(30, "Zen", workspace: "2", layout: "floating")], focused: "2")
        let opener = FakeOpener(tiler, lands: "2")
        let preset = WorkspacePreset(name: "Work", apps: [Self.app("Finder")], layout: .mainStack)
        _ = try await Self.apply(preset, tiler, opener)
        #expect(tiler.evals.last == [.setFloating(id: 10, false)] + LayoutPreset.mainStack.commands(workspace: "2", windows: [10, 20]))
        #expect(opener.opened.isEmpty)
    }

    @Test("Focus moving off the workspace stops the apply before it lays anything out")
    func focusLeaves() async throws {
        let tiler = FakeTiler(windows: [Self.window(11, "TextEdit", workspace: "1")], focused: "2")
        tiler.onCommand = { if case .moveWindow = $0 { tiler.focused = "3" } }
        let opener = FakeOpener(tiler, lands: "2")
        let preset = WorkspacePreset(name: "Work", apps: [Self.app("TextEdit")], layout: .columns)
        await #expect(throws: WorkspacePresetApply.LeftWorkspace.self) { try await Self.apply(preset, tiler, opener) }
        // The move went; no layout followed it.
        #expect(tiler.evals == [[.moveWindow(id: 11, toWorkspace: "2")]])
        // Not focused from the start: nothing at all.
        let elsewhere = FakeTiler(windows: [Self.window(11, "TextEdit", workspace: "1")], focused: "1")
        await #expect(throws: WorkspacePresetApply.LeftWorkspace.self) { try await Self.apply(preset, elsewhere, FakeOpener(elsewhere, lands: "2")) }
        #expect(elsewhere.sent == [.focusedWorkspace])
    }

    @Test("Own sizes 70/30 on a 2000 pt workspace: tiles in order at equal sizes first, then resizes that land at 1400 and 600 within 2 pt")
    func ownSizes() async throws {
        let tiler = FakeTiler(windows: [Self.window(11, "TextEdit", workspace: "2"), Self.window(10, "Finder", workspace: "2")], focused: "2")
        let opener = FakeOpener(tiler, lands: "2")
        let preset = WorkspacePreset(name: "Work", apps: [Self.app("Finder", 70), Self.app("TextEdit", 30)], layout: nil)
        // After the first eval the tiler shows them in order at equal slots, gap 10.
        var model = SnapshotTests.AeroModel(order: [10, 11], weights: [10: 1000, 11: 1000])
        _ = try await Self.apply(preset, tiler, opener, frames: { model.frames() })
        try #require(tiler.evals.count == 2)
        #expect(tiler.evals[0] == LayoutPreset.columns.commands(workspace: "2", windows: [10, 11]))
        model.apply(tiler.evals[1])
        #expect(abs(model.weights[10]! - 1400) <= 2 && abs(model.weights[11]! - 600) <= 2, "\(model.weights)")
    }

    @Test("Own sizes with a third tile the preset does not know: it keeps its slot, the preset's apps share the rest 70/30")
    func ownSizesWithOther() async throws {
        let tiler = FakeTiler(windows: [Self.window(10, "Finder", workspace: "2"), Self.window(11, "TextEdit", workspace: "2"),
                                                Self.window(20, "Ghostty", workspace: "2")], focused: "2")
        let preset = WorkspacePreset(name: "Work", apps: [Self.app("Finder", 70), Self.app("TextEdit", 30)], layout: nil)
        var model = SnapshotTests.AeroModel(order: [10, 11, 20], weights: [10: 600, 11: 600, 20: 600])
        _ = try await Self.apply(preset, tiler, FakeOpener(tiler, lands: "2"), frames: { model.frames() })
        try #require(tiler.evals.count == 2)
        model.apply(tiler.evals[1])
        #expect(abs(model.weights[20]! - 600) <= 2 && abs(model.weights[10]! - 840) <= 2 && abs(model.weights[11]! - 360) <= 2, "\(model.weights)")
    }

    @Test("An app listed twice is laid out once")
    func duplicateApp() async throws {
        let tiler = FakeTiler(windows: [Self.window(10, "Finder", workspace: "2")], focused: "2")
        let opener = FakeOpener(tiler, lands: "2")
        _ = try await Self.apply(WorkspacePreset(name: "x", apps: [Self.app("Finder"), Self.app("Finder")], layout: .columns), tiler, opener)
        #expect(opener.opened.isEmpty && tiler.evals.last == LayoutPreset.columns.commands(workspace: "2", windows: [10]))
    }

    @Test("The store keeps presets by name and each workspace's preset; a file that does not decode throws, so no save wipes it")
    func store() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-presets-\(UUID().uuidString)/workspace-presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspacePresetStore(url: url)
        #expect(try store.load() == WorkspacePresetStore.Contents())
        let work = WorkspacePreset(name: "Work", apps: [Self.app("Finder", 70), Self.app("TextEdit", 30)], layout: nil)
        var contents = WorkspacePresetStore.Contents()
        contents.assign(work, to: "2")
        try store.save(contents)
        let read = try store.load()
        #expect(read.preset(for: "2") == work && read.preset(for: "1") == nil)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
