import Foundation
import Observation
import PilotCore

/// Launcher › Abilities, under Generate a password (story 160; on Defaults until C3, Menu › Passwords until the page map): how long a password Generate a password makes, whether it has
/// symbols, and how long it stays copied before the pasteboard is cleared (20, with symbols, 90 s before).
@Observable @MainActor
final class PasswordSettings {
    static let shared = PasswordSettings()

    static let lengths = 12...64
    /// Seconds a copied password stays.
    static let clearChoices = [30, 60, 90, 120, 300]

    var length: Int { didSet { defaults.set(length, forKey: Self.lengthKey) } }
    var symbols: Bool { didSet { defaults.set(symbols, forKey: Self.symbolsKey) } }
    var clearAfter: Int { didSet { defaults.set(clearAfter, forKey: Self.clearKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    private static let lengthKey = "passwords.length", symbolsKey = "passwords.symbols", clearKey = "passwords.clearAfter"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        let length = defaults.integer(forKey: Self.lengthKey)
        self.length = Self.lengths.contains(length) ? length : 20
        symbols = defaults.object(forKey: Self.symbolsKey) as? Bool ?? true
        let clear = defaults.integer(forKey: Self.clearKey)
        clearAfter = Self.clearChoices.contains(clear) ? clear : 90
    }

    /// What bw generate is asked for.
    var arguments: [String] { Bitwarden.generateArguments(length: length, symbols: symbols) }
}
