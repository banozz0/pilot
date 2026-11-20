#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The panel's shell (pilot-ui-redesign T3, round 2's shots 7c-home, 7c-tools, 7c-more): Home, Tools › Captures, and More's
/// card open over an area it holds, at the window's first-open size in Instrument, Tokyo Night and Porcelain. First it measures
/// the tabs at its narrowest (`minSize`): `AppArea.tabCount` of `tabOrder` fit the bar with every name on one line, the More tab carrying its widest
/// name, and one more would not. Then Home at 780, 1296 and 3440 pt: the bar's own count follows the width (ADR 0018,
/// 2026-11-20), `tabCount` at the narrowest and every area, no More, at full width. The suite keeps the rail's name so the suite list stays stable. Seeded as Home's renders
/// are, in a moved home.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WindowRailRenders`
extension SharedLook {
@MainActor
@Suite("Window rail renders")
struct WindowRailRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let looks: [(name: String, theme: String)] = [("dark", "tokyo-night"), ("light", "porcelain")]

    @Test("The panel's tab bar fits its tabs named, and Home, Tools › Captures and More render at the first-open size", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let engine = try InstrumentBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("panel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let look = Look.shared
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }
        look.style = .instrument

        // The count that fits: the strip's own width at each count, the More tab named for the widest area it can hold.
        let room = PanelTabBar.room(AppWindowController.minSize.width)
        for developer in [false, true] {
            func width(_ count: Int) -> CGFloat {
                let split = AppArea.tabs(count: count, developer: developer)
                let widest = split.more.map(\.title).max { $0.count < $1.count } ?? "More"
                let strip = PanelTabStrip(tabs: split.tabs, open: .home, moreTitle: widest, moreOn: true, moreShown: !split.more.isEmpty)
                    .styled(.window, look: look).environment(engine)
                return NSHostingView(rootView: strip).fittingSize.width
            }
            let fits = width(AppArea.tabCount), more = width(AppArea.tabCount + 1)
            print("panel tabs: room \(room) pt, developer \(developer): \(AppArea.tabCount) tabs \(fits) pt, \(AppArea.tabCount + 1) tabs \(more) pt")
            #expect(fits <= room && more > room, "\(AppArea.tabCount) tabs: \(fits) pt, \(AppArea.tabCount + 1): \(more) pt, room \(room) pt")
        }

        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.window.rail")!)
        let more = PanelMore()
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model, more: more).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        window.setContentSize(AppWindowController.size)
        func shot(_ file: String, _ place: AppPlace, moreOpen: Bool = false, width: CGFloat = AppWindowController.size.width) throws {
            more.open = false
            window.setContentSize(NSSize(width: width, height: AppWindowController.size.height))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            more.open = moreOpen
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }
        // More open over an area it holds at the narrowest, so the More tab carries that area's name.
        let held = try #require(AppArea.tabs(developer: false).more.first)
        let all = AppArea.tabs(count: .max, developer: false).tabs.count
        for (name, theme) in Self.looks {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            for (width, tabs) in [(AppWindowController.minSize.width, AppArea.tabCount), (AppWindowController.size.width, nil), (3440, all)] {
                try shot("\(name)-home-\(Int(width))", AppPlace(.home), width: width)
                print("panel tabs at \(Int(width)) pt: \(PanelTabs.count) of \(all)")
                if let tabs { #expect(PanelTabs.count == tabs, "\(Int(width)) pt: \(PanelTabs.count) tabs") }
            }
            try shot("\(name)-tools-captures", AppPlace(.captures))
            try shot("\(name)-more-open", AppPlace(held.pages[0]), moreOpen: true, width: AppWindowController.minSize.width)
        }
    }
}
}
#endif
