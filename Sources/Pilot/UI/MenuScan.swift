import Foundation
import PilotCore

/// What the menu says while a branch's list is still being read (Sven, 2026-10-07 for Clean; 2026-10-12 for Update,
/// Remove and Install): the wait over its live line, the three steps from here with the running one "now", and the kinds
/// of row the list can hold, each wearing the glyph its rows will wear. Instrument's and Toybox's scan views draw it.
struct MenuScan {
    struct Step { let icon: MenuIcon, title: String, detail: String }
    /// A kind of row, shown only when this Mac has a tool it needs (`needs`, any of them; none needs nothing).
    struct Kind { let title: String, icon: MenuIcon; var needs: [String] = [] }

    let heading: String, line: String
    let steps: [Step]
    let kinds: [Kind]

    /// The kinds this Mac can list: every one when `tools` is unknown (renders, tests).
    func kinds(on tools: Set<String>?) -> [Kind] {
        guard let tools else { return kinds }
        return kinds.filter { $0.needs.isEmpty || !tools.isDisjoint(with: $0.needs) }
    }

    /// The command-line tools the kinds ask for that this Mac has: Homebrew's own, or anywhere a catalogue check looks.
    static func tools() -> Set<String> {
        let found = ["brew", "mas", "npm", "uv", "pipx", "bun", "cargo"].filter { Homebrew.cli($0) != nil || !CatalogueEntry.Check.copies(of: $0).isEmpty }
        return Set(found).union(InstallSearch.tools().map(\.rawValue))
    }

    private static let read = MenuIcon.glyph("magnifyingglass", .accent), list = MenuIcon.glyph("list.bullet.rectangle", .second)
    private static let brew = [Kind(title: "Homebrew formulae", icon: .formula, needs: ["brew"]),
                               Kind(title: "Homebrew casks", icon: .cask, needs: ["brew"])]

    /// Clean while `mo clean --dry-run` runs, Mole's progress as the line.
    static func clean(_ line: String) -> MenuScan {
        MenuScan(heading: "Mole is previewing what it would remove", line: line, steps: [
            Step(icon: read, title: "Mole previews", detail: "mo clean --dry-run reads every cache, log and leftover; nothing is removed"),
            Step(icon: list, title: "You read the list", detail: "each line under its section with its size, the total on top"),
            Step(icon: .glyph("sparkles", .good), title: "Clean asks first", detail: "↵ on Clean, then a confirm; mo clean removes what the list showed"),
        ], kinds: ["Browser caches", "Developer tools", "Logs", "Trash", "Downloads", "Message apps", "Media apps", "System caches",
                   "App leftovers"].map { Kind(title: $0, icon: .clean(title: $0, section: "")) })
    }

    /// Update while `brew outdated` and uv answer (InstallModule.updates); the other lists join once the rows show.
    static let update = MenuScan(
        heading: "Pilot is checking for updates",
        line: "Homebrew and uv answer first, then each other tool as it answers; it keeps going if you close the menu.",
        steps: [
            Step(icon: read, title: "Pilot checks", detail: "brew outdated and each tool's own outdated list, read-only; nothing upgrades"),
            Step(icon: list, title: "You read the list", detail: "Apps, Command-line tools and macOS, each from its version to the new one"),
            Step(icon: .glyph("arrow.up.circle", .good), title: "Update asks first", detail: "↵ on a row or Update all, then a confirm with the exact command"),
        ],
        kinds: brew + [Kind(title: "uv tools", icon: .uv, needs: ["uv"]), Kind(title: "macOS updates", icon: .macOS),
                       Kind(title: "App Store apps", icon: .appStore, needs: ["mas"]), Kind(title: "npm globals", icon: .npm, needs: ["npm"]),
                       Kind(title: "bun globals", icon: .bun, needs: ["bun"]), Kind(title: "cargo crates", icon: .cargo, needs: ["cargo"])])

    /// Remove while Homebrew's list, the apps, npm's tools and the web apps are read (InstallModule.removeRows).
    static let remove = MenuScan(
        heading: "Pilot is finding what can be removed",
        line: "Homebrew's list, then the apps, npm tools and web apps; sizes follow. Closing the menu stops the read.",
        steps: [
            Step(icon: read, title: "Pilot reads what is installed", detail: "brew info --installed, the Applications folders, npm and web apps; nothing is removed"),
            Step(icon: list, title: "You read the list", detail: "Apps, Command-line tools and Web apps, each with its size; Tab sorts"),
            Step(icon: .glyph("trash", .problem), title: "Remove asks first", detail: "↵ on a row, then a confirm; an app goes to the Trash, a tool is uninstalled"),
        ],
        kinds: brew + [Kind(title: "Apps", icon: .app), Kind(title: "App Store apps", icon: .appStore),
                       Kind(title: "npm globals", icon: .npm, needs: ["npm"]), Kind(title: "Web apps", icon: .webApp)])

    /// Install's search before any source answered: the Searching row's own words (the sources still asked) as the line.
    static func install(_ query: String, searching row: MenuEntry) -> MenuScan {
        MenuScan(heading: "Pilot is searching for “\(query)”", line: "\(row.title) \(row.detail ?? "")".trimmingCharacters(in: .whitespaces) + ".", steps: [
            Step(icon: read, title: "Every source at once", detail: "each one's results land under its name as it answers; nothing installs"),
            Step(icon: list, title: "You pick a result", detail: "the first result is selected the moment it lands; ↵ takes it"),
            Step(icon: .glyph("arrow.down.circle", .good), title: "Install asks first", detail: "a package confirms with its exact command first; a page opens in the browser"),
        ], kinds: brew + [Kind(title: "App Store apps", icon: .appStore), Kind(title: "GitHub repos", icon: .github),
                          Kind(title: "npm packages", icon: .npm, needs: ["npm"]), Kind(title: "Python tools", icon: .uv, needs: ["uv", "pipx"]),
                          Kind(title: "cargo crates", icon: .cargo, needs: ["cargo"]), Kind(title: "Go modules", icon: .go, needs: ["go"]),
                          Kind(title: "The web", icon: .webApp)])
    }
}
