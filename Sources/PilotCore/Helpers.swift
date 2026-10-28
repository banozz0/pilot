import Foundation

/// A command-line tool other Pilot features run (Sven 2026-10-12, ideas round): what it unlocks, how Pilot tells it is
/// there and how it installs. Install › Helpers lists them with Install, Clean's Install Mole and Update's install mas are two of
/// them, and Install's search names the first missing one that would add a source. Every install runs in the visible
/// terminal after the confirm step: Homebrew through its own installer, which asks for the Mac's password there, never in
/// Pilot; the rest are Homebrew formulae, so they need Homebrew first.
public struct Helper: Equatable, Sendable, Identifiable {
    public enum Route: Equatable, Sendable {
        /// `brew install <formula>`; no password.
        case formula(Package)
        /// A vendor's installer run in the terminal, which asks for the password itself.
        case installer(String)
    }

    public let id: String, name: String
    /// What it unlocks in Pilot, in one line.
    public let unlocks: String
    /// The command that says it is installed, in the folders Install looks in (CatalogueEntry.Check.commandFolders).
    public let command: String
    public let route: Route
    /// The source Install's search asks once it is there; nil for one that adds none.
    public let addsSource: InstallSearch.Source?

    public static let homebrew = Helper(
        id: "homebrew", name: "Homebrew", unlocks: "Install's Homebrew results, Update and Remove; the other helpers install through it",
        command: "brew", route: .installer(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#),
        addsSource: .homebrew)
    public static let mole = Helper(id: "mole", name: "Mole", unlocks: "Clean: the preview of what it removes, the clean and Disk usage",
                                    command: "mo", route: .formula(Package(.formula, "mole")!), addsSource: nil)
    public static let mas = Helper(id: "mas", name: "mas", unlocks: "Install gets free Mac App Store apps itself, not just their page; Update lists their updates",
                                   command: "mas", route: .formula(Package(.formula, "mas")!), addsSource: nil)
    public static let npm = Helper(id: "npm", name: "npm", unlocks: "npm packages in Install's search, Update and Remove (comes with Node)",
                                   command: "npm", route: .formula(Package(.formula, "node")!), addsSource: .tools)
    public static let cargo = Helper(id: "cargo", name: "cargo", unlocks: "Rust crates in Install's search and Update (comes with Rust)",
                                     command: "cargo", route: .formula(Package(.formula, "rust")!), addsSource: .tools)

    /// Install › Helpers' order; Install's search hint takes the first missing one, so Homebrew comes before what installs through it.
    public static let all = [homebrew, mole, mas, npm, cargo]

    public static func named(_ id: String) -> Helper? { all.first { $0.id == id } }

    /// `helper:npm`: the menu's and the URL scheme's id for its install.
    public var key: String { "helper:\(id)" }

    public init?(key: String) {
        guard key.hasPrefix("helper:"), let helper = Self.named(String(key.dropFirst(7))) else { return nil }
        self = helper
    }

    private init(id: String, name: String, unlocks: String, command: String, route: Route, addsSource: InstallSearch.Source?) {
        self.id = id; self.name = name; self.unlocks = unlocks; self.command = command; self.route = route; self.addsSource = addsSource
    }

    /// The formula it installs as; nil for Homebrew.
    public var package: Package? { if case .formula(let p) = route { p } else { nil } }

    /// What runs on yes.
    public var install: String {
        switch route {
        case .formula(let p): p.install
        case .installer(let command): command
        }
    }

    /// How it installs, as Install › Helpers' row and `pilot list helpers` say it.
    public var how: String {
        switch route {
        case .formula(let p): "brew install \(p.name) in a terminal window; needs Homebrew"
        case .installer: "Homebrew's installer in a terminal window, which asks for your password there"
        }
    }

    /// What its Install does now, the one decision Install › Helpers, the menu and `pilot install helper` share.
    public enum Step: Equatable, Sendable {
        case installed
        /// A formula while Homebrew is missing: install Homebrew first, never brew run into a wall.
        case needsHomebrew
        /// `brew install <formula>`, recorded as Pilot's install once it exits 0.
        case formula(Package)
        /// Homebrew's installer, which waits for Return so its next steps are read.
        case installer(String)
    }

    public func step(installed: Set<String>) -> Step {
        if installed.contains(id) { return .installed }
        switch route {
        case .installer(let command): return .installer(command)
        case .formula(let p): return installed.contains(Self.homebrew.id) ? .formula(p) : .needsHomebrew
        }
    }

    /// The path of its command in the folders Install looks in; Pilot runs with launchd's short PATH, so the folders
    /// are read, never PATH.
    public func path(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        CatalogueEntry.Check.commandFolders.lazy.map { NSString(string: "\($0)/\(self.command)").expandingTildeInPath }.first(where: isExecutable)
    }

    /// The ids of the helpers installed now.
    public static func installed(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Set<String> {
        Set(all.filter { $0.path(isExecutable: isExecutable) != nil }.map(\.id))
    }

    /// Install's search hint: the first missing helper that would add a source; nil when none is missing.
    public static func searchHint(installed: Set<String>) -> Helper? { all.first { $0.addsSource != nil && !installed.contains($0.id) } }
}
