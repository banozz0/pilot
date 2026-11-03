import AppKit
import Observation
import PilotCore

/// The Folder widget (P86, Sven Q730: "just as basic finder widget"): one folder, read-only, in Finder's columns. A
/// folder click goes into it inside the widget, back and up return; a file opens in its default app (a double-click in
/// the list, a click in Square and Strip), drags out to another app or Finder, and its menu opens it, opens it with,
/// shows it in Finder, copies its path or Quick Looks it. Nothing renames, moves, deletes or makes a folder (P85, 1.1).
/// It reads the shown folder as a placement shows and again when that folder changes, through one DispatchSource on it
/// alone (never its subfolders, never a clock), dropped when the placement hides.
@MainActor
enum WidgetFolder {
    nonisolated static let folderName = "folder", favouritesName = "favourites"

    /// Its widget.json, as Duplicate to edit writes it out.
    nonisolated static let manifest = """
        {"id": "pilot-folder", "title": "Folder", "icon": "📁", "version": "1.0",
         "description": "A folder, read-only: go into its folders, open, drag out or Quick Look its files. Pick the folder and favourites in Edit widget.",
         "draw": "blocks", "size": {"width": 660, "height": 340},
         "settings": [{"name": "folder", "label": "Folder", "type": "text", "default": "~/Downloads"},
                      {"name": "favourites", "label": "Favourites", "type": "text", "default": ""}]}
        """

    /// Each shown placement's model, by placement id: what its desktop right-click acts on.
    private static var shown: [String: WidgetFolderModel] = [:]

    /// A placement's loop while it shows: its model (kept on the tile, so a workspace switch keeps where it was, made
    /// again when Edit widget changes its folder or favourites), a read now, then one each time the folder changes or
    /// the widget goes elsewhere. The watch follows the shown folder and stops with the loop.
    static func feed(_ tile: WidgetTileModel, values: [String: JSONValue], placement id: String) async {
        let setting = Setting(values)
        let model = tile.folder.flatMap { $0.setting == setting ? $0 : nil } ?? WidgetFolderModel(setting)
        (tile.folder, tile.presses, tile.message) = (model, true, nil)
        shown[id] = model
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        model.changed = { changed.yield() }
        var watch: FolderChanges?
        defer { watch?.cancel(); model.changed = {}; if shown[id] === model { shown[id] = nil } }
        changed.yield()
        for await _ in changes {
            if Task.isCancelled { return }
            let folder = model.folder, sort = model.readSort, hidden = HiddenApps.shared.bundles
            if watch?.folder != folder || watch?.live != true {
                watch?.cancel()
                watch = FolderChanges(folder) { [weak model] gone in if gone { model?.lost() } else { changed.yield() } }
            }
            let read = await Task.detached(priority: .utility) { Result { try FolderListing.list(folder, sort: sort, hidden: hidden) } }.value
            if Task.isCancelled { return }
            // A read of a folder left meanwhile: the move already asked for the next one.
            if model.folder == folder, model.readSort == sort { model.take(read) }
        }
    }

    /// The Widgets page's preview: a fixed listing, so opening the page reads no folder of Sven's (Downloads asks macOS
    /// first) for a widget not placed yet.
    static func sample() -> WidgetFolderModel {
        let home = NSHomeDirectory(), now = Date()
        func item(_ name: String, _ folder: Bool, _ size: Int64?, _ ago: Double, _ kind: String, _ type: String?) -> FolderItem {
            FolderItem(url: URL(filePath: home + "/Downloads/" + name), name: name, isFolder: folder, size: size,
                       modified: now.addingTimeInterval(-ago * 3600), kind: kind, type: type)
        }
        let items = [
            item("Screenshots", true, nil, 2, "Folder", "public.folder"),
            item("Invoices", true, nil, 30, "Folder", "public.folder"),
            item("pilot-1.0.2.dmg", false, 9_600_000, 1, "Disk Image", "com.apple.disk-image-udif"),
            item("wallpaper.png", false, 4_200_000, 5, "PNG image", "public.png"),
            item("Ticket MLA–BCN.pdf", false, 315_800, 26, "PDF document", "com.adobe.pdf"),
            item("notes.md", false, 1_200, 50, "Markdown document", "net.daringfireball.markdown"),
            item("colors.toml", false, 1_200, 52, "TOML document", "public.plain-text"),
            item("demo.mov", false, 48_300_000, 75, "QuickTime movie", "com.apple.quicktime-movie"),
        ]
        let model = WidgetFolderModel(Setting(folder: "~/Downloads", favourites: [home + "/code", home + "/Pictures/Wallpapers"]))
        model.take(.success(.init(items: FolderListing.sorted(items, by: .name), count: items.count, free: 1_400_000_000_000)))
        return model
    }

    /// The file actions on top of a desktop placement's right-click menu: the item under the pointer, else the one last
    /// clicked; then the shown folder's Open as gallery (P90).
    static func sections(_ placement: String) -> [(title: String, items: [(title: String, run: () -> Void)])] {
        guard let model = shown[placement] else { return [] }
        let folder = model.folder
        let item = model.target.map { [($0.name, actions($0))] } ?? []
        return item + [(model.title, [("Open as gallery", { GalleryWindow.shared.open(folder) })])]
    }

    /// Open, Open with, Show in Finder, Copy path, Quick Look, and Open as gallery for a folder: a row's menu on Home and
    /// the desktop's, and the gallery's cards'.
    static func actions(_ item: FolderItem) -> [(title: String, run: () -> Void)] {
        let url = item.url
        let gallery: [(title: String, run: () -> Void)] = item.isFolder ? [("Open as gallery", { GalleryWindow.shared.open(url) })] : []
        return [("Open", { open(url) }), ("Open with…", { FileActions.openWith([url]) })] + gallery
            + [("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
               ("Copy path", { SystemModule.copy(url.path(percentEncoded: false), tip: "Copied the path") }),
               ("Quick Look", { FileActions.preview(url.path(percentEncoded: false)) })]
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// The setting a placement keeps: its folder, and its favourites one per line.
    struct Setting: Equatable {
        let folder: String, favourites: [String]

        init(folder: String, favourites: [String]) { self.folder = folder; self.favourites = favourites }

        init(_ values: [String: JSONValue]) {
            let folder = values[WidgetFolder.folderName]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.folder = folder.isEmpty ? "~/Downloads" : folder
            favourites = Self.lines(values[WidgetFolder.favouritesName]?.string ?? "")
        }

        static func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}

/// One placement's Folder widget: the folder it shows, where it came from, its sort and its last read.
@Observable @MainActor
final class WidgetFolderModel {
    /// A place in the sidebar: a title, its glyph and folder.
    struct Place: Identifiable, Hashable {
        let title: String, symbol: String, url: URL
        var id: String { url.path }
    }

    let setting: WidgetFolder.Setting
    let places: [Place]
    let favourites: [Place]
    private(set) var folder: URL
    private var history: [URL] = []
    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { folder.path(percentEncoded: false) != "/" }
    /// The sort a header click picks for the list.
    private(set) var sort: FolderListing.Sort = .name
    /// Square and Strip show the newest items, whatever the list's sort: set by the tile as its class changes.
    var newest = false { didSet { if oldValue != newest { changed() } } }
    var readSort: FolderListing.Sort { newest ? .modified : sort }
    private(set) var listing: FolderListing.Listing?
    /// Why the folder did not read: gone, or kept from Pilot by macOS.
    private(set) var problem: String?
    var selected: FolderItem.ID?
    var hovered: FolderItem?
    /// Wakes its feed: a move, a sort, a class that wants the newest.
    @ObservationIgnored var changed: () -> Void = {}

    init(_ setting: WidgetFolder.Setting, home: String = NSHomeDirectory()) {
        self.setting = setting
        folder = FolderListing.folder(setting.folder, home: home)
        places = [("Home", "house", ""), ("Downloads", "arrow.down.circle", "/Downloads"), ("Documents", "doc", "/Documents"),
                  ("Music", "music.note", "/Music"), ("Pictures", "photo", "/Pictures"), ("Videos", "film", "/Movies"),
                  ("Trash", "trash", "/.Trash")].map { Place(title: $0.0, symbol: $0.1, url: URL(filePath: home + $0.2, directoryHint: .isDirectory)) }
        favourites = setting.favourites.map { path in
            let url = FolderListing.folder(path, home: home)
            return Place(title: url.lastPathComponent.isEmpty ? path : url.lastPathComponent, symbol: "folder", url: url)
        }
    }

    /// The item a right-click acts on: the one under the pointer, else the one last clicked.
    var target: FolderItem? { hovered ?? listing?.items.first { $0.id == selected } }

    var title: String { folder.path(percentEncoded: false) == "/" ? "/" : folder.lastPathComponent }

    func go(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != folder else { return }
        history.append(folder)
        move(to: url)
    }

    func back() { if let last = history.popLast() { move(to: last) } }
    func up() { if canGoUp { go(folder.deletingLastPathComponent()) } }

    /// A header click: that sort.
    func sort(by sort: FolderListing.Sort) {
        guard sort != self.sort else { return }
        self.sort = sort
        changed()
    }

    /// The shown folder went away (deleted, renamed): up to the nearest one still there.
    func lost() {
        var url = folder
        while url.path(percentEncoded: false) != "/", !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { url = url.deletingLastPathComponent() }
        move(to: url)
    }

    /// Why a folder did not read, as the widget and the gallery say it.
    static func problem(_ error: any Error) -> String {
        let code = (error as NSError).code
        return code == NSFileReadNoPermissionError || code == NSFileReadUnknownError
            ? "Pilot may not read this folder: give it Full Disk Access in System Settings › Privacy & Security."
            : code == NSFileReadNoSuchFileError ? "This folder is gone." : error.localizedDescription
    }

    func take(_ read: Result<FolderListing.Listing, any Error>) {
        switch read {
        case .success(let listing): (self.listing, problem) = (listing, nil)
        case .failure(let error):
            listing = nil
            problem = Self.problem(error)
        }
        if let selected, listing?.items.contains(where: { $0.id == selected }) != true { self.selected = nil }
    }

    private func move(to url: URL) {
        folder = url
        (selected, hovered) = (nil, nil)
        changed()
    }
}

/// One DispatchSource on a folder's own entries (added, removed, renamed: a write to the folder), never its
/// subfolders. Bursts (a download writing) come together as one change a second; the folder itself deleted or renamed
/// says so at once.
@MainActor
final class FolderChanges {
    let folder: URL
    private let source: any DispatchSourceFileSystemObject
    private var waiting = false

    init?(_ folder: URL, changed: @escaping @MainActor (_ gone: Bool) -> Void) {
        let fd = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.folder = folder
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.source.data.isDisjoint(with: [.delete, .rename]) { self.source.cancel(); return changed(true) }
                guard !self.waiting else { return }
                self.waiting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.source.isCancelled else { return }
                        self.waiting = false
                        changed(false)
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    var live: Bool { !source.isCancelled }
    func cancel() { source.cancel() }
}
