#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of design round 4's foundation (card agent-bo-95422890), for Moody beside the approved artifact
/// 5sh21HWjCjsWYAwWKTibcE: a sheet of the twelve themes (each card in its own colours and display face, its roles and
/// graphs under it), and the app window in Lagoon and in Workshop. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ThemeRenders`
extension SharedLook {
@MainActor
@Suite("Theme renders")
struct ThemeRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The twelve themes and the window in two of them render", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderThemes() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        try render(ThemeSheet().frame(width: 1240), to: dir.appendingPathComponent("01-twelve-themes.png"))
        // The kit's gallery, section 5 of the artifact, in three themes (card agent-bo-95422891).
        for id in ["lagoon", "workshop", "void"] {
            Look.shared.themeID = id
            try render(KitGallery().pilotTheme(), to: dir.appendingPathComponent("kit-\(id).png"))
        }

        let engine = Engine()
        engine.observers.tiler.seed(focused: "2", occupied: [
            OccupiedWorkspace(name: "1", apps: ["Ghostty", "Ghostex"]), OccupiedWorkspace(name: "2", apps: ["Zen"]),
            OccupiedWorkspace(name: "3", apps: ["Obsidian"]), OccupiedWorkspace(name: "4", apps: ["Telegram", "Spotify"]),
        ])
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.themes")!)
        // Home (direction B, card agent-bo-95422992; HomeRenders draws its states), on seeded readings.
        engine.seedPresses([(Key("return"), "Open terminal"), (Key("2"), "Go to workspace 2"), (Key("return"), "Open terminal"),
                            (Key("space"), "Pilot menu"), (Key("v"), "Clipboard history"), (Key("l"), "Focus right")])
        let cpu: [Double] = [12, 18, 14, 22, 30, 26, 19, 23, 35, 28, 21, 17, 24, 31, 27, 22, 19, 25, 33, 29, 23, 20, 26, 23]
        let history = cpu.enumerated().map { i, c in
            SystemStats.Values(cpu: c / 100, ram: 0.58 + Double(i % 4) / 100, gpu: Double(4 + i % 7) / 100, down: Double(400_000 + (i * 397_000) % 2_800_000),
                               up: 140_000, cores: nil, diskRead: nil, diskWrite: nil, heat: 48 + Double(i % 6))
        }
        var raw = SystemStats.Raw(time: 1, cpu: .init(user: 1, system: 0, idle: 1, nice: 0),
                                  memory: .init(total: 1 << 34, pageSize: 16384, active: 1, inactive: 1, speculative: 0, wired: 1, compressed: 0,
                                                purgeable: 0, external: 0, pressure: .normal, swapUsed: 0, swapTotal: 0),
                                  network: .init(received: 0, sent: 0), battery: nil, thermal: .nominal, uptime: 1, gpu: 0.08)
        raw.slow.disk = .init(available: 134_000_000_000, total: 494_000_000_000)
        let rows: [SystemStats.Row] = [
            .init(name: "This Mac", value: "Apple M4 · Mac mini · macOS 26.5", explanation: ""),
            .init(name: "CPU split", value: "user 14% · system 9% · idle 77%", explanation: ""),
            .init(name: "Load", value: "1.92 · 2.10 · 2.04", explanation: ""),
            .init(name: "RAM", value: "9.8 of 16 GB · pressure normal", explanation: ""),
            .init(name: "Graphics", value: "Apple M4 · 10 cores", explanation: ""),
            .init(name: "Disk", value: "134 GB free of 494 GB", explanation: ""),
            .init(name: "Network", value: "Ethernet · 192.168.1.20", explanation: ""),
            .init(name: "Heat", value: "nominal", explanation: ""),
        ]
        let busy = ["Ghostty": "12.4%", "Zen": "9.1%", "Ghostex": "6.0%"].sorted { $0.value > $1.value }
            .map { LiveRow(SystemStats.Row(name: $0.key, value: $0.value, explanation: "")) }
        SystemSampler.shared.seed(history: history, latest: raw, rows: rows, busiest: [.cpu: busy, .ram: busy, .network: busy])
        Look.shared.themeID = PilotTheme.defaultID
        let page = HomePage(onScreen: false) { _ in }.environment(engine)
            .frame(width: 1000, height: 1250).pilotTheme().background(Theme.background)
        try render(page, to: dir.appendingPathComponent("home.png"))
        // Binds as a keyboard (card agent-bo-95422894), Lagoon and Workshop (brackets).
        for id in ["lagoon", "workshop"] {
            Look.shared.themeID = id
            for plain in [false, true] where !(plain && id == "workshop") {
                let page = BindsKeyboardPage(search: "", startOnPlain: plain) { _ in }.environment(engine)
                    .frame(width: 1000, height: 720).pilotTheme().background(Theme.background)
                try render(page, to: dir.appendingPathComponent("binds-\(id)\(plain ? "-plain" : "").png"))
            }
        }
        Look.shared.themeID = PilotTheme.defaultID
        for (i, id) in ["lagoon", "workshop", "void"].enumerated() {
            Look.shared.themeID = id   // saved in the moved home only; Ghostty is never touched
            let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
            AppWindowController.applyLook(.shared, to: window)
            for page in [AppPage.home, .look] {
                model.page = page
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let frame = try #require(window.contentView?.superview)
                frame.layoutSubtreeIfNeeded()
                try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(String(format: "%02d", i + 2))-\(id)-\(page.rawValue).png"))
            }
            window.close()
        }
        Look.shared.themeID = PilotTheme.defaultID
    }

    private func render(_ view: some View, to url: URL) throws { try writeRender(view, to: url) }
}

}

/// The twelve themes as the artifact's section 1 shows them: Sven's theme card (three dots, the name in the theme's own
/// face, its line, a deeply tinted ground with a thin tinted edge), then every role as a swatch and the three graph
/// colours, on the theme's own ground.
private struct ThemeSheet: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            ForEach(PilotTheme.designed) { ThemeTile(theme: $0) }
        }
        .padding(18)
        .background(Color(hex: 0x0B0C0F))
    }
}

private struct ThemeTile: View {
    let theme: PilotTheme

    var body: some View {
        let t = theme, c = ThemeColors(theme)
        let edge = Contrast.hex(Contrast.mix(Contrast.rgb(t.accent), Contrast.rgb(t.dark ? t.sidebar : t.surface), t.dark ? 0.22 : 0.3))
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: -9) {
                    ForEach([t.accent, t.second, t.third], id: \.self) { colour in
                        Circle().fill(Color(hex: colour)).frame(width: 28, height: 28)
                            .overlay { Circle().strokeBorder(Color(hex: t.dark ? t.sidebar : t.surface), lineWidth: 2) }
                    }
                }
                Text(t.name).display(24, face: t.face).foregroundStyle(c.text).lineLimit(1).padding(.top, 16)
                Text(t.tagline).font(.system(size: 14)).foregroundStyle(c.text2).padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: t.dark ? t.sidebar : t.surface), in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color(hex: edge)) }
            let roles: [(String, Color)] = [("g", c.ground), ("g2", c.sidebar), ("s", c.surface), ("s2", c.raised), ("l2", c.line2),
                                            ("t", c.text), ("t2", c.text2), ("a", c.accent), ("a2", c.second), ("a3", c.third),
                                            ("ok", c.good), ("wn", c.amber), ("bd", c.problem)]
            HStack(spacing: 3) {
                ForEach(roles, id: \.0) { role in
                    RoundedRectangle(cornerRadius: 4).fill(role.1).frame(height: 18)
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.12)) }
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(c.graphs.enumerated()), id: \.offset) { i, colour in
                    Capsule().fill(colour).frame(height: 3)
                }
            }
            Text("\(t.face.family) · focus \(t.focus.rawValue) · radius \(t.radius, format: .number) · from \(t.source)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(c.text3).lineLimit(2)
        }
        .padding(12)
        .background(c.ground, in: .rect(cornerRadius: 14))
    }
}
#endif
