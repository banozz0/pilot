#if DEBUG
import AppKit
import AVFoundation
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Voice › Dictation (story 194, Q452), in each state of its speech model and microphone, Instrument on Tokyo Night;
/// then its front and its More blocks (Speech models, While you speak; pilot-ui-redesign T18) under Tokyo Night and
/// Porcelain, at the panel's page width (780 less the 156 pt page list). A fake helper; nothing downloads or records.
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
        look.themeID = "tokyo-night"
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
        let width = AppWindowController.size.width - InstrumentFrame.listWidth
        for (state, block) in states {
            let page = Ground { block.frame(width: width, height: 1000, alignment: .top) }.styled(.page(.voice)).pilotTheme(look: look)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("\(state).png"))
        }

        // Front and More in both themes: a model in use and one more on disk, the take shown in both places as words.
        let rig = PilotDictationTests.Rig()
        rig.grant = .authorized
        try rig.onDisk(.parakeetUltra)
        try rig.onDisk(.whisperTurbo)
        rig.microphone.refresh()
        (rig.pilot.showIn, rig.pilot.whileSpeaking, rig.pilot.waveColour) = (.both, .words, .theme)
        for theme in ["tokyo-night", "porcelain"] {
            look.themeID = theme
            let front = Ground { DictationBlock(dictation: rig.pilot, microphone: rig.microphone).frame(width: width, height: 1000, alignment: .top) }
            let more = Ground {
                VStack(spacing: 16) { SpeechModelsBlock(dictation: rig.pilot); DictationShowsBlock(dictation: rig.pilot) }
                    .frame(width: width, height: 1000, alignment: .top)
            }
            for (tab, view) in [("front", AnyView(front)), ("more", AnyView(more))] {
                try RestyledRenders.writeTrimmed(rendered(view.styled(.page(.voice)).pilotTheme(look: look)), from: 0,
                                                 to: dir.appendingPathComponent("dictation-\(tab)-\(theme).png"))
            }
        }
    }
}

/// The block on its style's ground, as the page lays it.
private struct Ground<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.background(ink.background) }
}
}
#endif
