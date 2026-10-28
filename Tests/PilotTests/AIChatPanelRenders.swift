#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the AI chat panel (story 166): empty, a 3-turn conversation (prose with inline code and a
/// fenced block), and its third answer still streaming, in Instrument and Toybox on Lagoon and Toybox's theme.
/// A fake runner answers. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter AIChatPanelRenders`
extension SharedLook {
@MainActor
@Suite("AI chat panel renders")
struct AIChatPanelRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    nonisolated static let turns: [(String, String)] = [
        ("how do I undo the last git commit but keep the changes",
         "Use `git reset --soft HEAD~1`. It moves the branch back one commit and leaves the changes staged."),
        ("and if I already pushed it?",
         "Then rewrite nothing others may have pulled: add a commit that undoes it.\n\n```bash\ngit revert HEAD\ngit push\n```\n\nYour history keeps both commits."),
        ("what does --soft mean exactly",
         "`--soft` moves only the branch pointer. The index and your files stay as they were, so the undone commit's changes wait staged for the next commit."),
    ]

    /// A runner that answers `text` whole.
    nonisolated static func answers(_ text: String) -> AIChat.Runner {
        { _, _ throws(QuickAI.Failure) in AIChat.Reply(text) }
    }

    /// A runner that sends `text` and goes on writing until the render is drawn.
    nonisolated static func streams(_ text: String) -> AIChat.Runner {
        { _, piece throws(QuickAI.Failure) in
            piece(text)
            try? await Task.sleep(for: .seconds(60))
            return AIChat.Reply(text)
        }
    }

    /// A model holding `turns`, the last answer still streaming when `streaming`.
    static func model(_ turns: [(String, String)], streaming: Bool) async -> AIChatModel {
        let model = AIChatModel()
        model.route = "Claude Code · Sonnet"
        for (i, (question, answer)) in turns.enumerated() {
            let last = streaming && i == turns.count - 1
            model.send(question, through: .success(last ? streams(String(answer.prefix(60))) : answers(answer)))
            for _ in 0..<200 where last ? model.streaming.isEmpty : model.running { try? await Task.sleep(for: .milliseconds(10)) }
        }
        return model
    }

    @Test("The AI chat panel renders empty, with three turns and streaming, in every style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("ai-chat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }

        for style in PilotStyle.allCases {
            look.style = style
            for theme in ["lagoon", "toybox"] {
                look.themeID = theme
                let states = [("1-empty", await Self.model([], streaming: false)),
                              ("2-three-turns", await Self.model(Self.turns, streaming: false)),
                              ("3-streaming", await Self.model(Self.turns, streaming: true))]
                for (name, model) in states {
                    defer { model.clear() }
                    let rep = try #require(try await snapshot(rendering: AIChatPanel.content(model, look: look)))
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-\(name).png"))
                }
            }
        }
    }

    /// Look's Glass on, in Instrument on Lagoon (Toybox's panel stays solid), over a stand-in desktop: the notch's ground is clear, so
    /// the desktop shows where the glass will be. The glass itself (NSGlassEffectView) draws nothing offscreen.
    @Test("The AI chat panel over Glass in Instrument", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func glass() async throws {
        let dir = try ClockRenders.dir("ai-chat")
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = saved }
        let desktop = LinearGradient(colors: [Color(red: 0.9, green: 0.35, blue: 0.2), Color(red: 0.15, green: 0.3, blue: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
        (look.style, look.themeID, look.glass) = (.instrument, "lagoon", true)
        let model = await Self.model(Self.turns, streaming: false)
        defer { model.clear() }
        let rep = try #require(try await snapshot(rendering: AIChatPanel.content(model, look: look).background(desktop)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("glass-instrument-lagoon.png"))
    }
}
}
#endif
