#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Instrument's top bar (card agent-bo-95423181) beside mockup A's (pilot-redesign-A/topbar-dark.png, topbar-light.png
/// and the 4x crops): the strip at the mockup's 1600 by 32 and at Sven's 1440 by 30, dark and light; a break and the
/// workspaces' icons style; the tooltip. Seeded with
/// fakes in a moved home: workspaces 1 to 3 on this display and 4 on another, Finder in front with its window's title,
/// Stats' readings, a focus timer at 18:42, Wi-Fi (nothing reaches the tiler, the timer or Wi-Fi):
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-ib PILOT_RENDER_DIR=/tmp/pilot-renders-ib swift test --filter InstrumentTopBarRenders`
extension SharedLook {
@MainActor
@Suite("Instrument top bar renders")
struct InstrumentTopBarRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let screen = "Studio"

    /// The mockup's bar: Pilot's mark, the workspaces and the app in front on the left, the timer in the centre, the
    /// readings' group, sound, Wi-Fi, the layout and the clock on the right.
    static func sides(workspaces: BarStyle = .numbers) -> [TopBarSide: [BarSlot]] {
        var s = BarSettings.defaults
        func item(_ kind: BarKind, _ style: BarStyle) -> BarSlot {
            s.set(kind, style: style)
            return .item(s.entry(kind))
        }
        let readings = [BarKind.cpu, .memory, .network].map { kind in s.set(kind, style: .text); return s.entry(kind) }
        return [.left: [item(.pilot, .icon), item(.workspaces, workspaces), item(.focusedApp, .iconName)],
                .centre: [item(.timer, .countdown), item(.terminal, .iconName), item(.askAI, .iconName)],
                .right: [.group(readings), item(.volume, .iconPercent), item(.wifi, .icon), item(.keyboardLayout, .code), item(.clock, .dateTime)]]
    }

    /// Workspaces 1 to 3 on the studio display (monitor 1), 4 on the portrait one (monitor 2).
    static let windows = HomeRenders.windows.replacingOccurrences(of: "\"workspace\": \"4\", \"monitor-id\": 1", with: "\"workspace\": \"4\", \"monitor-id\": 2")
    static let monitors = """
    [{"monitor-id": 1, "monitor-name": "Studio", "workspace": "2"}, {"monitor-id": 2, "monitor-name": "Portrait", "workspace": "4"}]
    """

    struct Bar: View {
        let sides: [TopBarSide: [BarSlot]]
        let sources: BarSources
        let look: Look
        /// The bar drops' items unlit, or lit as their drops hang open (spec Bar drops T4).
        var lights = BarDropLights()
        /// A dictation take in the bar, at its position.
        var take: DictationOverlay? = nil
        /// What the bar adds at its right end, as a recording's control (TopBarView's `trailing`).
        var trailing: AnyView? = nil

        var body: some View {
            TopBarStrip(sides: sides, trailing: trailing, live: take.map { AnyView(DictationBarItem(overlay: $0)) }, liveSide: take?.setup.barSide ?? .left) { TopBarSlot(slot: $0, screen: InstrumentTopBarRenders.screen, sources: sources, store: .shared, lights: lights) }
                .styled(.topBar, look: look).pilotTheme(look: look)
        }
    }

    @Test("The strip, its tooltip and edit mode in Instrument dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("topbar-instrument")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        let look = Look.shared
        let (style, glass) = (look.style, look.glass)
        look.glass = false
        defer { (look.style, look.glass) = (style, glass) }

        StatsRenders.seed(SystemSampler.shared)
        let clock = HomeRenders.Clock(), start = clock.now
        let timer = ExtensionTimer(now: { clock.now })
        timer.startFocus()
        clock.now = start.addingTimeInterval(25 * 60 - (18 * 60 + 42))
        timer.tick()
        defer { timer.stop() }
        let observers = EngineObservers()
        let windows = try AeroWindow.parse(Self.windows)
        observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: try AeroMonitorWorkspace.parse(Self.monitors))
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            observers.seed(focusedApp: finder, windowTitle: "Downloads")
        }
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { nil }, readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                                   watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        let sources = BarSources(readings: readings, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: timer, pilotTitle: { "2" })
        let sides = Self.sides()
        var held: Set<BarKind> = []
        readings.hold(Set(sides.values.joined().flatMap(\.kinds)), replacing: &held)
        defer { readings.hold([], replacing: &held) }

        let variants = [("dark", true), ("light", false)]
        for (name, isDark) in variants {
            look.style = .instrument
            try writeRender(Bar(sides: sides, sources: sources, look: look).frame(width: 1600, height: 32), to: dir.appendingPathComponent("bar-\(name)-1600.png"), wait: 0.8)
            try writeRender(Bar(sides: sides, sources: sources, look: look).frame(width: 1440, height: 30), to: dir.appendingPathComponent("bar-\(name)-1440.png"), wait: 0.8)
            // The terminal's drop open: its item lit, Ask AI's not.
            try writeRender(Bar(sides: sides, sources: sources, look: look, lights: BarDropLights(open: [.terminal])).frame(width: 1440, height: 30),
                            to: dir.appendingPathComponent("bar-\(name)-1440-terminal-lit.png"), wait: 0.8)
            try writeRender(BarTooltipView(text: "Workspace 2: Telegram, Zen").styled(.topBar, look: look).pilotTheme(look: look).padding(24)
                .background(Color(StyleTokens.of(.instrument, theme: look.theme).colors.canvas)),
                            to: dir.appendingPathComponent("tooltip-\(name).png"), wait: 0.5)
        }
        // Dictation's take at each position in the top bar, the words at the centre; at 1100 the words fold away.
        look.style = .instrument
        for side in TopBarSide.allCases {
            try writeRender(Bar(sides: sides, sources: sources, look: look, take: DictationOverlayRenders.barTake(side)).frame(width: 1440, height: 30),
                            to: dir.appendingPathComponent("bar-dark-1440-dictation-\(side.rawValue).png"), wait: 0.8)
        }
        let words = DictationOverlayRenders.barTake(.centre, words: DictationOverlayTests.long)
        try writeRender(Bar(sides: sides, sources: sources, look: look, take: words).frame(width: 1440, height: 30),
                        to: dir.appendingPathComponent("bar-dark-1440-dictation-centre-words.png"), wait: 0.8)
        try writeRender(Bar(sides: sides, sources: sources, look: look, take: words).frame(width: 1100, height: 30),
                        to: dir.appendingPathComponent("bar-dark-1100-dictation-centre-words.png"), wait: 0.8)
        // A paused timer, and the workspaces' icons style.
        timer.startFocus(paused: true)
        look.style = .instrument
        try writeRender(Bar(sides: Self.sides(workspaces: .icons), sources: sources, look: look).frame(width: 1600, height: 32),
                        to: dir.appendingPathComponent("bar-dark-1600-paused-icons.png"), wait: 0.8)
        timer.startFocus()

    }
}
}
#endif
