#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Extras by feature (Sven, 2026-10-29, Q555 to Q557, after his 1.0 stranger run skipped the helpers): Onboarding's
/// Extras step on a fresh Mac (nothing on it, the real ticks) in Toybox and Instrument, as it opens and with Homebrew
/// unticked; then where Update and Clean offer the install later: the menu's Update without Homebrew, Clean without
/// Homebrew and Mole, and Mac › Update & Clean without either.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ExtrasByFeatureRenders`
extension SharedLook {
@MainActor
@Suite("Extras by feature renders")
struct ExtrasByFeatureRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Extras grouped by feature, and Update and Clean's install offers", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("extras-by-feature")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let engine = try SharedLook.HomeRenders.engine()
        let look = Look.shared
        look.themeID = Self.env["PILOT_RENDER_THEME"] ?? "lagoon"
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }

        for style in [PilotStyle.toybox, .instrument] {
            look.style = style
            for unticked in [false, true] {
                let model = OnboardingModel()
                model.step = .extras
                model.extras.seededOnMac = []
                let host = NSHostingView(rootView: OnboardingView(model: model).environment(engine))
                host.frame.size = host.fittingSize
                let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Welcome to Pilot"
                w.isReleasedWhenClosed = false
                w.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if unticked {
                    model.extras.set(.homebrew, false)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
                let chrome = try #require(w.contentView?.superview)
                chrome.layoutSubtreeIfNeeded()
                try #require(snapshot(chrome, scale: 2)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("extras-\(unticked ? "homebrew-unticked" : "fresh-mac")-\(style.rawValue).png"))
                w.close()
            }
        }

        look.style = .toybox
        var update = MenuNavigator(entries: [], branch: .update)
        update.provide(.package, home: .update, UpdateList.noHomebrew())
        try menu(update, "menu-update-no-homebrew", in: dir)
        var clean = MenuNavigator(entries: [], branch: .clean)
        clean.provide(.action, home: .clean, CleanMenu.entries(nil, mole: false, homebrew: false))
        try menu(clean, "menu-clean-no-homebrew-no-mole", in: dir)

        let page = UpkeepPage(store: ReportStore(folder: dir.appendingPathComponent("no-reports")), mole: false, homebrew: false)
            .styled(.page(.upkeep), look: look).frame(width: 1000, height: 500).pilotTheme(look: look)
        try LookPageTests().hosted(page, height: 500) { host in
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("upkeep-no-homebrew-no-mole.png"))
        }
    }

    private func menu(_ nav: MenuNavigator, _ name: String, in dir: URL) throws {
        let panel = HUD.makePanel(MenuView(model: MenuModel(nav: nav)))
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        content.layoutSubtreeIfNeeded()
        try #require(snapshot(content, scale: 2)?.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("\(name).png"))
    }
}
}
#endif
