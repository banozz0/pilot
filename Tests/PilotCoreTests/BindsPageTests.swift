import Foundation
import Testing
@testable import PilotCore

/// The Binds screen's content (story 28, wireframe mSEMT3YCZpU sections 2 and 3): one tab per sublayer, every action
/// listed, and the clash the editor shows before anything is saved.
@Suite("Binds page")
struct BindsPageTests {
    static let actions: [BindsPage.ActionInfo] = [
        .init(id: "windows.close", label: "Close window", module: "windows"),
        .init(id: "windows.toggleFloat", label: "Float or tile window", module: "windows"),
        .init(id: "windows.toggleFloatWorkspace", label: "Float or tile workspace", module: "windows"),
        .init(id: "windows.minimise", label: "Minimise", module: "windows"),
        .init(id: "apps.terminal", label: "Terminal", module: "apps"),
    ]
    static let defaults: [String: Key] = [
        "windows.close": Key("w"), "windows.toggleFloat": Key("t", .shift),
        "windows.toggleFloatWorkspace": Key("t", .ctrl), "apps.terminal": Key("return"),
    ]

    @Test("Each tab lists the actions bound on its sublayer; the last lists the actions with no key")
    func tabs() {
        let store = BindStore(defaults: Self.defaults)
        func ids(_ tab: BindsPage.Tab) -> [String] { BindsPage.rows(store: store, actions: Self.actions, tab: tab).map(\.id) }
        #expect(ids(.layer(.hyper)) == ["apps.terminal", "windows.close"])
        #expect(ids(.layer(.shift)) == ["windows.toggleFloat"])
        #expect(ids(.layer(.ctrl)) == ["windows.toggleFloatWorkspace"])
        #expect(ids(.layer(.alt)) == [])
        #expect(ids(.unbound) == ["windows.minimise"])
        #expect(BindsPage.Tab.sections.map(\.title)
                == ["Hyper", "Hyper+Shift", "Hyper+Ctrl", "Hyper+Alt", "Hyper+Shift+Ctrl", "Other Hyper keys", "Plain combos", "Not bound"])
        #expect(BindsPage.Tab.sections.map(\.shortTitle)
                == ["Hyper", "+Shift", "+Ctrl", "+Alt", "+Shift+Ctrl", "Other Hyper keys", "Plain combos", "Not bound"])
    }

    @Test("A row shows the key without its layer, the action, its module and whether the user set it")
    func row() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.minimise", to: Key("m", [.shift, .ctrl]))
        let row = try #require(BindsPage.rows(store: store, actions: Self.actions, tab: .layer(.shiftCtrl)).first)
        #expect(row == .init(id: "windows.minimise", key: "M", label: "Minimise", module: "windows", custom: true))
    }

    @Test("Search matches the action, the module or the key across every layer, and a whole trigger finds its bind")
    func search() {
        let store = BindStore(defaults: Self.defaults)
        func ids(_ search: String) -> [String] { BindsPage.sections(store: store, actions: Self.actions, search: search).flatMap(\.rows).map(\.id) }
        #expect(ids("float") == ["windows.toggleFloat", "windows.toggleFloatWorkspace"])
        #expect(ids("hyper+ctrl+t") == ["windows.toggleFloatWorkspace"])
        #expect(ids("apps") == ["apps.terminal"])
    }

    @Test("The clash names the key, the action holding it, and what Replace does; none on a free key or the action's own")
    func clash() {
        let store = BindStore(defaults: Self.defaults)
        #expect(BindsPage.clash(store: store, actions: Self.actions, key: Key("t", .shift), for: "windows.minimise")
                == "Hyper+Shift+T already runs Float or tile window. Replace leaves Float or tile window with no key.")
        #expect(BindsPage.clash(store: store, actions: Self.actions, key: Key("x", .shift), for: "windows.minimise") == nil)
        #expect(BindsPage.clash(store: store, actions: Self.actions, key: Key("t", .shift), for: "windows.toggleFloat") == nil)
    }

    @Test("Reset's refusal names the key and the action holding it")
    func refusal() {
        #expect(BindsPage.refusal(.triggerTaken(Key("t", .shift), by: "windows.toggleFloat"), actions: Self.actions)
                == "Hyper+Shift+T is taken by Float or tile window; give that a new key first.")
        #expect(BindsPage.Sublayer(modifiers: [.shift, .ctrl]) == .shiftCtrl)
        #expect(BindsPage.Sublayer(modifiers: .cmd) == nil)
    }

    @Test("Replace takes the key: the old holder is left with no key, and both are the user's own binds")
    func replace() throws {
        var store = BindStore(defaults: Self.defaults)
        #expect(store.replace("windows.minimise", with: Key("t", .shift)) == "windows.toggleFloat")
        #expect(store.action(for: Key("t", .shift)) == "windows.minimise")
        #expect(store.trigger(for: "windows.toggleFloat") == nil)
        #expect(store.isCustom("windows.toggleFloat"))
        let back = try BindStore(json: store.json(), defaults: Self.defaults)
        #expect(back == store)
    }

    @Test("An app bind that loses its key to Replace stays listed under Not bound, so it can be bound again")
    func pickedActionLosesKey() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("apps.open:com.apple.Notes", to: Key("n", .shift))
        store.replace("windows.minimise", with: Key("n", .shift))
        let notes = BindsPage.ActionInfo(id: "apps.open:com.apple.Notes", label: "Notes", module: "apps")
        let actions = BindsPage.actions(registered: Self.actions, store: store) { $0 == notes.id ? notes : nil }
        #expect(BindsPage.rows(store: store, actions: actions, tab: .unbound).map(\.id) == ["apps.open:com.apple.Notes"])
    }

    @Test("Editing a bind's action: its own key is no clash, a third action's still is, and Replace leaves that one with no key")
    func clashWhileMoving() {
        var store = BindStore(defaults: Self.defaults)
        let textEdit = "apps.open:com.apple.TextEdit"
        #expect(BindsPage.clash(store: store, actions: Self.actions, key: Key("w"), for: textEdit, from: "windows.close") == nil)
        #expect(BindsPage.clash(store: store, actions: Self.actions, key: Key("return"), for: textEdit, from: "windows.close")
                == "Hyper+Return already runs Terminal. Replace leaves Terminal with no key.")
        #expect(store.replace(textEdit, with: Key("return"), from: "windows.close") == "apps.terminal")
        #expect(store.action(for: Key("return")) == textEdit)
        #expect(store.trigger(for: "windows.close") == nil)
        #expect(store.trigger(for: "apps.terminal") == nil)
    }

    @Test("Binding an action that holds a key names the key that goes free, and the log line says it moved off it")
    func moving() throws {
        let ghostty = "apps.open:com.mitchellh.ghostty"
        var store = BindStore(defaults: [ghostty: Key("return")])
        #expect(BindsPage.moving(store: store, action: ghostty, to: Key("t")) == Key("return"))
        #expect(BindsPage.moving(store: store, action: ghostty, to: Key("return")) == nil)
        #expect(BindsPage.moving(store: store, action: "windows.minimise", to: Key("t")) == nil)
        try store.set(ghostty, to: Key("t"))
        #expect(store.trigger(for: ghostty) == Key("t"))
        #expect(store.action(for: Key("return")) == nil)
        #expect(BindsPage.bindLog(ghostty, on: Key("t"), freed: Key("return"))
                == "apps.open:com.mitchellh.ghostty on Hyper+T, moved off Hyper+Return")
        #expect(BindsPage.bindLog("windows.minimise", on: Key("return"), left: ghostty, from: "windows.close")
                == "windows.minimise on Hyper+Return, apps.open:com.mitchellh.ghostty left with no key, moved from windows.close")
        #expect(BindsPage.bindLog("web.open:pilot://x?token=abc", on: nil) == "web.open:pilot://x?token=<redacted> on no key")
    }

    /// The Binds page as one list (card agent-bo-95422785): a section per layer, so nothing hides behind a tab.
    static let sectioned: [BindsPage.ActionInfo] = actions + [
        .init(id: "apps.whatsapp", label: "WhatsApp", module: "apps"),
        .init(id: "apps.clipboard", label: "Clipboard history", module: "apps"),
    ]
    static func sectionedStore() throws -> BindStore {
        var store = BindStore(defaults: defaults)
        try store.set("apps.whatsapp", to: Key("g", [.shift, .alt]))
        try store.set("apps.clipboard", to: Key("v", .leftAlt, hyper: false))
        return store
    }

    @Test("Every action sits in exactly one section, Hyper+Shift+Alt included, and the layer sections show the key alone")
    func sections() throws {
        let store = try Self.sectionedStore()
        let sections = BindsPage.sections(store: store, actions: Self.sectioned)
        #expect(sections.map(\.tab) == [.layer(.hyper), .layer(.shift), .layer(.ctrl), .otherHyper, .plain, .unbound])
        #expect(sections.flatMap(\.rows).map(\.id).sorted() == Self.sectioned.map(\.id).sorted())
        #expect(sections.first?.rows.map(\.key) == ["Return", "W"])
        #expect(sections.first { $0.tab == .otherHyper }?.rows.map(\.key) == ["Hyper+Shift+Alt+G"])
        #expect(sections.first { $0.tab == .plain }?.rows.map(\.key) == ["Left Alt+V"])
        #expect(BindsPage.Tab.otherHyper.title == "Other Hyper keys")
    }

    @Test("The Plain combos section shows even when empty, so the page can say what one is; other empty layers do not")
    func emptySections() {
        let sections = BindsPage.sections(store: BindStore(defaults: Self.defaults), actions: Self.actions)
        #expect(sections.map(\.tab) == [.layer(.hyper), .layer(.shift), .layer(.ctrl), .plain, .unbound])
        #expect(sections.first { $0.tab == .plain }?.rows == [])
    }

    @Test("A layer filter leaves that one section; a search keeps each hit in its own layer's section")
    func filterAndSearch() throws {
        let store = try Self.sectionedStore()
        #expect(BindsPage.sections(store: store, actions: Self.sectioned, only: .layer(.shift)).map(\.tab) == [.layer(.shift)])
        let hits = BindsPage.sections(store: store, actions: Self.sectioned, search: "float")
        #expect(hits.map(\.tab) == [.layer(.shift), .layer(.ctrl)])
        #expect(hits.flatMap(\.rows).map(\.key) == ["T", "T"])
        #expect(BindsPage.sections(store: store, actions: Self.sectioned, search: "hyper+ctrl+t").flatMap(\.rows).map(\.id)
                == ["windows.toggleFloatWorkspace"])
        // A search ignores the filter, as the tabs did: a hit is never hidden by the layer picked.
        #expect(BindsPage.sections(store: store, actions: Self.sectioned, only: .layer(.hyper), search: "clipboard").map(\.tab) == [.plain])
        #expect(BindsPage.sections(store: store, actions: Self.sectioned, search: "zzz").isEmpty)
    }

    @Test("Plain combos explain themselves with two examples, spelled as the page spells keys; no other section needs to")
    func plainComboExplained() throws {
        let line = try #require(BindsPage.Tab.plain.explanation)
        #expect(line.contains("without Hyper"))
        #expect(line.contains("Left Alt+H") && line.contains("Ctrl+Cmd+X"))
        #expect(line.contains(Key("x", [.cmd, .ctrl], hyper: false).label))
        #expect(BindsPage.Tab.sections.filter { $0.explanation != nil } == [.plain])
    }
}
