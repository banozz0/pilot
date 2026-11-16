import CryptoKit
import Foundation
import PilotCore

/// The pull request `pilot theme publish` and `pilot ext publish` open (Sven, 2026-11-16): a title that names the pack
/// and a body for the catalogue's owner, made from the pack's own files before the Allow, which shows both. Its sections
/// follow the pr skill's template (Summary, Evidence, Merge Danger; after Dex Horthy's show-me skill, HumanLayer), as
/// .github/PULL_REQUEST_TEMPLATE.md does for a pull request opened by hand.
/// Every word from the pack is a stranger's: it is one line, its Markdown and HTML written out as text and an `@` kept
/// from mentioning anyone, so a pack can neither hide words from the reviewer nor tick the checklist, which is Pilot's.
enum CataloguePullRequest {
    /// What the body says that the pack's folder does not: read in the plan, before the Allow.
    struct Facts: Equatable, Sendable {
        /// The catalogue's index on origin/main lists this id: the title says update, and the body what changed.
        let update: Bool
        /// The listed extension's version.
        let listedVersion: String?
        /// Each file that differs from the listed copy: "added", "changed" or "removed", then its path in the pack.
        let changes: [String]
        /// check.py's last line, run on origin/main's catalogue with this pack in it.
        let check: String
        /// "Pilot 1.3.0 (build 19)".
        let build: String
        /// The handle the pack credits (`Pack by:`), or the sender's from a fork.
        let author: String?
        /// The catalogue's repo, "owner/name", whose copy of the commit the preview's link reaches.
        let repo: String
    }

    static func title(_ pack: CataloguePublish.Pack, update: Bool) -> String {
        let kind = pack.kind == .themes ? "Theme" : "Extension"
        let name = pack.kind == .themes ? pack.title : "\(pack.title) \(pack.label)"
        // A title is plain text on GitHub: one line and capped, nothing escaped.
        var flat = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if flat.count > 80 { flat = String(flat.prefix(79)) + "…" }
        return "\(kind)\(update ? " update" : ""): \(flat)"
    }

    /// GitHub's cap on a pull request's body, in characters; a title and body past it are refused before the Allow.
    static let longest = 65_536

    /// The body, read once in the plan and kept there: the Allow shows it (`shown`) and the publish sends it (`sent`),
    /// never read again from the pack's folder. The preview's link waits for the commit's id: `linkStart`…`linkEnd`
    /// wrap the whole link and `commitMark` stands for the id, characters no pack word can hold (`oneLine` and `code`
    /// drop every control character).
    static func body(_ pack: CataloguePublish.Pack, _ facts: Facts) -> String {
        let parts = pack.kind == .themes ? theme(pack, facts) : extensionBody(pack, facts)
        return parts.joined(separator: "\n") + "\n"
    }
    private static let commitMark = "\u{0}", linkStart = "\u{1}", linkEnd = "\u{2}"

    /// The body as the Allow shows it: `<commit>` where the id will go.
    static func shown(_ body: String) -> String {
        body.replacingOccurrences(of: linkStart, with: "").replacingOccurrences(of: linkEnd, with: "")
            .replacingOccurrences(of: commitMark, with: "<commit>")
    }

    /// The body as sent: the commit's id in the preview's link, or, when git gave none, no link at all.
    static func sent(_ body: String, commit: String?) -> String {
        if let commit, commit.wholeMatch(of: /[0-9a-f]{40}/) != nil {
            return body.replacingOccurrences(of: linkStart, with: "").replacingOccurrences(of: linkEnd, with: "")
                .replacingOccurrences(of: commitMark, with: commit)
        }
        return body.replacing(/\x{1}[^\x{2}]*\x{2}/, with: "(not linked: git gave no commit id)")
    }

    /// Title and body together, the body as sent (a 40-character id in place of the mark).
    static func length(_ title: String, _ body: String) -> Int {
        title.count + sent(body, commit: String(repeating: "0", count: 40)).count
    }

    // MARK: Theme

    /// The roles a reviewer looks at, in order, as the palette names them.
    private static let roles: [(key: String, name: String)] = [
        ("accent", "Accent"), ("background", "Background"), ("foreground", "Text"), ("light_foreground", "Second text"),
        ("muted", "Muted"), ("selection", "Selection"), ("red", "Red"), ("yellow", "Yellow"), ("green", "Green"),
        ("cyan", "Cyan"), ("blue", "Blue"), ("magenta", "Magenta"),
    ]
    private static let appNames = ["ghostty": "Ghostty", "zed": "Zed", "obsidian": "Obsidian"]

    private static func theme(_ pack: CataloguePublish.Pack, _ facts: Facts) -> [String] {
        let manifest = json(pack.folder.appending(path: "manifest.json"))
        let provenance = (try? String(contentsOf: pack.folder.appending(path: "PROVENANCE.md"), encoding: .utf8)) ?? ""
        let dark = manifest["dark"] as? Bool ?? true
        let palette = manifest["palette"] as? [String: String] ?? [:]
        let variants = (manifest["variants"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
        let wallpapers = pictures(manifest["wallpapers"] as? [String] ?? [], in: pack.folder)
        let apps = ["Pilot"] + ((manifest["adapters"] as? [String: Any]).map { Array($0.keys).sorted() } ?? [])
            .map { appNames[$0] ?? oneLine($0, 30) }
        let modes = ([dark ? "dark" : "light"] + variants.map { oneLine($0, 20) }).joined(separator: " and ")
        var lines = ["## Summary", "",
                     "\(leading(oneLine(pack.title, 80))): a \(modes) theme \(facts.author.map { "by \(handle($0))" } ?? "from Pilot"), "
                        + "\(count(wallpapers.count, "wallpaper")), for \(list(apps)). It goes in `\(pack.path)/`.", "",
                     "| Role | Colour |", "| --- | --- |"]
        for role in roles { if let hex = palette[role.key] { lines.append("| \(role.name) | \(hexCell(hex)) |") } }
        let others = palette.count - roles.filter { palette[$0.key] != nil }.count
        if others > 0 { lines += ["", "And \(count(others, "more colour")) in `manifest.json` (terminal brights and Pilot's own roles)."] }
        lines += ["", "**Wallpapers:** \(wallpapers.isEmpty ? "none." : "\(wallpapers.count), as PROVENANCE.md records them:")"]
        let licence = wallpaperLines(provenance)
        if !wallpapers.isEmpty {
            lines += licence.isEmpty ? ["", "- PROVENANCE.md says nothing about them: ask the author where they come from."]
                : [""] + licence.prefix(12).map { "- \($0)" }
        }
        let palettes = section("Palette", of: provenance)
        if !palettes.isEmpty { lines += ["", "**Palette from:**", ""] + palettes.prefix(4).map { "- \(oneLine($0, 240))" } }
        lines += updateLines(facts)
        lines += ["", "## Evidence", "", "- **Checks:** `catalogue/scripts/check.py`, run on the catalogue's main with this pack in it: `\(code(facts.check))`"]
        if let preview = manifest["preview"] as? String {
            let path = "\(pack.path)/\(preview)"
            let link = "https://github.com/\(facts.repo)/blob/\(commitMark)/\(url(path))?raw=true"
            // GitHub draws only the web's picture kinds in a body; a HEIC or the like is a link it downloads.
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(URL(filePath: preview).pathExtension.lowercased()) {
                lines.append("- **Preview:** the pack's own picture, committed in it as `\(code(preview))`:")
                lines += ["", "  \(linkStart)![\(oneLine(pack.title, 40)) preview](\(link))\(linkEnd)"]
            } else {
                lines.append("- **Preview:** the pack's own picture, committed in it as `\(code(preview))`, which GitHub cannot show in place: \(linkStart)[open it](\(link))\(linkEnd)")
            }
        } else {
            lines.append("- **Preview:** none; the pack has no `preview`, so the palette above is the whole look.")
        }
        lines.append("- **Sent by:** \(facts.build), `pilot theme publish \(code(pack.id))`")
        lines += ["", "## Merge Danger", "",
                  "**Door:** two-way",
                  "",
                  "A theme is colours, wallpapers and the config Pilot writes for \(list(apps.filter { $0 != "Pilot" }, or: "no other app")) on Apply. "
                    + "A revert takes it out of the gallery; anyone who applied it keeps it until they pick another.",
                  "",
                  "**Blast Radius:** cosmetic",
                  "",
                  "Only Macs that apply it change, and only in look."]
        lines += review(pack, [
            "Licence: the palette's source and every wallpaper allow this use, as PROVENANCE.md says",
            "The preview and wallpapers are what the pack says they are, nothing unrelated or unkind",
        ])
        return lines
    }

    // MARK: Extension

    private static func extensionBody(_ pack: CataloguePublish.Pack, _ facts: Facts) -> [String] {
        let manifest = json(pack.folder.appending(path: "extension.json"))
        let commands = manifest["commands"] as? [[String: Any]] ?? []
        let shown = commands.filter { ($0["hidden"] as? Bool) != true }
        let permissions = manifest["permissions"] as? [String: Any] ?? [:]
        let network = permissions["network"] as? [String] ?? []
        let files = permissions["files"] as? [String] ?? []
        let actions = permissions["actions"] as? [String] ?? []
        let clipboard = permissions["clipboard"] as? Bool ?? false
        let requires = manifest["requires"] as? [String] ?? []
        let programs = Array(Set(commands.compactMap { $0["run"] as? String })).sorted()
        let surfaces = manifest["surfaces"] as? [String: Any] ?? [:]
        var lines = ["## Summary", "",
                     "\(leading(oneLine(pack.title, 80))) \(oneLine(pack.label, 20)): \(oneLine(manifest["description"] as? String ?? "no description.", 400))", "",
                     "| Command | Shows |", "| --- | --- |"]
        lines += shown.map { "| \(cell($0["title"] as? String ?? $0["name"] as? String ?? "?")) | \(cell($0["mode"] as? String ?? "?")) |" }
        if shown.isEmpty { lines.append("| none listed | |") }
        if commands.count > shown.count { lines += ["", "And \(count(commands.count - shown.count, "hidden command")) only the extension itself runs."] }
        let places = surfaces.keys.sorted().map { key -> String in
            let every = (surfaces[key] as? [String: Any])?["every"] as? Int
            return "\(key == "bar" ? "top bar item" : key == "page" ? "page" : oneLine(key, 20))\(every.map { ", every \($0) s" } ?? "")"
        }
        if !places.isEmpty { lines += ["", "**Surfaces:** \(places.joined(separator: "; "))."] }
        lines += ["", "**What it touches:**", "",
                  "- **Runs:** \(programs.isEmpty ? "nothing" : programs.map { "`\(code($0))`" }.joined(separator: ", ")) as the user, with their rights\(requires.isEmpty ? "" : "; needs \(requires.map { "`\(code($0))`" }.joined(separator: ", "))")",
                  "- **Network:** \(network.isEmpty ? "none declared" : network.map { "`\(code($0))`" }.joined(separator: ", "))",
                  "- **Files:** \(files.isEmpty ? "none declared" : files.map { "`\(code($0))`" }.joined(separator: ", "))",
                  "- **Clipboard:** \(clipboard ? "reads or writes it" : "no")",
                  "- **Pilot actions:** \(actions.isEmpty ? "none" : actions.map { "`\(code($0))`" }.joined(separator: ", "))",
                  "", "Pilot shows these permissions; it does not enforce them (ADR 0010), so the programs are what to read."]
        lines += updateLines(facts)
        lines += ["", "## Evidence", "",
                  "- **Checks:** `catalogue/scripts/check.py`, run on the catalogue's main with this extension in it: `\(code(facts.check))`",
                  "- **Version:** \(facts.listedVersion.map { "`\(code($0))` in the catalogue, `\(code(pack.label))` here" } ?? "`\(code(pack.label))`, new to the catalogue")",
                  "- **Sent by:** \(facts.build), `pilot ext publish \(code(pack.id))`"]
        let reach = network.isEmpty ? "" : " and reach \(list(network.map { "`\(code($0))`" }))"
        lines += ["", "## Merge Danger", "",
                  "**Door:** one-way for anyone who installs it",
                  "",
                  "Its programs run on their Mac as them\(reach). A revert takes it out of the catalogue, not off the Macs that installed it, "
                    + "and what it already ran, sent or wrote stays done.",
                  "",
                  "**Blast Radius:** every Mac that installs it",
                  "",
                  "A bad version reaches each install that takes the update."]
        lines += review(pack, [
            "Licence: the code is the author's own or under a licence that allows it; no code from Raycast, Vicinae, ClipBook or Alfred extensions",
            "The programs do only what the Summary says: every host they reach and file they write is declared",
            "Python 3 standard library only, protocol lines alone on stdout, no item titles, clipboard text or secrets logged",
        ])
        return lines
    }

    // MARK: Shared

    private static func updateLines(_ facts: Facts) -> [String] {
        guard facts.update else { return [] }
        guard !facts.changes.isEmpty else { return ["", "**Changed since the catalogue's copy:** no file."] }
        return ["", "**Changed since the catalogue's copy:**", ""] + facts.changes.prefix(30).map { "- \($0)" }
            + (facts.changes.count > 30 ? ["- and \(facts.changes.count - 30) more"] : [])
    }

    /// The reviewer's checklist, Pilot's words only and none ticked.
    private static func review(_ pack: CataloguePublish.Pack, _ own: [String]) -> [String] {
        ["", "## Review", ""] + (own + [
            "No secrets: no tokens, keys, personal paths or account names in any file",
            "Scope: only `\(pack.path)/` and `catalogue/index.json` change",
        ]).map { "- [ ] \($0)" }
    }

    /// Each file that differs from `listed`, the index's copy, by sha256: added, changed, then removed.
    static func changes(_ folder: URL, listed: [ExtensionCatalogue.File]) -> [String] {
        let mine = files(folder)
        let theirs = Dictionary(listed.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for (path, sha) in mine.sorted(by: { $0.key < $1.key }) {
            if let old = theirs[path] { if old != sha { out.append("changed `\(code(path))`") } } else { out.append("added `\(code(path))`") }
        }
        out += theirs.keys.filter { mine[$0] == nil }.sorted().map { "removed `\(code($0))`" }
        return out
    }

    /// The folder's files by path inside it, each its sha256, `__pycache__` left out as the publish leaves it.
    static func files(_ folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let file as URL in walk {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = file.standardizedFileURL.path(percentEncoded: false)
            let path = String(full.dropFirst(base.hasSuffix("/") ? base.count : base.count + 1))
            guard !path.split(separator: "/").contains("__pycache__"), let data = try? Data(contentsOf: file) else { continue }
            out[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private static func json(_ file: URL) -> [String: Any] {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// The list items under `## <name>` in PROVENANCE.md, their marker dropped, each with the `###` heading it sits under
    /// (a wallpaper's file name), nil for one straight under the section.
    static func items(_ name: String, of text: String) -> [(under: String?, item: String)] {
        var inside = false, under: String?, out: [(String?, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count, words = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if level <= 2 { inside = words.lowercased() == name.lowercased(); under = nil } else if inside { under = words }
                continue
            }
            guard inside, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            out.append((under, String(trimmed.dropFirst(2))))
        }
        return out
    }

    static func section(_ name: String, of text: String) -> [String] { items(name, of: text).map(\.item) }

    /// What PROVENANCE.md says of each wallpaper: under a `###` per file, its rights, licence, source and author lines
    /// (each file one line); else the section's own list.
    static func wallpaperLines(_ text: String) -> [String] {
        let found = items("Wallpapers", of: text)
        let keys = ["rights", "licence", "license", "source", "author"]
        var order: [String] = [], picked: [String: [String]] = [:], plain: [String] = []
        for (under, item) in found {
            guard let under else { plain.append(oneLine(item, 240)); continue }
            if picked[under] == nil { order.append(under); picked[under] = [] }
            if keys.contains(where: { item.lowercased().hasPrefix($0) }) { picked[under]?.append(item) }
        }
        return plain + order.map { file in
            let said = picked[file] ?? []
            return "`\(code(file))`: " + (said.isEmpty ? "no rights, licence or source line" : said.map { oneLine($0, 160) }.joined(separator: "; "))
        }
    }

    /// The pictures a manifest's wallpapers name: a file, or each file in a folder, inside the pack.
    private static func pictures(_ entries: [String], in folder: URL) -> [String] {
        entries.flatMap { entry -> [String] in
            let url = folder.appending(path: entry)
            var folderFlag: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &folderFlag) else { return [] }
            guard folderFlag.boolValue else { return [entry] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted().map { "\(entry)/\($0)" }
        }
    }

    /// A stranger's words as one line of plain text: breaks and runs of space one space, at most `limit` characters,
    /// Markdown's and HTML's marks written out, and `@` kept from mentioning (a zero-width space after it).
    static func oneLine(_ text: String, _ limit: Int) -> String {
        var flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        flat = String(flat.unicodeScalars.filter { !ExtensionCheck.hides($0) })
        if flat.count > limit { flat = String(flat.prefix(limit - 1)) + "…" }
        var out = ""
        for ch in flat {
            switch ch {
            case "\\", "`", "*", "_", "[", "]", "#", "!", "|", "~", ">": out += "\\\(ch)"
            case "<": out += "&lt;"
            case "&": out += "&amp;"
            case "@": out += "@\u{200B}"
            default: out.append(ch)
            }
        }
        return out
    }

    /// A line that starts with a stranger's words: a list or heading marker at its start written out, so the line stays
    /// a sentence ("- x", "+ x", "1. x", "1) x"; `oneLine` already escapes "#" and ">").
    private static func leading(_ text: String) -> String {
        if let first = text.first, first == "-" || first == "+" { return "\\" + text }
        if let match = text.prefixMatch(of: /(\d{1,9})([.)])/) { return match.output.1 + "\\" + text.dropFirst(match.output.1.count) }
        return text
    }

    /// A table cell's words.
    private static func cell(_ text: String) -> String { oneLine(text, 80) }

    /// Inside a code span: one line, no hidden character, no backtick, no pipe (a table would split on it).
    private static func code(_ text: String) -> String {
        let flat = String(text.components(separatedBy: .newlines).joined(separator: " ").unicodeScalars.filter { !ExtensionCheck.hides($0) })
        return String(flat.prefix(200)).replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "|", with: "/")
    }

    /// A colour cell: the hex as code when it is one, else its words.
    private static func hexCell(_ hex: String) -> String {
        hex.wholeMatch(of: /#[0-9A-Fa-f]{3,8}/) != nil ? "`\(hex.uppercased())`" : cell(hex)
    }

    /// A handle as code, so it names and never mentions.
    private static func handle(_ login: String) -> String { "`@\(code(login))`" }

    /// RFC 3986's unreserved characters, the only ones a path segment keeps as they are: anything else, `(`, `)`, `@`,
    /// `*` and `!` among them, is percent-encoded, so a file name can never end the link or start Markdown after it.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func url(_ path: String) -> String {
        path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }.joined(separator: "/")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 0 ? "no \(noun)s" : n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    private static func list(_ items: [String], or none: String = "nothing") -> String {
        switch items.count {
        case 0: none
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
