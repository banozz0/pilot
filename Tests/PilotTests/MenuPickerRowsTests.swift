import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// A Picker in a Menu under the app window's switch style (Sven 2026-10-10, build 8: Workspaces › Tiling's Monitor pick
/// and Binds' preset pick were greyed out and could not be changed). Each control's menu is opened by a click in a window
/// never shown, caught before AppKit shows it, and every row must be enabled and pick its value.
@MainActor
@Suite(.serialized)
struct MenuPickerRowsTests {
    /// Every row of `menu` is enabled, and they are `titles`.
    func expectEnabled(_ menu: NSMenu, _ titles: [String]) {
        let rows = OpenedMenu.rows(menu)
        #expect(rows.map(\.title) == titles)
        #expect(rows.allSatisfy { $0.isEnabled }, "greyed: \(rows.filter { !$0.isEnabled }.map(\.title))")
    }

    @Test("Tiling's Monitor pick under the window's styles: Any, Main and each display are enabled, and Main picks .main")
    func monitorPick() throws {
        let displays = [ConnectedDisplay(name: "CU34G4Z", id: "A"), ConnectedDisplay(name: "LG ULTRAFINE", id: "B")]
        let pick = WorkspaceMonitors.choices(pinned: displays[1].pin, displays: displays)
        var picked: [MonitorPin?] = []
        let menu = try #require(try OpenedMenu.of(width: 220) {
            DropdownField(label: "Workspace 1's monitor", options: pick.choices, picked: pick.picked) { picked.append($0) }.frame(width: 220)
        })
        expectEnabled(menu, ["Any", "Main", "CU34G4Z", "LG ULTRAFINE"])
        try OpenedMenu.choose("Main", in: menu)
        #expect(picked == [.main])
    }

    @Test("Binds' preset pick under the window's styles: Pilot default and My binds are enabled, and My binds is picked")
    func presetPick() throws {
        let store = BindStore(presets: [.pilot: [:], .myBinds: [:]])
        var picked: [BindStore.Preset] = []
        let menu = try #require(try OpenedMenu.of(width: 200) {
            Menu {
                PresetPicker(presets: store.presets, active: store.preset) { picked.append($0) }
                Button("Show as list") {}
            } label: { Text("Preset · \(store.preset.title)").frame(width: 200, height: 32) }
            .menuStyle(.button).buttonStyle(InstrumentButtonStyle()).menuIndicator(.hidden).fixedSize()
        })
        expectEnabled(menu, ["Preset", "Pilot default", "My binds", "Show as list"])
        try OpenedMenu.choose("My binds", in: menu)
        #expect(picked == [.myBinds])
    }

    @Test("Defaults' app pick under the window's styles: each app is enabled")
    func appPick() throws {
        var pick = "com.apple.TextEdit"
        let menu = try #require(try OpenedMenu.of(width: 220) {
            AppPickerField(bundle: pick, name: "TextEdit", label: "Editor") {
                Picker("Editor", selection: Binding(get: { pick }, set: { pick = $0 })) {
                    Text("TextEdit").tag("com.apple.TextEdit")
                    Text("Xcode").tag("com.apple.dt.Xcode")
                }
                .pickerStyle(.inline)
            }
            .frame(width: 220)
        })
        expectEnabled(menu, ["TextEdit", "Xcode"])
    }

    /// The AI chat's settings on a scratch suite, codex having listed `codex` (as its catalog Refresh keeps them).
    func aiSettings(provider: AIProvider, codex: [String] = []) throws -> AISettings {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        defaults.set(provider.rawValue, forKey: "ai.provider")
        defaults.set(codex, forKey: AISettings.listKey(.codex))
        let settings = AISettings(defaults: defaults, keys: AISettingsTests.FakeKeys(), http: AISettingsTests.NoNetwork())
        settings.findCLI = { nil }
        settings.findPlan = { _ in nil }
        return settings
    }

    @Test("The AI chat's Codex model and effort pick (Sven on build 42): every row is enabled, and a pick sets the route")
    func codexRoutePick() throws {
        let ai = try aiSettings(provider: .codex, codex: ["gpt-6-sol", "gpt-6-luna"])
        ai.setModel("gpt-6-luna", for: .codex)
        ai.setEffort(.medium, for: .codex)
        let menu = try #require(try OpenedMenu.of(width: 260) { AIRouteMenu(settings: ai, provider: .codex).frame(width: 260, height: 32) })
        expectEnabled(menu, ["Codex's default", "gpt-6-sol", "gpt-6-luna", "Low", "Medium", "High"])
        try OpenedMenu.choose("gpt-6-sol", in: menu)
        try OpenedMenu.choose("High", in: menu)
        #expect(ai.model(for: .codex)?.id == "gpt-6-sol" && ai.effort(for: .codex) == .high)
        #expect(ai.routeName == "Codex · gpt-6-sol")
        try OpenedMenu.choose("Codex's default", in: menu)
        #expect(ai.model(for: .codex)?.id == nil && ai.routeName == "Codex")
    }

    @Test("The AI chat's Claude Code model and effort pick: every row is enabled, and a pick sets the route")
    func claudeRoutePick() throws {
        let ai = try aiSettings(provider: .claudeCode)
        let menu = try #require(try OpenedMenu.of(width: 260) { AIRouteMenu(settings: ai, provider: .claudeCode).frame(width: 260, height: 32) })
        expectEnabled(menu, ["Claude Code's default", "Haiku", "Sonnet", "Opus", "Low", "Medium", "High"])
        try OpenedMenu.choose("Opus", in: menu)
        try OpenedMenu.choose("Medium", in: menu)
        #expect(ai.model(for: .claudeCode)?.id == "opus" && ai.effort(for: .claudeCode) == .medium)
        #expect(ai.routeName == "Claude Code · Opus")
    }
}

/// A SwiftUI Menu's NSMenu, as a click opens it: the view under the window's styles, `width` by 32 in a borderless window
/// no one sees, clicked at its centre, AppKit's pop-up swapped for a catch while it runs so nothing reaches the screen.
@MainActor
enum OpenedMenu {
    private static var caught: NSMenu?
    private static let popUp = NSSelectorFromString("_popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:")

    static func of(width: CGFloat, @ViewBuilder _ view: () -> some View) throws -> NSMenu? {
        let size = CGSize(width: width, height: 32)
        testApp()
        let method = try #require(class_getInstanceMethod(NSMenu.self, popUp), "AppKit no longer pops a Menu this way")
        let catchIt: @convention(block) (NSMenu) -> Bool = { menu in MainActor.assumeIsolated { caught = menu }; return false }
        let original = method_setImplementation(method, imp_implementationWithBlock(catchIt))
        defer { method_setImplementation(method, original); caught = nil }
        let host = NSHostingView(rootView: view().pilotWindowStyles())
        host.frame.size = size
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        // A click reaches only a window ordered in: this one is see-through and far off every screen.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        PanelTestSupport.pump(0.4)
        PanelTestSupport.click(window, at: CGPoint(x: size.width / 2, y: size.height / 2))
        return caught
    }

    /// Every titled row but a section's header, a submenu's after its own, validated as AppKit does before showing.
    static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.update()
        return menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader && !$0.title.isEmpty }.flatMap { [$0] + ($0.submenu.map(rows) ?? []) }
    }

    /// Picks the row titled `title`, as a click on it would.
    static func choose(_ title: String, in menu: NSMenu) throws {
        if let i = menu.items.firstIndex(where: { $0.title == title && $0.submenu == nil }) { return menu.performActionForItem(at: i) }
        let sub = try #require(menu.items.compactMap(\.submenu).first { $0.items.contains { $0.title == title } }, "no row \(title)")
        try choose(title, in: sub)
    }
}
