#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pages in a big window (wide-pages, Sven on combined-14 build 3188: "When pilot is like enlarged, they are a little bit
/// empty"): every page and every tab past a page's first in the whole window, at 1700 by 1290 (a tiled window, as his)
/// and at the window's first size, in Tokyo Night (dark) and Porcelain (light), seeded as WindowPagesRenders is (fakes;
/// nothing reaches the tiler or the network). Then the first visit of Captures, Update & Clean, Open with and Pilot, built and
/// drawn alone as HomeRenders.firstVisit builds Home, into `wide-pages/first-visit.txt`. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WidePagesRenders`
/// PILOT_RENDER_ONLY narrows the shots to file names holding one of its comma-separated words; PILOT_RENDER_TIMING=0
/// leaves the timing out.
extension SharedLook {
@MainActor
@Suite("Wide pages renders")
struct WidePagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Every page, and every tab past a page's first, by file name.
    static let places: [(String, AppPlace)] = AppPage.allCases.map { ($0.rawValue, AppPlace($0)) }
        + AppSection.allCases.filter(\.isTab).map { ("\($0.page.rawValue)-\($0.rawValue)", AppPlace($0)) }

    static let sizes: [(name: String, size: NSSize)] = [("1700", NSSize(width: 1700, height: 1290)), ("default", AppWindowController.size)]

    @Test("Every page renders at 1700 by 1290 and at the window's first size, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("wide-pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        try SharedLook.HomeRenders.seedPresets()

        let engine = try SharedLook.HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]?.split(separator: ",").map(String.init)
        // Tried on, as Look's cards do: a theme pack the moved home holds would otherwise outrank `themeID`.
        defer { look.endTrial() }
        for (name, theme) in SharedLook.HomeRenders.looks {
            look.tryOn(id: theme, pack: nil)
            AppWindowController.applyLook(look, to: window)
            for (suffix, size) in Self.sizes {
                window.setContentSize(size)
                for (page, place) in Self.places {
                    let file = "\(name)-\(suffix)-\(page)"
                    guard only.map({ $0.contains { file.contains($0) } }) ?? true else { continue }
                    // Built whole: in view a page goes on a piece a frame at the screen's refresh (PageDeck.buildInView),
                    // which a window never ordered in does not get, so it would stop after its first frame. A ring asked
                    // for builds the part whole (PageView); this one names no row, so none is ringed. Set after the switch,
                    // which clears a ring, in the same turn, so the deck sees both at once.
                    model.go(place)
                    model.ringed = "wide-pages.render"
                    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                    model.ringed = nil
                    // Look ends what was tried on there once it is left or let go from the deck: on again for the shot.
                    if look.trialID != theme {
                        look.tryOn(id: theme, pack: nil)
                        AppWindowController.applyLook(look, to: window)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    }
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
                }
            }
        }
        window.setContentSize(AppWindowController.size)
        if Self.env["PILOT_RENDER_TIMING"] != "0" { try Self.firstVisit(engine: engine, look: look, to: dir) }
    }

    /// How long Captures, Update & Clean, Open with and Pilot take to build, lay out and draw as a first visit does, alone in a
    /// host at the window's first size and at 1700 by 1290, in Tokyo Night: a piece at a time as PageDeck.buildInView builds
    /// them (passes until its 8 ms frame budget is spent, drawn, then the next frame), the first frame and the time until
    /// whole. The first run warms up and is left out; the median of the next nine is written. A debug build's
    /// before-and-after measure, not the app's own milliseconds.
    static func firstVisit(engine: Engine, look: Look, to dir: URL) throws {
        look.tryOn(id: "tokyo-night", pack: nil)
        defer { look.endTrial() }
        let pages: [(String, AppPage, () -> AnyView)] = [
            ("captures", .captures, { AnyView(CapturesPage()) }),
            ("upkeep", .upkeep, { AnyView(UpkeepPage(mole: true, homebrew: true)) }),
            ("openWith", .openWith, { AnyView(OpenWithPage()) }),
            // The page with the most blocks flowing into PageFlow's columns.
            ("general", .general, { AnyView(GeneralPage()) }),
        ]
        func once(_ page: AppPage, _ view: () -> AnyView, _ size: CGSize) -> (first: Double, frames: Int, whole: Double) {
            drawingQoS()
            let stage = BuildStage()
            stage.inView = true
            let start = ContinuousClock.now
            let host = NSHostingView(rootView: view().environment(engine).environment(\.buildStage, stage)
                .styled(.page(page)).frame(width: size.width, height: size.height).pilotTheme(look: look))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            var frames: [Double] = [], frameStart = start
            repeat {
                repeat {
                    stage.step += 1; stage.held = false; stage.tickets = 1
                    host.layoutSubtreeIfNeeded()
                    if stage.held, stage.tickets == 1, !stage.holders.isEmpty { stage.holders.removeLast() }
                } while stage.held && ContinuousClock.now - frameStart < PageDeck.frameBudget
                host.display()
                CATransaction.flush()
                frames.append((ContinuousClock.now - frameStart) / .milliseconds(1))
                frameStart = .now
            } while stage.held && frames.count < 60
            let whole = (ContinuousClock.now - start) / .milliseconds(1)
            window.close()
            PanelTestSupport.pump(0.05)
            return (frames[0], frames.count, whole)
        }
        func line(_ values: [Double]) -> String {
            String(format: "median %.1f ms (", values.sorted()[values.count / 2]) + values.map { String(format: "%.1f", $0) }.joined(separator: " ") + ")"
        }
        var lines: [String] = []
        for (name, page, view) in pages {
            for (suffix, size) in Self.sizes {
                _ = once(page, view, size)
                let runs = (0..<9).map { _ in once(page, view, size) }
                lines.append("\(name) \(suffix) \(Int(size.width)) × \(Int(size.height)), first frame: " + line(runs.map(\.first))
                             + ", frames \(runs.map(\.frames).max() ?? 0), whole " + line(runs.map(\.whole)))
            }
        }
        try (lines + ["debug build"]).joined(separator: "\n").appending("\n").write(to: dir.appending(path: "first-visit.txt"), atomically: true, encoding: .utf8)
    }
}
}
#endif
