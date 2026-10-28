import PilotCore
import Testing

/// The Power item's popover (Sven 2026-10-10): each action reaches the right command through a fake runner, so no test
/// locks, sleeps, restarts, shuts down or logs out this Mac; the three that end the session wait for their confirm.
@Suite("Power")
@MainActor
struct PowerTests {
    final class FakeRunner: PowerRunning {
        var ran: [PowerCommand] = []
        func run(_ command: PowerCommand) { ran.append(command) }
    }

    static let commands: [PowerAction: PowerCommand] = [
        .lock: .lockScreen,
        .sleep: .process("/usr/bin/pmset", ["sleepnow"]),
        .sleepDisplays: .process("/usr/bin/pmset", ["displaysleepnow"]),
        .restart: .systemEvents("restart"),
        .shutDown: .systemEvents("shut down"),
        .logOut: .systemEvents("log out"),
    ]

    @Test("The popover's six actions in order, the three that end the session named with an ellipsis")
    func catalogue() {
        #expect(PowerAction.allCases.map(\.title) == ["Lock screen", "Sleep", "Sleep displays", "Restart…", "Shut down…", "Log out…"])
        #expect(PowerAction.allCases.filter(\.confirms) == [.restart, .shutDown, .logOut])
        #expect([PowerAction.restart, .shutDown, .logOut].map { $0.confirmation?.yes } == ["Restart", "Shut down", "Log out"])
    }

    @Test("Lock screen, Sleep and Sleep displays run their command at once, none asks")
    func runsAtOnce() {
        for action in [PowerAction.lock, .sleep, .sleepDisplays] {
            let runner = FakeRunner()
            var ask = PowerAsk()
            let ran = ask.pick(action, on: runner)
            #expect(ran)
            #expect(runner.ran == [Self.commands[action]!] && ask.asking == nil, "\(action)")
        }
    }

    @Test("Restart, Shut down and Log out run nothing until confirmed, then their command once")
    func confirms() {
        for action in [PowerAction.restart, .shutDown, .logOut] {
            let runner = FakeRunner()
            var ask = PowerAsk()
            let ranAtOnce = ask.pick(action, on: runner)
            #expect(!ranAtOnce && runner.ran.isEmpty && ask.asking == action, "\(action)")
            let confirmed = ask.confirm(on: runner)
            #expect(confirmed && runner.ran == [Self.commands[action]!] && ask.asking == nil, "\(action)")
            let again = ask.confirm(on: runner)
            #expect(!again && runner.ran.count == 1, "a second confirm runs nothing")
        }
    }

    @Test("Cancel, or picking an action that runs at once, drops the ask without running it")
    func cancel() {
        let runner = FakeRunner()
        var ask = PowerAsk()
        ask.pick(.shutDown, on: runner)
        ask.cancel()
        let confirmed = ask.confirm(on: runner)
        #expect(ask.asking == nil && !confirmed && runner.ran.isEmpty)
        ask.pick(.restart, on: runner)
        ask.pick(.lock, on: runner)
        #expect(ask.asking == nil && runner.ran == [.lockScreen])
    }

    @Test("Power is an item in the Power group: one icon style, a popover on click, off until placed")
    func item() {
        #expect(BarKind.power.group == .power && BarKind.power.title == "Power" && BarKind.power.styles == [.icon])
        #expect(BarKind.power.click == .popover && !BarSettings.defaults.entry(.power).on)
        #expect(BarParts.parts(BarSettings.defaults.entry(.power), BarInputs()) == [.symbol("power")])
    }
}
