#if DEBUG
import AppKit
import Clipboard
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Toybox's window frame and Home (card agent-bo-95423182, mockup B home-*.png, binds-dark.png for the rail): when the
/// sidebar folds into the rail, which pages draw their own title row, how Home lays out by width, which workspaces it
/// shows and how their windows stack, and the words it builds; then that both surfaces hosted under Toybox draw
/// otherwise than Instrument, and Toybox dark otherwise than light.
extension SharedLook {
@MainActor
@Suite("Toybox frame and Home")
struct ToyHomeTests {
    @Test("Direction 1: an area of one page (Home, Keys) has no list at any width, and a window under 900 pt folds it; an unmeasured one never")
    func rail() {
        func folds(_ page: AppPage, _ width: CGFloat) -> Bool { !RailLayout.showsList(page, width: width, searching: false) }
        #expect(folds(.binds, 1440) && folds(.binds, 1600))
        #expect(folds(.home, 1440))
        #expect(!folds(.look, 1000))
        #expect(folds(.look, 899))
        #expect(folds(.binds, 760))
        #expect(!folds(.menuBar, 0))
    }

    @Test("Home and Binds draw their own title rows; every other page gets the frame's header")
    func titleRow() {
        #expect(ToyLayout.ownsTitleRow(.home) && ToyLayout.ownsTitleRow(.binds))
        #expect(!ToyLayout.ownsTitleRow(.workspaces))
    }

    @Test("Workspaces shows the first four, the focused one always among them")
    func shown() {
        let cells = (1...7).map { OccupiedWorkspace(name: String($0), apps: []) }
        #expect(ToyHome.shown(cells, focused: "2").map(\.name) == ["1", "2", "3", "4"])
        #expect(ToyHome.shown(cells, focused: "6").map(\.name) == ["1", "2", "3", "6"])
        #expect(ToyHome.shown(cells, focused: nil).map(\.name) == ["1", "2", "3", "4"])
        #expect(ToyHome.shown(Array(cells.prefix(2)), focused: "1").map(\.name) == ["1", "2"])
    }

    @Test("With the tiler stopped, Workspaces keeps four slots: the bound workspaces' names in order, else 1 to 4")
    func stoppedSlots() {
        #expect(ToyHome.stoppedSlots(actions: ["workspaces.go:2", "apps.terminal", "workspaces.go:10", "workspaces.go:1"]) == ["1", "2", "10"])
        #expect(ToyHome.stoppedSlots(actions: (1...6).map { "workspaces.go:\($0)" }) == ["1", "2", "3", "4"])
        #expect(ToyHome.stoppedSlots(actions: ["workspaces.go:Mail", "workspaces.go:3"]) == ["3", "Mail"])
        #expect(ToyHome.stoppedSlots(actions: ["apps.terminal"]) == ["1", "2", "3", "4"])
    }

    @Test("A workspace's windows stack in columns: one or two side by side, three as one and two, four or more as two and two")
    func columns() {
        #expect(ToyHome.columns(0) == [])
        #expect(ToyHome.columns(1) == [1])
        #expect(ToyHome.columns(2) == [1, 1])
        #expect(ToyHome.columns(3) == [1, 2])
        #expect(ToyHome.columns(4) == [2, 2])
        #expect(ToyHome.columns(9) == [2, 2])
    }

    @Test("The words Home builds: the greeting by the hour, a workspace's apps shortest last, the binds chip, a copy's line")
    func words() {
        #expect([5, 11, 12, 17, 18, 2].map(ToyHome.greeting) == ["Morning", "Morning", "Afternoon", "Afternoon", "Evening", "Evening"])
        #expect(ToyHome.appNames(["Telegram", "Discord", "Spotify"]) == ["Telegram, Discord, Spotify", "Telegram, Discord +1", "Telegram +2"])
        #expect(ToyHome.appNames(["Zen"]) == ["Zen"])
        #expect(ToyHome.bindsLine(binds: 50, clashes: 0) == "binds, 0 clashes")
        #expect(ToyHome.bindsLine(binds: 1, clashes: 1) == "bind, 1 clash")
        #expect(ToyHome.clipLine(kind: .link, app: "Ghostty", ago: "2 min ago") == "Ghostty · 2 min ago")
        #expect(ToyHome.clipLine(kind: .colour, app: "Zen", ago: "9 min ago") == "Colour · Zen · 9 min ago")
        #expect(ToyHome.clipLine(kind: .image, app: nil, ago: "now") == "Image · now")
    }

    @Test("A meter's bars are its last readings against its ceiling, an unread one a stub")
    func bars() {
        #expect(ToyHome.bars([0.5, nil, 1, 2], count: 3, top: 2) == [0, 0.5, 1])
        #expect(ToyHome.bars([0.4], count: 3, top: 1) == [0.4])
        #expect(ToyHome.bars([], count: 3, top: 1) == [])
    }

    @Test("The frame and Home hosted under Toybox draw otherwise than Instrument, and Toybox follows the theme dark or light")
    func drawn() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        let engine = Engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowView(model: model, look: look).environment(engine)
        let home = HomePage(onScreen: false) { _ in }.environment(engine).styled(.page(.home), look: look)
        for (name, view) in [("frame", AnyView(window)), ("home", AnyView(home))] {
            // Toybox follows the theme, not the style's dark switch: Toybox Night is dark, Toybox light.
            func draw(_ style: PilotStyle, dark: Bool = true) throws -> Data {
                look.style = style
                look.themeID = dark ? "toybox-night" : "toybox"
                return try StyleTests().pixels(view, look: look)
            }
            let instrument = try draw(.instrument), dark = try draw(.toybox), light = try draw(.toybox, dark: false)
            #expect(dark != instrument && light != instrument, "\(name) drew Instrument under Toybox")
            #expect(dark != light, "\(name): Toybox light drew dark")
        }
    }
}
}
#endif
