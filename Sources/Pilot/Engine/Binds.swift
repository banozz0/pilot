import Foundation
import Observation
import PilotCore

/// The bind store on disk (PilotCore's BindStore): `~/Library/Application Support/Pilot/binds.json`, schema version
/// `BindStore.version`. Read at launch and by pilot://reload-binds; written back whenever it differs from what the
/// store holds, so the first launch seeds it and it always lists every bind for a reader outside Pilot (card agent-bo-95422451).
@Observable @MainActor
final class Binds {
    static let url = PilotFolder.support.appending(path: "binds.json")
    /// The file this store reads and writes: Self.url, and in any test run one of its own in the run's folder
    /// (PilotFolder), so no test's binds reach another's (Binds' editor drew whatever Home settles left, 2026-10-10). A
    /// render run too: its tests run in parallel in one moved home, and one test's preset switch broke another's bind.
    let fileURL = isTestRun ? PilotFolder.support.appending(path: "binds-\(UUID().uuidString).json") : Binds.url

    /// Each base's default keys, every registered action and a new file's mouse buttons, set by the first load.
    private var presets: [BindStore.Base: [String: Key]] = [:]
    private var actions: [String] = []
    private var mouse: () -> [Key: String] = { [:] }
    private(set) var store = BindStore(defaults: [:])
    /// Why the file was not read; nil after a clean load. While set, nothing is written, so a hand edit is never lost.
    private(set) var lastError: String?
    /// After every load and change: Engine arms the mouse taps a mouse bind needs.
    @ObservationIgnored var onChange: () -> Void = {}

    /// Actions that changed id, old to new: a bind on the old one moves at load. The layout toggle took a new id when
    /// the scrolling layout replaced its old layout (spec scrolling-layout, 2026-10-12).
    static let retired = ["windows.toggleAccordion": "windows.toggleScrolling"]

    /// The defaults run until an unreadable file is fixed. `mouse` is what a new file's buttons run, asked only for one.
    func load(presets: [BindStore.Base: [String: Key]], actions: [String], mouse: @escaping () -> [Key: String] = { [:] }) {
        self.presets = presets
        self.actions = actions
        self.mouse = mouse
        load()
    }

    func load() {
        let file = try? Data(contentsOf: fileURL)
        lastError = nil
        // My binds is Sven's layout (SH8): only a file that already holds it lists it, so a new user never sees it.
        let tables = file.map(BindStore.holdsMyBinds) == true ? presets : presets.filter { $0.key != .myBinds }
        do { store = try file.map { data throws(BindStore.LoadError) in try BindStore(json: data, presets: tables, actions: actions) } ?? BindStore(presets: tables, actions: actions) }
        catch {
            store = BindStore(presets: tables, actions: actions)
            lastError = "\(fileURL.path) not read: \(error)"
            return log.error("binds: \(self.lastError ?? "", privacy: .public); the defaults run")
        }
        // A new install starts with Sven's mouse buttons too (Q531); a file keeps its own, none included.
        if file == nil { for (key, action) in mouse() { store.setMouse(key, to: action) } }
        logRefused()
        log.notice("binds: \(self.store.binds.count) loaded from \(self.fileURL.path, privacy: .public), preset \(self.store.preset.id, privacy: .public)")
        backUp(file)
        for (old, new) in Self.retired where store.rename(old, to: new) {
            log.notice("binds: \(LinkToken.redact(old), privacy: .public) is \(LinkToken.redact(new), privacy: .public) now, on \(self.store.trigger(for: new)?.label ?? "no key", privacy: .public)")
        }
        for id in store.moveDisplayKeys() {
            log.notice("binds: \(LinkToken.redact(id), privacy: .public) moved to \(self.store.trigger(for: id)?.label ?? "no key", privacy: .public) (Q195)")
        }
        if let notice = store.notice {
            log.notice("binds: \(notice, privacy: .public)")
            HUD.tip(notice)
        }
        save(over: file)
    }

    /// The Binds screen and pilot://bind change binds here: each change is written at once, and a refused one leaves
    /// the store and the file as they were, with a log line. `old` is the bind the editor moved to another action.
    /// An action that already holds a key moves off it, and the log line names the key it freed.
    func set(_ action: String, to key: Key?, from old: String? = nil) throws(BindStore.BindError) {
        let freed = key.flatMap { BindsPage.moving(store: store, action: action, to: $0) }
        try change { s throws(BindStore.BindError) in try s.set(action, to: key, from: old) }
        log.notice("binds: \(BindsPage.bindLog(action, on: key, from: old, freed: freed), privacy: .public)")
    }

    /// Binds Binds › Mouse's learnt trigger to `action`, from `device` for a media key and on the drawn `button` that sends
    /// it, or frees it with nil.
    func setMouse(_ key: Key, to action: String?, device: MouseKeys.Device? = nil, button: Int? = nil) {
        store.setMouse(key, to: action, device: device, button: button)
        save()
        let on = store.mouseBinds.first { $0.trigger == key }?.bind.button.map { " on Mouse \($0)" } ?? ""
        log.notice("binds: \(key.label, privacy: .public)\(on, privacy: .public) \(action.map { "runs \(LinkToken.redact($0))" } ?? "freed", privacy: .public)")
    }

    /// Mouse 4's hold opens This window (Q194), when BindStore.addRingHold finds it free and its click bound.
    func addRingHold() {
        guard store.addRingHold() else { return log.notice("binds: Mouse 4's hold left as it is (no click bind, or a hold already)") }
        save()
        log.notice("binds: Mouse 4's hold opens This window")
    }

    func replace(_ action: String, with key: Key, from old: String? = nil) {
        let freed = BindsPage.moving(store: store, action: action, to: key)
        let other = store.replace(action, with: key, from: old)
        save()
        log.notice("binds: \(BindsPage.bindLog(action, on: key, left: other, from: old, freed: freed), privacy: .public)")
    }

    func reset(_ action: String) throws(BindStore.BindError) {
        try change { s throws(BindStore.BindError) in try s.reset(action) }
        log.notice("binds: \(LinkToken.redact(action), privacy: .public) reset to \(self.store.trigger(for: action)?.label ?? "no key", privacy: .public)")
    }

    /// Settings › Binds' preset picker and pilot://bind?preset=: every key changes to that preset's, app binds stay.
    func use(_ preset: BindStore.Preset) {
        store.use(preset)
        save()
        log.notice("binds: preset \(preset.id, privacy: .public), \(self.store.binds.count) binds")
        logRefused()
    }

    /// New preset (story 149): from scratch or a copy of the active one, which it then replaces.
    func addPreset(named name: String, copying: Bool) {
        let new = store.addPreset(named: name, copying: copying)
        save()
        log.notice("binds: preset \(new.id, privacy: .public) made \(copying ? "as a copy" : "from scratch", privacy: .public), \(self.store.binds.count) binds")
    }

    /// New preset on one base's default keys alone (Ask Pilot's /preset); false when the store has no such base.
    func addPreset(named name: String, base: BindStore.Base) -> Bool {
        guard let new = store.addPreset(named: name, base: base) else { return false }
        save()
        log.notice("binds: preset \(new.id, privacy: .public) made on \(base.rawValue, privacy: .public), \(self.store.binds.count) binds")
        return true
    }

    func renamePreset(_ preset: BindStore.Preset, to name: String) {
        guard store.renamePreset(preset, to: name) else { return }
        save()
        log.notice("binds: preset \(preset.id, privacy: .public) renamed \(self.store.preset(id: preset.id)?.name ?? name, privacy: .public)")
    }

    func deletePreset(_ preset: BindStore.Preset) {
        guard store.deletePreset(preset) else { return }
        save()
        log.notice("binds: preset \(preset.id, privacy: .public) deleted, \(self.store.preset.id, privacy: .public) active")
        logRefused()
    }

    /// Import's Add as preset: the file's active preset becomes a new one, and the active one.
    func importPreset(_ data: Data, name: String) throws(BindStore.LoadError) {
        let new = try store.importPreset(data, name: name)
        save()
        log.notice("binds: preset \(new.id, privacy: .public) imported, \(self.store.binds.count) binds")
        logRefused()
    }

    private func logRefused() {
        for r in store.refused {
            log.error("binds: \(LinkToken.redact(r.action), privacy: .public) on \(r.trigger.label, privacy: .public) refused, \(LinkToken.redact(r.takenBy), privacy: .public) holds it")
        }
    }

    /// Export and import (stories 41 and 58): an import's plan applied, its shell, URL, Shortcuts and picker binds off.
    func apply(_ plan: BindStore.Import) {
        store.apply(plan)
        save()
        log.notice("binds: imported \(plan.added.count) new, \(plan.changed.count) changed, \(plan.clashes.count) clashes; switched off: \(LinkToken.redact(plan.switchedOff.joined(separator: ", ")), privacy: .public)")
        logRefused()
    }

    /// A deleted focus preset's bind goes with it.
    func remove(_ action: String) {
        guard store.remove(action) else { return }
        save()
        log.notice("binds: \(LinkToken.redact(action), privacy: .public) removed")
    }

    func enable(_ action: String) {
        store.enable(action)
        save()
        log.notice("binds: \(LinkToken.redact(action), privacy: .public) turned on")
    }

    func resetAll() {
        store.resetAll()
        save()
        log.notice("binds: all reset")
    }

    private func change(_ edit: (inout BindStore) throws(BindStore.BindError) -> Void) throws(BindStore.BindError) {
        do { try edit(&store) } catch {
            if case .triggerTaken(let key, let other) = error {
                log.error("binds: \(key.label, privacy: .public) refused, \(LinkToken.redact(other), privacy: .public) holds it")
            }
            throw error
        }
        save()
    }

    /// An older file read in is kept beside, once, as binds.v1.json or binds.v2.json, before a version 3 write can
    /// replace it (story 149).
    private func backUp(_ file: Data?) {
        guard let file, store.fileVersion < BindStore.version else { return }
        let backup = fileURL.deletingLastPathComponent().appending(path: "binds.v\(store.fileVersion).json")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        do {
            try file.write(to: backup)
            log.notice("binds: version \(self.store.fileVersion) file kept as \(backup.path, privacy: .public)")
        } catch {
            log.error("binds: \(backup.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `old` is the file just read: written back only when it differs, beyond an older file's version (story 143).
    private func save(over old: Data? = nil) {
        onChange()
        let data = store.json()
        guard store.fileVersion == BindStore.version ? data != old : store.json(version: store.fileVersion) != old else { return }
        guard lastError == nil else { return log.error("binds: not written, \(self.fileURL.path, privacy: .public) could not be read") }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("binds: \(self.fileURL.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
