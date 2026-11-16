import Foundation
import PilotCore

/// `pilot ext publish <id>` (P49, Sven Q297) and `pilot theme publish <id>` (public-repo spec T23): an installed extension or
/// one of your theme packs, sent to the catalogue as a pull request on its repo (banozz0/pilot, its catalogue/ folder),
/// from a clone of it on this Mac whose folder is the setting `extensions.catalogueClone` (one for both kinds), empty
/// until set. One Allow names the pack, the branch, the repo and, for a person who cannot push to it, the fork; then a
/// new branch off the clone's origin/main gets the folder under catalogue/<kind>/<id>, the index rebuilt
/// (catalogue/scripts/build-index.py) and checked (catalogue/scripts/check.py), one commit, a push of that branch alone
/// and `gh pr create`. A person who cannot push (gh says so) gets a fork on their GitHub account, made or found through
/// GitHub's fork API and kept as the clone's remote `pilot-fork`, so origin stays the catalogue's repo; the branch goes
/// there and the pull request asks to merge `<login>:<branch>`. From a fork, a theme the catalogue's index does not list
/// yet gets a `Pack by:` line naming the login when it has none, so the gallery credits its author; one it lists (one
/// installed from the catalogue, say) is sent only by its own author, never re-credited. Nothing reaches the catalogue's
/// main until its owner merges.
/// The pull request's title and body (CataloguePullRequest) are read from the pack before the Allow, check.py's line from a
/// run on a scratch copy of origin/main's catalogue with the pack in it, and the Allow shows both whole.
/// A clone whose origin is not on GitHub is pushed to and no pull request opens. A failed step puts the clone back on
/// the branch it was on, the new branch gone.
@MainActor
enum CataloguePublish {
    /// Sending from a fork waits (SH19) until it is proved against GitHub itself (public-repo T23): a release build sends
    /// only from an account that can push to the catalogue's repo (Sven's) and refuses any other before its Allow; a
    /// debug build forks.
    #if DEBUG
    static let forks = true
    #else
    static let forks = false
    #endif
    static let key = "extensions.catalogueClone"
    static let defaults = UserDefaults.pilot()
    static var clone: String { defaults.string(forKey: key) ?? "" }
    /// The clone's remote for the person's fork.
    static let forkRemote = "pilot-fork"

    /// Where `gh` is, as the catalogue finds it; a sandbox run may name a stand-in (PILOT_SANDBOX_GH), so a fork is proved
    /// without an account.
    static var gh: String? {
        #if DEBUG
        if isIsolatedTestRun, let stand = ProcessInfo.processInfo.environment["PILOT_SANDBOX_GH"] { return stand }
        #endif
        return ExtensionCatalogue.Source.ghPath()
    }

    /// The two kinds the catalogue holds, each with its folder under catalogue/, its word, its verb and its branch prefix.
    enum Kind: String {
        case extensions, themes
        var noun: String { self == .themes ? "theme" : "extension" }
        /// `pilot <verb> publish`, and the branch's prefix.
        var verb: String { self == .themes ? "theme" : "ext" }
        var again: String { self == .themes ? "remove the branch to send this theme again" : "bump the extension's version, or remove the branch" }
    }

    /// What is sent: its kind, its id, a label for the branch (an extension's version, a theme's revision), its title and
    /// the folder it is copied from.
    struct Pack {
        let kind: Kind
        let id, label, title: String
        let folder: URL
        var path: String { "\(ExtensionCatalogue.root)/\(kind.rawValue)/\(id)" }

        static func extensionPack(_ ext: Extension) -> Pack {
            Pack(kind: .extensions, id: ext.id, label: ext.version ?? "0.1.0", title: ext.title, folder: ext.folder)
        }
        static func theme(_ loaded: ThemePackStore.Loaded) -> Pack {
            Pack(kind: .themes, id: loaded.pack.id, label: String(loaded.revision.suffix(8)), title: loaded.pack.title,
                 folder: URL(filePath: loaded.folder, directoryHint: .isDirectory))
        }
    }

    /// What a publish does, read before its Allow so the question names it.
    struct Plan {
        let pack: Pack
        let clone: URL
        let origin, repo, branch, back: String
        /// gh, for a clone whose origin is on GitHub.
        let gh: String?
        /// The person's GitHub login when they cannot push to `repo`, so the branch goes to their fork; nil when they can.
        let fork: String?
        /// A theme from a fork that the catalogue does not list yet: its copy gets a `Pack by:` line when it has none.
        let credit: Bool
        /// What the pull request says that the pack does not (its check line, whether it is an update).
        let facts: CataloguePullRequest.Facts
        var github: Bool { gh != nil }
        var title: String { CataloguePullRequest.title(pack, update: facts.update) }
        var ask: ControlGate.Ask {
            let what = "\(pack.kind.noun) \(pack.id) \(pack.label) on branch \(branch)"
            guard github else { return ControlGate.Ask("Push a branch to \(repo)", what) }
            let sent = "\(title)\n\n" + CataloguePullRequest.body(pack, facts)
            guard let fork else { return ControlGate.Ask("Open a pull request on \(repo)", what).sending(sent) }
            // GitHub picks the fork's name (an existing repo of the same name gets another), so the Allow names its owner.
            return ControlGate.Ask("Open a pull request on \(repo) from your fork of it on @\(fork)", what + ", pushed to that fork (made on your GitHub account if it is not there)").sending(sent)
        }
    }

    /// Read before the Allow, so it asks only for a publish that can run: a clean clone without the branch yet, and on
    /// GitHub, gh signed in and whether its account can push.
    static func plan(_ pack: Pack) async throws(ControlError) -> Plan {
        guard !clone.isEmpty else {
            throw ControlError(.notReady, "no catalogue clone set: clone \(ExtensionCatalogue.repo), then pilot set \(key) <its folder>")
        }
        let folder = URL(filePath: clone, directoryHint: .isDirectory)
        let origin = try await git(folder, "remote", "get-url", "origin")
        let back = try await git(folder, "branch", "--show-current")
        let branch = "\(pack.kind.verb)/\(pack.id)-\(pack.label)"
        guard try await git(folder, "status", "--porcelain").isEmpty else {
            throw ControlError(.badValue, "the catalogue clone has uncommitted changes; publishing needs it clean")
        }
        if (try? await git(folder, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)")) != nil {
            throw ControlError(.badValue, "branch \(branch) is already in the clone: \(pack.kind.again)")
        }
        var (repo, gh, fork, credit): (String, String?, String?, Bool) = (origin, nil, nil, false)
        if let github = Self.repo(origin) {
            guard let found = Self.gh else { throw ControlError(.notReady, "gh is not installed: it opens the pull request (brew install gh, then gh auth login)") }
            (repo, gh) = (github, found)
            let push = try await run(folder, found, ["api", "repos/\(github)", "--jq", ".permissions.push"], step: "gh api (sign in with gh auth login)")
            if push != "true" {
                guard forks else {
                    throw ControlError(.notReady, "your GitHub account cannot push to \(github), and this Pilot sends only from one that can: fork it and open a pull request by hand (CONTRIBUTING.md, The catalogue)")
                }
                let login = try await run(folder, found, ["api", "user", "--jq", ".login"], step: "gh api user (sign in with gh auth login)")
                fork = login
            }
        }
        _ = try await git(folder, "fetch", "-q", "origin", "main")
        let index = try await mainIndex(folder)
        if let login = fork, pack.kind == .themes { credit = try unlisted(pack.id, by: login, in: index) }
        let listed = pack.kind == .themes ? index.theme(pack.id)?.files : index.entry(pack.id)?.files
        let facts = CataloguePullRequest.Facts(
            update: listed != nil, listedVersion: pack.kind == .extensions ? index.entry(pack.id)?.version : nil,
            changes: listed.map { CataloguePullRequest.changes(pack.folder, listed: $0) } ?? [],
            check: try await scratchCheck(pack, folder, credit: credit ? fork : nil),
            build: "Pilot \(GeneralPage.shortVersion) (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"))",
            author: pack.kind == .themes ? (credit ? fork : packBy(pack.folder)) : fork, repo: repo)
        return Plan(pack: pack, clone: folder, origin: origin, repo: repo, branch: branch, back: back, gh: gh, fork: fork, credit: credit,
                    facts: facts)
    }

    /// The catalogue's index on the clone's origin/main, fetched.
    private static func mainIndex(_ clone: URL) async throws(ControlError) -> ExtensionCatalogue.Index {
        let text = try await git(clone, "show", "origin/main:\(ExtensionCatalogue.root)/\(ExtensionCatalogue.indexPath)")
        do { return try ExtensionCatalogue.index(Data(text.utf8)) } catch {
            throw ControlError(.badValue, "the catalogue's index on origin/main does not read: \(ExtensionCatalogue.Problem.reason(error))")
        }
    }

    /// check.py's last line on a scratch copy of origin/main's catalogue (and Packaging/ThemePacks, which it compares
    /// themes with) holding the pack as the publish would put it, the index rebuilt first: what the pull request
    /// reports, read before the Allow without touching the clone. A failing check stops here, before any question.
    private static func scratchCheck(_ pack: Pack, _ clone: URL, credit login: String?) async throws(ControlError) -> String {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pilot-publish-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true) } catch {
            throw ControlError(.badValue, "could not make a scratch folder for check.py: \(error.localizedDescription)")
        }
        let tar = scratch.appending(path: "main.tar").path(percentEncoded: false)
        let paths = (try? await git(clone, "cat-file", "-e", "origin/main:Packaging/ThemePacks")) != nil
            ? [ExtensionCatalogue.root, "Packaging/ThemePacks"] : [ExtensionCatalogue.root]
        _ = try await run(clone, "/usr/bin/git", ["archive", "-o", tar, "origin/main"] + paths, step: "git archive")
        _ = try await run(scratch, "/usr/bin/tar", ["-xf", tar], step: "tar")
        try place(pack, in: scratch, credit: login)
        _ = try await run(scratch, "/usr/bin/python3", ["\(ExtensionCatalogue.root)/scripts/build-index.py"], step: "build-index.py")
        let said = try await run(scratch, "/usr/bin/python3", ["\(ExtensionCatalogue.root)/scripts/check.py"], step: "check.py")
        return ScriptCommand.lastLine(said) ?? said
    }

    /// The handle on the pack's own `Pack by:` line, as build-index.py reads it; nil for none.
    private static func packBy(_ folder: URL) -> String? {
        let text = (try? String(contentsOf: folder.appending(path: "PROVENANCE.md"), encoding: .utf8)) ?? ""
        return text.firstMatch(of: /(?m)^[ \t]*(?:[-*][ \t]+)?Pack by:[ \t]*@(\S+)[ \t]*$/).map { String($0.output.1) }
    }

    /// Whether the catalogue's index on origin/main leaves out theme `id`. One it lists may come from a fork only from the
    /// author its index names: a pack installed from the catalogue is someone else's, and is never re-credited.
    private static func unlisted(_ id: String, by login: String, in index: ExtensionCatalogue.Index) throws(ControlError) -> Bool {
        guard let listed = index.theme(id) else { return true }
        guard let author = listed.author, author.lowercased() == login.lowercased() else {
            throw ControlError(.badValue, "\(id) is in the catalogue already, \(listed.author.map { "sent by @\($0)" } ?? "one of Pilot's own"): duplicate it under a new id to send one of yours")
        }
        return false
    }

    /// "owner/name" for a GitHub remote, by ssh or https, github.com its host; nil for any other.
    static func repo(_ origin: String) -> String? {
        guard let match = origin.wholeMatch(of: /(?:https:\/\/(?:[^@\/\s]+@)?|ssh:\/\/git@|git@)github\.com[:\/]([^\/\s]+\/[^\/\s]+?)(\.git)?\/?/) else { return nil }
        return String(match.output.1)
    }

    static func publish(_ plan: Plan) async throws(ControlError) -> JSONValue {
        let clone = plan.clone, pack = plan.pack
        _ = try await git(clone, "fetch", "origin", "main")
        _ = try await git(clone, "switch", "-q", "-c", plan.branch, "origin/main")
        var fork: String?
        do throws(ControlError) {
            try place(pack, in: clone, credit: plan.credit ? plan.fork : nil)
            _ = try await run(clone, "/usr/bin/python3", ["\(ExtensionCatalogue.root)/scripts/build-index.py"], step: "build-index.py")
            _ = try await run(clone, "/usr/bin/python3", ["\(ExtensionCatalogue.root)/scripts/check.py"], step: "check.py")
            _ = try await git(clone, "add", "-A", "--", pack.path, "\(ExtensionCatalogue.root)/\(ExtensionCatalogue.indexPath)")
            guard try await !git(clone, "diff", "--cached", "--name-only").isEmpty else {
                throw ControlError(.badValue, "\(pack.id) \(pack.label) is already in the catalogue as it is")
            }
            // "<id>: <label>": a commit subject, which git hooks read as "<area>: <what>"; the pull request's title names the kind.
            _ = try await git(clone, "commit", "-q", "-m", "\(pack.id): \(pack.label) from Pilot")
            if let gh = plan.gh, plan.fork != nil {
                fork = try await forked(plan, gh)
                try await pushToFork(clone, plan.branch)
            } else {
                _ = try await git(clone, "push", "-q", "-u", "origin", plan.branch)
            }
        } catch {
            // Back as it was: this run's changes and its unpushed branch go, nothing else (a fork made stays).
            _ = try? await git(clone, "reset", "-q", "--hard")
            _ = try? await git(clone, "clean", "-fdq", "--", pack.path)
            _ = try? await git(clone, "switch", "-q", plan.back)
            _ = try? await git(clone, "branch", "-q", "-D", plan.branch)
            throw error
        }
        _ = try? await git(clone, "switch", "-q", plan.back)
        var answer: [String: JSONValue] = [pack.kind.noun: .string(pack.id), "label": .string(pack.label), "branch": .string(plan.branch),
                                           "repo": .string(plan.repo), "pushed": .bool(true)]
        answer["fork"] = fork.map(JSONValue.string)
        guard let gh = plan.gh else {
            answer["pullRequest"] = .string("none: the clone's origin is not on GitHub")
            return .object(answer)
        }
        let head = plan.fork.map { "\($0):\(plan.branch)" } ?? plan.branch
        // The body the Allow showed, the preview's link now reaching the commit (a fork's commits are the repo's once the pull
        // request opens).
        let commit = try? await git(clone, "rev-parse", plan.branch)
        let body = CataloguePullRequest.body(pack, plan.facts, commit: commit)
        let pr = try await run(clone, gh, ["pr", "create", "--repo", plan.repo, "--base", "main", "--head", head,
                                           "--title", plan.title, "--body", body], step: "gh pr create")
        answer["pullRequest"] = .string(pr.split(separator: "\n").last.map(String.init) ?? pr)
        return .object(answer)
    }

    /// The person's fork, "login/name", made or found by GitHub's fork API (it answers the fork they have), held to the
    /// owner the Allow named, and the clone's `pilot-fork` remote pointed at it by origin's protocol (ssh or https).
    private static func forked(_ plan: Plan, _ gh: String) async throws(ControlError) -> String {
        let made = try await run(plan.clone, gh, ["api", "-X", "POST", "repos/\(plan.repo)/forks", "--jq", "[.full_name, .clone_url, .ssh_url] | @tsv"],
                                 step: "gh api forks").split(separator: "\t").map(String.init)
        guard made.count == 3 else { throw ControlError(.badValue, "gh api forks answered no fork") }
        guard let login = plan.fork, made[0].split(separator: "/").first?.lowercased() == login.lowercased() else {
            throw ControlError(.badValue, "GitHub answered the fork \(made[0]), not one on @\(plan.fork ?? ""): nothing was pushed")
        }
        let url = plan.origin.hasPrefix("git@") || plan.origin.hasPrefix("ssh://") ? made[2] : made[1]
        if (try? await git(plan.clone, "remote", "add", forkRemote, url)) == nil {
            _ = try await git(plan.clone, "remote", "set-url", forkRemote, url)
        }
        return made[0]
    }

    /// A new fork takes a moment before it takes pushes (GitHub makes it in the background): a few tries, 3 s apart.
    private static func pushToFork(_ clone: URL, _ branch: String) async throws(ControlError) {
        for attempt in 1...5 {
            do throws(ControlError) { _ = try await git(clone, "push", "-q", "-u", forkRemote, branch); return }
            catch { if attempt == 5 { throw error } }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// The pack's folder copied to its place under `root` (a clone, or a scratch catalogue), in place of what was there,
    /// `__pycache__` left out, and credited to `login` when one is given.
    private static func place(_ pack: Pack, in root: URL, credit login: String?) throws(ControlError) {
        let target = root.appending(path: pack.path, directoryHint: .isDirectory)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pack.folder, to: target)
            try? FileManager.default.removeItem(at: target.appending(path: "__pycache__"))
            if let login { try credit(target, login) }
        } catch { throw ControlError(.badValue, "could not copy \(pack.id) into \(root.lastPathComponent): \(error.localizedDescription)") }
    }

    /// A `Pack by: @login` line in the copy's PROVENANCE.md when it has none: the gallery credits a theme from a fork to
    /// its author, never to Pilot.
    private static func credit(_ pack: URL, _ login: String) throws {
        let file = pack.appending(path: "PROVENANCE.md")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "# \(pack.lastPathComponent) provenance\n"
        // build-index.py's PACK_BY: a line naming a handle, as a list item or not.
        guard !text.contains(/(?m)^[ \t]*(?:[-*][ \t]+)?Pack by:[ \t]*@\S+[ \t]*$/) else { return }
        try (text + (text.hasSuffix("\n") ? "" : "\n") + "\nPack by: @\(login)\n").write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func git(_ clone: URL, _ arguments: String...) async throws(ControlError) -> String {
        try await run(clone, "/usr/bin/git", arguments, step: "git \(arguments[0])")
    }

    /// One step in the clone, its output trimmed; a failure says which step and what it printed.
    static func run(_ clone: URL, _ tool: String, _ arguments: [String], step: String) async throws(ControlError) -> String {
        do {
            return try await ChildProcess.run(tool, arguments, environment: ChildProcess.toolEnvironment(tool), directory: clone,
                                              timeout: .seconds(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let failure as ChildProcess.Failure {
            // check.py's problems, one a line, stay whole; a Python traceback keeps its last line, the error itself.
            let said = failure.message.contains("Traceback (most recent call last)") ? ScriptCommand.lastLine(failure.message) ?? failure.message : failure.message
            throw ControlError(.badValue, "\(step) failed: \(said)")
        } catch {
            throw ControlError(.badValue, "\(step) failed: \(error.localizedDescription)")
        }
    }
}

extension SettingsSchema {
    /// Extensions › the catalogue clone `pilot ext publish` sends from (P49): empty until set; a clone of banozz0/pilot,
    /// holding catalogue/scripts/check.py. And the catalogue folder a debug build reads instead of GitHub
    /// (CatalogueSource): empty for GitHub; a folder holding index.json.
    func registerExtensionPublish() {
        register([
            .text(CataloguePublish.key, "Catalogue clone to publish from", page: "extensions", standard: "",
                  read: { CataloguePublish.clone }, write: { path throws(ControlError) in
                      guard !path.isEmpty else { return CataloguePublish.defaults.removeObject(forKey: CataloguePublish.key) }
                      let folder = try Self.folder(path)
                      guard FileManager.default.fileExists(atPath: folder + "/\(ExtensionCatalogue.root)/scripts/check.py") else {
                          throw ControlError(.badValue, "\(path) is no clone of \(ExtensionCatalogue.repo): it has no \(ExtensionCatalogue.root)/scripts/check.py")
                      }
                      CataloguePublish.defaults.set(folder, forKey: CataloguePublish.key)
                  }),
        ])
        // Read by a debug build only (CatalogueSource), so a release build never offers it.
        #if DEBUG
        register([
            .text(CatalogueSource.key, "Catalogue folder to read instead of GitHub", page: "extensions", standard: "",
                  read: { CatalogueSource.folder }, write: { path throws(ControlError) in
                      guard !path.isEmpty else { return CatalogueSource.defaults.removeObject(forKey: CatalogueSource.key) }
                      let folder = try Self.folder(path)
                      guard FileManager.default.fileExists(atPath: folder + "/" + ExtensionCatalogue.indexPath) else {
                          throw ControlError(.badValue, "\(path) is no catalogue folder: it has no \(ExtensionCatalogue.indexPath)")
                      }
                      CatalogueSource.defaults.set(folder, forKey: CatalogueSource.key)
                  }),
        ])
        #endif
    }
}
