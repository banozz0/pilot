// Pilot (spec scrolling-layout T7, 2026-10-12): how the focus hand-off brings another app forward on macOS 14 and later.
import AppKit

/// One way to bring an app forward. macOS 14's cooperative activation refuses a plain `activate()` from an app that is not
/// in front and got no user event of its own, and Pilot's key tap consumes the press (ADR 0001): every hand-off to another
/// app was refused (build 44, 16 of 16 logged `activate false` with the raise done). A way being allowed is not the app
/// being in front (Apple: allowed "does not guarantee" activation), so each one is confirmed before the next is tried.
enum AppActivation: String, Sendable {
    /// SkyLight's front-process call and key-window records, as yabai and AltTab bring a window forward (SkyLight).
    case skyLight = "SkyLight"
    /// `activate(from: front)`: the app takes the active status from the app in front at the press.
    case fromFront = "from the front app"
    /// The app element's AXFrontmost set true: the app activates itself on an Accessibility request.
    case axFrontmost = "AX frontmost"
    /// `activate()`.
    case plain

    /// The order the hand-off tries: the private call that works on macOS 14 and later first, the public ones after.
    static let order: [AppActivation] = [.skyLight, .fromFront, .axFrontmost, .plain]

    /// One way tried: whether macOS allowed it, and whether the app was in front after it.
    struct Step: Equatable, Sendable {
        let way: AppActivation
        let allowed: Bool
        let front: Bool
    }

    /// How a hand-off ended: the steps it took, and whether a newer press took over before the app was in front.
    struct Outcome: Equatable, Sendable {
        var steps: [Step] = []
        var superseded = false
        /// The way that put the app in front; nil when none did (or it was in front before any).
        var landed: AppActivation? { steps.last.flatMap { $0.front ? $0.way : nil } }
        /// Every way tried and the app still behind.
        var refused: Bool { !steps.isEmpty && landed == nil && !superseded }

        var line: String {
            let tried = steps.map { "\($0.way.rawValue) \($0.allowed ? "allowed" : "refused")\($0.allowed ? $0.front ? ", front" : ", not front" : "")" }
            let end = superseded ? "superseded by a newer focus or another app in front" : landed.map { "front by \($0.rawValue)" }
                ?? (refused ? "not front after every way" : "already front")
            return (tried + [end]).joined(separator: "; ")
        }
    }

    /// Tries `ways` in order until the app is in front: `isFront` is asked at once, then after each allowed way up to
    /// `polls` times with `pause` between; a refused way moves on at once. `isCurrent` turns false once a newer press
    /// took over (asked before each way, after it, and after each pause), and nothing more is tried or counted.
    @MainActor
    static func bringForward(_ ways: [AppActivation] = order, polls: Int = 8, isCurrent: () -> Bool, isFront: () -> Bool,
                             pause: () async -> Void, attempt: (AppActivation) async -> Bool) async -> Outcome {
        var outcome = Outcome()
        guard !isFront() else { return outcome }
        for way in ways {
            guard isCurrent() else { outcome.superseded = true; return outcome }
            let allowed = await attempt(way)
            guard isCurrent() else { outcome.superseded = true; return outcome }
            var front = false
            if allowed {
                for _ in 0..<polls {
                    if isFront() { front = true; break }
                    await pause()
                    guard isCurrent() else { outcome.superseded = true; return outcome }
                }
                front = front || isFront()
            }
            outcome.steps.append(Step(way: way, allowed: allowed, front: front))
            if front { return outcome }
        }
        return outcome
    }
}

/// SkyLight's front-process call, as yabai (`window_manager_focus_window_with_raise`) and AltTab make it: the process to the
/// front for its window, then the two window-server records that make that window key. They are focus records, no key
/// events (ADR 0001). The symbols are looked up at run time, so a macOS without them falls back to the public ways.
enum SkyLight {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ProcessForPid = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private nonisolated(unsafe) static let calls: (setFront: SetFront, post: PostRecord, process: ProcessForPid)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"), let post = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let process = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") // RTLD_DEFAULT
        else { return nil }
        return (unsafeBitCast(setFront, to: SetFront.self), unsafeBitCast(post, to: PostRecord.self), unsafeBitCast(process, to: ProcessForPid.self))
    }()

    /// Brings app `pid` forward with its window `windowId` key; false when a symbol is missing or a call fails.
    static func bringForward(pid: pid_t, windowId: UInt32) -> Bool {
        guard let calls else { return false }
        var psn = ProcessSerialNumber()
        guard calls.process(pid, &psn) == noErr, calls.setFront(&psn, windowId, 0x200) == 0 else { return false } // kCPSUserGenerated
        for kind: UInt8 in [1, 2] {
            var record = [UInt8](repeating: 0, count: 0xf8)
            record[0x04] = 0xf8
            record[0x08] = kind
            record[0x3a] = 0x10
            record.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
            withUnsafeBytes(of: windowId.littleEndian) { record.replaceSubrange(0x3c..<0x40, with: $0) }
            _ = record.withUnsafeMutableBufferPointer { calls.post(&psn, $0.baseAddress!) }
        }
        return true
    }
}
