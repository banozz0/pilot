#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Counts the app window's redraws while it shows but is not key: the layout passes of its SwiftUI host, per page, over
/// idle seconds (Sven, 2026-10-17: glass behind other apps without the stutter). An offscreen window starts no `.task`,
/// so the repeating reads (AppWindowModel.live) are not in it: what it finds is Observable, timeline and animation churn.
/// Opt-in, in a moved home like Home's renders.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_IDLE_PROBE=1 [PILOT_IDLE_SECONDS=2] [PILOT_IDLE_ONLY=home,stats] swift test --filter IdleRedrawProbe`
extension SharedLook {
@MainActor
@Suite("Idle redraw probe")
struct IdleRedrawProbe {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let idle = Double(env["PILOT_IDLE_SECONDS"] ?? "2") ?? 2

    final class Counting<V: View>: NSHostingView<V> {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }

    @MainActor @Observable final class Ticks { var n = 0 }
    struct TicksView: View {
        let ticks: Ticks
        var body: some View { Text("\(ticks.n)") }
    }

    static func idleLayouts<V: View>(_ host: Counting<V>, seconds: Double) -> Int {
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layouts = 0
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        return host.layouts
    }

    static func window(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    @Test("The count sees a model's changes and nothing from a still view", .enabled(if: env["PILOT_IDLE_PROBE"] != nil))
    func control() {
        testApp()
        let still = Counting(rootView: Text("still"))
        let stillWindow = Self.window(still)
        defer { stillWindow.close() }
        #expect(Self.idleLayouts(still, seconds: 2) == 0)
        let ticks = Ticks()
        let observed = Counting(rootView: TicksView(ticks: ticks))
        let observedWindow = Self.window(observed)
        defer { observedWindow.close() }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { ticks.n += 1 } }
        defer { timer.invalidate() }
        #expect(Self.idleLayouts(observed, seconds: 2.1) >= 3, "four changes in two seconds")
    }

    @Test("Each page, shown and not key, over idle seconds",
          .enabled(if: env["PILOT_IDLE_PROBE"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func pages() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require((NSHomeDirectory() as NSString).resolvingSymlinksInPath == (home as NSString).resolvingSymlinksInPath,
                     "the home directory did not move; refusing to start an engine on Sven's data")
        testApp()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        let engine = try HomeRenders.engine()
        let look = Look.shared
        look.glass = true
        look.transparency = 100
        defer { look.glass = false; look.transparency = 33 }
        let only = Self.env["PILOT_IDLE_ONLY"]?.split(separator: ",").map(String.init)
        for page in AppPage.allCases where only?.contains(page.rawValue) ?? true {
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            let host = Counting(rootView: AppWindowView(model: model).environment(engine))
            let window = AppWindowController.makeWindow(content: host)
            defer { window.close() }
            window.setContentSize(NSSize(width: 1280, height: 800))
            AppWindowController.applyLook(look, to: window)
            model.go(AppPlace(page))
            model.onScreen = true
            let layouts = Self.idleLayouts(host, seconds: Self.idle)
            print("probe page \(page.rawValue) layouts in \(Self.idle) s: \(layouts)")
            #expect(layouts <= 1, "\(page.rawValue) redraws on its own while the window is not key")
        }
    }
}
}
#endif
