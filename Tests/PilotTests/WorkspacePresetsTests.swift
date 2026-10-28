import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The editor's Save and Remove (card agent-bo-95422779) on a temporary store: nothing of Sven's is read or written, and
/// nothing reaches the tiler (no switch event is sent).
@MainActor
@Suite("Workspace presets store")
struct WorkspacePresetsTests {
    @Test("Save writes the preset and gives it to the workspace; Remove takes it off the workspace and keeps it to reuse")
    func saveAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspacePresetStore(url: dir.appending(path: "workspace-presets.json"))
        var saved: [(String, WorkspacePreset)] = []
        let presets = WorkspacePresets(observers: EngineObservers(), store: store)
        presets.onSave = { saved.append(($0, $1)); _ = $2 }
        let work = WorkspacePreset(name: "Work", apps: [.init(bundleId: "com.apple.finder", name: "Finder", percent: 100)], layout: nil)
        presets.save(work, to: "2")
        #expect(try store.load().preset(for: "2") == work)
        #expect(presets.contents.preset(for: "2") == work && presets.lastError == nil)
        #expect(saved.map(\.0) == ["2"])
        // A preset two workspaces share: saving it from one updates both layout rows.
        presets.save(work, to: "3")
        #expect(saved.map(\.0) == ["2", "2", "3"])
        presets.remove(from: "2")
        let read = try store.load()
        #expect(read.preset(for: "2") == nil && read.presets["Work"] == work)
    }

    @Test("A store file that does not decode is never overwritten: Save and Remove refuse and name the failure")
    func unreadableFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "workspace-presets.json")
        try Data("{ not json".utf8).write(to: url)
        let presets = WorkspacePresets(observers: EngineObservers(), store: WorkspacePresetStore(url: url))
        #expect(presets.lastError?.hasPrefix("workspace presets not read") == true)
        presets.save(WorkspacePreset(name: "Work", apps: [], layout: .columns), to: "2")
        presets.remove(from: "1")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
        #expect(presets.contents.preset(for: "2") == nil)
        #expect(presets.lastError?.hasPrefix("workspace preset not removed") == true)
    }

    @Test("A store that cannot be written keeps the old contents and names the failure")
    func failedSave() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "pilot-presets-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // A file where the store's folder should be: the write fails.
        let presets = WorkspacePresets(observers: EngineObservers(), store: WorkspacePresetStore(url: file.appending(path: "workspace-presets.json")))
        presets.save(WorkspacePreset(name: "Work", apps: [], layout: .columns), to: "2")
        #expect(presets.contents.preset(for: "2") == nil)
        #expect(presets.lastError?.hasPrefix("workspace preset not saved") == true)
    }

    @Test("Keep this layout reaches only the edited workspace's row; another workspace sharing the preset keeps its own auto")
    func keepLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = WorkspacePresets(observers: EngineObservers(), store: WorkspacePresetStore(url: dir.appending(path: "p.json")))
        var autos: [String: Bool?] = [:]
        presets.onSave = { workspace, _, auto in autos[workspace] = auto }
        let work = WorkspacePreset(name: "Work", apps: [.init(bundleId: "com.apple.finder", name: "Finder", percent: 100)], layout: .columns)
        presets.save(work, to: "2")
        presets.save(work, to: "3", keepLayout: false)
        #expect(autos["3"] == .some(false) && autos["2"] == .some(nil))
    }

    @Test("At login is used up only by a run that reached the tiler: a failed run is tried again, a done one never twice, a new session again")
    func loginSession() async throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspacePresetStore(url: dir.appending(path: "p.json"))
        var work = WorkspacePreset(name: "Work", apps: [.init(bundleId: "com.apple.finder", name: "Finder", percent: 100)], layout: .columns)
        work.apps[0].atLogin = true
        var contents = WorkspacePresetStore.Contents()
        contents.assign(work, to: "1")
        try store.save(contents)
        var session: Date? = Date(timeIntervalSince1970: 1_791_000_000)
        let presets = WorkspacePresets(observers: EngineObservers(), store: store, defaults: defaults, session: { session })
        var runs: [[String]] = []
        struct NotAnswering: Error {}
        await presets.openAtLogin { plan in runs.append(plan.map(\.bundleId)); throw NotAnswering() }
        await presets.openAtLogin { plan in runs.append(plan.map(\.bundleId)) }
        await presets.openAtLogin { plan in runs.append(plan.map(\.bundleId)) }
        #expect(runs == [["com.apple.finder"], ["com.apple.finder"]])
        // A Pilot restart in the same session: nothing.
        let again = WorkspacePresets(observers: EngineObservers(), store: store, defaults: defaults, session: { session })
        await again.openAtLogin { plan in runs.append(plan.map(\.bundleId)) }
        #expect(runs.count == 2)
        session = session?.addingTimeInterval(86_400)
        await again.openAtLogin { plan in runs.append(plan.map(\.bundleId)) }
        #expect(runs.count == 3)
        session = nil
        await again.openAtLogin { plan in runs.append(plan.map(\.bundleId)) }
        #expect(runs.count == 3)
    }
}
