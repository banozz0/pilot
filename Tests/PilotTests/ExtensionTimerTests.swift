import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Pomodoro as an extension (2026-10-10): Pilot's one timer, started by an extension's `timer` action, on a fake clock.
/// Its end and buttons go to a spy here; the last test runs one as its extension's through ExtensionActions.
@MainActor
@Suite("Extension timer")
struct ExtensionTimerTests {
    final class Clock { var now = Date(timeIntervalSinceReferenceDate: 800_000_000) }

    static let owner = ExtensionTimer.Owner(id: "pomodoro", title: "Pomodoro")
    static let pause = Extension.Item.Action(kind: .run(command: "pause", context: nil), title: "Pause")
    static let skip = Extension.Item.Action(kind: .run(command: "skip", context: nil), title: "Skip")
    static let ended = Extension.Item.Action(kind: .run(command: "ended", context: nil))

    /// The renders' alerts: a focus block's end with two buttons, and one with none, which shows OK.
    static let alert = Extension.AlertSpec(text: "Focus done", note: "4th block today. Take 15.", sound: "Glass",
                                           actions: [Extension.Item.Action(kind: .run(command: "rest", context: nil), title: "Start break"),
                                                     Extension.Item.Action(kind: .run(command: "stop", context: nil), title: "Stop")])
    static let plainAlert = Extension.AlertSpec(text: "Break done")

    /// A Pomodoro-like focus block: 25 minutes titled Focus, ending in the extension's `ended`, with Pause and Skip.
    static func focus(paused: Bool = false, seconds: Int = 1500) -> Extension.TimerSpec {
        Extension.TimerSpec(title: "Focus", seconds: seconds, paused: paused, end: ended, actions: [pause, skip])
    }

    /// A timer on `clock` whose actions and HUD lines land in the returned lists.
    private func timer(_ clock: Clock) -> (ExtensionTimer, acted: () -> [String], said: () -> [String]) {
        let timer = ExtensionTimer(now: { clock.now })
        var acted: [String] = [], said: [String] = []
        timer.act = { action, owner in acted.append("\(owner.id) \(action.label)") }
        timer.hud = { said.append($0) }
        return (timer, { acted }, { said })
    }

    @Test("A timer counts down from its seconds with its title and buttons, and at zero runs its end once as its extension's")
    func countsDown() {
        let clock = Clock()
        let (timer, acted, said) = timer(clock)
        timer.start(Self.focus(), owner: Self.owner)
        #expect(timer.countdown == "25:00" && timer.left == 1 && timer.title == "Focus" && !timer.isPaused)
        #expect(timer.buttons.map(\.label) == ["Pause", "Skip"] && timer.ends == clock.now.addingTimeInterval(1500))
        clock.now += 61
        timer.tick()
        #expect(timer.countdown == "23:59")
        #expect(abs((timer.left ?? 0) - 1439.0 / 1500) < 0.001)
        clock.now += 1439
        timer.tick()
        timer.tick()
        #expect(acted() == ["pomodoro Run"] && said().isEmpty, "the end, once")
        #expect(timer.title == nil && timer.countdown == nil && timer.left == nil && timer.ends == nil)
    }

    @Test("Without an end, zero says the title is done")
    func doneWithoutEnd() {
        let clock = Clock()
        let (timer, acted, said) = timer(clock)
        timer.start(Extension.TimerSpec(title: "Tea", seconds: 180), owner: Self.owner)
        clock.now += 180
        timer.tick()
        #expect(said() == ["Tea done"] && acted().isEmpty)
    }

    @Test("A paused timer shows its time held: it neither counts nor ends")
    func paused() {
        let clock = Clock()
        let (timer, acted, said) = timer(clock)
        timer.start(Self.focus(paused: true, seconds: 754), owner: Self.owner)
        #expect(timer.countdown == "12:34" && timer.isPaused && timer.ends == nil)
        clock.now += 10_000
        timer.tick()
        #expect(timer.countdown == "12:34" && acted().isEmpty && said().isEmpty)
    }

    @Test("A new timer replaces the one running, whoever sent it; seconds 0 stops it only for its own extension")
    func replaceAndStop() {
        let clock = Clock()
        let (timer, acted, _) = timer(clock)
        timer.start(Self.focus(), owner: Self.owner)
        let tea = ExtensionTimer.Owner(id: "tea", title: "Tea")
        timer.start(Extension.TimerSpec(title: "Steep", seconds: 240), owner: tea)
        #expect(timer.title == "Steep" && timer.countdown == "04:00" && timer.owner == tea && timer.buttons.isEmpty)
        timer.start(Extension.TimerSpec(title: "x", seconds: 0), owner: Self.owner)
        #expect(timer.title == "Steep", "another extension's stop leaves it")
        timer.stop(extension: "pomodoro")
        #expect(timer.title == "Steep")
        timer.start(Extension.TimerSpec(title: "x", seconds: 0), owner: tea)
        #expect(timer.title == nil, "its own stop ends it")
        clock.now += 1500
        timer.tick()
        #expect(acted().isEmpty, "the replaced focus never ends")
    }

    @Test("A button runs its action as the timer's extension's; an index it lacks does nothing")
    func buttons() {
        let (timer, acted, _) = timer(Clock())
        timer.start(Self.focus(), owner: Self.owner)
        timer.press(1)
        timer.press(5)
        #expect(acted() == ["pomodoro Skip"])
        timer.stop()
        timer.press(0)
        #expect(acted() == ["pomodoro Skip"])
    }

    @Test("A timer's action runs as its extension, read again with its folders; an extension gone since says so")
    func runsAsExtension() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-timer-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = dir.appending(path: "Extensions/pomodoro")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(#"{"id": "pomodoro", "title": "Pomodoro", "commands": [{"name": "ended", "title": "Ended", "mode": "no-view", "run": "go", "hidden": true}]}"#.utf8)
            .write(to: ext.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "go").path)
        let storage = ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: ExtensionsModuleTests.FakeKeychain())
        var ran: [String] = [], said: [String] = []
        await ExtensionActions.run(Self.ended, asExtension: "pomodoro", title: "Pomodoro", folder: dir.appending(path: "Extensions"), storage: storage,
                                   act: { action, ext, inputs in ran.append("\(ext.id) \(action.label) \(inputs.data.lastPathComponent)") }, hud: { said.append($0) })
        #expect(ran == ["pomodoro Run data"] && said.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "data/pomodoro/data").path), "its folders made, as for any run")
        try FileManager.default.removeItem(at: ext)
        await ExtensionActions.run(Self.ended, asExtension: "pomodoro", title: "Pomodoro", folder: dir.appending(path: "Extensions"), storage: storage,
                                   act: { _, _, _ in ran.append("ran") }, hud: { said.append($0) })
        #expect(ran.count == 1 && said == ["Pomodoro is no longer in Extensions."])
    }
}

extension ExtensionTimer {
    /// The renders' running timer: ExtensionTimerTests' focus block, its extension Pomodoro.
    func startFocus(paused: Bool = false) { start(ExtensionTimerTests.focus(paused: paused), owner: ExtensionTimerTests.owner) }
}
