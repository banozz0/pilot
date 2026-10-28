import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// Ask AI about a capture (story 191): a chat turn carries a picture to every route, the shapes each takes checked
/// offline: claude's stream-json message, codex's `--image` file, the Messages API's image block and Chat Completions'
/// data URL. Nothing runs a CLI or touches the network.
@Suite("AI chat pictures")
struct AIChatImageTests {
    static let picture = AIChat.Image(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The picture rides with its turn into the history an API is sent again")
    func history() {
        var chat = AIChat.Conversation()
        let first = chat.send("what is this error", image: Self.picture)
        #expect(first.image == Self.picture)
        #expect(first.turns.last?.image == Self.picture)
        chat.answered(AIChat.Reply("a missing file"))
        let next = chat.send("and the fix?")
        #expect(next.image == nil)
        #expect(next.turns.map(\.image) == [Self.picture, nil, nil])
    }

    @Test("claude's stream-json message is one line: the image block, then the text")
    func claudeMessage() throws {
        let data = QuickAI.message("Explain this", image: Self.picture)
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(!data.dropLast().contains(UInt8(ascii: "\n")))
        let line = try Self.json(data)
        #expect(line["type"] as? String == "user")
        let message = try #require(line["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64" && source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Self.picture.base64)
        #expect(content[1]["text"] as? String == "Explain this")
        #expect(QuickAI.chatArguments(session: nil, picture: true).suffix(2) == ["--input-format", "stream-json"])
        #expect(!QuickAI.chatArguments(session: nil).contains("--input-format"))
    }

    @Test("The Messages API gets an image block before the text; a turn without one stays a string")
    func anthropic() throws {
        let turns = [AIChat.Turn(.user, "what is this", image: Self.picture), AIChat.Turn(.assistant, "a dialog"), AIChat.Turn(.user, "translate it")]
        let body = AnthropicAPI.body(system: "s", turns: turns, model: AIModelChoice("claude-haiku-4-5", "Haiku 4.5", effort: false))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(first.map { $0["type"] as? String } == ["image", "text"])
        #expect((first[0]["source"] as? [String: Any])?["data"] as? String == Self.picture.base64)
        #expect(messages[1]["content"] as? String == "a dialog")
        #expect(messages[2]["content"] as? String == "translate it")
    }

    @Test("Chat Completions gets the text, then the picture as a data URL, on every OpenAI-shaped provider")
    func openAI() throws {
        for provider in [AIProvider.openAI, .ollama, .openAICompatible] {
            let body = OpenAIChat.body(system: "s", turns: [AIChat.Turn(.user, "read it", image: Self.picture)], model: "m", provider: provider)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages[0]["content"] as? String == "s")
            let content = try #require(messages[1]["content"] as? [[String: Any]])
            #expect(content.map { $0["type"] as? String } == ["text", "image_url"])
            #expect((content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64," + Self.picture.base64)
        }
        let plain = OpenAIChat.body(system: "s", turns: [AIChat.Turn(.user, "hi")], model: "m", provider: .openAI)
        #expect((plain["messages"] as? [[String: Any]])?[1]["content"] as? String == "hi")
    }

    @Test("codex takes the picture through --image, before the prompt, and the file goes once the turn ends")
    func codex() async throws {
        let seen = Mutex<(arguments: [String], existed: Bool)>(([], false))
        let codex = PlanCLI(.codex, path: "/opt/homebrew/bin/codex", spawn: { _, arguments, _, _, _, line in
            let file = arguments.firstIndex(of: "--image").map { arguments[$0 + 1] }
            seen.withLock { $0 = (arguments, file.map { FileManager.default.fileExists(atPath: $0) } ?? false) }
            [#"{"type":"thread.started","thread_id":"t1"}"#,
             #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"ENOENT"}}"#,
             #"{"type":"turn.completed"}"#].forEach(line)
            return ""
        })
        let reply = try await codex.chat(AIChat.Request(message: "what does it say", image: Self.picture)) { _ in }
        #expect(reply.answer == "ENOENT")
        let (arguments, existed) = seen.withLock { $0 }
        #expect(Array(arguments.prefix(3)) == ["exec", "--json", "--image"])
        #expect(existed)
        let file = arguments[3]
        #expect(file.hasSuffix(".png"))
        #expect(!FileManager.default.fileExists(atPath: file))
        // A follow-up resumes the thread; a plain message carries no file.
        #expect(!PlanCLI.chatArguments(.codex, session: "t1").contains("--image"))
        #expect(PlanCLI.chatArguments(.codex, session: "t1", image: "/tmp/p.png").prefix(5) == ["exec", "resume", "--json", "--image", "/tmp/p.png"])
    }

    @Test("The capture's starters name the Mac's language for Translate")
    func starters() {
        let starters = AIChat.Starter.capture(language: "Spanish")
        #expect(starters.map(\.title) == ["Explain this error", "Translate", "Extract text"])
        #expect(starters[1].prompt.contains("into Spanish"))
        #expect(AIChat.Starter.language(Locale(identifier: "es_CO")) == "Spanish")
        #expect(AIChat.Starter.language(Locale(identifier: "en_MT")) == "English")
    }
}
