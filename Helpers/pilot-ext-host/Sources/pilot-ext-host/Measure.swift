import Darwin
import Foundation

// --measure (spec raycast-extensions T7, the top-20 harness's seam): `pilot-ext-host --measure <log> [--measure-pid <pid>]…
// --prelude …` runs a command as ever, but nothing it asks for acts on the Mac. Each line it writes, each message it reads,
// each child, file write and fetch it asks for, and its exit (time to its first line, peak footprint) is one JSON line
// appended to <log>. Off unless the flag is given; Pilot never gives it (only a stand-in host in a sandbox's
// PILOT_EXT_HOST folder does), so a Mac's real runs never see it. Under it (T7 reviews 1 and 2):
// - No child ever starts through a shell (the coordinator's call after review 2). A child is its program and its argv:
//   the program a bare name found on the fixed PATH or an absolute path (never one relative to any folder), resolved by
//   realpath, and only in /bin, /usr/bin, /usr/sbin or /sbin, or the real brew; it starts as that absolute path with
//   that argv and a fixed environment, never the extension's. A `/bin/sh -c <line>` (Node's exec) is not handed to sh:
//   the line is split by a strict tokenizer (any $, backtick, backslash, shell operator, glob or bracket character, a
//   quote inside a word or a line break refuses it) and its words start as that program and argv, judged the same.
// - Its arguments must be that program's read form: any arguments for the plain readers, read forms for defaults,
//   sysctl, date and hostname, a kill of only the pids the caller named, and for brew only the exact argv shapes Brew's
//   views issue. Anything else (AppleScript included) is recorded and refused: the child ends at once with exit 1.
// - A file write goes only into the run's data and cache folders and a temporary folder made for this run alone (which
//   TMPDIR names and which goes at the exit), or to ExtensionData/<id>/gaps.json itself and its folder (the gap
//   recorder's); a path is judged by its parent's realpath and its last name, and a last name that is a link is
//   refused. Anything else fails with EPERM.
// - A fetch is recorded by its method and host. A GET or HEAD still goes out to the network (only reads are allowed,
//   not none); any other method fails.
// - An `open`, copy or paste the run asks for is Pilot's to perform, never the host's; its action line is recorded as that call.
// - node:sqlite opens a database immutable (SQLite.swift), so reading a WAL database makes no -shm file beside it, and
//   so reads only what the main file holds: a WAL database's newest rows (Chrome's History) may be missing.
@MainActor enum Measure {
    private static var log: Int32 = -1
    private static var killable: Set<Int32> = []
    private static var mode = "run", firstLine: Double?
    private static var folders: [String] = []
    /// Single paths a write may name (the gap recorder's file and its folder), beside the folders.
    private static var exact: Set<String> = []
    /// This run's own temporary folder, made at the start and removed at the exit.
    private static var scratch: String?
    /// Refused children still taking stdin (an osascript's script), by child id.
    private static var swallowed: [Int: String] = [:]
    private static let born = Date()

    static var on: Bool { log >= 0 }

    /// Takes `--measure <log>` and each `--measure-pid <pid>` off the front of `arguments`; a run gets its own TMPDIR.
    static func take(_ arguments: inout [String]) {
        while arguments.count >= 2, ["--measure", "--measure-pid"].contains(arguments[0]) {
            if arguments[0] == "--measure" { log = open(arguments[1], O_WRONLY | O_CREAT | O_APPEND, 0o644) } else if let pid = Int32(arguments[1]), pid > 1 { killable.insert(pid) }
            arguments.removeFirst(2)
        }
        guard on else { return }
        if let first = arguments.first, Installer.modes.contains(first) { mode = "install" }
        let made = NSTemporaryDirectory() + "pilot-measure-\(getpid())-\(UUID().uuidString)"
        if mode == "run", (try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: false)) != nil,
           let real = realpath(made) {
            scratch = real + "/"
            folders = [real + "/"]
            setenv("TMPDIR", real + "/", 1)
        }
        record(["kind": "start", "mode": mode, "killable": killable.sorted().map(Int.init)])
    }

    private static func record(_ fields: [String: Any]) {
        guard on else { return }
        var line = fields
        line["pid"] = Int(getpid())
        line["ms"] = (Date().timeIntervalSince(born) * 1000).rounded()
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0a)
        _ = data.withUnsafeBytes { write(log, $0.baseAddress, $0.count) }
    }

    /// `path` with every link resolved, its missing tail kept as written; nil when nothing of it exists.
    static func realpath(_ path: String) -> String? {
        if let real = Darwin.realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let url = URL(filePath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        guard parent != url.path, let head = realpath(parent) else { return nil }
        return (head as NSString).appendingPathComponent(url.lastPathComponent)
    }

    // MARK: The wire

    /// A message from Pilot; a run's gives the data and cache folders writes may go to.
    static func read(_ line: String) {
        guard on else { return }
        record(["kind": "in", "line": line])
        // Only the run message carries the paths; the text is checked before any line is parsed.
        if line.contains("\"run\""), let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           message["type"] as? String == "run", let paths = message["paths"] as? [String: String] {
            folders += paths.values.filter { !$0.isEmpty }.compactMap(realpath).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            // The gap recorder's file beside the data folder (gaps.js: ExtensionData/<id>/gaps.json) and its folder, exactly.
            if let data = paths["data"], !data.isEmpty, let around = realpath((data as NSString).deletingLastPathComponent) {
                exact.formUnion([around, around + "/gaps.json"])
            }
        }
    }

    /// A line to Pilot, raw; an action line (open, copy, paste) is also recorded as the call it asks Pilot for.
    static func wrote(_ line: String) {
        guard on else { return }
        if firstLine == nil { firstLine = Date().timeIntervalSince(born) * 1000 }
        record(["kind": "out", "line": line])
        guard line.contains("\"action\""), let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["type"] as? String == "action", let action = message["action"] as? [String: Any], let type = action["type"] as? String else { return }
        switch type {
        case "open": record(["kind": "open", "url": action["url"] ?? "", "ran": false, "why": "an action line: Pilot performs it, the harness never"])
        case "copy", "paste": record(["kind": type, "characters": (action["text"] as? String)?.count ?? 0, "ran": false])
        default: record(["kind": "action", "type": type, "ran": false])
        }
    }

    /// At the exit: the time to the first line and the peak footprint, from the kernel; the run's temporary folder goes.
    static func exit() {
        guard on else { return }
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
        record(["kind": "exit", "mode": mode, "firstLineMs": firstLine.map { $0.rounded() } ?? NSNull(),
                "peakFootprintMB": read == 0 ? (Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 * 10).rounded() / 10 : NSNull()])
        if let scratch { try? FileManager.default.removeItem(atPath: scratch) }
    }

    // MARK: Files and fetches

    /// Nil when a write to `path` may go ahead; else it is recorded, and this is the failure the prelude reads.
    static func refusesWrite(_ what: String, _ path: String) -> [String: Any]? {
        guard on else { return nil }
        // The parent's realpath and the last name as written: a link already at that name could point anywhere, so it is refused.
        let url = URL(filePath: path).standardizedFileURL
        var info = stat()
        let link = lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        let full = realpath(url.deletingLastPathComponent().path).map { ($0 as NSString).appendingPathComponent(url.lastPathComponent) } ?? url.path
        if !link, exact.contains(full) || folders.contains(where: { full.hasPrefix($0) || full + "/" == $0 }) { return nil }
        record(["kind": "write", "what": what, "path": full, "ran": false, "why": link ? "its last name is a link" : "outside the run's folders"])
        return ["error": "EPERM", "message": "EPERM: pilot-ext-host --measure writes nothing outside the run's folders, '\(path)'"]
    }

    /// Nil when a fetch may go: recorded by method and host; one that is not a GET or HEAD is refused, with its reason.
    static func refusesFetch(_ method: String, _ url: URL) -> String? {
        guard on else { return nil }
        let reads = ["GET", "HEAD"].contains(method)
        record(["kind": "fetch", "method": method, "host": url.host() ?? "", "ran": reads])
        return reads ? nil : "pilot-ext-host --measure sends no \(method) request"
    }

    // MARK: Children

    /// Folders a child's program may live in, after links are resolved; and the one program outside them.
    static let systemFolders = ["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/"], brew = "/opt/homebrew/bin/brew"
    /// The fixed PATH: the system's folders first, then Homebrew's, where only brew itself may run.
    static let searchPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
    /// The only environment a measured child gets.
    static var childEnvironment: [String: String] {
        ["PATH": searchPath, "HOME": NSHomeDirectory(), "TMPDIR": scratch ?? NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
         "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
    }
    /// Programs that only read, whatever their arguments.
    static let readOnly: Set<String> = ["ps", "pgrep", "lsof", "sw_vers", "uname", "id", "whoami", "which", "mdfind", "mdls", "du", "df",
                                        "ls", "cat", "head", "tail", "stat", "wc", "vm_stat", "ioreg", "system_profiler", "getconf", "true"]
    /// The exact argv shapes Brew's views issue (T7 review 2), each word a literal or `<name>` (a formula or cask name).
    static let brewShapes: [[String]] = [
        ["--prefix"], ["--cache"], ["--version"], ["--repository"], ["--cellar"], ["--caskroom"],
        ["info", "--json=v2", "--installed"], ["outdated", "--json=v2"], ["outdated", "--json=v2", "--greedy"],
        ["list", "--versions"], ["leaves"], ["config"], ["tap"], ["tap-info", "--json=v1", "--installed"], ["services", "list", "--json"],
    ]   // Seen and refused (T7.log): update (writes), doctor --json and vulns --json (run checks and fetch beyond a read).

    /// What a child asks for, under --measure: run its program by its absolute path with this argv and the fixed
    /// environment, or refuse it.
    enum Admission { case run(String, [String], [String: Any]), refused(kind: String, why: String) }

    /// The child as it may run, or why not; recorded either way unless it runs unmeasured.
    static func admit(_ file: String, _ args: [String], _ options: [String: Any], sync: Bool) -> Admission {
        guard on else { return .run(file, args, options) }
        let kind = (file as NSString).lastPathComponent == "osascript" ? "applescript" : "exec"
        switch judged(file, args) {
        case .success(let (program, argv)):
            var options = options
            options["env"] = childEnvironment
            record(["kind": kind, "file": file, "program": program, "args": args, "argv": argv, "ran": true].merging(sync ? ["sync": true] : [:]) { $1 })
            return .run(program, argv, options)
        case .failure(let why):
            return .refused(kind: kind, why: why.text)
        }
    }

    struct Why: Error { let text: String; init(_ text: String) { self.text = text } }

    /// The program and argv a child starts as: Node's `/bin/sh -c <line>` becomes the line's own words, never a shell.
    static func judged(_ file: String, _ args: [String]) -> Result<(String, [String]), Why> {
        guard case .success(let program) = located(file) else { return located(file).map { ($0, args) } }
        if (program as NSString).lastPathComponent == "sh" {
            guard args.count == 2, args[0] == "-c" else { return .failure(Why("a shell, which never starts under --measure")) }
            guard let words = tokens(args[1]), let first = words.first else { return .failure(Why("a shell line with more than plain words")) }
            return judge(first, Array(words.dropFirst()))
        }
        return judge(file, args)
    }

    /// `file` as an absolute program: a bare name on the fixed PATH, or an absolute path; never relative to a folder.
    static func located(_ file: String) -> Result<String, Why> {
        guard !file.contains("/") || file.hasPrefix("/") else { return .failure(Why("\(file) is relative to a folder")) }
        let found = file.hasPrefix("/") ? file : searchPath.split(separator: ":").map { "\($0)/\(file)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? file
        guard let program = realpath(found), FileManager.default.isExecutableFile(atPath: program) else { return .failure(Why("\(file) is not a program here")) }
        guard program == brew || systemFolders.contains(where: program.hasPrefix) else {
            return .failure(Why("\(program) is outside the system's own folders"))
        }
        return .success(program)
    }

    /// The program `file` names and its argv when `args` is its read form, else why it is refused.
    static func judge(_ file: String, _ args: [String]) -> Result<(String, [String]), Why> {
        let program: String
        switch located(file) {
        case .success(let path): program = path
        case .failure(let why): return .failure(why)
        }
        let name = (program as NSString).lastPathComponent
        let why: String?
        switch name {
        case "kill":
            // At most one leading signal flag (-9, -KILL), then only pids the harness named: `kill <pid> -1` is refused.
            let pids = args.first.map { $0.wholeMatch(of: /-([0-9]+|[A-Z]+)/) != nil } == true ? Array(args.dropFirst()) : args
            why = !pids.isEmpty && pids.allSatisfy({ Int32($0).map(killable.contains) == true }) ? nil : "a kill of a process the harness did not start"
        case "brew": why = brewShapes.contains(args) ? nil : "brew in a shape Brew's views do not read with"
        case "defaults": why = ["read", "read-type", "domains"].contains(args.first ?? "") ? nil : "defaults that is not a read"
        case "sysctl": why = args.allSatisfy({ ["-n", "-a", "-b", "-h"].contains($0) || $0.wholeMatch(of: /[a-z][a-z0-9_.]*/) != nil }) ? nil : "sysctl that may set a value"
        case "date": why = args.allSatisfy({ ["-u", "-j"].contains($0) || $0.hasPrefix("+") }) ? nil : "date that may set the clock"
        case "hostname": why = args.allSatisfy({ ["-s", "-f"].contains($0) }) ? nil : "hostname that may set the name"
        case "osascript": why = "AppleScript, which acts on the Mac"
        case "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh": why = "a shell, which never starts under --measure"
        default: why = readOnly.contains(name) ? nil : "\(name) is not on the read-only list"
        }
        return why.map { .failure(Why($0)) } ?? .success((program, args))
    }

    /// The words of a shell line made only of plain words: letters, digits and `_ . , = + : / @ % -`, a word optionally
    /// wrapped whole in one pair of ' or ". Anything else anywhere in the line (a $, backtick, backslash, operator,
    /// glob, bracket, a quote inside a word, a tab or line break) refuses the whole line: nil.
    static func tokens(_ line: String) -> [String]? {
        var words: [String] = []
        for part in line.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(part)
            if word.count >= 2, let q = word.first, q == word.last, q == "'" || q == "\"" { word = String(word.dropFirst().dropLast()) }
            guard !word.isEmpty, word.wholeMatch(of: /[A-Za-z0-9_.,=+:\/@%-]+/) != nil else { return nil }
            words.append(word)
        }
        return words.isEmpty ? nil : words
    }

    /// A refused child's stand-in: it takes its stdin and ends with exit 1 on the next turn, its pid answered as 0.
    static func standIn(_ id: Int, _ file: String, _ args: [String], kind: String, why: String, host: Host) -> Any {
        swallowed[id] = ""
        host.pending += 1
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                record(["kind": kind, "file": file, "args": args, "stdin": swallowed.removeValue(forKey: id) ?? "", "ran": false, "why": why])
                host.call("__pilotChild", [id, "stderr", "pilot-ext-host --measure: not run on this Mac (\(why))\n"])
                host.call("__pilotChild", [id, "exit", 1, NSNull()])
                host.call("__pilotChild", [id, "close"])
                host.pending -= 1
                host.settle()
            }
        }
        return 0
    }

    /// spawnSync's refused answer, recorded: exit 1.
    static func refusedSync(_ file: String, _ args: [String], input: String, kind: String, why: String) -> Any {
        record(["kind": kind, "file": file, "args": args, "stdin": input, "ran": false, "why": why, "sync": true])
        return ["status": 1, "signal": NSNull(), "stdout": "", "stderr": "pilot-ext-host --measure: not run on this Mac (\(why))\n", "pid": 0]
    }

    /// Text written to a refused child's stdin is kept for its record: true when `id` is one.
    static func swallow(_ id: Int, _ text: String) -> Bool {
        guard swallowed[id] != nil else { return false }
        swallowed[id]! += text
        return true
    }

    static func isStandIn(_ id: Int) -> Bool { swallowed[id] != nil }
}
