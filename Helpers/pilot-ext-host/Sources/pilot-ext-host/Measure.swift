import Darwin
import Foundation

// --measure (spec raycast-extensions T7, the top-20 harness's seam): `pilot-ext-host --measure <log> [--measure-pid <pid>]…
// --prelude …` runs a command as ever, but nothing it asks for acts on the Mac. Each line it writes, each message it reads,
// each child, file write and fetch it asks for, and its exit (time to its first line, peak footprint) is one JSON line
// appended to <log>. Off unless the flag is given; Pilot never gives it (only a stand-in host in a sandbox's
// PILOT_EXT_HOST folder does), so a Mac's real runs never see it. Under it (T7 review 1):
// - A child runs only in an exact read-only shape (admit): its program found by realpath in /bin, /usr/bin, /usr/sbin or
//   /sbin (or the real brew) and started by that path, never a copy elsewhere; its arguments held to that program's read
//   form; `sh` only with one plain `-c` line of such a command; a kill only of pids the caller named. It gets a fixed
//   environment, never the extension's, so no BASH_ENV, ENV or ZDOTDIR reaches a shell. Anything else (AppleScript
//   included) is recorded and refused: the child ends at once with exit 1.
// - A file write goes only to the run's data and cache folders (and ExtensionData/<id> around the data one, for
//   gaps.json) and a temporary folder made for this run alone, which
//   TMPDIR names to the extension and its children and which goes at the exit; anything else fails with EPERM.
// - A fetch is recorded by its method and host; one that is not a GET or HEAD fails.
// - An `open`, copy or paste the run asks for is Pilot's to perform, never the host's; its action line is recorded as that call.
// - node:sqlite opens a database immutable (SQLite.swift), so reading a WAL database makes no -shm file beside it.
@MainActor enum Measure {
    private static var log: Int32 = -1
    private static var killable: Set<Int32> = []
    private static var mode = "run", firstLine: Double?
    private static var folders: [String] = []
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
            // The data folder's own folder too, ExtensionData/<id>, where the gap recorder keeps gaps.json (gaps.js).
            let given = paths.values.filter { !$0.isEmpty } + [paths["data"].map { ($0 as NSString).deletingLastPathComponent }].compactMap { $0 }
            folders += given.compactMap(realpath).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
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
        let full = realpath(path) ?? URL(filePath: path).standardizedFileURL.path
        guard !folders.contains(where: { full.hasPrefix($0) || full + "/" == $0 }) else { return nil }
        record(["kind": "write", "what": what, "path": full, "ran": false])
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
    /// brew's subcommands that change nothing.
    static let brewReads: Set<String> = ["list", "ls", "info", "outdated", "search", "desc", "deps", "uses", "leaves", "config",
                                         "--prefix", "--cellar", "--repository", "--caskroom", "--cache", "--version", "--env", "commands", "tap-info"]

    /// What a child asks for, under --measure: run it (by its real path, with the fixed environment), or refuse it.
    enum Admission { case run(String, [String: Any]), refused(kind: String, why: String) }

    /// The child as it may run, or why not; recorded either way unless it runs unmeasured.
    static func admit(_ file: String, _ args: [String], _ options: [String: Any], sync: Bool) -> Admission {
        guard on else { return .run(file, options) }
        let kind = (file as NSString).lastPathComponent == "osascript" ? "applescript" : "exec"
        switch judge(file, args, shell: true) {
        case .success(let program):
            var options = options
            options["env"] = childEnvironment
            record(["kind": kind, "file": file, "program": program, "args": args, "ran": true].merging(sync ? ["sync": true] : [:]) { $1 })
            return .run(program, options)
        case .failure(let why):
            return .refused(kind: kind, why: why.text)
        }
    }

    struct Why: Error { let text: String; init(_ text: String) { self.text = text } }

    /// The real program `file` names and whether `args` is its read form: the program's path, or why it is refused.
    static func judge(_ file: String, _ args: [String], shell: Bool) -> Result<String, Why> {
        let found = file.contains("/") ? file : searchPath.split(separator: ":").map { "\($0)/\(file)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? file
        guard let program = realpath(found), FileManager.default.isExecutableFile(atPath: program) else { return .failure(Why("\(file) is not a program here")) }
        guard program == brew || systemFolders.contains(where: program.hasPrefix) else {
            return .failure(Why("\(program) is outside the system's own folders"))
        }
        let name = (program as NSString).lastPathComponent
        let why: String?
        switch name {
        case "sh" where shell:
            guard args.count == 2, args[0] == "-c", let words = simple(args[1]), let first = words.first else { return .failure(Why("a shell not given one plain -c line")) }
            // The shell finds the line's program on the same fixed PATH, so it starts the program judged here.
            let inner = judge(first, Array(words.dropFirst()), shell: false)
            if case .failure = inner { return inner }
            why = nil
        case "kill":
            // At most one leading signal flag (-9, -KILL), then only pids the harness named: `kill <pid> -1` is refused.
            let pids = args.first.map { $0.wholeMatch(of: /-([0-9]+|[A-Z]+)/) != nil } == true ? Array(args.dropFirst()) : args
            why = !pids.isEmpty && pids.allSatisfy({ Int32($0).map(killable.contains) == true }) ? nil : "a kill of a process the harness did not start"
        case "brew":
            let sub = args.first.flatMap { brewReads.contains($0) ? $0 : nil } ?? args.first { !$0.hasPrefix("-") } ?? ""
            why = sub == "tap" ? (args.count == 1 ? nil : "brew tap with a name adds one") : brewReads.contains(sub) ? nil : "brew \(sub) may change something"
        case "defaults": why = ["read", "read-type", "domains"].contains(args.first ?? "") ? nil : "defaults that is not a read"
        case "sysctl": why = args.allSatisfy({ ["-n", "-a", "-b", "-h"].contains($0) || $0.wholeMatch(of: /[a-z][a-z0-9_.]*/) != nil }) ? nil : "sysctl that may set a value"
        case "date": why = args.allSatisfy({ ["-u", "-j"].contains($0) || $0.hasPrefix("+") }) ? nil : "date that may set the clock"
        case "hostname": why = args.allSatisfy({ ["-s", "-f"].contains($0) }) ? nil : "hostname that may set the name"
        case "osascript": why = "AppleScript, which acts on the Mac"
        default: why = readOnly.contains(name) ? nil : "\(name) is not on the read-only list"
        }
        return why.map { .failure(Why($0)) } ?? .success(program)
    }

    /// A shell line's words when it is one plain command (quotes allowed; no ; & | < > $ ` or line break), else nil.
    static func simple(_ line: String) -> [String]? {
        var words: [String] = [], word = "", quote: Character?, any = false
        for c in line {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                continue
            }
            switch c {
            case "'", "\"": quote = c; any = true
            case " ", "\t": if any || !word.isEmpty { words.append(word); word = ""; any = false }
            case ";", "&", "|", "<", ">", "$", "`", "\n", "(", ")", "\\", "*", "?": return nil
            default: word.append(c)
            }
        }
        guard quote == nil else { return nil }
        if any || !word.isEmpty { words.append(word) }
        return words
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
