// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/SetEx.swift
// periphery:ignore
extension Set {

    @inlinable static func += (lhs: inout Set<Element>, rhs: any Sequence<Element>) {
        lhs.formUnion(rhs)
    }

    @inlinable static func -= (lhs: inout Set<Element>, rhs: any Sequence<Element>) {
        lhs.subtract(rhs)
    }
}
