import Foundation

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

/// One app or tool Install offers (SPEC.md, Install catalogue): how it installs, how Pilot tells it is installed, the
/// vendor page it was checked against and the day.
public struct CatalogueEntry: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        case package(Package)
        /// A vendor's download page, opened in the browser: no command runs.
        case download(String)
        /// The vendor's own install script, a GitHub release's `.sh` piped to sh in the visible terminal after the
        /// confirm step (Sven 2026-10-09: hermes-context installs this way).
        case script(String)

        public var package: Package? { if case .package(let p) = self { p } else { nil } }

        /// What runs on yes for a script: `curl -fsSL '<url>' | sh`; nil for any other method.
        public var scriptCommand: String? { if case .script(let url) = self { "curl -fsSL \(VisibleRun.quoted(url)) | sh" } else { nil } }

        /// How it arrives, in a word or two, as the menu's row says it.
        public var label: String {
            switch self {
            case .package(let p): p.kindLabel
            case .download: "download"
            case .script: "install script"
            }
        }
    }

    /// Installed when an app with this bundle id is registered, when any of these paths exists (`~` is home), or when
    /// this command is in one of the folders Homebrew or a vendor's own installer puts commands in: a tool installed by
    /// its vendor's script (Claude Code in ~/.local/bin) is still found, so Install never offers a second copy.
    public enum Check: Hashable, Sendable {
        case bundle(String), paths([String]), command(String)

        /// Where commands land: Homebrew's two prefixes, then the vendors' own installers. Not /usr/bin, which holds
        /// macOS's own copies (ruby, vim). Pilot runs with launchd's short PATH, so PATH cannot say.
        public static let commandFolders = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.cargo/bin", "~/.bun/bin", "~/.deno/bin"]

        /// Every copy of a command in those folders, in their order (Update reads each npm's own tree).
        public static func copies(of name: String, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [String] {
            commandFolders.map { NSString(string: "\($0)/\(name)").expandingTildeInPath }.filter(isExecutable)
        }

        public func isMet(bundleInstalled: (String) -> Bool, fileExists: (String) -> Bool) -> Bool {
            switch self {
            case .bundle(let id): bundleInstalled(id)
            case .paths(let paths): paths.contains { fileExists(NSString(string: $0).expandingTildeInPath) }
            case .command(let name): Self.paths(Self.commandFolders.map { "\($0)/\(name)" }).isMet(bundleInstalled: bundleInstalled, fileExists: fileExists)
            }
        }
    }

    public let id: String, name: String, category: String
    public let method: Method, check: Check
    public let vendor: String, checked: String

    /// The menu row's id: the package's key, or `download:<id>`.
    public var key: String { method.package?.key ?? "download:\(id)" }
}

/// The shipped catalogue (`Packaging/install-catalogue.json`, copied into the app's Resources): one flat list of
/// entries, each a JSON object of strings, its category one of them. The file's order is the menu's.
public enum InstallCatalogue {
    public enum Problem: Error, Equatable {
        case notJSON
        case missing(entry: String, field: String)
        case malformed(entry: String, field: String)
    }

    public static func parse(_ data: Data) throws(Problem) -> [CatalogueEntry] {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw .notJSON }
        return try file.entries.map { row throws(Problem) in try entry(row) }
    }

    /// The categories in the order their first entry appears.
    public static func categories(_ entries: [CatalogueEntry]) -> [String] {
        entries.map(\.category).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// One entry as the file holds it: one of cask, formula, uv, download or script, and one of bundle, path, paths or
    /// command. A script is a GitHub release's `.sh` only.
    private struct Row: Decodable {
        var id, name, category, cask, formula, uv, download, script, bundle, path, command, vendor, checked: String?
        var paths: [String]?
    }
    private struct File: Decodable { var entries: [Row] }

    private static func entry(_ row: Row) throws(Problem) -> CatalogueEntry {
        let id = row.id ?? "?"
        func required(_ value: String?, _ field: String) throws(Problem) -> String {
            guard let value, !value.isEmpty else { throw .missing(entry: id, field: field) }
            return value
        }
        let package = row.cask.map { Package(.cask, $0) } ?? row.formula.map { Package(.formula, $0) } ?? row.uv.map { Package(.uv, $0) }
        let method: CatalogueEntry.Method
        switch (package, row.download, row.script) {
        case (let p??, _, _): method = .package(p)
        case (.some(nil), _, _): throw .malformed(entry: id, field: "method")
        case (nil, let url?, _): method = .download(url)
        case (nil, nil, let url?):
            guard url.hasPrefix("https://github.com/"), url.contains("/releases/"), url.hasSuffix(".sh") else { throw .malformed(entry: id, field: "script") }
            method = .script(url)
        case (nil, nil, nil): throw .missing(entry: id, field: "method")
        }
        let checks: [CatalogueEntry.Check] = [row.bundle.map { .bundle($0) }, row.path.map { .paths([$0]) },
                                              row.paths.flatMap { $0.isEmpty ? nil : .paths($0) }, row.command.map { .command($0) }].compactMap { $0 }
        guard let check = checks.first else { throw .missing(entry: id, field: "installed-check") }
        guard checks.count == 1 else { throw .malformed(entry: id, field: "installed-check") }
        let vendor = try required(row.vendor, "vendor"), checked = try required(row.checked, "checked")
        guard vendor.hasPrefix("https://") else { throw .malformed(entry: id, field: "vendor") }
        guard (try? Date.ISO8601FormatStyle().year().month().day().parse(checked)) != nil else { throw .malformed(entry: id, field: "checked") }
        return CatalogueEntry(id: try required(row.id, "id"), name: try required(row.name, "name"), category: try required(row.category, "category"),
                              method: method, check: check, vendor: vendor, checked: checked)
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

extension MenuEntries {
    /// Install's rows (wireframe section 8): a branch per category naming its apps, then each entry in its category,
    /// with its method and whether it is installed (`installed`: entry ids).
    public static func install(_ entries: [CatalogueEntry], installed: Set<String>) -> [MenuEntry] {
        let categories = InstallCatalogue.categories(entries).map { c in
            MenuEntry(title: c, target: .branch(.category(c)), home: .install,
                      detail: entries.filter { $0.category == c }.map(\.name).joined(separator: ", "), icon: MenuIcon.category(c))
        }
        return categories + entries.map { e in
            let kind = e.method.label
            return MenuEntry(title: e.name, target: .package(e.key), home: .category(e.category),
                             detail: installed.contains(e.id) ? "\(kind) · installed" : kind, icon: MenuIcon.catalogue(e))
        }
    }
}
