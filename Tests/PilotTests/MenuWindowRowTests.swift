#if DEBUG
import AppKit
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Find a window (test row 2.3): a root search lists open windows as "App — title", and every such row says which
/// workspace its window is in, the current row or not, in every style.
extension SharedLook {
@MainActor
@Suite("Menu window rows")
struct MenuWindowRowTests {
    /// A browser tab's title, as long as Sven's: it must not push the workspace off the row.
    static let longTitle = "Pilot test part 2 fixes: Hyper+Space menu, find a window and script commands — Google Chrome — Sven"

    /// A root search whose current row is an app, a window under it on `workspace`.
    static func searching(workspace: String) -> MenuNavigator {
        var nav = MenuNavigator(entries: [MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps)])
        nav.query = "te"
        nav.provide(.window, MenuEntries.windows([AeroWindow(id: 4, appName: "TextEdit", bundleId: "com.apple.TextEdit", pid: 1,
                                                             workspace: workspace, monitorId: 1, layout: "h_tiles", title: Self.longTitle)],
                                                 excluding: nil))
        return nav
    }

    @Test("A window row that is not the current one draws its workspace, in Toybox and Instrument",
          arguments: [PilotStyle.toybox, .instrument])
    func workspaceShown(_ style: PilotStyle) throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        look.style = style
        func pixels(_ workspace: String) throws -> Data {
            let nav = Self.searching(workspace: workspace)
            let current = try #require(nav.rows.indices.contains(nav.selection) ? nav.rows[nav.selection] : nil)
            #expect(current.target == .app("com.apple.TextEdit"), "the window row is the current one")
            #expect(nav.rows.contains { $0.target == .window(4) })
            let model = MenuModel(nav: nav)
            var data = Data()
            let view = MenuView(model: model).styled(.menu, look: look)
            try LookPageTests().hosted(view.pilotTheme(look: look)) { host in
                PanelTestSupport.pump(0.05)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(host))
                data = Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
            }
            return data
        }
        #expect(try pixels("3") != pixels("7"), "\(style): the window row looks the same on workspace 3 and 7")
    }
}
}
#endif
