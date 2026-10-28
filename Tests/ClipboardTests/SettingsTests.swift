import Foundation
import Testing
@testable import Clipboard

/// Settings › Clipboard (story 89, wireframe mSEMT3YCZpU section 10): what each row stores, and the defaults
/// carried over from ClipBook Rust before it is switched off.
@Suite("Clipboard settings")
struct SettingsTests {
    let suite = testSuite()

    @Test("A fresh Mac gets ClipBook Rust's settings: no age limit, images kept, Return pastes, Bitwarden never recorded")
    func clipBookDefaults() throws {
        let settings = ClipboardSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(settings == .default)
        #expect(settings.keepCount == 500)
        #expect(settings.keepDays == nil)
        #expect(settings.saveImages)
        #expect(settings.returnAction == .paste)
        #expect(settings.ignoredApps == ["com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"])
    }

    @Test("Every row survives a relaunch")
    func survivesRelaunch() throws {
        let changed = ClipboardSettings(keepCount: 3, keepDays: 1, saveImages: false,
                                        ignoredApps: ["com.apple.TextEdit"], returnAction: .copy)
        changed.save(to: try #require(UserDefaults(suiteName: suite)))
        // A second instance on the same suite reads what a relaunched Pilot reads.
        let relaunched = try #require(UserDefaults(suiteName: suite))
        #expect(ClipboardSettings(defaults: relaunched) == changed)
        var forever = ClipboardSettings.default
        forever.ignoredApps = []
        forever.save(to: relaunched)
        #expect(ClipboardSettings(defaults: relaunched) == forever, "forever and an empty list are stored, not mistaken for unset")
    }

    @Test("The capture follows the settings: the never-record list and Save images")
    func captureFollowsSettings() {
        let capture = ClipboardSettings(keepCount: 500, keepDays: nil, saveImages: false,
                                        ignoredApps: ["com.apple.TextEdit"], returnAction: .paste).capture
        #expect(capture.ignoredApps == ["com.apple.TextEdit"])
        #expect(!capture.saveImages)
    }
}
