import Darwin
import Foundation

// --measure (spec raycast-extensions T7, the top-20 harness's seam): `pilot-ext-host --measure <log> [--measure-pid <pid>]…
// --prelude …` runs a command as ever, but nothing it asks for acts on the Mac. Each line it writes, each message it reads,
// each child it would start, each file write outside the run's own folders and its exit (time to its first line, peak
// footprint) is one JSON line appended to <log>. A child runs only when it reads and changes nothing: a program on the
// read-only list, `brew` with a read-only subcommand, `sqlite3` read-only, a plain `sh -c` line of one such command, or a
// kill of a pid the caller named (the harness's own `sleep`). Any other child (AppleScript included), and any write outside
// the run's data and cache folders and the temporary folder, is recorded and refused: the child ends at once with exit 1,
// the write fails with EPERM. An `open`, copy or paste the run asks for is already Pilot's to perform, never the host's;
// its action line is recorded as that call. Off unless the flag is given; Pilot never gives it (only a stand-in host
// in a sandbox's PILOT_EXT_HOST folder does), so a Mac's real runs never see it.
@MainActor enum Measure {
    private static var log: Int32 = -1
    private static var killable: Set<Int32> = []
    private static var mode = "run", firstLine: Double?
    private static var folders: [String] = []
    /// Refused children still taking stdin (an osascript's script), by child id.
    private static var swallowed: [Int: String] = [:]
    private static let born = Date()

    static var on: Bool { log >= 0 }

    /// Takes `--measure <log>` and each `--measure-pid <pid>` off the front of `arguments`.
    static func take(_ arguments: inout [String]) {
        while arguments.count >= 2, ["--measure", "--measure-pid"].contains(arguments[0]) {
            if arguments[0] == "--measure" { log = open(arguments[1], O_WRONLY | O_CREAT | O_APPEND, 0o644) } else if let pid = Int32(arguments[1]) { killable.insert(pid) }
            arguments.removeFirst(2)
        }
        guard on else { return }
        if let first = arguments.first, Installer.modes.contains(first) { mode = "install" }
        folders = [ProcessInfo.processInfo.environment["TMPDIR"], NSTemporaryDirectory(), "/private/tmp/", "/tmp/"].compactMap { $0 }
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

    // MARK: The wire

    /// A message from Pilot; a run's gives the data and cache folders writes may go to.
    static func read(_ line: String) {
        guard on else { return }
        record(["kind": "in", "line": line])
        // Only the run message carries the paths; the text is checked before any line is parsed.
        if line.contains("\"run\""), let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           message["type"] as? String == "run", let paths = message["paths"] as? [String: String] {
            folders += paths.values.filter { !$0.isEmpty }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        }
    }

    /// A line to Pilot, raw; an action line (open, copy, paste) is also recorded as the call it asks Pilot for.
    static func wrote(_ line: String) {
        guard on else { return }
        if firstLine == nil { firstLine = Date().timeIntervalSince(born) * 1000 }
        record(["kind": "out", "line": line])
        guard line.hasPrefix("{\"type\":\"action\""), let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["type"] as? String == "action", let action = message["action"] as? [String: Any], let type = action["type"] as? String else { return }
        switch type {
        case "open": record(["kind": "open", "url": action["url"] ?? "", "ran": false, "why": "an action line: Pilot performs it, the harness never"])
        case "copy", "paste": record(["kind": type, "characters": (action["text"] as? String)?.count ?? 0, "ran": false])
        default: record(["kind": "action", "type": type, "ran": false])
        }
    }

    /// At the exit: the time to the first line and the peak footprint, from the kernel.
    static func exit() {
        guard on else { return }
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
        record(["kind": "exit", "mode": mode, "firstLineMs": firstLine.map { $0.rounded() } ?? NSNull(),
                "peakFootprintMB": read == 0 ? (Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 * 10).rounded() / 10 : NSNull()])
    }

    // MARK: Files

    /// Nil when a write to `path` may go ahead; else it is recorded, and this is the failure the prelude reads.
    static func refusesWrite(_ what: String, _ path: String) -> [String: Any]? {
        guard on else { return nil }
        let full = URL(filePath: path).standardizedFileURL.path
        guard !folders.contains(where: { full.hasPrefix($0) || full + "/" == $0 }) else { return nil }
        record(["kind": "write", "what": what, "path": full, "ran": false])
        return ["error": "EPERM", "message": "EPERM: pilot-ext-host --measure writes nothing outside the run's folders, '\(path)'"]
    }

    // MARK: Children

    /// Programs that only read the Mac's state, by name.
    static let readOnly: Set<String> = ["ps", "pgrep", "lsof", "sysctl", "sw_vers", "uname", "id", "whoami", "which", "mdfind", "mdls",
                                        "du", "df", "ls", "cat", "head", "tail", "file", "stat", "wc", "date", "hostname", "system_profiler",
                                        "vm_stat", "top", "ioreg", "pmset", "scutil", "networksetup", "getconf", "true"]
    /// brew's subcommands that change nothing.
    static let brewReads: Set<String> = ["list", "ls", "info", "outdated", "search", "desc", "deps", "uses", "leaves", "config", "doctor",
                                         "--prefix", "--cellar", "--repository", "--caskroom", "--cache", "--version", "--env", "commands", "tap-info"]

    /// Why `file args` must not run, or nil when it may.
    static func refusal(_ file: String, _ args: [String]) -> String? {
        let name = (file as NSString).lastPathComponent
        switch name {
        case "sh", "bash", "zsh":
            guard args.count == 2, args[0] == "-c" else { return "a shell not given one -c line" }
            guard let words = simple(args[1]), let first = words.first else { return "a shell line that is not one plain command" }
            return refusal(first, Array(words.dropFirst()))
        case "kill":
            let pids = args.filter { !$0.hasPrefix("-") }.map { Int32($0) }
            guard !pids.isEmpty, pids.allSatisfy({ $0.map(killable.contains) == true }) else { return "a kill of a process the harness did not start" }
            return nil
        case "brew":
            let sub = args.first.flatMap { brewReads.contains($0) ? $0 : nil } ?? args.first { !$0.hasPrefix("-") } ?? ""
            if sub == "tap" { return args.filter { !$0.hasPrefix("-") }.count == 1 ? nil : "brew tap with a name adds one" }
            return brewReads.contains(sub) ? nil : "brew \(sub) may change something"
        case "sqlite3":
            return args.contains("-readonly") || args.contains(where: { $0.contains("mode=ro") || $0.contains("immutable=1") }) ? nil : "sqlite3 not opened read-only"
        case "defaults": return args.first == "read" || args.first == "domains" ? nil : "defaults that is not a read"
        case "osascript": return "AppleScript, which acts on the Mac"
        default: return readOnly.contains(name) ? nil : "\(name) is not on the read-only list"
        }
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

    /// A child about to start: recorded; when refused, a stand-in that takes its stdin and ends with exit 1 on the next
    /// turn, its pid answered as 0 (nil lets it start).
    static func refuses(_ id: Int, _ file: String, _ args: [String], host: Host) -> Any? {
        guard on, let (kind, why) = judged(file, args, sync: false) else { return nil }
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

    /// spawnSync's: nil lets it start; else it is recorded and this is its answer, exit 1.
    static func refusesSync(_ file: String, _ args: [String], input: String) -> Any? {
        guard on, let (kind, why) = judged(file, args, sync: true) else { return nil }
        record(["kind": kind, "file": file, "args": args, "stdin": input, "ran": false, "why": why, "sync": true])
        return ["status": 1, "signal": NSNull(), "stdout": "", "stderr": "pilot-ext-host --measure: not run on this Mac (\(why))\n", "pid": 0]
    }

    /// A child's kind and why it is refused; a child that may run is recorded here, as run, and answers nil.
    private static func judged(_ file: String, _ args: [String], sync: Bool) -> (kind: String, why: String)? {
        let kind = (file as NSString).lastPathComponent == "osascript" ? "applescript" : "exec"
        guard let why = refusal(file, args) else {
            record(["kind": kind, "file": file, "args": args, "ran": true].merging(sync ? ["sync": true] : [:]) { $1 })
            return nil
        }
        return (kind, why)
    }

    /// Text written to a refused child's stdin is kept for its record: true when `id` is one.
    static func swallow(_ id: Int, _ text: String) -> Bool {
        guard swallowed[id] != nil else { return false }
        swallowed[id]! += text
        return true
    }

    static func isStandIn(_ id: Int) -> Bool { swallowed[id] != nil }
}
