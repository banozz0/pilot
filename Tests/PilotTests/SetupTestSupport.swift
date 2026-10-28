import Foundation

/// A defaults store of its own per test, holding whether a Setup section's Show press was remembered, so no test reads
/// or writes Pilot's real defaults.
func setupDefaults(_ key: String, shown: Bool) -> UserDefaults {
    let d = UserDefaults(suiteName: testSuite())!
    d.set(shown, forKey: key)
    return d
}
