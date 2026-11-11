import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Story 152 (N6): Defaults › Menu keeps the root's order and hidden rows in Pilot's settings, survives an id no branch
/// has, and Reset gives today's root back. The block drawn offscreen and read back; PILOT_RENDER_DIR keeps the PNGs.
@MainActor
@Suite("Menu root settings")
struct MenuRootSettingsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }

    @Test("Order and hidden rows are kept; a stored unknown id is ignored, not a crash; Reset is today's root")
    func kept() {
        let store = Self.defaults()
        store.set(["reports-from-the-future", "config", "apps"], forKey: "menu.rootOrder")
        store.set(["reports-from-the-future"], forKey: "menu.rootHidden")
        let settings = MenuRootSettings(defaults: store)
        // "config" is no branch now (an extra since Sven 2026-10-21): the rest stand in their default places.
        #expect(settings.root.shown() == [.apps, .learn, .trigger, .install, .remove, .update, .clean, .extensions, .about, .system])
        settings.root.move(.clean, to: 0)
        settings.root.show(.learn, false)
        let again = MenuRootSettings(defaults: store)
        #expect(again.root.shown() == [.clean, .apps, .trigger, .install, .remove, .update, .extensions, .about, .system])
        again.reset()
        #expect(MenuRootSettings(defaults: store).root.isDefault())
    }

    @Test("The Menu block lists every root row with its switch, and Reset once changed")
    func renders() throws {
        let look = LookPageTests().look().0
        let settings = MenuRootSettings(defaults: Self.defaults())
        settings.root.move(.system, to: 0)
        settings.root.show(.clean, false)
        var text = "", rows = ""
        let view = MenuRootBlock(settings: settings).padding(20)
            .frame(width: 760, height: 560, alignment: .top).background(Theme.background).pilotTheme(look: look)
        try LookPageTests().hosted(view, height: 560) { host in
            let rep = try #require(snapshot(host, scale: 2))
            if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "menu-root.png"))
            }
            text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
            // Read whole, Vision joins a row's icon to its label and, on a slightly different layout of the same page
            // (the full run's), drops the row: "Install" went missing. So the labels are read in the column right of the
            // icons, where each stands alone.
            let cg = try #require(rep.cgImage)
            let labels = try #require(cg.cropping(to: CGRect(x: 80 * 2, y: 0, width: cg.width - 80 * 2, height: cg.height)))
            rows = try recognisedText(in: NSBitmapImageRep(cgImage: labels)).map(\.text).joined(separator: "\n")
        }
        for line in ["What the menu shows first", "Reset to default"] {
            #expect(text.contains(line), "\(line) missing, read: \(text)")
        }
        for line in ["System", "Apps", "Learn", "Actions", "Install", "Remove", "Update", "Clean", "Extensions"] {
            #expect(rows.contains(line), "\(line) missing, read: \(rows)")
        }
    }
}
