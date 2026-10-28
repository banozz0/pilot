// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/UniqueToken.swift
final class UniqueToken: Equatable, Hashable, CustomStringConvertible, Sendable {
    private let hash = Int.random(in: Int.min ... Int.max)
    static func == (lhs: UniqueToken, rhs: UniqueToken) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(hash) }
    var description: String { "UniqueToken(\(hash))" }
}
