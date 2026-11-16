// Pilot (live bug 2026-11-16): a window whose app will not let it shrink to its tile ran under its neighbour (Vesktop,
// 940 x 500 at the least, in a 430-point column of Centred main on a 1920-point screen). AX names no minimum size, so the
// tiler learns it from its own writes: the size an app takes back when asked for less. layoutTiles then gives that
// window its least size and the tiles beside it give way (TileFit), without touching the tree's weights, so the preset's
// shares come back once it goes.
import AppKit
import Synchronization

/// The windows `WindowMinimums` holds a size or a pending one for, readable from the AX threads: their every write is
/// news, a write of any other one only when the app took more than it was asked.
private let watched = Mutex<Set<UInt32>>([])

/// The least size each window's app lets it be, as the tiler's frame writes found it, on the main actor where layout
/// reads it. An app's AX thread reports each tiled write's outcome (`report`); a larger size counts only once a second
/// write finds the same, so an app that resizes late is not taken for one that refuses.
@MainActor
enum WindowMinimums {
    private static var known: [UInt32: CGSize] = [:]
    /// A size taken back once, waiting for the next write to bear it out.
    private static var seen: [UInt32: CGSize] = [:]

    static func least(_ windowId: UInt32) -> CGSize? { known[windowId] }

    /// No window is known to refuse a size: layout keeps its weights as they are.
    static var isEmpty: Bool { known.isEmpty }

    static func forget(_ windowId: UInt32) {
        known[windowId] = nil
        seen[windowId] = nil
        watched.withLock { _ = $0.remove(windowId) }
    }

    /// From an app's AX thread: window `windowId` was asked for `asked` and took `took`. Most writes take what they ask
    /// and are no news, so only a refusal or a watched window's write goes to the main actor.
    nonisolated static func report(_ windowId: UInt32, asked: CGSize, took: CGSize) {
        guard took.width > asked.width + 1 || took.height > asked.height + 1 || watched.withLock({ $0.contains(windowId) }) else { return }
        Task.startUnstructured { @MainActor in
            if learn(windowId, asked: asked, took: took) { scheduleCancellableCompleteRefreshSession(.pilotCall("window minimum")) }
        }
    }

    /// Updates what is known of `windowId` from one write, each side apart; whether layout should run again: a larger
    /// size seen the first time (to bear it out) or borne out (to make room for it).
    @discardableResult
    static func learn(_ windowId: UInt32, asked: CGSize, took: CGSize) -> Bool {
        var least = known[windowId] ?? .zero, pending = seen[windowId] ?? .zero, again = false
        func side(_ asked: CGFloat, _ took: CGFloat, _ least: inout CGFloat, _ pending: inout CGFloat) {
            guard took > asked + 1 else {
                // It took what it was asked, or less: its least is no more than that.
                least = min(least, took)
                pending = 0
                return
            }
            guard took > least + 1 else { return } // known already
            if abs(pending - took) <= 1 {
                least = took
                pending = 0
            } else {
                pending = took
            }
            again = true
        }
        side(asked.width, took.width, &least.width, &pending.width)
        side(asked.height, took.height, &least.height, &pending.height)
        known[windowId] = least == .zero ? nil : least
        seen[windowId] = pending == .zero ? nil : pending
        let watching = known[windowId] != nil || seen[windowId] != nil
        watched.withLock { if watching { $0.insert(windowId) } else { $0.remove(windowId) } }
        return again
    }
}
