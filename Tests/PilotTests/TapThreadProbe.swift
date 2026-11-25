import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Probe (taps-thread, env-gated, PILOT_TAP_PROBE=1): the main thread blocked for 250 ms, as a page build blocks it, and
/// key and click events delivered meanwhile to the keyboard tap's and the mouse-button tap's own C callbacks on the run
/// loop their sources go on, the way the window server delivers them. Each event's wait, from its delivery to the
/// callback's answer, is printed. Events are made, never posted; no tap is created.
@MainActor
@Suite("Tap thread probe")
struct TapThreadProbe {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var rows: [(name: String, ms: Double, taken: Bool, main: Bool)] = []
        var ranOnMain: [Key] = []
        var done = false
    }

    @Test("Keys and clicks pass through the taps in under a few ms while the main thread is blocked 250 ms",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_TAP_PROBE"] == "1"))
    func mainBlocked() async throws {
        let hyperH = Key(keyCode: 4), mouse4 = MouseKeys.button(3)
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let buttons = MouseButtonTap(layer: tap)
        let box = Box()
        tap.isBound = { $0 == hyperH || $0 == mouse4 }
        tap.onRun = { key, _ in
            print("TAPPROBE onRun \(key.label) called on \(Thread.isMainThread ? "main" : "tap thread")")
            DispatchQueue.main.async { box.lock.withLock { box.ranOnMain.append(key) } }
        }
        func key(_ code: Int64, _ down: Bool) throws -> CGEvent {
            try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down))
        }
        func click(_ down: Bool) throws -> CGEvent {
            try #require(CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                                 mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: 3)!))
        }
        nonisolated(unsafe) let events: [(String, CGEventType, CGEvent, Bool)] = [
            ("plain a down", .keyDown, try key(0, true), false), ("plain a up", .keyUp, try key(0, false), false),
            ("F18 (Hyper) down", .keyDown, try key(KeyCode.f18, true), false), ("Hyper+H down", .keyDown, try key(4, true), false),
            ("Hyper+H up", .keyUp, try key(4, false), false), ("F18 (Hyper) up", .keyUp, try key(KeyCode.f18, false), false),
            ("Mouse 4 down", .otherMouseDown, try click(true), true), ("Mouse 4 up", .otherMouseUp, try click(false), true),
        ]
        nonisolated(unsafe) let keyInfo = Unmanaged.passUnretained(tap).toOpaque()
        nonisolated(unsafe) let buttonInfo = Unmanaged.passUnretained(buttons).toOpaque()
        nonisolated(unsafe) let loop = EventTapThread.shared.runLoop
        nonisolated(unsafe) let proxy = OpaquePointer(bitPattern: 1)!
        DispatchQueue.global(qos: .userInteractive).async {
            usleep(30_000)   // inside the main thread's 250 ms
            for (name, type, event, isButton) in events {
                let answered = DispatchSemaphore(value: 0)
                let start = DispatchTime.now().uptimeNanoseconds
                nonisolated(unsafe) var taken = false
                nonisolated(unsafe) var onMain = false
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                    let callback = isButton ? MouseButtonTap.callback : HyperTap.callback
                    taken = callback(proxy, type, event, isButton ? buttonInfo : keyInfo) == nil
                    onMain = Thread.isMainThread
                    answered.signal()
                }
                CFRunLoopWakeUp(loop)
                answered.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                box.lock.withLock { box.rows.append((name, ms, taken, onMain)) }
                usleep(20_000)   // spread over the main thread's 250 ms
            }
            box.lock.withLock { box.done = true }
        }
        let blockedFor = Self.blockMain(until: { box.lock.withLock { box.done } })
        try await Task.sleep(for: .milliseconds(100))   // the main queue drains the hops to main
        let rows = box.lock.withLock { box.rows }
        print("TAPPROBE main blocked \(blockedFor)")
        for row in rows {
            print("TAPPROBE \(row.name): \(String(format: "%.3f", row.ms)) ms, \(row.taken ? "taken" : "passed"), callback on \(row.main ? "main" : "tap thread")")
        }
        print("TAPPROBE binds run on main afterwards: \(box.lock.withLock { box.ranOnMain.map(\.label) })")
        #expect(rows.map(\.taken) == [false, false, true, true, true, true, true, true])
        #expect(rows.allSatisfy { $0.ms < 5 }, "every event answered in under 5 ms")
        #expect(box.lock.withLock { box.ranOnMain } == [hyperH, mouse4])
    }

    @Test("The bind table the tap reads off the main thread follows every change to the store, and Key binds' switch",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_TAP_PROBE"] == "1"))
    func tableFollowsStore() throws {
        let binds = Binds()
        let keys = ["apps.launcher": Key("space"), "apps.files": Key("f")]
        binds.load(presets: Dictionary(uniqueKeysWithValues: BindStore.Base.allCases.map { ($0, keys) }), actions: Array(keys.keys))
        #expect(binds.table.runs(Key("f")) && !binds.table.runs(Key("y")))
        try binds.set("apps.files", to: Key("y"))
        #expect(binds.table.runs(Key("y")) && !binds.table.runs(Key("f")), "a new key runs at once, the old one frees")
        binds.table.set(keyBinds: false)
        #expect(!binds.table.runs(Key("y")) && binds.table.runs(Key("space")), "Key binds off: only the launcher runs")
        print("TAPPROBE table: Hyper+Y runs after set, Hyper+F free; Key binds off leaves only Hyper+Space")
    }

    /// The main thread busy 250 ms, as a page build is, then its run loop turned until `done` (a block put on the main
    /// run loop runs then).
    private static func blockMain(until done: () -> Bool) -> Duration {
        let blocked = ContinuousClock.now
        Thread.sleep(forTimeInterval: 0.25)
        let blockedFor = ContinuousClock.now - blocked
        while !done() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        return blockedFor
    }
}
