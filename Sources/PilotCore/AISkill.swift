import Foundation

/// One job Pilot's AI knows how to do (P29, Sven Q268–Q271, 2026-10-18): Packaging/skills/<name>/SKILL.md, a short
/// header (its name, the list's title and line, when the AI reads it, its icon and the starter a pick puts in the chat
/// box, and an example where the starter is empty) over its body, the steps the AI follows. Typed or picked as `/<name>` at the start of a message, its body goes
/// with that message on every provider (AIChat.Request.skilled); `pilot guide <name>` reads it otherwise.
public struct AISkill: Equatable, Sendable, Identifiable {
    public let name, title, description, when, symbol, starter, body: String
    /// What the list shows as the example of using it: the starter, else the header's `example` (/extension's idea).
    public let example: String
    public var id: String { name }
    /// What the chat box starts with: `/binds`.
    public var command: String { "/" + name }

    /// A SKILL.md's text: `---`, one `key: value` a line (a value in double quotes keeps its spaces), `---`, the body.
    public init?(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            fields[String(line[..<colon])] = value
        }
        guard let name = fields["name"], !name.isEmpty else { return nil }
        self.name = name
        title = fields["title"] ?? name
        description = fields["description"] ?? ""
        when = fields["when"] ?? ""
        symbol = fields["symbol"] ?? "sparkles"
        starter = fields["starter"] ?? ""
        example = fields["example"] ?? starter
        body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What follows `command` at the start of `message`, trimmed; nil when the message does not start with it as a word.
    public static func words(after command: String, in message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(command) else { return nil }
        let rest = text.dropFirst(command.count)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `message` as the AI gets it when it starts with this skill's command: the skill's steps, then the user's words.
    public func message(_ message: String) -> String? {
        guard let words = Self.words(after: command, in: message) else { return nil }
        return "The user picked Pilot's \(command) skill for this message. Follow its steps:\n\n\(body)\n\n"
            + "The user's message:\n\n\(words.isEmpty ? "(none: start the job)" : words)"
    }
}

extension AIChat.Request {
    /// The request with each of the user's messages that starts with one of `skills`' commands carrying that skill's
    /// steps (P29). In the message, not the system prompt: claude and codex keep a session's first prompt, so a skill
    /// picked on a later turn would never reach them; an API is sent the history, so an earlier pick's steps go again.
    public func skilled(_ skills: [AISkill]) -> Self {
        func expand(_ text: String) -> String { skills.lazy.compactMap { $0.message(text) }.first ?? text }
        var out = self
        out.message = expand(message)
        out.history = history.map { turn in
            var turn = turn
            if turn.role == .user { turn.text = expand(turn.text) }
            return turn
        }
        return out
    }
}
