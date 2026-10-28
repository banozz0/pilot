// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/util/SequenceEx.swift
// periphery:ignore:all

extension Sequence {

    public func filterIsInstance<R>(of _: R.Type) -> [R] {
        var result: [R] = []
        for elem in self {
            if let elemR = elem as? R {
                result.append(elemR)
            }
        }
        return result
    }

    public var first: Element? {
        var iter = makeIterator()
        return iter.next()
    }

    @inlinable public func minBy(_ selector: (Self.Element) -> some Comparable) -> Self.Element? {
        self.min(by: { a, b in selector(a) < selector(b) })
    }

    @inlinable public func sortedBy(_ selector: (Self.Element) -> some Comparable) -> [Self.Element] {
        sorted(by: { a, b in selector(a) < selector(b) })
    }

    @inlinable public func sortedBy(_ selectors: [(Self.Element) -> some Comparable]) -> [Self.Element] {
        sorted(by: { a, b in
            for selector in selectors {
                let a = selector(a)
                let b = selector(b)
                if a < b { return true }
                if a > b { return false }
            }
            return false
        })
    }

    public func sumOfDouble(_ selector: (Self.Element) throws -> Double) rethrows -> Double {
        var result: Double = 0
        for elem in self {
            result += try selector(elem)
        }
        return result
    }

    public func sumOfInt(_ selector: (Self.Element) -> Int) -> Int {
        var result: Int = 0
        for elem in self {
            result += selector(elem)
        }
        return result
    }

    public func grouped<Group>(by criterion: (_ transforming: Element) -> Group) -> [Group: [Element]] {
        Dictionary(grouping: self, by: criterion)
    }

    public var withIndex: [(index: Int, value: Element)] {
        var index = -1
        return map {
            index += 1
            return (index, $0)
        }
    }

    public func toSet() -> Set<Element> where Element: Hashable { Set(self) }

}
