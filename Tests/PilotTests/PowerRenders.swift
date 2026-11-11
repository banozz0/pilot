#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The Power item's popover (Sven 2026-10-10): its six actions, and Restart's confirm in place, in Instrument on
/// Tokyo Night. A fake runner, so nothing runs. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter PowerRenders`
@MainActor
@Suite("Power renders")
struct PowerRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    final class FakeRunner: PowerRunning {
        var ran: [PowerCommand] = []
        func run(_ command: PowerCommand) { ran.append(command) }
    }

    @Test("The Power popover renders its actions and Restart's confirm", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("power")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        let runner = FakeRunner()
        var restart = PowerAsk()
        restart.pick(.restart, on: runner)
        (look.themeID, look.style, look.glass) = ("tokyo-night", .instrument, false)
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        for (state, ask) in [("actions", PowerAsk()), ("confirm-restart", restart)] {
            try writeRender(PowerPopover(runner: runner, ask: ask).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: dir.appendingPathComponent("instrument-\(state).png"))
        }
        #expect(runner.ran.isEmpty, "a render runs nothing")
    }
}
}
#endif
