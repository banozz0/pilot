import Foundation
import Observation

/// How Pilot reaches a screen's brightness (story 144): Apple's own call, DDC/CI to the monitor, or nothing.
public enum BrightnessRoute: String, Sendable {
    case apple, ddc, none

    /// Setup › Displays' label for the route.
    public var label: String {
        switch self {
        case .apple: "Apple"
        case .ddc: "DDC"
        case .none: "no control"
        }
    }
}

/// The DDC/CI bytes for VESA's VCP codes, as the I2C write at chip 0x37, data address 0x51 carries them. Each packet is
/// a length byte (0x80 | its size), the body and an XOR checksum that starts from the monitor's address 0x6E and 0x51;
/// a reply's checksum starts from the host's 0x50. Packets per the DDC/CI standard, as m1ddc and MonitorControl send them.
public enum DDC {
    public static let chip: UInt32 = 0x37
    public static let dataAddress: UInt32 = 0x51
    /// VCP 0x10: luminance.
    public static let brightness: UInt8 = 0x10
    public static let replyLength = 11

    /// Set VCP: 0x84 0x03 code high low checksum.
    public static func set(_ code: UInt8, to value: UInt16) -> [UInt8] { framed([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]) }

    /// Get VCP: 0x82 0x01 code checksum.
    public static func get(_ code: UInt8) -> [UInt8] { framed([0x01, code]) }

    /// A Get VCP reply's current and maximum value; nil when its checksum, opcode, result or code is off, or it says no maximum.
    public static func reply(_ bytes: [UInt8], for code: UInt8) -> (current: Int, max: Int)? {
        guard bytes.count >= replyLength, bytes[..<10].reduce(0x50, ^) == bytes[10],
              bytes[2] == 0x02, bytes[3] == 0x00, bytes[4] == code else { return nil }
        let max = Int(bytes[6]) << 8 | Int(bytes[7])
        return max > 0 ? (Int(bytes[8]) << 8 | Int(bytes[9]), max) : nil
    }

    private static func framed(_ body: [UInt8]) -> [UInt8] {
        let packet = [0x80 | UInt8(body.count)] + body
        return packet + [packet.reduce(0x6E ^ UInt8(dataAddress), ^)]
    }
}

/// The calls behind the routes, all blocking: DisplayServices and IOAVService on the Mac, a fake in the tests. Reads and
/// writes run on the screen's own queue, never on the main thread, except Apple's quick read.
public protocol BrightnessHardware: Sendable {
    /// The level, 0 to 1, when DisplayServices can change this screen; nil otherwise.
    func readApple(_ display: UInt32) -> Double?
    /// The level over DDC/CI; nil when the monitor does not answer.
    func readDDC(_ display: UInt32) -> Double?
    /// False when the screen refused.
    func write(_ level: Double, to display: UInt32, over route: BrightnessRoute) -> Bool
}

/// Sends only the newest value: while one send runs, later values replace each other and only the last goes next, so a
/// held key or a dragged slider never queues up writes the monitor would play back. One serial queue per screen, which
/// its reads share, so a read never interleaves with a write.
public final class NewestValueQueue<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let send: @Sendable (Value) -> Void
    private let lock = NSLock()
    private var waiting: Value?
    private var draining = false

    public init(label: String, send: @escaping @Sendable (Value) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.send = send
    }

    public func submit(_ value: Value) {
        let start = lock.withLock { () -> Bool in
            waiting = value
            if draining { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    /// Runs `work` on this queue, after the send in flight.
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }

    private func drain() {
        while let value = take() { send(value) }
    }

    private func take() -> Value? {
        lock.withLock {
            guard let value = waiting else { draining = false; return nil }
            waiting = nil
            return value
        }
    }
}

/// Every screen's brightness (story 144, card agent-bo-95423313): its route and level, read when a screen connects, wakes
/// or the setup changes, never on a key press. A step or a slider moves the cached level at once and the write follows in
/// the background, newest value first.
@MainActor @Observable
public final class Brightness {
    public struct Screen: Equatable, Sendable {
        public var route: BrightnessRoute
        /// 0 to 1; nil only with no route.
        public var level: Double?
    }

    /// A screen to read. A non-Apple screen with HDR on is no Apple display, though DisplayServices may claim it
    /// (MonitorControl's guard): the caller says so through `appleAllowed`.
    public struct Display: Sendable {
        public let id: UInt32
        public let appleAllowed: Bool
        public init(id: UInt32, appleAllowed: Bool) { self.id = id; self.appleAllowed = appleAllowed }
    }

    /// Steps per full range, as macOS's own brightness keys.
    public nonisolated static let steps = 16.0

    /// Screens read so far, by CGDirectDisplayID.
    public private(set) var screens: [UInt32: Screen] = [:]
    @ObservationIgnored private let hardware: any BrightnessHardware
    @ObservationIgnored private var queues: [UInt32: NewestValueQueue<Write>] = [:]
    @ObservationIgnored private var generation = 0

    private struct Write: Sendable { let level: Double, route: BrightnessRoute }

    public init(hardware: any BrightnessHardware) { self.hardware = hardware }

    /// Reads every screen's route and level in parallel, each on its own queue (a monitor that never answers costs about
    /// 0.5 s there), and forgets screens that are gone. A newer refresh wins over one still running.
    public func refresh(_ displays: [Display]) async {
        generation += 1
        let mine = generation, ids = Set(displays.map(\.id))
        screens = screens.filter { ids.contains($0.key) }
        queues = queues.filter { ids.contains($0.key) }
        let hardware = hardware
        await withTaskGroup(of: (UInt32, Screen).self) { group in
            for display in displays {
                let queue = queue(display.id)
                group.addTask { (display.id, await queue.run { Self.probe(display, hardware) }) }
            }
            for await (id, screen) in group where mine == generation { screens[id] = screen }
        }
    }

    /// Apple's route, then DDC, then none: the first that works.
    nonisolated static func probe(_ display: Display, _ hardware: any BrightnessHardware) -> Screen {
        if display.appleAllowed, let level = hardware.readApple(display.id) { return Screen(route: .apple, level: level) }
        if let level = hardware.readDDC(display.id) { return Screen(route: .ddc, level: level) }
        return Screen(route: .none, level: nil)
    }

    /// One step up or down; the new level, or nil when the screen has no control or is not read yet. An Apple screen's
    /// level is read afresh first, since macOS's own keys and auto-brightness move it too.
    @discardableResult
    public func step(_ display: UInt32, up: Bool) -> Double? {
        guard let screen = screens[display], let cached = screen.level else { return nil }
        let level = screen.route == .apple ? hardware.readApple(display) ?? cached : cached
        return set(display, Self.next(level, up: up))
    }

    /// Sets a level (Setup's slider); the level set, or nil when the screen has no control.
    @discardableResult
    public func set(_ display: UInt32, _ level: Double) -> Double? {
        guard let route = screens[display]?.route, route != .none else { return nil }
        let level = min(1, max(0, level))
        screens[display]?.level = level
        queue(display).submit(Write(level: level, route: route))
        return level
    }

    /// The next 1/16 mark up or down from a level, so an odd level lands on the grid.
    public nonisolated static func next(_ level: Double, up: Bool) -> Double {
        let at = level * steps
        let mark = up ? (at + 1e-6).rounded(.down) + 1 : (at - 1e-6).rounded(.up) - 1
        return min(1, max(0, mark / steps))
    }

    private func queue(_ display: UInt32) -> NewestValueQueue<Write> {
        if let queue = queues[display] { return queue }
        let hardware = hardware
        let queue = NewestValueQueue<Write>(label: "dev.banozz.pilot.brightness.\(display)") { write in
            _ = hardware.write(write.level, to: display, over: write.route)
        }
        queues[display] = queue
        return queue
    }
}
