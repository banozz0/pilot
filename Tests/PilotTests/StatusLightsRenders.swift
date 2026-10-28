#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Status lights item offscreen, only its dots (Q205): quiet (the Menu bar page's unlit dots; the top bar shows
/// nothing), one lit, one waiting, privacy hot, several at once, as a slice of the top bar, and the popover over the
/// several, in Instrument and Toybox. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter StatusLightsRenders`
extension SharedLook {
@MainActor
@Suite("Status lights renders")
struct StatusLightsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func light(_ id: String, _ family: StatusLight.Family, _ state: StatusLight.State, _ title: String, _ source: String,
                      _ detail: String? = nil, jump: StatusJump = .none) -> StatusLight {
        StatusLight(id: id, family: family, state: state, title: title, source: source, detail: detail, jump: jump)
    }

    static let working = light("run", .agent, .working, "Status lights", "Ghostex · pilot", "Writing the orbit", jump: .ghostex("A"))
    static let waiting = light("ask", .agent, .waiting, "Pilot coordinator 17", "Ghostex · pilot", "Which direction: orbit, pill or ring?", jump: .ghostex("B"))
    static let mic = light("mic.Zoom", .privacy, .watching, "Zoom", "microphone", jump: .app("Zoom"))
    static let recording = light("recording", .privacy, .watching, "Pilot", "screen recording", "Recording the screen")
    static let several = [waiting, working,
                          light("fin", .agent, .done, "Capture bar item", "Ghostex · pilot", "Patch ready for review", jump: .ghostex("C")),
                          mic, recording,
                          light("dl", .job, .working, "Xcode_26.1.xip", "Safari", "Downloading", jump: .file(URL(fileURLWithPath: "/tmp/x"))),
                          light("bad", .job, .error, "swift test --filter Binds", "pilot light", "exit 1")]

    @Test("The dots in their five states and the popover over several lights",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("status-lights")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let states: [(String, [StatusLight])] = [("1-quiet", []), ("2-one-lit", [Self.working]), ("3-waiting", [Self.waiting]),
                                                 ("4-privacy", [Self.mic, Self.recording]), ("5-several", Self.several)]
        // The popover's source: pushed jobs and privacy fakes stand in for every family.
        let fakes = StatusLightsTests.Fakes()
        fakes.ghostex = StatusLightsTests.json([
            StatusLightsTests.session("B", "Pilot coordinator 17", activity: "attention", said: "working", message: "Which direction: orbit, pill or ring?"),
            StatusLightsTests.session("A", "Status lights", activity: "working", said: "working", message: "Writing the orbit"),
            StatusLightsTests.session("C", "Capture bar item", activity: "attention", said: "done", thread: true, message: "Patch ready for review"),
        ])
        fakes.mic = MicState(apps: ["Zoom"])
        fakes.camera = true
        fakes.recording.on = true
        let lights = fakes.lights()
        lights.start()
        defer { lights.stop() }
        await StatusLightsTests.settle(lights) { lights.agents.count == 3 }
        lights.push(id: "build", state: .working, title: "swift build --product Pilot", family: .job, detail: "Compiling", session: "S1:P:G")
        lights.push(id: "test", state: .error, title: "swift test --filter Binds", family: .job, detail: "exit 1", session: nil)

        for (style, theme) in [(PilotStyle.instrument, "lagoon"), (.toybox, "toybox")] {
            look.style = style
            look.themeID = theme
            let canvas = Color(look.chromeTokens(.topBar).colors.canvas)
            for (name, lit) in states {
                // A slice of the bar's right end: the dots, a rule, the clock.
                let bar = HStack(spacing: 12) {
                    StatusDotsView(lights: lit)
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 14)
                    Text("14:32").font(BarMetrics.font)
                }
                .padding(.horizontal, 12).frame(height: 30).background(canvas)
                .environment(\.inTopBar, true).styled(.topBar, look: look).pilotTheme(look: look)
                let rep = try #require(snapshot(drawing: bar, scale: 4))
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(style.rawValue)-\(name).png"))
            }
            let popover = StatusPopover(lights: lights).padding(10).background(Color(look.chromeTokens(.hud).colors.canvas))
                .styled(.hud, look: look).pilotTheme(look: look)
            let rep = try #require(snapshot(drawing: popover))
            try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(style.rawValue)-popover.png"))
        }
    }
}
}
#endif
