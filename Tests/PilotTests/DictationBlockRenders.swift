#if DEBUG
import AppKit
import AVFoundation
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Voice › Dictation (story 194, Q452), in each state of its speech model and microphone, Instrument on
/// Lagoon. A fake helper; nothing downloads or records.
/// `PILOT_RENDER_DIR=<fresh dir> swift test --filter DictationBlockRenders`
extension SharedLook {
@MainActor
@Suite("Dictation block renders")
struct DictationBlockRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Pilot's dictation renders in each model and microphone state", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() throws {
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("dictation")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"
        look.style = .instrument

        func block(_ grant: AVAuthorizationStatus, _ drive: (PilotDictationTests.Rig) throws -> Void) throws -> DictationBlock {
            let rig = PilotDictationTests.Rig()
            rig.grant = grant
            try drive(rig)
            rig.microphone.refresh()
            return DictationBlock(dictation: rig.pilot, microphone: rig.microphone)
        }
        let states: [(String, DictationBlock)] = [
            ("1-absent", try block(.notDetermined) { _ in }),
            ("2-downloading", try block(.authorized) { $0.model.download(); $0.helper.last.heard(.progress(0.42)) }),
            ("3-preparing", try block(.authorized) { $0.model.download(); $0.helper.last.heard(.preparing) }),
            ("4-ready", try block(.authorized) { try $0.onDisk() }),
            ("5-ready-mic-denied", try block(.denied) { try $0.onDisk() }),
            ("7-two-on-disk", try block(.authorized) { try $0.onDisk(.parakeetUltra); try $0.onDisk(.whisperTurbo) }),
            // Top bar picked while the bar is off (no engine here): the fallback line; a custom waveform colour's well.
            ("8-top-bar-custom-colour", try block(.authorized) { try $0.onDisk(); $0.pilot.showIn = .topBar; $0.pilot.waveColour = .custom(0xFF5FA2) }),
            ("6-failed", try block(.authorized) {
                $0.model.download(); $0.helper.last.heard(.error("The Internet connection appears to be offline.")); $0.helper.last.ended(1)
            }),
        ]
        for (state, block) in states {
            let page = Ground { block.frame(width: 760, height: 1000, alignment: .top) }.styled(.page(.voice)).pilotTheme(look: look)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("\(state).png"))
        }
    }
}

/// The block on its style's ground, as the page lays it.
private struct Ground<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
