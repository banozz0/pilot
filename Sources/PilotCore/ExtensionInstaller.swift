import Foundation

/// Installs, updates and removes catalogue extensions (2026-10-10, ADR 0010). An install fetches every file of the
/// entry into a temporary folder beside the Extensions folder (one volume, so the last step is a rename), each checked
/// against the index's size and sha256; the folder must then read as an Extension with the entry's id. Only then is
/// an installed copy with that id, in whatever folder, moved aside beside the temporary one and the new folder renamed
/// to `Extensions/<id>`; the copies aside go to the Trash after, or back where they were when that rename fails. A
/// file that does not match installs nothing. ExtensionData/<id> (preferences, data) and the Keychain are never touched,
/// so an update or a reinstall keeps its settings. Remove moves the folder to the Trash, recoverable.
public struct ExtensionInstaller: Sendable {
    /// The Extensions folder, the folder the temporary one is made in, where files come from, and the Trash.
    public let extensions: URL, staging: URL, source: ExtensionCatalogue.Source
    let trash: @Sendable (URL) throws -> Void

    public init(extensions: URL = Extension.folder, staging: URL? = nil, source: ExtensionCatalogue.Source = .live,
                trash: @escaping @Sendable (URL) throws -> Void = FileOps.trashNow) {
        self.extensions = extensions
        self.staging = staging ?? extensions.deletingLastPathComponent()
        self.source = source
        self.trash = trash
    }

    /// The catalogue's index, read now.
    public func index() async throws -> ExtensionCatalogue.Index {
        let data = try await source.fetch(ExtensionCatalogue.indexPath, ExtensionCatalogue.indexLimit)
        return try ExtensionCatalogue.index(data)
    }

    /// Installs `entry`, or updates the copy installed, and returns it as read from its new folder. `progress` hears
    /// each file fetched (done, of all). Throws a Problem, and leaves the Extensions folder as it was, when a file does
    /// not arrive or match, what arrived is not that extension, or a folder named its id holds something else. `fileLimit`
    /// is the most a file may weigh: the catalogue's, or a staged Raycast-format folder's (ExtensionCheck.install).
    @discardableResult
    public func install(_ entry: ExtensionCatalogue.Entry, fileLimit: Int = ExtensionCatalogue.fileLimit,
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Extension {
        _ = try replaced(entry.id)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let temp = staging.appending(path: ".extension-\(entry.id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try await source.download(entry.files, from: "extensions/\(entry.id)", limit: fileLimit, into: temp,
                                  mode: { $0.executable ? 0o755 : 0o644 }, progress: progress)
        let arrived: Extension
        do { arrived = try Extension(folder: temp) }
        catch let problem as Extension.Problem { throw ExtensionCatalogue.Problem.notAnExtension(problem.reason) }
        guard arrived.id == entry.id else { throw ExtensionCatalogue.Problem.wrongID(found: arrived.id, expected: entry.id) }
        try Task.checkCancellation()
        // Asked again: the folder may have changed while the files came.
        let old = try replaced(entry.id)
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        // Renames on one volume: the old copies go aside, not to the Trash, until the new one is in place.
        let aside = staging.appending(path: ".extension-\(entry.id)-old-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: aside) }
        var moved: [(from: URL, to: URL)] = []
        let target = extensions.appending(path: entry.id)
        do {
            for (i, folder) in old.enumerated() {
                let to = aside.appending(path: "\(i)/\(folder.lastPathComponent)")
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: folder, to: to)
                moved.append((folder, to))
            }
            try fm.moveItem(at: temp, to: target)
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            throw error
        }
        for (_, to) in moved { try? trash(to) }
        do { return try Extension(folder: target) }
        catch let problem as Extension.Problem { throw ExtensionCatalogue.Problem.notAnExtension(problem.reason) }
    }

    /// The folders an install of `id` replaces: the installed extension with that id, wherever it is, and a folder named
    /// `id` that reads as it. Throws when a folder named `id` holds another extension or none.
    func replaced(_ id: String) throws -> [URL] {
        // A Raycast install that took one of Pilot's own ids before T28 moves to its own first, so it is never replaced.
        RaycastManifest.migrate(in: extensions, data: extensions.deletingLastPathComponent().appending(path: "ExtensionData"))
        let found = Extension.find(in: extensions)
        var folders = found.extensions.filter { $0.id == id }.map { $0.folder.resolvingSymlinksInPath() }
        let named = extensions.appending(path: id).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: named.path), !folders.contains(named) else { return folders }
        do {
            let other = try Extension(folder: named)
            guard other.id == id else { throw ExtensionCatalogue.Problem.folderTaken(id: id, why: "holds extension \"\(other.id)\"") }
            folders.append(named)
        } catch let problem as Extension.Problem {
            throw ExtensionCatalogue.Problem.folderTaken(id: id, why: "is not an extension (\(problem.reason))")
        }
        return folders
    }

    /// Moves the installed extension `id`'s folder to the Trash and returns its title; its data and settings stay.
    @discardableResult
    public func remove(_ id: String) throws -> String {
        guard let ext = Extension.find(in: extensions).extensions.first(where: { $0.id == id }) else {
            throw ExtensionCatalogue.Problem.notInstalled(id)
        }
        try trash(ext.folder)
        return ext.title
    }
}

/// A Raycast extension's folder from GitHub, built on this Mac without Node (ADR 0017, T6): pilot-ext-host's `--fetch`
/// lists the folder once and fetches its files into `workspace` (each checked against its git blob hash), and answers
/// the plan; its `--build` then gets esbuild into `tools` once and the lockfile's
/// tarballs (each checked by its sha512, no install script run) and bundles each command. Pilot then checks and installs
/// the built folder as a local one, with no question (T26). `workspace` is Pilot's alone, made beside the Extensions folder, and gone after.
public struct GitHubInstall: Sendable {
    public struct Plan: Codable, Sendable {
        public struct Command: Codable, Sendable { public let name, title, mode: String }
        /// `key` is the lockfile's place, the folder Node requires it by; `name` the registry's, different for an alias.
        public struct Package: Codable, Sendable { public let key, name, version, resolved, integrity: String }
        public let id, title, source, tree, manifest, esbuild, esbuildVersion: String
        public let version: String?
        public let commands: [Command], preferences: [String], packages: [Package]
        public let files, bytes, esbuildBytes: Int
    }

    /// One request the host made: its host, what it fetched, its size and the check it passed.
    public struct Fetched: Codable, Sendable { public let host, what, check: String; public let bytes: Int }

    public let spec: String, workspace: URL, tools: URL
    /// A Raycast extension's source folder on this Mac to build in place of a GitHub folder (T32), nil for GitHub.
    public let local: URL?

    /// `github:<owner>/<repo>/<folder>` as the host takes it, nil for any other argument.
    public init?(_ argument: String, extensions: URL) {
        guard argument.hasPrefix("github:") else { return nil }
        self.init(spec: String(argument.dropFirst("github:".count)), local: nil, extensions: extensions)
    }

    /// A Raycast extension's source folder on this Mac (T32: what /extension makes), read by the host's `--local` as `--fetch`
    /// reads a GitHub folder, then built the same way; `folder` is already resolved and allowed to be read.
    public init(local folder: URL, extensions: URL) { self.init(spec: folder.path, local: folder, extensions: extensions) }

    private init(spec: String, local: URL?, extensions: URL) {
        self.spec = spec
        self.local = local
        let support = extensions.deletingLastPathComponent()
        workspace = support.appending(path: "\(Self.prefix)\(UUID().uuidString)")
        tools = support.appending(path: "Tools")
    }

    static let prefix = ".ext-github-"

    /// The plan, once Pilot holds every remote word its answer and refusals show to its own rules too, as the host's plan() does:
    /// the id as Extension.isName, every command name as Extension.isCommandName (Raycast's capitals kept), Raycast's three modes, each preference name a letter then
    /// letters, digits, _ and -, the tree 40 lowercase hex digits, each package's key names, real name and version npm's,
    /// and the title, the one free text, at most 80 Unicode scalars (escaped, never refused: the result line and every
    /// refusal the pilot command echoes pass it through ControlGate.Ask.visible; the version shows only when
    /// ExtensionCatalogue.Version reads it). A workspace over an
    /// hour old, left by a run that stopped midway, is swept first.
    public func fetch() async throws -> (Plan, [Fetched]) {
        let fm = FileManager.default, support = workspace.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: support.path)) ?? [] where name.hasPrefix(Self.prefix) {
            let old = support.appending(path: name)
            if let made = (try? fm.attributesOfItem(atPath: old.path))?[.modificationDate] as? Date, made < Date(timeIntervalSinceNow: -3600) {
                try? fm.removeItem(at: old)
            }
        }
        let step = local.map { ["--local", $0.path] } ?? ["--fetch", spec]
        let (lines, last) = try await host(step + [workspace.path, tools.path], input: Data())
        let plan = try JSONDecoder().decode(Plan.self, from: last)
        guard Extension.isName(plan.id), plan.title.unicodeScalars.count <= 80,
              plan.commands.allSatisfy({ Extension.isCommandName($0.name) && ["view", "no-view", "menu-bar"].contains($0.mode) }) else {
            throw Refused(errorDescription: "its package.json names it outside Pilot's id rule (a-z, 0-9 and hyphens) or a command outside letters, digits, hyphens and underscores")
        }
        guard plan.preferences.allSatisfy({ $0.count <= 64 && $0.wholeMatch(of: #/[A-Za-z][A-Za-z0-9_-]*/#) != nil }) else {
            throw Refused(errorDescription: "its package.json names a preference outside a letter then letters, digits, _ and -")
        }
        guard local != nil || plan.tree.wholeMatch(of: #/[0-9a-f]{40}/#) != nil else { throw Refused(errorDescription: "GitHub's listing named no tree") }
        guard plan.packages.allSatisfy(Self.npm) else { throw Refused(errorDescription: "its lockfile names a package outside npm's names") }
        return (plan, lines)
    }

    /// A package npm could have put there: every name on its key's path and its real name npm's, legacy capitals
    /// included, and a version of semver's characters. The host's plan() holds them to the same pattern first
    /// (Installer.npmName in Helpers/pilot-ext-host/Sources/pilot-ext-host/Install.swift, a package of its own): change both together.
    static func npm(_ package: Plan.Package) -> Bool {
        let name = #/(@[A-Za-z0-9~-][A-Za-z0-9._~-]*\/)?[A-Za-z0-9~-][A-Za-z0-9._~-]*/#
        guard package.key.hasPrefix("node_modules/") else { return false }
        let names = package.key.dropFirst("node_modules/".count).components(separatedBy: "/node_modules/") + [package.name]
        return names.allSatisfy { $0.count <= 214 && $0.wholeMatch(of: name) != nil }
            && package.version.count <= 64 && package.version.wholeMatch(of: #/[0-9A-Za-z.+-]+/#) != nil
    }

    /// What a build answers: its folder, the esbuild it used, downloaded or reused, and the Node built-ins its bundles
    /// require that the prelude lacks or only loads (T25), read from esbuild's metafile and held to Node's own names.
    public struct Built: Decodable, Sendable {
        public let folder, esbuild, esbuildPath, esbuildVersion: String
        public let needs: [String]?
        /// `needs`, each a Node module name (a-z, digits, _ and /), so nothing the extension wrote reaches the result line.
        public var missingModules: [String] { (needs ?? []).filter { $0.count <= 40 && $0.wholeMatch(of: #/[a-z][a-z0-9_]*(\/[a-z0-9_]+)?/#) != nil } }
    }

    /// The build, and each request it made; `plan` is the one fetched. The host gets the prelude, which it reads for
    /// the modules Pilot has.
    public func build(_ plan: Plan) async throws -> (Built, [Fetched]) {
        let prelude = ExtensionRun.host(environment: ProcessInfo.processInfo.environment)?.prelude
        let (lines, last) = try await host(["--build", workspace.path, tools.path] + (prelude.map { [$0.path] } ?? []), input: try JSONEncoder().encode(plan))
        return (try JSONDecoder().decode(Built.self, from: last), lines)
    }

    public func remove() { try? FileManager.default.removeItem(at: workspace) }

    struct Refused: LocalizedError { let errorDescription: String? }

    /// Runs the host in one of its install steps: its `fetch` lines, and its last line, which is `plan` or `built`;
    /// an `error` line throws its words.
    private func host(_ arguments: [String], input: Data) async throws -> ([Fetched], Data) {
        guard let (host, _) = ExtensionRun.host(environment: ProcessInfo.processInfo.environment) else { throw ExtensionRun.NoHost() }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": FileManager.default.temporaryDirectory.path]
        let out = try await ChildProcess.run(host.path, arguments, environment: environment, input: input, directory: workspace,
                                             timeout: .seconds(600), limit: 4 << 20)
        let lines = out.split(separator: "\n").map { Data($0.utf8) }
        struct Line: Decodable { let type: String, text: String? }
        guard let last = lines.last, let kind = try? JSONDecoder().decode(Line.self, from: last) else { throw Refused(errorDescription: "the extension host answered nothing") }
        if kind.type == "error" { throw Refused(errorDescription: kind.text ?? "the extension host stopped") }
        return (lines.compactMap { line in
            (try? JSONDecoder().decode(Line.self, from: line))?.type == "fetch" ? try? JSONDecoder().decode(Fetched.self, from: line) : nil
        }, last)
    }
}
