import Darwin
import Foundation
import PilotCore

/// Sven, 2026-10-24 (Q437): the workspace each window is on, so a window Pilot knew before it relaunched goes back there
/// instead of to the workspace its screen shows. With the main screen off every window came back on 1, those Sven had
/// put on 2 and 4 too. Its saved workspace wins over an app rule, as after a fault (RecoveredPlacement).
struct WindowHome: Codable, Equatable, Sendable {
    let windowId: UInt32
    let appBundleId: String
    let title: String
    let placement: RecoveredPlacement

    /// The same window on the same workspace: a title alone changing is no move, so it saves nothing.
    var spot: [String] { [String(windowId), appBundleId, placement.workspace, String(placement.isFloating)] }
}

extension WindowHome {
    /// Any window on a workspace with an app bundle id; nil for a popup or an app with none.
    @MainActor init?(_ window: Window) {
        guard let app = window.app.rawAppBundleId, let placement = recoveryPlacements(of: [window])[window.windowId] else { return nil }
        self.init(windowId: window.windowId, appBundleId: app, title: windowTitles[window.windowId] ?? "", placement: placement)
    }
}

/// In memory until the engine starts, which loads Application Support's; tests never touch that file.
@MainActor var windowHomes = WindowHomes()

@MainActor
final class WindowHomes {
    /// ~/Library/Application Support/Pilot/window-homes.json
    static let standardFile = PilotFolder.support.appending(path: "window-homes.json")
    /// How long after the engine starts a window may still claim its home: a slow app's windows register a session late.
    static let claimWindow: TimeInterval = 60

    struct Saved: Codable, Sendable {
        let saved: Date
        let homes: [WindowHome]
    }

    /// The windows alive at this refresh, registered or not yet; within one boot a home matched by title is never theirs.
    var alive: Set<UInt32> = []

    private var homes: [WindowHome] = []
    /// Read at the start and not claimed yet; each window's own until the claim window closes.
    private var waiting: [WindowHome]
    /// Window ids hold only within one boot; a file from before it is matched by app and title alone.
    private let idsHold: Bool
    private let deadline: Date
    private let file: URL?
    private let now: () -> Date

    init(file: URL? = nil, now: @escaping () -> Date = Date.init, bootTime: Date? = WindowHomes.bootTime()) {
        self.file = file
        self.now = now
        let started = now()
        deadline = started + Self.claimWindow
        let stored = file.flatMap { try? DayFile<Saved>(url: $0).load(or: Saved(saved: .distantPast, homes: [])) }
        idsHold = stored.map { saved in bootTime.map { saved.saved > $0 } ?? false } ?? false
        waiting = stored.map { started.timeIntervalSince($0.saved) < WindowSlots.maxAge ? $0.homes : [] } ?? []
        homes = waiting
    }

    /// Where a registering window goes, once: its own id's home for the same app, else the app's home with its title (read
    /// only then, as `read` gives it) whose window is gone; nil when it has none or the claim window closed.
    func claim(_ windowId: UInt32, appBundleId: String?, title read: () async throws -> String?) async rethrows -> RecoveredPlacement? {
        guard let appBundleId, isOpen, waiting.contains(where: { $0.appBundleId == appBundleId }) else { return nil }
        var i = waiting.firstIndex { idsHold && $0.windowId == windowId && $0.appBundleId == appBundleId }
        if i == nil, let title = try await read(), !title.isEmpty {
            i = waiting.firstIndex { $0.appBundleId == appBundleId && $0.title == title && !(idsHold && alive.contains($0.windowId)) }
        }
        return i.map { waiting.remove(at: $0).placement }
    }

    /// The tree as laid out now, plus the homes still waiting; saved when a window came, went or moved.
    func record(_ windows: [Window]) {
        if !isOpen { waiting = [] }
        let live = windows.compactMap(WindowHome.init)
        let ids = Set(live.map(\.windowId))
        let next = (live + waiting.filter { !ids.contains($0.windowId) }).sorted { $0.windowId < $1.windowId }
        if next.map(\.spot) == homes.map(\.spot) { return }
        homes = next
        if let file { try? DayFile<Saved>(url: file).save(Saved(saved: now(), homes: next)) }
    }

    private var isOpen: Bool { !waiting.isEmpty && now() < deadline }

    /// kern.boottime: wall time, where systemUptime leaves out the time the Mac slept.
    nonisolated static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }
}
