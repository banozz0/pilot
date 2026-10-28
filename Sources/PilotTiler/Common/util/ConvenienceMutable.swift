// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/util/ConvenienceMutable.swift
public protocol ConvenienceMutable: ~Copyable {}

extension ConvenienceMutable {
    public consuming func copy<T>(_ key: WritableKeyPath<Self, T>, _ value: T) -> Self {
        self[keyPath: key] = value
        return self
    }
}
