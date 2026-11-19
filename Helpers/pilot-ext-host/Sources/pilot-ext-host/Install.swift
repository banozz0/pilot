import Compression
import CryptoKit
import Foundation

// The GitHub install route (ADR 0017, T6): a Raycast extension's folder from GitHub, built on this Mac without Node. Pilot
// runs the host twice, never with a JSContext:
//   pilot-ext-host --fetch <owner>/<repo>/<path> <workspace> <tools>
//     one recursive tree listing of that folder (api.github.com), then each file it needs from raw.githubusercontent.com,
//     checked against the listing's git blob hash, into <workspace>/source; its last line is the plan Pilot asks about:
//     the manifest's commands and preferences, the packages its lockfile pins, and whether esbuild is in <tools> yet.
//   pilot-ext-host --build <workspace> <tools>, the asked plan on stdin
//     esbuild 0.28.2 (once, checked by its pinned sha512, kept in <tools>), each package's tarball from the npm registry
//     checked by the lockfile's sha512 and unpacked here (no npm, so no install script ever runs), then esbuild per
//     command into <workspace>/built: package.json, assets/ and dist/<command>.js, which Pilot then checks and installs.
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

    /// What the host supplies itself, so a package's own copy is never fetched or bundled: two Reacts break hooks.
    static let externals: Set<String> = ["@raycast/api", "react"]
    static let registry = "https://registry.npmjs.org/"

    // Limits: the source folder, read from the listing before any file is fetched, and the packages.
    static let mostFiles = 400, fileLimit = 5 << 20, folderLimit = 30 << 20
    static let mostPackages = 300, tarballLimit = 20 << 20, unpackedLimit = 200 << 20

    static func run(_ arguments: [String]) -> Never {
        Task.detached {
            do {
                switch arguments.first {
                case "--fetch" where arguments.count == 4:
                    try await fetch(arguments[1], workspace: URL(filePath: arguments[2]), tools: URL(filePath: arguments[3]))
                case "--build" where arguments.count == 3:
                    let input = FileHandle.standardInput.readDataToEndOfFile()
                    try await build(workspace: URL(filePath: arguments[1]), tools: URL(filePath: arguments[2]), plan: input)
                default:
                    throw Refused("usage: pilot-ext-host --fetch <owner>/<repo>/<path> <workspace> <tools> | --build <workspace> <tools>")
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
        guard parts.count >= 3, parts.allSatisfy({ $0.wholeMatch(of: named) != nil && $0 != "." && $0 != ".." }) else {
            throw Refused("github:\(spec) is not github:<owner>/<repo>/<folder>")
        }
        let (owner, repo, path) = (parts[0], parts[1], parts.dropFirst(2).joined(separator: "/"))
        // One listing of the folder alone: HEAD:<path> names its tree, so the repository's whole tree is never read.
        let listing = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/HEAD:\(path)?recursive=1")!
        let data = try await get(listing, limit: 8 << 20, accept: "application/vnd.github+json")
        guard let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = tree["tree"] as? [[String: Any]],
              let treeSHA = tree["sha"] as? String else { throw Refused("GitHub's listing of \(path) did not read") }
        guard tree["truncated"] as? Bool != true else { throw Refused("GitHub cut its listing of \(path) short") }
        fetched(listing, "tree \(owner)/\(repo)/\(path)", data.count, "\(entries.count) entries, not truncated")
        // Only what a build reads: the manifest, the lockfile, tsconfig, src/ and assets/. Links and submodules never.
        let wanted = entries.compactMap { e -> (path: String, sha: String, size: Int)? in
            guard e["type"] as? String == "blob", let p = e["path"] as? String, let sha = e["sha"] as? String,
                  ["100644", "100755"].contains(e["mode"] as? String ?? "") else { return nil }
            let top = ["package.json", "package-lock.json", "tsconfig.json"].contains(p)
            guard top || p.hasPrefix("src/") || p.hasPrefix("assets/") else { return nil }
            return (p, sha, e["size"] as? Int ?? 0)
        }
        guard wanted.contains(where: { $0.path == "package.json" }) else { throw Refused("\(path) has no package.json") }
        guard wanted.count <= mostFiles else { throw Refused("\(path) has \(wanted.count) files to fetch, more than \(mostFiles)") }
        if let big = wanted.first(where: { $0.size > fileLimit }) { throw Refused("\(big.path) is \(big.size) bytes, past \(fileLimit)") }
        let total = wanted.reduce(0) { $0 + $1.size }
        guard total <= folderLimit else { throw Refused("\(path) is \(total) bytes to fetch, past \(folderLimit)") }
        let source = workspace.appending(path: "source")
        for file in wanted {
            guard safe(file.path) else { throw Refused("\(file.path) leaves its folder") }
            let encoded = (path + "/" + file.path).split(separator: "/").map {
                $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0)
            }.joined(separator: "/")
            let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(encoded)")!
            let body = try await get(url, limit: fileLimit)
            // A git blob's id is sha1("blob <size>\0" + bytes): the file is the one the listing named, whatever HEAD is now.
            let blob = Data("blob \(body.count)\0".utf8) + body
            guard hex(Array(Insecure.SHA1.hash(data: blob))) == file.sha else {
                throw Refused("\(file.path) from GitHub does not match its listing's blob \(file.sha.prefix(12)); nothing was installed")
            }
            fetched(url, file.path, body.count, "git blob \(file.sha.prefix(12))")
            let to = source.appending(path: file.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: to)
        }
        var plan = try plan(source)
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

    /// The manifest's words and the packages its lockfile pins that the build needs: everything reachable from the root's
    /// dependencies, at the lockfile's own places, the host's externals and their trees left out.
    static func plan(_ source: URL) throws -> [String: Any] {
        let manifestData = try Data(contentsOf: source.appending(path: "package.json"))
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let id = manifest["name"] as? String, let commands = manifest["commands"] as? [[String: Any]] else {
            throw Refused("its package.json is not a Raycast manifest")
        }
        // The extension's, then each command's, a name given twice kept once (RaycastManifest.preferences).
        var preferences: [String] = []
        for list in [manifest["preferences"]] + commands.map({ $0["preferences"] }) {
            for name in (list as? [[String: Any]] ?? []).compactMap({ $0["name"] as? String }) where !preferences.contains(name) { preferences.append(name) }
        }
        var plan: [String: Any] = [
            "id": id, "title": manifest["title"] as? String ?? id, "manifest": hex(Array(SHA256.hash(data: manifestData))),
            "commands": commands.map { ["name": $0["name"] as? String ?? "", "title": $0["title"] as? String ?? "", "mode": $0["mode"] as? String ?? "view"] },
            "preferences": preferences,
        ]
        if let version = manifest["version"] as? String { plan["version"] = version }
        let roots = Set((manifest["dependencies"] as? [String: Any] ?? [:]).keys).subtracting(externals)
        guard !roots.isEmpty else { plan["packages"] = [[String: Any]](); return plan }
        guard let lockData = try? Data(contentsOf: source.appending(path: "package-lock.json")),
              let lock = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any],
              let packages = lock["packages"] as? [String: [String: Any]], (lock["lockfileVersion"] as? Int ?? 0) >= 2 else {
            throw Refused("it has dependencies but no package-lock.json of version 2 or 3")
        }
        // Node's lookup: <from>/node_modules/<name>, then each folder up to the root's node_modules.
        func resolve(_ name: String, from key: String) -> String? {
            var at = key
            while true {
                let candidate = (at.isEmpty ? "" : at + "/") + "node_modules/" + name
                if packages[candidate] != nil { return candidate }
                guard !at.isEmpty else { return nil }
                if let range = at.range(of: "/node_modules/", options: .backwards) { at = String(at[..<range.lowerBound]) } else { at = "" }
            }
        }
        var needed: [String] = [], seen = Set<String>(), queue: [(name: String, from: String, optional: Bool)] = roots.sorted().map { ($0, "", false) }
        while !queue.isEmpty {
            let (name, from, optional) = queue.removeFirst()
            guard !externals.contains(name) else { continue }
            guard let key = resolve(name, from: from) else {
                if optional { continue }
                throw Refused("its package-lock.json lacks \(name), which \(from.isEmpty ? "it" : from) needs")
            }
            guard seen.insert(key).inserted else { continue }
            let entry = packages[key] ?? [:]
            if entry["inBundle"] as? Bool == true { continue }
            if entry["link"] as? Bool == true { throw Refused("\(key) is a link in its lockfile, which Pilot does not install") }
            // A platform package for another Mac or system is skipped when optional, refused when not.
            let os = entry["os"] as? [String], cpu = entry["cpu"] as? [String]
            if os.map({ !$0.contains("darwin") }) ?? false || cpu.map({ !$0.contains("arm64") }) ?? false {
                if optional || entry["optional"] as? Bool == true { continue }
                throw Refused("\(key) is not built for this Mac (os \(os ?? []), cpu \(cpu ?? []))")
            }
            needed.append(key)
            let peersOptional = (entry["peerDependenciesMeta"] as? [String: [String: Any]] ?? [:]).filter { $0.value["optional"] as? Bool == true }.keys
            for dep in (entry["dependencies"] as? [String: Any] ?? [:]).keys.sorted() { queue.append((dep, key, false)) }
            for dep in (entry["optionalDependencies"] as? [String: Any] ?? [:]).keys.sorted() { queue.append((dep, key, true)) }
            for dep in (entry["peerDependencies"] as? [String: Any] ?? [:]).keys.sorted() { queue.append((dep, key, peersOptional.contains(dep))) }
        }
        guard needed.count <= mostPackages else { throw Refused("it needs \(needed.count) packages, more than \(mostPackages)") }
        plan["packages"] = try needed.map { key -> [String: Any] in
            let entry = packages[key] ?? [:]
            guard safe(key), key.hasPrefix("node_modules/") else { throw Refused("\(key) leaves its folder") }
            guard let resolved = entry["resolved"] as? String, resolved.hasPrefix(registry), URL(string: resolved) != nil else {
                throw Refused("\(key) does not come from \(registry) (\(entry["resolved"] as? String ?? "no resolved URL"))")
            }
            guard let integrity = entry["integrity"] as? String, integrity.hasPrefix("sha512-") else {
                throw Refused("\(key) has no sha512 integrity in its lockfile")
            }
            return ["key": key, "version": entry["version"] as? String ?? "", "resolved": resolved, "integrity": integrity]
        }
        return plan
    }

    // MARK: Build

    static func build(workspace: URL, tools: URL, plan data: Data) async throws {
        guard let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let manifest = plan["manifest"] as? String,
              let packages = plan["packages"] as? [[String: String]], let commands = plan["commands"] as? [[String: String]] else {
            throw Refused("the build was handed no plan")
        }
        let source = workspace.appending(path: "source"), fm = FileManager.default
        let manifestData = try Data(contentsOf: source.appending(path: "package.json"))
        guard hex(Array(SHA256.hash(data: manifestData))) == manifest else { throw Refused("its package.json changed after the question") }
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
        for command in commands {
            guard let name = command["name"], name.wholeMatch(of: #/^[A-Za-z0-9._-]+$/#) != nil else { throw Refused("a command has no name") }
            guard let entry = ["tsx", "ts", "jsx", "js"].map({ "src/\(name).\($0)" }).first(where: { fm.fileExists(atPath: source.appending(path: $0).path) }) else {
                throw Refused("command \(name) has no src/\(name).tsx, .ts, .jsx or .js")
            }
            try esbuildRun(esbuild.url, in: source, [
                entry, "--bundle", "--platform=node", "--format=cjs", "--target=es2022", "--jsx=automatic", "--log-level=error",
                "--define:process.env.NODE_ENV=\"production\"", "--external:@raycast/api", "--external:react", "--external:react/*",
                "--outfile=\(built.appending(path: "dist/\(name).js").path)",
            ])
            say(["type": "bundle", "command": name, "entry": entry,
                 "bytes": (try? fm.attributesOfItem(atPath: built.appending(path: "dist/\(name).js").path)[.size] as? Int) ?? 0])
        }
        try manifestData.write(to: built.appending(path: "package.json"))
        if fm.fileExists(atPath: source.appending(path: "assets").path) {
            try fm.copyItem(at: source.appending(path: "assets"), to: built.appending(path: "assets"))
        }
        say(["type": "built", "folder": built.path, "esbuild": esbuild.reused ? "reused" : "downloaded", "esbuildPath": esbuild.url.path])
    }

    // MARK: esbuild

    struct Tool { let url: URL, reused: Bool }

    /// The esbuild already in `tools` when its bytes still hash as they did when it was unpacked, else nil.
    static func esbuildReady(_ tools: URL) throws -> URL? {
        let folder = tools.appending(path: "esbuild-\(esbuildVersion)"), binary = folder.appending(path: "esbuild")
        guard let data = try? Data(contentsOf: binary), let saved = try? String(contentsOf: folder.appending(path: "esbuild.sha256"), encoding: .utf8)
        else { return nil }
        return hex(Array(SHA256.hash(data: data))) == saved.trimmingCharacters(in: .whitespacesAndNewlines) ? binary : nil
    }

    /// esbuild from `tools`, or downloaded once into it: the registry's tarball checked by the pinned sha512, its
    /// `bin/esbuild` kept with the sha256 it had, and `--version` read back before it builds anything.
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
        let temp = tools.appending(path: ".esbuild-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        _ = try untar(try gunzip(tarball, limit: 64 << 20), into: temp.appending(path: "package"))
        let binary = temp.appending(path: "package/bin/esbuild")
        let data = try Data(contentsOf: binary)
        let folder = temp.appending(path: "esbuild-\(esbuildVersion)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: binary, to: folder.appending(path: "esbuild"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "esbuild").path)
        try hex(Array(SHA256.hash(data: data))).write(to: folder.appending(path: "esbuild.sha256"), atomically: true, encoding: .utf8)
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
            throw Refused("esbuild stopped: " + String(decoding: errors.data, as: UTF8.self).prefix(600))
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Network, hashes and archives

    static func get(_ url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("pilot-ext-host", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await Host.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Refused("\(url.host() ?? "") answered \(status) for \(url.path())") }
        guard data.count <= limit else { throw Refused("\(url.path()) is \(data.count) bytes, past \(limit)") }
        return data
    }

    /// Whether `data` hashes to an npm integrity string's sha512.
    static func matches(_ data: Data, _ integrity: String) -> Bool {
        guard integrity.hasPrefix("sha512-"), let want = Data(base64Encoded: String(integrity.dropFirst(7))) else { return false }
        return Data(SHA512.hash(data: data)) == want
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
            guard size >= 0, start + size <= b.count else { throw Refused("a package's archive is cut short") }
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
            let inner = full.split(separator: "/").dropFirst().joined(separator: "/")
            guard !inner.isEmpty else { continue }
            guard safe(inner) else { throw Refused("a package's archive holds \(full), which leaves its folder") }
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
