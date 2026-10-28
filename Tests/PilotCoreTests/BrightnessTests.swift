import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423313 (story 144): the DDC bytes, the route each screen takes, the 1/16 steps and the newest-value
/// queue, all on fakes; no test touches a real screen.
@Suite("Brightness")
struct BrightnessTests {
    /// Screens by id: what Apple's call and DDC answer, and every write that reached them.
    final class FakeHardware: BrightnessHardware, @unchecked Sendable {
        let apple: [UInt32: Double], ddc: [UInt32: Double]
        private let lock = NSLock()
        private var _writes: [(UInt32, Double, BrightnessRoute)] = []
        var writes: [(UInt32, Double, BrightnessRoute)] { lock.withLock { _writes } }

        init(apple: [UInt32: Double] = [:], ddc: [UInt32: Double] = [:]) { self.apple = apple; self.ddc = ddc }
        func readApple(_ display: UInt32) -> Double? { apple[display] }
        func readDDC(_ display: UInt32) -> Double? { ddc[display] }
        func write(_ level: Double, to display: UInt32, over route: BrightnessRoute) -> Bool {
            lock.withLock { _writes.append((display, level, route)) }
            return true
        }
    }

    @Test("Set and Get VCP carry the length byte, the body and the XOR checksum from 0x6E and 0x51")
    func packets() {
        #expect(DDC.set(0x10, to: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.set(0x10, to: 0x0102) == [0x84, 0x03, 0x10, 0x01, 0x02, 0xAB])
        #expect(DDC.get(0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test("A reply reads current and maximum; a bad checksum, an unsupported code or another code reads nothing")
    func replies() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x20, 0xE0]
        #expect(DDC.reply(reply, for: 0x10).map { [$0.current, $0.max] } == [32, 100])
        var broken = reply
        broken[10] = 0xE1
        #expect(DDC.reply(broken, for: 0x10) == nil)
        func signed(_ bytes: [UInt8]) -> [UInt8] { Array(bytes[..<10]) + [bytes[..<10].reduce(0x50, ^)] }
        var unsupported = reply
        unsupported[3] = 0x01
        #expect(DDC.reply(signed(unsupported), for: 0x10) == nil)
        #expect(DDC.reply(reply, for: 0x12) == nil)
        #expect(DDC.reply(Array(reply.prefix(8)), for: 0x10) == nil)
    }

    @Test("Each screen takes Apple's route, then DDC, then none; HDR on a non-Apple screen skips Apple's claim")
    @MainActor func routes() async {
        let hardware = FakeHardware(apple: [1: 0.5, 2: 0.7], ddc: [2: 0.32, 3: 0.4])
        let brightness = Brightness(hardware: hardware)
        await brightness.refresh([.init(id: 1, appleAllowed: true), .init(id: 2, appleAllowed: false),
                                  .init(id: 3, appleAllowed: true), .init(id: 4, appleAllowed: true)])
        #expect(brightness.screens[1] == .init(route: .apple, level: 0.5))
        #expect(brightness.screens[2] == .init(route: .ddc, level: 0.32), "DisplayServices claims it, the guard says no")
        #expect(brightness.screens[3] == .init(route: .ddc, level: 0.4))
        #expect(brightness.screens[4] == .init(route: .none, level: nil))
        await brightness.refresh([.init(id: 3, appleAllowed: true)])
        #expect(Array(brightness.screens.keys) == [3], "screens that are gone are forgotten")
    }

    @Test("Steps land on the 1/16 grid and stop at 0 and 1")
    func steps() {
        #expect(Brightness.next(0.5, up: true) == 9.0 / 16)
        #expect(Brightness.next(0.5, up: false) == 7.0 / 16)
        #expect(Brightness.next(0.32, up: true) == 6.0 / 16)
        #expect(Brightness.next(0.32, up: false) == 5.0 / 16)
        #expect(Brightness.next(1, up: true) == 1)
        #expect(Brightness.next(0.02, up: false) == 0)
    }

    @Test("A step moves the cached level at once and writes it over the screen's route; no control writes nothing")
    @MainActor func stepWrites() async {
        let hardware = FakeHardware(ddc: [1: 0.32])
        let brightness = Brightness(hardware: hardware)
        #expect(brightness.step(1, up: true) == nil, "not read yet")
        await brightness.refresh([.init(id: 1, appleAllowed: true), .init(id: 2, appleAllowed: true)])
        #expect(brightness.step(1, up: true) == 6.0 / 16)
        #expect(brightness.screens[1]?.level == 6.0 / 16)
        #expect(brightness.step(2, up: true) == nil)
        #expect(brightness.set(2, 0.5) == nil)
        #expect(brightness.set(1, 1.4) == 1, "a level is clamped")
        await brightness.refresh([.init(id: 1, appleAllowed: true)])  // runs on screen 1's queue, after its writes
        #expect(hardware.writes.allSatisfy { $0.0 == 1 && $0.2 == .ddc })
        #expect(hardware.writes.last?.1 == 1)
    }

    @Test("While one write runs, later values replace each other and only the newest goes next")
    func newestWins() async {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let sent = Sent()
        let queue = NewestValueQueue<Int>(label: "test.newest") { value in
            if value == 1 { started.signal(); release.wait() }
            sent.add(value)
        }
        queue.submit(1)
        await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
        for value in 2...4 { queue.submit(value) }
        release.signal()
        await queue.run {}
        #expect(sent.values == [1, 4])
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int] = []
        var values: [Int] { lock.withLock { _values } }
        func add(_ value: Int) { lock.withLock { _values.append(value) } }
    }
}
