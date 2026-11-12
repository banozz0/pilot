#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The pill-first bar (PillFirst, Q160 to Q165, branch pill-first) in Instrument on Tokyo Night (dark) and Porcelain
/// (light): the saved bar above the pill-first bar drawn over it, collapsed on each page's face and on the live face (a
/// timer, a recording); then the drop open on each standard page, Calendar before access, and the live Activity tab. The
/// bar is the real strip from an isolated bar store switched by `choosePreset("pillFirst")`; the pill's faces are fed
/// plain values. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter PillFirstRenders`
extension SharedLook {
@MainActor
@Suite("Pill-first bar renders")
struct PillFirstRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let width: CGFloat = 1280

    @Test("The pill-first bar collapsed and each page open, in Tokyo Night and Porcelain",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.pill-first-render")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(true, forKey: BarItemsStore.extensionsApartKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        let saved = store.settings
        let today = store.settings.preview(.topBar).top ?? [:]
        try store.choosePreset(BarItemsStore.pillFirstPreset)
        // The preset is drawn over the saved bar: nothing of it changed.
        try #require(store.pillFirst.on && store.settings == saved && store.presetID == BarItemsStore.pillFirstPreset)
        let sides = PillFirst.sides(store.settings)

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        look.glass = false
        look.style = .instrument
        defer { (look.style, look.themeID, look.glass) = was }
        let walls = DesktopControlsRenders.walls()
        var input = BarInputs()
        input.pilotTitle = "1"; input.workspaces = ["1", "2", "3", "4"]; input.focusedWorkspace = "1"
        input.focusedApp = "Ghostty"; input.volume = 0.62; input.muted = false; input.wifiOn = true; input.keyboardLayout = "ABC"
        input.now = ClockRenders.now; input.timeZone = TimeZone(secondsFromGMT: 0)!; input.locale = Locale(identifier: "en_US_POSIX")

        for (mode, theme) in [("dark", "tokyo-night"), ("light", "porcelain")] {
            look.themeID = theme
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let dir = try ClockRenders.dir("pill-first-\(mode)")
            let backdrop = walls[tokens.dark ? 0 : min(5, walls.count - 1)]
            let base = Self.values(walls)
            func strip(_ sides: [TopBarSide: [BarSlot]], pill: PillValues, open: Bool = false) -> some View {
                TopBarStrip(sides: sides) { slot in
                    if slot.kind == .pill {
                        PillCompactFace(values: pill, open: open)
                    } else if let parts = BarParts.parts(slot, input, settings: store.settings) {
                        BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 6)
                    }
                }
                .styled(.topBar, look: look)
                .frame(width: Self.width, height: DesktopControlsRenders.strip).clipped()
            }
            func shot(_ view: some View, _ name: String) throws {
                try writeRender(view.style(tokens).font(.system(size: 13)).foregroundStyle(Color(tokens.colors.text)), to: dir.appendingPathComponent("\(name).png"), wait: 0.4)
            }

            // Collapsed: the saved bar, then the pill-first bar on each page's face and on the live face.
            var faces: [(String, PillValues)] = []
            for (i, tab) in base.tabs.enumerated() {
                var values = base
                values.tab = i
                values.page = tab.page
                faces.append(("Pill first · \(tab.title)", values))
            }
            var timer = base
            timer.live = base.running[1]
            faces.append(("Pill first · live timer (Q164)", timer))
            var recording = base
            recording.live = base.running[0]
            faces.append(("Pill first · live recording (Q164)", recording))
            try shot(VStack(alignment: .leading, spacing: 10) {
                Text("Saved bar (unchanged)").font(.caption)
                TopBarStrip(sides: today) { slot in
                    if let parts = BarParts.parts(slot, input, settings: store.settings) {
                        BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 6)
                    }
                }
                .styled(.topBar, look: look).frame(width: Self.width, height: DesktopControlsRenders.strip).clipped()
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    Text(face.0).font(.caption)
                    strip(sides, pill: face.1)
                }
            }
            .padding(14).background { DesktopControlsRenders.Wallpaper(image: backdrop) }, "bar-collapsed")

            // Open on each page; Calendar before access; the live Activity tab.
            func open(_ values: PillValues, _ name: String) throws {
                try shot(VStack(spacing: 0) {
                    strip(sides, pill: values, open: true)
                    PillDropFace(values: values).padding(.bottom, 36)
                }
                .frame(width: Self.width)
                .background(alignment: .top) { DesktopControlsRenders.Wallpaper(image: backdrop) }, name)
            }
            for (i, tab) in base.tabs.enumerated() {
                var values = base
                values.tab = i
                values.page = tab.page
                try open(values, "page-\(i + 1)-\(tab.title.lowercased())")
            }
            var asking = base
            asking.tab = 1; asking.page = .calendar
            asking.calendar?.access = .asking
            asking.highlight = 0
            try open(asking, "page-2-calendar-asking")
            var live = timer
            live.tabs.append(.init(.activity))
            live.tab = live.tabs.count - 1
            live.page = .activity
            try open(live, "page-live-activity")
        }
    }

    /// The pill-first bar's standard pages, the Extensions page named Dev with three extensions (Q163).
    static func values(_ walls: [NSImage]) -> PillValues {
        var values = DesktopControlsRenders.pill(walls)
        let pages = PillFirst.Page.standard.map { $0.kind == .extensions ? PillFirst.Page(.extensions, title: "Dev", extensions: ["github", "ci", "ports"]) : $0 }
        values.tabs = pages.map { PillValues.Tab(.init($0.kind), title: $0.title) }
        values.tab = 0
        values.page = .music
        values.extensions = [
            .init(symbol: "arrow.triangle.branch", name: "GitHub", value: "3", detail: "Pull requests wait on you"),
            .init(symbol: "checkmark.seal", name: "CI", value: "Green", detail: "main · 4 min ago"),
            .init(symbol: "network", name: "Ports", value: "2", detail: "3000 · 8080"),
        ]
        values.calendar = .init(access: .granted, weekday: "Thursday", day: "12", month: "November 2026", short: "Thu 12 Nov", events: [
            .init(time: "14:00 – 15:00", title: "Design review", colour: Color(Paint(0x4C8DF6)), now: true),
            .init(time: "16:30 – 17:00", title: "Call with the accountant", colour: Color(Paint(0x3FB27F))),
            .init(time: "All day", title: "Release day", colour: Color(Paint(0xE5684C)), day: "Tomorrow"),
            .init(time: "09:30 – 09:45", title: "Standup", colour: Color(Paint(0x4C8DF6)), day: "Tomorrow"),
        ])
        values.stats = [
            .init(symbol: "cpu", title: "CPU", number: "7", unit: "%", detail: "In use", share: 0.07),
            .init(symbol: "memorychip", title: "Memory", number: "14.2", unit: "GB", detail: "of 24 GB", share: 14.2 / 24),
            .init(symbol: "internaldrive", title: "Disk", number: "412", unit: "GB", detail: "free of 994 GB", share: 1 - 412.0 / 994),
            .init(symbol: "thermometer.medium", title: "Temperature", number: "48", unit: "°C", detail: "Hottest sensor"),
        ]
        values.running = [
            .init(symbol: "video", title: "Screen recording", detail: "Recording", reading: "0:41"),
            .init(symbol: "timer", title: "Focus", detail: "Write the release notes", reading: "18:42", canPause: true),
        ]
        return values
    }
}
}
#endif
