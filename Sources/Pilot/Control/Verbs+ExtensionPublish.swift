import Foundation
import PilotCore

/// `pilot ext publish <id>` (P49, Sven Q297, "now, for your own extensions"): an installed extension, made with /extension,
/// sent to the catalogue as a pull request on its repo (banozz0/pilot, its catalogue/ folder), from a clone of it on this
/// Mac whose folder is the setting `extensions.catalogueClone`, empty until set. One Allow names the extension, the branch
/// and the repo; then a new branch off the clone's origin/main gets the folder under catalogue/extensions/<id>, the index
/// rebuilt (catalogue/scripts/build-index.py) and checked (catalogue/scripts/check.py), one commit, a push of that branch
/// alone and `gh pr create`. Forking for a person who cannot push to the repo is public-repo spec T23.
/// Nothing reaches the catalogue's main until its owner merges. A clone whose origin is not on GitHub is pushed to and no
/// pull request opens. A failed step puts the clone back on the branch it was on, the new branch gone.
@MainActor
enum CataloguePublish {
    /// Publish waits for v1.1 (SH19: a stranger cannot push to the catalogue's repo, so it needs fork-and-PR): a release
    /// build has no `ext publish`, no catalogue clone setting and no /publish skill; a debug build keeps all three.
    #if DEBUG
    nonisolated static let available = true
    #else
    nonisolated static let available = false
    #endif
    static let key = "extensions.catalogueClone"
    static let defaults = UserDefaults.pilot()
    static var clone: String { defaults.string(forKey: key) ?? "" }

    /// What a publish does, read before its Allow so the question names it.
    struct Plan {
        let id, version, title: String
        let folder, clone: URL
        let origin, repo, branch, back: String
        var github: Bool { repo != origin }
        var ask: ControlGate.Ask {
            ControlGate.Ask(github ? "Open a pull request on \(repo)" : "Push a branch to \(repo)", "\(id) \(version) on branch \(branch)")
        }
    }

    /// Read before the Allow, so it asks only for a publish that can run: a clean clone without the branch yet.
    static func plan(_ ext: Extension) async throws(ControlError) -> Plan {
        guard !clone.isEmpty else {
            throw ControlError(.notReady, "no catalogue clone set: clone \(ExtensionCatalogue.repo), then pilot set \(key) <its folder>")
        }
        let folder = URL(filePath: clone, directoryHint: .isDirectory)
        let origin = try await git(folder, "remote", "get-url", "origin")
        let back = try await git(folder, "branch", "--show-current")
        let version = ext.version ?? "0.1.0", branch = "ext/\(ext.id)-\(version)"
        guard try await git(folder, "status", "--porcelain").isEmpty else {
            throw ControlError(.badValue, "the catalogue clone has uncommitted changes; publishing needs it clean")
        }
        if (try? await git(folder, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)")) != nil {
            throw ControlError(.badValue, "branch \(branch) is already in the clone: bump the extension's version, or remove the branch")
        }
        return Plan(id: ext.id, version: version, title: ext.title, folder: ext.folder, clone: folder, origin: origin,
                    repo: repo(origin) ?? origin, branch: branch, back: back)
    }

    /// "owner/name" for a GitHub remote, by ssh or https; nil for any other.
    static func repo(_ origin: String) -> String? {
        guard let match = origin.firstMatch(of: /github\.com[:\/]([^\/\s]+\/[^\/\s]+?)(\.git)?\/?$/) else { return nil }
        return String(match.output.1)
    }

    static func publish(_ plan: Plan) async throws(ControlError) -> JSONValue {
        let clone = plan.clone
        _ = try await git(clone, "fetch", "origin", "main")
        _ = try await git(clone, "switch", "-q", "-c", plan.branch, "origin/main")
        do throws(ControlError) {
            let target = clone.appending(path: "\(ExtensionCatalogue.root)/extensions/\(plan.id)", directoryHint: .isDirectory)
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: plan.folder, to: target)
                try? FileManager.default.removeItem(at: target.appending(path: "__pycache__"))
            } catch { throw ControlError(.badValue, "could not copy \(plan.id) into the clone: \(error.localizedDescription)") }
            _ = try await run(clone, "/usr/bin/python3", ["\(ExtensionCatalogue.root)/scripts/build-index.py"], step: "build-index.py")
            _ = try await run(clone, "/usr/bin/python3", ["\(ExtensionCatalogue.root)/scripts/check.py"], step: "check.py")
            _ = try await git(clone, "add", "-A", "--", "\(ExtensionCatalogue.root)/extensions/\(plan.id)", "\(ExtensionCatalogue.root)/\(ExtensionCatalogue.indexPath)")
            guard try await !git(clone, "diff", "--cached", "--name-only").isEmpty else {
                throw ControlError(.badValue, "\(plan.id) \(plan.version) is already in the catalogue as it is")
            }
            _ = try await git(clone, "commit", "-q", "-m", "\(plan.id): \(plan.version) from Pilot")
            _ = try await git(clone, "push", "-q", "-u", "origin", plan.branch)
        } catch {
            // Back as it was: this run's changes and its unpushed branch go, nothing else.
            _ = try? await git(clone, "reset", "-q", "--hard")
            _ = try? await git(clone, "clean", "-fdq", "--", "\(ExtensionCatalogue.root)/extensions/\(plan.id)")
            _ = try? await git(clone, "switch", "-q", plan.back)
            _ = try? await git(clone, "branch", "-q", "-D", plan.branch)
            throw error
        }
        _ = try? await git(clone, "switch", "-q", plan.back)
        var answer: [String: JSONValue] = ["extension": .string(plan.id), "version": .string(plan.version), "branch": .string(plan.branch),
                                           "repo": .string(plan.repo), "pushed": .bool(true)]
        guard plan.github else {
            answer["pullRequest"] = .string("none: the clone's origin is not on GitHub")
            return .object(answer)
        }
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ControlError(.notReady, "the branch \(plan.branch) is pushed, but gh is not installed to open its pull request")
        }
        let body = "\(plan.title) \(plan.version), sent from Pilot with pilot ext publish. catalogue/scripts/check.py passed and catalogue/index.json is rebuilt."
        let pr = try await run(clone, gh, ["pr", "create", "--repo", plan.repo, "--base", "main", "--head", plan.branch,
                                           "--title", "\(plan.id): \(plan.version)", "--body", body], step: "gh pr create")
        answer["pullRequest"] = .string(pr.split(separator: "\n").last.map(String.init) ?? pr)
        return .object(answer)
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
    }
}
