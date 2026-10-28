import Foundation
import Observation

/// What Update can upgrade (stories 85 and 118): a Homebrew formula or cask or a uv tool, a global npm package in the
/// tree at `prefix` (a Mac can have Homebrew's and another), a global bun package, a cargo crate, an App Store app, or
/// a macOS update by its label.
public enum Updatable: Hashable, Sendable {
    case package(Package)
    case npm(String, prefix: String)
    case bun(String), cargo(String)
    case appStore(id: String, name: String)
    case macOS(label: String, title: String, restart: Bool)

    /// The row's id in Update's picks.
    public var key: String {
        switch self {
        case .package(let p): p.key
        case .npm(let n, let prefix): "npm:\(prefix):\(n)"
        case .bun(let n): "bun:\(n)"
        case .cargo(let n): "cargo:\(n)"
        case .appStore(let id, _): "mas:\(id)"
        case .macOS(let label, _, _): "macos:\(label)"
        }
    }

    /// What the row shows.
    public var name: String {
        switch self {
        case .package(let p): p.name
        case .npm(let n, _), .bun(let n), .cargo(let n), .appStore(_, let n), .macOS(_, let n, _): n
        }
    }

    public func kindLabel(home: String) -> String {
        switch self {
        case .package(let p): p.kindLabel
        case .npm(_, let prefix): "npm in \(AppConfigs.tilde(prefix, home: home))"
        case .bun: "bun"
        case .cargo: "cargo"
        case .appStore: "App Store"
        case .macOS: "macOS"
        }
    }
}

/// One thing Update would upgrade (stories 85 and 118): from which version to which ("" when the list does not say).
/// A pinned formula is shown and never upgraded.
public struct UpdateRow: Equatable, Sendable {
    public let item: Updatable, from: String, to: String
    /// A cask that updates itself: left out unless the setting includes such casks.
    public let selfUpdating: Bool, pinned: Bool
    /// A cask's app on disk, whose own icon its row wears (Sven 2026-10-09: Update's Apps showed none); brew outdated
    /// does not say, so Pilot asks `brew info` for it (UpdateList.caskApps).
    public var app: String?

    /// Upgrades when it, or Update all, is picked: not pinned, and shown.
    public func goes(includingSelfUpdating: Bool) -> Bool { !pinned && (includingSelfUpdating || !selfUpdating) }

    /// The category Update lists it under (card agent-bo-95423022).
    public var category: UpdateList.Category {
        switch item {
        case .macOS: .macOS
        case .appStore: .apps
        case .package(let p) where p.kind == .cask: .apps
        default: .tools
        }
    }

    public init(item: Updatable, from: String, to: String, selfUpdating: Bool = false, pinned: Bool = false) {
        self.item = item; self.from = from; self.to = to; self.selfUpdating = selfUpdating; self.pinned = pinned
    }
}

/// Update's list (SPEC.md: `brew outdated --json=v2`, self-updating casks left out unless a setting includes them,
/// outdated `uv` tools, and since story 118 macOS updates, App Store apps, global npm and bun packages and cargo crates,
/// from version to version; only what Sven confirms upgrades).
public enum UpdateList {
    /// What a row of Update is: Update all, the self-updating switch, Install mas, a row by its key, a pinned row,
    /// whose Return asks to unpin, or Reports (story 153).
    public enum Pick: Hashable, Sendable { case all, selfUpdating, installMas, row(String), unpin(String), reports }

    /// Update's categories in order, named as Remove's are; one with nothing outdated is not listed.
    public enum Category: String, CaseIterable, Sendable {
        case apps = "Apps", tools = "Command-line tools", macOS = "macOS"

        public var branch: MenuBranch { .category(rawValue, in: .update) }
    }

    /// `plain` is `brew outdated --json=v2`, `greedy` the same with `--greedy-auto-updates`: a cask only the greedy one
    /// lists updates itself.
    public static func parse(plain: Data, greedy: Data) throws -> [UpdateRow] {
        let plainCasks = Set(try JSONDecoder().decode(Outdated.self, from: plain).casks.map(\.name))
        let all = try JSONDecoder().decode(Outdated.self, from: greedy)
        let formulae = all.formulae.compactMap { row(.formula, $0, selfUpdating: false) }
        let casks = all.casks.compactMap { row(.cask, $0, selfUpdating: !plainCasks.contains($0.name)) }
        return formulae + casks
    }

    /// `uv tool list --outdated`: `name vX [latest: Y]`, each followed by its executables on `- ` lines.
    public static func parseUV(_ text: String) -> [UpdateRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> UpdateRow? in
            let parts = line.split(separator: " ")
            guard parts.count == 4, parts[1].hasPrefix("v"), parts[2] == "[latest:", parts[3].hasSuffix("]"),
                  let package = Package(.uv, String(parts[0])) else { return nil }
            return UpdateRow(item: .package(package), from: String(parts[1].dropFirst()), to: String(parts[3].dropLast()))
        }
    }

    /// `softwareupdate --list`: `* Label: X`, then `Title: T, Version: V, …, Action: restart,` on the next line. A macOS
    /// update goes from the running `macOS`; for anything else the list does not say.
    public static func parseSoftwareUpdate(_ text: String, macOS: String) -> [UpdateRow] {
        var rows: [UpdateRow] = [], label: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if let m = line.firstMatch(of: /^\s*[*-]?\s*Label: (.+)$/) { label = String(m.1); continue }
            guard let current = label, let title = line.firstMatch(of: /Title: ([^,]+)/)?.1 else { continue }
            label = nil
            rows.append(UpdateRow(item: .macOS(label: current, title: String(title), restart: line.contains("Action: restart")),
                                  from: title.hasPrefix("macOS") ? macOS : "", to: line.firstMatch(of: /Version: ([^,]+)/).map { String($0.1) } ?? ""))
        }
        return rows
    }

    /// `mas outdated`: `<id> <name> (<from> -> <to>)`.
    public static func parseMas(_ text: String) -> [UpdateRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> UpdateRow? in
            guard let m = line.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(\d+)\s+(.+?)\s+\((\S+) -> (\S+)\)/) else { return nil }
            return UpdateRow(item: .appStore(id: String(m.1), name: String(m.2)), from: String(m.3), to: String(m.4))
        }
    }

    /// `npm outdated -g --json` from one npm: each package with its tree, from `location` (`<prefix>/lib/node_modules/…`).
    /// Homebrew's own npm and corepack are the node formula's, so they stay out.
    public static func parseNPM(_ json: Data) -> [UpdateRow] {
        struct Row: Decodable { let current: String?; let latest: String?; let location: String? }
        guard let rows = try? JSONDecoder().decode([String: Row].self, from: json) else { return [] }
        return rows.sorted { $0.key < $1.key }.compactMap { name, r -> UpdateRow? in
            guard let current = r.current, let latest = r.latest, let prefix = r.location.flatMap(npmPrefix), Package.isName(name),
                  Package.isName(latest) else { return nil }
            if ["npm", "corepack"].contains(name), ["/opt/homebrew", "/usr/local"].contains(prefix) { return nil }
            return UpdateRow(item: .npm(name, prefix: prefix), from: current, to: latest)
        }
    }

    /// The tree a global npm package lives in, from its path (`<prefix>/lib/node_modules/…`).
    public static func npmPrefix(_ path: String) -> String? { path.range(of: "/lib/node_modules/").map { String(path[..<$0.lowerBound]) } }

    /// npm `verb` on the tree at `prefix` through that tree's own npm: `--prefix`, since the visible terminal's PATH may
    /// start another node, whose npm would act on its own tree.
    public static func npm(_ verb: String, prefix: String) -> String {
        "\(VisibleRun.quoted(prefix + "/bin/npm")) \(verb) -g --prefix \(VisibleRun.quoted(prefix))"
    }

    /// `bun outdated -g`: its box table, Package, Current, Update and Latest; a `(dev)` tag is dropped.
    public static func parseBun(_ text: String) -> [UpdateRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> UpdateRow? in
            let cells = line.split(separator: "│").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cells.count == 4, cells[0] != "Package" else { return nil }
            let name = cells[0].replacing(/\s*\(\w+\)$/, with: "")
            guard Package.isName(name) else { return nil }
            return UpdateRow(item: .bun(name), from: cells[1], to: cells[3])
        }
    }

    /// `cargo install --list`: the crates installed from crates.io, `name vX:`; a path or git crate names its source in
    /// brackets and is left out, since crates.io has no newer copy of it.
    public static func cargoCrates(_ text: String) -> [(name: String, version: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let m = line.wholeMatch(of: /(\S+) v(\S+):/), Package.isName(String(m.1)) else { return nil }
            return (String(m.1), String(m.2))
        }
    }

    /// `cargo search <crate> --limit 1`'s line for exactly that crate: `name = "X"`.
    public static func cargoLatest(_ text: String, crate: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.compactMap { $0.firstMatch(of: /^(\S+) = "([^"]+)"/) }
            .first { $0.1 == crate }.map { String($0.2) }
    }

    /// The tip when a check ends with Update not on screen; nil while it shows, since its rows (or its failure) say it.
    public static func tip(_ rows: [UpdateRow]?, includeSelfUpdating: Bool, showing: Bool) -> String? {
        guard !showing else { return nil }
        guard let rows else { return "Homebrew's outdated list could not be read; open Update to try again" }
        let count = visible(rows, includeSelfUpdating: includeSelfUpdating).count
        return count == 0 ? "Everything is up to date" : "\(count) update\(count == 1 ? "" : "s") ready in Pilot's menu"
    }

    public static func visible(_ rows: [UpdateRow], includeSelfUpdating: Bool) -> [UpdateRow] {
        rows.filter { includeSelfUpdating || !$0.selfUpdating }
    }

    /// The one command the rows that go run, nil when none does: formulae, casks (`--greedy` when a self-updating one
    /// is among them, or brew skips it), uv tools, npm packages through each tree's own npm, bun, cargo, App Store apps,
    /// then macOS updates (never `-R`: macOS asks before it restarts), each step only after the one before succeeds.
    public static func command(_ rows: [UpdateRow], includeSelfUpdating: Bool) -> String? {
        let go = rows.filter { $0.goes(includingSelfUpdating: includeSelfUpdating) }
        func step(_ prefix: String, _ words: [String]) -> String? { words.isEmpty ? nil : ([prefix] + words).joined(separator: " ") }
        func packages(_ kind: Package.Kind) -> [String] { go.compactMap { if case .package(let p) = $0.item, p.kind == kind { p.name } else { nil } } }
        let greedy = go.contains(where: \.selfUpdating) ? " --greedy" : ""
        var npm: [(prefix: String, words: [String])] = []
        for r in go {
            guard case .npm(let name, let prefix) = r.item else { continue }
            if let i = npm.firstIndex(where: { $0.prefix == prefix }) { npm[i].words.append("\(name)@\(r.to)") } else { npm.append((prefix, ["\(name)@\(r.to)"])) }
        }
        let steps = [step("brew upgrade --formula", packages(.formula)), step("brew upgrade --cask\(greedy)", packages(.cask)),
                     step("uv tool upgrade", packages(.uv))]
            + npm.map { step(Self.npm("install", prefix: $0.prefix), $0.words) }
            + [step("bun update -g --latest", go.compactMap { if case .bun(let n) = $0.item { n } else { nil } }),
               step("cargo install", go.compactMap { if case .cargo(let n) = $0.item { n } else { nil } }),
               step("mas upgrade", go.compactMap { if case .appStore(let id, _) = $0.item { id } else { nil } }),
               step("softwareupdate -i", go.compactMap { if case .macOS(let label, _, _) = $0.item { VisibleRun.quoted(label) } else { nil } })]
        let run = steps.compactMap(\.self)
        return run.isEmpty ? nil : run.joined(separator: " && ")
    }

    /// What Update all runs: every shown row that goes but macOS's updates, which are each Sven's own pick.
    public static func all(_ rows: [UpdateRow], includeSelfUpdating: Bool) -> String? {
        command(allRows(rows, includeSelfUpdating: includeSelfUpdating), includeSelfUpdating: includeSelfUpdating)
    }

    /// The rows Update all upgrades, which its report lists.
    public static func allRows(_ rows: [UpdateRow], includeSelfUpdating: Bool) -> [UpdateRow] {
        rows.filter { r in
            if case .macOS = r.item { return false }
            return r.goes(includingSelfUpdating: includeSelfUpdating)
        }
    }

    /// What Update all updates in a few words, "2 casks · 1 formula · 1 uv tool": the rows that go, but macOS's; nil
    /// when none does.
    public static func summary(_ rows: [UpdateRow], includeSelfUpdating: Bool) -> String? {
        let go = allRows(rows, includeSelfUpdating: includeSelfUpdating)
        let kinds: [(noun: String, plural: String, counts: (Updatable) -> Bool)] = [
            ("cask", "casks", { if case .package(let p) = $0 { p.kind == .cask } else { false } }),
            ("formula", "formulae", { if case .package(let p) = $0 { p.kind == .formula } else { false } }),
            ("uv tool", "uv tools", { if case .package(let p) = $0 { p.kind == .uv } else { false } }),
            ("npm package", "npm packages", { if case .npm = $0 { true } else { false } }),
            ("bun package", "bun packages", { if case .bun = $0 { true } else { false } }),
            ("crate", "crates", { if case .cargo = $0 { true } else { false } }),
            ("App Store app", "App Store apps", { if case .appStore = $0 { true } else { false } }),
        ]
        let words = kinds.compactMap { k -> String? in
            let n = go.count { k.counts($0.item) }
            return n == 0 ? nil : "\(n) \(n == 1 ? k.noun : k.plural)"
        }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// Update's rows (card agent-bo-95423022, browsed as Install is): Update all with its exact command, a branch per
    /// category with something outdated, naming it, each row there with its versions and where it came from, the switch
    /// for self-updating casks, and Install mas while mas is missing and recommendations show (Install's Recommend apps,
    /// card agent-bo-95423241). Return on a row asks to update that one.
    /// The outdated casks' tokens, for `brew info --json=v2 --cask`, which names each one's app.
    public static func caskTokens(_ rows: [UpdateRow]) -> [String] {
        rows.compactMap { if case .package(let p) = $0.item, p.kind == .cask { p.name } else { nil } }
    }

    /// `brew info --json=v2 --cask <tokens>` read as Remove reads Homebrew's list: each row whose cask names an app gets
    /// it, so its row wears the app's own icon.
    public static func withApps(_ rows: [UpdateRow], info: Data) -> [UpdateRow] {
        let apps = Dictionary(((try? RemoveList.parse(info)) ?? []).compactMap { r in r.app.map { (r.key, $0) } }) { a, _ in a }
        return rows.map { var r = $0; r.app = apps[r.item.key] ?? r.app; return r }
    }

    /// Each row wears its app's own icon: a cask's app, else `icons`' (the Install catalogue's by package key: its app
    /// once installed, else its shipped picture), else its kind's glyph.
    public static func entries(_ rows: [UpdateRow], includeSelfUpdating: Bool, masInstalled: Bool = true, recommend: Bool = true,
                               icons: [String: MenuIcon] = [:], home: String = NSHomeDirectory()) -> [MenuEntry] {
        let shown = visible(rows, includeSelfUpdating: includeSelfUpdating)
        let run = MenuEntry(title: "Update all", target: .update(.all), home: .update,
                            detail: all(shown, includeSelfUpdating: includeSelfUpdating)
                                ?? (shown.isEmpty ? "everything is up to date" : "only macOS updates or pinned formulae left, pick each one"), inSearch: false,
                            icon: .glyph("arrow.down.circle", .accent), short: summary(shown, includeSelfUpdating: includeSelfUpdating))
        let branches = Category.allCases.compactMap { c -> MenuEntry? in
            let mine = shown.filter { $0.category == c }
            guard !mine.isEmpty else { return nil }
            return MenuEntry(title: c.rawValue, target: .branch(c.branch), home: .update, detail: mine.map(\.item.name).joined(separator: ", "),
                             icon: MenuIcon.updateCategory(c))
        }
        let listed = shown.map { r in
            let restart = if case .macOS(_, _, true) = r.item { "restarts the Mac" } else { nil as String? }
            let versions = r.from.isEmpty ? "→ \(r.to)" : "\(r.from) → \(r.to)"
            let detail = ([versions, r.item.kindLabel(home: home), r.pinned ? "pinned by you · Return unpins" : nil, r.selfUpdating ? "updates itself" : nil, restart] as [String?])
                .compactMap(\.self).joined(separator: " · ")
            return MenuEntry(title: r.item.name, target: .update(unpin(r) == nil ? .row(r.item.key) : .unpin(r.item.key)),
                             home: r.category.branch, detail: detail, inSearch: false,
                             icon: r.app.map { MenuIcon.updatable(r.item, app: $0) } ?? icons[r.item.key] ?? MenuIcon.updatable(r.item))
        }
        let setting = MenuEntry(title: "Apps that update themselves: \(includeSelfUpdating ? "On" : "Off")", target: .update(.selfUpdating),
                                home: .update, inSearch: false, icon: .glyph("arrow.triangle.2.circlepath", .second))
        let reports = MenuEntry(title: "Reports", target: .update(.reports), home: .update, detail: "every Update and Clean run, kept",
                                inSearch: false, icon: MenuIcon.reports)
        let mas = masInstalled || !recommend ? [] : [MenuEntry(title: "App Store apps: install mas", target: .update(.installMas), home: .update,
                                                 detail: Helper.mas.install, inSearch: false, icon: MenuIcon.appStore)]
        return [run] + branches + [setting] + mas + [reports] + listed
    }

    /// The way out of a pin (card agent-bo-95422979): `brew unpin` for a pinned formula, nil for any other row.
    public static func unpin(_ row: UpdateRow) -> String? {
        guard row.pinned, case .package(let p) = row.item, p.kind == .formula else { return nil }
        return "brew unpin \(p.name)"
    }

    private static func row(_ kind: Package.Kind, _ o: Outdated.Row, selfUpdating: Bool) -> UpdateRow? {
        guard let package = Package(kind, o.name), let from = o.installed_versions.last else { return nil }
        return UpdateRow(item: .package(package), from: from, to: o.current_version, selfUpdating: selfUpdating, pinned: o.pinned ?? false)
    }

    private struct Outdated: Decodable {
        struct Row: Decodable { let name: String; let installed_versions: [String]; let current_version: String; let pinned: Bool? }
        let formulae: [Row]
        let casks: [Row]
    }
}

/// Update's check (Sven 2026-10-25, as Clean's preview): Homebrew's and uv's rows, then the other lists joining them,
/// run once and kept as long as Mole's preview (CleanPreviewer.keep). It keeps going when the menu closes, and a menu
/// opening meanwhile, from the keys or Mac › Update & Clean, reads the same run. `first` reads Homebrew's and uv's rows,
/// nil when they could not be read; `more` the lists that join them, read at the same time.
@MainActor @Observable
public final class UpdateChecker {
    public static let keep = CleanPreviewer.keep

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let first: @Sendable () async -> [UpdateRow]?
    @ObservationIgnored private let more: @Sendable () async -> [UpdateRow]
    /// When the last check ended with every list read.
    @ObservationIgnored private var at: Date?
    @ObservationIgnored private var landing: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Bumped by `drop` and each new check, so a run let go of neither lands nor is kept.
    @ObservationIgnored private var generation = 0
    /// The rows so far: Homebrew's and uv's, then every list once the rest joined; nil before they land or when they failed.
    public private(set) var rows: [UpdateRow]?
    /// Whether a check runs, until its last list joined.
    public private(set) var checking = false
    /// Each run's end, once, whether or not a menu waits on it: every row, or nil when Homebrew's could not be read.
    @ObservationIgnored public var onFinish: (([UpdateRow]?) -> Void)?

    public init(now: @escaping () -> Date = { .now }, first: @escaping @Sendable () async -> [UpdateRow]?,
                more: @escaping @Sendable () async -> [UpdateRow]) {
        self.now = now
        self.first = first
        self.more = more
    }

    /// The rows while a check runs or its rows are fresh; nil when the next open checks again.
    public var current: [UpdateRow]? {
        if checking { return rows }
        guard let at, now().timeIntervalSince(at) < Self.keep else { return nil }
        return rows
    }

    /// Homebrew's and uv's rows at least: the current ones, or the check's once they land, starting one when none runs;
    /// nil when they could not be read. Cancelling the caller only stops its wait: the check carries on.
    public func check() async -> [UpdateRow]? {
        if let current { return current }
        if !checking { start() }
        await landing?.value
        return rows
    }

    /// Every row, once the check's last list joined; starts one when nothing is current.
    public func checked() async -> [UpdateRow]? {
        if !checking, current == nil { start() }
        await running?.value
        return rows
    }

    /// After an update or an unpin the kept rows are wrong, so the next open checks again; a check still running stops.
    public func drop() {
        generation += 1
        rows = nil
        at = nil
        checking = false
        landing?.cancel()
        running?.cancel()
        landing = nil
        running = nil
    }

    private func start() {
        generation += 1
        let mine = generation
        rows = nil
        at = nil
        checking = true
        let landing = Task { [weak self, first] in
            let read = await first()
            self?.landed(read, in: mine)
        }
        self.landing = landing
        running = Task { [weak self, more] in
            let joining = await more()
            await landing.value
            self?.joined(joining, in: mine)
        }
    }

    private func landed(_ read: [UpdateRow]?, in run: Int) {
        guard run == generation else { return }
        guard let read else {
            checking = false
            running?.cancel()
            onFinish?(nil)
            return
        }
        rows = read
    }

    private func joined(_ more: [UpdateRow], in run: Int) {
        guard run == generation, checking else { return }
        rows? += more
        checking = false
        at = now()
        onFinish?(rows)
    }
}
