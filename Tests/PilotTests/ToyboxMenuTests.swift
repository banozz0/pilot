#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Toybox's menu (card agent-bo-95423182, mockup B's launcher): a bind and a foot's key spelled as key caps, and the menu
/// hosted under Toybox drawing its own pixels, dark apart from light, and apart from Instrument's.
extension SharedLook {
@MainActor
@Suite("Toybox menu")
struct ToyboxMenuTests {
    @Test("A bind's label is Hyper's cap, then one cap per key; a foot's key one cap per symbol, a word whole")
    func caps() {
        #expect(ToyCaps.bind("Hyper+Return") == ToyCaps.Bind(hyper: true, keys: ["Return"]))
        #expect(ToyCaps.bind("Hyper+Shift+T") == ToyCaps.Bind(hyper: true, keys: ["Shift", "T"]))
        #expect(ToyCaps.bind("Left Alt+H") == ToyCaps.Bind(hyper: false, keys: ["Left Alt", "H"]))
        #expect(ToyCaps.bind("Hyper") == ToyCaps.Bind(hyper: true, keys: []))
        #expect(ToyCaps.hint("↑↓") == ["↑", "↓"])
        #expect(ToyCaps.hint("← →") == ["←", "→"])
        #expect(ToyCaps.hint("⌘K") == ["⌘", "K"])
        #expect(ToyCaps.hint("⌘↵") == ["⌘", "↵"])
        #expect(ToyCaps.hint("Esc") == ["Esc"])
        #expect(ToyCaps.hint("Tab") == ["Tab"])
        #expect(ToyCaps.hint("↵") == ["↵"])
    }

    @Test("Toybox keeps its own menu and draws an answer's card in it: the first answer row, the Ask row a row under it (T13)")
    func answerCards() throws {
        let built = try RailMenuRenders.built()
        for query in ["22 km to mi", "#2bc4f0"] {
            let model = MenuModel(nav: ToyboxMenuRenders.answer(query, built))
            #expect(model.layout == .classic && model.railBand == .none, "\(query): Toybox draws no rail")
            let rows = model.nav.rows
            try #require(rows.count >= 2, "\(query): \(rows.map(\.title))")
            #expect(model.answerCard(rows[0], at: 0) != nil && model.answerCard(rows[1], at: 1) == nil, "\(query)")
            #expect(rows[1].title == "Ask AI" && model.nav.selected?.id == rows[0].id, "\(query)")
        }
    }

    /// The menu at a root search over sample rows, as PanelRenders seeds it.
    static func searching() -> MenuNavigator {
        var nav = MenuNavigator(entries: [
            MenuEntry(title: "Ghostty", target: .app("com.mitchellh.ghostty"), home: .apps, detail: "Hyper+Return", detailIsKey: true, running: true),
            MenuEntry(title: "Open terminal", target: .action("apps.terminal"), home: .keybindings, detail: "Hyper+Return", detailIsKey: true),
            MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps),
        ])
        nav.query = "te"
        nav.provide(.window, [MenuEntry(title: "Notes — TextEdit", target: .window(4), detail: "workspace 3")])
        return nav
    }

    @Test("Hosted under Toybox the menu draws other pixels than Instrument, and follows the theme: Toybox Night others than Toybox")
    func drawn() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        func pixels(_ style: PilotStyle, theme: String) throws -> Data {
            look.style = style
            look.themeID = theme
            var data = Data()
            let view = MenuView(model: MenuModel(nav: Self.searching())).styled(.menu, look: look)
            try LookPageTests().hosted(view.pilotTheme(look: look)) { host in
                PanelTestSupport.pump(0.05)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(host))
                data = Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
            }
            return data
        }
        let instrument = try pixels(.instrument, theme: "toybox-night"), dark = try pixels(.toybox, theme: "toybox-night"), light = try pixels(.toybox, theme: "toybox")
        #expect(dark != instrument, "Toybox drew Instrument's menu")
        #expect(dark != light, "Toybox did not follow the theme from Toybox Night to Toybox")
    }
}
}
#endif
