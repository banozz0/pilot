#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Toybox's other pages (card agent-bo-95423182, batch 2 on): the whole window at 1440 by 900 in Toybox dark and light on
/// each page and part, and Instrument beside it, seeded as ToyboxHomeRenders does (fakes; nothing reaches the tiler, the
/// clipboard or the network). `PILOT_RENDER_ONLY=<part of a name>[,<another>]` narrows it; `PILOT_RENDER_THEME=<id>` picks the theme.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ToyboxPagesRenders`
extension SharedLook {
@MainActor
@Suite("Toybox pages renders")
struct ToyboxPagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let places: [(name: String, place: AppPlace)] = [
        ("workspaces", AppPlace(.workspaces)), ("tiling", AppPlace(.tiling)),
        ("clipboard", AppPlace(.clipboard)), ("snippets", AppPlace(.snippets)),
        ("look", AppPlace(.look)), ("system", AppPlace(.system)), ("stats", AppPlace(.stats)), ("menubar", AppPlace(.menuBar)),
        ("install", AppPlace(.catalogue)), ("webapps", AppPlace(.webApps)), ("openwith", AppPlace(.openWith)), ("configs", AppPlace(.configs)),
        ("menu", AppPlace(.menu)), ("general", AppPlace(.general)), ("ai", AppPlace(.ai)), ("extensions", AppPlace(AppPage.extensions)),
    ]

    static let tall: Set<String> = ["look", "system", "menubar"]

    @Test("Toybox's other pages render dark and light beside Instrument", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("toybox-pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        try SharedLook.HomeRenders.seedPresets()
        let windows = try AeroWindow.parse(ToyboxHomeRenders.windows)
        engine.observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows)
        SharedLook.StatsRenders.seed(SystemSampler.shared)

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.contains($0) } } ?? true }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        // PILOT_RENDER_THEME picks the theme (Lagoon by default): Toybox follows it.
        look.themeID = Self.env["PILOT_RENDER_THEME"] ?? "lagoon"
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }

        func shot(_ name: String, _ place: AppPlace, style: PilotStyle, dark: Bool = true, width: Int = 1440, height: Int = 900) throws {
            guard wanted(name) else { return }
            look.style = style
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        for (name, place) in Self.places {
            try shot("\(name)-toybox-dark", place, style: .toybox)
            try shot("\(name)-toybox-light", place, style: .toybox, dark: false)
            try shot("\(name)-instrument", place, style: .instrument)
        }
        // Onboarding's four steps (batch 4; Permissions and Extras, 2026-10-28), in its own window as PilotApp opens it.
        for step in [OnboardingModel.Step.welcome, .permissions, .extras, .tryIt] {
            for (suffix, style, dark) in [("toybox-dark", PilotStyle.toybox, true), ("toybox-light", .toybox, false), ("instrument", .instrument, true)] {
                let name = "onboarding-\(step)-\(suffix)"
                guard wanted(name) else { continue }
                look.style = style
                let model = OnboardingModel()
                model.step = step
                let host = NSHostingView(rootView: OnboardingView(model: model).environment(engine))
                host.frame.size = host.fittingSize
                let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Welcome to Pilot"
                w.isReleasedWhenClosed = false
                w.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let chrome = try #require(w.contentView?.superview)
                chrome.layoutSubtreeIfNeeded()
                try #require(snapshot(chrome, scale: 2)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(name).png"))
                w.close()
            }
        }
        // Install's catalogue with its rows: the test bundle carries no install-catalogue.json, so the page in the window
        // shows none; this one reads Packaging's copy.
        let catalogue = try InstallCatalogue.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Packaging/install-catalogue.json")))
        for (suffix, style, dark) in [("toybox-dark", PilotStyle.toybox, true), ("toybox-light", .toybox, false), ("instrument", .instrument, true)] {
            let name = "catalogue-rows-\(suffix)"
            guard wanted(name) else { continue }
            look.style = style
            let host = NSHostingView(rootView: InkGround { CataloguePage(entries: catalogue) }.styled(.page(.install)).pilotTheme().environment(engine))
            host.frame.size = NSSize(width: 1100, height: 1300)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(name).png"))
        }
        // The long pages whole, for the review: a window tall enough to show what the 900 pt one scrolls to.
        for (name, place) in Self.places where Self.tall.contains(name) {
            try shot("\(name)-toybox-light-tall", place, style: .toybox, dark: false, height: 1900)
            try shot("\(name)-toybox-dark-tall", place, style: .toybox, height: 1900)
        }
    }
}

/// A page on its style's ground, as the window's frame lays it, with the style's default words.
private struct InkGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
