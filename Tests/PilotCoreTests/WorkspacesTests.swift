import Testing
import Foundation
@testable import PilotCore

@Suite("Workspaces 1 to 9")
struct WorkspacesTests {
    @Test("The registry holds go, move and move-and-follow for workspaces 1 to 9, on Hyper+N, Hyper+Shift+N and Hyper+Alt+N")
    @MainActor func nineWorkspaces() throws {
        var ran: [String] = []
        var registry = ActionRegistry()
        try Workspaces.register(into: &registry, kept: { Workspaces.all }, go: { ran.append("go \($0)") },
                                move: { ran.append(($1 ? "follow " : "move ") + $0) })
        for n in 1...9 {
            #expect(registry.actions["workspaces.go:\(n)"]?.defaultKey == Key("\(n)"))
            #expect(registry.actions["workspaces.move:\(n)"]?.defaultKey == Key("\(n)", .shift))
            #expect(registry.actions["workspaces.moveFollow:\(n)"]?.defaultKey == Key("\(n)", .alt))
        }
        #expect(registry.actions["workspaces.go:10"] == nil && registry.actions["workspaces.go:0"] == nil)
        registry.actions["workspaces.go:9"]?.run()
        registry.actions["workspaces.move:2"]?.run()
        registry.actions["workspaces.moveFollow:3"]?.run()
        #expect(ran == ["go 9", "move 2", "follow 3"])
    }

    @Test("A removed workspace's go and move are inert: they only report it, and run again once it is added back")
    @MainActor func removedIsInert() throws {
        var ran: [String] = []
        var kept = Workspaces.names(6)
        var registry = ActionRegistry()
        try Workspaces.register(into: &registry, kept: { kept }, removed: { ran.append("removed \($0)") },
                                go: { ran.append("go \($0)") }, move: { name, _ in ran.append("move \(name)") })
        registry.actions["workspaces.go:7"]?.run()
        registry.actions["workspaces.move:9"]?.run()
        registry.actions["workspaces.moveFollow:8"]?.run()
        registry.actions["workspaces.go:6"]?.run()
        kept = Workspaces.names(7)
        registry.actions["workspaces.go:7"]?.run()
        #expect(ran == ["removed 7", "removed 9", "removed 8", "go 6", "go 7"])
    }

    @Test("The count: nine unsaved, kept between 1 and 9, its names counted from 1")
    func count() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(Workspaces.count(in: defaults) == 9)
        #expect(Workspaces.names(Workspaces.count(in: defaults)) == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        Workspaces.save(3, in: defaults)
        #expect(Workspaces.count(in: defaults) == 3 && Workspaces.names(3) == ["1", "2", "3"])
        Workspaces.save(0, in: defaults)
        #expect(Workspaces.count(in: defaults) == 1)
        Workspaces.save(12, in: defaults)
        #expect(Workspaces.count(in: defaults) == 9)
        defaults.set(-4, forKey: Workspaces.key)
        #expect(Workspaces.count(in: defaults) == 1)
    }

    @Test("Kept: the first count until a list is saved; Delete leaves a gap; a deleted one's windows go to the one before, else after")
    func kept() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(Workspaces.kept(in: defaults) == Workspaces.all)
        Workspaces.save(4, in: defaults)
        #expect(Workspaces.kept(in: defaults) == ["1", "2", "3", "4"])
        Workspaces.save(kept: ["4", "1", "3", "12"], in: defaults)
        #expect(Workspaces.kept(in: defaults) == ["1", "3", "4"] && Workspaces.count(in: defaults) == 3)
        #expect(Workspaces.neighbour(of: "3", in: ["1", "3", "4"]) == "1")
        #expect(Workspaces.neighbour(of: "1", in: ["1", "3", "4"]) == "3")
        #expect(Workspaces.neighbour(of: "4", in: ["1", "3", "4"]) == "3")
        #expect(Workspaces.neighbour(of: "1", in: ["1"]) == nil)
    }

    @Test("Deleting 3 of 1 to 5 closes its number: 4 becomes 3, 5 becomes 4, windows move lowest first, the deleted one's go before it; deleting 1 moves none of its own")
    func renumber() {
        let r = WorkspaceRenumber(deleting: "3", from: Workspaces.names(5))
        #expect(r.names == ["1", "2", "3", "4"] && r.renamed == ["1": "1", "2": "2", "4": "3", "5": "4"])
        #expect(r.moves == [.init(from: "3", to: "2"), .init(from: "4", to: "3"), .init(from: "5", to: "4")])
        #expect(r.new("4") == "3" && r.new("3") == "2" && r.new("1") == "1" && r.new("9") == "9")
        #expect(r.rekeyed(["1": "a", "3": "c", "4": "d", "5": "e", "8": "stale"]) == ["1": "a", "3": "d", "4": "e", "8": "stale"])
        #expect(r.rules([.init(appId: "x", workspace: "3"), .init(appId: "y", workspace: "5")])
                == [.init(appId: "x", workspace: "2"), .init(appId: "y", workspace: "4")])
        let first = WorkspaceRenumber(deleting: "1", from: Workspaces.names(3))
        #expect(first.moves == [.init(from: "2", to: "1"), .init(from: "3", to: "2")] && first.new("1") == "1")
        let gaps = WorkspaceRenumber(deleting: nil, from: ["1", "2", "4"])
        #expect(gaps.changes && gaps.moves == [.init(from: "4", to: "3")])
        #expect(!WorkspaceRenumber(deleting: nil, from: Workspaces.names(4)).changes)
    }

    @Test("Renumbered, a named preset and a snapshot follow their workspace; an unnamed preset takes its new number's name")
    func renumberData() throws {
        let r = WorkspaceRenumber(deleting: "2", from: Workspaces.names(4))
        let app = WorkspacePreset.App(bundleId: "a", name: "A", percent: 100)
        var contents = WorkspacePresetStore.Contents()
        contents.assign(WorkspacePreset(name: "Chat", apps: [app], layout: .columns), to: "2")
        contents.assign(WorkspacePreset(name: "Read", apps: [app], layout: .rows), to: "3")
        contents.assign(WorkspacePreset(name: "Workspace 4", apps: [app], layout: nil), to: "4")
        let next = contents.renumbered(r)
        #expect(next.workspaces == ["2": "Read", "3": "Workspace 3"])
        #expect(next.presets["Chat"] != nil, "the deleted one's named preset stays to reuse")
        #expect(next.presets["Workspace 4"] == nil && next.presets["Workspace 3"]?.layout == nil)
        let store = SnapshotStore(url: FileManager.default.temporaryDirectory.appending(path: "pilot-renumber-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: store.url) }
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        for workspace in ["2", "4"] { try store.save(Snapshot(workspace: workspace, layout: "h_tiles", savedAt: at, windows: [])) }
        let renumbered = try store.renumber(r)
        #expect(renumbered.keys.sorted() == ["3"] && renumbered["3"]?.workspace == "3")
        #expect(try store.load() == renumbered)
    }

    @Test("Only go and move past the count are removed; every other action, and a named workspace's, never is")
    func removedActions() {
        let kept = Workspaces.names(4)
        #expect(Workspaces.isRemoved(action: "workspaces.go:5", kept: kept))
        #expect(Workspaces.isRemoved(action: "workspaces.move:9", kept: kept))
        #expect(Workspaces.isRemoved(action: "workspaces.moveFollow:5", kept: kept))
        #expect(!Workspaces.isRemoved(action: "workspaces.moveFollow:4", kept: kept))
        #expect(!Workspaces.isRemoved(action: "workspaces.go:4", kept: kept))
        #expect(!Workspaces.isRemoved(action: "workspaces.next", kept: kept))
        #expect(!Workspaces.isRemoved(action: "windows.close", kept: kept))
        #expect(Workspaces.number(inAction: "workspaces.move:7") == "7" && Workspaces.number(inAction: "workspaces.toggleGaps") == nil)
    }

    @Test("Pilot default binds Hyper+1..9 to go to workspace N and Hyper+Shift+1..9 to move the window there")
    func pilotDefault() {
        for n in 1...9 {
            #expect(PilotDefault.binds["workspaces.go:\(n)"] == Key("\(n)"))
            #expect(PilotDefault.binds["workspaces.move:\(n)"] == Key("\(n)", .shift))
        }
        #expect(PilotDefault.binds["workspaces.go:0"] == nil)
    }

    @Test("Loaded as the Pilot preset, every number key goes and its Shift moves; none clashes")
    @MainActor func pilotPreset() throws {
        var registry = ActionRegistry()
        try Workspaces.register(into: &registry, kept: { Workspaces.all }, go: { _ in }, move: { _, _ in })
        let store = BindStore(presets: [.pilot: PilotDefault.binds], actions: Array(registry.actions.keys) + Array(PilotDefault.binds.keys))
        for n in 1...9 {
            #expect(store.action(for: Key("\(n)")) == "workspaces.go:\(n)")
            #expect(store.action(for: Key("\(n)", .shift)) == "workspaces.move:\(n)")
        }
    }
}
