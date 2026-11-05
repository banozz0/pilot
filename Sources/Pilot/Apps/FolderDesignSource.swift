import AppKit
import PilotCore

/// Pick a design (P43, frame 3): the menu's picker over the folders selected in Finder, titled with their count. Each
/// design is a row wearing its art; Return applies it to the folders it dresses, ⌘O asks for a picture of your own
/// instead. The kinds the folders are (T61: Downloads, Code…) come first, each its own section, then Pilot's twelve, then
/// every other kind; Your designs (P55) follow Pilot's, then Your own. A folder in a git repository is left out (Q294's recommendation) and a row under the designs says why;
/// ⌘I (or Return on that row) includes it, and again leaves it out.
@MainActor
final class FolderDesignSource: MenuSource {
    var show: ([MenuEntry]) -> Void = { _ in }
    let folders: [URL]
    /// The folders inside a git repository, and the ones of them Sven included.
    let inGit: [URL]
    private(set) var included: Set<URL> = []
    /// Your designs, each with Pilot's copy, read as the picker opens.
    let yours: [(design: FolderDesign, file: URL)]
    /// The kinds the folders are, whose designs list first.
    let suggested: [FolderDesign.Kind]

    /// `inGit` as read already (a render names its own); else each folder's parents are checked.
    init(_ folders: [URL], inGit: [URL]? = nil, yours: YourFolderDesigns = .standard, suggested: [FolderDesign.Kind]? = nil) {
        self.folders = folders
        self.suggested = suggested ?? FolderDesigns.kinds(of: folders)
        self.inGit = inGit ?? folders.filter { FolderLooks.gitRepository($0) != nil }
        self.yours = yours.list()
    }

    /// The folders Return dresses.
    var dressed: [URL] { folders.filter { !inGit.contains($0) || included.contains($0) } }

    static let ownKey = Extension.Item.Action.Key("cmd+o"), includeKey = Extension.Item.Action.Key("cmd+i")
    static let ownID = "folders.design:\(FolderDesign.own.id)", gitPrefix = "folders.git:"

    /// What ⌘I does to `folder` now.
    func toggleTitle(_ folder: URL) -> String { "\(included.contains(folder) ? "Leave out" : "Include") \(folder.lastPathComponent)" }

    func search(_ query: String) { show(rows()) }

    func rows() -> [MenuEntry] {
        let apply = "Apply to \(dressed.count)", own = "Your own picture…"
        let include = inGit.first.map(toggleTitle)
        // A design of yours wears its picture, read from Pilot's copy.
        func design(_ d: FolderDesign, icon: MenuIcon, section: String) -> MenuEntry {
            var row = MenuEntry(title: d.title, target: .action("folders.design:\(d.id)"), keywords: "folder design", icon: icon)
            row.ownActions = [apply, own] + (include.map { [$0] } ?? [])
            row.ownKeys = [nil, Self.ownKey] + (include == nil ? [] : [Self.includeKey])
            row.section = section
            return row
        }
        var mine = MenuEntry(title: FolderDesign.own.title, target: .action(Self.ownID), subtitle: "A PNG or SVG",
                             icon: .glyph("plus.rectangle.on.folder", .neutral))
        mine.ownActions = [own]
        mine.section = yours.isEmpty ? "Designs" : "Your designs"
        let warnings = inGit.map { folder -> MenuEntry in
            let name = folder.lastPathComponent, isIn = included.contains(folder)
            var row = MenuEntry(title: isIn ? "\(name) is a git repository, dressed anyway" : "\(name) is a git repository, so it is left out",
                                target: .action(Self.gitPrefix + folder.path),
                                subtitle: isIn ? "git will list its hidden Icon file as untracked" : "Its hidden Icon file would show as untracked",
                                icon: .glyph("exclamationmark.triangle", .amber))
            row.ownActions = [toggleTitle(folder)]
            row.ownKeys = [Self.includeKey]
            row.section = "Git repositories"
            return row
        }
        func pilot(_ designs: [FolderDesign], _ section: String) -> [MenuEntry] {
            designs.map { design($0, icon: MenuIcon(symbol: "folder", tint: .accent, bundled: "folder-designs/\($0.id)"), section: section) }
        }
        let others = FolderDesign.kinds.filter { !suggested.contains($0) }
        return suggested.flatMap { pilot($0.designs, "For \($0.title)") } + pilot(FolderDesign.classic, "Designs")
            + others.flatMap { pilot($0.designs, $0.title) }
            + yours.map { design($0.design, icon: MenuIcon(symbol: "folder", tint: .accent, picture: $0.file.path), section: "Your designs") }
            + [mine] + warnings
    }

    func pick(_ row: MenuEntry, action index: Int) -> MenuPick {
        guard case .action(let id) = row.target else { return .stay }
        // ⌘I on a design toggles the first git repository; a warning row, its own.
        let warned = id.hasPrefix(Self.gitPrefix) ? URL(filePath: String(id.dropFirst(Self.gitPrefix.count)), directoryHint: .isDirectory) : nil
        if warned != nil || row.ownKeys?.indices.contains(index) == true && row.ownKeys?[index] == Self.includeKey {
            return .keep(clear: false, back: false) { [self] in
                if let folder = warned ?? inGit.first { included.formSymmetricDifference([folder]) }
                show(rows())
                return nil
            }
        }
        let folders = dressed
        if id == Self.ownID || index == 1 {
            return .close { FolderDesigns.chooseOwn { url in Self.apply(.own(url), to: folders) } }
        }
        let picked = String(id.dropFirst("folders.design:".count))
        if let (design, file) = yours.first(where: { $0.design.id == picked }), !folders.isEmpty {
            return .close { Self.apply(.yours(design, file), to: folders) }
        }
        guard let design = FolderDesign.named(picked), !folders.isEmpty else { return .stay }
        return .close { Self.apply(.design(design), to: folders) }
    }

    static func apply(_ choice: FolderDesigns.Choice, to folders: [URL]) {
        Task { FolderDesigns.applied(await FolderDesigns.apply(choice, to: folders), choice) }
    }

    func close() {}
}
