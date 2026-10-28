#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// AI › Setup (task N10; any provider, 2026-10-10; its own page since C3; its own tab, page map 2026-10-17), opt-in like the
/// other renders: the tab alone in
/// Instrument and Toybox on Lagoon, and Instrument on Porcelain, in each state: the subscription signed in, signed out and
/// missing, the Anthropic key missing, saved and tested, and rejected, OpenAI with no key, Ollama with a listed model
/// that is not running, an endpoint set up, and the ChatGPT and Google subscriptions connected, not connected and
/// missing. Fake Keychain, network and CLIs; nothing is read, run or sent.
/// `PILOT_RENDER_DIR=<fresh dir> swift test --filter AISettingsRenders`
extension SharedLook {
@MainActor
@Suite("AI settings renders")
struct AISettingsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("AI › Setup renders in each style and state", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() throws {
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("ai-settings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        let path = NSHomeDirectory() + "/.local/bin/claude"
        func block(_ provider: AIProvider, key: String? = nil, cli: AISettings.CLIStatus = .missing,
                   test: AIPage.Test? = nil, setUp: (UserDefaults) -> Void = { _ in }) throws -> AISetupPage {
            let keys = AISettingsTests.FakeKeys()
            try keys.setKey(key, for: provider)
            let defaults = try #require(UserDefaults(suiteName: testSuite()))
            setUp(defaults)
            let ai = AISettings(defaults: defaults, keys: keys, http: AISettingsTests.NoNetwork())
            ai.provider = provider
            ai.checkCLI = { $0 == provider ? cli : .missing }
            return AISetupPage(settings: ai, test: test)
        }
        let states: [(String, AISetupPage)] = [
            ("1-cli-signed-in", try block(.claudeCode, cli: .signedIn(path: path))),
            ("2-cli-signed-out", try block(.claudeCode, cli: .signedOut(path: path), test: .failed(.signedOut))),
            ("3-cli-missing", try block(.claudeCode)),
            ("4-api-no-key", try block(.anthropicAPI)),
            ("c1-codex-connected", try block(.codex, cli: .signedIn(path: "/opt/homebrew/bin/codex"), test: .passed) {
                $0.set(["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"], forKey: AISettings.listKey(.codex))
                $0.set("gpt-6.1-sol", forKey: AISettings.modelKey(.codex))
                $0.set("medium", forKey: AISettings.effortKey(.codex))
            }),
            ("c2-codex-not-connected", try block(.codex, cli: .signedOut(path: "/opt/homebrew/bin/codex"), test: .failed(.notConnected(.codex)))),
            ("5-api-key-works", try block(.anthropicAPI, key: "sk-ant-fake", test: .passed)),
            ("6-api-key-rejected", try block(.anthropicAPI, key: "sk-ant-fake", test: .failed(.keyRejected(.anthropicAPI)))),
            ("7-openai-no-key", try block(.openAI)),
            ("8-ollama-not-running", try block(.ollama, test: .failed(.unreachable(.ollama, "http://localhost:11434"))) {
                $0.set(["llama3.2:latest", "qwen3:4b"], forKey: AISettings.listKey(.ollama))
            }),
            ("9-endpoint-works", try block(.openAICompatible, key: "fake", test: .passed) {
                $0.set("https://openrouter.ai/api/v1", forKey: AISettings.addressKey(.openAICompatible))
                $0.set("vendor/model-x", forKey: AISettings.modelKey(.openAICompatible))
            }),
        ]
        let looks: [(String, PilotStyle, String)] = [("instrument", .instrument, "lagoon"), ("instrument", .instrument, "porcelain"),
                                                     ("toybox", .toybox, "lagoon")]
        for (name, style, theme) in looks {
            look.themeID = theme
            look.style = style
            for (state, block) in states where theme == "lagoon" || state.hasPrefix("1") || state.hasPrefix("5") || state.hasPrefix("c1") {
                let page = Ground { block.frame(width: 760, height: 2000, alignment: .top) }.styled(.page(.ai)).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("\(name)-\(theme)-\(state).png"))
            }
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
