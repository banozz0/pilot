import Foundation
import Synchronization

/// One thing Install, Remove and Update act on: a Homebrew cask or formula, a `uv` tool, a global npm package by name,
/// an App Store app by its id (card agent-bo-95422998), or a pipx tool, a cargo crate or a Go module path (N9). The name is a token Homebrew, PyPI, npm or mas would accept,
/// never shell text, so a command built from it is safe to run.
public struct Package: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case cask, formula, uv, npm, mas, pipx, cargo, go

        /// A command-line tool's kind: everything but an app (a cask, an App Store app).
        public var isTool: Bool {
            switch self {
            case .formula, .uv, .npm, .pipx, .cargo, .go: true
            case .cask, .mas: false
            }
        }
    }

    public let kind: Kind, name: String

    /// Nil for a name with anything but letters, digits and `@._+-/` (a tap's `owner/tap/name`), or one that starts with
    /// `-`, which a tool would read as a flag.
    public init?(_ kind: Kind, _ name: String) {
        guard Self.isName(name) else { return nil }
        self.kind = kind; self.name = name
    }

    static func isName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._+-/".contains($0)) }
    }

    /// `cask:coteditor`, `formula:hello`, `uv:telegram-tools`: the id the menu, the store and the URL scheme use.
    public var key: String { "\(kind.rawValue):\(name)" }

    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":"), let kind = Kind(rawValue: String(key[..<colon])) else { return nil }
        self.init(kind, String(key[key.index(after: colon)...]))
    }

    public var install: String {
        switch kind {
        case .cask: "brew install --cask \(name)"
        case .formula: "brew install \(name)"
        case .uv: "uv tool install \(name)"
        case .npm: "npm install -g \(name)"
        case .mas: "mas get \(name)"
        case .pipx: "pipx install \(name)"
        case .cargo: "cargo install \(name)"
        case .go: "go install \(name)@latest"
        }
    }

    public var remove: String {
        switch kind {
        case .cask: "brew uninstall --cask \(name)"
        case .formula: "brew uninstall \(name)"
        case .uv: "uv tool uninstall \(name)"
        case .npm: "npm uninstall -g \(name)"
        case .mas: "mas uninstall \(name)"
        case .pipx: "pipx uninstall \(name)"
        case .cargo: "cargo uninstall \(name)"
        // Go has no uninstall: its command is a file in GOPATH's bin, named for the module's last part.
        case .go: "rm -i \"$(go env GOPATH)/bin/\(name.split(separator: "/").last ?? "")\""
        }
    }

    /// How it arrives, as Install's cards and search rows say it: "Homebrew app", "uv tool", "App Store".
    public var via: String {
        switch kind {
        case .cask: MenuIcon.package(self) == .font ? "Homebrew font" : "Homebrew app"
        case .formula: "Homebrew tool"
        case .uv: "uv tool"
        case .pipx: "pipx tool"
        case .npm: "npm package"
        case .cargo: "cargo crate"
        case .go: "Go module"
        case .mas: "App Store"
        }
    }

    /// What a row shows for the kind.
    public var kindLabel: String {
        switch kind {
        case .cask, .formula: kind.rawValue
        case .uv: "uv tool"
        case .npm: "npm package"
        case .mas: "App Store app"
        case .pipx: "pipx tool"
        case .cargo: "cargo crate"
        case .go: "Go module"
        }
    }
}

/// Whether an app or tool is installed: when an app with this bundle id is registered, when any of these paths exists (`~` is home), or when
/// this command is in one of the folders Homebrew or a vendor's own installer puts commands in: a tool installed by
/// its vendor's script (Claude Code in ~/.local/bin) is still found, so Install never offers a second copy.
public enum InstallCheck: Hashable, Sendable {
    case bundle(String), paths([String]), command(String)

    /// Where commands land: Homebrew's two prefixes, the vendors' own installers, then Node's version managers', where
    /// npm and what it installs live (a tester's npm under one read missing, 2026-11-18). Not /usr/bin, which holds
    /// macOS's own copies (ruby, vim). Pilot runs with launchd's short PATH, and a version manager adds its folder only
    /// in an interactive shell, so PATH cannot say. Read again after 5 s, so a Node installed since launch is found, while
    /// a menu open, which checks every catalogue row, lists nvm's folder once.
    public static var commandFolders: [String] {
        cache.withLock { cached in
            if let cached, cached.at.timeIntervalSinceNow > -5 { return cached.folders }
            let fresh = folders(home: standIn?.home ?? NSHomeDirectory(), root: standIn?.root ?? "")
            cached = (Date(), fresh)
            return fresh
        }
    }

    private static let cache = Mutex<(at: Date, folders: [String])?>(nil)

    /// A sandbox run's stand-in Mac (PILOT_SANDBOX_TOOLS): its home and the folder Homebrew's prefixes sit under, so
    /// `pilot list helpers` reads a fixture's folders, never the Mac's. Set once, before the verbs serve.
    nonisolated(unsafe) public static var standIn: (home: String, root: String)?

    /// The folders for `home`, Homebrew's under `root` (a stand-in Mac's folder; the Mac's own when empty). nvm's is
    /// its default Node's bin: the newest installed version that `alias/default` names (`22`, `v22.11.0`), else the
    /// newest installed. fnm's is its default alias, in each of the homes fnm has used.
    public static func folders(home: String, root: String = "",
                               list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
                               read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [String] {
        let nvm = "\(home)/.nvm/versions/node"
        let versions = list(nvm).filter { $0.hasPrefix("v") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let named = read("\(home)/.nvm/alias/default")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = named.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
        let pick = wanted.flatMap { w in versions.first { $0.dropFirst() == w || $0.dropFirst().hasPrefix(w + ".") } } ?? versions.first
        return ["/opt/homebrew/bin", "/usr/local/bin"].map { root + $0 }
            + [".local/bin", ".cargo/bin", ".bun/bin", ".deno/bin"].map { "\(home)/\($0)" }
            + (pick.map { ["\(nvm)/\($0)/bin"] } ?? [])
            + [".volta/bin", ".local/share/fnm/aliases/default/bin", "Library/Application Support/fnm/aliases/default/bin",
               ".fnm/aliases/default/bin", ".asdf/shims", ".local/share/mise/shims", ".nodenv/shims", "n/bin"].map { "\(home)/\($0)" }
    }

    /// Every copy of a command in those folders, in their order (Update reads each npm's own tree).
    public static func copies(of name: String, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [String] {
        commandFolders.map { "\($0)/\(name)" }.filter(isExecutable)
    }

    public func isMet(bundleInstalled: (String) -> Bool, fileExists: (String) -> Bool) -> Bool {
        switch self {
        case .bundle(let id): bundleInstalled(id)
        case .paths(let paths): paths.contains { fileExists(NSString(string: $0).expandingTildeInPath) }
        case .command(let name): Self.paths(Self.commandFolders.map { "\($0)/\(name)" }).isMet(bundleInstalled: bundleInstalled, fileExists: fileExists)
        }
    }
}

/// The script a visible terminal runs (story 97): it deletes its own file (zsh has it open already), shows the command, runs it with Homebrew and uv's tools on PATH,
/// runs `onSuccess` and exits on 0, so the window closes, and otherwise says so and waits for Return, so it stays.
/// With a `report` folder (story 153, Update and Clean) the same command runs under script(1), which keeps it on a
/// terminal of its own and copies what it prints to `output` (never what is typed); the shell's pid goes to `pid` and the
/// exit status to `status`, 129 or 143 when the window closes or the run is stopped.
public enum VisibleRun {
    public static func script(command: String, onSuccess: String, report: URL? = nil) -> String {
        """
        #!/bin/zsh
        rm -f -- "$0"
        export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
        print -r -- \(quoted("$ " + command))
        \(report.map { recorded(command, in: $0) } ?? command)
        s=$?
        if [ $s -eq 0 ]; then \(onSuccess); exit 0; fi
        print; print -r -- "Failed with exit $s. Press Return to close."
        read
        exit $s
        """
    }

    /// Terminal's window settings for the script, as a `.terminal` file Terminal opens: the script is the window's
    /// shell, and the window closes when it exits cleanly (shellExitAction 1) and stays when it fails, as Ghostty's
    /// does. Used only when Ghostty is not installed; opening it adds a "Pilot run" profile to Terminal.
    public static func terminalSettings(script: String) -> Data {
        let settings: [String: Any] = ["name": "Pilot run", "type": "Window Settings", "ProfileCurrentVersion": 2.07,
                                       "CommandString": "/bin/zsh \(quoted(script))", "RunCommandAsShell": true, "shellExitAction": 1]
        return try! PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
    }

    /// The command under script(1) with no rc files read, so it runs with the environment above, its pid, output and
    /// status in `report`.
    private static func recorded(_ command: String, in report: URL) -> String {
        """
        r=\(quoted(report.path))
        print -r -- $$ > "$r/pid"
        trap 'print -r -- 129 > "$r/status"; exit 129' HUP
        trap 'print -r -- 143 > "$r/status"; exit 143' TERM
        /usr/bin/script -q "$r/output" /bin/zsh -f -c \(quoted(command))
        s=$?
        print -r -- $s > "$r/status"
        (exit $s)
        """
    }

    /// A visible run's `onSuccess` that keeps the window until Return, so its output can be read.
    public static let waitForReturn = "print; read -r '?Done. Press Return to close.'"

    /// Single-quoted for the shell.
    public static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// What Pilot installed, by package key and day (SPEC.md: "Install records what it installed in Pilot's store"); Remove
/// lists these first.
public struct InstalledStore: Sendable {
    /// ~/Library/Application Support/Pilot/installed.json
    public static let standard = InstalledStore(url: PilotFolder.support.appending(path: "installed.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// None when nothing was installed yet. A file that does not decode throws, so no record wipes it.
    public func load() throws -> [String: Date] { try JSONFile(url: url).load(or: [:]) }

    public func record(_ package: Package, at date: Date) throws {
        var all = try load()
        all[package.key] = date
        try JSONFile(url: url).save(all)
    }

    /// After a removal: Pilot no longer lists it as its install.
    public func forget(_ package: Package) throws {
        var all = try load()
        guard all.removeValue(forKey: package.key) != nil else { return }
        try JSONFile(url: url).save(all)
    }
}

/// One JSON file in Application Support: the stores' shared read and atomic write, dates as ISO 8601.
struct JSONFile<Value: Codable> {
    let url: URL

    /// `empty` when the file does not exist yet; a file that does not decode throws, so no save wipes it.
    func load(or empty: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    /// `starters` when the file does not exist yet, saved at once so they are added only this once (Sven 2026-10-10:
    /// the starter quicklinks and aliases); a file, even an empty list, is read as `load(or:)` reads it.
    func load(seeding starters: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? save(starters)
            return starters
        }
        return try load(or: starters)
    }

    func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
