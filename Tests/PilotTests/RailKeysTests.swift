#if DEBUG
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The Rail's root walks with the arrows from Go to's branches up into the kinds and back (Sven's bug on build 45, Q119:
/// only Go to was reachable).
extension SharedLook {
@MainActor
@Suite("Rail keys")
struct RailKeysTests {
    private func root() throws -> MenuModel {
        let model = MenuModel(nav: MenuNavigator(entries: try RailMenuRenders.built()))
        model.layout = .rail
        return model
    }

    @Test("↑ on the first branch climbs Packages to All; ↓ comes back down to the branches")
    func walksTheWholeRail() throws {
        let model = try root()
        #expect(model.railBand == .root && model.nav.selection == 0 && model.railCursor == nil)
        let kinds = MenuEntry.Kind.tabOrder
        #expect(model.railKey(.up))
        #expect(model.railCursor == kinds.count - 1, "Packages, the last kind, sits over Go to")
        for _ in 0..<kinds.count { _ = model.railKey(.up) }
        #expect(model.railCursor == 0, "All, the top, holds")
        for _ in 1..<kinds.count { #expect(model.railKey(.down)) }
        #expect(model.railCursor == kinds.count - 1)
        #expect(model.railKey(.down))
        #expect(model.railCursor == nil && model.nav.selection == 0, "back on the first branch")
        #expect(!model.railKey(.down), "the branches' arrows stay the navigator's")
        _ = model.nav.handle(.down)
        #expect(!model.railKey(.up), "↑ from a lower branch moves among the branches")
    }

    @Test("Return or → on a kind shows it, as a click on it does; Tab and Escape go back to the navigator")
    func picksAKind() throws {
        let model = try root()
        _ = model.railKey(.up)
        _ = model.railKey(.up)
        #expect(model.railCursor == MenuEntry.Kind.tabOrder.firstIndex(of: .action))
        #expect(model.railKey(.return))
        #expect(model.nav.only == .action && model.railCursor == nil)
        let other = try root()
        _ = other.railKey(.up)
        #expect(other.railKey(.right) && other.nav.only == .package)
        let all = try root()
        for _ in MenuEntry.Kind.tabOrder { _ = all.railKey(.up) }
        #expect(all.railKey(.return) && all.railCursor == 0 && all.nav.only == nil, "Return on All keeps the cursor there")
        let tab = try root()
        _ = tab.railKey(.up)
        #expect(!tab.railKey(.tab) && tab.railCursor == nil)
        #expect(tab.railKey(.commandK) == false, "with nothing on a kind, Cmd+K is the row's")
    }

    @Test("Away from the Rail's root the rail takes no key")
    func onlyAtTheRoot() throws {
        let classic = try root()
        classic.layout = .classic
        #expect(!classic.railKey(.up) && classic.railCursor == nil)
        let typed = try root()
        typed.nav.query = "ghost"
        #expect(!typed.railKey(.up))
        let branch = MenuModel(nav: MenuNavigator(entries: try RailMenuRenders.built(), branch: .trigger))
        branch.layout = .rail
        #expect(!branch.railKey(.up))
    }
}
}
#endif
