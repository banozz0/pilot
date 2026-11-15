import Foundation

/// Packaging/pilot-agent-shell's rule, the same expression, for the commands Pilot runs itself (the API keys' loop,
/// AIChat.APIAgent, and Codex's tool, pilot-mcp): one plain `pilot …` call, words of letters, digits and _ . / : = @ % + , -
/// or a "double-quoted" word with no $, ` or \ in it. The script also refuses a single quote; neither form holds one.
/// `command` holds `word` inside it: change both, and the script, together (AIToolLoopTests' parity test runs the script).
public enum AgentGate {
    public static let refusal = "Pilot refused this: only one plain pilot command per call (no ; && | redirects $ ` or quotes ')."
    // Regex is not Sendable; these two are only ever matched against, never changed.
    nonisolated(unsafe) static let command = /^pilot(?: +(?:[A-Za-z0-9_.\/:=@%+,-]+|"[^"$`\\]*"))* *\z/
    nonisolated(unsafe) static let word = /[A-Za-z0-9_.\/:=@%+,-]+|"[^"$`\\]*"/

    /// The words after `pilot`, unquoted, or nil when the gate refuses the line. A line that does not start with
    /// `pilot` is read as one (the model named the tool already); one that does is the gate's to judge as it is.
    public static func words(_ line: String) -> [String]? {
        let line = line.hasPrefix("pilot") ? line : "pilot " + line
        guard line.wholeMatch(of: command) != nil else { return nil }
        return line.dropFirst(5).matches(of: word).map { match in
            let word = match.output
            return word.first == "\"" ? String(word.dropFirst().dropLast()) : String(word)
        }
    }
}

/// The agents' one tool, `pilot`, as every API and MCP names it.
public enum AgentTool {
    public static let name = "pilot"
    public static let description = "Runs one pilot command, the only way to read or change Pilot, and returns its answer. "
        + "One plain command per call: no pipes, ;, &&, redirects, $( ) or other programs."
    public static var schema: [String: Any] { [
        "type": "object",
        "properties": ["command": ["type": "string", "description": "The whole command line, such as pilot get look.theme"]],
        "required": ["command"],
    ] }

    /// What one command hands back, at most this many UTF-8 bytes. Claude Code's shell tool (2.1.325, measured
    /// 2026-11-15 and 16) keeps an answer of up to 30,000 bytes whole and saves a longer one to a file, showing only its
    /// first 2 KB, which an agent allowed nothing but `pilot` can never read: the `pilot` an agent runs (PILOT_AGENT) cuts
    /// first. Its limit counts UTF-8 bytes of what the command printed, not characters: 30,000 ASCII bytes came back whole,
    /// 30,001 went to a file, and so did 10,100 en dashes (10,100 characters, 30,098 bytes). What it wraps around the
    /// output counts too (an "Exit code" line and stderr on a failure; a trailing newline it trims), so the cut keeps
    /// 2,000 bytes clear of it.
    public static let resultLimit = 28_000

    /// `text` whole when it fits `resultLimit`, else its head and its tail around a "… N KB cut …" line: a plan's id, a
    /// summary or an error may sit at either end.
    public static func cut(_ text: String) -> String {
        guard text.utf8.count > resultLimit else { return text }
        let room = resultLimit - 64  // The marker's line.
        var head = text.startIndex, used = 0
        while head < text.endIndex {
            let units = text[head].utf8.count
            guard used + units <= room * 2 / 3 else { break }
            used += units; head = text.index(after: head)
        }
        var tail = text.endIndex
        while tail > head {
            let before = text.index(before: tail), units = text[before].utf8.count
            guard used + units <= room else { break }
            used += units; tail = before
        }
        let kilobytes = max(1, (text[head..<tail].utf8.count + 512) / 1024)
        return String(text[..<head]) + "\n… \(kilobytes) KB cut …\n" + String(text[tail...])
    }

    /// What every `pilot` an agent runs sees, with no shell between: the home folder, the account, the temporary folder
    /// and the language, and PILOT_AGENT, so its changes wait on one plan and one Allow (ControlPlan).
    public static func environment(from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = parent.filter { ["HOME", "USER", "TMPDIR", "LANG"].contains($0.key) }
        environment["PILOT_AGENT"] = "1"
        return environment
    }
}
