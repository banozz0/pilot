/// Low-battery alerts (Sven, Q394: "my Keychron just ran out of battery and there was no way I could figure"): a Bluetooth
/// device crossing down through 20 % and then 10 % alerts once at each. A threshold rearms once the device reads above it
/// by `rearm` points, so a battery hovering at 20 % never alerts twice, and one charged while away alerts again when it
/// next runs low.
public struct LowBattery: Equatable, Sendable {
    public static let thresholds = [MenuBarStats.batteryLevels.high, MenuBarStats.batteryLevels.critical]
    public static let rearm = 5

    /// One alert: the device and the threshold it fell to.
    public struct Alert: Equatable, Sendable {
        public var name: String
        public var percent: Int
        public init(name: String, percent: Int) { self.name = name; self.percent = percent }
        public var text: String { "\(name) at \(percent)%. Charge it soon." }
    }

    /// Each device's thresholds already alerted, by name; a device that leaves keeps its own until it reads charged.
    private var fired: [String: Set<Int>] = [:]

    public init() {}

    /// The alerts this reading gives: per device, only the lowest threshold newly crossed, so a device first seen at 8 %
    /// alerts once, at 10 %, and 20 % counts as done.
    public mutating func record(_ devices: [SystemStats.BluetoothDevice]) -> [Alert] {
        devices.compactMap { device in
            guard let percent = device.percent else { return nil }
            var done = fired[device.name] ?? []
            done.subtract(Self.thresholds.filter { percent > $0 + Self.rearm })
            let crossed = Self.thresholds.filter { percent <= $0 && !done.contains($0) }
            done.formUnion(crossed)
            fired[device.name] = done.isEmpty ? nil : done
            return crossed.min().map { _ in Alert(name: device.name, percent: percent) }
        }
    }
}
