import Foundation
import Observation
import PilotCore
import SwiftUI

/// The Pilot block's settings (stories 68 and 96) and the one path that changes them: saved in Pilot's settings and
/// handed to the tiler. On first run they start from what `~/.aerospace.toml` did, read once as an import and never
/// written (ADR 0011), so nothing changes under Sven's fingers (coordinator note 1).
@Observable @MainActor
final class PilotBlockStore {
    /// The import: `~/.aerospace.toml`, and in a test run a path in the run's own folder (PilotFolder) a test may write a
    /// fixture to, so no pass or fail hangs on Sven's file (OW P7). A render run reads its moved home's.
    static let path = isIsolatedTestRun ? PilotFolder.support.appending(path: ".aerospace.toml").path : NSHomeDirectory() + "/.aerospace.toml"
    private static let key = "pilotBlock"
    private static let yabaiFloatsCarried = "pilotBlock.yabaiFloatsCarried"
    private static let floatNamesMoved = "pilotBlock.floatNamesMoved"

    private let tiler: TilerService
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var block: PilotBlock
    /// The last refusal or failure, shown on the settings pages; nil after a clean write.
    private(set) var lastError: String?
    private var queue: Task<Void, Never>?
    /// Each float name's bundle id, by the app macOS shows by that name (C8); tests pass their own.
    @ObservationIgnored private let bundles: @MainActor ([String]) -> [String: String]

    init(tiler: TilerService, defaults: UserDefaults = .pilot(), bundles: @escaping @MainActor ([String]) -> [String: String] = AppsModule.bundles(named:)) {
        self.tiler = tiler
        self.defaults = defaults
        self.bundles = bundles
        defer { moveFloatNames() }
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(PilotBlock.self, from: data) {
            block = saved
            return
        }
        block = PilotBlock()
        // Never a HUD here: init runs inside SwiftUI's first graph update. Settings are saved only once something was
        // carried, so an empty or unreadable file never wipes what a later launch could still carry over; the carry-over
        // reads the block too, so a file already migrated to it gives the same settings. No file is nothing to import, as
        // on a Mac that never ran AeroSpace, never an error on the settings pages.
        do {
            guard let found = try PilotBlock.carryOver(from: String(contentsOfFile: Self.path, encoding: .utf8)) else { return }
            block = found
            save()
            wslog.notice("pilot block: carried over \(found.rules.count) rules, \(found.floatApps.count + found.floatTitles.count) floats, gaps \(found.gaps.inner)/\(found.gaps.outer) from \(Self.path, privacy: .public)")
        } catch CocoaError.fileReadNoSuchFile {
        } catch {
            lastError = String(describing: error)
            wslog.error("pilot block: carry-over failed: \(self.lastError ?? "", privacy: .public)")
        }
    }

    /// yabai's floats (Finder) join the always-float list once, written through the usual edit; the flag is set once the
    /// write took or nothing was missing, so a later removal on Settings › Workspaces sticks (card agent-bo-95422769).
    func carryYabaiFloats() {
        let carried = defaults.bool(forKey: Self.yabaiFloatsCarried)
        if block.yabaiFloatsToCarry(alreadyCarried: carried).isEmpty {
            if !carried { defaults.set(true, forKey: Self.yabaiFloatsCarried) }
            return
        }
        edit({ $0.floatAppIds += $0.yabaiFloatsToCarry(alreadyCarried: false) }) { [defaults] written in
            guard written else { return }
            defaults.set(true, forKey: Self.yabaiFloatsCarried)
            wslog.notice("pilot block: carried yabai's floats \(PilotBlock.yabaiFloats.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Float names an app on this Mac answers to become its bundle id, once, before the tiler first reads the block (C8); a
    /// name none answers to stays a name (its row says so), so no later launch scans the app folders for it again.
    private func moveFloatNames() {
        guard !block.floatApps.isEmpty, !defaults.bool(forKey: Self.floatNamesMoved) else { return }
        defaults.set(true, forKey: Self.floatNamesMoved)
        let ids = bundles(block.floatApps)
        guard block.moveFloatNames(to: ids) else { return }
        wslog.notice("pilot block: float names \(ids.keys.sorted().joined(separator: ", "), privacy: .public) now match by bundle id")
        save()
    }

    /// The top bar's room (card agent-bo-95422850), awaited by its switch; a refused change throws with the reason.
    func writeTopBar(_ bars: [PilotBlock.BarInset]) async throws {
        let written = await withCheckedContinuation { done in edit({ $0.topBar = bars }) { done.resume(returning: $0) } }
        if !written { throw NotWritten(reason: lastError ?? "unknown") }
    }

    /// The dock's room at the foot of its screen (spec pilot-dock), as the top bar's above.
    func writeDock(_ room: [PilotBlock.BarInset]) async throws {
        let written = await withCheckedContinuation { done in edit({ $0.dock = room }) { done.resume(returning: $0) } }
        if !written { throw NotWritten(reason: lastError ?? "unknown") }
    }

    struct NotWritten: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Hyper+Shift+Backspace: gaps off writes zeros, on writes the sizes back.
    func toggleGaps() { edit { $0.gapsOn.toggle() } }

    /// A settings control bound to one field; setting it is an `edit`.
    func binding<Value>(_ field: WritableKeyPath<PilotBlock, Value> & Sendable) -> Binding<Value> {
        Binding(get: { self.block[keyPath: field] }, set: { value in self.edit { $0[keyPath: field] = value } })
    }

    /// Applies one settings change and hands it to the tiler. A refused change is taken back, so the settings always say
    /// what the tiler does. Edits run one at a time, so a refused one never takes back a later one.
    func edit(_ change: @escaping @MainActor (inout PilotBlock) -> Void, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let earlier = queue
        queue = Task {
            await earlier?.value
            let before = block
            change(&block)
            let written = await apply()
            if written { save() } else { block = before }
            done(written)
        }
    }

    private func apply() async -> Bool {
        let t0 = ContinuousClock.now
        do {
            try await tiler.settingsChanged(block)
            lastError = nil
            wslog.notice("pilot block applied, gaps \(self.block.gapsOn ? "on" : "off", privacy: .public), \(self.block.rules.count) rules, \(Int((ContinuousClock.now - t0) / .milliseconds(1))) ms")
            return true
        } catch {
            lastError = String(describing: error)
            wslog.error("pilot block: \(self.lastError ?? "", privacy: .public)")
            HUD.tip("Tiling settings not applied: see \(AppPlace(.tiling).path)")
            return false
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(block) { defaults.set(data, forKey: Self.key) }
    }
}
