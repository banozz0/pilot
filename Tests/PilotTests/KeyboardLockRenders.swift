#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Lock keyboard for cleaning (Part 04): one display's lock screen through KeyboardLockController.makePanel at 1440 by
/// 900, Esc up and Esc held 1.5 s, and Binds › Keyboard's Cleaning block at 760 pt, in Instrument and Toybox, dark and
/// light. Solid: offscreen glass draws flat grey, so the glass is Sven's QA. Never locks the keyboard: the panel is drawn,
/// never shown, and no tap is made. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter KeyboardLockRenders`
extension SharedLook {
@MainActor
@Suite("Keyboard lock renders")
struct KeyboardLockRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The lock screen and the Cleaning block render in Instrument and Toybox, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let engine = try ToyboxBindsRenders().engine()
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("keyboard-lock")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let since = Date(timeIntervalSinceReferenceDate: 783_000_000), now = since.addingTimeInterval(12)
        for (style, themes) in [(PilotStyle.instrument, ["nightwatch", "tokyo-night"]), (.toybox, ["toybox"])] {
            look.style = style
            for theme in themes {
                look.themeID = theme
                let tag = "\(style.rawValue)-\(theme)"
                for (name, escape) in [("up", nil), ("held", now.addingTimeInterval(-1.5))] as [(String, Date?)] {
                    let model = KeyboardLockModel(since: since, escapeSince: escape, now: { now })
                    let panel = KeyboardLockController.makePanel(KeyboardLockView(model: model, glass: false) {},
                                                                 frame: CGRect(x: 0, y: 0, width: 1440, height: 900), look: look)
                    defer { panel.close() }
                    let content = try #require(panel.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    content.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(content, scale: 1))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("screen-\(tag)-\(name).png"))
                }
                let card = KeyboardLockCard(edit: { _ in }).padding(20).frame(width: 760)
                    .styled(.page(.binds)).environment(engine).pilotTheme(look: look).background(Theme.background)
                try #require(try rendered(card).representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("card-\(tag).png"))
            }
        }
    }
}
}
#endif
