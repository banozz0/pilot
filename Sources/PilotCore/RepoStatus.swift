import Foundation

/// One own repo's work not yet committed or pushed, as the Repos widget shows it (Pilot 1.0.2, Sven Q725): files changed
/// (staged, unstaged or untracked), commits ahead of its upstream, and behind it as the last fetch left the upstream's
/// ref. Nothing fetches: behind is only what the repo already knows.
public struct RepoStatus: Sendable, Equatable {
    public let name: String
    public let url: URL
    public var branch: String?
    public var changed = 0, ahead = 0, behind = 0
    /// Why git gave no answer (none installed, a timeout): such a repo shows with it, never as clean.
    public var problem: String?

    public init(name: String, url: URL, branch: String? = nil, changed: Int = 0, ahead: Int = 0, behind: Int = 0, problem: String? = nil) {
        self.name = name; self.url = url; self.branch = branch
        self.changed = changed; self.ahead = ahead; self.behind = behind; self.problem = problem
    }

    /// Nothing to commit or push: the widget leaves it out. Behind alone is clean, nothing of Sven's waits.
    public var clean: Bool { problem == nil && changed == 0 && ahead == 0 }
}

extension Repos {
    /// How long one repo's git may take, and the most it may print: past that it shows as "many changed".
    static let statusTimeout: Duration = .seconds(5)
    static let statusLimit = 1_000_000

    /// `repo`'s state from one `git status --porcelain=v2 --branch` in a child, GIT_OPTIONAL_LOCKS=0 so it never writes
    /// the index (plumbing's diff-files would count a file only touched as changed); a branch with no upstream counts the
    /// commits no remote has, with a second child, only when the repo has a remote.
    public static func status(_ repo: RepoSummary) async -> RepoStatus {
        var status = RepoStatus(name: repo.name, url: repo.url, branch: repo.branch)
        guard let git else { status.problem = "no git"; return status }
        var environment = ChildProcess.toolEnvironment(git)
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let out: String
        do {
            out = try await ChildProcess.run(git, ["-C", repo.url.path, "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch",
                                                   "--untracked-files=normal"], environment: environment, timeout: statusTimeout, limit: statusLimit)
        } catch is ChildProcess.TooLarge {
            status.problem = "many changed"; return status
        } catch {
            status.problem = "not read"; return status
        }
        let read = parse(out)
        status.changed = read.changed
        (status.ahead, status.behind) = (read.ahead ?? 0, read.behind ?? 0)
        if read.ahead == nil, read.born, hasRemote(repo.url) {
            let count = try? await ChildProcess.run(git, ["-C", repo.url.path, "rev-list", "--count", "HEAD", "--not", "--remotes"],
                                                    environment: environment, timeout: statusTimeout, limit: 64)
            status.ahead = count.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        }
        return status
    }

    /// What `status --porcelain=v2 --branch` says: its entries, one a line (no `-z`, so a rename is one line too);
    /// ahead and behind from `# branch.ab`, nil with no upstream; `born` once HEAD has a commit.
    static func parse(_ out: String) -> (changed: Int, ahead: Int?, behind: Int?, born: Bool) {
        var changed = 0, ahead: Int?, behind: Int?, born = false
        for line in out.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 { ahead = Int(parts[0].dropFirst()); behind = Int(parts[1].dropFirst()) }
            } else if line.hasPrefix("# branch.oid ") {
                born = !line.hasSuffix("(initial)")
            } else if !line.hasPrefix("#") {
                changed += 1
            }
        }
        return (changed, ahead, behind, born)
    }

    /// Whether `.git/config` names a remote: without one there is nowhere to push, so nothing counts as ahead.
    static func hasRemote(_ repo: URL) -> Bool {
        (try? String(contentsOf: repo.appendingPathComponent(".git/config"), encoding: .utf8))?.contains("[remote \"") == true
    }

    /// Every repo's state, four children at a time, in `repos`' order.
    public static func statuses(_ repos: [RepoSummary]) async -> [RepoStatus] {
        await withTaskGroup(of: (Int, RepoStatus).self) { group in
            var found: [RepoStatus?] = Array(repeating: nil, count: repos.count), next = 0
            func add() {
                guard next < repos.count else { return }
                let (at, repo) = (next, repos[next])
                next += 1
                group.addTask { (at, await status(repo)) }
            }
            for _ in 0..<4 { add() }
            for await (at, status) in group {
                found[at] = status
                add()
            }
            return found.compactMap { $0 }
        }
    }
}
