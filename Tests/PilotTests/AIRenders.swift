#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// T13 drawn (spec pilot-ai-helper; two tabs, page map 2026-10-17): AI › Chat in the whole window, the chat filling it,
/// and AI › Setup, each provider on one line with its state and its button, the picked one's set-up, the keys, in both
/// window layouts (rail and page list, toolbar tabs) and both styles (Instrument on Lagoon, Toybox), at 1440 by 900 (two
/// columns) and 760 by 760 (one); the empty chat with an unready provider picked (one line and Set up…, and Setup with
/// it); the empty chat with Claude Code (the Skills bubble, P29) at both sizes and its Skills list open, with an API key
/// (no /extension, Q193), with codex signed in (the same skills, Q203) and with codex not yet signed in to Pilot's own Codex home (Sign in to Codex); a
/// provider's set-up popover's content; and the Ask AI panel. Fake
/// Keychain, network and CLIs: nothing is read, run or sent. Glass draws nothing offscreen; Sven's screenshot proves it.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> PILOT_RESOURCES=Packaging swift test --filter AIRenders` (the skills)
extension SharedLook {
@MainActor
@Suite("AIRenders", .timeLimit(.minutes(1)))
struct AIRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let looks: [(name: String, style: PilotStyle, theme: String)] = [("instrument", .instrument, "lagoon"), ("toybox", .toybox, "toybox"),
                                                                         ("porcelain", .instrument, "porcelain"), ("toybox-night", .toybox, "toybox-night")]

    /// Claude Code signed in, Codex not connected, Ollama with a model, an Anthropic key saved and the other keys
    /// missing; `picked` the provider the chat uses.
    static func settings(picked: AIProvider, codex: AISettings.CLIStatus = .signedOut(path: "/opt/homebrew/bin/codex")) throws -> AISettings {
        let keys = AISettingsTests.FakeKeys()
        try keys.setKey("sk-ant-fake", for: .anthropicAPI)
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        defaults.set(["llama3.2:latest", "qwen3:4b"], forKey: AISettings.listKey(.ollama))
        defaults.set("sonnet", forKey: AISettings.modelKey(.claudeCode))
        let ai = AISettings(defaults: defaults, keys: keys, http: AISettingsTests.NoNetwork())
        ai.provider = picked
        let statuses: [AIProvider: AISettings.CLIStatus] = [.claudeCode: .signedIn(path: NSHomeDirectory() + "/.local/bin/claude"),
                                                            .codex: codex]
        ai.checkCLI = { statuses[$0] ?? .missing }
        return ai
    }

    @Test("AI › Chat fills the window with the chat, and AI › Setup lists the providers one line each, in every layout and style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let engine = try ToyboxBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("ai")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = Self.env["PILOT_RENDER_ONLY"]
        let look = Look.shared
        let saved = (look.themeID, look.style, look.windowShape, look.glass)
        defer { (look.themeID, look.style, look.windowShape, look.glass) = saved }
        look.glass = false

        let talking = try Self.settings(picked: .claudeCode)
        let unready = try Self.settings(picked: .openAI)
        let codex = try Self.settings(picked: .codex, codex: .signedIn(path: "/opt/homebrew/bin/codex"))
        let codexSignIn = try Self.settings(picked: .codex)
        let apiKey = try Self.settings(picked: .anthropicAPI)
        await talking.refreshCLIs()
        await apiKey.refreshCLIs()
        await unready.refreshCLIs()
        await codex.refreshCLIs()
        await codexSignIn.refreshCLIs()
        let conversation = await AIChatPanelRenders.model(AIChatPanelRenders.turns, streaming: false)
        let fresh = AIChatModel()
        let bound = await AIChatAgentTests.conversation(asking: false), asking = await AIChatAgentTests.conversation(asking: true)
        let plan1 = try await Self.planning(Self.oneChange), plan8 = try await Self.planning(Self.eightChanges)
        defer { conversation.clear(); bound.clear(); asking.clear(); plan1.clear(); plan8.clear() }

        var sources = AIPageSources()
        sources.send = {}
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        // The page's sources are read through a box, so one window draws each state.
        let box = Box(settings: talking, chat: conversation)
        sources.settings = { box.settings }
        sources.chat = { box.chat }
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.aiPageSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)

        func shot(_ file: String, width: Int, height: Int, place: AppPlace = AppPlace(.ai)) throws {
            guard only.map(file.contains) ?? true else { return }
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            model.go(AppPlace(.binds))
            PanelTestSupport.pump(0.2)
            model.go(place)
            PanelTestSupport.pump(0.9)
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 1))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }

        for shape in WindowShape.allCases {
            look.windowShape = shape
            for (name, style, theme) in Self.looks {
                (look.style, look.themeID) = (style, theme)
                AppWindowController.applyLook(look, to: window)
                (box.settings, box.chat) = (talking, conversation)
                try shot("\(shape.rawValue)-\(name)-chat-1440", width: 1440, height: 900)
                try shot("\(shape.rawValue)-\(name)-chat-760", width: 760, height: 760)
                // AI › Setup: every provider line, the picked one's set-up, the keys and the new-chat time.
                try shot("\(shape.rawValue)-\(name)-setup-1440", width: 1440, height: 900, place: AppPlace(.aiSetup))
                if shape == .rail {
                    try shot("\(shape.rawValue)-\(name)-setup-760", width: 760, height: 760, place: AppPlace(.aiSetup))
                    (box.settings, box.chat) = (unready, fresh)
                    try shot("\(shape.rawValue)-\(name)-empty-unready-1440", width: 1440, height: 900)
                    try shot("\(shape.rawValue)-\(name)-setup-unready-1440", width: 1440, height: 900, place: AppPlace(.aiSetup))
                    (box.settings, box.chat) = (talking, fresh)
                    try shot("\(shape.rawValue)-\(name)-empty-acts-1440", width: 1440, height: 900)
                    try shot("\(shape.rawValue)-\(name)-empty-acts-760", width: 760, height: 760)
                    // P29: a / typed in the empty box opens the Skills list over the chat.
                    fresh.draft = "/"
                    try shot("\(shape.rawValue)-\(name)-skills-open-1440", width: 1440, height: 900)
                    try shot("\(shape.rawValue)-\(name)-skills-open-760", width: 760, height: 760)
                    fresh.draft = ""
                    (box.settings, box.chat) = (codex, fresh)
                    try shot("\(shape.rawValue)-\(name)-empty-codex-1440", width: 1440, height: 900)
                    (box.settings, box.chat) = (codexSignIn, fresh)
                    try shot("\(shape.rawValue)-\(name)-empty-codex-sign-in-1440", width: 1440, height: 900)
                    try shot("\(shape.rawValue)-\(name)-empty-codex-sign-in-760", width: 760, height: 760)
                    (box.settings, box.chat) = (apiKey, fresh)
                    try shot("\(shape.rawValue)-\(name)-empty-api-key-1440", width: 1440, height: 900)
                    for (state, chat) in [("bound", bound), ("asking", asking), ("plan-1", plan1), ("plan-8", plan8)] {
                        (box.settings, box.chat) = (talking, chat)
                        try shot("\(shape.rawValue)-\(name)-agent-\(state)-1440", width: 1440, height: 900)
                    }
                }
            }
        }

        // A provider's set-up, as its line's button opens it: an API with no key, and the picked subscription.
        for (name, style, theme) in Self.looks {
            (look.style, look.themeID) = (style, theme)
            for (state, route, ai) in [("setup-openai-no-key", AIProvider.openAI, unready), ("setup-claude-signed-in", .claudeCode, talking)]
            where only.map("\(name)-\(state)".contains) ?? true {
                let view = OnSurface { AIProviderSetup(route: route, settings: ai) }
                    .environment(engine).styled(.page(.ai), look: look).pilotTheme(look: look)
                let rep = try #require(try await snapshot(rendering: view, scale: 1))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(state).png"))
            }
            // The Ask AI panel on the same conversation, and on the agent's.
            for (file, chat) in [("\(name)-panel", conversation), ("\(name)-agent-bound-panel", bound), ("\(name)-agent-asking-panel", asking),
                                 ("\(name)-plan-1-panel", plan1), ("\(name)-plan-8-panel", plan8)] where only.map(file.contains) ?? true {
                let rep = try #require(try await snapshot(rendering: AIChatPanel.content(chat, look: look), scale: 1))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            }
        }
    }

    /// A plan of one bind, the card's smallest.
    static let oneChange: [ControlPlan.Draft] = [.init("Bind Open Linear", old: "none", new: "Hyper+L", key: "Hyper+L", free: true)]

    /// Eight rows, each kind the card draws: free and taken keys, a key moved, settings and lists old → new, and a shell
    /// bind that asks on its own, so Discard is the filled button.
    static let eightChanges: [ControlPlan.Draft] = [
        .init("Bind Open Linear", old: "none", new: "Hyper+L", key: "Hyper+L", free: true),
        .init("Bind Open Figma", old: "none", new: "Hyper+F", key: "Hyper+F", free: true),
        .init("Bind Open Notion", old: "Hyper+N", new: "Hyper+O", key: "Hyper+O", free: true),
        .init("Bind Toggle floating", old: "none", new: "Hyper+Shift+F", key: "Hyper+Shift+F", free: false),
        .init("Bind Upgrade Homebrew", old: "none", new: "Hyper+U", key: "Hyper+U", free: true,
              asks: .init("Run shell", "brew upgrade")),
        .init("Set tiling.gaps.inner", old: "8", new: "12"),
        .init("Set menu.width", old: "640", new: "720"),
        .init("Add to app-rules", old: "–", new: "Slack on 4"),
    ]

    /// The agent's turn: it reads the setup, says so, then runs `pilot plan apply` and waits there as the gate asks.
    nonisolated static let planTurn: AIChatModel.Turn = { _, event throws(QuickAI.Failure) in
        for (i, command) in ["pilot guide binds", "pilot actions --module apps", "pilot keys --free", "pilot list apps"].enumerated() {
            event(.toolCall(id: "r\(i)", command: command))
            event(.toolResult(id: "r\(i)", output: "{}", isError: false))
        }
        event(.text("You open Linear, Figma and Notion most and none has a free key of its own. Here is the plan."))
        event(.toolCall(id: "apply", command: "pilot plan apply"))
        try? await Task.sleep(for: .seconds(60))
        return AIChat.Reply("")
    }

    /// A chat whose turn read the setup, then waits on `pilot plan apply`, the plan of `drafts` asked on its row.
    static func planning(_ drafts: [ControlPlan.Draft]) async throws -> AIChatModel {
        let plan = ControlPlan()
        for (i, draft) in drafts.enumerated() { _ = try plan.add(draft, request: ControlRequest(verb: "set", args: ["row\(i)", "\(i)"])) }
        let model = AIChatModel()
        model.route = "Claude Code · Sonnet"
        model.viewers += 1
        model.send("Suggest Hyper binds for the apps I use most.", acting: .success(planTurn))
        await AIChatAgentTests.rowOpen(model)
        let ask = plan.ask
        Task { _ = await model.decide(ask, program: "pilot, from claude") }
        _ = await AIChatAgentTests.asked(model)
        return model
    }

    /// The popover's content on the style's raised surface, as the popover draws it (offscreen the floating surface is clear).
    struct OnSurface<Content: View>: View {
        @Environment(\.ink) private var ink
        @ViewBuilder var content: Content
        var body: some View { content.background(ink.surface).padding(24).background(ink.background) }
    }

    @MainActor final class Box {
        var settings: AISettings
        var chat: AIChatModel
        init(settings: AISettings, chat: AIChatModel) { (self.settings, self.chat) = (settings, chat) }
    }
}
}
#endif
