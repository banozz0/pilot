#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Every page and each of its tabs, the whole window under Nightwatch in Instrument (Toybox with `PILOT_RENDER_STYLE=toybox`),
/// at 1600 and 760 wide and 2200 tall so a page's foot shows (page density, Sven 2026-11-12: rows stretched too wide and
/// holes beside short blocks), or at `PILOT_RENDER_WIDTHS=1600,1200,760`. The Menu bar page is shot only as a control, to show
/// the change leaves it alone. Seeded as InstrumentPagesRenders' rest; opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> PILOT_RESOURCES=Packaging swift test --filter PageDensityRenders`
/// (`PILOT_RENDER_ONLY=general,look` for some).
extension SharedLook {
@MainActor
@Suite("Page density renders")
struct PageDensityRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Every page, each tab of it by name: `general`, `tiling-focusedWindow`.
    static var places: [(name: String, place: AppPlace)] {
        AppPage.allCases.flatMap { page in
            let tabs = page.tabs.map(\.value)
            return (tabs.isEmpty ? [nil] : tabs).map { section in
                (section.map { "\(page.rawValue)-\($0.rawValue)" } ?? page.rawValue, AppPlace(page, section))
            }
        }
    }

    @Test("Every page renders at 1600 and 760", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let toybox = Self.env["PILOT_RENDER_STYLE"] == "toybox"
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent(toybox ? "density-toybox" : "density")
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
        // A crash report from today in the test run's own folder, so About shows its third button, Reveal crash reports
        // (build 2425: three buttons squeezed Send feedback's label out of a column).
        try FileManager.default.createDirectory(at: CrashReports.folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let crash = CrashReports.folder.appending(path: "Pilot-\(stamp.string(from: Date().addingTimeInterval(-3600))).ips")
        FileManager.default.createFile(atPath: crash.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: crash) }
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
        look.style = toybox ? .toybox : .instrument
        look.themeID = "nightwatch"
        AppWindowController.applyLook(look, to: window)
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.hasPrefix($0) } } ?? true }
        for (name, place) in Self.places where wanted(name) {
            for width in Self.env["PILOT_RENDER_WIDTHS"].map({ $0.split(separator: ",").compactMap { Int($0) } }) ?? [1600, 760] {
                window.setContentSize(NSSize(width: CGFloat(width), height: 2200))
                // Off the page and back, awaited, so a page that reads on appearing has landed.
                model.go(AppPlace(place.page == .home ? .stats : .home))
                try await Task.sleep(for: .milliseconds(150))
                model.go(place)
                try await Task.sleep(for: .milliseconds(700))
                frame.layoutSubtreeIfNeeded()
                try #require(snapshot(frame, scale: 1)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(name)-\(width).png"))
            }
        }
    }
}
}
#endif
