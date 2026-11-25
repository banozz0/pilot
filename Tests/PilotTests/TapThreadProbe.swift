import AppKit
import Carbon.HIToolbox
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

    @Test("The system calls the callback makes off the main thread answer there, and the tap thread idles at no CPU",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_TAP_PROBE"] == "1"))
    func offMainCalls() throws {
        let hyperH = Key(keyCode: 4)
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        final class Seen: @unchecked Sendable {
            var typed = "", pressedAt: TimeInterval?, secure = false, front: pid_t?, media = false, thread: thread_act_t = 0
        }
        let seen = Seen()
        tap.isBound = { $0 == hyperH }
        tap.onTyped = { _, characters in seen.typed += characters(); return false }   // HyperTap.characters: keyboardGetUnicodeString
        tap.onRun = { _, _ in seen.pressedAt = HyperTap.keyDownTime }                    // NSEvent(cgEvent:)
        tap.isFromMouse = { _, _ in seen.media = true; return false }                   // reached through NSEvent(cgEvent:)'s subtype
        tap.captureMouse = { _ in }   // a catch waiting: the media key asks isFromMouse
        let media = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, subtype: 8, data1: 17 << 16 | 0x0A << 8, data2: -1)?.cgEvent)
        func key(_ code: Int64, _ down: Bool) throws -> CGEvent {
            try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down))
        }
        nonisolated(unsafe) let events: [(CGEventType, CGEvent)] = [
            (.keyDown, try key(0, true)), (.keyUp, try key(0, false)),
            (.keyDown, try key(KeyCode.f18, true)), (.keyDown, try key(4, true)), (.keyUp, try key(4, false)), (.keyUp, try key(KeyCode.f18, false)),
            (CGEventType(rawValue: BrightnessKeys.eventType)!, media),
        ]
        nonisolated(unsafe) let info = Unmanaged.passUnretained(tap).toOpaque()
        nonisolated(unsafe) let proxy = OpaquePointer(bitPattern: 1)!
        nonisolated(unsafe) let loop = EventTapThread.shared.runLoop
        let answered = DispatchSemaphore(value: 0)
        // @Sendable: a block formed in this main-actor test would carry a main-actor check and trap on the tap thread.
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { @Sendable in
            seen.thread = mach_thread_self()
            for (type, event) in events { _ = HyperTap.callback(proxy, type, event, info) }
            seen.secure = IsSecureEventInputEnabled()
            seen.front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            answered.signal()
        }
        CFRunLoopWakeUp(loop)
        #expect(answered.wait(timeout: .now() + 2) == .success, "the tap thread answered")
        func cpu() -> Double {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(seen.thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
            }
            return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
        }
        let before = cpu()
        Thread.sleep(forTimeInterval: 0.3)
        let idle = (cpu() - before) * 1000
        print("TAPPROBE off main: typed \"\(seen.typed)\", key-down time \(seen.pressedAt.map { String(format: "%.3f", $0) } ?? "nil"), media key reached isFromMouse \(seen.media), secure input \(seen.secure), front pid \(seen.front.map(String.init) ?? "nil")")
        print("TAPPROBE tap thread CPU over 300 ms idle: \(String(format: "%.3f", idle)) ms")
        #expect(seen.typed == "a" && seen.pressedAt != nil && seen.media && seen.front != nil)
        #expect(idle < 5, "the tap thread sleeps between events")
    }

    @Test("Drag path: the border's frame ticker leaves no thread and no tick behind once a drag ends",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_TAP_PROBE"] == "1"))
    func tickerEnds() async throws {
        func threads() -> Int {
            var list: thread_act_array_t?, count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
            return Int(count)
        }
        final class Ticks: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let ticks = Ticks()
        try await Task.sleep(for: .milliseconds(200))
        let before = threads()
        for _ in 0..<50 {   // fifty drags, 40 ms each
            let stop = DragFollower.threadTicker { ticks.lock.withLock { ticks.n += 1 } }
            try await Task.sleep(for: .milliseconds(40))
            stop()
        }
        try await Task.sleep(for: .milliseconds(500))
        let after = threads(), ticked = ticks.lock.withLock { ticks.n }
        try await Task.sleep(for: .milliseconds(500))
        let later = ticks.lock.withLock { ticks.n }
        print("TAPPROBE drag ticker: threads \(before) before, \(after) after 50 drags; \(ticked) ticks during, \(later - ticked) in the 500 ms after")
        #expect(after - before <= 2, "no drag-frames thread outlives its drag")
        #expect(later == ticked, "no tick after the drags ended")
    }

    @Test("A click passes the drag tap's press tap in under a few ms while the main thread is blocked 250 ms",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_TAP_PROBE"] == "1"))
    func clickWhileMainBlocked() async throws {
        let layer = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let drag = MouseDragTap(modifier: { .alt }, layer: layer, tiler: TilerService(engine: WorkspaceListTests.FakeTiler(), tip: { _ in }))
        drag.widgetsShown = true   // a plain right press then asks the main thread, as a widget's menu would (no widget here)
        let box = Box()
        func click(_ type: CGEventType, _ button: CGMouseButton) throws -> CGEvent {
            try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 5, y: 5), mouseButton: button))
        }
        nonisolated(unsafe) let events: [(String, CGEventType, CGEvent)] = [
            ("left down", .leftMouseDown, try click(.leftMouseDown, .left)), ("left up", .leftMouseUp, try click(.leftMouseUp, .left)),
            ("left down", .leftMouseDown, try click(.leftMouseDown, .left)), ("left up", .leftMouseUp, try click(.leftMouseUp, .left)),
            ("right down (widgets shown: main)", .rightMouseDown, try click(.rightMouseDown, .right)),
            ("right up", .rightMouseUp, try click(.rightMouseUp, .right)),
        ]
        nonisolated(unsafe) let info = Unmanaged.passUnretained(drag).toOpaque()
        nonisolated(unsafe) let loop = EventTapThread.presses.runLoop
        // A key typed while the widgets-shown right press waits on the main thread: on the keyboard tap's own thread.
        nonisolated(unsafe) let keyInfo = Unmanaged.passUnretained(layer).toOpaque()
        nonisolated(unsafe) let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        final class KeyWait: @unchecked Sendable { var ms: Double? }
        let keyWait = KeyWait()
        nonisolated(unsafe) let proxy = OpaquePointer(bitPattern: 1)!
        DispatchQueue.global(qos: .userInteractive).async {
            usleep(30_000)
            for (name, type, event) in events {
                let answered = DispatchSemaphore(value: 0)
                let start = DispatchTime.now().uptimeNanoseconds
                nonisolated(unsafe) var taken = false
                nonisolated(unsafe) var onMain = false
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                    taken = MouseDragTap.pressCallback(proxy, type, event, info) == nil
                    onMain = Thread.isMainThread
                    answered.signal()
                }
                CFRunLoopWakeUp(loop)
                if name.hasPrefix("right down") {
                    usleep(10_000)
                    let keyAnswered = DispatchSemaphore(value: 0), keyStart = DispatchTime.now().uptimeNanoseconds
                    let keys = EventTapThread.shared.runLoop
                    CFRunLoopPerformBlock(keys, CFRunLoopMode.commonModes.rawValue) {
                        _ = HyperTap.callback(proxy, .keyDown, key, keyInfo)
                        keyAnswered.signal()
                    }
                    CFRunLoopWakeUp(keys)
                    keyAnswered.wait()
                    keyWait.ms = Double(DispatchTime.now().uptimeNanoseconds - keyStart) / 1_000_000
                }
                answered.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                box.lock.withLock { box.rows.append((name, ms, taken, onMain)) }
                usleep(20_000)
            }
            box.lock.withLock { box.done = true }
        }
        let blockedFor = Self.blockMain(until: { box.lock.withLock { box.done } })
        let rows = box.lock.withLock { box.rows }
        print("TAPPROBE click: main blocked \(blockedFor)")
        for row in rows {
            print("TAPPROBE click \(row.name): \(String(format: "%.3f", row.ms)) ms, \(row.taken ? "taken" : "passed"), callback on \(row.main ? "main" : "tap thread")")
        }
        #expect(rows.allSatisfy { !$0.taken }, "every click goes on to the app")
        #expect(rows.prefix(4).allSatisfy { $0.ms < 5 }, "plain left clicks answered in under 5 ms")
        print("TAPPROBE click: a key typed while the right press waited on main: \(keyWait.ms.map { String(format: "%.3f", $0) } ?? "nil") ms")
        #expect((keyWait.ms ?? 999) < 5, "keys go on while a press waits on the main thread")
        // What the gate leaves to the main thread: a press under Hyper, or with the drag modifier; a plain one passes.
        let alt = UInt64(CGEventFlags.maskAlternate.rawValue)
        let plain = drag.gate.passes(.leftMouseDown, flags: 0), withAlt = drag.gate.passes(.leftMouseDown, flags: alt)
        _ = layer.route(KeyEvent(kind: .keyDown, keyCode: KeyCode.f18))
        let underHyper = drag.gate.passes(.leftMouseDown, flags: 0)
        _ = layer.route(KeyEvent(kind: .keyUp, keyCode: KeyCode.f18))
        print("TAPPROBE click gate: plain passes \(plain), Alt passes \(withAlt), under Hyper passes \(underHyper), release passes \(drag.gate.passes(.leftMouseUp, flags: 0))")
        #expect(plain && !withAlt && !underHyper && drag.gate.passes(.leftMouseUp, flags: 0))
        // With no drag modifier, a press held past Hyper's release keeps the tap on for its own release.
        drag.dragging = false
        drag.widgetsShown = false
        drag.gate.set(idle: false); drag.gate.hyper(true); drag.gate.hyper(false)
        let heldOn = drag.gate.wantsOn
        drag.gate.set(idle: true)
        print("TAPPROBE click gate: a press held after Hyper's release keeps the tap on \(heldOn), off once let go \(!drag.gate.wantsOn)")
        #expect(heldOn && !drag.gate.wantsOn)
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
