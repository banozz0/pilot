import AppKit
import PilotCore
import PilotTiler

/// Rescue (story 72): a tiler parks windows of hidden workspaces off-screen, and a crash leaves them there. The bind
/// brings them back through Accessibility; Pilot's launch runs it quietly before its tiler starts (card
/// agent-bo-95422999, AC5).
@MainActor
final class WindowRescue {
    /// Every app's windows and the screens: Accessibility live, fakes in tests.
    struct Mac {
        var windows: @MainActor () -> [RescueWindow]
        var screens: @MainActor () -> [CGRect]
        /// The visible frame stranded windows land in.
        var landing: @MainActor () -> CGRect

        static let live = Mac(windows: {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.flatMap { app in
                AXWindow.windows(of: app.processIdentifier).compactMap { window in
                    guard !window.isMinimised, let frame = window.frame else { return nil }
                    return RescueWindow(frame: frame, move: window.setFrame)
                }
            }
        }, screens: { Screens.frames }, landing: { Screens.visibleFrames[Screens.mainIndex] })
    }

    private let tiler: TilerService
    private let mac: Mac

    init(tiler: TilerService, mac: Mac = .live) {
        self.tiler = tiler
        self.mac = mac
    }

    static func register(into registry: inout ActionRegistry, rescue: WindowRescue) {
        do { try registry.register(Action(id: "workspaces.rescue", label: "Rescue stranded windows", module: .workspaces,
                                          defaultKey: Key("escape", shift: true)) { rescue.run() }) }
        catch { wslog.error("workspaces.rescue: \(String(describing: error), privacy: .public)") }
    }

    /// The bind and the dropdown. While a tiler runs, Pilot's or the old one, its off-screen windows are hidden on purpose,
    /// not stranded.
    func run() {
        let running = tiler.isRunning ? tiler.tilerName : tiler.otherTilerIsRunning ? OtherTiler.name : nil
        if let running {
            wslog.notice("rescue: \(running, privacy: .public) is running, no window is stranded")
            return HUD.tip("\(running) is running: no window is stranded")
        }
        bringBack()
    }

    /// Pilot's tiler about to start, with no other tiler running (TilerService.startEngine): no HUD.
    func bringBackQuietly() { bringBack(quietly: true) }

    /// Quietly is the launch's run: no HUD at all, only the log line.
    func bringBack(quietly: Bool = false) {
        let t0 = ContinuousClock.now
        let screens = mac.screens()
        let stranded = mac.windows().filter { Rescue.isStranded($0.frame, screens: screens) }
        let landing = Rescue.placements(stranded.map(\.frame), in: mac.landing())
        for (window, frame) in zip(stranded, landing) { window.move(frame) }
        wslog.notice("rescue: \(stranded.count, privacy: .public) windows brought back, \(Int((ContinuousClock.now - t0) / .milliseconds(1)), privacy: .public) ms")
        if !quietly { HUD.tip(stranded.isEmpty ? "No window is stranded" : "\(stranded.count) windows brought back") }
    }
}

/// One window rescue may move: where it is, and how to move it.
struct RescueWindow {
    let frame: CGRect
    let move: (CGRect) -> Void
}
