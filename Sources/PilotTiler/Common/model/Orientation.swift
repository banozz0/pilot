// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/model/Orientation.swift
public enum Orientation: Sendable {
    /// Windows are planced along the **horizontal** line
    /// x-axis
    case h
    /// Windows are planced along the **vertical** line
    /// y-axis
    case v
}

extension Orientation {
    public var opposite: Orientation { self == .h ? .v : .h }
}
