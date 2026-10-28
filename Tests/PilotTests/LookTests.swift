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

    @Test("A Window layout saved as the hub, taken out on 2026-10-11, loads as the rail; Toolbar tabs stays")
    func hubLoadsAsRail() {
        let defaults = Self.defaults()
        defaults.set("hub", forKey: "look.windowLayout")
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).windowShape == .rail)
        defaults.set("tabs", forKey: "look.windowLayout")
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).windowShape == .tabs)
    }

    @Test("The Hyper+Space menu is Line by default and for an unknown saved value (Q165); the Rail is kept and saved")
    func menuLayout() {
        let defaults = Self.defaults()
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).menuLayout == .line)
        defaults.set("instrument", forKey: "look.menuLayout")
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).menuLayout == .line)
        Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).menuLayout = .rail
        #expect(defaults.string(forKey: "look.menuLayout") == "rail")
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).menuLayout == .rail)
    }

    @Test("A Classic saved before Line existed moves to Line once (Q165); Classic picked after that stays")
    func menuLayoutMovesToLineOnce() {
        let defaults = Self.defaults()
        defaults.set("classic", forKey: "look.menuLayout")
        let look = Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults)
        #expect(look.menuLayout == .line && defaults.string(forKey: "look.menuLayout") == "line")
        look.menuLayout = .classic
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: defaults).menuLayout == .classic)
        // A Rail saved before is kept.
        let rail = Self.defaults()
        rail.set("rail", forKey: "look.menuLayout")
        #expect(Look(themes: Self.themes, ghostty: FakeGhostty(), defaults: rail).menuLayout == .rail)
    }

    static let themes = try! OmarchyThemes.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Packaging/themes.json")))

    /// Defaults of the test's own, so no test reads another's settings.
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }
}
