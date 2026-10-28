#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The bar drops' chrome on a whole screen (spec Bar drops T8, the C frames, design cards 6, 10, 11): the terminal alone,
/// centred under the bar, and both side by side, Terminal left, in Instrument and Toybox, dark and light, on a 1080 pt
/// portrait and a 3440 pt ultrawide, each drop on its BarDropPlacement frame under the real top bar strip with its item
/// lit. Over a stand-in desktop with one window behind the drops, so the hairline's hold over a window shows. The
/// terminal is the drop's real chrome round a stand-in shell (Shell: a canned session in the drop's mono face; Ghostty's
/// view draws nothing offscreen); Ask AI is its real face with one turn. Look's Glass is off: glass draws nothing
/// offscreen (Sven's screenshot proves it). The motion is not drawn. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pdh PILOT_RENDER_DIR=/tmp/pdr swift test --filter BarDropRenders`
extension SharedLook {
@MainActor
@Suite("Bar drop renders")
struct BarDropRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let screens: [(name: String, size: CGSize)] = [("1080", CGSize(width: 1080, height: 1920)), ("3440", CGSize(width: 3440, height: 1440))]
    static let looks: [(name: String, style: PilotStyle, theme: String)] = [
        ("instrument-dark", .instrument, "lagoon"), ("instrument-light", .instrument, "porcelain"),
        ("toybox-dark", .toybox, "toybox-night"), ("toybox-light", .toybox, "toybox"),
    ]
    static let strip: CGFloat = 32

    /// The C frames' session, as runs of (words, colour): a prompt, a test run, Claude Code at work.
    enum Tint { case plain, path, dim, good, mark }
    static let session: [[(String, Tint)]] = {
        let prompt: [(String, Tint)] = [("~/code/pilot", .path), (" main", .dim), (" ❯ ", .path)]
        return [
            prompt + [("git status -sb", .plain)],
            [("## main...origin/main", .dim)],
            [(" M", .mark), (" Sources/Pilot/TopBar/TopBarView.swift", .plain)],
            prompt + [("swift test --filter BarDropTests", .plain)],
            [("Building for debugging...", .dim)],
            [("Test Suite 'BarDropTests' ", .plain), ("passed", .good), (" at 2026-10-12 21:04:11", .plain)],
            [("     Executed 9 tests, with 0 failures in 0.412 seconds", .plain)],
            prompt + [("claude", .plain)],
            [("✻", .mark), (" Claude Code  ", .plain), ("~/code/pilot", .dim)],
            [],
            [("> ", .dim), ("make the drop follow the focused display", .plain)],
            [("● ", .good), ("Read Sources/Pilot/QuickAI/AIChatPanel.swift", .plain)],
            [("● ", .good), ("Update Sources/Pilot/QuickAI/AIChatPanel.swift ", .plain), ("+6", .good), (" -2", .mark)],
            [("  ⎿  frame(_:visible:) now takes the focused screen", .dim)],
            [],
            [("> ", .dim)],
        ]
    }()

    /// The shell's stand-in: the session in the drop's mono face and Ink, a caret after the last prompt. The live view
    /// (Ghostty's Metal) draws nothing offscreen.
    struct Shell: View {
        @Environment(\.ink) private var ink

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(BarDropRenders.session.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 0) {
                        line.reduce(Text("")) { $0 + Text($1.0).foregroundStyle(colour($1.1)) }
                        if i == BarDropRenders.session.count - 1 { Rectangle().fill(ink.accent).frame(width: 7, height: 15) }
                    }
                    .font(ink.mono(12.5)).frame(height: 17)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        private func colour(_ tint: Tint) -> Color {
            switch tint {
            case .plain: ink.text
            case .path: ink.accentInk
            case .dim: ink.muted
            case .good: ink.green
            case .mark: ink.red
            }
        }
    }

    @Test("One drop and both, Instrument and Toybox, dark and light, at 1080 and 3440 pt",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("bar-drops")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }

        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                                   readBattery: { nil }, readWiFi: { nil }, watchStats: { _ in Task {} })
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: SystemSamplerTests.sampler(SystemSamplerTests.Counter()),
                                 keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()), timer: ExtensionTimer(), pilotTitle: { "2" })
        let model = await AIChatPanelRenders.model([
            ("Which app is using the most memory right now?",
             "**Zen** is at 2.4 GB across 31 tabs, then **Ghostex** at 1.1 GB. Everything else is under 400 MB. Want the five heaviest Zen tabs?"),
        ], streaming: false)
        defer { model.clear() }

        for each in Self.looks {
            look.style = each.style
            look.themeID = each.theme
            for screen in Self.screens {
                for open in [[BarDropKind.terminal], [.terminal, .askAI]] {
                    let canvas = Self.canvas(screen.size, open: Set(open), model: model, sources: sources, look: look)
                    let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = look.appearance(for: .quickAI)
                    window.contentView = canvas
                    defer { window.close() }
                    canvas.layoutSubtreeIfNeeded()
                    PanelTestSupport.pump(0.6)
                    // The ultrawide at 1x keeps the file sane; the portrait at 2x, as Sven's screens draw.
                    let rep = try #require(snapshot(canvas, scale: screen.size.width > 2000 ? 1 : 2))
                    let name = "\(each.name)-\(screen.name)-\(open.count == 1 ? "terminal" : "both").png"
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(name))
                }
            }
        }
    }

    /// A screen of `size` with the top bar along its top, its drop items lit for `open`, a window behind, and each open
    /// drop on its frame. AppKit's coordinates, the origin bottom left, as BarDropPlacement's.
    static func canvas(_ size: CGSize, open: Set<BarDropKind>, model: AIChatModel, sources: BarSources, look: Look) -> NSView {
        let screen = CGRect(origin: .zero, size: size)
        let bar = TopBarGeometry.frame(screen: screen, strip: Double(strip))
        let visible = CGRect(x: 0, y: 0, width: size.width, height: bar.minY)
        let canvas = NSView(frame: screen)
        canvas.wantsLayer = true

        let desktop = NSHostingView(rootView: Desktop(look: look).styled(.window, look: look).pilotTheme(look: look))
        desktop.frame = visible
        canvas.addSubview(desktop)

        var settings = BarSettings.defaults
        let items: [BarSlot] = [BarKind.terminal, .askAI].map { kind in settings.set(kind, style: .iconName); return .item(settings.entry(kind)) }
        let strip = TopBarStrip(sides: [.centre: items]) {
            TopBarSlot(slot: $0, screen: "Studio", sources: sources, store: .shared, lights: BarDropLights(open: open))
        }
        let barHost = NSHostingView(rootView: strip.styled(.topBar, look: look).pilotTheme(look: look))
        barHost.frame = bar
        canvas.addSubview(barHost)

        for (drop, frame) in BarDropPlacement.frames(open: open, screen: screen, visible: visible, bar: bar) {
            let view: NSView
            switch drop {
            case .terminal:
                let shell = NSHostingView(rootView: Shell().styled(.quickAI, look: look).pilotTheme(look: look))
                shell.sizingOptions = []
                shell.frame = CGRect(origin: .zero, size: frame.size)
                view = TerminalDropChrome(shell, look: look, key: "⇪ T", detail: { "zsh · ~/code/pilot" }, hide: {})
            case .askAI:
                let host = NSHostingView(rootView: AIChatPanel.content(model, size: nil, look: look))
                host.sizingOptions = []
                view = host
            }
            view.frame = frame
            canvas.addSubview(view)
        }
        return canvas
    }

    /// The desktop under the bar: the canvas, and one window behind where the drops hang, its title bar and a few rows.
    struct Desktop: View {
        @Environment(\.ink) private var ink
        let look: Look

        var body: some View {
            GeometryReader { space in
                let width = min(space.size.width - 160, 1800)
                ZStack(alignment: .top) {
                    ink.background
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 7) { ForEach(0..<3, id: \.self) { _ in Circle().fill(ink.line2).frame(width: 11, height: 11) } }
                        ForEach(0..<14, id: \.self) { row in
                            RoundedRectangle(cornerRadius: 3).fill(ink.line).frame(width: width * [0.62, 0.4, 0.75, 0.5][row % 4], height: 9)
                        }
                    }
                    .padding(22)
                    .frame(width: width, height: space.size.height * 0.62, alignment: .topLeading)
                    .background(look.theme.dark ? ink.raised : Color.white, in: .rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ink.line, lineWidth: 1) }
                    .padding(.top, 120)
                }
            }
        }
    }
}
}
#endif
