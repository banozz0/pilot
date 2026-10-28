import AppKit
import Observation
import PilotCore

/// Card agent-bo-95423036: where one of an app's tiled windows sat when the app quit, so the relaunched app's window with
/// its title (else the next in order) goes back there.
struct WindowSlot: Codable, Equatable, Sendable {
    let appBundleId: String
    let title: String
    let workspace: String
    /// The window's index in each tiling container from its workspace's root down; the last is its index in its parent.
    let path: [Int]
    /// The window's part of its parent along the parent's orientation, 0 to 1. A raw weight would not do: weights are
    /// 1 after a balance, an arrange or on a scrolling strip and points once a layout ran, so a slot saved at 1 got a
    /// sliver beside windows of 1686 points (Sven, 2026-10-15). Nil in a slot saved as a weight: it takes an even share.
    let share: CGFloat?
    let saved: Date
}

/// Each window's title as its app's thread last read it (when the window registered and at each title change), since a
/// quit app's windows can no longer be asked.
@MainActor var windowTitles: [UInt32: String] = [:]

/// A window's title, read on its app's thread, into windowTitles: when it registers, and at each change while the engine
/// knows the window (a change after it left would keep a dead id).
func publishTitle(_ windowId: UInt32, _ ax: AXUIElement, onlyIfKnown: Bool = false) {
    let title = ax.get(Ax.titleAttr)
    Task.startUnstructured { @MainActor in
        if !onlyIfKnown || MacWindow.allWindowsMap[windowId] != nil { windowTitles[windowId] = title }
    }
}

func titleObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    if let windowId = ax.containingWindowId() { publishTitle(windowId, ax, onlyIfKnown: true) }
}

/// In memory until the engine starts, which loads Application Support's; tests never touch that file.
@MainActor var windowSlots = WindowSlots()

@MainActor
@Observable
final class WindowSlots {
    /// ~/Library/Application Support/Pilot/window-slots.json
    static let standardFile = PilotFolder.support.appending(path: "window-slots.json")
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// How long windows that left stay part of their app's quit: an app's windows may go a refresh or two before macOS
    /// reports the app terminated.
    static let quitWindow: TimeInterval = 10

    var slots: [WindowSlot] { didSet { save() } }

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let now: () -> Date
    /// Per app process, its tiled windows' slots from the first of its windows to leave, until it quits.
    @ObservationIgnored private var leaving: [pid_t: (since: Date, slots: [UInt32: WindowSlot])] = [:]

    init(file: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        let stored = file.flatMap { try? DayFile<[WindowSlot]>(url: $0).load(or: []) } ?? []
        slots = stored.filter { Self.isFresh($0, at: now()) }
    }

    /// Before the tree lets `windows` go: each of their apps' tiled windows as they sit now, should that app be quitting.
    func windowsLeaving(_ windows: [Window]) { record(Set(windows.map(\.app.pid))) }

    /// The app `pid` quit: its tiled windows' slots, those still in the tree and those that just left, replace its saved ones.
    func appQuit(pid: pid_t) {
        record([pid])
        guard let quit = leaving.removeValue(forKey: pid)?.slots, let app = quit.values.first?.appBundleId else { return }
        slots = slots.filter { $0.appBundleId != app } + quit.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A new window's title, read only when `appBundleId` has a slot under a week old; nil when it has none.
    func title(for appBundleId: String?, read: () async throws -> String) async rethrows -> String? {
        mine(appBundleId).isEmpty ? nil : try await read()
    }

    /// Where a new window of `appBundleId` titled `title` goes: the slot with its title, else the app's first, taken; nil
    /// when the app has no slot under a week old or the slot's workspace is gone or off screen, so the window lands as any
    /// new one: on the workspace Sven opened it from, as in AeroSpace and Omarchy (Sven, 2026-10-24, build 88: GitHub opened
    /// on workspace 2 went back to its slot on 1, and Pilot followed it there).
    /// Synchronous, so nothing can change the tree between this and the bind (Moody Pp-ArM6Raog).
    func placement(appBundleId: String?, title: String) -> BindingData? {
        let mine = mine(appBundleId)
        guard let i = mine.first(where: { !title.isEmpty && slots[$0].title == title }) ?? mine.first else { return nil }
        return slots.remove(at: i).bindingData
    }

    private func mine(_ appBundleId: String?) -> [Int] {
        slots.indices.filter { slots[$0].appBundleId == appBundleId && Self.isFresh(slots[$0], at: now()) }
    }

    /// Drops what left too long ago, then adds each of `pids`' tiled windows not yet held, as they sit now.
    private func record(_ pids: Set<pid_t>) {
        let now = now()
        leaving = leaving.filter { now.timeIntervalSince($0.value.since) < Self.quitWindow }
        guard !pids.isEmpty else { return }
        for window in Workspace.all.flatMap(\.allLeafWindowsRecursive) where pids.contains(window.app.pid) {
            leaving[window.app.pid, default: (now, [:])].slots[window.windowId] = leaving[window.app.pid]?.slots[window.windowId]
                ?? WindowSlot(window, saved: now)
        }
    }

    private static func isFresh(_ slot: WindowSlot, at now: Date) -> Bool { now.timeIntervalSince(slot.saved) < maxAge }

    private func save() {
        if let file { try? DayFile<[WindowSlot]>(url: file).save(slots) }
    }
}

extension WindowSlot {
    /// A tiled window's slot; nil for a floating or unbound one, or an app with no bundle id.
    @MainActor init?(_ window: Window, saved: Date) {
        guard let app = window.app.rawAppBundleId, let workspace = window.nodeWorkspace,
              let parent = window.parent as? TilingContainer, let weight = try? window.getWeight(parent.orientation),
              let total = try? parent.children.sumOfDouble({ try $0.getWeight(parent.orientation) }), total > 0 else { return nil }
        guard let path = try? window.parentsWithSelf.prefix(while: { $0.parent is TilingContainer }).reversed().map({ try $0.ownIndex.orFault() })
        else { return nil }
        self.init(appBundleId: app, title: windowTitles[window.windowId] ?? "", workspace: workspace.name, path: path, share: weight / CGFloat(total), saved: saved)
    }

    /// Down the path while its containers still stand, then at the path's index there, at the weight that gives it its
    /// share once the layout spreads what is left evenly over the parent's children (layoutTiles): `n` siblings weighing
    /// `w` in all leave it s·w·(n+1)/n. Alone, a slot saved alone, or one with no share takes an even share.
    @MainActor var bindingData: BindingData? {
        guard let workspace = Workspace.existing(byName: workspace), workspace.isVisible, var parent = try? workspace.rootTilingContainer, !path.isEmpty else { return nil }
        var depth = 0
        while depth < path.count - 1, let child = parent.children.getOrNil(atIndex: path[depth]) as? TilingContainer {
            parent = child
            depth += 1
        }
        let n = parent.children.count
        let siblings = CGFloat((try? parent.children.sumOfDouble { try $0.getWeight(parent.orientation) }) ?? 0)
        var weight = WEIGHT_AUTO
        if let share, share < 1, n > 0, siblings > 0 { weight = share.coerce(in: 0.1 ... 0.9) * siblings * CGFloat(n + 1) / CGFloat(n) }
        return BindingData(parent: parent, adaptiveWeight: weight, index: min(path[depth], n))
    }
}
