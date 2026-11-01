import AppKit
import Observation
import PilotCore

/// Workspace presets (story 108, card agent-bo-95422778): each workspace's saved preset, applied every time the tiler
/// switches to that workspace, one apply at a time. PilotCore's WorkspacePresetApply holds the steps; this runs them on
/// Pilot's tiler, Pilot's launch-or-focus and the window list's frames.
@Observable @MainActor
final class WorkspacePresets {
    private(set) var contents = WorkspacePresetStore.Contents()
    /// The last store failure, shown in the editor.
    private(set) var lastError: String?

    /// After a save, once per workspace that takes the preset: the engine sets that workspace's layout row to match
    /// (WorkspaceLayout.saving), with the editor's Keep this layout for the workspace it was saved from, nil for the others.
    @ObservationIgnored var onSave: (String, WorkspacePreset, Bool?) -> Void = { _, _, _ in }
    @ObservationIgnored private let observers: EngineObservers
    @ObservationIgnored private let store: WorkspacePresetStore
    @ObservationIgnored private let defaults: UserDefaults
    /// When this login session started; nil when unknown.
    @ObservationIgnored private let session: () -> Date?
    /// The apply running now; a switch while it runs cancels it, and the new one starts once it has stopped.
    @ObservationIgnored private var applying: Task<Void, Never>?
    /// An At login run is under way; a second start waits for the next answer.
    @ObservationIgnored private var openingAtLogin = false
    /// The workspace Open this workspace's layout switched to: its switch opens what is missing.
    @ObservationIgnored private var openOnArrival: String?
    private var tiler: TilerService { observers.tiler }

    init(observers: EngineObservers, store: WorkspacePresetStore = .standard, defaults: UserDefaults = .pilot(),
         session: @escaping () -> Date? = WorkspacePresets.loginSession) {
        self.observers = observers
        self.store = store
        self.defaults = defaults
        self.session = session
        do { contents = try store.load() } catch { fail("workspace presets not read", error) }
    }

    /// The editor's Save: the preset under its name, given to `workspace`; it applies on the next switch there.
    func save(_ preset: WorkspacePreset, to workspace: String, keepLayout: Bool? = nil) {
        guard let saved = write("workspace preset not saved", { $0.assign(preset, to: workspace) }) else { return }
        wslog.notice("preset \(preset.name, privacy: .public) saved for workspace \(workspace, privacy: .public)")
        for name in saved.workspaces(using: preset.name) { onSave(name, preset, name == workspace ? keepLayout : nil) }
    }

    /// The editor's autosave (Sven 2026-10-17, no Save button): the draft as its preset, or with no app and no name the
    /// layout row alone. False when nothing could be written.
    func write(_ draft: WorkspacePresetDraft, to workspace: String, layouts: WorkspaceLayouts) -> Bool {
        switch WorkspacePageDrafts.save(draft, workspace: workspace, hadPreset: contents.preset(for: workspace) != nil) {
        case .preset(let preset, let keep):
            save(preset, to: workspace, keepLayout: keep)
        case .layout(let row, let removePreset):
            if removePreset { remove(from: workspace) }
            layouts.set(workspace, row)
        case .refused:
            return false
        }
        return lastError == nil
    }

    /// Each workspace's preset under its new number (Sven's Q233, WorkspacePresetStore.Contents.renumbered).
    func renumber(_ r: WorkspaceRenumber) {
        _ = write("workspace presets not renumbered") { $0 = $0.renumbered(r) }
    }

    /// The editor's Remove: the workspace keeps no preset; the preset stays saved to reuse.
    func remove(from workspace: String) {
        if write("workspace preset not removed", { $0.unassign(workspace) }) != nil {
            wslog.notice("preset removed from workspace \(workspace, privacy: .public)")
        }
    }

    /// One change on the file as it is now, read again first: a file that does not decode refuses the change, so no
    /// save wipes the presets in it. Nil when nothing was written.
    private func write(_ what: String, _ change: (inout WorkspacePresetStore.Contents) -> Void) -> WorkspacePresetStore.Contents? {
        do {
            var next = try store.load()
            change(&next)
            try store.save(next)
            contents = next
            lastError = nil
            return next
        } catch {
            fail(what, error)
            return nil
        }
    }

    func start() {
        tiler.onWorkspaceSwitched = { [weak self] workspace in self?.switched(to: workspace) }
        tiler.onConnected = { [weak self] in self?.openAtLogin() }
    }

    /// Once per login session, the apps a workspace's preset marks At login open and go to that workspace
    /// (WorkspaceLoginOpen). The session counts as done only once a run reached the tiler, so a Pilot that starts
    /// before the tiler answers tries again on its first answer; a Pilot restart later in the session opens nothing.
    func openAtLogin(using run: @MainActor ([WorkspaceLoginOpen.Planned]) async throws -> Void) async {
        guard !openingAtLogin, let session = session(),
              WorkspaceLoginOpen.due(session: session, last: defaults.object(forKey: Self.loginKey) as? Double) else { return }
        openingAtLogin = true
        defer { openingAtLogin = false }
        let plan = WorkspaceLoginOpen.plan(contents)
        do {
            if !plan.isEmpty { try await run(plan) }
            defaults.set(session.timeIntervalSince1970, forKey: Self.loginKey)
        } catch {
            wslog.error("at login: \(String(describing: error), privacy: .public); tried again when the tiler answers")
        }
    }

    /// The real run: the tiler's client and Pilot's launch-or-focus.
    private func openAtLogin() {
        Task {
            await openAtLogin { [tiler] plan in
                let outcome = try await WorkspaceLoginOpen(plan: plan, tiler: tiler.runner, apps: Opener()).run()
                wslog.notice("at login: opened \(outcome.opened.joined(separator: ", "), privacy: .public), moved \(outcome.pulled), missing \(outcome.missing.joined(separator: ", "), privacy: .public)")
            }
        }
    }

    static let loginKey = "workspaces.atLoginSession"

    /// The latest console login of this user, from the login records `who` reads.
    nonisolated static func loginSession() -> Date? {
        setutxent()
        defer { endutxent() }
        let user = NSUserName()
        var latest: Date?
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: &record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: &record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec))
            latest = max(latest ?? date, date)
        }
        return latest
    }

    /// Open this workspace's layout (Sven, build 6 of 1.0.2): the workspace in front, or `workspace`, gets its preset
    /// applied with what is missing opened, whatever its Open what is missing switch says. A workspace not in front is
    /// switched to first; its switch runs the apply.
    func openLayout(_ workspace: String? = nil) {
        guard let name = workspace ?? tiler.focused else { return HUD.tip("No workspace in front") }
        guard let preset = contents.preset(for: name), !preset.apps.isEmpty else {
            return HUD.tip("Workspace \(name) has no layout saved: add apps under Opens here")
        }
        guard name != tiler.focused else { return apply(preset, on: name, openMissing: true) }
        openOnArrival = name
        Task {
            await tiler.perform("workspaces.openLayout:\(name)") { client in
                do { try await client.run(.workspace(name)) } catch { openOnArrival = nil; throw error }
            }
        }
    }

    static func register(into registry: inout ActionRegistry, presets: WorkspacePresets) {
        do {
            try registry.register(Action(id: "workspaces.openLayout", label: "Open this workspace's layout", module: .workspaces,
                                         defaultKey: Key("o", .ctrl), tier: .v1) { presets.openLayout() })
        } catch { wslog.error("workspaces.openLayout: \(String(describing: error), privacy: .public)") }
    }

    private func switched(to workspace: String) {
        let forced = openOnArrival == workspace
        openOnArrival = nil
        // A named workspace with no app yet has nothing to open or lay out.
        guard let preset = contents.preset(for: workspace), !preset.apps.isEmpty else { return }
        apply(preset, on: workspace, openMissing: forced || preset.openMissing)
    }

    /// One apply at a time: a newer one cancels the one running and starts once it has stopped.
    private func apply(_ saved: WorkspacePreset, on workspace: String, openMissing: Bool) {
        var preset = saved
        preset.openMissing = openMissing
        let previous = applying
        previous?.cancel()
        applying = Task {
            await previous?.value
            await tiler.perform("workspaces.preset:\(workspace):\(preset.name)") { client in
                let outcome = try await WorkspacePresetApply(preset: preset, workspace: workspace, tiler: client, apps: Opener(),
                                                             frames: observers.framesByID).run()
                wslog.notice("preset \(preset.name, privacy: .public) on workspace \(workspace, privacy: .public): opened \(outcome.opened.joined(separator: ", "), privacy: .public), pulled \(outcome.pulled), missing \(outcome.missing.joined(separator: ", "), privacy: .public)")
                if !outcome.missing.isEmpty {
                    let names = preset.apps.filter { outcome.missing.contains($0.bundleId) }.map(\.name)
                    HUD.tip("\(preset.name): no window from \(names.joined(separator: ", "))")
                }
            }
        }
    }

    private func fail(_ what: String, _ error: Error) {
        lastError = "\(what): \(error)"
        wslog.error("\(self.lastError ?? "", privacy: .public)")
    }


    /// Pilot's launch-or-focus (AppsModule.open).
    private struct Opener: AppOpening {
        func open(bundle: String) -> Bool { AppsModule.open(bundle: bundle) }
    }
}
