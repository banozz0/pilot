#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Look, Setup and Stats in Instrument (card agent-bo-95423181, batch 5): the whole window, frame and page, under
/// Nightwatch at 1440, 1000 and 760 wide (Look and Setup also 2000 tall, for their foot), and under Paper (light) and Hearth (warm) at 1440, seeded as ToyboxPagesRenders
/// does (fakes; nothing reaches the tiler or the network). Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter InstrumentPagesRenders`
extension SharedLook {
@MainActor
@Suite("Instrument pages renders")
struct InstrumentPagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Look, Setup and Stats render in Instrument at three widths and in three themes",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("instrument-pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        let windows = try AeroWindow.parse(ToyboxHomeRenders.windows)
        engine.observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows)
        SharedLook.StatsRenders.seed(SystemSampler.shared)

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]
        let shots: [(theme: String, widths: [Int])] = [("nightwatch", [1440, 1000, 760]), ("paper", [1440]), ("hearth", [1440])]
        for (theme, widths) in shots {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            for page in [AppPage.look, .system, .activity] where only.map({ $0.split(separator: ",").contains { page.rawValue.contains($0) } }) ?? true {
                // Look's and Setup's foot too, in a window tall enough for all of it, at the widest under Nightwatch.
                let tall = theme == "nightwatch" && page != .activity ? [(1440, 2000, "-tall")] : []
                for (width, height, suffix) in widths.map({ ($0, 900, "") }) + tall {
                    window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
                    model.go(AppPlace(page))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("\(page.rawValue)-\(theme)-\(width)\(suffix).png"))
                }
            }
        }
    }

    /// Batch 6's pages (Workspaces and Tiling, Clipboard and Snippets, Install's catalogue and Web apps,
    /// Defaults, Pilot, Extensions): Nightwatch at 1440 and 760, Paper at 1440. Install's catalogue has no rows in the test
    /// bundle, so its rows are shot apart, from Packaging's copy, on the page ground at the page's two widths.
    static let rest: [(name: String, place: AppPlace)] = [
        ("workspaces", AppPlace(.workspaces)), ("tiling", AppPlace(.tiling)), ("clipboard", AppPlace(.clipboard)),
        ("snippets", AppPlace(.snippets)), ("install", AppPlace(.catalogue)),
        ("webapps", AppPlace(.webApps)), ("openwith", AppPlace(.openWith)), ("configs", AppPlace(.configs)), ("general", AppPlace(.general)),
        ("ai", AppPlace(.ai)), ("menu", AppPlace(.menu)), ("stats", AppPlace(.stats)), ("extensions", AppPlace(.extensions)),
    ]

    @Test("Batch 6's pages render in Instrument at two widths and in two themes",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderRest() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("instrument-rest")
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
        // Extensions on ExtensionsPageViewTests' fixture (three extensions, two folders not read), one bound.
        engine.binds.replace("ext.github.search", with: Key("g", .shift))
        let fixture = URL(fileURLWithPath: home).appending(path: "extensions-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let extensions = try await ExtensionsPageViewTests.fixture(in: fixture)
        let make = ExtensionsPageView.make
        ExtensionsPageView.make = { extensions }
        defer { ExtensionsPageView.make = make }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.contains($0) } } ?? true }
        let shots: [(theme: String, widths: [Int])] = [("nightwatch", [1440, 760]), ("paper", [1440])]
        let catalogue = try InstallCatalogue.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Packaging/install-catalogue.json")))
        for (theme, widths) in shots {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            for (name, place) in Self.rest where wanted(name) {
                for width in widths {
                    window.setContentSize(NSSize(width: CGFloat(width), height: 900))
                    // Off the page and back, awaited, so a page that reads on appearing (Extensions) has landed.
                    model.go(AppPlace(.home))
                    try await Task.sleep(for: .milliseconds(200))
                    model.go(place)
                    try await Task.sleep(for: .milliseconds(900))
                    frame.layoutSubtreeIfNeeded()
                    try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("\(name)-\(theme)-\(width).png"))
                }
            }
            // The catalogue's rows on the page's ground, at the page's width beside the sidebar.
            guard wanted("catalogue") else { continue }
            for width in widths {
                let host = NSHostingView(rootView: CatalogueGround { CataloguePage(entries: catalogue) }.styled(.page(.install)).pilotTheme().environment(engine))
                host.frame.size = NSSize(width: CGFloat(width) - (width < 1000 ? 208 : 232), height: 1500)
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("catalogue-rows-\(theme)-\(width).png"))
            }
        }
    }

    /// General › About's Acknowledgements (SH10), the texts read from Packaging, and two licence sheets shot apart
    /// (a sheet is a window of its own), under Nightwatch at 1440.
    @Test("General › About renders its Acknowledgements and one licence sheet",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderAbout() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("instrument-about")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let saved = Acknowledgement.directory
        Acknowledgement.directory = LookThemeTests.fonts.deletingLastPathComponent()
        defer { Acknowledgement.directory = saved }
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let savedLook = (look.themeID, look.style)
        defer { (look.themeID, look.style) = savedLook }
        look.style = .instrument
        look.themeID = "nightwatch"
        AppWindowController.applyLook(look, to: window)
        window.setContentSize(NSSize(width: 1440, height: 1100))
        model.go(AppPlace(.general, .about))
        try await Task.sleep(for: .milliseconds(1200))
        frame.layoutSubtreeIfNeeded()
        try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("about-nightwatch-1440.png"))

        // Parakeet's short credit, and the display fonts' twelve texts joined, the longest sheet.
        for (name, file) in [("Parakeet", "parakeet"), ("Display fonts", "fonts")] {
            let entry = try #require(Acknowledgement.known.first { $0.name.hasPrefix(name) })
            let host = NSHostingView(rootView: LicenceSheet(entry: entry).pilotSheet().floating().environment(engine))
            host.frame.size = NSSize(width: 620, height: 520)
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("licence-sheet-\(file).png"))
        }
    }
}

/// A page on its style's ground, as the window's frame lays it.
private struct CatalogueGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
