// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/util/Nullable.swift
/// Like Swift's built-in Optional but avoids implicit nil coercions
public enum Nullable<T> {
    case just(T)
    case null

    public var valueOrNil: T? {
        switch self {
            case .just(let value): value
            case .null: nil
        }
    }

    public var isNull: Bool { valueOrNil == nil }
}
