import Foundation

/// One GitHub user's contribution calendar (P82, Sven Q726/Q728), as GitHub's GraphQL API answers it through the GitHub
/// CLI (`gh api graphql`, run by Pilot as a child): the year's total and Sunday-first weeks of days, each its count and
/// GitHub's own level (none, then its four quartiles). Pure: parsing, the gh call's words, its failures, the weeks' levels.
/// Pilot never reads or keeps gh's token; gh signs its own request.
public struct GitHubContributions: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        /// `2026-11-01`, as GitHub dates it; `weekday` 0 is Sunday; `level` 0 to 4.
        public let date: String, weekday: Int, count: Int, level: Int
        public init(date: String, weekday: Int, count: Int, level: Int) {
            self.date = date; self.weekday = weekday; self.count = count; self.level = level
        }
    }

    public let login: String
    public let total: Int
    /// Oldest first; the first and the last may be short: the last ends today.
    public let weeks: [[Day]]
    /// When gh answered it.
    public let read: Date

    public init(login: String, total: Int, weeks: [[Day]], read: Date) {
        self.login = login; self.total = total; self.weeks = weeks; self.read = read
    }

    /// Why there is no fresh calendar, each with the line a tile shows and how to fix it.
    public enum Failure: Error, Equatable, Sendable {
        case missing, loggedOut, noUser(String), badLogin(String), failed(String)

        public var line: String {
            switch self {
            case .missing: "The GitHub CLI (gh) is not installed"
            case .loggedOut: "gh is not signed in to GitHub"
            case .noUser(let name): "No GitHub user \(name)"
            case .badLogin(let name): "\(name) is not a GitHub user name"
            case .failed: "GitHub did not answer"
            }
        }

        public var fix: String {
            switch self {
            case .missing: "brew install gh, then gh auth login"
            case .loggedOut: "Run gh auth login in a terminal"
            case .noUser, .badLogin: "Pick another user in Edit widget"
            case .failed(let said): said
            }
        }

        /// What a non-zero gh exit means, from its status and what it printed.
        public init(status: Int32, said: String, user: String) {
            if said.contains("Could not resolve to a User") { self = .noUser(user) }
            else if status == 4 || said.contains("gh auth login") || said.contains("HTTP 401") { self = .loggedOut }
            else { self = .failed(String(said.split(separator: "\n").first ?? "gh exited \(status)").prefix(120).description) }
        }
    }

    /// A GitHub login: letters, digits and single hyphens, not at an end, at most 39.
    public static func isLogin(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 39 && !s.hasPrefix("-") && !s.hasSuffix("-") && !s.contains("--")
            && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private static let calendar = "contributionsCollection{contributionCalendar{totalContributions weeks{contributionDays{date contributionCount contributionLevel weekday}}}}"

    /// gh's words for `user`'s calendar, or the signed-in user's when it is empty: the login goes as a GraphQL variable
    /// (`-f`, a string as typed), never into the query's text.
    public static func arguments(user: String) -> [String] {
        user.isEmpty ? ["api", "graphql", "-f", "query=query{viewer{login \(calendar)}}"]
            : ["api", "graphql", "-f", "query=query($login:String!){user(login:$login){login \(calendar)}}", "-f", "login=\(user)"]
    }

    private static let levels = ["NONE": 0, "FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4]

    /// gh's answer; nil when it is not a calendar.
    public init?(answer: Data, read: Date) {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: answer),
              case .object(let data)? = root["data"], case .object(let user)? = data["user"] ?? data["viewer"],
              case .string(let login)? = user["login"], case .object(let collection)? = user["contributionsCollection"],
              case .object(let cal)? = collection["contributionCalendar"], case .number(let total)? = cal["totalContributions"],
              case .array(let weeks)? = cal["weeks"] else { return nil }
        let days = weeks.map { week -> [Day] in
            guard case .object(let w) = week, case .array(let days)? = w["contributionDays"] else { return [] }
            return days.compactMap { day in
                guard case .object(let d) = day, case .string(let date)? = d["date"], case .number(let count)? = d["contributionCount"],
                      case .number(let weekday)? = d["weekday"], (0...6).contains(Int(weekday)) else { return nil }
                let level = d["contributionLevel"]?.string.flatMap { Self.levels[$0] } ?? (count > 0 ? 1 : 0)
                return Day(date: date, weekday: Int(weekday), count: Int(count), level: level)
            }
        }.filter { !$0.isEmpty }
        self.init(login: login, total: Int(total), weeks: days, read: read)
    }

    /// Each week's level by its total, against the busiest week: a Strip's one row of recent weeks.
    public static func weekLevels(_ weeks: [[Day]]) -> [Int] {
        let totals = weeks.map { $0.reduce(0) { $0 + $1.count } }
        guard let most = totals.max(), most > 0 else { return totals.map { _ in 0 } }
        return totals.map { $0 == 0 ? 0 : min(4, max(1, Int((4 * Double($0) / Double(most)).rounded(.up)))) }
    }

    /// "Jan" for a week starting in a new month within its first week, at each week's index: the Large grid's months.
    public static func months(_ weeks: [[Day]]) -> [(week: Int, name: String)] {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var out: [(Int, String)] = [], last: Int?
        for (i, week) in weeks.enumerated() {
            guard let first = week.first else { continue }
            let parts = first.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1...12).contains(parts[1]) else { continue }
            if parts[1] != last, parts[2] <= 7, out.last.map({ i - $0.0 >= 3 }) ?? true { out.append((i, names[parts[1] - 1])) }
            last = parts[1]
        }
        return out
    }
}
