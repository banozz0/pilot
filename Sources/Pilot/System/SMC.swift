import Foundation
import IOKit
import PilotCore

/// The SMC's private user client (AppleSMC), read the way the Stats app (exelban/stats, MIT) reads it, none of its code
/// (card agent-bo-95422832): selector 2 with the classic 80-byte SMCKeyData struct, 9 for a key's size and type, 5 to read
/// it, 8 for the key at an index. Opened once and kept; the CPU, GPU and chip (Ts) temperature keys are found once, on the
/// first read, by walking every key (about 1 400 on an M4, a fraction of a second, off the main thread). A call costs
/// about 130 µs and an M4 has over a hundred such keys, so each read takes a quarter of them in turn, plus the fans and
/// PSTR, and keeps the rest from earlier: every sensor is fresh within four ticks, a read about 4 ms. Apple documents none
/// of it, so a macOS update may change it: every failure gives no reading, never a crash, and This Mac then shows no
/// sensor rows. Reads only, never a write.
final class SMC: @unchecked Sendable {
    static let shared = SMC()

    /// SMCKeyData_t as the kernel lays it out: the key info struct pads to 12 bytes, written out here as two spare bytes.
    private struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0, padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    private struct Key { let code: UInt32, name: String, size: UInt32, type: String }

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var temperatureKeys: [Key] = []
    /// Each fan's speed key with its range, which never changes, read once.
    private var fanKeys: [(actual: Key, minimum: Double, maximum: Double)] = []
    private var powerKey: Key?, powerInKey: Key?
    private var temperatures: [String: Double] = [:]
    private var primed = false
    private var cursor = 0

    private init() {
        guard MemoryLayout<KeyData>.stride == 80 else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { connection = 0; return }
        let count = SMCValue.count(key("#KEY").flatMap(value), limit: 10_000)
        // Every key a row reads: the CPU's, the GPU's and the rest of the chip's (Ts, for SoC).
        let prefixes = Set(SystemStats.cpuSensors + SystemStats.gpuSensors + SystemStats.socSensors)
        temperatureKeys = (0..<count).compactMap { index -> Key? in
            var data = KeyData()
            data.command = 8
            data.index = UInt32(index)
            guard call(&data) else { return nil }
            let name = Self.name(data.key)
            guard prefixes.contains(where: name.hasPrefix) else { return nil }
            return key(name)
        }
        // A range that does not read is NaN, which the rows leave off.
        fanKeys = (0..<SMCValue.count(key("FNum").flatMap(value), limit: 4)).compactMap { i in
            key("F\(i)Ac").map { ($0, key("F\(i)Mn").flatMap(value) ?? .nan, key("F\(i)Mx").flatMap(value) ?? .nan) }
        }
        powerKey = key("PSTR")
        powerInKey = key("PDTR")
    }

    /// Every sensor that reads, or nil when the SMC cannot be opened.
    func sensors() -> SystemStats.Sensors? {
        lock.withLock {
            guard connection != 0 else { return nil }
            // The first read takes every key, so the first reading is whole.
            let slice = primed ? (temperatureKeys.count + 3) / 4 : temperatureKeys.count
            primed = true
            for _ in 0..<slice {
                let key = temperatureKeys[cursor % temperatureKeys.count]
                temperatures[key.name] = value(key)
                cursor += 1
            }
            let fans = fanKeys.compactMap { keys -> SystemStats.Fan? in
                guard let actual = value(keys.actual) else { return nil }
                return .init(actual: actual, minimum: keys.minimum, maximum: keys.maximum)
            }
            return .init(temperatures: temperatures, fans: fans, power: powerKey.flatMap(value), powerIn: powerInKey.flatMap(value))
        }
    }

    /// The whole Mac's draw in watts (PSTR) alone, one call: the battery item's reading on a Mac with no battery.
    func power() -> Double? {
        lock.withLock { connection == 0 ? nil : powerKey.flatMap(value) }
    }

    private func key(_ name: String) -> Key? {
        let code = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var data = KeyData()
        data.key = code
        data.command = 9
        guard name.utf8.count == 4, call(&data), data.size > 0, data.size <= 32 else { return nil }
        return Key(code: code, name: name, size: data.size, type: Self.name(data.type))
    }

    private func value(_ key: Key) -> Double? {
        var data = KeyData()
        data.key = key.code
        data.size = key.size
        data.command = 5
        guard call(&data) else { return nil }
        let bytes = withUnsafeBytes(of: data.bytes) { Array($0.prefix(Int(key.size))) }
        return SMCValue.decode(type: key.type, bytes: bytes)
    }

    private func call(_ data: inout KeyData) -> Bool {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        guard IOConnectCallStructMethod(connection, 2, &data, MemoryLayout<KeyData>.stride, &output, &size) == KERN_SUCCESS,
              output.result == 0 else { return false }
        data = output
        return true
    }

    private static func name(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}
