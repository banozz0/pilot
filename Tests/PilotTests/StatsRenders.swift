#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Stats as the approved mockup ErxOpOTBN8U (card agent-bo-95422992): the strip under the chips redraws as a chip is
/// clicked, every run; and, opt-in like the other renders, the whole window at 1440, 1000 and 760 in
/// Tokyo Night on the mockup's Mac mini (seeded readings, the menu bar showing CPU, Memory, Storage and Temperature), the
/// CPU chart's hover, 1 hour and Today, Graph and One item, and the chooser before and after Network's chip is clicked:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter StatsRenders`
extension SharedLook {
@MainActor
@Suite("Stats renders")
struct StatsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The mockup's readings: a Mac mini M4 at 09:41, 9 % CPU, 56 % memory, 97 % of 245 GB used, 52 °C, a fan at 1,020 rpm.
    /// `battery`: a MacBook's, at 64 % on battery with 91 % health, for the Overview's seventh card.
    static func seed(_ sampler: SystemSampler, count: Int = 60, battery: Bool = false) {
        var x = 7.0
        func rnd() -> Double { x = (x * 9301 + 49297).truncatingRemainder(dividingBy: 233_280); return x / 233_280 }
        func walk(_ base: Double, _ amp: Double, spikes: Double = 0) -> [Double] {
            var v = base
            return (0..<count).map { _ in
                v = min(base + amp * 1.6, max(base - amp * 1.6, v + (rnd() - 0.5) * amp))
                return max(0, v + (spikes > 0 && rnd() > 0.93 ? amp * spikes * rnd() : 0))
            }
        }
        let cpu = walk(0.11, 0.05, spikes: 3), ram = walk(0.56, 0.006), gpu = walk(0.08, 0.035, spikes: 2.5)
        let read = walk(1_400_000, 1_100_000, spikes: 4), write = walk(400_000, 350_000, spikes: 3)
        let down = walk(800_000, 650_000, spikes: 4), up = walk(50_000, 40_000, spikes: 3), heat = walk(51, 2), fan = walk(1020, 22)
        // macOS lists the efficiency cores first.
        let cores = [4, 3, 5, 2, 3, 2, 22, 14, 9, 6].map { Double($0) / 100 }
        let history = (0..<count).map { i in
            SystemStats.Values(cpu: i == count - 1 ? 0.09 : cpu[i], ram: i == count - 1 ? 0.56 : ram[i], gpu: i == count - 1 ? 0.08 : gpu[i],
                               down: i == count - 1 ? 1_200_000 : down[i], up: i == count - 1 ? 40_000 : up[i], cores: cores,
                               diskRead: i == count - 1 ? 1_400_000 : read[i], diskWrite: i == count - 1 ? 340_000 : write[i],
                               split: [0.06, 0.03, 0.91], heat: i == count - 1 ? 52 : heat[i], fan: i == count - 1 ? 1020 : fan[i])
        }
        let page: UInt64 = 16384, gib: UInt64 = 1 << 30
        var raw = SystemStats.Raw(time: 1, cpu: .init(user: 1, system: 0, idle: 1, nice: 0),
                                  memory: .init(total: 16 * gib, pageSize: page, active: 61 * gib / 10 / page, inactive: 0, speculative: 0,
                                                wired: 19 * gib / 10 / page, compressed: gib / page, purgeable: 0, external: 0, pressure: .normal,
                                                swapUsed: 0, swapTotal: 0),
                                  network: .init(received: 3_400_000_000, sent: 410_000_000), battery: nil, thermal: .nominal,
                                  uptime: 3 * 86_400 + 4 * 3600 + 120, gpu: 0.08)
        raw.cores = Array(repeating: .zero, count: 10)
        raw.efficiencyCores = 6
        raw.load = [1.42, 1.60, 1.71]
        raw.gpuDetail = .init(renderer: 0.06, tiler: 0.03, model: "Apple M4", cores: 10)
        raw.slow.disk = .init(available: 7_400_000_000, total: 245_000_000_000)
        raw.slow.localIP = "192.168.1.23"
        raw.slow.wifi = .init(channel: 149, band: "5 GHz", signal: -52, noise: -92, rate: 866, standard: "802.11ac")
        raw.slow.machine = .init(chip: "Apple M4", model: "Mac16,10", macOS: "26.5")
        if battery {
            raw.battery = .init(percent: 64, charging: false, pluggedIn: false, minutesLeft: 252)
            raw.slow.batteryHealth = .init(cycles: 212, percent: 91)
        }
        raw.slow.bluetooth = [.init(name: "Magic Keyboard", level: "72 %"), .init(name: "Magic Trackpad", level: "45 %"),
                              .init(name: "AirPods Pro", level: "L 100 % · R 100 % · case 80 %")]
        raw.sensors = .init(temperatures: ["Tp01": 52, "Tp05": 55, "Te05": 49, "Tp09": 52, "Tg05": 47, "Tg0D": 47, "Ts0P": 41],
                            fans: [.init(actual: 1020, minimum: 1000, maximum: 4900)], power: 7.8)
        // The rows This Mac words from these readings (SystemStats.rows), as Home's full list shows them.
        let rows: [SystemStats.Row] = [("Load", "1.42 · 1.60 · 1.71"), ("RAM", "9.0 of 16 GB · pressure normal"), ("Disk", "7.4 GB free of 245 GB"),
                                       ("Graphics", "Apple M4 · 10 cores"), ("IP", "192.168.1.23")].map { .init(name: $0.0, value: $0.1, explanation: "") }
        let busy = { (list: [(String, String)]) in list.map { LiveRow(SystemStats.Row(name: $0.0, value: $0.1, explanation: "")) } }
        // The Overview's apps (helpers under their app) and what is worth a look, as a listing would leave them.
        let app = { (name: String, cpu: Double, mb: UInt64) in
            Activity.Row(kind: .app, pid: Int32(mb), name: name, cpu: cpu, memory: mb << 20, rights: .quitAndForce)
        }
        let apps = [app("Ghostex", 58.2, 1434), app("Zen", 7.4, 2150), app("WindowServer", 4.1, 604), app("Ghostty", 2.0, 388),
                    app("Pilot", 1.2, 96), app("Obsidian", 0.8, 812)]
        let minute = { (n: Double) in Date().addingTimeInterval(-n * 60) }
        let findings = [
            StatsOverview.Finding(id: "cpu.Ghostex", app: "Ghostex", title: "Ghostex is keeping the CPU busy",
                                  line: "61 % of a core on average for the last 8 minutes, across 318 processes.", value: "Now 58.2 %", tag: .cpu, since: minute(7)),
            StatsOverview.Finding(id: "grow.Zen", app: "Zen", title: "Zen is using more and more memory",
                                  line: "Up 640 MB in the last 9 minutes, now 2.1 GB.", value: "Now 2.1 GB", tag: .memory, since: minute(4)),
            StatsOverview.Finding(id: "mac.disk", app: nil, title: "The disk is nearly full",
                                  line: "7.4 GB free of 245 GB; a macOS update wants about 20 GB.", value: "7.4 GB free", tag: .disk, since: minute(12)),
        ]
        sampler.seed(history: history, latest: raw, rows: rows,
                     apps: (apps.sorted { $0.cpu > $1.cpu }, apps.sorted { $0.memory > $1.memory }, 612), findings: findings, busiest: [
            .cpu: busy([("Ghostex", "18.2 %"), ("Zen", "7.4 %"), ("WindowServer", "4.1 %"), ("Ghostty", "2.0 %"), ("Pilot", "1.2 %")]),
            .ram: busy([("Zen", "2.1 GB"), ("Ghostex", "1.4 GB"), ("Obsidian", "812 MB"), ("WindowServer", "604 MB"), ("Ghostty", "388 MB")]),
            .network: busy([("Zen", "↓ 1.1 MB/s ↑ 32 KB/s"), ("Ghostex", "↓ 64 KB/s ↑ 6 KB/s"), ("mDNSResponder", "↓ 2 KB/s ↑ 1 KB/s")]),
        ])
    }

    /// The mockup's menu bar: CPU, Memory, Storage and Temperature as text, each its own item.
    static func pickMockup(_ store: BarItemsStore) {
        store.settings.setReadingsLook(.text)
        for kind in BarSettings.readingKinds where store.settings.isOn(kind, in: .menuBar) != [.cpu, .memory, .storage, .heat].contains(kind) {
            store.settings.toggleReading(kind)
        }
    }

    /// The strip drawn on its own at 2x, as device RGB bytes; the same host each time, so a change is the view observing.
    static func pixels(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(host, scale: 2))
        return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
    }

    @Test("The menu bar strip draws one clock: macOS's only while Pilot's clock item is not in the bar, alone or in a group")
    func oneClock() {
        let s = BarSettings.defaults
        #expect(MenuBarPage.showsMacClock([.item(s.entry(.cpu)), .item(s.entry(.timer))]))
        #expect(MenuBarPage.showsMacClock([]))
        #expect(!MenuBarPage.showsMacClock([.item(s.entry(.cpu)), .item(s.entry(.clock))]))
        #expect(!MenuBarPage.showsMacClock([.group([s.entry(.cpu), s.entry(.clock)])]))
    }

    @Test("The strip's items, short of room, go whole from the left, never part of one")
    func stripDropsWholeItems() async throws {
        let widths: [CGFloat] = [30, 40, 50]
        #expect(TrailingRow.kept(widths, spacing: 12, room: .infinity) == 3)
        #expect(TrailingRow.kept(widths, spacing: 12, room: 144) == 3)
        #expect(TrailingRow.kept(widths, spacing: 12, room: 143) == 2)
        #expect(TrailingRow.kept(widths, spacing: 12, room: 102) == 2)
        #expect(TrailingRow.kept(widths, spacing: 12, room: 101) == 1)
        #expect(TrailingRow.kept(widths, spacing: 12, room: 49) == 0)
        #expect(TrailingRow.kept([], spacing: 12, room: 10) == 0)

        // Drawn as the strip draws its items (masked at the row, beside a spacer that takes what the row leaves): with
        // room for all but a point, the last two blocks against the right edge, whole, and nothing of the first.
        let colors: [Color] = [.red, .green, .blue]
        func block(_ i: Int) -> some View { colors[i].frame(width: widths[i], height: 10) }
        let strip = try await PilotTests.pixels(rendering: HStack(spacing: 0) {
            Spacer(minLength: 0).layoutPriority(-2)
            TrailingRow(spacing: 12) { ForEach(0..<3, id: \.self) { block($0) } }.mask { Rectangle().padding(.vertical, -15) }
        }.frame(width: 143).background(.black))
        let lastTwo = try await PilotTests.pixels(rendering: HStack(spacing: 12) { block(1); block(2) }
            .frame(width: 143, alignment: .trailing).background(.black))
        #expect(strip == lastTwo)
    }

    @Test("Stats renders as the mockup at 1440, 1000 and 760", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("stats")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        // Today's minutes, one a minute since midnight, in the moved home's stats-today.json, read as at launch.
        let file = DayFile<StatsHistory>("stats-today")
        try #require(file.url.path.hasPrefix(home), "the minute history would land outside the moved home")
        var minutes = StatsHistory()
        let now = Date(), midnight = Calendar.current.startOfDay(for: now)
        let count = Int(now.timeIntervalSince(midnight) / 60) + 1
        let day = SystemSampler()
        Self.seed(day, count: count)
        for (i, values) in day.history.enumerated() { minutes.record(values, at: midnight.addingTimeInterval(Double(i) * 60)) }
        minutes.record(day.history[0], at: now.addingTimeInterval(60))   // closes the last minute
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.save(minutes)
        SystemSampler.shared.loadMinutes()

        let engine = Engine()
        Self.seed(SystemSampler.shared)
        engine.observers.tiler.seed(focused: "1", occupied: [OccupiedWorkspace(name: "1", apps: ["Ghostex"]), OccupiedWorkspace(name: "2", apps: ["Zen"])])
        let store = BarItemsStore.shared
        Self.pickMockup(store)
        // PILOT_RENDER_ONLY narrows the renders to the file names holding it.
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.stats")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "tokyo-night"
        defer { Look.shared.themeID = PilotTheme.defaultID }
        for width in [1440, 1000, 760] where wanted("window-\(width)") {
            window.setContentSize(NSSize(width: CGFloat(width), height: width == 760 ? 3000 : 1900))
            model.go(AppPlace(.stats))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            try RestyledRenders.writeTrimmed(try #require(snapshot(frame, scale: 2)), from: 207,
                                             to: dir.appendingPathComponent("window-\(width).png"))
        }
        // The page alone at the window's page width: the CPU chart's hover, then 1 hour and Today.
        let pageWidth = CGFloat(1000 - 207)
        for (name, start) in [("hover", StatsPage.Start(hover: 0.72)), ("hour", StatsPage.Start(range: .hour, hover: 0.72)),
                              ("today", StatsPage.Start(range: .today))] where wanted("page-\(name)") {
            let page = StatsPage(onScreen: false, start: start).environment(engine)
                .frame(width: pageWidth, height: 1900).pilotTheme(look: .shared).background(Theme.background)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("page-\(name).png"))
        }
        // The Overview in each view in the narrowest window and a wide one: no card runs under the next.
        for view in StatsView.allCases {
            for width in [760, 1440] where wanted("overview-\(view.rawValue)-\(width)") {
                StatsViewsStore.shared.setAll(view)
                window.setContentSize(NSSize(width: CGFloat(width), height: 1000))
                model.go(AppPlace(.stats))
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("overview-\(view.rawValue)-\(width).png"))
            }
        }
        StatsViewsStore.shared.reset()
        // The Menu bar page, where the readings are chosen as bar items (card agent-bo-95423024; Q185).
        if wanted("menubar") {
            let page = MenuBarPage(onScreen: false).environment(engine)
                .frame(width: 793, height: 1900).pilotTheme(look: .shared).background(Theme.background)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("menubar.png"))
        }
    }
}
}
#endif
