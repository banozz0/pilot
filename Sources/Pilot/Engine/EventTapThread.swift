import CoreFoundation
import Foundation
import Synchronization

/// The run loop the keyboard tap, the mouse-button tap and the drag tap's press tap are on: a thread of their own, so a
/// main-thread turn (a page built, a window's warm-up) never holds a key or a click anywhere on the Mac (load-lag: a page
/// build held every key up to 250 ms). Their callbacks read only locked state and hand actions to the main queue; a press
/// the drag tap may take waits for the main thread's answer (waitOnMain).
final class EventTapThread: Sendable {
    static let shared = EventTapThread()

    /// CFRunLoop is thread-safe for adding, removing and waking sources.
    nonisolated(unsafe) let runLoop: CFRunLoop

    private init() {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            // A source that never fires keeps the run loop running before any tap's source is on it.
            var context = CFRunLoopSourceContext()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
            ready.signal()
            while true { CFRunLoopRun() }
        }
        thread.name = "dev.banozz.pilot.event-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loop!
    }

    func add(_ source: CFRunLoopSource) {
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    func remove(_ source: CFRunLoopSource) { CFRunLoopRemoveSource(runLoop, source, .commonModes) }

    /// Runs `body` on the tap thread once its current callback, if any, has returned.
    func perform(_ body: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }
}

/// Runs `body` on the main thread and waits for it, up to `timeout` seconds: false when the main thread had not taken it
/// by then, and it never runs. A block on the main run loop in its common modes, as a tap's source there was, so it runs
/// inside a nested run loop too (a menu's tracking), where the main queue may be held by the block that opened it.
func waitOnMain(timeout: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Bool {
    final class Handoff: Sendable {
        let done = DispatchSemaphore(value: 0), claimed = Atomic(false)
        func claim() -> Bool { claimed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged }
    }
    let handoff = Handoff()
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        guard handoff.claim() else { return }
        MainActor.assumeIsolated { body() }
        handoff.done.signal()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    if handoff.done.wait(timeout: .now() + timeout) == .success { return true }
    if handoff.claim() { return false }   // never started: it never will
    handoff.done.wait()                   // started just now: its answer stands
    return true
}

/// Runs `body` on the main queue, after the tap callback that calls it returned, in the order the tap handed them over.
func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// A main-thread hook as the tap calls it: each call goes to the main queue with its arguments, in order, and the tap
/// goes on at once. One FIFO queue for every hook keeps a bind's run ahead of its release.
func hopping(_ body: @escaping () -> Void) -> () -> Void {
    nonisolated(unsafe) let body = body
    return { DispatchQueue.main.async { body() } }
}

func hopping<A>(_ body: @escaping (A) -> Void) -> (A) -> Void {
    nonisolated(unsafe) let body = body
    return { a in
        nonisolated(unsafe) let a = a
        DispatchQueue.main.async { body(a) }
    }
}

func hopping<A, B>(_ body: @escaping (A, B) -> Void) -> (A, B) -> Void {
    nonisolated(unsafe) let body = body
    return { a, b in
        nonisolated(unsafe) let a = a, b = b
        DispatchQueue.main.async { body(a, b) }
    }
}
