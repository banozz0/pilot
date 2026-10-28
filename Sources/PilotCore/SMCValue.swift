import Foundation

/// One SMC value's bytes by its four-letter type, as the SMC hands them (card agent-bo-95422832).
public enum SMCValue {
    /// A count the SMC gave (#KEY, FNum) as a whole number from 0 to `limit`; 0 for a failed read or nonsense, so a bad
    /// value never traps or runs a loop away.
    public static func count(_ value: Double?, limit: Int) -> Int {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return Int(min(value, Double(limit)))
    }

    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        let big = { (count: Int) in bytes.count >= count ? bytes.prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } : nil }
        switch type {
        case "flt ": return bytes.count >= 4 ? Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)) : nil
        case "fpe2": return big(2).map { Double($0) / 4 }
        case "sp78": return big(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "ui8 ": return big(1).map { Double($0) }
        case "ui16": return big(2).map { Double($0) }
        case "ui32": return big(4).map { Double($0) }
        default: return nil
        }
    }
}
