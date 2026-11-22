import Foundation

/// Folders walked from the menu without Finder (spec launcher-best T8, LaunchBar's → and ←): a root search starting `/`
/// or `~` lists what the typed path names, and → on a folder row opens it, listing its own items read on the press with
/// no index asked; ← or ⌫ on an empty search goes up a folder. The rows are file rows like the Files view's, so Cmd+K,
/// Return, ⌘Return and Quick Look act on them as there.
public enum FolderBrowse {
    /// The most rows one read lists; the names are filtered first, so a big folder is not read item by item.
    public static let cap = 200

    /// The folder a typed path names and the start of the name after its last `/`: `~/code/pi` is `<home>/code` and
    /// `pi`, `~/code/` is `<home>/code` and nothing; nil for a search that is not a path (`~` alone is home, `~sven` is not).
    public static func typed(_ query: String, home: String) -> (folder: String, stem: String)? {
        guard query.hasPrefix("/") || query == "~" || query.hasPrefix("~/"), !query.contains("\n") else { return nil }
        let typed = query == "~" ? "~/" : query
        guard let cut = typed.lastIndex(of: "/") else { return nil }
        let lead = String(typed[...cut]), stem = String(typed[typed.index(after: cut)...])
        return (standard(lead.hasPrefix("~") ? home + lead.dropFirst() : lead), stem)
    }

    /// `folder`'s items whose names start with `stem`, then those holding it, each by name as Finder sorts; hidden ones
    /// (a dot or Finder's flag) only when `stem` starts with a dot or `showHidden` (the Files view's ⌘⇧.). A folder row
    /// shows → as its key, since → opens it; a file its day edited, as the Files view's rows.
    public static func rows(in folder: String, matching stem: String = "", home: String, showHidden: Bool = false) -> [MenuEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let dotted = showHidden || stem.hasPrefix(".")
        let typed = Self.fold(stem)
        // Folded once each, sorted by name once; the names that start with `stem`, then those holding it.
        let shown = names.filter { dotted || !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, Self.fold($0)) }
        let ordered = typed.isEmpty ? shown.map(\.0)
            : shown.filter { $0.1.hasPrefix(typed) }.map(\.0) + shown.filter { !$0.1.hasPrefix(typed) && $0.1.contains(typed) }.map(\.0)
        let kept = Array(ordered.lazy.compactMap { name -> (path: String, folder: Bool, edited: Date?)? in
            let path = (folder as NSString).appendingPathComponent(name)
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey, .contentModificationDateKey])
            if !dotted, values?.isHidden == true { return nil }
            return (path, values?.isDirectory == true && values?.isPackage != true, values?.contentModificationDate)
        }.prefix(cap))
        // The Files view's rows; a folder's shows → as its key instead of a day.
        return zip(kept, MenuEntries.files(kept.map { (path: $0.path, edited: $0.edited) }, home: home)).map { item, row in
            guard item.folder else { return row }
            var row = row
            row.detail = "→"
            row.detailIsKey = true
            return row
        }
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// The folder above `path`; nil above `/`.
    public static func parent(of path: String) -> String? { path == "/" ? nil : (path as NSString).deletingLastPathComponent }

    /// `path` without `..`, `.` or a trailing `/` (but `/` itself), as the rows' paths are joined.
    public static func standard(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.isEmpty ? "/" : standard
    }
}
