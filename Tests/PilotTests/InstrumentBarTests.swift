#if DEBUG
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Instrument's top bar (card agent-bo-95423181, mockup A's topbar.html): where its hairlines go, which workspaces it
/// splits off as another display's, and what its focus pill says.
@MainActor
@Suite("Instrument top bar")
struct InstrumentBarTests {
    static func slot(_ kind: BarKind) -> BarSlot { .item(BarSettings.defaults.entry(kind)) }

    @Test("A hairline leads each new group of the bar: the app after the workspaces, sound after the readings, the clock after sound; none beside the user's own divider")
    func hairlines() {
        #expect(InstrumentBar.hairlines(before: [.pilot, .workspaces, .focusedApp].map(Self.slot)) == [2])
        let readings = BarSlot.group([.cpu, .memory].map { BarSettings.defaults.entry($0) })
        #expect(InstrumentBar.hairlines(before: [readings] + [.volume, .wifi, .keyboardLayout, .clock].map(Self.slot)) == [1, 4])
        #expect(InstrumentBar.hairlines(before: [.cpu, .memory, .heat].map(Self.slot)).isEmpty)
        #expect(InstrumentBar.hairlines(before: [.cpu, .divider, .volume].map(Self.slot)).isEmpty, "Sven's divider is the only line there")
        #expect(InstrumentBar.hairlines(before: [.timer, .clock].map(Self.slot)).isEmpty)
    }

    static func items(_ names: [String]) -> [TopBarWorkspaces.Item] { TopBarWorkspaces.items(occupied: names, focused: "2", visibleHere: "2") }
    static let shown = try! AeroMonitorWorkspace.parse("""
    [{"monitor-id": 1, "monitor-name": "Studio", "workspace": "2"}, {"monitor-id": 2, "monitor-name": "Portrait", "workspace": "4"}]
    """)
    static func windows(_ workspace: String, monitor: Int) -> [AeroWindow] {
        try! AeroWindow.parse("""
        [{"window-id": 9, "app-name": "Zen", "app-bundle-id": "app.zen-browser.zen", "app-pid": 9, "workspace": "\(workspace)", "monitor-id": \(monitor),
          "window-layout": "h_tiles", "window-title": "GitHub"}]
        """)
    }

    @Test("The workspaces another display holds go after this screen's, split off where they start; one display, or none read, splits nothing")
    func displays() {
        let names = { (r: (items: [TopBarWorkspaces.Item], elsewhere: Int?)) in r.items.map(\.name) }
        // 4 shows on the portrait display, as the mockup's.
        let portrait = InstrumentBar.displays(Self.items(["1", "2", "3", "4"]), here: 1, shown: Self.shown, monitors: [:])
        #expect(names(portrait) == ["1", "2", "3", "4"] && portrait.elsewhere == 3)
        // 1's windows are on the portrait display though it is hidden there: it moves after this screen's.
        let moved = InstrumentBar.displays(Self.items(["1", "2", "3", "4"]), here: 1, shown: Self.shown, monitors: TilerService.monitors(Self.windows("1", monitor: 2)))
        #expect(names(moved) == ["2", "3", "1", "4"] && moved.elsewhere == 2)
        #expect(InstrumentBar.displays(Self.items(["1", "2", "3"]), here: 1, shown: Self.shown, monitors: [:]).elsewhere == nil)
        #expect(InstrumentBar.displays(Self.items(["1", "2", "4"]), here: nil, shown: Self.shown, monitors: [:]).elsewhere == nil)
    }

    @Test("The focus pill says the timer's title and is lit only while a timer counts")
    func focus() {
        let timer = ExtensionTimer(now: Date.init)
        defer { timer.stop() }
        #expect(InstrumentBarFocus(timer) == InstrumentBarFocus(word: nil, lit: false))
        timer.startFocus()
        #expect(InstrumentBarFocus(timer) == InstrumentBarFocus(word: "Focus", lit: true))
        timer.startFocus(paused: true)
        #expect(InstrumentBarFocus(timer) == InstrumentBarFocus(word: "Paused", lit: false))
        timer.start(Extension.TimerSpec(title: "Break", seconds: 300), owner: ExtensionTimerTests.owner)
        #expect(InstrumentBarFocus(timer) == InstrumentBarFocus(word: "Break", lit: true))
    }
}
#endif
