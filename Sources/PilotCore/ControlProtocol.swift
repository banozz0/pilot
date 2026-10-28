import Foundation

/// The control socket's wire format (ADR 0013): one JSON object per line each way. A request names a verb and carries
/// the pilot command's words as they were typed; the answer is its result or a typed error. It only grows: a new verb,
/// field or code is added, an old one never changes meaning.
public enum ControlLine {
    /// A longer line is refused and its connection closed.
    public static let maxBytes = 1 << 20

    /// One request line, without its newline.
    public static func request(_ line: Data) throws(ControlError) -> ControlRequest {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            throw ControlError(.badRequest, "not a request: expected {\"verb\":…,\"args\":[…]} on one line")
        }
        return request
    }

    /// One answer line, its newline included. A result JSON cannot hold (a NaN or infinite number) answers bad-value
    /// under the request's id instead.
    public static func encode(_ answer: ControlAnswer) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = (try? encoder.encode(answer))
            ?? (try? encoder.encode(ControlAnswer.failure(answer.id, ControlError(.badValue, "answer is not JSON"))))
            ?? Data(#"{"error":{"code":"bad-value","message":"answer is not JSON"},"ok":false}"#.utf8)
        line.append(0x0A)
        return line
    }
}

/// `{"id":…,"verb":…,"args":[…],"cwd":…,"secret":…}`: the id comes back as sent, args are the command's words after the verb.
public struct ControlRequest: Codable, Equatable, Sendable {
    public var id: JSONValue?
    public var verb: String
    public var args: [String]
    /// The caller's working directory, for verbs that take a relative path.
    public var cwd: String?
    /// What the command read from its stdin for `--stdin` (`pbpaste | pilot set ai.key.openAI --stdin`): a secret kept
    /// out of args, so no message, prompt or log line built from the words can carry it. Nothing answers or logs it.
    public var secret: String?
    /// Sent by a `pilot` that Pilot's AI agent ran (PILOT_AGENT in AIChat.Agent.environment): its changes are planned,
    /// never applied unasked (ControlPlan). The agent's shell gate lets no command set it.
    public var agent: Bool?

    public init(id: JSONValue? = nil, verb: String, args: [String] = [], cwd: String? = nil, secret: String? = nil, agent: Bool? = nil) {
        self.id = id; self.verb = verb; self.args = args; self.cwd = cwd; self.secret = secret; self.agent = agent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(JSONValue.self, forKey: .id)
        verb = try c.decode(String.self, forKey: .verb)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        agent = try c.decodeIfPresent(Bool.self, forKey: .agent)
    }
}

/// `{"id":…,"ok":true,"result":…}` or `{"id":…,"ok":false,"error":{"code":…,"message":…}}`.
public struct ControlAnswer: Codable, Equatable, Sendable {
    public var id: JSONValue?
    public var ok: Bool
    public var result: JSONValue?
    public var error: ControlError?

    public static func success(_ id: JSONValue?, _ result: JSONValue) -> ControlAnswer { ControlAnswer(id: id, ok: true, result: result) }
    public static func failure(_ id: JSONValue?, _ error: ControlError) -> ControlAnswer { ControlAnswer(id: id, ok: false, error: error) }
}

/// A typed failure: what every verb throws and the command prints on stderr.
public struct ControlError: Error, Codable, Equatable, Sendable {
    /// ADR 0013's codes. `not-running` is the command's own; Pilot never sends it.
    public struct Code: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let badRequest = Code(rawValue: "bad-request")
        public static let unknownVerb = Code(rawValue: "unknown-verb")
        public static let unknownAction = Code(rawValue: "unknown-action")
        public static let unknownKey = Code(rawValue: "unknown-key")
        public static let badValue = Code(rawValue: "bad-value")
        public static let outOfRange = Code(rawValue: "out-of-range")
        public static let taken = Code(rawValue: "taken")
        public static let denied = Code(rawValue: "denied")
        public static let keychainOnly = Code(rawValue: "keychain-only")
        public static let timeout = Code(rawValue: "timeout")
        /// A flag the verb, or the collection's add, does not take.
        public static let unknownFlag = Code(rawValue: "unknown-flag")
        public static let unknownCollection = Code(rawValue: "unknown-collection")
        public static let unknownPage = Code(rawValue: "unknown-page")
        public static let unknownSection = Code(rawValue: "unknown-section")
        public static let unknownModule = Code(rawValue: "unknown-module")
        public static let unknownPreset = Code(rawValue: "unknown-preset")
        /// A collection with no add or no remove.
        public static let readOnly = Code(rawValue: "read-only")
        /// What the verb needs is not up yet (the key engine, the workspaces); asking again later may work.
        public static let notReady = Code(rawValue: "not-ready")
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

/// The command's words after the verb: positional words, `--flag value`, `--flag=value` and bare `--flag` switches;
/// after `--` every word is positional. A flag takes the next word as its value unless it is one of `switches` or the
/// next word is itself a flag.
public struct ControlArguments: Equatable, Sendable {
    public private(set) var positional: [String] = []
    public private(set) var values: [String: String] = [:]
    public private(set) var switches: Set<String> = []

    public init(_ words: [String], switches known: Set<String> = []) {
        var rest = words[...]
        while let word = rest.popFirst() {
            guard word.hasPrefix("--"), word.count > 2 else {
                if word == "--" { positional += rest; return }
                positional.append(word); continue
            }
            let flag = word.dropFirst(2)
            if let eq = flag.firstIndex(of: "=") {
                values[String(flag[..<eq])] = String(flag[flag.index(after: eq)...])
            } else if !known.contains(String(flag)), let next = rest.first, !next.hasPrefix("--") {
                values[String(flag)] = next; rest = rest.dropFirst()
            } else {
                switches.insert(String(flag))
            }
        }
    }

    /// The positional word at `index`, or bad-request naming what is missing.
    public func word(_ index: Int, _ name: String) throws(ControlError) -> String {
        guard positional.indices.contains(index) else { throw ControlError(.badRequest, "missing \(name)") }
        return positional[index]
    }

    /// Every flag given, with a value or bare.
    public var flags: Set<String> { switches.union(values.keys) }

    public func value(_ flag: String) -> String? { values[flag] }

    /// A flag's value, or bad-request when it is bare.
    public func required(_ flag: String) throws(ControlError) -> String {
        guard let value = values[flag] else { throw ControlError(.badRequest, "--\(flag) needs a value") }
        return value
    }
    public func has(_ flag: String) -> Bool { switches.contains(flag) || values[flag] != nil }
}
