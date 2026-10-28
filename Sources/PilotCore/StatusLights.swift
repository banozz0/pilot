import Foundation

/// One lit source of the Status lights item (Sven, 2026-10-16, Q194-Q196, Q201, Q202; design
/// /scratchpad/status-lights.html, direction A): an agent working, waiting on Sven or done, an app holding the
/// microphone or camera, Pilot recording, a download or a build. A quiet source has no light at all.
public struct StatusLight: Equatable, Sendable, Identifiable {
    /// The three families, each with its own slots around the Pilot mark; the popover lists them in this order.
    public enum Family: Int, CaseIterable, Sendable {
        case agent, privacy, job

        public var title: String {
            switch self {
            case .agent: "Agents"
            case .privacy: "Privacy"
            case .job: "Jobs"
            }
        }
    }

    /// Most urgent first: a family's slots and the popover's rows take them in this order.
    public enum State: Int, Comparable, Sendable {
        case waiting, error, watching, working, done

        public var word: String {
            switch self {
            case .waiting: "waiting on you"
            case .error: "failed"
            case .watching: "in use"
            case .working: "working"
            case .done: "done"
            }
        }

        /// A `pilot light` word: working, waiting, done, error; clear is nil.
        public static let words: [String: State?] = ["working": .working, "waiting": .waiting, "done": .done, "error": .error, "clear": nil]

        public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    /// How long a done light stays lit when the popover never shows it.
    public static let doneFor: TimeInterval = 600

    public let id: String
    public var family: Family
    public var state: State
    /// Who: the agent's session, the app holding the microphone, the file being downloaded, the command.
    public var title: String
    /// Where it comes from: "Ghostex · pilot", "microphone", "Safari".
    public var source: String
    /// Its context: what the agent says it is doing, the input muted, a build's exit code.
    public var detail: String?
    public var jump: StatusJump

    public init(id: String, family: Family, state: State, title: String, source: String, detail: String? = nil, jump: StatusJump = .none) {
        self.id = id; self.family = family; self.state = state; self.title = title; self.source = source
        self.detail = detail; self.jump = jump
    }

    /// The row's action, as the popover words it; nil where a click goes nowhere.
    public var go: String? {
        switch jump {
        case .ghostex: "Open chat"
        case .app: "Show"
        case .file: "Show in Finder"
        case .settings: "Settings"
        case .none: nil
        }
    }
}

/// Where a light's row takes Sven: the agent's Ghostex session, the app holding the microphone, a download in Finder,
/// a Settings pane.
public enum StatusJump: Equatable, Sendable {
    /// A Ghostex session, by its global ref (`ghostex focus <ref>`).
    case ghostex(String)
    /// A running app, by its name as the light shows it.
    case app(String)
    case file(URL)
    /// A System Settings pane, by its id.
    case settings(String)
    case none
}

/// The Status lights item: only coloured dots in a row (Sven, Q205: no Pilot mark), nothing at all while none is lit.
/// Agents first, then privacy, then jobs; a family's most urgent lights take its dots and the rest fold into the popover.
public enum StatusDots {
    /// Each family's most dots, so the item never grows past eight.
    public static func most(_ family: StatusLight.Family) -> Int {
        switch family {
        case .agent, .privacy: 3
        case .job: 2
        }
    }
    /// The unlit dots the Menu bar page's strip draws while none is lit, so the item can be found there.
    public static let quiet = 3
    /// A dot, and the box each sits in: room for waiting's breath to 1.5 times the dot, so the dots stand 4 pt apart.
    public static let dot: Double = 6
    public static let box: Double = 10

    /// The dots the item draws, left to right: per family the most urgent first, at most its share.
    public static func shown(_ lights: [StatusLight]) -> [StatusLight] {
        groups(lights).flatMap { $0.lights.prefix(most($0.family)) }
    }

    /// Most urgent first; the same state keeps its order.
    public static func ranked(_ lights: [StatusLight]) -> [StatusLight] {
        lights.enumerated().sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }.map(\.element)
    }

    /// The popover's groups: each lit family in order, its lights most urgent first.
    public static func groups(_ lights: [StatusLight]) -> [(family: StatusLight.Family, lights: [StatusLight])] {
        StatusLight.Family.allCases.compactMap { family in
            let mine = ranked(lights.filter { $0.family == family })
            return mine.isEmpty ? nil : (family, mine)
        }
    }

    /// The item's tooltip and spoken label: "Status lights: nothing lit" or "1 waiting on you, 2 working".
    public static func summary(_ lights: [StatusLight]) -> String {
        guard !lights.isEmpty else { return "Status lights: nothing lit" }
        let counts = Dictionary(grouping: lights, by: \.state).sorted { $0.key < $1.key }
        return counts.map { "\($0.value.count) \($0.key.word)" }.joined(separator: ", ")
    }
}

/// The agents' lights from Ghostex's own session list (`ghostex sessions --json --full`): each running agent session is
/// working, waiting on Sven (a session of his own with its turn ended or a question open), done (a thread that
/// finished, or any session whose status says done, for ten minutes) or failed. A coordinator's thread never waits on
/// Sven: its coordinator answers it.
public enum GhostexAgents {
    public static func lights(_ json: Data, now: Date = Date()) -> [StatusLight] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]] else { return [] }
        return sessions.compactMap { light($0, now: now) }
    }

    static func light(_ s: [String: Any], now: Date) -> StatusLight? {
        guard s["status"] as? String == "running", s["agentName"] is String, let ref = s["globalRef"] as? String else { return nil }
        let activity = s["activity"] as? String
        let status = s["programStatus"] as? [String: Any]
        let said = status?["state"] as? String
        let updated = (status?["records"] as? [[String: Any]])?.compactMap { $0["updatedAtMs"] as? Double }.max()
        let thread = s["coordinatorRole"] as? String == "thread"
        let asks = (s["pendingQuestionCount"] as? Int ?? 0) > 0 || activity == "attention"
        let state: StatusLight.State
        if ["error", "failed", "blocked"].contains(said) && activity != "working" {
            state = .error
        } else if activity == "working" {
            state = .working
        } else if asks && !thread {
            state = .waiting
        } else if asks || (said == "done" && updated.map { now.timeIntervalSince1970 - $0 / 1000 < StatusLight.doneFor } ?? false) {
            state = .done
        } else {
            return nil
        }
        let title = (s["displayTitle"] as? String) ?? (s["title"] as? String) ?? "Agent"
        let project = s["projectName"] as? String
        // A done or failed light is one ending: the id carries its time, so a seen one never comes back lit.
        let id = state == .done || state == .error ? "agent.\(ref)@\(Int(updated ?? 0))" : "agent.\(ref)"
        return StatusLight(id: id, family: .agent, state: state, title: title,
                           source: ["Ghostex", project].compactMap(\.self).joined(separator: " · "),
                           detail: (status?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }, jump: .ghostex(ref))
    }
}

/// One download in ~/Downloads, by its partial file (Safari's .download, Chrome's .crdownload, Firefox's .part): working
/// while it is there, done once its file has its own name.
public enum Downloads {
    public static let partials: Set<String> = ["download", "crdownload", "part"]

    /// The file a partial becomes: "Xcode.xip.download" is "Xcode.xip"; nil for a file that is not one.
    public static func final(_ name: String) -> String? {
        let name = name as NSString
        return partials.contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : nil
    }

    /// Safari's and Chrome's own names for the browser behind a partial.
    public static func source(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "download": "Safari"
        case "crdownload": "Chrome"
        default: "Firefox"
        }
    }
}
