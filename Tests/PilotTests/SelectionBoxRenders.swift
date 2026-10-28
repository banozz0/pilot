#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of selected text (Sven Q213 to Q220): the selection pill, the chat bubble before its first message,
/// with its "…" rewrites, a chat, a rewrite with Replace, a failure, and Voice › Read aloud's voice list, in Instrument and
/// Toybox on Lagoon and Toybox's theme. Fake runners answer. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SelectionBoxRenders`
extension SharedLook {
@MainActor
@Suite("Selection box renders")
struct SelectionBoxRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let selected = "Can we move the design review to Thursday? A few of us are out on Wednesday and I'd rather everyone sees the pricing options together."

    /// The bubble's model after `turns`, each a rewrite (its instruction) or a question (nil), answered whole.
    static func model(_ turns: [(String, String?, String)], more: Bool = false, failing: QuickAI.Failure? = nil) async -> SelectionBoxModel {
        let model = SelectionBoxModel()
        model.open(selected, in: "Notes")
        model.chat.route = "Claude Code · Haiku"
        model.more = more
        for (said, instruction, answer) in turns {
            model.began(rewrite: instruction)
            let route: Result<AIChat.Runner, QuickAI.Failure> = if let failing { .failure(failing) } else { .success(AIChatPanelRenders.answers(answer)) }
            model.chat.send(said, through: route)
            for _ in 0..<200 where model.chat.running { try? await Task.sleep(for: .milliseconds(10)) }
        }
        return model
    }

    static let voices = [
        SpeechVoice(id: "en.ava", name: "Ava", language: "en-US", quality: .premium),
        SpeechVoice(id: "en.zoe", name: "Zoe", language: "en-US", quality: .enhanced),
        SpeechVoice(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
        SpeechVoice(id: "com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB", quality: .standard),
        SpeechVoice(id: "en.moira", name: "Moira", language: "en-IE", quality: .enhanced),
        SpeechVoice(id: "en.karen", name: "Karen", language: "en-AU", quality: .enhanced),
        SpeechVoice(id: "com.apple.voice.compact.en-IN.Rishi", name: "Rishi", language: "en-IN", quality: .standard),
        SpeechVoice(id: "es.paulina", name: "Paulina", language: "es-MX", quality: .enhanced),
        SpeechVoice(id: "com.apple.voice.compact.es-ES.Monica", name: "Mónica", language: "es-ES", quality: .standard),
        SpeechVoice(id: "com.apple.voice.compact.fr-FR.Thomas", name: "Thomas", language: "fr-FR", quality: .standard),
    ]

    @Test("The pill, the chat bubble's states and the voice list render in every style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("selection-box")
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let rewrite = "Can we move the design review to Thursday? Some of us are out Wednesday, and I'd like everyone to see the pricing options together."
        let states: [(String, SelectionBoxModel)] = [
            ("2-start", await Self.model([])),
            ("3-more", await Self.model([], more: true)),
            ("4-chat", await Self.model([
                ("what's this asking for?", nil, "A move of the design review from Wednesday to Thursday, so the people out on Wednesday see the pricing options with everyone else."),
                ("reply yes, but only after 2pm", nil, "\"Thursday works, as long as it's after 2pm. Shall I move the invite to 2:30?\""),
            ])),
            ("5-rewrite", await Self.model([("Make concise", SelectionPrompt.chips[2].instruction, rewrite)])),
            ("6-failed", await Self.model([("Make concise", SelectionPrompt.chips[2].instruction, "")], failing: .noKey(.openAI))),
        ]
        let speech = ReadAloudSettings(defaults: try #require(UserDefaults(suiteName: testSuite())))
        speech.voiceID = "kokoro/af_heart"
        speech.personal = .notAsked
        // Kokoro downloaded (Q264): its row says on this Mac and its voices lead the list.
        let kokoroBase = FileManager.default.temporaryDirectory.appending(path: "kokoro-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: kokoroBase.appending(path: "kokoro"), withIntermediateDirectories: true)
        try Data(KokoroModel.helperName.utf8).write(to: kokoroBase.appending(path: "kokoro/\(SpeechModel.readyFile)"))
        defer { try? FileManager.default.removeItem(at: kokoroBase) }
        let kokoro = KokoroModel(base: kokoroBase)
        for style in PilotStyle.allCases {
            look.style = style
            for theme in ["lagoon", "toybox"] {
                look.themeID = theme
                let pill = SelectionPillView().padding(24).styled(.hud, look: look).pilotTheme(look: look)
                try write(pill, to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-1-pill.png"))
                for (name, model) in states {
                    let view = SelectionBoxView(model: model)
                        .frame(width: SelectionBox.width, height: SelectionBox.height(started: model.started))
                        .padding(24)
                        .styled(.quickAI, look: look).pilotTheme(look: look)
                    try write(view, to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-\(name).png"))
                }
                let sections = SpeechVoice.sections(SpeechVoice.listed(SpeechVoice.shown(kokoro.voices + Self.voices), preferred: ["en-GB", "es-CO"]), preferred: ["en-GB", "es-CO"])
                let page = VoiceGround { ReadAloudBlock(speech: speech, kokoro: kokoro, mine: sections.mine, rest: sections.rest).frame(width: 760, height: 2300, alignment: .top) }
                    .styled(.page(.voice)).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-7-voices.png"))
            }
        }
        for (_, model) in states { model.chat.clear() }
    }

    private func write(_ view: some View, to url: URL) throws {
        let rep = try #require(snapshot(drawing: view))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// The block on its style's ground, as the page lays it.
private struct VoiceGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
