import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The look's own parts beside its themes: Pilot's monospace face and its error kept apart from Setup's. Throwaway
/// defaults and a fake Ghostty: nothing of Sven's is read or written.
@MainActor
@Suite("Look")
struct LookTests {
    /// Records each Ghostty include Pilot would write; nothing reaches Ghostty.
    final class FakeGhostty: GhosttyWriting {
        var written: [GhosttyLook] = []
        var isApplied = true
        func apply(_ look: GhosttyLook) throws -> Bool { written.append(look); return true }
    }

    @Test("Pilot's monospace face is JetBrains Mono when installed, else the system's, at the size and weight asked for")
    func monoFont() {
        let look = Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: Self.defaults())
        let regular = look.monoFont(size: 12), medium = look.monoFont(size: 12, medium: true)
        let installed = NSFont(name: "JetBrainsMono-Regular", size: 12) != nil
        #expect(regular.familyName == (installed ? "JetBrains Mono" : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).familyName))
        #expect(regular.pointSize == 12 && medium.fontName != regular.fontName && look.monoFont(size: 12) === regular)
    }

    final class FailingSources: InputSourceSystem {
        var fails = true
        func all() -> [InputSource] {
            [InputSource(id: "british", name: "British", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: true),
             InputSource(id: "abc", name: "ABC", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: false)]
        }
        func select(_ id: String) throws { if fails { throw CocoaError(.featureUnsupported) } }
    }

    @Test("A keyboard layout failure is Setup's own: it never shows as the look's error")
    func layoutErrorApart() throws {
        let sources = FailingSources()
        let look = Look(themes: Self.themes, ghostty: FakeGhostty(), inputSources: sources, defaults: Self.defaults())
        look.followLayouts()
        look.pickLayout("abc")
        #expect(look.layoutError?.hasPrefix("keyboard layout not changed") == true)
        #expect(look.lastError == nil)
        sources.fails = false
        look.pickLayout("abc")
        #expect(look.layoutError == nil && look.lastError == nil)
    }

    @Test("A Window layout an older Pilot saved, retired with the panel (ui-redesign T2), is cleared at launch")
    func windowLayoutCleared() {
        let defaults = Self.defaults()
        defaults.set("tabs", forKey: "look.windowLayout")
        _ = Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults)
        #expect(defaults.object(forKey: "look.windowLayout") == nil)
    }

    static let themes = try! OmarchyThemes.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Packaging/themes.json")))

    /// Defaults of the test's own, so no test reads another's settings.
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }
}
