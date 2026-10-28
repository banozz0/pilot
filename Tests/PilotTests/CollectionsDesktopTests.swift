import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot list|add|remove` on the desktop's and the bar's lists, plus `snapshot` and `bar` (AI helper T8): every change
/// read back from the store object its page binds to, on throwaway defaults, a temporary presets file, the test run's
/// own Pilot folder for snapshots, a fake tiler, fake screens and a throwaway wallpaper folder. Nothing of Sven's is written
/// (wallpaper reset counts ~/Pictures/Wallpapers, read only), the running Pilot is never touched, no restore runs and no
/// wallpaper is set: the verbs are asked through the registry the socket answers from.
@MainActor
@Suite("Collections: desktop and bar")
struct CollectionsDesktopTests {
    @MainActor final class Rig {
        let engine = WorkspaceListTests.FakeTiler()
        let tiler: TilerService
        let defaults: UserDefaults
        let presetsFile = FileManager.default.temporaryDirectory.appending(path: "pilot-t8-\(UUID().uuidString)/workspace-presets.json")
        let presets: WorkspacePresets
        let layouts: WorkspaceLayouts
        let block: PilotBlockStore
        let monitors: WorkspaceMonitorStore
        let snapshots: WorkspaceSnapshots
        let list: WorkspaceList
        let bar: BarItemsStore
        let wallpaper: WallpaperSettings
        /// Two images in a throwaway folder, the wallpaper cycle's only source.
        let pictures = FileManager.default.temporaryDirectory.appending(path: "pilot-w19-\(UUID().uuidString)")
        let verbs = ControlVerbs()
        /// Every workspace a restore was asked for, "" for the focused one.
        var restored: [String] = []
        /// The HUD's tip as the readbacks see it: a fake, so no tip is ever shown.
        var tip: (id: ObjectIdentifier, text: String)?
        /// Two screens; a step records what it was asked and moves the screen's wallpaper on, as WallpaperSwitch would.
        var screens: [WallpaperControl.Screen] = []
        var steps: [(forward: Bool, ids: [UInt32]?)] = []
        /// What the Allow gate was asked, and its answer.
        var asked: [ControlGate.Ask] = []
        var allow = true

        /// `snapshot` is saved in the run's Pilot folder before the stores read it.
        init(snapshot: Snapshot? = nil) throws {
            defaults = try #require(UserDefaults(suiteName: testSuite()))
            // Saved first, so no store carries anything over from an AeroSpace config.
            defaults.set(try JSONEncoder().encode(PilotBlock()), forKey: "pilotBlock")
            WorkspaceMonitors.save([:], in: defaults)
            // All nine kept already, so the list pins none of them on Main as a first launch would.
            Workspaces.save(kept: Workspaces.all, in: defaults)
            if let snapshot { try SnapshotStore.standard.save(snapshot) }
            tiler = TilerService(engine: engine, tip: { _ in })
            let observers = EngineObservers(tiler: tiler)
            presets = WorkspacePresets(observers: observers, store: WorkspacePresetStore(url: presetsFile), defaults: defaults)
            layouts = WorkspaceLayouts(observers: observers, defaults: defaults)
            block = PilotBlockStore(tiler: tiler, defaults: defaults) { _ in [:] }
            monitors = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)
            snapshots = WorkspaceSnapshots(observers: observers, defaults: defaults)
            snapshots.reopenApps = false
            list = WorkspaceList(tiler: tiler, block: block, monitors: monitors, defaults: defaults)
            // As the engine wires it, but the snapshots file every test shares is left alone.
            list.follow(presets: presets, layouts: layouts, snapshots: nil)
            bar = BarItemsStore(defaults: defaults) { [:] }
            wallpaper = WallpaperSettings(defaults: defaults)
            // As the engine wires it: a save sets the workspace's layout row, with Keep this layout.
            presets.onSave = { [layouts] workspace, preset, auto in layouts.set(workspace, layouts.layout(workspace).saving(preset, auto: auto)) }
            var lists = DesktopLists(presets: presets, layouts: layouts, block: block, monitors: monitors, snapshots: snapshots, tiler: tiler, list: list)
            lists.displays = { [ConnectedDisplay(name: "LG ULTRAFINE", id: "B")] }
            lists.save = { [unowned self, snapshots] in
                snapshots.save()
                say("Workspace 3 saved: 2 windows")
            }
            lists.restore = { [unowned self] in
                restored.append($0 ?? "")
                say("Workspace \($0 ?? "1") restored")
            }
            let readback = RunReadback(wait: .milliseconds(200), every: .milliseconds(10), tip: { [unowned self] in tip })
            lists.readback = readback
            lists.restoreReadback = readback
            verbs.registerDesktop({ lists }, bar: { [bar] in bar })

            try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            for name in ["a.jpg", "b.jpg", "notes.txt"] { FileManager.default.createFile(atPath: pictures.appending(path: name).path, contents: Data()) }
            wallpaper.reset()
            wallpaper.add([pictures])
            wallpaper.remove(WallpaperCycle.standardFolder.path)
            screens = [.init(id: 1, name: "Built-in Retina Display", shape: .landscape, current: pictures.appending(path: "a.jpg")),
                       .init(id: 7, name: "LG ULTRAFINE", shape: .landscape, current: nil)]
            verbs.registerWallpaper(WallpaperControl(settings: wallpaper, screens: { [unowned self] in screens }, step: { [unowned self] forward, ids in
                steps.append((forward, ids))
                for i in screens.indices where ids?.contains(screens[i].id) ?? true {
                    screens[i] = .init(id: screens[i].id, name: screens[i].name, shape: .landscape, current: pictures.appending(path: "b.jpg"))
                }
                say("b · 2 of 2")
            }, readback: readback, gate: ControlGate { [unowned self] ask, _ in
                asked.append(ask)
                return allow
            }, pictures: pictures))
        }

        deinit {
            try? FileManager.default.removeItem(at: presetsFile.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pictures)
        }

        /// A new tip, as HUD.tip would raise it.
        func say(_ text: String) {
            let raised = Tip()
            raisedTips.append(raised)
            tip = (ObjectIdentifier(raised), text)
        }
        private final class Tip {}
        private var raisedTips: [Tip] = []

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }

        /// The answer's result; a failure is recorded with its message.
        func ok(_ verb: String, _ args: String..., sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue? {
            let answer = await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
            #expect(answer.ok, "\(verb) \(args.joined(separator: " ")): \(answer.error?.message ?? "")", sourceLocation: sourceLocation)
            return answer.result
        }

        func rows(_ collection: String) async -> [JSONValue] {
            guard case .array(let rows)? = await ok("list", collection) else { return [] }
            return rows
        }
    }

    static func field(_ row: JSONValue, _ name: String) -> JSONValue? {
        guard case .object(let fields) = row else { return nil }
        return fields[name]
    }

    @Test("Every desktop and bar list is registered, with its fields in schema")
    func registered() async throws {
        let rig = try Rig()
        guard case .array(let all)? = await rig.ok("list") else { Issue.record("list answered no array"); return }
        let names = all.compactMap { Self.field($0, "name") }
        // Each row says which field remove names (W1).
        let keys = ["workspace-presets": "workspace", "app-rules": "app", "column-rules": "app", "float-apps": "app", "float-titles": "title", "monitor-pins": "workspace",
                    "layouts": "workspace", "snapshots": "workspace", "workspaces": "workspace", "saved-presets": "name",
                    "wallpaper-sources": "path", "wallpaper-screens": "screen"]
        for name in keys.keys.sorted() + ["bar-items"] { #expect(names.contains(.string(name)), "\(name) not listed") }
        for (name, key) in keys { #expect(try Self.field(rig.verbs.schema(collection: name), "rowKey") == .string(key), "\(name)") }
        #expect(rig.verbs.verbs["snapshot"] != nil && rig.verbs.verbs["bar"] != nil && rig.verbs.verbs["wallpaper"] != nil)
        // The verbs declare their flags, so a typo is refused rather than dropped.
        #expect(await rig.ask("snapshot", "save", "--all").error?.code == .unknownFlag)
        #expect(await rig.ask("wallpaper", "next", "--screens", "LG").error?.code == .unknownFlag)
    }

    @Test("Workspace presets: add saves through the store the editor saves with, list reads it, remove takes it off the workspace")
    func workspacePresets() async throws {
        let rig = try Rig()
        let row = await rig.ok("add", "workspace-presets", "--workspace", "3", "--apps", "com.apple.finder,com.apple.TextEdit",
                               "--name", "Write", "--layout", "own", "--percents", "60,40", "--open-missing", "off")
        #expect(row.flatMap { Self.field($0, "name") } == .string("Write"))
        let saved = try #require(rig.presets.contents.preset(for: "3"))
        #expect(saved.apps.map(\.bundleId) == ["com.apple.finder", "com.apple.TextEdit"] && saved.apps.map(\.percent) == [60, 40])
        #expect(saved.layout == nil && !saved.openMissing)
        #expect(try WorkspacePresetStore(url: rig.presetsFile).load().preset(for: "3") == saved)
        #expect(await rig.rows("workspace-presets").map { Self.field($0, "workspace") } == [.string("3")])

        // A ready layout needs no sizes; a draft the editor would refuse is refused with its words.
        _ = await rig.ok("add", "workspace-presets", "--workspace", "4", "--apps", "com.apple.finder", "--layout", "grid")
        #expect(rig.presets.contents.preset(for: "4")?.layout == .grid)
        #expect(await rig.ask("add", "workspace-presets", "--workspace", "5", "--apps", "com.apple.finder,com.apple.TextEdit",
                              "--layout", "own", "--percents", "50,20").error?.code == .badValue)
        #expect(await rig.ask("add", "workspace-presets", "--workspace", "5", "--apps", "com.example.no-such-app").error?.message.contains("com.example.no-such-app") == true)
        let missing = await rig.ask("add", "workspace-presets", "--workspace", "5")
        #expect(missing.error?.code == .badValue && missing.error?.message.contains("--apps") == true)

        _ = await rig.ok("remove", "workspace-presets", "3")
        #expect(rig.presets.contents.preset(for: "3") == nil && rig.presets.contents.presets["Write"] != nil)
        #expect(await rig.rows("workspace-presets").map { Self.field($0, "workspace") } == [.string("4")])
        #expect(await rig.ask("remove", "workspace-presets", "3").error?.code == .badValue)
    }

    @Test("App rules, float apps and float titles: each change reaches the Pilot block the tiler is handed, and is saved")
    func blockLists() async throws {
        let rig = try Rig()
        _ = await rig.ok("add", "app-rules", "--app", "com.mitchellh.ghostty", "--workspace", "2")
        _ = await rig.ok("add", "app-rules", "--app", "com.mitchellh.ghostty", "--workspace", "4")
        #expect(rig.block.block.rules == [.init(appId: "com.mitchellh.ghostty", workspace: "4")])
        #expect(await rig.rows("app-rules") == [.object(["app": .string("com.mitchellh.ghostty"), "workspace": .string("4")])])
        #expect(await rig.ask("add", "app-rules", "--app", "com.mitchellh.ghostty").error?.message.contains("--workspace") == true)

        // Column rules (spec scrolling-layout T11): one per app, a width or focus off, through the same block.
        _ = await rig.ok("add", "column-rules", "--app", "com.mitchellh.ghostty", "--width", "1/3")
        _ = await rig.ok("add", "column-rules", "--app", "com.mitchellh.ghostty", "--width", "2/3", "--focus", "off")
        #expect(rig.block.block.scrolling.apps == [.init(appId: "com.mitchellh.ghostty", width: .twoThirds, focus: false)])
        #expect(await rig.rows("column-rules") == [.object(["app": .string("com.mitchellh.ghostty"), "width": .string("2/3"), "focus": .bool(false)])])
        #expect(await rig.ask("add", "column-rules", "--app", "com.apple.finder").error?.code == .badValue, "a rule that changes nothing")
        #expect(await rig.ask("add", "column-rules", "--app", "com.apple.finder", "--width", "5/6").error?.code == .badValue)
        _ = await rig.ok("remove", "column-rules", "com.mitchellh.ghostty")
        #expect(await rig.rows("column-rules").isEmpty)

        _ = await rig.ok("add", "float-apps", "--app", "com.apple.finder")
        _ = await rig.ok("add", "float-titles", "--title", "Google Accounts")
        #expect(rig.block.block.floatAppIds == ["com.apple.finder"] && rig.block.block.floatTitles == ["Google Accounts"])
        #expect(await rig.rows("float-apps") == [.object(["app": .string("com.apple.finder")])])
        #expect(await rig.rows("float-titles") == [.string("Google Accounts")])
        // What the tiler was handed last holds them, and so do the saved settings.
        #expect(rig.engine.applied.last == rig.tiler.tilerSettings(rig.block.block))
        let saved = try JSONDecoder().decode(PilotBlock.self, from: try #require(rig.defaults.data(forKey: "pilotBlock")))
        #expect(saved == rig.block.block)

        _ = await rig.ok("remove", "app-rules", "com.mitchellh.ghostty")
        _ = await rig.ok("remove", "float-apps", "com.apple.finder")
        _ = await rig.ok("remove", "float-titles", "Google Accounts")
        #expect(rig.block.block == PilotBlock())
        for list in ["app-rules", "float-apps", "float-titles"] { #expect(await rig.rows(list).isEmpty, "\(list) not empty") }
        #expect(await rig.ask("remove", "float-titles", "Google Accounts").error?.code == .badValue)
    }

    @Test("Monitor pins and layouts: set through the stores the Tiling and Workspaces pages bind to; remove gives Any and None")
    func pinsAndLayouts() async throws {
        let rig = try Rig()
        _ = await rig.ok("add", "monitor-pins", "--workspace", "3", "--monitor", "lg ultrafine")
        _ = await rig.ok("add", "monitor-pins", "--workspace", "4", "--monitor", "main")
        #expect(rig.monitors.pins == ["3": .display(name: "LG ULTRAFINE", id: "B"), "4": .main])
        #expect(WorkspaceMonitors.pins(in: rig.defaults, carryingFrom: "", displays: []) == rig.monitors.pins)
        let three = await rig.rows("monitor-pins").first { Self.field($0, "workspace") == .string("3") }
        #expect(three.flatMap { Self.field($0, "monitor") } == .string("LG ULTRAFINE"))
        let unknown = await rig.ask("add", "monitor-pins", "--workspace", "3", "--monitor", "Studio Display")
        #expect(unknown.error?.code == .badValue && unknown.error?.message.contains("LG ULTRAFINE") == true)
        _ = await rig.ok("remove", "monitor-pins", "3")
        #expect(rig.monitors.pins == ["4": .main])
        // Only the workspaces Pilot keeps, as the pages list them.
        #expect(await rig.ask("add", "monitor-pins", "--workspace", "foo", "--monitor", "main").error?.code == .badValue)

        _ = await rig.ok("add", "layouts", "--workspace", "2", "--layout", "mainStack", "--auto", "on")
        #expect(rig.layouts.layout("2") == WorkspaceLayout(preset: .mainStack, auto: true))
        #expect(WorkspaceLayout.load(rig.defaults)["2"] == WorkspaceLayout(preset: .mainStack, auto: true))
        #expect(await rig.rows("layouts") == [.object(["workspace": .string("2"), "layout": .string("mainStack"), "auto": .bool(true)])])
        #expect(await rig.ask("add", "layouts", "--workspace", "2", "--layout", "spiral").error?.code == .badValue)
        _ = await rig.ok("remove", "layouts", "2")
        #expect(rig.layouts.layout("2") == .unset)
        #expect(await rig.rows("layouts").isEmpty)
        // Auto keeps a layout, so none has none; a workspace with a preset takes its layout from the preset.
        _ = await rig.ok("add", "layouts", "--workspace", "2", "--layout", "none", "--auto", "on")
        #expect(rig.layouts.layout("2") == WorkspaceLayout(preset: nil, auto: false))
        _ = await rig.ok("add", "workspace-presets", "--workspace", "6", "--apps", "com.apple.finder")
        #expect(await rig.ask("add", "layouts", "--workspace", "6", "--layout", "rows").error?.message.contains("preset") == true)
    }

    @Test("Snapshots: list reads the saved ones, save runs the Save snapshot action on the tiler, restore hands the workspace to Restore, remove deletes")
    func snapshots() async throws {
        let workspace = "t8-\(UUID().uuidString.prefix(8))"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(Snapshot.self, from: Data(#"""
            {"workspace": "\#(workspace)", "layout": "h_tiles", "savedAt": "2026-10-11T09:00:00Z", "windows": [{"bundleId": "com.apple.finder",
             "appName": "Finder", "title": "Home", "floating": false, "frame": [[0, 0], [800, 600]]}]}
            """#.utf8))
        let rig = try Rig(snapshot: saved)
        let row = await rig.rows("snapshots").first { Self.field($0, "workspace") == .string(workspace) }
        #expect(row.flatMap { Self.field($0, "windows") } == .array([.string("Finder 'Home'")]))

        let save = await rig.ok("snapshot", "save")
        #expect(save.flatMap { Self.field($0, "hud") } == .string("Workspace 3 saved: 2 windows"))
        // The action's own run asks the tiler for the focused workspace; the fake names none, so nothing is written.
        let deadline = ContinuousClock.now + .seconds(2)
        while !rig.engine.commands.contains(.focusedWorkspace), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.engine.commands.contains(.focusedWorkspace))

        let restore = await rig.ok("snapshot", "restore", workspace)
        #expect(restore.flatMap { Self.field($0, "hud") } == .string("Workspace \(workspace) restored"))
        _ = await rig.ok("snapshot", "restore")
        #expect(rig.restored == [workspace, ""])
        #expect(await rig.ask("snapshot", "restore", "no-such-workspace").error?.code == .badValue)
        #expect(await rig.ask("snapshot", "take").error?.code == .badRequest)
        #expect(await rig.ask("add", "snapshots").error?.code == .badValue)

        _ = await rig.ok("remove", "snapshots", workspace)
        let left = try SnapshotStore.standard.load()
        #expect(rig.snapshots.saved[workspace] == nil && left[workspace] == nil)
        #expect(await rig.ask("remove", "snapshots", workspace).error?.code == .badValue)
    }

    @Test("Workspace presets: add changes the saved preset as the editor does, keeping what is left out; From a preset and shared names")
    func workspacePresetEdits() async throws {
        let rig = try Rig()
        let finder = "com.apple.finder", text = "com.apple.TextEdit"
        let row = await rig.ok("add", "workspace-presets", "--workspace", "3", "--apps", "\(finder),\(text)", "--name", "Write",
                               "--layout", "columns", "--keep-layout", "off", "--at-login", text)
        #expect(row.flatMap { Self.field($0, "keepLayout") } == .bool(false))
        #expect(rig.presets.contents.preset(for: "3")?.apps.map(\.atLogin) == [false, true])
        #expect(rig.layouts.layout("3") == WorkspaceLayout(preset: .columns, auto: false))

        // A change of layout alone keeps the apps, their At login, the name and Keep this layout.
        _ = await rig.ok("add", "workspace-presets", "--workspace", "3", "--layout", "rows")
        var saved = try #require(rig.presets.contents.preset(for: "3"))
        #expect(saved.name == "Write" && saved.layout == .rows && saved.apps.map(\.atLogin) == [false, true])
        #expect(rig.layouts.layout("3") == WorkspaceLayout(preset: .rows, auto: false))
        _ = await rig.ok("add", "workspace-presets", "--workspace", "3", "--keep-layout", "on")
        #expect(rig.layouts.layout("3").auto)

        // --apps is the whole list in order: a reorder keeps each app's size and At login.
        _ = await rig.ok("add", "workspace-presets", "--workspace", "3", "--layout", "own", "--percents", "70,30")
        _ = await rig.ok("add", "workspace-presets", "--workspace", "3", "--apps", "\(text),\(finder)")
        saved = try #require(rig.presets.contents.preset(for: "3"))
        #expect(saved.apps.map(\.bundleId) == [text, finder] && saved.apps.map(\.percent) == [30, 70] && saved.apps.map(\.atLogin) == [true, false])
        _ = await rig.ok("add", "workspace-presets", "--workspace", "3", "--at-login", "none")
        #expect(rig.presets.contents.preset(for: "3")?.apps.allSatisfy { !$0.atLogin } == true)
        let stray = await rig.ask("add", "workspace-presets", "--workspace", "3", "--at-login", "com.apple.Safari")
        #expect(stray.error?.code == .badValue && stray.error?.message.contains("com.apple.Safari") == true)

        // From a preset: workspace 4 takes Write; the two share it by name, and both rows say so.
        let shared = await rig.ok("add", "workspace-presets", "--workspace", "4", "--preset", "Write")
        #expect(shared.flatMap { Self.field($0, "sharedWith") } == .array([.string("3")]))
        #expect(rig.presets.contents.preset(for: "4") == rig.presets.contents.preset(for: "3"))
        #expect(await rig.ask("add", "workspace-presets", "--workspace", "4", "--preset", "Nope").error?.message.contains("Write") == true)
        #expect(await rig.ask("add", "workspace-presets", "--workspace", "4", "--colour", "red").error?.code == .unknownFlag)

        // A preset taken off every workspace stays saved, as the page keeps it to reuse.
        _ = await rig.ok("remove", "workspace-presets", "3")
        _ = await rig.ok("remove", "workspace-presets", "4")
        let kept = await rig.rows("saved-presets")
        #expect(kept.map { Self.field($0, "name") } == [.string("Write")])
        #expect(kept.first.flatMap { Self.field($0, "workspaces") } == .array([]))
        #expect(await rig.ask("remove", "saved-presets", "Write").error?.code == .badValue)
    }

    @Test("Workspaces: each kept workspace with its name, on screen, its apps, preset and snapshot, as the page reads them; add and remove as Add and Delete")
    func workspaces() async throws {
        let rig = try Rig()
        func row(_ name: String) async -> JSONValue? { await rig.rows("workspaces").first { Self.field($0, "workspace") == .string(name) } }
        // The tiler not answering: focused is unknown, as the page's state line is blank.
        #expect(await row("2").flatMap { Self.field($0, "focused") } == .null)
        rig.tiler.seed(focused: "2", occupied: [OccupiedWorkspace(name: "2", apps: ["Finder", "Ghostty"])])
        _ = await rig.ok("add", "workspace-presets", "--workspace", "2", "--apps", "com.apple.finder", "--name", "Files")
        let two = try #require(await row("2"))
        #expect(Self.field(two, "focused") == .bool(true) && Self.field(two, "preset") == .string("Files") && Self.field(two, "name") == .string("Files"))
        #expect(Self.field(two, "apps") == .array([.string("Finder"), .string("Ghostty")]) && Self.field(two, "snapshot") == .null)
        #expect(await row("3").flatMap { Self.field($0, "focused") } == .bool(false))
        #expect(await row("3").flatMap { Self.field($0, "name") } == .null, "no name of its own")
        // Delete takes the one named and closes its number (Q233): Files, on 2, is 1 now; Add appends; nine is the most.
        #expect(await rig.ask("add", "workspaces").error?.code == .badValue)
        #expect(await rig.ok("remove", "workspaces", "1") == .string("1"))
        #expect(rig.list.names == Workspaces.names(8))
        #expect(await row("9") == nil)
        #expect(await row("1").flatMap { Self.field($0, "name") } == .string("Files"))
        #expect(await rig.ask("remove", "workspaces", "9").error?.code == .badValue)
        #expect(await rig.ok("add", "workspaces").flatMap { Self.field($0, "workspace") } == .string("9"))
        #expect(rig.list.names == Workspaces.all)
    }

    @Test("Wallpaper: sources list, add and remove through the block's store, screens read their place and Next, steps and shuffle")
    func wallpaper() async throws {
        let rig = try Rig()
        let folder = rig.pictures.path
        #expect(await rig.rows("wallpaper-sources") == [.object(["path": .string(folder), "name": .string(WallpaperBlock.chipName(folder)),
                                                                 "kind": .string("folder"), "images": .number(2)])])
        // Inside the Pictures folder (the rig's) nothing asks.
        let image = rig.pictures.appending(path: "a.jpg").path
        let added = await rig.ok("add", "wallpaper-sources", "--path", image)
        #expect(added.flatMap { Self.field($0, "kind") } == .string("image") && rig.wallpaper.sources == [folder, image])
        #expect(await rig.ask("add", "wallpaper-sources", "--path", rig.pictures.appending(path: "notes.txt").path).error?.code == .badValue)
        #expect(await rig.ask("add", "wallpaper-sources", "--path", "relative/folder").error?.code == .badValue)
        #expect(rig.asked.isEmpty)
        #expect(try Self.field(rig.verbs.schema(collection: "wallpaper-sources"), "asks") == .array([.string("add")]))
        _ = await rig.ok("remove", "wallpaper-sources", image)
        #expect(rig.wallpaper.sources == [folder])
        #expect(await rig.ask("remove", "wallpaper-sources", image).error?.code == .badValue)

        // Outside it, a folder, a link out of it and a path not there each ask, naming the folder, before anything looks;
        // a deny reads and keeps nothing.
        let outside = FileManager.default.temporaryDirectory.appending(path: "pilot-w19-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: rig.pictures.appending(path: "link"), withDestinationURL: outside)
        rig.allow = false
        let denied = await rig.ask("add", "wallpaper-sources", "--path", outside.path)
        #expect(denied.error?.code == .denied && rig.asked.last?.title == "Add wallpaper folder")
        #expect(rig.asked.last?.detail.contains(outside.lastPathComponent) == true && rig.wallpaper.sources == [folder])
        #expect(await rig.ask("add", "wallpaper-sources", "--path", rig.pictures.appending(path: "link").path).error?.code == .denied)
        #expect(await rig.ask("add", "wallpaper-sources", "--path", "\(outside.path)/missing.jpg").error?.code == .denied)
        #expect(rig.asked.count == 3 && rig.asked.last?.title == "Add wallpaper image")
        rig.allow = true
        _ = await rig.ok("add", "wallpaper-sources", "--path", outside.path)
        #expect(rig.wallpaper.sources == [folder, outside.path] && rig.asked.count == 4)
        #expect(await rig.ask("add", "wallpaper-sources", "--path", "\(outside.path)/missing").error?.code == .badValue)
        _ = await rig.ok("remove", "wallpaper-sources", outside.path)
        #expect(rig.wallpaper.sources == [folder])

        let screens = await rig.rows("wallpaper-screens")
        #expect(screens.map { Self.field($0, "screen") } == [.string("Built-in Retina Display"), .string("LG ULTRAFINE")])
        #expect(screens.first.flatMap { Self.field($0, "place") } == .number(1) && screens.first.flatMap { Self.field($0, "count") } == .number(2))
        // The folder's listing names /private/var, the temporary directory /var.
        #expect(screens.first.flatMap { Self.field($0, "next") } == .string("/private" + rig.pictures.appending(path: "b.jpg").path))
        #expect(screens.last.flatMap { Self.field($0, "detail") } == .string("No wallpaper file"))
        #expect(await rig.ask("remove", "wallpaper-screens", "LG ULTRAFINE").error?.code == .badValue)

        // Next on one screen by name or id, or on the scope's screens with none named; the tip and the rows after come back.
        let next = await rig.ok("wallpaper", "next", "--screen", "lg ultrafine")
        #expect(next.flatMap { Self.field($0, "hud") } == .string("b · 2 of 2"))
        #expect(rig.steps.last?.forward == true && rig.steps.last?.ids == [7])
        guard case .array(let after)? = next.flatMap({ Self.field($0, "screens") }) else { Issue.record("no screens"); return }
        #expect(Self.field(after[1], "place") == .number(2))
        _ = await rig.ok("wallpaper", "previous", "--screen", "1")
        _ = await rig.ok("wallpaper", "previous")
        #expect(rig.steps.map(\.forward) == [true, false, false] && rig.steps.map(\.ids) == [[7], [1], nil])
        #expect(await rig.ask("wallpaper", "next", "--screen", "Studio Display").error?.message.contains("LG ULTRAFINE") == true)
        #expect(await rig.ask("wallpaper", "shuffle", "--screen", "1").error?.code == .unknownFlag)
        #expect(await rig.ask("wallpaper", "spin").error?.code == .badRequest)

        // Shuffle again only while shuffled, as the block shows the button; it changes the seed.
        #expect(await rig.ask("wallpaper", "shuffle").error?.code == .badValue)
        rig.wallpaper.order = .shuffle
        let seed = rig.wallpaper.seed
        _ = await rig.ok("wallpaper", "shuffle")
        #expect(rig.wallpaper.seed != seed)

        guard case .array(let reset)? = await rig.ok("wallpaper", "reset") else { Issue.record("reset answered no rows"); return }
        #expect(rig.wallpaper.isStandard && reset.map { Self.field($0, "path") } == [.string(WallpaperCycle.standardFolder.path)])
    }

    @Test("Wallpaper per screen: --screen adds, removes and resets a screen's own folders; its row counts against its own list")
    func wallpaperPerScreen() async throws {
        let rig = try Rig()
        let own = rig.pictures.appending(path: "own")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: own.appending(path: "c.jpg").path, contents: Data())
        rig.screens[1] = .init(id: 7, name: "LG ULTRAFINE", shape: .landscape, current: own.appending(path: "c.jpg"), displayUUID: "UUID-LG")
        rig.wallpaper.folders = .perScreen
        _ = await rig.ok("add", "wallpaper-sources", "--path", own.path, "--screen", "lg ultrafine")
        // Kept with its links resolved, then standardized as every source is.
        let kept = try #require(WallpaperControl.real(own.path).map { URL(filePath: $0).standardizedFileURL.path })
        #expect(rig.wallpaper.ownSources("UUID-LG") == [kept] && rig.wallpaper.sources == [rig.pictures.path])
        // No lasting id, no folders of its own.
        #expect(await rig.ask("add", "wallpaper-sources", "--path", own.path, "--screen", "1").error?.code == .badValue)
        #expect(await rig.ask("add", "wallpaper-sources", "--path", own.path, "--screen", "Studio Display").error?.code == .badValue)

        // The shared folder holds three images (own/c.jpg among them), LG's own one.
        let rows = await rig.rows("wallpaper-screens")
        #expect(rows.first.flatMap { Self.field($0, "count") } == .number(3) && rows.last.flatMap { Self.field($0, "count") } == .number(1))
        #expect(rows.last.flatMap { Self.field($0, "ownSources") } == .array([.string(kept)]))
        #expect(rows.first.flatMap { Self.field($0, "ownSources") } == .array([]))
        rig.wallpaper.folders = .shared
        #expect(await rig.rows("wallpaper-screens").last.flatMap { Self.field($0, "count") } == .number(3), "shared mode: every screen on the shared list")

        #expect(await rig.ask("remove", "wallpaper-sources", rig.pictures.path, "--screen", "LG ULTRAFINE").error?.code == .badValue)
        _ = await rig.ok("remove", "wallpaper-sources", kept, "--screen", "LG ULTRAFINE")
        #expect(rig.wallpaper.ownSources("UUID-LG").isEmpty && rig.wallpaper.sources == [rig.pictures.path])
        rig.wallpaper.add([own], display: "UUID-LG")
        _ = await rig.ok("wallpaper", "reset", "--screen", "7")
        #expect(rig.wallpaper.screenSources.isEmpty && rig.wallpaper.sources == [rig.pictures.path], "a screen's reset leaves the shared ones")
    }

    @Test("Bar items: add, move, remove and the spacer change the store both bars draw from, as pilot://bar does")
    func barItems() async throws {
        let rig = try Rig()
        if rig.bar.settings.entry(.battery).on { _ = await rig.ok("remove", "bar-items", "battery") }
        #expect(await !rig.rows("bar-items").contains { Self.field($0, "item") == .string("battery") })

        let added = await rig.ok("add", "bar-items", "--item", "battery", "--side", "right", "--index", "0")
        #expect(added.flatMap { Self.field($0, "side") } == .string("right"))
        #expect(rig.bar.settings.entry(.battery).on && rig.bar.settings.entry(.battery).side == .right)
        #expect(rig.bar.settings.slots(in: .topBar, topBarOn: true, side: .right).first?.kind == .battery)
        #expect(await rig.rows("bar-items").contains { Self.field($0, "item") == .string("battery") })
        // Saved, as a page change is.
        let saved = try JSONDecoder().decode(BarSettings.self, from: try #require(rig.defaults.data(forKey: BarItemsStore.key)))
        #expect(saved == rig.bar.settings)

        _ = await rig.ok("bar", "move", "battery", "--side", "left")
        #expect(rig.bar.settings.entry(.battery).side == .left)

        _ = await rig.ok("bar", "spacer", "120")
        #expect(rig.bar.settings.entry(.spacer).width == 120)
        _ = await rig.ok("bar", "spacer", "reset")
        #expect(rig.bar.settings.entry(.spacer).width == nil)
        #expect(await rig.ask("bar", "spacer", "9000").error?.code == .outOfRange)

        _ = await rig.ok("remove", "bar-items", "battery")
        #expect(!rig.bar.settings.entry(.battery).on)
        #expect(await !rig.rows("bar-items").contains { Self.field($0, "item") == .string("battery") })
        #expect(await rig.ask("remove", "bar-items", "pilot").error?.message.contains("pinned") == true)
        #expect(await rig.ask("add", "bar-items", "--item", "toaster").error?.code == .badValue)
        #expect(await rig.ask("add", "bar-items").error?.message.contains("--item") == true)
    }
}
