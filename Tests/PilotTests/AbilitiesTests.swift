import Foundation
@testable import PilotCore
import Testing
@testable import Pilot

/// Binds › Abilities (story 155): every action the app registers is listed once, with a line of its own saying what it
/// does, its key or none, and Try only where running it from the app window is safe.
@MainActor
@Suite("Abilities")
struct AbilitiesTests {
    /// The list as the page builds it, every optional ability added, over the registry's defaults (or `store`), never the
    /// binds file's keys.
    static func groups(_ engine: Engine, store: BindStore? = nil, search: String = "") -> [Abilities.Group] {
        Abilities.groups(actions: engine.allBindActions, store: store ?? BindStore(defaults: engine.registry.defaults), menu: AppsModule.menuID,
                         search: search)
    }

    @Test("Every registered action is listed exactly once, under its module, with its own line of what it does")
    func everyAction() {
        let engine = Engine()
        let groups = Self.groups(engine)
        let listed = groups.flatMap(\.abilities).compactMap(\.action)
        #expect(engine.registry.actions.count > 150)
        #expect(listed.count == Set(listed).count)
        #expect(Set(engine.registry.actions.keys).isSubset(of: listed))
        for action in engine.registry.sorted {
            #expect(Abilities.what(action.id, label: action.label) != "Runs \(action.label).", "\(action.id) has no line of its own")
            #expect(groups.first { $0.abilities.contains { $0.action == action.id } }?.module == action.module.rawValue)
        }
    }

    @Test("Every line and every Try refusal names an action that is registered, so none is left behind by a rename")
    func noStaleEntries() {
        let ids = Set(Engine().registry.actions.keys)
        #expect(Set(Abilities.lines.keys).subtracting(ids).isEmpty)
        #expect(Abilities.noTry.subtracting(ids).isEmpty)
    }

    @Test("What the menu answers when typed comes first, each with the menu's key, something to try and no Set key")
    func typedFirst() throws {
        let typed = try #require(Self.groups(Engine()).first)
        #expect(typed.module == nil && typed.title == "Type in the menu")
        #expect(typed.abilities.map(\.name).contains("File search") && typed.abilities.map(\.name).contains("Ask AI"))
        #expect(typed.abilities.allSatisfy { $0.key == "Hyper+Space" && $0.action == nil && $0.canTry && $0.typing != nil })
    }

    @Test("A key shows as bound now; an unbound action has none, so the row offers Set key")
    func keys() {
        let engine = Engine()
        var store = BindStore(defaults: engine.registry.defaults)
        try? store.set("system.nextWallpaper", to: nil)
        let all = Self.groups(engine, store: store).flatMap(\.abilities)
        #expect(all.first { $0.id == "apps.clipboard" }?.key == "Hyper+V")
        #expect(all.first { $0.id == "system.nextWallpaper" }?.key == nil)
    }

    @Test("Search matches a name, a line, a module or a key, and drops empty groups")
    func search() {
        let engine = Engine()
        func names(_ q: String) -> [String] { Self.groups(engine, search: q).flatMap(\.abilities).map(\.name) }
        #expect(names("wallpaper") == ["Next wallpaper", "Next wallpaper on every screen", "Previous wallpaper", "Previous wallpaper on every screen"])
        #expect(names("claude").contains("Ask AI") && names("claude").contains("Fix selected text"))
        #expect(names("Hyper+V").contains("Clipboard history"))
        #expect(names("feedback").contains("Report a bug"))
        #expect(Self.groups(engine, search: "zzqx").isEmpty)
    }

    @Test("Try is not offered for what would act on Pilot's own window, type into it, power off, cut the network or rewrite settings")
    func tryIsSafe() {
        for id in ["windows.close", "windows.snapLeft", "drive.quitApp", "drive.paste", "workspaces.move:1", "system.shutDown", "system.restart",
                   "system.logOut", "system.lock", "system.wifi", "system.clearAllNotifications", "engine.hyper", "look.ghosttyApply",
                   "scripts.run:x", "ext.y.z", "ai.fix", "apps.pastePlain"] {
            #expect(!Abilities.canTry(id), "\(id)")
        }
        for id in ["system.nextWallpaper", "apps.clipboard", "notes.toggle", "ai.ask", "workspaces.go:2", "captures.area", "extensions.catalogue",
                   "captures.pickColour", "media.playPause"] {
            #expect(Abilities.canTry(id), "\(id)")
        }
    }

    /// Sven 2026-10-10: a new Mac lists the generic abilities only; Bitwarden, lazygit and Ghostty's look wait under
    /// More abilities.
    static let appSpecific: Set<String> = [
        "apps.bitwardenFill", "apps.bitwardenForget", "apps.bitwardenLock", "apps.bitwardenGenerator", "apps.bitwardenSearch",
        "apps.generatePassword", "apps.lazygit", "look.ghosttyApply", "look.ghosttyRemove",
    ]

    @Test("Abilities ship minimal: an app-specific one is listed only once added with its app here, or while it holds a key")
    func shipMinimal() {
        let engine = Engine()
        #expect(Set(Abilities.optional.keys) == Self.appSpecific)
        #expect(Self.appSpecific.isSubset(of: Set(engine.registry.actions.keys)), "every optional id is a registered action")
        let all = { (_: CatalogueEntry.Check) in true }, none = { (_: CatalogueEntry.Check) in false }
        // A new Mac: nothing added, no key; every generic ability stays.
        let fresh = engine.registry.sorted.map(\.id).filter { Abilities.isListed($0, bound: false, added: [], has: all) }
        #expect(Set(engine.registry.actions.keys).subtracting(fresh) == Self.appSpecific)
        for id in ["apps.browser", "apps.terminal", "apps.files", "apps.calendar", "apps.mail", "apps.clipboard", "apps.emoji", "ai.ask", "ai.fix",
                   "windows.close", "workspaces.next", "captures.area"] {
            #expect(fresh.contains(id), "\(id) ships")
        }
        // Added, but its app is gone: hidden; a key keeps it listed whatever is installed.
        #expect(Abilities.isListed("apps.bitwardenLock", bound: false, added: ["apps.bitwardenLock"], has: all))
        #expect(!Abilities.isListed("apps.bitwardenLock", bound: false, added: ["apps.bitwardenLock"], has: none))
        #expect(Abilities.isListed("apps.lazygit", bound: true, added: [], has: none))
        // More abilities offers the unlisted ones whose app is here, searchable, none to try before it is added.
        let listed = { (id: String) in id == "apps.lazygit" }
        let more = Abilities.addable(actions: engine.allBindActions, listed: listed, has: { $0 != .bundle(Bitwarden.bundle) })
        #expect(Set(more.map(\.id)) == Self.appSpecific.subtracting(["apps.lazygit"]).filter { Abilities.optional[$0] != .bundle(Bitwarden.bundle) })
        #expect(more.allSatisfy { !$0.canTry && $0.action != nil })
        #expect(Abilities.addable(actions: engine.allBindActions, listed: { _ in false }, has: all, search: "lazygit").map(\.id) == ["apps.lazygit"])
    }

    @Test("Once, a Mac that ran Pilot before keeps every optional ability; a new Mac starts with none added; Remove and Add stick")
    func seed() throws {
        func store() throws -> UserDefaults { try #require(UserDefaults(suiteName: NSTemporaryDirectory() + "abilities.\(UUID().uuidString)")) }
        let old = try store()
        let existing = AbilitySettings(defaults: old)
        existing.seed(existingUser: true)
        #expect(existing.added == Self.appSpecific)
        existing.remove("look.ghosttyApply")
        existing.seed(existingUser: true)
        #expect(!existing.added.contains("look.ghosttyApply"), "seeded once only")
        #expect(AbilitySettings(defaults: old).added == Self.appSpecific.subtracting(["look.ghosttyApply"]))
        let fresh = AbilitySettings(defaults: try store())
        fresh.seed(existingUser: false)
        #expect(fresh.added.isEmpty)
        fresh.add("apps.lazygit")
        #expect(fresh.added == ["apps.lazygit"])
    }

    @Test("Menu has the Abilities tab (C3; Binds' until then), which its old link, its own and the window's search reach")
    func place() {
        #expect(AppPage.menu.tabs.map(\.title).prefix(2) == ["Your menu", "Abilities"] && AppPage.binds.tabs.map(\.title) == ["Keyboard", "Overlay", "Mouse", "Swap keys", "Export and import"])
        #expect(AppPlace.linked(URL(string: "pilot://open?page=binds&tab=abilities")!) == AppPlace(.menu, .abilities))
        #expect(AppPlace.linked(URL(string: "pilot://open?page=menu&tab=abilities")!) == AppPlace(.menu, .abilities))
        #expect(AppPlace.search("what can pilot do").first == AppPlace(.abilities))
        // Menu takes the frame's bar in both new styles; Binds keeps its own.
        #expect(!InstrumentFrame.pageOwnsBar(.menu) && InstrumentFrame.pageOwnsBar(.binds))
        #expect(!ToyLayout.ownsTitleRow(.menu))
    }
}
