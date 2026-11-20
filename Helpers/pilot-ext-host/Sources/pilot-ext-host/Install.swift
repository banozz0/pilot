import Compression
import CryptoKit
import Foundation
import JavaScriptCore

// The GitHub install route (ADR 0017, T6): a Raycast extension's folder from GitHub, built on this Mac without Node. Pilot
// runs the host twice, never with an extension's code in a JSContext:
//   pilot-ext-host --fetch <owner>/<repo>/<path> <workspace> <tools>
//     one recursive tree listing of that folder (api.github.com), then each file it needs from raw.githubusercontent.com,
//     checked against the listing's git blob hash, into <workspace>/source; its last line is the plan Pilot builds from (no question, T26):
//     the manifest's commands and preferences, the packages its lockfile pins (its dependencies, and the dev-only ones its
//     code imports), and whether esbuild is in <tools> yet.
//   pilot-ext-host --build <workspace> <tools> [<pilot-ext-prelude.js>], the fetched plan on stdin
//     esbuild 0.28.2 (once, checked by its pinned sha512, kept in <tools>), each package's tarball from the npm registry
//     checked by the lockfile's sha512 and unpacked here (no npm, so no install script ever runs), then esbuild per
//     command into <workspace>/built: package.json, assets/ and dist/<command>.js, which Pilot then checks and installs.
//     The `built` line names the Node built-ins the bundles require that the prelude lacks or only loads (`needs`, T25):
//     read from esbuild's metafile, held to Node's own module names, against the prelude's __pilotModules, read in a
//     JSContext of its own that runs only the prelude.
// Each request is one `fetch` line (host, what, bytes, the check it passed); the last line is `plan`, `built` or `error`.
// Nothing is written outside the two folders named.

enum Installer {
    static let modes: Set<String> = ["--fetch", "--build"]

    // esbuild as the npm registry serves it (@esbuild/darwin-arm64, MIT), pinned: the integrity is the one the prelude's
    // own lockfile records for this version (Helpers/pilot-ext-host/prelude/package-lock.json).
    static let esbuildVersion = "0.28.2"
    static let esbuildURL = "https://registry.npmjs.org/@esbuild/darwin-arm64/-/darwin-arm64-0.28.2.tgz"
    static let esbuildIntegrity = "sha512-n4KqkOQrraxHJcgjM1RvwbigfQKIKJVpM7xp+KsxiyUSrRdIXnt73VhrPAx0fV44hgfmIVKjxMN9J1t5jySVkw=="
    static let esbuildDownload = 4_434_422
    /// The sha256 of that tarball's `package/bin/esbuild`, as unpacked on 2026-11-19 (raycast-extensions T6 log, section 5): a
    /// copy in Tools is reused only while it still hashes to this, and a fresh one is kept only when it does.
    static let esbuildSHA256 = "10b6243df618d374bb2d5c9cfbe7052e1405f6aa4e53a6164f11a91b9f2e1384"
    /// The longest `github:` argument and the longest title the answer carries.
    static let longestSpec = 200, longestTitle = 80

    /// What the host supplies itself, so a package's own copy is never fetched or bundled: two Reacts break hooks.
    static let externals: Set<String> = ["@raycast/api", "react"]
    static let registry = "https://registry.npmjs.org/"
    /// npm's package names, the legacy ones with capitals included: letters, digits, . _ ~ and -, never first . or _,
    /// and an optional @scope/ of the same. Pilot holds the plan to the same pattern again (GitHubInstall.npm in
    /// Sources/PilotCore/ExtensionInstaller.swift; this package links no PilotCore): change both together.
    nonisolated(unsafe) static let npmName = #/(@[A-Za-z0-9~-][A-Za-z0-9._~-]*\/)?[A-Za-z0-9~-][A-Za-z0-9._~-]*/#
    /// A preference's name as Pilot shows it: a letter, then letters, digits, _ and -.
    nonisolated(unsafe) static let preferenceName = #/[A-Za-z][A-Za-z0-9_-]*/#

    // Limits: the source folder, read from the listing before any file is fetched, and the packages.
    static let mostFiles = 400, fileLimit = 5 << 20, folderLimit = 30 << 20
    static let mostPackages = 300, tarballLimit = 20 << 20, unpackedLimit = 200 << 20

    static func run(_ arguments: [String]) -> Never {
        Task.detached {
            do {
                switch arguments.first {
                case "--fetch" where arguments.count == 4:
                    try await fetch(arguments[1], workspace: URL(filePath: arguments[2]), tools: URL(filePath: arguments[3]))
                case "--build" where arguments.count == 3 || arguments.count == 4:
                    let input = FileHandle.standardInput.readDataToEndOfFile()
                    try await build(workspace: URL(filePath: arguments[1]), tools: URL(filePath: arguments[2]), plan: input,
                                    prelude: arguments.count == 4 ? URL(filePath: arguments[3]) : nil)
                default:
                    throw Refused("usage: pilot-ext-host --fetch <owner>/<repo>/<path> <workspace> <tools> | --build <workspace> <tools> [<prelude>]")
                }
            } catch {
                say(["type": "error", "text": (error as? Refused)?.text ?? error.localizedDescription])
            }
            exit(0)
        }
        dispatchMain()
    }

    struct Refused: Error { let text: String; init(_ text: String) { self.text = text } }

    static func say(_ fields: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        put(String(decoding: data, as: UTF8.self), to: .standardOutput)
    }

    static func fetched(_ url: URL, _ what: String, _ bytes: Int, _ check: String) {
        say(["type": "fetch", "host": url.host() ?? "", "what": what, "bytes": bytes, "check": check])
    }

    // MARK: Fetch

    static func fetch(_ spec: String, workspace: URL, tools: URL) async throws {
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let named = #/^[A-Za-z0-9._-]+$/#
        guard spec.count <= longestSpec, parts.count >= 3, parts.allSatisfy({ $0.wholeMatch(of: named) != nil && $0 != "." && $0 != ".." }) else {
            throw Refused("github:\(spec) is not github:<owner>/<repo>/<folder>")
        }
        let (owner, repo, path) = (parts[0], parts[1], parts.dropFirst(2).joined(separator: "/"))
        // One listing of the folder alone: HEAD:<path> names its tree, so the repository's whole tree is never read.
        let listing = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/HEAD:\(path)?recursive=1")!
        let data = try await get(listing, limit: 8 << 20, accept: "application/vnd.github+json")
        guard let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = tree["tree"] as? [[String: Any]],
              let treeSHA = tree["sha"] as? String, treeSHA.wholeMatch(of: #/[0-9a-f]{40}/#) != nil else {
            throw Refused("GitHub's listing of \(path) did not read")
        }
        guard tree["truncated"] as? Bool != true else { throw Refused("GitHub cut its listing of \(path) short") }
        fetched(listing, "tree \(owner)/\(repo)/\(path)", data.count, "\(entries.count) entries, not truncated")
        // Only what a build reads: the manifest, the lockfile, its tsconfig, src/ and assets/. Links and submodules never.
        // Of the tsconfig only `baseUrl` and `paths` reach esbuild, each inside the folder (tsconfigRaw), never `extends`.
        let blobs = entries.compactMap { e -> Blob? in
            guard e["type"] as? String == "blob", let p = e["path"] as? String, let sha = e["sha"] as? String,
                  ["100644", "100755"].contains(e["mode"] as? String ?? "") else { return nil }
            return (p, sha, e["size"] as? Int ?? 0)
        }
        var wanted = blobs.filter { ["package.json", "package-lock.json", "tsconfig.json"].contains($0.path) || $0.path.hasPrefix("src/") || $0.path.hasPrefix("assets/") }
        guard wanted.contains(where: { $0.path == "package.json" }) else { throw Refused("\(path) has no package.json") }
        let source = workspace.appending(path: "source")
        // Then each top-level folder of the extension's own that a relative import in what was fetched names (T15: Google
        // Translate's `../vendor/…`, or `../vendor` itself), held to the same limits; an import that climbs above the
        // folder is refused. Names are compared case-folded, as APFS reads them, so `../Src/…` is never fetched over src/.
        var batch = wanted, have = Set(wanted.map(\.path)), total = 0
        while !batch.isEmpty {
            total = try checkLimits(wanted, path)
            for file in batch { try await fetchBlob(file, owner: owner, repo: repo, path: path, into: source) }
            let folders = try importedFolders(batch.map(\.path), in: source).filter { !["src", "assets", "node_modules"].contains($0.lowercased()) }
            batch = blobs.filter { blob in !have.contains(blob.path) && folders.contains(where: { blob.path.hasPrefix($0 + "/") }) }
            wanted += batch
            have.formUnion(batch.map(\.path))
        }
        var plan = try plan(source, imports: importedPackages(wanted.map(\.path), in: source))
        plan["type"] = "plan"
        plan["tree"] = treeSHA
        plan["source"] = "github:\(owner)/\(repo)/\(path)"
        plan["files"] = wanted.count
        plan["bytes"] = total
        plan["esbuild"] = try esbuildReady(tools) == nil ? "download" : "reuse"
        plan["esbuildBytes"] = esbuildDownload
        plan["esbuildVersion"] = esbuildVersion
        say(plan)
    }

    typealias Blob = (path: String, sha: String, size: Int)

    /// The source folder's limits, read from the listing before a file of `wanted` is fetched; answers its bytes.
    static func checkLimits(_ wanted: [Blob], _ path: String) throws -> Int {
        guard wanted.count <= mostFiles else { throw Refused("\(path) has \(wanted.count) files to fetch, more than \(mostFiles)") }
        if let big = wanted.first(where: { $0.size > fileLimit }) { throw Refused("\(cut(big.path)) is \(big.size) bytes, past \(fileLimit)") }
        let total = wanted.reduce(0) { $0 + $1.size }
        guard total <= folderLimit else { throw Refused("\(path) is \(total) bytes to fetch, past \(folderLimit)") }
        return total
    }

    /// The top-level folders that the relative imports (`from "./…"`, `import("../…")`, `require("../…")`) in `files`
    /// reach, each resolved from its file's own folder. One that climbs above the extension's folder is refused.
    static func importedFolders(_ files: [String], in source: URL) throws -> Set<String> {
        let code = #/(?:\bfrom|\bimport|\brequire)\s*\(?\s*["'](\.{1,2}/[^"'\n]{1,300})["']/#
        var folders = Set<String>()
        for file in files where codeSuffixes.contains(where: file.hasSuffix) {
            guard let text = try? String(contentsOf: source.appending(path: file), encoding: .utf8) else { continue }
            for match in text.matches(of: code) {
                var parts = file.split(separator: "/").dropLast().map(String.init)
                for part in match.1.split(separator: "/").map(String.init) {
                    if part == ".." {
                        guard !parts.isEmpty else { throw Refused("\(cut(file)) imports \(cut(String(match.1))), outside the extension's folder") }
                        parts.removeLast()
                    } else if part != "." { parts.append(part) }
                }
                // Its top-level name: a folder when the listing has files under it (`../vendor`, `../vendor/x`), else nothing.
                if let top = parts.first { folders.insert(top) }
            }
        }
        return folders
    }

    /// The packages the bare imports (`from "x"`, `import("@s/x/y")`, `require("x")`) in `files` name, by package name.
    static func importedPackages(_ files: [String], in source: URL) -> Set<String> {
        let code = #/(?:\bfrom|\bimport|\brequire)\s*\(?\s*["']([^"'./\s][^"'\s]{0,300})["']/#
        var names = Set<String>()
        for file in files where codeSuffixes.contains(where: file.hasSuffix) {
            guard let text = try? String(contentsOf: source.appending(path: file), encoding: .utf8) else { continue }
            for match in text.matches(of: code) where !match.1.contains(":") {
                let parts = match.1.split(separator: "/").map(String.init)
                let name = match.1.hasPrefix("@") ? parts.prefix(2).joined(separator: "/") : parts[0]
                if name.wholeMatch(of: npmName) != nil { names.insert(name) }
            }
        }
        return names
    }

    static let codeSuffixes = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"]

    /// One file of the listing from raw.githubusercontent.com, checked against its git blob hash, into `source`.
    static func fetchBlob(_ file: Blob, owner: String, repo: String, path: String, into source: URL) async throws {
        guard safe(file.path) else { throw Refused("\(cut(file.path)) leaves its folder") }
        let encoded = (path + "/" + file.path).split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0)
        }.joined(separator: "/")
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(encoded)")!
        let body = try await get(url, limit: fileLimit)
        // A git blob's id is sha1("blob <size>\0" + bytes): the file is the one the listing named, whatever HEAD is now.
        let blob = Data("blob \(body.count)\0".utf8) + body
        guard hex(Array(Insecure.SHA1.hash(data: blob))) == file.sha else {
            throw Refused("\(cut(file.path)) from GitHub does not match its listing's blob \(file.sha.prefix(12)); nothing was installed")
        }
        fetched(url, file.path, body.count, "git blob \(file.sha.prefix(12))")
        let to = source.appending(path: file.path)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: to)
    }

    /// The manifest's words and the packages its lockfile pins that the build needs: everything reachable from the root's
    /// dependencies, at the lockfile's own places, the host's externals and their trees left out.
    static func plan(_ source: URL, imports: Set<String> = []) throws -> [String: Any] {
        let manifestData = try Data(contentsOf: source.appending(path: "package.json"))
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let id = manifest["name"] as? String, let commands = manifest["commands"] as? [[String: Any]] else {
            throw Refused("its package.json is not a Raycast manifest")
        }
        // Every remote word Pilot shows is held to a rule here, and again in GitHubInstall.fetch: the id and command
        // names to Pilot's id rule (Extension.isName; a command Extension.isCommandName), the modes to Raycast's three, preference names to an identifier, each
        // package's key, real name and version to npm's (below), the version through ExtensionCatalogue.Version when shown.
        // The title is the one free text, cut to 80 Unicode scalars, last on its line and escaped by Pilot when it builds the
        // result line (ControlGate.Ask.visible), as is every refusal text below that quotes a remote word (cut, at most 120
        // scalars). The tree is the listing's own 40 hex digits (fetch).
        // A command keeps Raycast's capitals (Extension.isCommandName): letters, digits, hyphens and underscores.
        let name = #/[a-z0-9][a-z0-9-]*/#, commandName = #/[A-Za-z0-9][A-Za-z0-9_-]*/#
        guard id.wholeMatch(of: name) != nil, id.count <= 64 else { throw Refused("its package.json names it \"\(cut(id, 64))\", not an id of a-z, 0-9 and hyphens") }
        // Names are compared case-folded: `Index` and `index` would both build dist/index.js on the Mac's own disk.
        var folded = Set<String>()
        for command in commands {
            let c = command["name"] as? String ?? ""
            guard c.wholeMatch(of: commandName) != nil, c.count <= 64 else { throw Refused("a command in its package.json is named \"\(cut(c, 64))\", not letters, digits, hyphens and underscores") }
            guard folded.insert(c.lowercased()).inserted else { throw Refused("two commands in its package.json are both named \"\(cut(c, 64))\", case aside") }
            guard ["view", "no-view", "menu-bar"].contains(command["mode"] as? String ?? "view") else { throw Refused("command \(c) has a mode Raycast does not have") }
        }
        // The extension's, then each command's, a name given twice kept once (RaycastManifest.preferences).
        var preferences: [String] = []
        for list in [manifest["preferences"]] + commands.map({ $0["preferences"] }) {
            for name in (list as? [[String: Any]] ?? []).map({ $0["name"] as? String ?? "" }) where !preferences.contains(name) {
                guard name.wholeMatch(of: preferenceName) != nil, name.count <= 64 else {
                    throw Refused("a preference in its package.json is named \"\(cut(name, 64))\", not a letter then letters, digits, _ and -")
                }
                preferences.append(name)
            }
        }
        let title = manifest["title"] as? String ?? id
        var plan: [String: Any] = [
            "id": id, "title": String(String.UnicodeScalarView(title.unicodeScalars.prefix(longestTitle))), "manifest": hex(Array(SHA256.hash(data: manifestData))),
            "commands": commands.map { ["name": $0["name"] as? String ?? "", "title": $0["title"] as? String ?? "", "mode": $0["mode"] as? String ?? "view"] },
            "preferences": preferences,
        ]
        if let version = manifest["version"] as? String { plan["version"] = version }
        // The dependencies, and each package the code imports that the lockfile pins at the root as dev-only (T15: GitHub's
        // generated code imports graphql-tag, which only its codegen pins), so the plan names and counts it.
        let dependencies = Set((manifest["dependencies"] as? [String: Any] ?? [:]).keys)
        let packages = lock(source)
        let devOnly = imports.subtracting(dependencies).filter { name in
            let entry = packages?["node_modules/" + name]
            return entry?["dev"] as? Bool == true || entry?["devOptional"] as? Bool == true
        }
        let roots = dependencies.union(devOnly).subtracting(externals)
        guard !roots.isEmpty else { plan["packages"] = [[String: Any]](); return plan }
        guard let packages else { throw Refused("it has dependencies but no package-lock.json of version 2 or 3") }
        plan["packages"] = try walk(roots, packages).map { try described($0, packages) }
        return plan
    }

    /// The lockfile's packages, by their places, when it is one of version 2 or 3.
    static func lock(_ source: URL) -> [String: [String: Any]]? {
        guard let lockData = try? Data(contentsOf: source.appending(path: "package-lock.json")),
              let lock = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any],
              let packages = lock["packages"] as? [String: [String: Any]], (lock["lockfileVersion"] as? Int ?? 0) >= 2 else { return nil }
        return packages
    }

    /// Node's lookup: <from>/node_modules/<name>, then each folder up to the root's node_modules.
    static func resolve(_ name: String, from key: String, _ packages: [String: [String: Any]]) -> String? {
        var at = key
        while true {
            let candidate = (at.isEmpty ? "" : at + "/") + "node_modules/" + name
            if packages[candidate] != nil { return candidate }
            guard !at.isEmpty else { return nil }
            if let range = at.range(of: "/node_modules/", options: .backwards) { at = String(at[..<range.lowerBound]) } else { at = "" }
        }
    }

    /// The lockfile places of everything reachable from `roots` (names the root requires), the host's externals and
    /// their trees left out, and the places in `skip` (already unpacked) not walked again.
    static func walk(_ roots: Set<String>, _ packages: [String: [String: Any]], skip: Set<String> = []) throws -> [String] {
        var needed: [String] = [], seen = skip, queue: [(name: String, from: String, optional: Bool)] = roots.sorted().map { ($0, "", false) }
        while !queue.isEmpty {
            let (name, from, optional) = queue.removeFirst()
            guard !externals.contains(name) else { continue }
            guard let key = resolve(name, from: from, packages) else {
                if optional { continue }
                throw Refused("its package-lock.json lacks \(cut(name)), which \(from.isEmpty ? "it" : cut(from)) needs")
            }
            guard seen.insert(key).inserted else { continue }
            let entry = packages[key] ?? [:]
            if entry["inBundle"] as? Bool == true { continue }
            if entry["link"] as? Bool == true { throw Refused("\(cut(key)) is a link in its lockfile, which Pilot does not install") }
            // A platform package for another Mac or system is skipped when optional, refused when not.
            let os = entry["os"] as? [String], cpu = entry["cpu"] as? [String]
            if os.map({ !$0.contains("darwin") }) ?? false || cpu.map({ !$0.contains("arm64") }) ?? false {
                if optional || entry["optional"] as? Bool == true { continue }
                throw Refused("\(cut(key)) is not built for this Mac (os \(cut("\(os ?? [])")), cpu \(cut("\(cpu ?? [])")))")
            }
            needed.append(key)
            let peersOptional = (entry["peerDependenciesMeta"] as? [String: [String: Any]] ?? [:]).filter { $0.value["optional"] as? Bool == true }.keys
            for dep in (entry["dependencies"] as? [String: Any] ?? [:]).keys.sorted() { queue.append((dep, key, false)) }
            for dep in (entry["optionalDependencies"] as? [String: Any] ?? [:]).keys.sorted() { queue.append((dep, key, true)) }
            for dep in (entry["peerDependencies"] as? [String: Any] ?? [:]).keys.sorted() { queue.append((dep, key, peersOptional.contains(dep))) }
        }
        guard needed.count + skip.count <= mostPackages else { throw Refused("it needs \(needed.count + skip.count) packages, more than \(mostPackages)") }
        return needed
    }

    /// One package of the plan: its place, real name, version, the registry URL it must come from and its sha512.
    static func described(_ key: String, _ packages: [String: [String: Any]]) throws -> [String: String] {
        let entry = packages[key] ?? [:]
        guard safe(key), key.hasPrefix("node_modules/") else { throw Refused("\(cut(key)) leaves its folder") }
        // Each name on the key's path is the folder Node requires it by, an alias when the lockfile says so (npm:
        // string-width-cjs is string-width); the real name, the entry's own `name` else the key's last name, is the one
        // the registry serves it under: <name>/-/<name less its scope>-<version>.tgz. Both are held to npm's names,
        // legacy ones included (JSONStream), and the version to semver's characters.
        let names = key.dropFirst("node_modules/".count).components(separatedBy: "/node_modules/")
        let version = entry["version"] as? String ?? ""
        let real = entry["name"] as? String ?? names.last ?? ""
        guard (names + [real]).allSatisfy({ $0.wholeMatch(of: npmName) != nil && $0.count <= 214 }),
              version.wholeMatch(of: #/[0-9A-Za-z.+-]+/#) != nil, version.count <= 64 else { throw Refused("\(cut(key)) is not an npm package name and version") }
        let expected = registry + real + "/-/" + (real.split(separator: "/").last.map(String.init) ?? real) + "-" + version + ".tgz"
        // An entry with no `resolved` (an older npm left it out: Pomodoro's node-fetch, T28) is fetched from the registry by
        // its name and version; its sha512 below still decides, so one with neither is refused.
        let resolved = entry["resolved"] as? String ?? expected
        guard resolved == expected else {
            throw Refused("\(cut(key)) does not come from its own place on \(registry) (\(cut(entry["resolved"] as? String ?? "no resolved URL")))")
        }
        guard let integrity = entry["integrity"] as? String, sha512(integrity) != nil else {
            throw Refused("\(cut(key)) has no sha512 integrity in its lockfile")
        }
        return ["key": key, "name": real, "version": version, "resolved": resolved, "integrity": integrity]
    }

    // MARK: Build

    static func build(workspace: URL, tools: URL, plan data: Data, prelude: URL? = nil) async throws {
        guard let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let manifest = plan["manifest"] as? String,
              let packages = plan["packages"] as? [[String: String]], let commands = plan["commands"] as? [[String: String]] else {
            throw Refused("the build was handed no plan")
        }
        let source = workspace.appending(path: "source"), fm = FileManager.default
        let manifestData = try Data(contentsOf: source.appending(path: "package.json"))
        guard hex(Array(SHA256.hash(data: manifestData))) == manifest else { throw Refused("its package.json changed after the plan") }
        let esbuild = try await esbuildTool(tools)
        var unpacked = 0
        for package in packages {
            guard let key = package["key"], let resolved = package["resolved"], let integrity = package["integrity"], let url = URL(string: resolved),
                  resolved.hasPrefix(registry), safe(key), key.hasPrefix("node_modules/") else { throw Refused("a package in the plan is not the registry's") }
            let tarball = try await get(url, limit: tarballLimit)
            guard matches(tarball, integrity) else {
                throw Refused("\(key) \(package["version"] ?? "") does not match its lockfile's integrity; nothing was installed")
            }
            fetched(url, "\(key.dropFirst("node_modules/".count))@\(package["version"] ?? "")", tarball.count, "sha512 integrity")
            unpacked += try untar(try gunzip(tarball, limit: unpackedLimit - unpacked), into: source.appending(path: key))
            guard unpacked <= unpackedLimit else { throw Refused("its packages unpack past \(unpackedLimit) bytes") }
        }
        let built = workspace.appending(path: "built")
        try fm.createDirectory(at: built.appending(path: "dist"), withIntermediateDirectories: true)
        var required = Set<String>()
        for command in commands {
            guard let name = command["name"], name.wholeMatch(of: #/^[A-Za-z0-9._-]+$/#) != nil else { throw Refused("a command has no name") }
            guard let entry = ["tsx", "ts", "jsx", "js"].map({ "src/\(name).\($0)" }).first(where: { fm.fileExists(atPath: source.appending(path: $0).path) }) else {
                throw Refused("command \(name) has no src/\(name).tsx, .ts, .jsx or .js")
            }
            let meta = workspace.appending(path: "meta-\(name).json")
            try esbuildRun(esbuild.url, in: source, [
                entry, "--bundle", "--platform=node", "--format=cjs", "--target=es2022", "--jsx=automatic", "--log-level=error",
                // dynamic import() becomes require(): a bare JSContext has no module loader (useSQL's node:sqlite, T7).
                "--tsconfig-raw=\(tsconfigRaw(source))", "--supported:dynamic-import=false", "--define:process.env.NODE_ENV=\"production\"", "--external:@raycast/api", "--external:react",
                "--external:react/*", "--metafile=\(meta.path)", "--outfile=\(built.appending(path: "dist/\(name).js").path)",
            ])
            // Every file bundled must be the folder's own or a package unpacked into it: Node's lookup also climbs to
            // folders above the workspace (~/node_modules), and nothing from there may enter a bundle.
            guard let metaData = try? Data(contentsOf: meta), let read = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                  let inputs = (read["inputs"] as? [String: Any])?.keys else { throw Refused("esbuild wrote no list of what it bundled") }
            let root = source.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            // An absolute input is refused as it stands: appending it to the folder would read it as inside.
            if let outside = inputs.first(where: { $0.hasPrefix("/") || !source.appending(path: $0).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) }) {
                throw Refused("command \(name) would bundle \(cut(outside)), which is outside the extension's folder; nothing was installed")
            }
            required.formUnion(builtins(read))
            say(["type": "bundle", "command": name, "entry": entry,
                 "bytes": (try? fm.attributesOfItem(atPath: built.appending(path: "dist/\(name).js").path)[.size] as? Int) ?? 0])
        }
        try manifestData.write(to: built.appending(path: "package.json"))
        if fm.fileExists(atPath: source.appending(path: "assets").path) {
            try fm.copyItem(at: source.appending(path: "assets"), to: built.appending(path: "assets"))
        }
        say(["type": "built", "folder": built.path, "esbuild": esbuild.reused ? "reused" : "downloaded", "esbuildPath": esbuild.url.path,
             "esbuildVersion": esbuildVersion, "needs": needs(required, prelude: prelude)])
    }

    // MARK: Node modules (T25)

    /// Node's own module names (nodejs.org/api/modules.html, `require('node:module').builtinModules` in Node 22, read
    /// 2026-11-20), `node:` dropped: the only words a `needs` line may carry, so it never repeats a name the extension made up.
    static let nodeBuiltins: Set<String> = [
        "assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram",
        "diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises", "http", "http2", "https", "inspector",
        "inspector/promises", "module", "net", "os", "path", "path/posix", "path/win32", "perf_hooks", "process", "punycode",
        "querystring", "readline", "readline/promises", "repl", "sqlite", "stream", "stream/consumers", "stream/promises",
        "stream/web", "string_decoder", "sys", "test", "timers", "timers/promises", "tls", "trace_events", "tty", "url", "util",
        "util/types", "v8", "vm", "wasi", "worker_threads", "zlib",
    ]

    /// The Node built-ins one command's bundle leaves to `require`: esbuild's metafile, every output's external imports.
    static func builtins(_ meta: [String: Any]) -> Set<String> {
        let outputs = (meta["outputs"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let imports = outputs.flatMap { ($0["imports"] as? [[String: Any]]) ?? [] }
        return Set(imports.compactMap { i -> String? in
            guard i["external"] as? Bool == true, let path = i["path"] as? String else { return nil }
            let plain = path.hasPrefix("node:") ? String(path.dropFirst(5)) : path
            return nodeBuiltins.contains(plain) ? plain : nil
        })
    }

    /// Of `required`, the ones the prelude lacks or only loads, A to Z. A prelude that cannot be read has none, so every
    /// one is named: the result line then says too much, never too little.
    static func needs(_ required: Set<String>, prelude: URL?) -> [String] {
        let (provided, loadOnly) = prelude.flatMap(preludeModules) ?? ([], [])
        return required.filter { !provided.contains($0) || loadOnly.contains($0) }.sorted()
    }

    /// The prelude's own `__pilotModules()`, in a JSContext that runs only the prelude: its native calls answer nothing.
    static func preludeModules(_ prelude: URL) -> (Set<String>, Set<String>)? {
        guard let source = try? String(contentsOf: prelude, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript("globalThis.__native = new Proxy({}, { get: () => () => ({}) });")
        context.evaluateScript(source, withSourceURL: prelude)
        guard context.exception == nil, let read = context.objectForKeyedSubscript("__pilotModules")?.call(withArguments: [])?.toDictionary(),
              let provided = read["provided"] as? [String], let loadOnly = read["loadOnly"] as? [String] else { return nil }
        return (Set(provided), Set(loadOnly))
    }

    /// esbuild's tsconfig: the extension's own `baseUrl` and `paths` alone (Obsidian's `@/*` → `src/*`), when each is a
    /// relative place inside the folder (safe(): no `..`, never absolute) and the file reads as JSON; else `{}`. No other
    /// option and no `extends` is passed, and the metafile check after the build still refuses any input outside the folder.
    static func tsconfigRaw(_ source: URL) -> String {
        guard let data = try? Data(contentsOf: source.appending(path: "tsconfig.json")),
              let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = read["compilerOptions"] as? [String: Any], let paths = options["paths"] as? [String: [String]] else { return "{}" }
        let base = options["baseUrl"] as? String ?? "."
        func inside(_ place: String) -> Bool {
            let plain = place.hasPrefix("./") ? String(place.dropFirst(2)) : place
            return plain.isEmpty || plain == "." || safe(plain.replacingOccurrences(of: "*", with: "x"))
        }
        guard inside(base), paths.count <= 50, paths.allSatisfy({ key, targets in
            key.count <= 200 && !key.contains("..") && !key.hasPrefix("/") && targets.count <= 10 && targets.allSatisfy(inside)
        }), let raw = try? JSONSerialization.data(withJSONObject: ["compilerOptions": ["baseUrl": base, "paths": paths]], options: .sortedKeys) else { return "{}" }
        return String(decoding: raw, as: UTF8.self)
    }

    // MARK: esbuild

    struct Tool { let url: URL, reused: Bool }

    /// The esbuild already in `tools` while its bytes hash to the pinned sha256, else nil.
    static func esbuildReady(_ tools: URL) throws -> URL? {
        let binary = tools.appending(path: "esbuild-\(esbuildVersion)/esbuild")
        guard let data = try? Data(contentsOf: binary) else { return nil }
        return hex(Array(SHA256.hash(data: data))) == esbuildSHA256 ? binary : nil
    }

    /// esbuild from `tools`, or downloaded once into it: the registry's tarball checked by the pinned sha512, its
    /// `bin/esbuild` kept only when it hashes to the pinned sha256 and its `--version` reads back. A temporary folder left
    /// by a run that stopped midway is swept first.
    static func esbuildTool(_ tools: URL) async throws -> Tool {
        if let ready = try esbuildReady(tools) {
            say(["type": "tool", "esbuild": "reused", "path": ready.path])
            return Tool(url: ready, reused: true)
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard machine == "arm64" else { throw Refused("Pilot's esbuild is for Apple silicon; this Mac is \(machine)") }
        let url = URL(string: esbuildURL)!
        let tarball = try await get(url, limit: tarballLimit)
        guard matches(tarball, esbuildIntegrity) else { throw Refused("esbuild \(esbuildVersion) from the registry does not match its pinned sha512") }
        fetched(url, "@esbuild/darwin-arm64@\(esbuildVersion)", tarball.count, "sha512 integrity, pinned")
        let fm = FileManager.default
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        sweep(tools, prefix: ".esbuild-")
        let temp = tools.appending(path: ".esbuild-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        _ = try untar(try gunzip(tarball, limit: 64 << 20), into: temp.appending(path: "package"))
        let binary = temp.appending(path: "package/bin/esbuild")
        let data = try Data(contentsOf: binary)
        guard hex(Array(SHA256.hash(data: data))) == esbuildSHA256 else { throw Refused("the esbuild unpacked does not hash to its pinned sha256") }
        let folder = temp.appending(path: "esbuild-\(esbuildVersion)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: binary, to: folder.appending(path: "esbuild"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "esbuild").path)
        // Read back before it is kept, so a binary that is not this version never lands in Tools to be reused.
        let version = try esbuildRun(folder.appending(path: "esbuild"), in: temp, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == esbuildVersion else { throw Refused("the esbuild downloaded says it is \(version), not \(esbuildVersion)") }
        let final = tools.appending(path: "esbuild-\(esbuildVersion)")
        try? fm.removeItem(at: final)
        try fm.moveItem(at: folder, to: final)
        let tool = final.appending(path: "esbuild")
        say(["type": "tool", "esbuild": "downloaded", "path": tool.path, "version": version])
        return Tool(url: tool, reused: false)
    }

    /// Runs esbuild in `folder` with the system's PATH only, so no Node or tool of the user's is found; its stdout, or
    /// its stderr as the refusal.
    @discardableResult
    static func esbuildRun(_ tool: URL, in folder: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory(), "TMPDIR": NSTemporaryDirectory()]
        let out = Pipe(), err = Pipe()
        (process.standardOutput, process.standardError, process.standardInput) = (out, err, FileHandle.nullDevice)
        try process.run()
        let errors = Drain(err.fileHandleForReading.fileDescriptor)
        Thread.detachNewThread { errors.run() }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errors.done.wait()
        guard process.terminationStatus == 0 else {
            throw Refused("esbuild stopped: " + cut(String(decoding: errors.data, as: UTF8.self), 600))
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Network, hashes and archives

    static func get(_ url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("pilot-ext-host", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        // Taken in the chunks URLSession hands over and stopped at `limit`: a body past it is never held whole.
        let capped = Capped(limit: limit)
        return try await withCheckedThrowingContinuation { continuation in
            capped.start(Host.session.dataTask(with: request), continuation)
        }.get(url, limit: limit)
    }

    /// One download's task delegate: refuses a status other than 200 or a stated length past `limit` before any body,
    /// adds each chunk as it comes, and cancels the task once the body runs past `limit`.
    final class Capped: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        struct Result: Sendable {
            let data: Data, status: Int, length: Int64, past: Bool
            func get(_ url: URL, limit: Int) throws -> Data {
                guard status == 200 else { throw Refused("\(url.host() ?? "") answered \(status) for \(url.path())") }
                guard length <= Int64(limit) else { throw Refused("\(url.path()) is \(length) bytes, past \(limit)") }
                guard !past else { throw Refused("\(url.path()) runs past \(limit) bytes") }
                return data
            }
        }

        let limit: Int
        private let lock = NSLock()
        private var data = Data(), status = 0, length: Int64 = -1, past = false
        private var continuation: CheckedContinuation<Result, any Error>?

        init(limit: Int) { self.limit = limit }

        func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Result, any Error>) {
            lock.withLock { self.continuation = continuation }
            task.delegate = self
            task.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let ok = lock.withLock {
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                length = response.expectedContentLength
                return status == 200 && length <= Int64(limit)
            }
            completionHandler(ok ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let over = lock.withLock {
                guard !past else { return false }
                if data.count + chunk.count > limit { past = true; data = Data(); return true }
                data.append(chunk)
                return false
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, result) = lock.withLock {
                defer { self.continuation = nil }
                return (self.continuation, Result(data: data, status: status, length: length, past: past))
            }
            // A cancel of this delegate's own (a status, a length or a body past the limit) answers why; any other error is the error.
            let refused = result.past || (result.status != 0 && (result.status != 200 || result.length > Int64(limit)))
            if let error, !refused { continuation?.resume(throwing: error) } else { continuation?.resume(returning: result) }
        }
    }

    /// The sha512 digests an npm integrity string names: Subresource Integrity, hashes split by spaces, others ignored.
    static func sha512(_ integrity: String) -> [Data]? {
        let found = integrity.split(whereSeparator: \.isWhitespace).compactMap { token -> Data? in
            token.hasPrefix("sha512-") ? Data(base64Encoded: String(token.dropFirst(7))) : nil
        }
        return found.isEmpty ? nil : found
    }

    /// Whether `data` hashes to a sha512 its integrity string names.
    static func matches(_ data: Data, _ integrity: String) -> Bool {
        guard let wanted = sha512(integrity) else { return false }
        return wanted.contains(Data(SHA512.hash(data: data)))
    }

    /// Removes the folders in `folder` named `prefix…` that are over an hour old: what a run stopped midway left.
    static func sweep(_ folder: URL, prefix: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            let url = folder.appending(path: name)
            if let made = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, made < Date(timeIntervalSinceNow: -3600) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// A remote word as a refusal quotes it: at most `longest` Unicode scalars, then "…". Pilot writes out its control
    /// and hidden scalars (ControlGate.Ask.visible) before any of it reaches a terminal or the prompt.
    static func cut(_ text: String, _ longest: Int = 120) -> String {
        text.unicodeScalars.count <= longest ? text : String(String.UnicodeScalarView(text.unicodeScalars.prefix(longest))) + "…"
    }

    /// A relative path with no empty, `.` or `..` part.
    static func safe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// A gzip member's bytes: its header read (RFC 1952), its deflate body inflated by Compression's raw zlib, at most `limit`.
    static func gunzip(_ data: Data, limit: Int) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw Refused("a download is not gzip") }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { throw Refused("a download's gzip header runs past its end") }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Refused("Compression did not start")
        }
        defer { compression_stream_destroy(&stream) }
        var out = Data(), buffer = [UInt8](repeating: 0, count: 1 << 16)
        try b.withUnsafeBufferPointer { all in
            stream.src_ptr = all.baseAddress! + i
            stream.src_size = b.count - 8 - i
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> compression_status in
                    stream.dst_ptr = out.baseAddress!
                    stream.dst_size = out.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                out.append(contentsOf: buffer.prefix(buffer.count - stream.dst_size))
                guard out.count <= limit else { throw Refused("a download unpacks past \(limit) bytes") }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw Refused("a download's gzip body does not inflate") }
            }
        }
        return out
    }

    /// A tar archive's regular files and folders into `folder`, each path's first part (npm's `package/`) dropped;
    /// links and devices are skipped and a path leaving the folder refuses. ustar's prefix, pax `path` and GNU long
    /// names are read. Answers the bytes written.
    static func untar(_ data: Data, into folder: URL) throws -> Int {
        let b = [UInt8](data), fm = FileManager.default
        func text(_ at: Int, _ count: Int) -> String {
            String(decoding: b[at..<min(at + count, b.count)].prefix { $0 != 0 }, as: UTF8.self)
        }
        func number(_ at: Int, _ count: Int) -> Int {
            if b[at] & 0x80 != 0 { return b[(at + 1)..<(at + count)].reduce(0) { $0 << 8 | Int($1) } }
            return Int(text(at, count).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
        }
        var offset = 0, written = 0, longName: String?, paxPath: String?
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        while offset + 512 <= b.count {
            guard b[offset..<(offset + 512)].contains(where: { $0 != 0 }) else { break }
            let name = text(offset, 100), size = number(offset + 124, 12), type = b[offset + 156]
            let prefix = text(offset + 257, 6).hasPrefix("ustar") ? text(offset + 345, 155) : ""
            let start = offset + 512
            guard size >= 0, size <= b.count - start else { throw Refused("a package's archive is cut short") }
            offset = start + (size + 511) / 512 * 512
            let body = Data(b[start..<(start + size)])
            switch type {
            case UInt8(ascii: "x"):
                for record in String(decoding: body, as: UTF8.self).split(separator: "\n") {
                    if let range = record.range(of: " path=") { paxPath = String(record[range.upperBound...]) }
                }
                continue
            case UInt8(ascii: "g"): continue
            case UInt8(ascii: "L"): longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self); continue
            default: break
            }
            let full = paxPath ?? longName ?? (prefix.isEmpty ? name : prefix + "/" + name)
            (paxPath, longName) = (nil, nil)
            // npm packs some archives as `package/./dist/…`: a single `.` segment is dropped, never `..`, which safe() refuses.
            let inner = full.split(separator: "/").filter { $0 != "." }.dropFirst().joined(separator: "/")
            guard !inner.isEmpty else { continue }
            guard safe(inner) else { throw Refused("a package's archive holds \(cut(full)), which leaves its folder") }
            let to = folder.appending(path: inner)
            switch type {
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: to)
                try fm.setAttributes([.posixPermissions: number(start - 512 + 100, 8) & 0o111 != 0 ? 0o755 : 0o644], ofItemAtPath: to.path)
                written += size
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            default: continue
            }
        }
        return written
    }
}

extension Installer {
    static func hex<S: Sequence<UInt8>>(_ bytes: S) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
