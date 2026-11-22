import AppKit
import PilotCore

/// The Repos widget's data (`"data": {"repos": true}`, Sven Q725): the repos folder's own repos (Repos.list, `folders.repos`) with files changed or
/// commits not pushed, each its name, branch and counts, drawn by Pilot as blocks; a clean repo is left out. Read by git
/// in children, four at a time (Repos.statuses), when a placement shows and every 5 minutes while one does; nothing
/// fetches and nothing watches. One read serves every placement and the Widgets page's preview, and a placement shown
/// again within a minute of it (an empty workspace's, at each switch to it) shows that read without running git again.
@MainActor
enum WidgetRepos {
    /// An open press, as Pilot builds it in these blocks: the repo's name after it. WidgetDesk.press takes it only from a
    /// repos widget, and only for a repo it listed.
    static let openPrefix = "repos.open:"
    static let every: Duration = .seconds(300)
    static let floor: Duration = .seconds(60)

    private static var last: (at: ContinuousClock.Instant, repos: [RepoStatus])?
    private static var reading: Task<[RepoStatus], Never>?

    /// Every own repo's state: the last read while it is younger than `fresh`, else a new one, shared with any read
    /// under way.
    static func read(fresh: Duration = floor) async -> [RepoStatus] {
        if let last, ContinuousClock.now - last.at < fresh { return last.repos }
        if let reading { return await reading.value }
        let task = Task.detached(priority: .utility) { [folder = PilotFolders.shared.reposURL] in await Repos.statuses(Repos.list(in: folder)) }
        reading = task
        let repos = await task.value
        (last, reading) = ((.now, repos), nil)
        return repos
    }

    /// How long a placement's feed sleeps before its next read: until the last read is 5 minutes old.
    static func wait() -> Duration {
        guard let last else { return every }
        return max(every - (ContinuousClock.now - last.at), .seconds(1))
    }

    /// What the widget draws: the repos with work waiting, by name, each a row that opens it; one line when there are
    /// none. The branch rides in the title, whose tail truncates, so a narrow tile keeps the name and the counts.
    static func blocks(_ repos: [RepoStatus]) -> [Extension.Block] {
        guard !repos.isEmpty else { return [.note(.init(text: "No repos in \(AppConfigs.tilde(PilotFolders.shared.repos, home: NSHomeDirectory()))", icon: "info"))] }
        let waiting = repos.filter { !$0.clean }
        guard !waiting.isEmpty else {
            return [.note(.init(text: "All clean", aside: repos.count == 1 ? "1 repo" : "\(repos.count) repos", icon: "checkmark.circle"))]
        }
        let rows = waiting.map { repo in
            Extension.Item(id: repo.name, title: [repo.name, repo.branch].compactMap { $0 }.joined(separator: " · "), subtitle: line(repo),
                           actions: [.init(kind: .pilot(openPrefix + repo.name), title: "Open \(repo.name)")])
        }
        return [.list(title: nil, items: rows)]
    }

    /// "3 changed · 1 ahead": what waits, or why git gave no answer.
    static func line(_ repo: RepoStatus) -> String {
        if let problem = repo.problem { return problem }
        return [repo.changed > 0 ? "\(repo.changed) changed" : nil, repo.ahead > 0 ? "\(repo.ahead) ahead" : nil,
                repo.behind > 0 ? "\(repo.behind) behind" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// A row's press: its folder in Finder.
    static func open(_ name: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PilotFolders.shared.reposURL.appending(path: name, directoryHint: .isDirectory).path)
    }
}
