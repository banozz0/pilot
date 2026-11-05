import Foundation
import OSLog
import PilotCore

private let ciLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// GitHub checks, the CI widget's data (`"data": {"ci": true}`, P79, Sven Q773): each repo's latest GitHub Actions run,
/// passing, failing or running, drawn by Pilot as blocks; a repo with no Actions runs is left out (T43). The repos are the
/// GitHub extension's "Only these owners or repos" (an owner keeps ~/code's repos whose origin it owns), else every ~/code
/// repo with a GitHub origin. Read by `gh run list` in children, four at a time, off the main thread, never with a token
/// Pilot reads: when a placement shows and again only once the last read is 5 minutes old, while one does; a repo gh
/// found no runs in is asked again only hourly. One read serves every placement; the Widgets page's preview shows
/// the last read alone and runs nothing.
@MainActor
enum WidgetCI {
    static let every: Duration = .seconds(300)
    /// How often a repo with no Actions runs is asked again.
    static let emptyEvery: Duration = .seconds(3600)
    nonisolated static let timeout: Duration = .seconds(20)

    /// A repo's latest run, or why there is none.
    struct Run: Equatable, Sendable {
        enum State: Equatable, Sendable { case passing, failing, running, other(String) }
        let repo: String
        var state: State?
        var workflow: String?, branch: String?, url: String?
        var problem: String?
    }

    private static var last: (at: ContinuousClock.Instant, runs: [Run])?
    private static var reading: Task<[Run], Never>?
    /// When gh last found no runs in a repo: it is left unread until that is an hour old.
    private static var emptyAt: [String: ContinuousClock.Instant] = [:]

    /// The last read while it is younger than 5 minutes, else a new one, shared with any read under way. A repo with no
    /// runs an hour ago or less keeps that answer and runs no gh.
    static func read() async -> [Run] {
        if let last, ContinuousClock.now - last.at < every { return last.runs }
        if let reading { return await reading.value }
        let now = ContinuousClock.now
        let quiet = Set(emptyAt.filter { now - $0.value < emptyEvery }.keys)
        let task = Task.detached(priority: .utility) { [home = ConfigsModule.home] in
            let all = repos(home: home)
            let read = Dictionary(await fetch(all.filter { !quiet.contains($0) }).map { ($0.repo, $0) }, uniquingKeysWith: { first, _ in first })
            return all.map { read[$0] ?? Run(repo: $0, problem: noRuns) }
        }
        reading = task
        let runs = await task.value
        emptyAt = Dictionary(runs.compactMap { run in
            quiet.contains(run.repo) ? emptyAt[run.repo].map { (run.repo, $0) } : run.problem == noRuns ? (run.repo, now) : nil
        }, uniquingKeysWith: { first, _ in first })
        (last, reading) = ((.now, runs), nil)
        return runs
    }

    /// How long a placement's feed sleeps before its next read: until the last read is 5 minutes old.
    static func wait() -> Duration {
        guard let last else { return every }
        return max(every - (ContinuousClock.now - last.at), .seconds(1))
    }

    /// The Widgets page's look: the last read, or a line, with nothing run.
    static func preview() -> [Extension.Block] {
        last.map { blocks($0.runs) } ?? [.note(.init(text: "Read by gh once placed", icon: "info"))]
    }

    // MARK: Which repos

    /// The `owner/repo` names to read: the GitHub extension's `only` setting's repos, then ~/code's GitHub repos its
    /// owners own; with no such setting, every ~/code repo with a GitHub origin. Sorted, no repeats.
    nonisolated static func repos(home: URL) -> [String] {
        let github = Extension.find().extensions.first { $0.id == "github" }
        let only = github.flatMap { ExtensionStorage().values(of: $0)["only"]?.string } ?? ""
        let local = Repos.list(home: home).compactMap { origin(of: $0.url) }
        return pick(only: only, local: local)
    }

    /// `only`'s words (commas or spaces between): an `owner/repo` is read as is, an owner keeps the local repos it owns;
    /// none keeps every local one.
    nonisolated static func pick(only: String, local: [String]) -> [String] {
        let words = only.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@/")) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return Array(Set(local)).sorted { $0.lowercased() < $1.lowercased() } }
        let named = words.filter { $0.contains("/") }, owners = Set(words.filter { !$0.contains("/") }.map { $0.lowercased() })
        let owned = local.filter { owners.contains($0.split(separator: "/").first.map { $0.lowercased() } ?? "") }
        var seen = Set<String>()
        return (named + owned).filter { seen.insert($0.lowercased()).inserted }.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The `owner/repo` of a repo's origin on github.com, read from its `.git/config`, no git run.
    nonisolated static func origin(of repo: URL) -> String? {
        guard let config = try? String(contentsOf: repo.appending(path: ".git/config"), encoding: .utf8) else { return nil }
        return origin(config: config)
    }

    nonisolated static func origin(config: String) -> String? {
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == #"[remote "origin"]"#; continue }
            guard inOrigin, line.hasPrefix("url"), let equals = line.firstIndex(of: "=") else { continue }
            let url = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let match = url.firstMatch(of: /github\.com[:\/]([^\/\s]+)\/([^\/\s]+?)(\.git)?\/?$/) else { return nil }
            return "\(match.1)/\(match.2)"
        }
        return nil
    }

    // MARK: Reading

    /// Every repo's latest run, four `gh run list` at a time, in `repos`' order.
    nonisolated static func fetch(_ repos: [String], gh: String? = WidgetGitHub.ghPath) async -> [Run] {
        guard let gh else { return repos.map { Run(repo: $0, problem: "no gh") } }
        var environment = ChildProcess.toolEnvironment(gh)
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_NO_UPDATE_NOTIFIER"] = "1"; environment["NO_COLOR"] = "1"
        let env = environment
        return await withTaskGroup(of: (Int, Run).self) { group in
            var runs = [Run?](repeating: nil, count: repos.count), next = 0
            func add() {
                guard next < repos.count else { return }
                let i = next, repo = repos[i]
                next += 1
                group.addTask { (i, await latest(repo, gh: gh, environment: env)) }
            }
            for _ in 0..<4 { add() }
            for await (i, run) in group { runs[i] = run; add() }
            return runs.compactMap { $0 }
        }
    }

    nonisolated static func latest(_ repo: String, gh: String, environment: [String: String]) async -> Run {
        ciLog.notice("ci: gh run list \(repo, privacy: .private)")
        do {
            let answer = try await ChildProcess.data(gh, ["run", "list", "--repo", repo, "--limit", "1", "--json", "status,conclusion,workflowName,headBranch,url"],
                                                     environment: environment, timeout: timeout)
            return run(repo, answer: answer)
        } catch let failure as ChildProcess.Failure {
            // The row's aside is short; the whole of what gh said goes to the log.
            ciLog.error("ci: gh run list \(repo, privacy: .private) exited \(failure.status): \(failure.message, privacy: .private)")
            return Run(repo: repo, problem: failure.message.localizedCaseInsensitiveContains("auth") ? "gh signed out"
                       : failure.message.localizedCaseInsensitiveContains("not found") ? "not found" : "gh failed")
        } catch {
            return Run(repo: repo, problem: "no answer")
        }
    }

    /// gh's answer, a list of one run or none.
    nonisolated static func run(_ repo: String, answer: Data) -> Run {
        guard let list = try? JSONSerialization.jsonObject(with: answer) as? [[String: Any]] else { return Run(repo: repo, problem: "no answer") }
        guard let first = list.first else { return Run(repo: repo, problem: noRuns) }
        let status = first["status"] as? String ?? "", conclusion = first["conclusion"] as? String ?? ""
        return Run(repo: repo, state: state(status: status, conclusion: conclusion), workflow: first["workflowName"] as? String,
                   branch: first["headBranch"] as? String, url: first["url"] as? String)
    }

    /// A repo's problem when gh finds no Actions run: such a repo is left out of the list, counted under it.
    nonisolated static let noRuns = "no runs"

    nonisolated static func state(status: String, conclusion: String) -> Run.State {
        guard status == "completed" else { return .running }
        switch conclusion {
        case "success": return .passing
        case "failure", "timed_out", "startup_failure": return .failing
        default: return .other(conclusion.isEmpty ? status : conclusion.replacingOccurrences(of: "_", with: " "))
        }
    }

    // MARK: Drawing

    /// One row a repo: a dot for the run's state, its name, workflow and branch (the tail truncates, so a narrow tile
    /// keeps the name), and the state or why there is no run at its right; failing first, then running, then the rest, passing last.
    /// Repos with no Actions runs are left out, a line under the list counting them.
    static func blocks(_ runs: [Run]) -> [Extension.Block] {
        guard !runs.isEmpty else { return [.note(.init(text: "No GitHub repos in ~/code or the GitHub extension", icon: "info"))] }
        let shown = runs.filter { $0.problem != noRuns }, hidden = runs.count - shown.count
        let repos = hidden == 1 ? "1 repo" : "\(hidden) repos"
        guard !shown.isEmpty else { return [.note(.init(text: "No GitHub Actions runs in your \(repos)", icon: "info"))] }
        let rank: (Run) -> Int = { switch $0.state { case .failing: 0; case .running: 1; case .passing: 3; default: 2 } }
        let rows = shown.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element).map { run in
            let name = run.repo.split(separator: "/").last.map(String.init) ?? run.repo
            return Extension.Item(id: run.repo, title: [name, run.workflow, run.branch].compactMap { $0 }.joined(separator: " · "),
                                  subtitle: run.problem ?? word(run.state),
                                  icon: dot(run.state), actions: [])
        }
        guard hidden > 0 else { return [.list(title: nil, items: rows)] }
        return [.list(title: nil, items: rows), .note(.init(text: "\(repos) with no Actions runs hidden", icon: "info"))]
    }

    static func word(_ state: Run.State?) -> String? {
        switch state {
        case .passing: "passing"
        case .failing: "failing"
        case .running: "running"
        case .other(let word): word
        case nil: nil
        }
    }

    static func dot(_ state: Run.State?) -> String {
        switch state {
        case .passing: "🟢"
        case .failing: "🔴"
        case .running: "🟡"
        default: "⚪"
        }
    }
}
