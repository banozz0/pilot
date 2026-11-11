#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The recording's control (story 192, Q162) offscreen: counting down, recording and paused as the top bar draws it,
/// and the capsule that stands in with the bar off, in Instrument and Toybox. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter RecordingControlRenders`
extension SharedLook {
@MainActor
@Suite("Recording control renders")
struct RecordingControlRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The control draws its count, its time and its pause, in the bar and as the capsule",
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
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("recording-control")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let recorder = Recorder()
        let scrolling = ScrollCapture(area: CGRect(x: 0, y: 0, width: 40, height: 60), display: 1, scale: 1) { _, _ in }
        let auto = ScrollCapture(area: CGRect(x: 0, y: 0, width: 40, height: 60), display: 1, scale: 1, auto: true) { _, _ in }
        for (style, theme) in [(PilotStyle.instrument, "tokyo-night"), (.toybox, "toybox")] {
            look.style = style
            look.themeID = theme
            for (name, phase, elapsed) in [("1-counting", Recorder.Phase.counting(3), 0.0), ("2-recording", .recording, 42.4), ("3-paused", .paused, 725.0)] {
                recorder.pose(phase, elapsed: elapsed)
                for capsule in [false, true] {
                    let view = RecordingControl(recorder: recorder, capsule: capsule).padding(10).frame(height: 40)
                        .background(Color(look.chromeTokens(.topBar).colors.canvas)).styled(capsule ? .hud : .topBar, look: look).pilotTheme(look: look)
                    let rep = try #require(try await snapshot(rendering: view))
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: out.appendingPathComponent("\(style.rawValue)-\(name)\(capsule ? "-capsule" : "").png"))
                }
            }
            // The scrolling capture's control (CP11), before and after the first rows.
            for (name, rows) in [("scroll-start", 0), ("scroll-rows", 60)] {
                if rows > 0 { scrolling.feed(ScrollCaptureTests.frame(0..<60)); try await Task.sleep(for: .milliseconds(50)) }
                let view = ScrollControl(capture: scrolling).padding(10).background(Color(look.chromeTokens(.hud).colors.canvas))
                    .styled(.hud, look: look).pilotTheme(look: look)
                let rep = try #require(try await snapshot(rendering: view))
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(style.rawValue)-\(name).png"))
            }
            let autoView = ScrollControl(capture: auto).padding(10).background(Color(look.chromeTokens(.hud).colors.canvas))
                .styled(.hud, look: look).pilotTheme(look: look)
            // The after-capture thumbnail (build 54), plain and hovered.
            for (hovered, copied) in [(false, false), (true, false), (true, true)] {
                let model = ThumbnailModel(image: CaptureGrabTests.image(400, 260), scale: 2, file: nil)
                model.stopClock()
                model.hovered = hovered
                model.stopClock()
                if copied { model.flash("Copied") }
                let size = ThumbnailStack.size(model.size)
                let thumb = ThumbnailView(model: model).frame(width: size.width, height: size.height).padding(10)
                    .background(Color(look.chromeTokens(.hud).colors.canvas)).styled(.hud, look: look).pilotTheme(look: look)
                let rep = try #require(try await snapshot(rendering: thumb))
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(style.rawValue)-thumbnail\(hovered ? "-hover" : "")\(copied ? "-copied" : "").png"))
            }
            let autoRep = try #require(try await snapshot(rendering: autoView))
            try #require(autoRep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(style.rawValue)-scroll-auto.png"))
        }
    }
}
}
#endif
