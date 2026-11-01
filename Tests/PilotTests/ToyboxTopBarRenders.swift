#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Toybox's top bar (card agent-bo-95423182) beside mockup B's (pilot-redesign-B/topbar-dark.png, topbar-light.png and
/// the 2x crops): the bar at 1440 by Sven's 30 pt strip in Toybox dark, Toybox light and Instrument, and at a notched
/// MacBook's 37; then its popovers, tooltip and the drag chip in the same three. Seeded with fakes
/// in a moved home: the mockup's workspaces, Stats' readings, a focus block at 18:42, Wi-Fi, an 82 % battery (nothing
/// reaches the tiler, the timer, Wi-Fi or the battery):
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-toy PILOT_RENDER_DIR=/tmp/pilot-renders-toy swift test --filter ToyboxTopBarRenders`
extension SharedLook {
@MainActor
@Suite("Toybox top bar renders")
struct ToyboxTopBarRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The mockup's bar: Pilot, the workspaces and the app in front on the left, the timer in the centre, the readings'
    /// group, sound, the layout, Wi-Fi, the battery and the clock on the right.
    static func sides() -> [TopBarSide: [BarSlot]] {
        var s = BarSettings.defaults
        func item(_ kind: BarKind, _ style: BarStyle) -> BarSlot {
            s.set(kind, style: style)
            return .item(s.entry(kind))
        }
        let readings = [BarKind.cpu, .memory, .network].map { kind in s.set(kind, style: .text); return s.entry(kind) }
        return [.left: [item(.pilot, .iconNumber), item(.workspaces, .numbers), item(.focusedApp, .iconName)],
                .centre: [item(.timer, .countdown), item(.terminal, .iconName), item(.askAI, .iconName)],
                .right: [.group(readings), item(.volume, .icon), item(.keyboardLayout, .code), item(.wifi, .icon), item(.battery, .iconPercent),
                         item(.clock, .dateTime)]]
    }

    /// The bar as TopBarView draws it, on `look`.
    struct Bar: View {
        let sides: [TopBarSide: [BarSlot]]
        let sources: BarSources
        let look: Look
        /// The bar drops' items unlit, or lit as their drops hang open (spec Bar drops T4).
        var lights = BarDropLights()
        /// A dictation take in the bar, at its position.
        var take: DictationOverlay? = nil

        var body: some View {
            TopBarStrip(sides: sides, live: take.map { AnyView(DictationBarItem(overlay: $0)) }, liveSide: take?.setup.barSide ?? .left) { TopBarSlot(slot: $0, screen: "Studio", sources: sources, store: .shared, lights: lights) }
                .styled(.topBar, look: look).pilotTheme(look: look)
        }
    }

    @Test("The top bar, its popovers, tooltip and drag chip in Toybox dark and light and in Instrument",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("topbar")
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
        let windows = try AeroWindow.parse(HomeRenders.windows)
        observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first { observers.seed(focusedApp: finder) }
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { SystemStats.Battery(percent: 82, charging: false, minutesLeft: 300) },
                                   readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                                   watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        let sources = BarSources(readings: readings, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: timer, pilotTitle: { "2" })
        let sides = Self.sides()
        var held: Set<BarKind> = []
        readings.hold(Set(sides.values.joined().flatMap(\.kinds)), replacing: &held)
        defer { readings.hold([], replacing: &held) }

        let variants = [("toybox-dark", PilotStyle.toybox, true), ("toybox-light", .toybox, false), ("instrument", .instrument, true)]
        for (name, pick, isDark) in variants {
            look.style = pick
            try writeRender(Bar(sides: sides, sources: sources, look: look).frame(width: 1440, height: 30), to: dir.appendingPathComponent("bar-\(name).png"), wait: 0.8)
            // Both drops open: both items lit.
            try writeRender(Bar(sides: sides, sources: sources, look: look, lights: BarDropLights(open: [.terminal, .askAI])).frame(width: 1440, height: 30),
                            to: dir.appendingPathComponent("bar-\(name)-drops-lit.png"), wait: 0.8)
        }
        look.style = .toybox
        try writeRender(Bar(sides: sides, sources: sources, look: look).frame(width: 1440, height: 37), to: dir.appendingPathComponent("bar-toybox-dark-37.png"), wait: 0.8)
        // Dictation's take at each position, a custom colour.
        for side in TopBarSide.allCases {
            try writeRender(Bar(sides: sides, sources: sources, look: look, take: DictationOverlayRenders.barTake(side, colour: .custom(0xFF5FA2)))
                .frame(width: 1440, height: 30), to: dir.appendingPathComponent("bar-toybox-dark-dictation-\(side.rawValue).png"), wait: 0.8)
        }

        // Each popover, the tooltip and the drag's chip, on the canvas.
        let store = BarItemsStore.shared
        let popovers: [(String, AnyView)] = [
            ("workspaces", AnyView(BarPopover(kinds: [.workspaces], sources: sources, store: store))),
            ("focused-app", AnyView(BarPopover(kinds: [.focusedApp], sources: sources, store: store))),
            ("sound", AnyView(BarPopover(kinds: [.volume], sources: sources, store: store))),
            ("wifi", AnyView(BarPopover(kinds: [.wifi], sources: sources, store: store))),
            ("clock", AnyView(BarPopover(kinds: [.clock], sources: sources, store: store))),
            ("timer", AnyView(BarPopover(kinds: [.timer], sources: sources, store: store))),
            ("readings", AnyView(BarPopover(kinds: [.cpu, .memory], sources: sources, store: store))),
            ("tooltip", AnyView(BarTooltipView(text: "Workspace 2: Telegram, Zen"))),
            ("chip", AnyView(BarDragChip(kind: .battery, slot: sides[.right]?[4], screen: "Studio", sources: sources, store: store))),
        ]
        for (name, view) in popovers {
            for (variant, pick, isDark) in variants {
                look.style = pick
                let tokens = StyleTokens.of(pick, theme: look.theme)
                // The tooltip and chip are the strip's surface; the rest the bar's popovers'.
                let surface: StyleSurface = ["tooltip", "chip"].contains(name) ? .topBar : .barPopovers
                try writeRender(view.styled(surface, look: look).pilotTheme(look: look).padding(24).background(Color(tokens.colors.canvas)),
                                to: dir.appendingPathComponent("\(name)-\(variant).png"), wait: 0.5)
            }
        }
    }
}
}
#endif
