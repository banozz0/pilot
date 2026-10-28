import Foundation

/// Send feedback (story 136, card agent-bo-95423195): a new GitHub issue on Pilot's own repo, opened on its issue form
/// (.github/ISSUE_TEMPLATE, whose label applies for anyone) with the title and the form's Mac field in the link, so there
/// is no token and no server. The field carries only the facts a fix needs, and a report the AI wrote (P48) its title,
/// what happened and the steps; logs are the person's to paste, and neither their user name nor their home folder ever
/// reaches the link.
public enum Feedback {
    public enum Kind: String, CaseIterable, Sendable {
        case bug, idea

        /// The menu row and the action's label, the action's id and the issue's title; the form is `<rawValue>.yml`.
        var parts: (label: String, actionID: String, title: String) {
            switch self {
            case .bug: ("Report a bug", "engine.reportBug", "Bug: ")
            case .idea: ("Suggest an idea", "engine.suggestIdea", "Idea: ")
            }
        }
        public var label: String { parts.label }
        public var actionID: String { parts.actionID }
    }

    /// What the form's mac field says about this Mac and this Pilot, each fact as read.
    public struct Facts: Sendable {
        public var version, macOS, model, layerKey, look, tiler: String
        public init(version: String, macOS: String, model: String, layerKey: String, look: String, tiler: String) {
            self.version = version; self.macOS = macOS; self.model = model; self.layerKey = layerKey; self.look = look; self.tiler = tiler
        }
    }

    public static let newIssue = "https://github.com/banozz0/pilot/issues/new"
    /// The id of the field both forms share for the facts.
    public static let field = "mac"
    /// Well under the roughly 8 KB GitHub and browsers take in a link.
    public static let maxLength = 8000
    /// Any one fact longer than this is cut, which keeps the whole link under `maxLength`: six facts of 80 four-byte
    /// characters encode to 5760, and the rest of the link is under 1000.
    static let factLength = 80

    /// What a bug report already knows (P48: /troubleshoot's Report it): its title, what happened (the form's `what`) and
    /// the steps to see it again (`steps`), as the AI wrote them; scrubbed like the facts, and cut to keep the link whole.
    public struct Report: Sendable {
        public var title, what, steps: String
        public init(title: String, what: String, steps: String = "") { self.title = title; self.what = what; self.steps = steps }
    }

    public static func url(_ kind: Kind, facts: Facts, report: Report? = nil, userName: String = NSUserName()) -> URL {
        let lines = [("Pilot", facts.version), ("macOS", facts.macOS), ("Mac", facts.model), ("Layer key", facts.layerKey),
                     ("Look", facts.look), ("Tiler", facts.tiler)]
            .map { "- \($0): \(scrub(String($1.prefix(factLength)), userName: userName))" }
        let mac = lines.joined(separator: "\n") + "\n\nLogs help: paste any you want to share yourself. Pilot never sends them."
        func link(_ title: String, _ what: String, _ steps: String) -> URL {
            let query = [("template", "\(kind.rawValue).yml"), ("title", kind.parts.title + title), ("what", what), ("steps", steps), (field, mac)]
                .filter { !$0.1.isEmpty || $0.0 == "title" }
                .map { "\($0)=\(encode($1))" }.joined(separator: "&")
            return URL(string: "\(newIssue)?\(query)")!
        }
        guard let report else { return link("", "", "") }
        // The facts leave over 6000 of the link's 8000: the report's words are cut, longest first, until it fits.
        var (title, what, steps) = (scrub(String(report.title.prefix(factLength)), userName: userName),
                                    scrub(report.what, userName: userName), scrub(report.steps, userName: userName))
        while link(title, what, steps).absoluteString.count > maxLength {
            if what.count >= steps.count { what = String(what.prefix(what.count * 4 / 5)) + "…" }
            else { steps = String(steps.prefix(steps.count * 4 / 5)) + "…" }
        }
        return link(title, what, steps)
    }

    /// Every character but the unreserved ones percent-encoded, so &, +, # and = in a fact stay text.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A home folder path or the user name, in any case, becomes "…".
    private static func scrub(_ fact: String, userName: String) -> String {
        var fact = fact.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
        if !userName.isEmpty { fact = fact.replacingOccurrences(of: userName, with: "…", options: .caseInsensitive) }
        return fact
    }
}
