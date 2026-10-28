// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/config/DynamicConfigValue.swift (lines 1-31) and parseGaps.swift (lines 1-83); the TOML parsers are dropped.

struct PerMonitorValue<Value: Equatable>: Equatable {
    let description: MonitorDescription
    let value: Value
}
extension PerMonitorValue: Sendable where Value: Sendable {}

enum DynamicConfigValue<Value: Equatable>: Equatable {
    case constant(Value)
    case perMonitor([PerMonitorValue<Value>], default: Value)
}
extension DynamicConfigValue: Sendable where Value: Sendable {}

extension DynamicConfigValue {
    @MainActor func getValue(for monitor: any MonitorInfo) -> Value {
        switch self {
            case .constant(let value): return value
            case .perMonitor(let array, let defaultValue):
                let sortedMonitors = sortedMonitorInfos
                return array
                    .lazy
                    .compactMap {
                        $0.description.resolveMonitor(sortedMonitors: sortedMonitors)?.rect.topLeftCorner == monitor.rect.topLeftCorner
                            ? $0.value
                            : nil
                    }
                    .first ?? defaultValue
        }
    }
}


struct Gaps: ConvenienceMutable, Equatable, Sendable {
    var inner: Inner
    var outer: Outer

    static let zero = Gaps(inner: .zero, outer: .zero)

    struct Inner: ConvenienceMutable, Equatable, Sendable {
        var vertical: DynamicConfigValue<Int>
        var horizontal: DynamicConfigValue<Int>

        static let zero = Inner(vertical: 0, horizontal: 0)

        init(vertical: Int, horizontal: Int) {
            self.vertical = .constant(vertical)
            self.horizontal = .constant(horizontal)
        }
    }

    struct Outer: ConvenienceMutable, Equatable, Sendable {
        var left: DynamicConfigValue<Int>
        var bottom: DynamicConfigValue<Int>
        var top: DynamicConfigValue<Int>
        var right: DynamicConfigValue<Int>

        static let zero = Outer(left: 0, bottom: 0, top: 0, right: 0)

        init(left: Int, bottom: Int, top: Int, right: Int) {
            self.left = .constant(left)
            self.bottom = .constant(bottom)
            self.top = .constant(top)
            self.right = .constant(right)
        }

        init(left: DynamicConfigValue<Int>, bottom: DynamicConfigValue<Int>, top: DynamicConfigValue<Int>, right: DynamicConfigValue<Int>) {
            self.left = left
            self.bottom = bottom
            self.top = top
            self.right = right
        }
    }
}

struct ResolvedGaps {
    let inner: Inner
    let outer: Outer

    struct Inner {
        let vertical: Int
        let horizontal: Int

        func get(_ orientation: Orientation) -> Int {
            orientation == .h ? horizontal : vertical
        }
    }

    struct Outer {
        let left: Int
        let bottom: Int
        let top: Int
        let right: Int
    }

    @MainActor init(gaps: Gaps, monitor: any MonitorInfo) {
        inner = .init(
            vertical: gaps.inner.vertical.getValue(for: monitor),
            horizontal: gaps.inner.horizontal.getValue(for: monitor),
        )

        outer = .init(
            left: gaps.outer.left.getValue(for: monitor),
            bottom: gaps.outer.bottom.getValue(for: monitor),
            top: gaps.outer.top.getValue(for: monitor),
            right: gaps.outer.right.getValue(for: monitor),
        )
    }
}
