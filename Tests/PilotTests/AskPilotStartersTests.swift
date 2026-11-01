import PilotCore
import Testing
@testable import Pilot

/// Ask Pilot's skills (P29, Sven Q268–Q271, 2026-10-18; the starters before, Q177): a pick puts the command and its starter
/// in the chat box and never sends; /extension routes to the extension maker and waits for the idea; a message that starts
/// with a guide's command carries its steps to every provider, in the message itself; every provider may change Pilot
/// (the API keys since Q193, codex since Q203), only Claude Code makes extensions and widgets, which the Skills list offers on every provider (Sven, 2026-10-31).
@MainActor
@Suite("Ask Pilot starters")
struct AskPilotStartersTests {
    static let skills = AgentGuidesTests.skills

    @Test("Make an extension puts /extension and waits; the maker takes the turn once an idea follows")
    func extensionRoutes() throws {
        let skill = try #require(Self.skills.first { $0.name == ExtensionMaker.skill })
        let draft = AskPilotSkills.draft(picking: skill, over: "")
        #expect(draft == "/extension ")
        #expect(ExtensionMaker.idea(draft) == "")
        #expect(ExtensionMaker.idea(draft + "list my open ports") == "list my open ports")
    }

    @Test("Ten skills, each with its line and starter; a pick fills the box over a typed / and keeps typed words")
    func starters() throws {
        #expect(Self.skills.count == 10)
        for skill in Self.skills {
            #expect(!skill.title.isEmpty && !skill.description.isEmpty && !skill.when.isEmpty && !skill.body.isEmpty, "\(skill.name)")
            #expect(AskPilotSkills.draft(picking: skill, over: "") == skill.command + " " + skill.starter)
        }
        let binds = try #require(Self.skills.first { $0.name == "binds" })
        #expect(AskPilotSkills.draft(picking: binds, over: "/bi") == "/binds Suggest Hyper binds for the apps I use most.")
        #expect(AskPilotSkills.draft(picking: binds, over: "Slack on L") == "/binds Slack on L")
        #expect(AskPilotSkills.matching(Self.skills, "se").map(\.name) == ["settings", "preset"])
        #expect(AskPilotSkills.matching(Self.skills, "").count == 10)
        // The steps go in the message, every user turn's, the maker's /extension left to its own turn.
        let request = AIChat.Request(history: [.init(.user, "/binds"), .init(.assistant, "Five keys.")], message: "/settings menu width")
            .skilled(AgentGuidesTests.guides)
        let settings = try #require(Self.skills.first { $0.name == "settings" })
        #expect(request.message.contains("/settings skill") && request.message.contains(settings.body))
        #expect(request.message.hasSuffix("menu width"))
        #expect(request.history[0].text.contains(binds.body) && request.history[1].text == "Five keys.")
        #expect(AIChat.Request(message: "/extension ports").skilled(AgentGuidesTests.guides).message == "/extension ports")
        #expect(AIChat.Request(message: "/bindsx").skilled(AgentGuidesTests.guides).message == "/bindsx")
    }

    @Test("Every provider acts, the makers run wherever Claude Code is installed; the list offers both makers, the placeholder follows")
    func acts() throws {
        #expect(AIPage.makes(.signedIn(path: "/c")) && AIPage.makes(.checking) && !AIPage.makes(.missing))
        #expect(AIPage.placeholder(ready: true) == "Tell Pilot what to change, or pick a skill")
        #expect(AIPage.placeholder(ready: false) == "Ask anything")
        let widget = try #require(Self.skills.first { $0.name == WidgetMaker.skill })
        #expect(widget.title == "Make a widget" && widget.example == "my battery and disk as two meters")
        #expect(AskPilotSkills.draft(picking: widget, over: "") == "/widget ")
        #expect(Self.skills.first { $0.name == ExtensionMaker.skill }?.title == "Make an extension")
    }

    @Test("An API key's provider gets Pilot's tool loop; a subscription its CLI")
    func apiAgent() throws {
        for provider in [AIProvider.anthropicAPI, .ollama] {
            let agent = try #require(try SharedLook.AIRenders.settings(picked: provider).apiAgent(instructions: "Use pilot only.")).get()
            #expect(agent.route.toolProvider == provider && agent.instructions == "Use pilot only.")
        }
        #expect(try SharedLook.AIRenders.settings(picked: .claudeCode).apiAgent() == nil)
        #expect(try SharedLook.AIRenders.settings(picked: .codex).apiAgent() == nil)
    }

    @Test("A plan row's key splits into keycaps, a plus key kept")
    func keycaps() {
        #expect(AIPlanKeycaps.caps("Hyper+L") == ["Hyper", "L"])
        #expect(AIPlanKeycaps.caps("Hyper+Shift+F") == ["Hyper", "Shift", "F"])
        #expect(AIPlanKeycaps.caps("Hyper++") == ["Hyper", "+"])
    }
}
