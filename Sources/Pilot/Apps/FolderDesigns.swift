import AppKit
import OSLog
import PilotCore
import UniformTypeIdentifiers

let folderLog = Logger(subsystem: "dev.banozz.pilot", category: "folders")

/// Folder designs (P43): the art Pilot draws, a picture of your own fitted to a folder, the folders selected in Finder,
/// and applying or resetting a look on many folders at once, off the main thread, through FolderLooks. Files › Folders
/// and the menu's two Finder selection rows (Dress selected folders, Reset folder icons) both come here.
enum FolderDesigns {
    static let looks = FolderLooks()
    /// What to dress folders in: one of Pilot's designs, one of Your designs with Pilot's copy (P55), or a picture of your own.
    enum Choice: Equatable, Sendable {
        case design(FolderDesign)
        case yours(FolderDesign, URL)
        case own(URL)

        var design: FolderDesign {
            switch self {
            case .design(let d), .yours(let d, _): d
            case .own: .own
            }
        }
        var isOwn: Bool { design == .own }
    }

    // MARK: The kind of a folder (T61)

    /// Home folders by their path under home, then any folder by its name (lowercased), each to its kind's id
    /// (folder-designs-variants.build.md). /Applications is never matched: Pilot never dresses it.
    static let homeKinds = ["Applications": "applications", "Desktop": "desktop", "Documents": "documents", "Downloads": "downloads",
                            "Pictures": "pictures", "Pictures/Screenshots": "screenshots", "Movies": "movies", "Music": "music",
                            "Public": "public", "Public/Drop Box": "public", "Library/Mobile Documents/com~apple~CloudDocs": "icloud"]
    static let nameKinds: [String: String] = [
        "applications": "applications", "apps": "applications",
        "screenshots": "screenshots", "screen records": "screenshots", "screen recordings": "screenshots",
        "pictures": "pictures", "photos": "pictures", "pfp": "pictures",
        "movies": "movies", "videos": "movies", "music": "music", "drop box": "public",
        "dropbox": "icloud", "google drive": "icloud", "icloud drive": "icloud",
        "code": "code", "go": "code", "ghostex": "code", "developer": "code", "projects": "code",
        "hermes-vault": "notes", "pilot notes": "notes", "notes": "notes",
        "wallpapers": "design", "wallpaper": "design", "pages": "design", "assets": "design", "design": "design",
        "archive": "archive", "archives": "archive", "backups": "archive", "backup": "archive",
        "work": "work", "clients": "work", "invoices": "work", "taxes": "work",
        "models": "data", "data": "data",
    ]

    /// The kind `folder` is, for the designs it suggests first: a home folder by its place, any other by its name, then a
    /// folder in iCloud Drive or a synced cloud, an Obsidian vault, a git repository, or a folder holding apps (its first
    /// 200 entries). Reads the disk, so off the main thread where it can be.
    nonisolated static func kind(of folder: URL, home: URL = URL(filePath: NSHomeDirectory())) -> FolderDesign.Kind? {
        let path = folder.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        guard path != "/Applications" else { return nil }
        let under = path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : nil
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: folder.appending(path: name).path) }
        let id = under.flatMap { homeKinds[$0] } ?? nameKinds[folder.lastPathComponent.lowercased()]
            ?? (under.map { $0.hasPrefix("Library/Mobile Documents/") || $0.hasPrefix("Library/CloudStorage/") } == true ? "icloud" : nil)
            ?? (has(".obsidian") ? "notes" : has(".git") ? "code" : nil)
            ?? (fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants])?
                .prefix(200).contains { ($0 as? URL)?.pathExtension == "app" } == true ? "applications" : nil)
        return id.flatMap(FolderDesign.kind)
    }

    /// The kinds `folders` are, each once, in their order: the designs offered first.
    nonisolated static func kinds(of folders: [URL]) -> [FolderDesign.Kind] { distinct(folders.map { kind(of: $0) }) }

    /// `kinds` each once, in their order.
    nonisolated static func distinct(_ kinds: [FolderDesign.Kind?]) -> [FolderDesign.Kind] {
        kinds.compactMap(\.self).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// A design's art from the app's Resources, as a folder is dressed in it: the 1024 px cut-out (HEIC), and beside it the
    /// simpler 64 px drawing NSImage picks at 32 px and under, so a Finder list or sidebar shows the mark, not the papers
    /// (Scripts/folder-designs.py, P54). Read when used, never kept: the grid and menu draw the 256 px `<id>-preview.heic`.
    static func art(_ id: String) -> NSImage? {
        guard let image = BundledJSON.url(id, "heic", in: "folder-designs").flatMap(NSImage.init(contentsOf:)) else { return nil }
        if let small = BundledJSON.url("\(id)-small", "png", in: "folder-designs").flatMap(NSImageRep.init(contentsOf:)) {
            small.size = image.size
            image.addRepresentation(small)
        }
        return image
    }

    /// The icon `choice` sets: a design's art as it is; a picture of your own, or one of Your designs (P55), whole when
    /// it is cut out (transparent corners, already folder-shaped), else fitted inside the front of Pilot's plain folder.
    static func icon(_ choice: Choice) -> NSImage? {
        switch choice {
        case .design(let design): return art(design.id)
        case .yours(_, let url), .own(let url): return picture(url)
        }
    }

    /// A picture as a folder icon: whole when cut out, else fitted into the plain folder's front.
    static func picture(_ url: URL) -> NSImage? {
        guard let picture = NSImage(contentsOf: url), picture.size.width > 0, picture.size.height > 0 else { return nil }
        if cutOut(picture) { return picture }
        guard let plain = art(FolderDesign.plain) else { return nil }
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { rect in
            plain.draw(in: rect)
            // The plain folder's front in its 64 × 64 icon (x 4.5 to 59.5, y 23 to 55), less a margin.
            let unit = rect.width / 64, front = CGRect(x: 7 * unit, y: 26 * unit, width: 50 * unit, height: 25 * unit)
            let scale = min(front.width / picture.size.width, front.height / picture.size.height)
            let size = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            let place = CGRect(x: front.midX - size.width / 2, y: front.midY - size.height / 2, width: size.width, height: size.height)
            NSBezierPath(roundedRect: place, xRadius: 2 * unit, yRadius: 2 * unit).addClip()
            picture.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
    }

    /// One of Your designs as a menu row's icon (P55): drawn as it dresses a folder, kept small (about 20 KB) once read.
    /// The picker reads them off the main thread as it opens (`dynamic`); a row drawn before that reads its own.
    @MainActor static func rowIcon(_ path: String) -> NSImage? {
        if let kept = rowIcons[path] { return kept }
        guard let picture = picture(URL(filePath: path)) else { return nil }
        rowIcons[path] = AppsModule.small(picture)
        return rowIcons[path]
    }

    @MainActor private static var rowIcons: [String: NSImage] = [:]

    /// Your designs not drawn yet, each as it dresses a folder, by its copy's path; read off the main thread.
    nonisolated static func rowPictures(besides drawn: Set<String>) -> [(String, NSImage)] {
        YourFolderDesigns.standard.list().filter { !drawn.contains($0.file.path) }.compactMap { d in picture(d.file).map { (d.file.path, $0) } }
    }

    /// A picture whose four corners are see-through: cut out, as an icon is, rather than a photo.
    static func cutOut(_ picture: NSImage) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        picture.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return [(0, 0), (31, 0), (0, 31), (31, 31)].allSatisfy { (rep.colorAt(x: $0, y: $1)?.alphaComponent ?? 1) < 0.1 }
    }

    /// What one apply or reset did, as the HUD and the tab say it.
    struct Outcome {
        var done: [URL] = []
        /// Folders left as they were, each with why.
        var left: [(URL, String)] = []

        @MainActor func line(_ verb: String, _ tail: String = "") -> String {
            let head = done.isEmpty ? "No folders \(verb.lowercased())" : "\(verb) \(ExtensionsPageView.plural(done.count, "folder"))\(tail)"
            return ([head] + left.map { "\($0.0.lastPathComponent): \($0.1)" }).joined(separator: " · ")
        }
    }

    /// Dresses `folders` in `choice` off the main thread.
    static func apply(_ choice: Choice, to folders: [URL]) async -> Outcome {
        await each(folders, "\(choice.design.id) on", prepare: { icon(choice) }) { looks, image, folder, outcome in
            guard let image else { return outcome.left.append((folder, "the picture could not be read")) }
            do throws(FolderLooks.Failure) {
                try looks.apply(image, design: choice.design.id, to: folder)
                outcome.done.append(folder)
            } catch {
                outcome.left.append((folder, why(error)))
            }
        }
    }

    /// Takes back Pilot's icon on `folders` off the main thread; a folder Pilot did not dress is left without a word.
    static func reset(_ folders: [URL]) async -> Outcome {
        await each(folders, "reset", prepare: {}) { looks, _, folder, outcome in
            do throws(FolderLooks.Failure) {
                switch try looks.reset(folder) {
                case .reset: outcome.done.append(folder)
                case .changed: outcome.left.append((folder, "its icon changed since Pilot set it, so it stays"))
                case .notPilot: break
                }
            } catch {
                outcome.left.append((folder, why(error)))
            }
        }
    }

    /// Why a folder was left, as the HUD and the tab say it.
    private static func why(_ failure: FolderLooks.Failure) -> String {
        switch failure {
        case .systemFolder: "a system folder, which Pilot never dresses"
        case .notSaved: "what it had could not be kept, so it was left"
        case .notWritten: "macOS did not take the change; the folder is as it was"
        case .notRestored: "macOS took part of the change; Pilot keeps what it had, so Reset can try again"
        case .noBackup: "Pilot's copy of what it had is gone, so its icon stays"
        }
    }

    /// `body` on each folder in turn with what `prepare` made once (the icon), off the main thread, logged as `verb`.
    private static func each<Made>(_ folders: [URL], _ verb: String, prepare: @escaping @Sendable () -> Made,
                                   _ body: @escaping @Sendable (FolderLooks, Made, URL, inout Outcome) -> Void) async -> Outcome {
        let looks = looks
        return await Task.detached(priority: .userInitiated) {
            var outcome = Outcome()
            let made = prepare()
            for folder in folders { body(looks, made, folder, &outcome) }
            folderLog.notice("folders: \(verb, privacy: .public) \(outcome.done.count) of \(folders.count)")
            return outcome
        }.value
    }

    /// The HUD after an apply from the menu (frame 4).
    @MainActor static func applied(_ outcome: Outcome, _ choice: Choice) {
        HUD.tip(outcome.line("Dressed", " in \(choice.design.title)") + (outcome.done.isEmpty ? "" : " · Reset from the menu or Files › Folders"),
                seconds: outcome.left.isEmpty ? 3 : 6)
    }

    /// Asks for a picture of your own (PNG or SVG, or any picture Change icon takes), then hands it on; Pilot comes to
    /// the front for the panel.
    @MainActor static func chooseOwn(types: [UTType] = [.png, .svg],
                                     message: String = "A PNG or SVG: a cut-out picture is the whole icon, any other is fitted inside a folder's front.",
                                     then: @escaping @MainActor (URL) -> Void) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.message = message
        panel.prompt = "Use picture"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { then(url) }
        }
    }

    /// Asks for pictures or folders of them to add to Your designs (P55), then hands them on.
    @MainActor static func chooseDesigns(then: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = YourFolderDesigns.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Pictures (PNG, SVG, HEIC, JPEG, ICNS) or whole folders of them. Pilot keeps its own copies."
        panel.prompt = "Add designs"
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { then(panel.urls) }
        }
    }

    // MARK: The menu on Finder's selection

    /// The folders selected in Finder's front window (or on the desktop), read through Accessibility (FinderItems) as the
    /// menu's own menu item rows are, off the main thread; packages (an app, a library) are files to Finder, so left out.
    nonisolated static func finderSelection() -> [URL] { FinderItems.selection().filter(FolderLooks.isFolder) }

    static let dressID = "folders.dress", resetID = "folders.reset"

    /// Dress selected folders, and Reset folder icons when Pilot dressed any of them, while Finder is in front with folders
    /// selected (frame 2); typing finds them at the root. Off the main thread: a dressed folder's icon is read to tell.
    nonisolated static func rows(_ folders: [URL]) -> [MenuEntry] {
        guard !folders.isEmpty else { return [] }
        let dressed = folders.count { if case .pilot = looks.look(of: $0) { true } else { false } }
        let icon = MenuIcon.glyph("folder", .accent).app(bundle: DesktopIcons.finder)
        func row(_ title: String, _ id: String, _ detail: String, _ words: String) -> MenuEntry {
            MenuEntry(title: title, target: .action(id), detail: detail, keywords: words, ownKind: .selection, subtitle: "Finder selection", icon: icon)
        }
        let dress = row("Dress selected folders", dressID, "\(folders.count) folder\(folders.count == 1 ? "" : "s")",
                        "folder design icon artwork customise colour")
        return [dress] + (dressed == 0 ? [] : [row("Reset folder icons", resetID, "\(dressed) dressed", "folder design icon undo restore")])
    }

    /// The two rows' actions; not in the registry, so they never list without a Finder selection. Each reads Finder's
    /// selection again as it runs, Finder in front once more.
    @MainActor static func dynamic(_ id: String) -> Action? {
        guard id == dressID || id == resetID else { return nil }
        return Action(id: id, label: id == dressID ? "Dress selected folders" : "Reset folder icons", module: .apps) {
            Task {
                let drawn = Set(rowIcons.keys)
                let (folders, pictures, kinds) = await Task.detached {
                    let folders = finderSelection(), dress = id == dressID
                    return (folders, dress ? rowPictures(besides: drawn) : [], dress ? kinds(of: folders) : [])
                }.value
                for (path, picture) in pictures { rowIcons[path] = AppsModule.small(picture) }
                if id == dressID { pick(folders, suggested: kinds) } else { HUD.tip(await reset(folders).line("Reset")) }
            }
        }
    }

    /// Pick a design for `folders` in the menu (frame 3), the designs of the kinds they are first: read off the main
    /// thread when not handed in, since an unnamed folder's kind lists its entries.
    @MainActor static func pick(_ folders: [URL], suggested: [FolderDesign.Kind]? = nil) {
        guard !folders.isEmpty else { return HUD.tip("Select folders in Finder first") }
        guard let suggested else {
            Task { pick(folders, suggested: await Task.detached { kinds(of: folders) }.value) }
            return
        }
        PilotMenu.shared.pick(live: ExtensionsPageView.plural(folders.count, "folder"),
                              source: FolderDesignSource(folders, suggested: suggested))
    }
}
