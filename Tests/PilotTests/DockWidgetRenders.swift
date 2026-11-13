#if DEBUG
import AppKit
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Dock widgets as built (design round 3, Sven 2026-11-13: Q214 B, Q215 the eleven): all eleven on, in a dock of 16 apps
/// over a wallpaper on Dracula, on the ultrawide (they fit) and on the laptop (the icons shrink, then the widgets scroll).
/// Every face goes through the dock's own mapping: the extensions' bar lines as they print them, read by Pilot's parser,
/// then DockFaces; the timer, CPU and memory, Bluetooth batteries and Calendar events through the same builders the dock
/// calls. Glass is DockRenders' stand-in. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_DOCK_WALL=<png> swift test --filter DockWidgetRenders`
@MainActor
@Suite("Dock widget renders")
struct DockWidgetRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    typealias R = DockRenders

    /// A bar line as an extension prints it, through the parser Pilot reads it with.
    static func answer(_ line: String) -> Extension.BarAnswer {
        guard case .bar(let answer) = ExtensionRun.surfaceAnswer(line, kind: .bar) else { fatalError("unreadable bar line: \(line)") }
        return answer
    }

    /// A stand-in album cover, as now playing's thumbnail arrives: a small JPEG in base64.
    static func cover() -> String {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.95, green: 0.60, blue: 0.29, alpha: 1), NSColor(srgbRed: 0.61, green: 0.32, blue: 0.88, alpha: 1)])?
                .draw(in: rect, angle: -45)
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.base64EncodedString()
    }

    /// Friday 13 November 2026, 14:35, and the day's events.
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Malta")!; return c }()
    static func at(_ hour: Int, _ minute: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: hour, minute: minute))! }
    static let now = at(14, 35)
    static let events = [
        ClockEvent(title: "Standup", start: at(10, 0), end: at(10, 30), colour: Paint(0x4F8CF7)),
        ClockEvent(title: "Design review", start: at(15, 0), end: at(16, 0), colour: Paint(0xE5A23B)),
        ClockEvent(title: "Gym", start: at(18, 0), end: at(19, 0), colour: Paint(0x45B36B)),
        ClockEvent(title: "Malta holiday", start: at(0, 0), end: at(23, 59), allDay: true, holiday: true),
    ]

    /// An installed extension's top bar answer as a widget (round 4): Tailscale's, its icon beside its title over its text.
    static func tailscale() -> DockWidgetBody {
        .faces(DockFaces.extensionItem(answer(#"{"type":"bar","text":"🛜 2 online"}"#), title: "Tailscale", icon: "🛜"))
    }

    /// All eleven, in DockWidget's order, as the dock draws them.
    static func bodies() -> [(DockWidget, DockWidgetBody)] {
        let ai = answer(#"{"type":"bar","text":"","tone":"warn","gauges":[{"icon":"claude","text":"72%","tone":"fine"},{"icon":"openai","text":"64%","tone":"warn"}]}"#)
        let music = answer(#"{"type":"bar","text":"♫ Caribou – Can't Do Without You","blocks":[{"type":"section","aside":"Music","blocks":[{"type":"list","items":[{"id":"t","title":"Can't Do Without You","subtitle":"Caribou","icon":"🎵","image":"\#(cover())"}]}]}]}"#)
        // Markets 1.5's line: its faces, from its own settings (price and change shown, two symbols).
        let markets = answer(#"{"type":"bar","text":"SPY ▲0.4% · BTC ▼1.2%","faces":[{"label":"SPY","value":"$512 ▲0.4%","tone":"fine","symbol":"chart.line.uptrend.xyaxis"},{"label":"BTC","value":"€97.1k ▼1.2%","tone":"alert","symbol":"chart.line.downtrend.xyaxis"}]}"#)
        let values = SystemStats.Values(cpu: 0.23, ram: 0.61, gpu: nil, down: 1_240_000, up: 42_000, cores: nil, diskRead: nil, diskWrite: nil)
        let devices = [SystemStats.BluetoothDevice(name: "Magic Mouse", level: "64 %"),
                       SystemStats.BluetoothDevice(name: "AirPods Pro", level: "L 90 % · R 85 % · case 40 %", fromProfiler: true)]
        return [
            (.aiUsage, .faces(DockFaces.aiUsage(ai))),
            (.nextEvent, .faces([DockFaces.nextEvent(events, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))])),
            (.nowPlaying, .faces([DockFaces.nowPlaying(music)!])),
            (.focus, .faces([DockFaces.focus(countdown: "18:42", left: 0.62, title: "Focus 2 of 4", paused: false)])),
            (.system, .faces(DockFaces.system([.cpu, .ram, .network], values: values, raw: nil))),
            (.weather, .faces([DockFaces.weather(answer(#"{"type":"bar","text":"☀️ 24°"}"#))])),
            (.todo, .faces([DockFaces.todo(answer(#"{"type":"bar","text":"☑️ 5 · 2"}"#))])),
            (.github, .faces([DockFaces.github(answer(#"{"type":"bar","text":"2 to review","tone":"warn"}"#))])),
            // Its faces, drawn as any answer's faces are (DockWidgetSources.answered).
            (.markets, .faces(DockFaces.extensionItem(markets, title: "Markets", icon: "📈"))),
            (.timeline, .timeline(DockFaces.timeline(events, now: now, calendar: calendar))),
            // A Mac mini: no battery, the power it draws (Sven on build 2467).
            (.battery, .faces(DockFaces.battery(nil, watts: 14, bluetooth: devices)!)),
        ]
    }

    @Test("All eleven widgets on the ultrawide and the laptop", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("dock-widgets")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let wall = Self.env["PILOT_DOCK_WALL"].flatMap(NSImage.init(contentsOfFile:))
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }
        (look.style, look.themeID, look.glass, look.transparency) = (.instrument, "dracula", true, 100)
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let tint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
        let bodies = Self.bodies()
        for (name, screen) in [("all-ultrawide", R.ultrawide), ("all-laptop", R.laptop)] {
            let desk = R.Desk(wall: wall, screen: screen, size: CGSize(width: screen.width, height: 150))
            let strip = DockStrip(size: .medium, apps: R.apps(16), hasWidgets: true, maxWidth: screen.width - 2 * DockPill.sideMargin,
                                  backing: { AnyView($0.modifier(R.GlassStandIn(desk: desk, tint: tint))) }) {
                ForEach(Array(bodies.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
            }
            try writeRender(desk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look),
                            to: dir.appendingPathComponent("\(name).png"), wait: 1.5)
        }
    }
}
}
#endif
