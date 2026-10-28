import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422840 (Sven, 2026-10-05): the main editor is a role, found from the Mac's defaults and changed on
/// the Default apps page.
@MainActor
@Suite("Editor role")
struct EditorRoleTests {
    @Test("Hyper+N opens the Editor role in My binds, where it opened VS Code by name")
    func myBindsKey() {
        var registry = ActionRegistry()
        AppsModule.register(into: &registry)
        #expect(registry.defaults["apps.editor"] == Key("n"))
    }

    @Test("The pick is kept as it changes and read back by a new choice; nil is automatic")
    func pickIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let choice = EditorChoice(defaults: defaults, installed: { _ in true }, handler: { _ in "com.microsoft.VSCode" })
        #expect(choice.pick == nil && choice.app == "com.microsoft.VSCode")
        choice.pick = "dev.zed.Zed"
        #expect(choice.app == "dev.zed.Zed")
        #expect(EditorChoice(defaults: defaults, installed: { _ in true }, handler: { _ in nil }).pick == "dev.zed.Zed")
        choice.pick = nil
        #expect(EditorChoice(defaults: defaults, installed: { _ in true }, handler: { _ in nil }).pick == nil)
    }

    @Test("The user's pick wins while it is installed; once it is gone the editor is found again")
    func pickWhileInstalled() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        var zed = true
        let choice = EditorChoice(defaults: defaults, installed: { $0 != "dev.zed.Zed" || zed }, handler: { _ in "com.apple.TextEdit" })
        choice.pick = "dev.zed.Zed"
        #expect(choice.app == "dev.zed.Zed")
        zed = false
        #expect(choice.app == "com.microsoft.VSCode")
    }
}
