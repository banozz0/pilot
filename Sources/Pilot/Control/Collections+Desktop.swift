import Foundation
import PilotCore

/// The desktop's lists (AI helper T8): workspace presets, app rules, floats, monitor pins, layouts and snapshots, each
/// read and changed through the store its Settings page binds to, so the page shows a change at once and the tiler gets
/// it as a page edit gives it. ~/.aerospace.toml stays an import and is never written.
@MainActor
struct DesktopLists {
    let presets: WorkspacePresets
    let layouts: WorkspaceLayouts
    let block: PilotBlockStore
    let monitors: WorkspaceMonitorStore
    let snapshots: WorkspaceSnapshots
    /// Which workspaces are kept, for `pilot add workspaces` and `pilot remove workspaces <n>`; nil where a test leaves it out.
    var list: WorkspaceList?
    /// The focused workspace and the ones with windows, as the Workspaces page state reads them.
    let tiler: TilerService
    /// The displays a pin may name.
    var displays: @MainActor () -> [ConnectedDisplay] = { ConnectedDisplay.current }
    /// The Save snapshot action's run.
    var save: @MainActor () -> Void
    /// The workspace a restore puts back, the focused one for nil: the Restore snapshot action's run.
    var restore: @MainActor (String?) -> Void
    /// The tips a save raises; a restore is watched longer, since it switches, places and settles first.
    var readback = RunReadback()
    var restoreReadback = RunReadback(wait: .seconds(3))

    init(presets: WorkspacePresets, layouts: WorkspaceLayouts, block: PilotBlockStore, monitors: WorkspaceMonitorStore,
         snapshots: WorkspaceSnapshots, tiler: TilerService, list: WorkspaceList? = nil) {
        self.presets = presets; self.layouts = layouts; self.block = block; self.monitors = monitors; self.snapshots = snapshots
        self.tiler = tiler; self.list = list
        save = { snapshots.save() }
        restore = { snapshots.restore($0) }
    }

    /// The engine's stores; nil until the engine is up.
    static var live: DesktopLists? {
        Engine.shared.map { DesktopLists(presets: $0.presets, layouts: $0.layouts, block: $0.pilotBlock, monitors: $0.workspaceMonitors,
                                         snapshots: $0.snapshots, tiler: $0.observers.tiler, list: $0.workspaceList) }
    }

    /// One of the workspaces Pilot keeps, the ones the pages list.
    func workspace(_ word: String?) throws(ControlError) -> String {
        guard let word, monitors.workspaces.contains(word) else {
            throw ControlError(.badValue, "no workspace \(word ?? ""); Pilot keeps \(monitors.workspaces.joined(separator: ", "))")
        }
        return word
    }

    /// The kept workspaces' list, which Add and Delete change.
    func kept() throws(ControlError) -> WorkspaceList {
        guard let list else { throw ControlError(.badRequest, "Pilot's workspaces are not loaded yet; ask again in a moment") }
        return list
    }

    /// A workspace whose layout row is its own: one with a preset takes its layout from the preset, as the page shows it.
    func layoutOnly(_ word: String?) throws(ControlError) -> String {
        let workspace = try workspace(word)
        if presets.contents.preset(for: workspace) != nil {
            throw ControlError(.badValue, "workspace \(workspace) has a preset; its layout is the preset's --layout (pilot add workspace-presets)")
        }
        return workspace
    }

    /// One Pilot block change as its page makes it, answered once the tiler took it; a refused one is taken back.
    func edit(_ change: @escaping @MainActor (inout PilotBlock) -> Void) async throws(ControlError) {
        let written = await withCheckedContinuation { done in block.edit(change) { done.resume(returning: $0) } }
        if !written { throw ControlError(.badValue, "not applied: \(block.lastError ?? "the tiler refused it")") }
    }
}

extension ControlVerbs {
    /// The desktop's and the bar's lists, plus `snapshot` and `bar`, the two verbs whose changes are not a row added or
    /// removed. Stores are looked up on each request, so the socket may start before the engine.
    func registerDesktop(_ desktop: @escaping @Sendable @MainActor () -> DesktopLists? = { .live },
                         bar: @escaping @Sendable @MainActor () -> BarItemsStore = { .shared }) {
        let lists: @Sendable @MainActor () throws(ControlError) -> DesktopLists = {
            guard let lists = desktop() else { throw ControlError(.badRequest, "Pilot's workspaces are not loaded yet; ask again in a moment") }
            return lists
        }
        registerPresets(lists)
        registerBlockLists(lists)
        registerPinsAndLayouts(lists)
        registerSnapshots(lists)
        registerBar(bar)
    }

    private func registerPresets(_ lists: @escaping @Sendable @MainActor () throws(ControlError) -> DesktopLists) {
        register(ControlCollection(
            "workspaces", help: "Each workspace Pilot keeps: its name, whether it is on screen, the apps with windows on it, its preset and snapshot "
                + "(Workspaces). add makes the next number, as the page's Add does; remove <n> deletes that one as Delete does: its windows move to the one before it, and each one after it moves down a number with its name, preset, layout, snapshot, app rules, monitor and windows.",
            rowKey: "workspace",
            list: { () throws(ControlError) in
                let lists = try lists()
                return .array(lists.monitors.workspaces.map { Self.row(workspace: $0, lists: lists) })
            },
            add: { _ throws(ControlError) in
                let lists = try lists()
                guard let added = try lists.kept().add() else { throw ControlError(.badValue, "Pilot keeps all nine workspaces already, one per number key") }
                return Self.row(workspace: added, lists: lists)
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let list = try lists.kept()
                let workspace = try lists.workspace(try args.word(0, "workspace"))
                guard list.canRemove else { throw ControlError(.badValue, "workspace \(workspace) is the last one; at least one stays") }
                list.remove(workspace)
                return .string(workspace)
            }))
        register(ControlCollection(
            "saved-presets", help: "Every saved preset, given to a workspace or kept to reuse, as From a preset… lists them (Workspaces); read-only.",
            rowKey: "name",
            list: { () throws(ControlError) in
                let contents = try lists().presets.contents
                return .array(contents.presets.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { preset in
                    var row = Self.fields(preset)
                    row["workspaces"] = .array(contents.workspaces(using: preset.name).map(JSONValue.string))
                    return .object(row)
                })
            }))
        register(ControlCollection(
            "workspace-presets",
            help: "The apps each workspace opens and lays out when switched to (Workspaces). add changes the workspace's preset as the editor does: "
                + "what is left out stays. Presets are kept by name, so saving under the name another workspace's preset has changes that one too (sharedWith).",
            fields: [.init("workspace", help: "the workspace, as 3"),
                     .init("apps", help: "bundle ids, comma separated, in order: the whole list; sizes split evenly again when an app comes or goes (the preset's apps)", required: false),
                     .init("preset", help: "start from this saved preset, as From a preset… does (pilot list saved-presets)", required: false),
                     .init("name", help: "the preset's name (the preset's; Workspace <n> for a new one)", required: false),
                     .init("layout", help: "\(Self.cases(LayoutPreset.self)) or own (side by side at --percents) (the preset's; the workspace's own layout, else columns, for a new one)", required: false),
                     .init("percents", help: "own sizes, comma separated, adding up to 100", required: false),
                     .init("open-missing", help: "on opens apps with no window yet, off only pulls running ones in (the preset's; on)", required: false),
                     .init("keep-layout", help: "on lays the workspace out again as windows come and go; own sizes never do (the workspace's)", required: false),
                     .init("at-login", help: "the apps opened once per login, comma separated, the rest off; none for no app (the preset's)", required: false)],
            rowKey: "workspace",
            list: { () throws(ControlError) in
                let lists = try lists()
                let contents = lists.presets.contents
                return .array(contents.workspaces.keys.sorted(by: OccupiedWorkspace.ordered).compactMap { workspace in
                    contents.preset(for: workspace).map { Self.row($0, workspace: workspace, lists: lists) }
                })
            },
            add: { args throws(ControlError) in
                let lists = try lists()
                let workspace = try lists.workspace(args.value("workspace"))
                let contents = lists.presets.contents
                // The editor's draft: the saved preset, else a new one from the workspace's layout row.
                var draft = WorkspacePageDrafts.baseline(workspace, saved: contents.preset(for: workspace), row: lists.layouts.layout(workspace))
                if let name = args.value("preset") {
                    guard let saved = contents.presets[name] else {
                        throw ControlError(.badValue, "no saved preset \(name); there are \(contents.presets.keys.sorted().joined(separator: ", "))")
                    }
                    draft = WorkspacePresetDraft(saved, workspace: workspace, row: WorkspaceLayout(preset: draft.layout, auto: draft.keepLayout))
                }
                if let name = args.value("name") { draft.name = name }
                if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = "Workspace \(workspace)" }
                if let apps = args.value("apps") {
                    try Self.place(Self.items(apps), in: &draft)
                } else if draft.apps.isEmpty {
                    throw ControlError(.badValue, "workspace \(workspace) has no preset yet, so add needs --apps: bundle ids, comma separated, in order")
                }
                switch args.value("layout") {
                case nil where args.value("percents") == nil: break
                case nil, "own": draft.layout = nil
                case let word?: draft.layout = try Self.choice(word, "--layout")
                }
                if let percents = args.value("percents") {
                    let parts = Self.items(percents).compactMap(Int.init)
                    guard draft.layout == nil, parts.count == draft.apps.count, parts.allSatisfy((1...100).contains) else {
                        throw ControlError(.badValue, "--percents is one size from 1 to 100 per app, with --layout own")
                    }
                    for (i, percent) in parts.enumerated() { draft.setPercent(percent, at: i) }
                }
                if let open = args.value("open-missing") { draft.openMissing = try Self.onOff(open, "--open-missing") }
                if let keep = args.value("keep-layout") { draft.keepLayout = try Self.onOff(keep, "--keep-layout") }
                if let atLogin = args.value("at-login") {
                    let on = atLogin == "none" ? [] : Self.items(atLogin)
                    if let stray = on.first(where: { !draft.contains($0) }) {
                        throw ControlError(.badValue, "--at-login names \(stray), which is not among the preset's apps: \(draft.apps.map(\.bundleId).joined(separator: ", "))")
                    }
                    for (i, app) in draft.apps.enumerated() { draft.setAtLogin(on.contains(app.bundleId), at: i) }
                }
                if let problem = draft.problem { throw ControlError(.badValue, problem) }
                guard case .preset(let preset, let keep) = WorkspacePageDrafts.save(draft, workspace: workspace, hadPreset: false) else {
                    throw ControlError(.badValue, "the preset does not save")
                }
                lists.presets.save(preset, to: workspace, keepLayout: keep)
                if let failed = lists.presets.lastError { throw ControlError(.badValue, failed) }
                return Self.row(preset, workspace: workspace, lists: lists)
            },
            remove: { args throws(ControlError) in
                let presets = try lists().presets
                let workspace = try args.word(0, "workspace")
                guard presets.contents.preset(for: workspace) != nil else { throw ControlError(.badValue, "workspace \(workspace) has no preset") }
                presets.remove(from: workspace)
                if let failed = presets.lastError { throw ControlError(.badValue, failed) }
                return .string(workspace)
            }))
    }

    /// `--apps` as the editor's Opens here list ends up: apps not named are taken off, new ones added, then each moved to
    /// its place; an app kept keeps its size and At login unless one came or went.
    private static func place(_ wanted: [String], in draft: inout WorkspacePresetDraft) throws(ControlError) {
        var bundles: [String] = [], names: [String: String] = [:]
        for bundle in wanted where !bundles.contains(bundle) {
            bundles.append(bundle)
            if draft.contains(bundle) { continue }
            guard let name = AppsModule.appName(bundle) else { throw ControlError(.badValue, "no app on this Mac has the bundle id \(bundle)") }
            names[bundle] = name
        }
        for i in draft.apps.indices.reversed() where !bundles.contains(draft.apps[i].bundleId) { draft.remove(at: i) }
        for bundle in bundles { if let name = names[bundle] { draft.add(bundleId: bundle, name: name) } }
        for (to, bundle) in bundles.enumerated() {
            if let from = draft.apps.firstIndex(where: { $0.bundleId == bundle }), from != to { draft.move(from: from, to: to) }
        }
    }

    private func registerBlockLists(_ lists: @escaping @Sendable @MainActor () throws(ControlError) -> DesktopLists) {
        register(ControlCollection(
            "app-rules", help: "Apps whose windows always open on one workspace (Workspaces).",
            fields: [.init("app", help: "the app's bundle id"), .init("workspace", help: "the workspace its windows go to")],
            rowKey: "app",
            list: { () throws(ControlError) in .array(try lists().block.block.rules.map(Self.row)) },
            add: { args throws(ControlError) in
                let lists = try lists()
                let rule = PilotBlock.AppRule(appId: try Self.app(args.value("app")), workspace: try lists.workspace(args.value("workspace")))
                // One rule per app, as the page keeps it: a second add moves the app.
                if !lists.block.block.rules.contains(rule) {
                    try await lists.edit { block in
                        if let i = block.rules.firstIndex(where: { $0.appId == rule.appId }) { block.rules[i] = rule } else { block.rules.append(rule) }
                    }
                }
                return Self.row(rule)
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let app = try args.word(0, "app")
                guard lists.block.block.rules.contains(where: { $0.appId == app }) else { throw ControlError(.badValue, "no app rule for \(app)") }
                try await lists.edit { $0.rules.removeAll { $0.appId == app } }
                return .string(app)
            }))
        // Spec scrolling-layout T11: one rule per app, as app-rules keeps them; a second add replaces it.
        register(ControlCollection(
            "column-rules", help: "Apps whose column on a scrolling strip keeps its own width, or whose new windows leave focus where it was (Tiling).",
            fields: [.init("app", help: "the app's bundle id"),
                     .init("width", help: "its column's width, \(Self.cases(PilotBlock.ColumnWidth.self)); left out, the automatic one", required: false),
                     .init("focus", help: "off: a window it opens leaves focus where it was; on unless given", required: false)],
            rowKey: "app",
            list: { () throws(ControlError) in .array(try lists().block.block.scrolling.apps.map(Self.row)) },
            add: { args throws(ControlError) in
                let lists = try lists()
                var rule = PilotBlock.ColumnRule(appId: try Self.app(args.value("app")))
                if let width = args.value("width") { rule.width = try Self.choice(width, "width") }
                if let focus = args.value("focus") { rule.focus = try Self.onOff(focus, "focus") }
                guard rule.width != nil || !rule.focus else { throw ControlError(.badValue, "a column rule needs a width, focus off, or both") }
                if !lists.block.block.scrolling.apps.contains(rule) {
                    try await lists.edit { block in
                        if let i = block.scrolling.apps.firstIndex(where: { $0.appId == rule.appId }) { block.scrolling.apps[i] = rule }
                        else { block.scrolling.apps.append(rule) }
                    }
                }
                return Self.row(rule)
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let app = try args.word(0, "app")
                guard lists.block.block.scrolling.apps.contains(where: { $0.appId == app }) else { throw ControlError(.badValue, "no column rule for \(app)") }
                try await lists.edit { $0.scrolling.apps.removeAll { $0.appId == app } }
                return .string(app)
            }))
        register(ControlCollection(
            "float-apps", help: "Apps whose windows never tile (Tiling); names from before bundle ids are rows too.",
            fields: [.init("app", help: "the app's bundle id")],
            rowKey: "app",
            list: { () throws(ControlError) in
                let block = try lists().block.block
                return .array(block.floatAppIds.map { .object(["app": .string($0)]) } + block.floatApps.map { .object(["name": .string($0)]) })
            },
            add: { args throws(ControlError) in
                let lists = try lists()
                let app = try Self.app(args.value("app"))
                if !lists.block.block.floatAppIds.contains(app) { try await lists.edit { $0.floatAppIds.append(app) } }
                return .object(["app": .string(app)])
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let row = try args.word(0, "app")
                let block = lists.block.block
                guard block.floatAppIds.contains(row) || block.floatApps.contains(row) else { throw ControlError(.badValue, "\(row) does not float") }
                try await lists.edit { $0.floatAppIds.removeAll { $0 == row }; $0.floatApps.removeAll { $0 == row } }
                return .string(row)
            }))
        register(ControlCollection(
            "float-titles", help: "Window titles that never tile, whatever the app: a title containing one, case ignored (Tiling).",
            fields: [.init("title", help: "the text a window's title contains")],
            rowKey: "title",
            list: { () throws(ControlError) in .array(try lists().block.block.floatTitles.map(JSONValue.string)) },
            add: { args throws(ControlError) in
                let lists = try lists()
                guard let title = args.value("title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
                    throw ControlError(.badValue, "float-titles needs --title: the text a window's title contains")
                }
                if !lists.block.block.floatTitles.contains(title) { try await lists.edit { $0.floatTitles.append(title) } }
                return .string(title)
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let title = try args.word(0, "title")
                guard lists.block.block.floatTitles.contains(title) else { throw ControlError(.badValue, "no float title \(title)") }
                try await lists.edit { $0.floatTitles.removeAll { $0 == title } }
                return .string(title)
            }))
    }

    private func registerPinsAndLayouts(_ lists: @escaping @Sendable @MainActor () throws(ControlError) -> DesktopLists) {
        register(ControlCollection(
            "monitor-pins", help: "The display each workspace opens on: main, a display, or any (Workspaces).",
            fields: [.init("workspace", help: "the workspace, as 3"),
                     .init("monitor", help: "main, any, or a connected display's name or id")],
            rowKey: "workspace",
            list: { () throws(ControlError) in
                let monitors = try lists().monitors
                return .array(monitors.workspaces.map { Self.row(monitors.pins[$0], workspace: $0) })
            },
            add: { args throws(ControlError) in
                let lists = try lists()
                let workspace = try lists.workspace(args.value("workspace"))
                let word = args.value("monitor") ?? ""
                // The Monitor pick's own choices: Any, Main, each display, and the workspace's unplugged one.
                let choices = WorkspaceMonitors.choices(pinned: lists.monitors.pins[workspace], displays: lists.displays()).choices
                guard let choice = choices.first(where: { $0.title.caseInsensitiveCompare(word) == .orderedSame })
                        ?? choices.first(where: { if case .display(_, word?) = $0.value { true } else { false } }) else {
                    throw ControlError(.badValue, "--monitor is one of \(choices.map(\.title).joined(separator: ", ")), not \(word)")
                }
                lists.monitors.set(choice.value, for: workspace)
                return Self.row(lists.monitors.pins[workspace], workspace: workspace)
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let workspace = try lists.workspace(try args.word(0, "workspace"))
                lists.monitors.set(nil, for: workspace)
                return Self.row(nil, workspace: workspace)
            }))
        register(ControlCollection(
            "layouts", help: "Each workspace's layout preset and auto, which rebuilds it as windows come and go (Workspaces).",
            fields: [.init("workspace", help: "the workspace, as 3"),
                     .init("layout", help: "\(Self.cases(LayoutPreset.self)) or none"),
                     .init("auto", help: "on rebuilds the layout whenever a window opens or closes (on)", required: false)],
            rowKey: "workspace",
            list: { () throws(ControlError) in
                let layouts = try lists().layouts.layouts.filter { $0.value.preset != nil }
                return .array(layouts.sorted { OccupiedWorkspace.ordered($0.key, $1.key) }.map { Self.row($0.value, workspace: $0.key) })
            },
            add: { args throws(ControlError) in
                let lists = try lists()
                let workspace = try lists.layoutOnly(args.value("workspace"))
                let word = args.value("layout") ?? ""
                let preset: LayoutPreset? = word == "none" ? nil : try Self.choice(word, "--layout")
                let auto = try args.value("auto").map { word throws(ControlError) in try Self.onOff(word, "--auto") } ?? true
                // As the page saves a workspace with no apps: auto keeps a layout, so none has none to keep.
                let row = WorkspaceLayout(preset: preset, auto: auto && preset != nil)
                if lists.layouts.layout(workspace) != row { lists.layouts.set(workspace, row) }
                return Self.row(row, workspace: workspace)
            },
            remove: { args throws(ControlError) in
                let lists = try lists()
                let workspace = try lists.layoutOnly(try args.word(0, "workspace"))
                guard lists.layouts.layout(workspace).preset != nil else { throw ControlError(.badValue, "workspace \(workspace) has no layout") }
                lists.layouts.set(workspace, .unset)
                return .string(workspace)
            }))
    }

    private func registerSnapshots(_ lists: @escaping @Sendable @MainActor () throws(ControlError) -> DesktopLists) {
        register(ControlCollection(
            "snapshots", help: "Each workspace's saved windows (Workspaces); pilot snapshot save|restore makes and uses them.",
            rowKey: "workspace",
            list: { () throws(ControlError) in
                let saved = try lists().snapshots.saved.sorted { OccupiedWorkspace.ordered($0.key, $1.key) }
                return .array(saved.map { workspace, snapshot in
                    .object(["workspace": .string(workspace), "layout": .string(snapshot.layout),
                                    "saved": .string(snapshot.savedAt.ISO8601Format()),
                                    "windows": .array(snapshot.windows.map { .string("\($0.appName) '\($0.title)'") })])
                })
            },
            remove: { args throws(ControlError) in
                let snapshots = try lists().snapshots
                let workspace = try args.word(0, "workspace")
                guard snapshots.saved[workspace] != nil else { throw ControlError(.badValue, "workspace \(workspace) has no snapshot") }
                snapshots.delete(workspace)
                if let failed = snapshots.lastError { throw ControlError(.badValue, failed) }
                return .string(workspace)
            }))
        let subcommands: @Sendable @MainActor () -> JSONValue = { .object(["subcommands": .array(["save", "restore"].map(JSONValue.string))]) }
        let detail = [
            "save": "pilot snapshot save: saves the focused workspace's windows, replacing its snapshot, as Save snapshot does; hud says how many or that nothing was saved.",
            "restore": "pilot snapshot restore [<workspace>]: puts a workspace's saved windows back, the focused one's when none is named, switching there first and reopening closed apps when snapshots.reopenApps is on; hud says what was not found.",
        ]
        register(ControlVerb("snapshot", help: "Saves the focused workspace's windows, or restores a workspace's, as the snapshot actions do, and answers with the tips they raised.",
                             usage: "pilot snapshot save | pilot snapshot restore [<workspace>]", flags: [],
                             schema: subcommands, index: subcommands, detail: { detail[$0] }) { call throws(ControlError) in
            let lists = try lists()
            let args = call.arguments()
            switch try args.word(0, "save or restore") {
            case "save":
                let tips = await lists.readback.watch { lists.save() }
                return .object(["dispatched": .string("workspaces.saveSnapshot"), "hud": Self.hud(tips)])
            case "restore":
                let workspace = args.positional.dropFirst().first
                if let workspace, lists.snapshots.saved[workspace] == nil {
                    throw ControlError(.badValue, "workspace \(workspace) has no snapshot")
                }
                let tips = await lists.restoreReadback.watch { lists.restore(workspace) }
                return .object(["dispatched": .string("workspaces.restoreSnapshot"), "workspace": workspace.map(JSONValue.string) ?? .null,
                                "hud": Self.hud(tips)])
            case let other: throw ControlError(.badRequest, "pilot snapshot save or restore, not \(other)")
            }
        })
    }

    /// The tips a run raised, one per line, as `pilot run` answers them; null for none.
    static func hud(_ tips: [String]) -> JSONValue { tips.isEmpty ? .null : .string(tips.joined(separator: "\n")) }

    // MARK: Rows and words

    private static func fields(_ preset: WorkspacePreset) -> [String: JSONValue] {
        ["name": .string(preset.name), "layout": .string(preset.layout?.rawValue ?? "own"), "openMissing": .bool(preset.openMissing),
         "apps": .array(preset.apps.map { .object(["app": .string($0.bundleId), "name": .string($0.name),
                                                   "percent": .number(Double($0.percent)), "atLogin": .bool($0.atLogin)]) })]
    }

    /// A workspace's preset with its Keep this layout, and the other workspaces that take the same preset by name.
    private static func row(_ preset: WorkspacePreset, workspace: String, lists: DesktopLists) -> JSONValue {
        var row = fields(preset)
        row["workspace"] = .string(workspace)
        // As the editor's switch shows it: own sizes keep no layout.
        row["keepLayout"] = .bool(lists.layouts.layout(workspace).auto && preset.layout != nil)
        row["sharedWith"] = .array(lists.presets.contents.workspaces(using: preset.name).filter { $0 != workspace }.map(JSONValue.string))
        return .object(row)
    }

    /// A workspace kept: its name (null while it has none), whether it is focused, its apps, preset and snapshot.
    private static func row(workspace: String, lists: DesktopLists) -> JSONValue {
        let tiler = lists.tiler, contents = lists.presets.contents
        let apps = tiler.occupied.first { $0.name == workspace }?.apps ?? []
        // Focused stays null while the tiler is not answering, as the page's state line goes blank.
        return .object(["workspace": .string(workspace), "name": contents.name(for: workspace).map(JSONValue.string) ?? .null,
                        "focused": tiler.isAnswering ? .bool(workspace == tiler.focused) : .null,
                        "apps": .array(apps.map(JSONValue.string)),
                        "preset": contents.workspaces[workspace].map(JSONValue.string) ?? .null,
                        "snapshot": lists.snapshots.saved[workspace].map { .string($0.savedAt.ISO8601Format()) } ?? .null])
    }

    private static func row(_ rule: PilotBlock.AppRule) -> JSONValue {
        .object(["app": .string(rule.appId), "workspace": .string(rule.workspace)])
    }

    private static func row(_ rule: PilotBlock.ColumnRule) -> JSONValue {
        .object(["app": .string(rule.appId), "width": rule.width.map { .string($0.rawValue) } ?? .null, "focus": .bool(rule.focus)])
    }

    private static func row(_ pin: MonitorPin?, workspace: String) -> JSONValue {
        let (monitor, id): (String, String?) = switch pin {
        case nil: ("Any", nil)
        case .main: ("Main", nil)
        case .display(let name, let id): (name, id)
        }
        return .object(["workspace": .string(workspace), "monitor": .string(monitor), "id": id.map(JSONValue.string) ?? .null])
    }

    private static func row(_ layout: WorkspaceLayout, workspace: String) -> JSONValue {
        .object(["workspace": .string(workspace), "layout": .string(layout.preset?.rawValue ?? "none"), "auto": .bool(layout.auto)])
    }

    /// A comma-separated field's parts, trimmed, empty ones dropped.
    private static func items(_ field: String?) -> [String] {
        (field ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func app(_ word: String?) throws(ControlError) -> String {
        guard let word, !word.isEmpty, !word.contains(where: \.isWhitespace) else {
            throw ControlError(.badValue, "an app is its bundle id, as com.apple.finder, not \(word ?? "nothing")")
        }
        return word
    }

    /// One of an enum's cases by its raw value, in the settings verbs' words.
    static func choice<T: CaseIterable & RawRepresentable<String>>(_ word: String, _ field: String) throws(ControlError) -> T {
        guard let value = T(rawValue: word) else { throw ControlError(.badValue, "\(field) is one of \(cases(T.self)), not \(word)") }
        return value
    }

    static func cases<T: CaseIterable & RawRepresentable<String>>(_: T.Type) -> String { T.allCases.map(\.rawValue).joined(separator: ", ") }

    /// On or off in the words `pilot set` takes.
    static func onOff(_ word: String, _ field: String) throws(ControlError) -> Bool {
        switch word.lowercased() {
        case "true", "on", "yes", "1": true
        case "false", "off", "no", "0": false
        default: throw ControlError(.badValue, "\(field) is on or off, not \(word)")
        }
    }
}
