// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/util/StringEx.swift
import Foundation

public typealias ResOrStr<T> = Result<T, String>
extension String: @retroactive LocalizedError { // Make it possible to use String in Result. todo migrate to self written Result monad
    public var errorDescription: String? { self }
}

// Make it possible to use [String] in Result. todo migrate to self written Result monad
extension Array: @retroactive Error where Element: Error {}
extension Array: @retroactive LocalizedError where Element: LocalizedError {}

extension String {
    public func prefixLines(with: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).map { with + $0 }.joined(separator: "\n")
    }

    public var singleQuoted: String { "'" + self + "'" }
}
