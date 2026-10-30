#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Film v2 (Sven, 2026-10-29, Q578 to Q583): the pages the 1.0 film never showed, in Pilot's window at the film's size and
/// in its theme (ExplainerFilmRenders.theme, Void), on Pilot default's binds as a new install has them: Keys › Swap keys
/// with one swap made, Keys › Plain combos, Launcher › Quicklinks (the shipped four) and Launcher › Aliases (a few saved),
/// and Tools › Voice. Fakes throughout, in a moved home: nothing is swapped at the HID level (the tap never runs here), and
/// no model, network or this Mac's devices are read. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter FilmV2Renders`
extension SharedLook {
@MainActor
@Suite("Film v2 renders")
struct FilmV2Renders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let aliases: [Alias] = [
        Alias(key: "action:apps.webApp", alias: "wa", title: "Make a web app"), Alias(key: "app:com.apple.Safari", alias: "sf", title: "Safari"),
        Alias(key: "action:apps.clipboard", alias: "cb", title: "Clipboard history"), Alias(key: "package:cask:zed", alias: "z", title: "Zed"),
        Alias(key: "app:com.mitchellh.ghostty", alias: "t", title: "Ghostty"),
    ]

    @Test("Pilot's window on Pilot default: Swap keys, Plain combos, Quicklinks, Aliases and Voice",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func pages() throws {
        let dir = try ExplainerFilmRenders.prepare("v2-pages")
        try FileManager.default.createDirectory(at: PilotFolder.support, withIntermediateDirectories: true)
        try #require(PilotFolder.support.path.hasPrefix(NSHomeDirectory()), "Pilot's folder would land outside the moved home")
        try AliasesStore.standard.save(Aliases(Self.aliases))
        let engine = try HomeRenders.engine()
        // Pilot default, the preset a new install starts on.
        try Data(#"{"version": 3, "preset": "pilot", "binds": []}"#.utf8).write(to: engine.binds.fileURL)
        engine.binds.load()
        // A swap reaches the keyboard only through this hook and a running tap; the render never starts the tap, and the hook
        // goes quiet first so no swap can reach this Mac's keyboard.
        engine.settings.onKeySwapsChange = {}
        engine.settings.keySwaps = [KeySwap(.rightCommand, .rightOption)]
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close(); engine.settings.keySwaps = [] }
        let frame = try #require(window.contentView?.superview)
        AppWindowController.applyLook(Look.shared, to: window)
        for (place, name) in [(AppPlace(.keySwaps), "key-swaps"), (AppPlace(.plainCombos), "plain-combos"),
                              (AppPlace(.quicklinks), "quicklinks"), (AppPlace(.aliases), "aliases"), (AppPlace(.voice), "voice")] {
            window.setContentSize(NSSize(width: 1200, height: 780))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
}
#endif
