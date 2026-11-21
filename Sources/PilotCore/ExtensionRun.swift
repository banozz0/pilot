import Foundation

/// Running an extension command (card agent-bo-95423242, ADR 0010): its program as a direct child through ChildProcess,
/// off the main thread, in its own folder. Pilot writes one JSON line on its stdin, `{"type":"run",...}`, and closes it;
/// the program prints JSON lines on stdout. The child gets a small fixed environment, never Pilot's own, so the link
/// token and any key Pilot was started with stay out of it.
public enum ExtensionRun {
    /// A no-view command may take this long, like a script's network call; then it is stopped.
    public static let noViewTimeout: Duration = .seconds(30)

    /// What a no-view run shows: its HUD line (nil when it said nothing) with its sound, its error message, the actions it
    /// printed in order (and how many past the limit were dropped), a timeout or a failed exit.
    public enum Outcome: Equatable, Sendable {
        case hud(String?, sound: String? = nil), error(String), actions([Extension.Item.Action], dropped: Int = 0), timedOut, failed(String)
    }

    /// The most actions one run may print; the rest are dropped and logged.
    public static let mostActions = 8

    /// One line the program prints; anything else it prints is a plain line.
    private struct Message: Decodable { let type: String, text: String?, sound: String?, action: Extension.Item.Action.Line? }

    /// The child's whole environment: HOME, USER and TMPDIR from Pilot's, PATH with the program's folder and Homebrew's
    /// (launchd's does not reach it) before the system's, LANG, and the extension's id.
    static func environment(for command: Extension.Command, from pilot: [String: String]) -> [String: String] {
        pilot.filter { ["HOME", "USER", "TMPDIR"].contains($0.key) }.merging([
            "PATH": ChildProcess.searchPath(for: command.program.path), "LANG": "en_US.UTF-8", "PILOT_EXTENSION_ID": command.id.extension,
        ]) { _, new in new }
    }

    /// What every run message of an extension carries (card agent-bo-95423246): its preference values by name and its
    /// data and cache folders, never in the program's arguments or environment; and Pilot's own defaults (Surfaces v2:
    /// `repos`, Defaults › Folders › Repos, and `terminal`, the terminal app's bundle id), never a token or a variable.
    public struct Inputs: Equatable, Sendable {
        public let preferences: [String: JSONValue], data: URL, cache: URL
        public var pilot: [String: String]
        public init(preferences: [String: JSONValue], data: URL, cache: URL, pilot: [String: String] = [:]) {
            self.preferences = preferences; self.data = data; self.cache = cache; self.pilot = pilot
        }
    }

    /// The line Pilot writes on the command's stdin; a list's carries the search, a surface's which surface asks (story 161),
    /// a run's the text typed or the answer asked for (`input`, Surfaces v2).
    static func message(_ command: Extension.Command, query: String? = nil, context: JSONValue? = nil,
                        surface: Extension.Surface.Kind? = nil, input: String? = nil, inputs: Inputs) -> Data {
        var fields: [String: JSONValue] = ["type": .string("run"), "extension": .string(command.id.extension), "command": .string(command.name),
                                           "preferences": .object(inputs.preferences),
                                           "paths": .object(["data": .string(inputs.data.path), "cache": .string(inputs.cache.path)])]
        fields["query"] = query.map(JSONValue.string)
        fields["context"] = context
        fields["surface"] = surface.map { .string($0.rawValue) }
        fields["input"] = input.map(JSONValue.string)
        fields["pilot"] = inputs.pilot.isEmpty ? nil : .object(inputs.pilot.mapValues(JSONValue.string))
        return line(fields)
    }

    /// One message as a JSON line, its keys sorted.
    static func line(_ fields: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(fields)) ?? Data()) + Data("\n".utf8)
    }

    /// What the command prints, run to its end; throws ChildProcess's TimedOut or Failure, or CancellationError when cancelled.
    public static func output(_ command: Extension.Command, query: String? = nil, context: JSONValue? = nil,
                              surface: Extension.Surface.Kind? = nil, input: String? = nil, inputs: Inputs,
                              environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration = noViewTimeout) async throws -> String {
        try await ChildProcess.run(command.program.path, [], environment: environment(for: command, from: pilot),
                                   input: message(command, query: query, context: context, surface: surface, input: input, inputs: inputs),
                                   directory: command.program.deletingLastPathComponent(), timeout: timeout)
    }

    /// Runs a no-view command and says what it showed.
    public static func noView(_ command: Extension.Command, context: JSONValue? = nil, input: String? = nil, inputs: Inputs,
                              environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration = noViewTimeout) async -> Outcome {
        do { return outcome(of: try await output(command, context: context, input: input, inputs: inputs, environment: pilot, timeout: timeout)) }
        catch is ChildProcess.TimedOut { return .timedOut }
        catch {
            return .failed(String(((error as? ChildProcess.Failure)?.message ?? error.localizedDescription).prefix(200)))
        }
    }

    /// The first error message; else every action message in printed order, the first eight; else the last HUD message
    /// with its sound; else the last plain line, as a script's; else nothing. A message of a type Pilot does not know is
    /// skipped.
    public static func outcome(of output: String) -> Outcome {
        var hud: String?, sound: String?, actions: [Extension.Item.Action] = [], plain: [Substring] = []
        let decoder = JSONDecoder()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "{", let message = try? decoder.decode(Message.self, from: Data(line.utf8)) else {
                plain.append(line)
                continue
            }
            switch message.type {
            case "error": return .error(message.text ?? "")
            case "hud": (hud, sound) = (message.text, Extension.sound(message.sound))
            case "action":
                guard let known = message.action.flatMap(Extension.Item.Action.init) else { return .error("sent an action Pilot does not know") }
                actions.append(known)
            default: continue
            }
        }
        if !actions.isEmpty { return .actions(Array(actions.prefix(mostActions)), dropped: max(actions.count - mostActions, 0)) }
        if let hud { return .hud(hud, sound: sound) }
        return .hud(ScriptCommand.lastLine(plain.joined(separator: "\n")))
    }
}
