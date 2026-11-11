import AppKit
import Observation
import OSLog
import PilotCore
import PilotTiler
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Pilot Files (P85, spec pilot-1.1 T10, T11): a file browser in windows of its own, like Finder (Q772), in T5's
/// pick B (Q784): the sidebar (Places, Favourites, Devices), the folder as a list or a grid, and an inspector that never
/// closes. A folder opens in place, a file opens through NSWorkspace, Space Quick Looks it, search asks the pilot-files
/// index inside the shown folder. Hidden apps (Install › Hidden apps) never show, in the listing or in a search.
/// The file actions (T11: rename, Trash, copy, move, new folder, undo; T55: new file from a template, cut and paste) each
/// go through T6's FileOps in `FilesModel.run`; every refusal it gives shows in the window. Confirmed permanent Bin
/// deletion uses TrashDeletion separately and cannot be undone. T55 adds the
/// typed path bar (a click or Cmd+L, with folder completion), Copy path in three forms, and folder sizes in list view.
/// Each window keeps one folder watch, its thumbnails and its folder sizes, and all go with its close: nothing runs while
/// no window is open.
@MainActor
final class FilesWindows {
    static let shared = FilesWindows()

    private struct Open {
        let window: PilotWindow
        let model: FilesModel
        let observers: [NSObjectProtocol]
    }

    private var open: [Open] = []

    static let size = NSSize(width: 1180, height: 720), minSize = NSSize(width: 820, height: 440)
    private static let frameName = "PilotFilesWindow"

    /// The open action: the last Pilot Files window forward, else a new one on Downloads.
    func show() {
        guard let last = open.last else { return newWindow() }
        bring(last.window)
    }

    /// Hyper+F puts the active browser away; the next press restores its folder and selection.
    func toggle() {
        guard let last = open.first(where: { $0.window.isKeyWindow }) ?? open.last else { return newWindow() }
        if NSApp.isActive, last.window.isKeyWindow, !last.window.isMiniaturized {
            last.window.miniaturize(nil)
        } else {
            bring(last.window)
        }
    }

    /// Cmd+N: another window, on `folder` (the shown one) or Downloads, a step down and right of the last.
    func newWindow(_ folder: URL? = nil) {
        let model = FilesModel(folder: folder ?? FilesModel.start)
        model.newWindow = { [weak self] in self?.newWindow($0) }
        let host = NSHostingView(rootView: FilesView(model: model).styled(.window).pilotTheme().pilotWindowStyles())
        let w = AppWindowController.makeWindow(content: host, size: Self.size, minSize: Self.minSize)
        TilerOwnWindows.floatByDefault(w)
        w.title = "Pilot Files"
        // Cmd+K's picker opens at the picked row's left, a little in, else at the content's top left.
        model.screenPoint = { [weak w] frame in
            guard let w, let content = w.contentView else { return nil }
            let at = frame.map { CGPoint(x: $0.minX + 24, y: $0.maxY) } ?? CGPoint(x: FilesView.sidebarWidth + 24, y: 100)
            return w.convertPoint(toScreen: CGPoint(x: at.x, y: content.bounds.height - at.y))
        }
        let app = AppWindowController.shared
        w.onQuit = { app.quit() }
        if let last = open.last?.window {
            w.setFrame(last.frame.offsetBy(dx: 28, dy: -28), display: false)
        } else if !w.setFrameUsingName(Self.frameName) {
            w.center()
        }
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(w) }
            },
            // The undo journal is shared with `pilot files undo` and the other windows, and the disks fill and empty
            // outside Pilot: read the next undo and the devices' space again on focus.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self, weak w, weak model] _ in
                MainActor.assumeIsolated {
                    if let self, let w, let index = self.open.firstIndex(where: { $0.window === w }) {
                        self.open.append(self.open.remove(at: index))
                    }
                    model?.refreshUndo()
                    model?.readSidebar()
                    model?.refreshIcons()
                    // A copy made in another app since Cmd+X drops the mark, so nothing shows dimmed for nothing.
                    FilesCut.shared.dropIfStale()
                }
            },
        ] + [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification].map { name in
            center.addObserver(forName: name, object: name == NSWindow.didResignKeyNotification ? w : nil, queue: .main) { [weak self, weak w] _ in
                // The next key window is assigned after resign-key; let sheets and Pilot's pickers take it first.
                DispatchQueue.main.async { if let w { self?.minimiseIfInactive(w) } }
            }
        }
        open.append(Open(window: w, model: model, observers: observers))
        app.applyDockIcon(.dock)
        followLook()
        model.start()
        bring(w)
        filesLog.notice("pilot files: window opened on \(model.folder.lastPathComponent, privacy: .private), \(self.open.count) open")
    }

    private func bring(_ w: PilotWindow) {
        let shown = w.isVisible && !w.isMiniaturized
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        if !shown { TilerOwnWindows.shown() }
        WindowFocus.bringForward()
    }

    private func minimiseIfInactive(_ w: PilotWindow) {
        guard let entry = open.first(where: { $0.window === w }), w.isVisible, !w.isMiniaturized,
              w.attachedSheet == nil, entry.model.prompt == nil else { return }
        if NSApp.isActive {
            guard !w.isKeyWindow, !(NSApp.keyWindow is NSPanel),
                  !open.contains(where: { $0.window === NSApp.keyWindow }) else { return }
        }
        w.miniaturize(nil)
    }

    /// Restyles every open window as the theme, style or material changes; one watch while any is open.
    private func followLook() {
        guard !open.isEmpty else { return }
        open.forEach { AppWindowController.applyLook(.shared, to: $0.window) }
        guard !followingLook else { return }
        followingLook = true
        withObservationTracking { _ = (Look.shared.layers, Look.shared.style, Look.shared.theme, Look.shared.glassBlur) } onChange: { [weak self] in
            Task { @MainActor in
                self?.followingLook = false
                self?.followLook()
            }
        }
    }
    private var followingLook = false

    /// A window closed: its frame is kept for the next first window, its watch, reads and thumbnails stop, and its tree
    /// goes on the run loop's next pass.
    private func closed(_ w: PilotWindow) {
        guard let i = open.firstIndex(where: { $0.window === w }) else { return }
        let closing = open.remove(at: i)
        closing.observers.forEach(NotificationCenter.default.removeObserver)
        w.saveFrame(usingName: Self.frameName)
        closing.model.close()
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { w.contentView = nil } }
        filesLog.notice("pilot files: window closed, \(self.open.count) open")
    }
}

private let filesLog = Logger(subsystem: "dev.banozz.pilot", category: "files")

/// Cmd+X's mark, one for every Pilot Files window: the items cut, each by its path and its identity (device and inode),
/// dimmed wherever they show, put on the clipboard as files too. The next Cmd+V in any window moves them, while the
/// clipboard still holds what Cmd+X put there and only while each path still holds the very item cut: one renamed or
/// replaced since is refused, nothing moves, and the mark goes (`take`). Anything copied since (here or in another app)
/// drops the mark, and that Cmd+V pastes a copy as it always did.
@Observable @MainActor
final class FilesCut {
    static let shared = FilesCut()

    private(set) var urls: [URL] = []
    var paths: Set<String> { Set(urls.map(\.path)) }
    @ObservationIgnored private var change = -1
    /// The clipboard Pilot Files copies, cuts and pastes through: the Mac's; a test hands in one of its own.
    @ObservationIgnored var board = NSPasteboard.general

    @ObservationIgnored private var ids: [FileOps.Identity] = []

    /// Marks `items`, or answers the name of one that is gone.
    func mark(_ items: [URL]) -> String? {
        let found = items.compactMap(FileOps.identity(of:))
        guard found.count == items.count else { return items.first { FileOps.identity(of: $0) == nil }?.lastPathComponent }
        board.clearContents()
        board.writeObjects(items as [NSURL])
        (urls, ids, change) = (items, found, board.changeCount)
        return nil
    }

    /// What Cmd+V does with the mark.
    enum Take: Equatable {
        /// No mark, or the clipboard changed since: paste as always.
        case none
        /// Move these, the very items cut (`ids`); the plan is checked against them before it runs.
        case move([URL], ids: [FileOps.Identity])
        /// This one was renamed or replaced since Cmd+X: nothing moves. The mark goes, and so do the file names Cmd+X put
        /// on the clipboard, so no later paste copies whatever took that name.
        case changed(String)
    }

    func take() -> Take {
        guard !urls.isEmpty else { return .none }
        guard board.changeCount == change else { clear(); return .none }
        if let gone = zip(urls, ids).first(where: { FileOps.identity(of: $0.0) != $0.1 }) {
            board.clearContents()
            clear()
            return .changed(gone.0.lastPathComponent)
        }
        return .move(urls, ids: ids)
    }

    /// On focus: a clipboard changed elsewhere drops the mark, so nothing shows dimmed for nothing.
    func dropIfStale() { if !urls.isEmpty, board.changeCount != change { clear() } }

    func clear() { if !urls.isEmpty { (urls, ids) = ([], []) } }
}

/// A New file row: Text and Markdown (empty), then each file in Pilot's Templates folder, copied.
struct FileTemplate: Identifiable, Hashable, Sendable {
    let title: String, name: String, url: URL?
    var id: String { url?.path ?? name }

    static let builtIn = [FileTemplate(title: "Text file", name: "untitled.txt", url: nil),
                          FileTemplate(title: "Markdown file", name: "untitled.md", url: nil)]

    /// `~/Library/Application Support/Pilot/Templates/`: any file Sven puts there is a New file row.
    static var folder: URL { PilotFolder.support.appending(path: "Templates", directoryHint: .isDirectory) }

    /// The templates folder's plain files, by name, hidden ones left out; none when it is missing.
    nonisolated static func read(_ folder: URL) -> [FileTemplate] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Plain files only, no link, folder or package, at most FileOps.templateLimit: what New file can copy.
        return urls.filter(FileOps.isTemplate).map { FileTemplate(title: $0.lastPathComponent, name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// One Pilot Files window's state: the folder, its history both ways, the listing or a search's hits, the selection,
/// the sidebar's places and devices, and the thumbnails made while it is open.
@Observable @MainActor
final class FilesModel {
    enum Mode: String, Sendable { case list, grid }

    /// A sidebar row: a place or a favourite.
    struct Place: Identifiable, Hashable, Sendable {
        let title: String, symbol: String, url: URL
        var id: String { url.path }
    }

    /// A mounted volume: its name, glyph, available and whole bytes.
    struct Device: Identifiable, Hashable, Sendable {
        let name: String, symbol: String, url: URL
        var free: Int64?
        let total: Int64?
        var ejectable = false
        var id: String { url.path }
        /// The share in use, for the 3 pt bar.
        var used: Double? {
            guard let free, let total, total > 0 else { return nil }
            return min(1, max(0, Double(total - free) / Double(total)))
        }
    }

    /// What a window reads besides the folder; tests pass fixed ones so a render reads nothing of the Mac's.
    struct Sources {
        /// Hidden apps' bundle ids (HiddenApps).
        var hidden: @MainActor () -> Set<String>
        /// The menu's favourites (FavouriteBook rows); the folders among them are the sidebar's Favourites.
        var favourites: @MainActor () -> Set<String>
        var devices: @Sendable () -> [Device]
        /// The pilot-files index; nil in the reply when Pilot lacks Full Disk Access.
        var search: @MainActor (FileSearch.Ask, @escaping ([FileSearch.Hit]?) -> Void) -> Void
        /// A file's QuickLook thumbnail (images, video, documents); nil where QuickLook draws none.
        var make: FileThumbnails.Make
        /// A file's own icon as Finder shows it (a folder's colour, a custom icon, an app's).
        var icon: FileThumbnails.Make = FilesModel.workspaceIcon

        static let live = Sources(
            hidden: { HiddenApps.shared.bundles },
            favourites: { FavouriteBook.shared.rows },
            devices: { FilesModel.mountedDevices() },
            search: { FileIndex.shared.search($0, reply: $1) },
            make: FileThumbnails.quickLook)
    }

    static var start: URL { URL(filePath: NSHomeDirectory() + "/Downloads", directoryHint: .isDirectory) }

    private(set) var folder: URL
    private var backList: [URL] = []
    private var forwardList: [URL] = []
    var canGoBack: Bool { !backList.isEmpty }
    var canGoForward: Bool { !forwardList.isEmpty }
    var canGoUp: Bool { folder.path(percentEncoded: false) != "/" }

    /// The shown folder's last read: its items (at most FolderListing.cap), how many it holds, its volume's free bytes.
    private(set) var listing: FolderListing.Listing?
    /// Why the folder did not read.
    private(set) var problem: String?
    var items: [FolderItem] { listing?.items ?? [] }
    var count: Int { listing?.count ?? 0 }
    var free: Int64? { listing?.free }
    /// The shown folder has read once, so an empty listing is an empty folder.
    var loaded: Bool { listing != nil || problem != nil }
    /// Folder sizes are worked out in list view only.
    var mode: Mode = .list { didSet { if mode != oldValue { mode == .list ? sizeFolders() : stopSizing() } } }
    /// Cmd+Shift+.: hidden files list too, as in Finder; Hidden apps' apps never do.
    var showHidden = false { didSet { if showHidden != oldValue { reload() } } }
    /// A header click: a folder read whole sorts in memory, a capped one reads again for the sort's first items.
    var sort: FolderListing.Sort = .name {
        didSet {
            guard sort != oldValue else { return }
            if let listing, listing.count <= listing.items.count { resort() } else { reload() }
        }
    }
    /// What a folder's size is, worked out in list view: bytes, or nil where it is protected or does not read whole
    /// ("—"). By item id, kept while the window is open and asked again when the folder's own date changes.
    struct FolderSize: Equatable { let modified: Date?, bytes: Int64? }
    private(set) var folderSizes: [String: FolderSize] = [:]
    /// Folder sizes are being worked out for the shown folder.
    var sizingFolders: Bool { sizing != nil }
    var knownSizes: [String: Int64] { folderSizes.compactMapValues(\.bytes) }

    /// The editable path field (a click on the folder's name, or Cmd+L), above the persistent bottom path.
    var editingPath = false
    /// New file's rows: Text, Markdown, then Pilot's Templates folder's files, read again on focus.
    private(set) var templates = FileTemplate.builtIn

    /// The group and its active item: previews and rename still have one subject.
    private(set) var selectedIDs: Set<FolderItem.ID> = []
    private var active: FolderItem.ID?
    private var anchor: FolderItem.ID?
    var selected: FolderItem.ID? {
        get { active }
        set { pick(Set(newValue.map { [$0] } ?? []), active: newValue); anchor = newValue }
    }

    private func pick(_ ids: Set<FolderItem.ID>, active: FolderItem.ID?) {
        selectedIDs = ids
        self.active = active
        if renaming != nil, renaming != active { renaming = nil }
    }

    func select(_ item: FolderItem, modifiers: NSEvent.ModifierFlags = []) {
        if modifiers.contains(.shift), let anchor,
           let start = shown.firstIndex(where: { $0.id == anchor }), let end = shown.firstIndex(where: { $0.id == item.id }) {
            let range = Set(shown[min(start, end)...max(start, end)].map(\.id))
            pick(modifiers.contains(.command) ? selectedIDs.union(range) : range, active: item.id)
        } else if modifiers.contains(.command) {
            var ids = selectedIDs
            if !ids.insert(item.id).inserted { ids.remove(item.id) }
            pick(ids, active: ids.contains(item.id) ? item.id : shown.last(where: { ids.contains($0.id) })?.id)
            anchor = active
        } else {
            selected = item.id
        }
    }

    func selectAll() {
        pick(Set(shown.map(\.id)), active: selected ?? shown.first?.id)
        anchor = active
    }

    private func pruneSelection() {
        let ids = selectedIDs.intersection(shown.map(\.id))
        pick(ids, active: active.flatMap { ids.contains($0) ? $0 : nil } ?? shown.first(where: { ids.contains($0.id) })?.id)
        if let anchor, !ids.contains(anchor) { self.anchor = active }
    }

    /// The search field shows; its words search the shown folder and everything under it.
    var searching = false { didSet { if !searching { query = ""; searchFocused = false } } }
    /// The search field has the keys: Cmd+K, I, O, Down and Up are the field's then, not the window's.
    var searchFocused = false
    var query = "" { didSet { if query != oldValue { search() } } }
    /// A search's hits; nil while no words are typed.
    private(set) var hits: [FolderItem]?
    /// Said under the bar when a search could only filter this folder's names.
    private(set) var searchNote: String?

    let places: [Place]
    private(set) var favourites: [Place] = []
    private(set) var devices: [Device] = []

    /// What the window says under the folder after a file action: what was done, or FileOps' refusal in its own words
    /// (`say`).
    struct Notice: Equatable {
        let text: String
        let problem: Bool
        /// A copy or a move refused for a name already there: Keep both or Replace runs it again with that answer.
        var clash: FileOps.Request?
        /// The identities that request must still move (a cut's), checked again when it runs with the answer.
        var expect: [FileOps.Identity]?

        static func done(_ text: String) -> Notice { Notice(text: text, problem: false) }
        static func refused(_ text: String, clash: FileOps.Request? = nil, expect: [FileOps.Identity]? = nil) -> Notice {
            Notice(text: text, problem: true, clash: clash, expect: expect)
        }
    }
    private(set) var notice: Notice?
    enum Prompt {
        case rename(URL), delete(TrashDeletion.Plan)
        var title: String {
            switch self { case .rename: "Rename Folder"; case .delete: "Delete Permanently?" }
        }
        var message: String {
            switch self {
            case let .rename(url): "Rename \(url.lastPathComponent) on disk."
            case let .delete(plan): "Permanently delete \(plan.name) from the Bin? This cannot be undone."
            }
        }
    }
    var prompt: Prompt?
    var newName = ""
    /// The operation Cmd+Z puts back next, as FileOps' journal says (shared with `pilot files undo`), or nil.
    private(set) var nextUndo: String?
    /// The item whose name is being edited in place.
    var renaming: FolderItem.ID?
    /// File actions still running.
    private(set) var working = 0
    /// Bumped each time a notice is said, so an action finishing late knows another spoke since it was pressed (`say`).
    @ObservationIgnored private var said = 0

    /// Pilot Files' one writer: the shared journal, so Cmd+Z and `pilot files undo` put back the same operations.
    @ObservationIgnored var ops = FileOps.shared
    @ObservationIgnored var templateFolder = FileTemplate.folder
    private var sizing: Task<Void, Never>?
    /// The folders the running walk sizes, so a watch event asking for the same ones lets it finish.
    @ObservationIgnored private var sizingIDs: Set<String> = []
    /// The running walk's number: what a stopped walk delivers late is dropped (`sized`).
    @ObservationIgnored private var sizingRun = 0
    @ObservationIgnored private let home: String
    @ObservationIgnored private var draggedURLs: [URL] = []
    @ObservationIgnored var newWindow: (URL) -> Void = { _ in }
    /// A point in the window's content (top left origin) on screen, for Cmd+K's picker; nil while no window shows.
    @ObservationIgnored var screenPoint: (CGRect?) -> CGPoint? = { _ in nil }
    /// Where the picked row or tile sits in the window's content, as it last drew.
    @ObservationIgnored var pickedFrame: CGRect?
    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private var changes: FolderChanges?
    @ObservationIgnored private var writing = 0
    @ObservationIgnored private var pendingLoss = false
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var asking: Task<Void, Never>?
    /// The latest search's number: a reply to an older one is dropped.
    @ObservationIgnored private var asked = 0
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let pictures: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = FilesModel.pictureBytes
        return cache
    }()
    @ObservationIgnored private var pending: [String: Task<NSImage?, Never>] = [:]
    /// Bumped when Cmd+K changed an icon, so every icon is drawn again: an icon set inside a folder fires no watch.
    private(set) var iconEpoch = 0
    @ObservationIgnored private var iconsChanged = false
    /// Pictures QuickLook made none of: not asked again while the window is open (a grid scrolled back and forth).
    @ObservationIgnored private var none: Set<String> = []

    static let pictureBytes = 64 << 20
    /// The most hits a search shows.
    static let hitCap = 500

    init(folder: URL, home: String = NSHomeDirectory(), sources: Sources = .live) {
        self.folder = folder.standardizedFileURL
        self.sources = sources
        self.home = home
        places = [("Home", "house", home), ("Desktop", "menubar.dock.rectangle", home + "/Desktop"),
                  ("Downloads", "arrow.down.circle", home + "/Downloads"), ("Documents", "doc", home + "/Documents"),
                  ("Pictures", "photo", home + "/Pictures"), ("Movies", "film", home + "/Movies"), ("Music", "music.note", home + "/Music"),
                  ("Applications", "square.grid.2x2", "/Applications"), ("Trash", "trash", home + "/.Trash")]
            .map { Place(title: $0.0, symbol: $0.1, url: URL(filePath: $0.2, directoryHint: .isDirectory)) }
    }

    var title: String { folder.path(percentEncoded: false) == "/" ? "/" : folder.lastPathComponent }
    /// What the list or grid shows: a search's hits, else the folder's items.
    var shown: [FolderItem] { hits ?? items }
    var selection: FolderItem? { selected.flatMap { id in shown.first { $0.id == id } } }
    var selections: [FolderItem] { shown.filter { selectedIDs.contains($0.id) } }
    /// A context action on an unselected item acts on that item; within the group it keeps the group.
    func selections(for item: FolderItem?) -> [FolderItem] {
        if let item, !selectedIDs.contains(item.id) { return [item] }
        return selections
    }

    /// The drag owns its URLs even after spring navigation clears this folder's selection.
    func drag(_ ids: [String]) -> [URL] {
        let urls = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0.url) })
        draggedURLs = ids.compactMap { urls[$0] }
        return draggedURLs
    }

    func endDrag() { draggedURLs = [] }

    func canSpring(into url: URL) -> Bool {
        url != folder && !Self.inTrash(url) && !draggedURLs.contains {
            url.path == $0.path || url.path.hasPrefix($0.path + "/")
        }
    }

    var pathFolders: [Place] {
        var urls = [folder]
        while let first = urls.first, first.path != "/" { urls.insert(first.deletingLastPathComponent(), at: 0) }
        return urls.map { url in
            let place = places.first { $0.url == url }
            let device = devices.first { $0.url == url }
            let symbol = device?.symbol ?? place?.symbol ?? (url.path == "/Users" ? "person.2" : "folder")
            return Place(title: device?.name ?? (url.path == "/" ? "/" : url.lastPathComponent), symbol: symbol, url: url)
        }
    }
    /// The selection, else the shown folder as an item of its own: what the inspector shows and Cmd+K acts on.
    var subject: FolderItem {
        selection ?? FolderItem(url: folder, name: title, isFolder: true, size: nil, modified: nil, kind: "Folder", type: "public.folder")
    }

    /// The window opened: the folder, the sidebar's favourites and devices, and a watch on mounts while it is open.
    func start() {
        move(to: folder)
        readSidebar()
        refreshUndo()
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.readSidebar() } }
        }
    }

    // MARK: Moving

    func go(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != folder else { return }
        backList.append(folder)
        forwardList = []
        move(to: url)
    }

    func back() {
        guard let last = backList.popLast() else { return }
        forwardList.append(folder)
        move(to: last)
    }

    func forward() {
        guard let next = forwardList.popLast() else { return }
        backList.append(folder)
        move(to: next)
    }

    func up() { if canGoUp { go(folder.deletingLastPathComponent()) } }

    private func move(to url: URL) {
        folder = url
        selected = nil
        renaming = nil
        searching = false
        // What was done stays only where it was done; a refusal stays until it is closed.
        if notice?.problem == false { notice = nil }
        (listing, problem) = (nil, nil)
        editingPath = false
        stopSizing()
        reload()
        watch()
    }

    /// Reads the folder's own level off the main thread, Hidden apps' bundles left out. The listing's space is the
    /// shown volume's device's too: the toolbar, the status bar and the sidebar say one figure (Sven, 2026-11-04).
    func reload() {
        reading?.cancel()
        let folder = folder, sort = sort, hidden = sources.hidden(), showHidden = showHidden
        reading = Task {
            let (read, volume) = await Task.detached(priority: .userInitiated) {
                (Result { try FolderListing.list(folder, sort: sort, hidden: hidden, showHidden: showHidden) }, FilesModel.volumeURL(folder))
            }.value
            guard !Task.isCancelled, folder == self.folder else { return }
            switch read {
            // A change that left the listing as it was (a download's last write) redraws nothing.
            case .success(let listing):
                if listing != self.listing || problem != nil { (self.listing, problem) = (listing, nil) }
                if sort == .size { resort() }
                sizeFolders()
            case .failure(let error): (listing, problem) = (nil, WidgetFolderModel.problem(error))
            }
            if hits == nil { pruneSelection() }
            took(devices, volume: volume)
        }
    }

    /// `read`, the shown folder's volume carrying the listing's own figure.
    private func took(_ read: [Device], volume: URL?) {
        let made = read.map { device in
            var device = device
            if let free = listing?.free, device.url.standardizedFileURL == volume { device.free = free }
            return device
        }
        if made != devices { devices = made }
    }

    nonisolated private static func volumeURL(_ folder: URL) -> URL? {
        (try? folder.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL
    }

    /// One watch on the shown folder's own entries; the folder gone moves up to the nearest one still there.
    private func watch() {
        changes?.cancel()
        let watched = folder
        changes = FolderChanges(watched) { [weak self] gone in
            guard let self, self.folder == watched else { return }
            if gone {
                self.changes = nil
                if self.writing > 0 { self.pendingLoss = true } else { self.lost() }
            } else { self.reload() }
        }
    }

    private func lost() {
        var url = folder
        while url.path(percentEncoded: false) != "/", !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { url = url.deletingLastPathComponent() }
        move(to: url)
    }

    /// The favourites, the devices and the templates again: at open, on a mount and on focus.
    func readSidebar() {
        let devices = sources.devices, rows = sources.favourites(), folder = folder, templateFolder = templateFolder
        Task {
            let (favourites, devices, volume, templates) = await Task.detached(priority: .utility) {
                (FilesModel.favouriteFolders(rows).map { path in
                    let url = URL(filePath: path, directoryHint: .isDirectory)
                    return Place(title: url.lastPathComponent, symbol: "folder", url: url)
                }, devices(), FilesModel.volumeURL(folder), FileTemplate.read(templateFolder))
            }.value
            if favourites != self.favourites { self.favourites = favourites }
            if FileTemplate.builtIn + templates != self.templates { self.templates = FileTemplate.builtIn + templates }
            took(devices, volume: folder == self.folder ? volume : nil)
        }
    }

    /// The window closed: the watch, the reads, the folder sizes, the mount watch and every thumbnail go.
    func close() {
        reading?.cancel()
        stopSizing()
        folderSizes = [:]
        asking?.cancel()
        changes?.cancel()
        changes = nil
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        volumeObservers = []
        pending.values.forEach { $0.cancel() }
        pending = [:]
        none = []
        pictures.removeAllObjects()
    }

    // MARK: Opening

    /// A double-click or Open: a folder opens here, anything else in its own app.
    func open(_ item: FolderItem) {
        if item.isFolder { go(item.url) } else { NSWorkspace.shared.open(item.url) }
    }

    /// A group opens every folder visibly; a single folder keeps navigating this window.
    func open(_ items: [FolderItem]) {
        for item in items {
            if items.count > 1, item.isFolder { newWindow(item.url) } else { open(item) }
        }
    }

    /// The Folder widget's read-only file actions, its Open opening a folder here rather than in Finder; its Copy path
    /// leaves for the window's three forms (FilesCopyPathMenu).
    func actions(_ item: FolderItem) -> [(title: String, run: () -> Void)] {
        WidgetFolder.actions(item).filter { $0.title != "Copy path" }
            .map { $0.title == "Open" ? ("Open", { [weak self] in self?.open(item) }) : $0 }
    }

    /// Space and Quick Look: the item in Quick Look, or the panel closed when it shows.
    func quickLook(_ item: FolderItem) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible { return panel.orderOut(nil) }
        FileActions.preview(item.url.path(percentEncoded: false))
    }

    /// Cmd+I: Pilot's Show preview window, the file and its facts (Finder's Get Info would need Finder's automation).
    func info() { if let selection { FilePreviewWindow.open(selection.url) } }

    /// Cmd+K: the picked item's file actions, the list Hyper + right-click gives, at the picked row; the shown folder's
    /// when nothing is picked, less Move to Trash (the folder shown is the window's own). Move to Trash goes through
    /// FileOps (Cmd+Z puts it back) and Open opens a folder here.
    func showActions() {
        let item = subject
        guard let at = screenPoint(selection == nil ? nil : pickedFrame) else { return }
        let picked = selections.isEmpty ? [item] : selections
        FileActionsMenu.show(picked.map(\.url), at: at, except: selection == nil ? [.trash] : []) { [weak self] action in
            guard let self else { return false }
            switch action {
            case .changeIcon, .resetIcon, .folderDesign: iconsChanged = true; return false
            case .open: open(picked)
            case .trash: trash(picked)
            case .copyPath: pickPathForm(picked.map(\.url))
            default: return false
            }
            return true
        }
    }

    /// Cmd+K's Copy path: a picker of its three forms, each row showing what it copies.
    private func pickPathForm(_ urls: [URL]) {
        let forms = FolderListing.PathForm.allCases
        let rows = forms.map { form in
            MenuEntry(title: form.title, target: .action("files.path." + form.rawValue), subtitle: urls.first.map { FolderListing.path($0, as: form, home: home) },
                      icon: .glyph("doc.on.doc", .accent))
        }
        PilotMenu.shared.pick(rows, title: "Copy path") { [weak self] row in
            guard case .action(let id) = row.target, let form = forms.first(where: { "files.path." + $0.rawValue == id }) else { return }
            self?.copyPaths(urls, as: form)
        }
    }

    /// Copy path: `url`'s path in `form` on the clipboard as text, said in the window.
    func copyPath(_ url: URL, as form: FolderListing.PathForm) {
        copyPaths([url], as: form)
    }

    func copyPaths(_ urls: [URL], as form: FolderListing.PathForm) {
        let text = urls.map { FolderListing.path($0, as: form, home: home) }.joined(separator: "\n")
        FilesCut.shared.clear()
        let board = FilesCut.shared.board
        board.clearContents()
        board.setString(text, forType: .string)
        say(.done(urls.count == 1 ? "Copied \(text)" : "Copied \(urls.count) paths."))
    }

    /// The arrow keys: the next or previous item, the first when none is picked.
    func step(_ by: Int) {
        let shown = shown
        guard !shown.isEmpty else { return }
        let at = selected.flatMap { id in shown.firstIndex { $0.id == id } }
        let next = at.map { min(shown.count - 1, max(0, $0 + by)) } ?? (by > 0 ? 0 : shown.count - 1)
        selected = shown[next].id
    }

    // MARK: File actions

    /// The one way the window changes a file: FileOps plans the request and runs that plan (the window's own press is
    /// the ask, so no Allow), off the main thread. What it did, or its refusal word for word (a clash, an undo that can't
    /// be asked, a volume with no Trash, a step dropped, another operation running), shows as the window's notice.
    /// While `working` is above 0 the status bar says an action is running.
    /// `expect`: the identities the plan's items must have (a cut's), else nothing runs.
    func run(_ request: FileOps.Request, expect: [FileOps.Identity]? = nil) {
        if let refusal = Self.trashRefusal(request) { return say(.refused(refusal)) }
        let ops = ops
        if notice?.problem == false { notice = nil }
        let pressed = said
        working += 1
        writing += 1
        Task {
            let outcome: Result<FileOps.Done, Error>
            do {
                let plan = try await ops.plan(request)
                if let expect, plan.sources != expect { throw CutChanged(request) }
                outcome = .success(try await ops.perform(plan))
            } catch { outcome = .failure(error) }
            nextUndo = await ops.nextUndo
            working -= 1
            switch outcome {
            case .success(let done): finished(request, done, pressed: pressed)
            case .failure(let changed as CutChanged): say(.refused(changed.message), pressed: pressed)
            case .failure(let failure as FileOps.Failure):
                let clash = failure.kind == .clash && Self.answering(request, .ask) != nil
                say(.refused(failure.message, clash: clash ? request : nil, expect: clash ? expect : nil), pressed: pressed)
                filesLog.notice("pilot files: refused: \(failure.message, privacy: .private)")
            case .failure(let error): say(.refused(error.localizedDescription), pressed: pressed)
            }
            writing -= 1
            if writing == 0, pendingLoss {
                pendingLoss = false
                if !FileManager.default.fileExists(atPath: folder.path) { lost() }
                else if changes == nil { watch() }
            }
        }
    }

    /// Shows `new`. Nothing said is lost to a later word: a refusal stays until it is closed (or its clash answered),
    /// and whatever comes after it is added to it; an action finishing late (`pressed`: what `said` was when it was
    /// pressed) is added after anything said since, so a slower action's "done" never hides a quicker one's word. A
    /// second question waits until the first is answered or closed.
    private func say(_ new: Notice, pressed: Int? = nil) {
        if let shown = notice, shown == new || (shown.text.hasSuffix(" " + new.text) && shown.clash == new.clash && shown.expect == new.expect) { return }
        if let shown = notice, shown.problem || (pressed != nil && pressed != said) {
            let stop = shown.text.hasSuffix(".") ? "" : "."
            let waiting = shown.clash != nil && new.clash != nil
            let added = waiting ? "\(new.text). Not asked yet: answer or close the first question, then do it again." : new.text
            // A clash keeps the identities its request must still move (a cut's), whichever question is kept.
            let (clash, expect) = shown.clash != nil ? (shown.clash, shown.expect) : (new.clash, new.expect)
            notice = Notice(text: "\(shown.text)\(stop) \(added)", problem: shown.problem || new.problem, clash: clash, expect: expect)
        } else {
            notice = new
        }
        said += 1
    }

    private func finished(_ request: FileOps.Request, _ done: FileOps.Done, pressed: Int) {
        // Rename/move changes paths in place, not navigation history, including undo and pinned descendants.
        func following(_ url: URL) -> URL {
            FileOps.relocated(url, by: done.moved)
        }
        backList = backList.map(following)
        forwardList = forwardList.map(following)
        let current = following(folder)
        if current != folder { move(to: current) }
        let next: String
        if case .undo = request { next = nextUndo.map { "Cmd+Z next: \($0)." } ?? "Nothing more to undo." } else { next = "Cmd+Z undoes it." }
        say(.done("\(done.title): done. \(next)"), pressed: pressed)
        if let problem = FavouriteBook.shared.relocate(done.moved) { say(.refused(problem)) }
        readSidebar()
        // The item made, moved or put back here is picked; a new folder's name opens for editing, as Finder's does.
        let madeHere = done.items.filter { $0.deletingLastPathComponent().path == folder.path }
        if let made = madeHere.first {
            pick(Set(madeHere.map(\.path)), active: made.path)
            anchor = made.path
            switch request {
            case .newFolder(_, nil), .newFile: renaming = made.path
            default: break
            }
        } else if case .trash = request {
            selected = nil
        }
        // The cut items moved: their mark goes.
        if case let .move(items, _, _) = request, items == FilesCut.shared.urls { FilesCut.shared.clear() }
        reload()
        if hits != nil { search() }
    }

    /// `request`, a copy or a move that asked on a clash, answered with `clash`; nil for any other request.
    private static func answering(_ request: FileOps.Request, _ clash: FileOps.Clash) -> FileOps.Request? {
        switch request {
        case let .copy(items, folder, .ask): .copy(items, into: folder, clash)
        case let .move(items, folder, .ask): .move(items, into: folder, clash)
        default: nil
        }
    }

    /// The clash's answer: the same copy or move again, keeping both or sending the one there to the Trash.
    func answer(_ clash: FileOps.Clash) {
        guard let request = notice?.clash.flatMap({ Self.answering($0, clash) }) else { return }
        let expect = notice?.expect
        notice = nil
        run(request, expect: expect)
    }

    /// A cut's items are not the ones Cmd+X marked: renamed or replaced since, so nothing moved.
    struct CutChanged: Error {
        let message: String
        init(_ request: FileOps.Request) {
            let name = if case let .move(items, _, _) = request { items.first?.lastPathComponent ?? "An item" } else { "An item" }
            message = Self.words(name)
        }
        static func words(_ name: String) -> String { "\(name) changed since Cmd+X (renamed or replaced); nothing was moved. Cut it again." }
    }

    func dismissNotice() { notice = nil }

    /// Reads the journal's next undo again: the pilot command or another window may have changed it.
    func refreshUndo() {
        let ops = ops
        Task { nextUndo = await ops.nextUndo }
    }

    /// Cmd+Z: the journal's last operation put back, as `pilot files undo` does.
    func undo() { run(.undo) }

    /// Return: the picked item's name opens for editing.
    func beginRename(_ item: FolderItem? = nil) {
        guard let item = item ?? selection else { return }
        selected = item.id
        renaming = item.id
    }

    /// The edited name, on Return; the same name changes nothing.
    func rename(_ item: FolderItem, to name: String) {
        renaming = nil
        guard name != item.name else { return }
        run(.rename(item.url, to: name))
    }

    /// Cmd+Backspace: the picked group to the Trash, or explicit permanent-deletion confirmation inside it.
    func trash(_ item: FolderItem? = nil) {
        trash(selections(for: item))
    }

    private func trash(_ picked: [FolderItem]) {
        guard !picked.isEmpty else { return }
        if picked.allSatisfy({ Self.inTrash($0.url.deletingLastPathComponent()) }) {
            return prepareDeletion(picked.map(\.url))
        }
        run(.trash(picked.map(\.url)))
    }

    func isFavourite(_ url: URL) -> Bool { sources.favourites().contains("file:" + url.path) }

    func toggleFavourite(_ url: URL) {
        if let problem = FavouriteBook.shared.set("file:" + url.path, !isFavourite(url)) { say(.refused(problem)) }
        readSidebar()
    }

    func canRenameFolder(_ url: URL) -> Bool {
        url.pathComponents.count > 2 && url.path != home && !Self.inTrash(url)
            && !places.contains { $0.url.path == url.path } && !devices.contains { $0.url.path == url.path }
    }

    func isBin(_ url: URL) -> Bool {
        url.path == home + "/.Trash" || (url.deletingLastPathComponent().lastPathComponent == ".Trashes" && url.lastPathComponent == String(geteuid()))
    }

    func askRenameFolder(_ url: URL) {
        guard canRenameFolder(url), prompt == nil, working == 0 else { return }
        newName = url.lastPathComponent
        prompt = .rename(url)
    }

    func changeFolderDesign(_ urls: [URL]) {
        iconsChanged = true
        FolderDesigns.pick(urls)
    }

    /// The Bin action snapshots system Trash roots off main; an explicit selection never widens to the whole Bin.
    func prepareDeletion(_ selected: [URL]? = nil) {
        guard working == 0, prompt == nil else { return }
        working += 1
        let home = home, volumes = devices.map(\.url)
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let roots = [URL(filePath: home + "/.Trash", directoryHint: .isDirectory)] + volumes.compactMap { volume -> URL? in
                        guard (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true else { return nil }
                        return try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volume, create: false)
                    }
                    return try TrashDeletion.plan(selected, roots: roots)
                }.value
                if plan.count == 0 { say(.done("The Bin is empty.")) }
                else { prompt = .delete(plan) }
            } catch { say(.refused(error.localizedDescription)) }
            working -= 1
        }
    }

    /// Confirmation consumes the saved plan; cancellation just clears prompt and never calls this method.
    func confirmPrompt(_ asked: Prompt) {
        prompt = nil
        switch asked {
        case let .rename(url):
            guard newName != url.lastPathComponent else { return }
            run(.rename(url, to: newName))
        case let .delete(plan):
            working += 1
            Task {
                do {
                    let count = try await Task.detached(priority: .userInitiated) { try TrashDeletion.perform(plan) }.value
                    say(.done("Deleted \(count) \(count == 1 ? "item" : "items") permanently. This cannot be undone."))
                } catch { say(.refused(error.localizedDescription)) }
                working -= 1
                reload()
                if hits != nil { search() }
            }
        }
    }

    func eject(_ url: URL) {
        guard working == 0 else { return }
        working += 1
        Task {
            do {
                let ejected = try await Task.detached(priority: .userInitiated) {
                    guard Self.mountedDevices().contains(where: { $0.url == url && $0.ejectable }) else { return false }
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return true
                }.value
                guard ejected else { working -= 1; readSidebar(); return say(.refused("This volume is no longer available to eject.")) }
                if folder.path == url.path || folder.path.hasPrefix(url.path + "/") { go(URL(filePath: home)) }
                readSidebar()
                say(.done("Ejected \(url.lastPathComponent)."))
            } catch { say(.refused("Could not eject \(url.lastPathComponent): \(error.localizedDescription)")) }
            working -= 1
        }
    }

    /// Cmd+C: the picked files on the clipboard, for Cmd+V (copy) or Cmd+Option+V (move) here or in Finder.
    func copy(_ item: FolderItem? = nil) {
        let picked = selections(for: item)
        guard !picked.isEmpty else { return }
        FilesCut.shared.clear()
        let board = FilesCut.shared.board
        board.clearContents()
        board.writeObjects(picked.map { $0.url as NSURL })
        say(.done("Copied \(picked.count == 1 ? picked[0].name : "\(picked.count) items"). Cmd+V copies into the folder shown, Cmd+Option+V moves."))
    }

    /// Cmd+X: the picked group marked (dimmed) to move; the next Cmd+V moves it into the folder shown then, Esc unmarks it.
    func cut(_ item: FolderItem? = nil) {
        let picked = selections(for: item)
        guard !picked.isEmpty else { return }
        if let gone = FilesCut.shared.mark(picked.map(\.url)) { return say(.refused("\(gone) is gone; nothing was cut.")) }
        say(.done("Cut \(picked.count == 1 ? picked[0].name : "\(picked.count) items"). Cmd+V moves into the folder shown; Esc keeps the originals."))
    }

    /// Cmd+V moves the cut items into the shown folder (FileOps, so Cmd+Z puts them back), else copies the clipboard's
    /// files there; Cmd+Option+V moves them.
    func paste(moving: Bool) {
        switch FilesCut.shared.take() {
        case let .move(cut, ids): return run(.move(cut, into: folder, .ask), expect: ids)
        case let .changed(name): return say(.refused(CutChanged.words(name)))
        case .none: break
        }
        let urls = FilesCut.shared.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            say(.refused("Nothing to \(moving ? "move" : "paste"): the clipboard holds no file. Pick one and press Cmd+C first."))
            return
        }
        run(moving ? .move(urls, into: folder, .ask) : .copy(urls, into: folder, .ask))
    }

    /// Cmd+Shift+N: a new folder here, its name open for editing.
    func newFolder() { run(.newFolder(in: folder, named: nil)) }

    /// New file: `template` made here (a number added when its name is taken), its name open for editing; Cmd+Z sends
    /// it to the Trash.
    func newFile(_ template: FileTemplate) { run(.newFile(in: folder, named: template.name, template: template.url)) }

    /// Cmd+Option+N: New file's rows as a picker at the window's top left, Templates folder last.
    func showNewFile() {
        guard let at = screenPoint(nil) else { return }
        let templates = templates
        var rows = templates.map { MenuEntry(title: $0.title, target: .action("files.new." + $0.id), subtitle: $0.url == nil ? $0.name : nil,
                                             icon: .glyph("doc.badge.plus", .accent)) }
        rows.append(MenuEntry(title: "Templates folder…", target: .action("files.new.templates"), subtitle: "Put any file here to make new ones from it",
                              icon: .glyph("folder", .accent)))
        PilotMenu.$anchor.withValue(at) {
            PilotMenu.shared.pick(rows, title: "New file") { [weak self] row in
                guard let self, case .action(let id) = row.target else { return }
                if id == "files.new.templates" { return openTemplates() }
                if let template = templates.first(where: { "files.new." + $0.id == id }) { newFile(template) }
            }
        }
    }

    /// Opens Pilot's Templates folder here, making it first (through FileOps, so Cmd+Z takes it back) when it is missing.
    func openTemplates() {
        let folder = templateFolder
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { return go(folder) }
        let support = folder.deletingLastPathComponent()
        go(support)
        run(.newFolder(in: support, named: folder.lastPathComponent))
    }

    // MARK: The path bar

    /// The path bar's Return: a folder opens here, a file's folder opens with it picked; nothing there keeps the field
    /// open and says so.
    func goTo(_ typed: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { editingPath = false; return }
        let url = FolderListing.resolve(text, from: folder, home: home)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return say(.refused("Nothing at \(FolderListing.shown(url, home: home)). Check the path, or press Esc to keep this folder."))
        }
        editingPath = false
        if FolderLooks.isFolder(url) {
            go(url)
        } else {
            go(url.deletingLastPathComponent())
            selected = url.standardizedFileURL.path
        }
    }

    // MARK: Folder sizes

    /// List view's folder sizes: one walk at a time off the main thread, each folder in turn (packages too), skipping
    /// any already known at its date; stopped by another folder, grid view or the window's close. Protected folders
    /// (`FolderListing.protectedRoots`) answer nil without being read, so macOS never asks.
    private func sizeFolders() {
        guard mode == .list, let items = listing?.items else { return stopSizing() }
        let wanted = items.filter { item in item.size == nil && folderSizes[item.id].map { $0.modified != item.modified } ?? true }
        // A watch event asking for folders the walk is already sizing lets it finish.
        if sizing != nil, Set(wanted.map(\.id)).isSubset(of: sizingIDs) { return }
        stopSizing()
        guard !wanted.isEmpty else { return }
        let home = home, inside = folder.standardizedFileURL.path(percentEncoded: false)
        sizingIDs = Set(wanted.map(\.id))
        sizingRun += 1
        let run = sizingRun
        sizing = Task.detached(priority: .utility) { [weak self] in
            // Built once a walk, by identity: the shown folder's volume, the protected roots it is not in, other apps' data.
            let fence = FolderListing.Fence(inside: inside, protected: FolderListing.protectedRoots(home: home, fullDiskAccess: FileIndex.hasFullDiskAccess()),
                                            appData: FolderListing.appData(home: home))
            // Sizes reach the window at most four times a second, so a folder of many folders redraws a few times.
            var found: [(FolderItem, Int64?)] = [], told = ContinuousClock.now
            for item in wanted {
                found.append((item, fence.flatMap { FolderListing.folderSize(item.url, fence: $0) { Task.isCancelled } }))
                guard !Task.isCancelled else { return }
                if ContinuousClock.now - told > .milliseconds(250) {
                    await self?.sized(found, run: run, last: false)
                    (found, told) = ([], .now)
                }
            }
            await self?.sized(found, run: run, last: true)
        }
    }

    /// Sizes from walk `token`; the `last` ones end it, and a size sort takes them in. A walk stopped or replaced since
    /// (another folder, grid view, a newer walk) changes nothing, so it never ends the walk that replaced it.
    private func sized(_ found: [(FolderItem, Int64?)], run: Int, last: Bool) {
        guard run == sizingRun else { return }
        for (item, bytes) in found { folderSizes[item.id] = FolderSize(modified: item.modified, bytes: bytes) }
        guard last else { return }
        (sizing, sizingIDs) = (nil, [])
        if sort == .size { resort() }
    }

    /// A folder read whole sorted again in memory (a capped one reads again for the sort's first items).
    private func resort() {
        guard let listing, listing.count <= listing.items.count else { return }
        let sorted = FolderListing.sorted(listing.items, by: sort, sizes: knownSizes)
        if sorted != listing.items { self.listing?.items = sorted }
    }

    /// Writes nothing when no walk runs, so a reload that changed nothing redraws no row.
    private func stopSizing() {
        guard let sizing else { return }
        sizing.cancel()
        sizingRun += 1
        (self.sizing, sizingIDs) = (nil, [])
    }

    /// What the Size column says: a file's bytes; a folder's worked-out size, "…" while it is worked out, "—" where it
    /// is protected, does not read whole, or is not worked out (grid, search hits).
    func sizeLabel(_ item: FolderItem) -> String {
        if let size = item.size { return FolderListing.size(size) }
        if let known = folderSizes[item.id] { return FolderListing.size(known.bytes) }
        return sizingFolders && hits == nil ? "…" : "—"
    }

    /// Files dropped on a folder (a folder's row or tile, or the shown folder's empty space), from this window, another
    /// or Finder. As Finder: a move on the same volume, a copy onto another or with Option held. A drop where the files
    /// already are, or of a folder onto itself, does nothing.
    func drop(_ urls: [URL], on target: URL) -> Bool {
        let sources = urls.filter(\.isFileURL)
        guard !sources.isEmpty, !sources.contains(where: { $0.standardizedFileURL == target.standardizedFileURL }) else { return false }
        if places.last?.url == target {
            run(.trash(sources))
            return true
        }
        let volume = Self.volume(target)
        let moving = !NSEvent.modifierFlags.contains(.option) && volume != nil && sources.allSatisfy { Self.volume($0)?.isEqual(volume) == true }
        if moving, sources.allSatisfy({ $0.deletingLastPathComponent().path == target.path }) { return false }
        run(moving ? .move(sources, into: target, .ask) : .copy(sources, into: target, .ask))
        return true
    }

    /// Why the window won't run `request` in a Trash, or nil. The Trash takes items only through Move to Trash, whose undo
    /// knows where each came from: nothing is copied, moved, made or renamed in it, and nothing in it goes to the Trash
    /// again. Confirmed permanent deletion uses TrashDeletion separately. Taking an item out, and any undo, run.
    private static func trashRefusal(_ request: FileOps.Request) -> String? {
        let into = "Nothing goes into the Trash this way: use Move to Trash (Cmd+Backspace), so Cmd+Z can put it back."
        switch request {
        case let .copy(_, folder, _), let .move(_, folder, _), let .newFolder(folder, _), let .newFile(folder, _, _): return inTrash(folder) ? into : nil
        case let .rename(item, _):
            return inTrash(item.deletingLastPathComponent()) ? "\(item.lastPathComponent) is in the Trash; take it out before renaming it." : nil
        case let .trash(items):
            return items.first { inTrash($0.deletingLastPathComponent()) }.map {
                "\($0.lastPathComponent) is already in the Bin. Use Delete Immediately to permanently delete it."
            }
        case .undo: return nil
        }
    }

    /// Whether `folder` is a Trash or inside one: ~/.Trash, iCloud Drive's .Trash, or a volume's .Trashes.
    nonisolated static func inTrash(_ folder: URL) -> Bool {
        (folder.standardizedFileURL.pathComponents + folder.resolvingSymlinksInPath().pathComponents)
            .contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    nonisolated private static func volume(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    // MARK: Search

    /// The typed words, a moment after the last key: the index's hits inside the shown folder, hidden files and Hidden
    /// apps left out; without Full Disk Access, this folder's names that hold them.
    private func search() {
        asking?.cancel()
        asked += 1
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { (hits, searchNote) = (nil, nil); pruneSelection(); return }
        let folder = folder, number = asked
        asking = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let ask = FileSearch.Ask(text: typed, filters: FileFilters(place: .folder(folder.path(percentEncoded: false))))
            sources.search(ask) { [weak self] found in
                MainActor.assumeIsolated { self?.took(found, typed: typed, folder: folder, number: number) }
            }
        }
    }

    /// The index's reply to search `number`, as rows off the main thread; nil (no Full Disk Access) filters this
    /// folder's names instead.
    private func took(_ found: [FileSearch.Hit]?, typed: String, folder: URL, number: Int) {
        guard number == asked, folder == self.folder else { return }
        guard let found else {
            (hits, searchNote) = (Gallery.filter(items, typed), "Names in this folder only: searching inside it needs Full Disk Access.")
            pruneSelection()
            return
        }
        let paths = found.prefix(Self.hitCap).map(\.path), hidden = sources.hidden()
        asking = Task {
            let made = await Task.detached(priority: .userInitiated) { paths.compactMap { FilesModel.item(URL(filePath: $0), hidden: hidden) } }.value
            guard !Task.isCancelled, number == asked, folder == self.folder else { return }
            (hits, searchNote) = (made, nil)
            pruneSelection()
        }
    }

    nonisolated static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
                                            .localizedTypeDescriptionKey, .contentTypeKey]

    /// A search hit as a row, or nil: gone, hidden (a dot name or Finder's hidden flag, which Hidden apps sets), or an
    /// app whose bundle id `hidden` holds.
    nonisolated static func item(_ url: URL, hidden: Set<String>) -> FolderItem? {
        guard !url.lastPathComponent.hasPrefix("."), let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { return nil }
        if url.pathExtension.lowercased() == "app", !hidden.isEmpty, let id = Bundle(url: url)?.bundleIdentifier, hidden.contains(id) { return nil }
        let isFolder = values.isDirectory == true && values.isPackage != true
        return FolderItem(url: url, name: url.lastPathComponent, isFolder: isFolder,
                          size: isFolder ? nil : values.fileSize.map(Int64.init), modified: values.contentModificationDate,
                          kind: values.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"), type: values.contentType?.identifier)
    }

    // MARK: Pictures

    /// A file's thumbnail (or with `icon` its own icon), `pixels` a side at most, made off the main thread once while
    /// the window is open; one being made is waited for.
    func picture(_ url: URL, pixels: Int, icon: Bool = false, modified: Date? = nil) async -> NSImage? {
        let key = "\(icon ? "icon \(iconEpoch) " : "")\(modified?.timeIntervalSince1970 ?? 0) \(pixels) \(url.path)"
        if let made = pictures.object(forKey: key as NSString) { return made }
        guard !none.contains(key) else { return nil }
        let making = pending[key] ?? Task { [make = icon ? sources.icon : sources.make] in
            guard let image = await make(url, pixels) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        }
        pending[key] = making
        let made = await making.value
        pending[key] = nil
        if let made { pictures.setObject(made, forKey: key as NSString, cost: Int(made.size.width * made.size.height * 16)) } else { none.insert(key) }
        return made
    }

    /// The window is key again after Cmd+K's Change icon, Reset icon or Folder design: the icons are drawn afresh, and
    /// once more a moment later, as a reset or a design may still be writing when the picker gives the window back.
    func refreshIcons() {
        guard iconsChanged else { return }
        iconsChanged = false
        iconEpoch += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.iconEpoch += 1
        }
    }

    nonisolated static func isImage(_ item: FolderItem) -> Bool { item.type.flatMap { UTType($0) }?.conforms(to: .image) == true }

    /// Whether a file asks QuickLook for a thumbnail (pictures, video, documents) in the list, grid and inspector; folders
    /// and apps keep their own icon.
    nonisolated static func thumbnails(_ item: FolderItem) -> Bool { !item.isFolder && !item.isApp }

    /// `url`'s icon as Finder draws it, `pixels` a side: NSWorkspace's, which is safe off the main thread, drawn there.
    @concurrent nonisolated static func workspaceIcon(_ url: URL, _ pixels: Int) async -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(cgContext: ctx, flipped: false)
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: The sidebar's sources

    /// The menu's favourites (Cmd+K) that are folders still there, by name.
    nonisolated static func favouriteFolders(_ rows: Set<String>) -> [String] {
        rows.compactMap { row -> String? in
            guard row.hasPrefix("file:") else { return nil }
            let path = String(row.dropFirst(5))
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue,
                  !NSWorkspace.shared.isFilePackage(atPath: path) else { return nil }
            return path
        }
        .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    /// The volumes Finder shows, the start-up disk first, each with its free and whole bytes.
    nonisolated static func mountedDevices() -> [Device] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> (Bool, Device)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let symbol = values.volumeIsLocal == false ? "server.rack" : values.volumeIsInternal == true ? "internaldrive" : "externaldrive"
            let volume = DiskEject.Volume(name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path,
                                         ejectable: values.volumeIsEjectable ?? false, removable: values.volumeIsRemovable ?? false,
                                         isInternal: values.volumeIsInternal ?? true, local: values.volumeIsLocal ?? false,
                                         root: values.volumeIsRootFileSystem ?? false)
            return (values.volumeIsRootFileSystem == true,
                    Device(name: values.volumeLocalizedName ?? url.lastPathComponent, symbol: symbol, url: url,
                           free: values.volumeAvailableCapacityForImportantUsage, total: values.volumeTotalCapacity.map(Int64.init),
                           ejectable: !DiskEject.ejectable([volume]).isEmpty))
        }
        .sorted { $0.0 && !$1.0 }
        .map(\.1)
    }
}

/// What the inspector says of one item: its picture or lines, then Kind, Size, Dimensions, Modified, From (only when
/// known) and Where. Read off the main thread.
struct FilesInspection: Equatable, Sendable {
    let preview: FilePreview?
    let facts: [FilePreview.Fact]

    nonisolated static func read(_ item: FolderItem, home: String = NSHomeDirectory()) -> FilesInspection {
        let preview = FilePreview.read(item.url.path(percentEncoded: false))
        let read = Dictionary((preview?.facts ?? []).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        var facts = [FilePreview.Fact(label: "Kind", value: item.kind)]
        if let size = item.size { facts.append(.init(label: "Size", value: FolderListing.size(size))) }
        if case .folder(let n)? = preview?.look { facts.append(.init(label: "Items", value: n >= FilePreview.itemLimit ? "\(n)+" : "\(n)")) }
        for label in ["Dimensions", "Pages"] { if let value = read[label] { facts.append(.init(label: label, value: value)) } }
        facts.append(.init(label: "Modified", value: FolderListing.date(item.modified)))
        if let from = from(item.url) { facts.append(.init(label: "From", value: from)) }
        facts.append(.init(label: "Where", value: FolderListing.shown(item.url.deletingLastPathComponent(), home: home)))
        return FilesInspection(preview: preview, facts: facts)
    }

    /// Where a download came from: the site's host in the file's where-froms, as Finder's Get Info shows it.
    nonisolated static func from(_ url: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard read == size, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
              let first = list.first(where: { !$0.isEmpty }) else { return nil }
        return URL(string: first)?.host() ?? first
    }
}

// MARK: - The window's face

/// Pick B: the sidebar (230 pt), the content under its 58 pt toolbar with the 30 pt status bar, and the inspector
/// (300 pt), in Pilot's tokens at the window's 14/13 scale.
struct FilesView: View {
    @Environment(\.ink) private var ink
    @Bindable var model: FilesModel

    static let sidebarWidth: CGFloat = 230, inspectorWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 0) {
            FilesSidebar(model: model).frame(width: Self.sidebarWidth).background(ink.sidebar)
            ink.line.frame(width: 1)
            VStack(spacing: 0) {
                // Above the content: the path bar's completions hang over it.
                FilesToolbar(model: model).padding(.horizontal, 16).frame(height: 58).zIndex(1)
                ink.line.frame(height: 1)
                FilesContent(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = model.notice {
                    ink.line.frame(height: 1)
                    FilesNotice(notice: notice, model: model)
                }
                ink.line.frame(height: 1)
                FilesPathBar(model: model).frame(height: 49)
                ink.line.frame(height: 1)
                status.padding(.horizontal, 16).frame(height: 27)
            }
            .frame(maxWidth: .infinity)
            ink.line.frame(width: 1)
            FilesInspector(model: model).frame(width: Self.inspectorWidth)
        }
        // The ground draws once: whole when Solid, none over Glass, whose tint carries it (as the app window's frame).
        .background(Theme.windowFill(ink.background))
        .background { keys }
        .alert(model.prompt?.title ?? "", isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } }),
               presenting: model.prompt) { prompt in
            switch prompt {
            case .rename:
                TextField("Folder name", text: $model.newName)
                Button("Rename") { model.confirmPrompt(prompt) }.keyboardShortcut(.defaultAction)
            case .delete:
                Button("Delete Permanently", role: .destructive) { model.confirmPrompt(prompt) }
            }
            Button("Cancel", role: .cancel) { model.prompt = nil }
        } message: { prompt in Text(prompt.message) }
        // This container survives spring navigation. SwiftUI snapshots every URL when the drag begins.
        .dragContainer(for: URL.self, itemID: \.path) { (ids: [String]) in model.drag(ids) }
        .dragContainerSelection(model.selections.map(\.id))
        .dragConfiguration(.init(allowMove: true))
        .onDragSessionUpdated { session in
            if case .ended = session.phase { model.endDrag() }
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Text(Self.status(count: model.hits?.count ?? model.count, selected: model.selections)).lineLimit(1)
            if model.working > 0 {
                ProgressView().controlSize(.mini)
                Text("Working…").lineLimit(1)
            }
            if model.showHidden { Text("· Hidden files shown").lineLimit(1) }
            if let note = model.searchNote { Text("· \(note)").lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 8)
            if let free = model.free { Text("\(FolderListing.size(free)) available").lineLimit(1) }
        }
        .font(ink.ui(12)).foregroundStyle(ink.muted)
    }

    /// "10 items, 3 selected (2.1 MB)"; a total is shown only when every selected size is known.
    static func status(count: Int, selected: [FolderItem]) -> String {
        let items = count == 1 ? "1 item" : "\(count) items"
        guard !selected.isEmpty else { return items }
        let picked = "\(items), \(selected.count) selected"
        let sizes = selected.compactMap(\.size)
        return sizes.count == selected.count ? "\(picked) (\(FolderListing.size(sizes.reduce(0, +))))" : picked
    }

    /// The window's keys: Cmd+N another window, Cmd+[ and ] back and forward, Cmd+Up the enclosing folder, Cmd+Down or
    /// Cmd+O opens, Cmd+F searches, Cmd+1 and 2 list and grid, Cmd+K the file actions, Cmd+I the file's preview and facts,
    /// Cmd+L the path bar, Cmd+Option+N a new file. Cmd+K, I, O, Down and Up wait while the search field has focus.
    /// FilesKeysHelp.keys lists them, and the list's own keys (FilesContent.key), for the toolbar's key help.
    private var keys: some View {
        Group {
            Group {
                Button("") { model.showActions() }.keyboardShortcut("k")
                Button("") { model.info() }.keyboardShortcut("i")
                Button("") { model.up() }.keyboardShortcut(.upArrow)
                ForEach([KeyboardShortcut(.downArrow), KeyboardShortcut("o")], id: \.key) { key in
                    Button("") { if let item = model.selection { model.open(item) } }.keyboardShortcut(key)
                }
            }
            // While the search field has focus, these keys are the field's (Cmd+Up and Down move its caret).
            .disabled(model.searchFocused)
            Button("") { model.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("") { model.newWindow(model.folder) }.keyboardShortcut("n")
            Button("") { model.showNewFile() }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("") { model.editingPath = true }.keyboardShortcut("l")
            Button("") { model.back() }.keyboardShortcut("[")
            Button("") { model.forward() }.keyboardShortcut("]")
            Button("") { model.searching = true }.keyboardShortcut("f")
            Button("") { model.mode = .list }.keyboardShortcut("1")
            Button("") { model.mode = .grid }.keyboardShortcut("2")
        }
        // While a name or the path is being edited no shortcut acts: each key goes to the field.
        .disabled(model.renaming != nil || model.editingPath)
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// What a file action did, or FileOps' refusal in its own words (a problem's mark in red), with Keep both and Replace
/// when a name is already taken. A refusal stays until closed; what was done stays until the next action.
private struct FilesNotice: View {
    @Environment(\.ink) private var ink
    let notice: FilesModel.Notice
    let model: FilesModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.problem ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .font(ink.ui(12, .semibold)).foregroundStyle(notice.problem ? ink.red : ink.muted)
            Text(notice.text).font(ink.ui(12.5)).foregroundStyle(ink.text).lineLimit(4).truncationMode(.middle)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).help(notice.text)
            if notice.clash != nil {
                Button("Keep both") { model.answer(.keepBoth) }.buttonStyle(.pilot)
                    .help("A number is added to the new one's name")
                Button("Replace") { model.answer(.replace) }.buttonStyle(.pilot)
                    .help("The one already there goes to the Trash first; Cmd+Z brings it back")
            }
            Button { model.dismissNotice() } label: { Image(systemName: "xmark").font(ink.ui(11, .semibold)).frame(width: 20, height: 20) }
                .buttonStyle(.plain).foregroundStyle(ink.muted).help("Close").accessibilityLabel("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

/// The one accent fill that marks the picked row, tile or place.
private struct PickedFill: ViewModifier {
    @Environment(\.ink) private var ink
    let on: Bool
    var radius: CGFloat = 7
    func body(content: Content) -> some View {
        content.background { if on { RoundedRectangle(cornerRadius: ink.radius(radius), style: .continuous).fill(ink.accent.opacity(0.16)) } }
    }
}

/// Native folder actions shared by the sidebar, breadcrumbs and empty space.
private struct FilesFolderMenu: View {
    let url: URL
    let model: FilesModel

    var body: some View {
        Button("Open in New Window") { model.newWindow(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Info") { FilePreviewWindow.open(url) }
        FilesCopyPathMenu(model: model, urls: [url])
        Divider()
        if !FilesModel.inTrash(url) || model.isFavourite(url) {
            Button(model.isFavourite(url) ? "Remove Favourite" : "Add to Favourites") { model.toggleFavourite(url) }
        }
        if !FilesModel.inTrash(url) {
            if model.canRenameFolder(url) { Button("Rename…") { model.askRenameFolder(url) } }
            Button("Change Folder Design…") { model.changeFolderDesign([url]) }
        }
        if model.isBin(url) {
            Button("Empty Bin…", role: .destructive) { model.prepareDeletion() }.disabled(model.working > 0)
        }
        if model.devices.contains(where: { $0.url == url && $0.ejectable }) {
            Button("Eject") { model.eject(url) }.disabled(model.working > 0)
        }
    }
}

private struct FilesSidebar: View {
    @Environment(\.ink) private var ink
    let model: FilesModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                heading("Places", first: true)
                ForEach(model.places) { place in row(place.url, place.symbol, place.title) { EmptyView() } }
                if !model.favourites.isEmpty {
                    heading("Favourites")
                    ForEach(model.favourites) { place in row(place.url, place.symbol, place.title) { EmptyView() } }
                }
                if !model.devices.isEmpty {
                    heading("Devices")
                    ForEach(model.devices) { device in
                        let free = device.free.map(FolderListing.size)
                        // "X available" under the meter, the toolbar's and the status bar's word, so the name keeps the row.
                        row(device.url, device.symbol, device.name, folderIcon: false, help: free.map { "\($0) available" }) {
                            EmptyView()
                        } under: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let used = device.used { InstrumentMeter(share: used) }
                                if let free { Text("\(free) available").font(ink.mono(10.5)).foregroundStyle(ink.muted).lineLimit(1) }
                            }
                            .padding(.leading, 25)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 44).padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private func heading(_ title: String, first: Bool = false) -> some View {
        InstrumentEyebrow(text: title).padding(.horizontal, 10).padding(.top, first ? 0 : 16).padding(.bottom, 4)
    }

    /// A place, a favourite or a device: its glyph and name, what it shows at the right, and under it (a device's meter).
    private func row(_ url: URL, _ symbol: String, _ title: String, folderIcon: Bool = true, help: String? = nil, @ViewBuilder trailing: () -> some View,
                     @ViewBuilder under: () -> some View = { EmptyView() }) -> some View {
        let here = model.folder == url.standardizedFileURL
        return Button { model.go(url) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    if folderIcon && !model.isBin(url) {
                        FilesIcon(item: FolderItem(url: url, name: title, isFolder: true, size: nil, modified: nil, kind: "Folder", type: nil),
                                  model: model, side: 16, lit: here)
                    } else {
                        Image(systemName: symbol).font(ink.ui(12)).frame(width: 16).foregroundStyle(here ? ink.accent : ink.text2)
                    }
                    Text(title).font(ink.ui(13.5)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    trailing()
                }
                under()
            }
            .padding(.horizontal, 10).frame(minHeight: 26).padding(.vertical, 1)
            .modifier(PickedFill(on: here))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help.map { "\(FolderListing.shown(url)) · \($0)" } ?? FolderListing.shown(url))
        .accessibilityLabel(help.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(here ? .isSelected : [])
        .modifier(FilesDropTarget(url: url, model: model))
        .contextMenu { FilesFolderMenu(url: url, model: model) }
    }
}

/// C: generous, equal-width folder targets, with middle ancestors available even in a narrow window.
private struct FilesPathBar: View {
    @Environment(\.ink) private var ink
    let model: FilesModel
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let folders = model.pathFolders
            let slots = max(3, Int(geometry.size.width / 128))
            let hidden = folders.count > slots ? Array(folders.dropFirst().dropLast(slots - 2)) : []
            HStack(spacing: 0) {
                ForEach(folders) { place in
                    if !hidden.contains(where: { $0.id == place.id }) {
                        if place.id != folders.first?.id { ink.line.frame(width: 1) }
                        target(place)
                    } else if place.id == hidden.first?.id {
                        ink.line.frame(width: 1)
                        Button { expanded.toggle() } label: {
                            Image(systemName: "ellipsis").font(ink.ui(14)).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Enclosing folders")
                        .accessibilityLabel("Show enclosing folders")
                        .dropDestination(for: URL.self) { _, _ in false } isTargeted: { hovering = $0 }
                        .task(id: hovering) {
                            guard hovering else { return }
                            try? await Task.sleep(for: .milliseconds(650))
                            if !Task.isCancelled { expanded = true }
                        }
                        .popover(isPresented: $expanded, arrowEdge: .top) {
                            VStack(spacing: 0) { ForEach(hidden) { target($0).frame(height: 36) } }
                                .frame(width: 240).padding(6).background(ink.background)
                        }
                    }
                }
            }
            .foregroundStyle(ink.text2)
        }
        .onChange(of: model.folder) { expanded = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    private func target(_ place: FilesModel.Place) -> some View {
        Button { model.go(place.url); expanded = false } label: {
            HStack(spacing: 8) {
                Image(systemName: place.symbol).foregroundStyle(ink.muted)
                Text(place.title).font(ink.ui(12, place.url == model.folder ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(FolderListing.shown(place.url))
        .accessibilityLabel(place.url.path)
        .accessibilityAddTraits(place.url == model.folder ? .isSelected : [])
        .modifier(FilesDropTarget(url: place.url, model: model))
        .contextMenu { FilesFolderMenu(url: place.url, model: model) }
    }
}

private struct FilesToolbar: View {
    @Environment(\.ink) private var ink
    @Bindable var model: FilesModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            barButton("chevron.left", "Back", on: model.canGoBack) { model.back() }
            barButton("chevron.right", "Forward", on: model.canGoForward) { model.forward() }
            if model.editingPath {
                FilesPathField(model: model).padding(.leading, 4)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(ink.ui(15, .semibold)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(ink.mono(11)).foregroundStyle(ink.muted).lineLimit(1)
                }
                .padding(.leading, 4)
                .contentShape(.rect)
                .onTapGesture { model.editingPath = true }
                .help("\(FolderListing.shown(model.folder)) · click or Cmd+L to type a path")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.editingPath = true }
            }
            Spacer(minLength: 8)
            if model.searching {
                SearchBox(prompt: "Search \(model.title)", text: $model.query, focused: $searchFocused).frame(minWidth: 140, maxWidth: 220)
                    .onExitCommand { model.searching = false }
                    .onAppear { searchFocused = true }
                    .onChange(of: searchFocused) { _, focused in model.searchFocused = focused }
            }
            modes
            barButton(model.searching ? "xmark" : "magnifyingglass", model.searching ? "Close search" : "Search", on: true) {
                model.searching.toggle()
            }
            barButton("keyboard", "Keys", on: true) { showsKeys.toggle() }
                .popover(isPresented: $showsKeys, arrowEdge: .bottom) { FilesKeysHelp().floating() }
        }
    }

    @State private var showsKeys = false

    private var subtitle: String { model.listing.map(FolderListing.status) ?? " " }

    /// List | Grid: the mock's third segment (columns) waits for Sven.
    private var modes: some View {
        HStack(spacing: 2) {
            ForEach([(FilesModel.Mode.list, "list.bullet", "List"), (.grid, "square.grid.2x2", "Grid")], id: \.0) { mode, symbol, label in
                let on = model.mode == mode
                Button { model.mode = mode } label: {
                    Image(systemName: symbol).font(ink.ui(12, .medium)).frame(width: 30, height: 24)
                        .foregroundStyle(on ? ink.accent : ink.text2)
                        .background { if on { RoundedRectangle(cornerRadius: ink.radius(6), style: .continuous).fill(ink.selected) } }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous).strokeBorder(ink.line2))
    }

    private func barButton(_ symbol: String, _ label: String, on: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(ink.ui(13, .semibold)).frame(width: 26, height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain).foregroundStyle(on ? ink.text2 : ink.muted.opacity(0.5)).disabled(!on)
        .help(label).accessibilityLabel(label)
    }
}

/// The path bar as a field (a click on the folder's name, or Cmd+L): the shown folder's path from ~, Return goes there
/// (a file's folder, the file picked), Tab completes a folder's name, Esc or a click elsewhere keeps the folder. The
/// folders that complete what is typed hang under it, read off the main thread; a click goes into one.
private struct FilesPathField: View {
    @Environment(\.ink) private var ink
    let model: FilesModel
    @State private var text = ""
    @State private var matches: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(7), style: .continuous)
        TextField("Path", text: $text)
            .textFieldStyle(.plain).font(ink.mono(13)).foregroundStyle(ink.text)
            .padding(.horizontal, 8).frame(height: 30)
            .background(shape.fill(ink.background))
            .overlay { shape.strokeBorder(ink.accent) }
            .frame(minWidth: 240, maxWidth: 520)
            .focused($focused)
            .onAppear { text = FolderListing.shown(model.folder) + (model.canGoUp ? "/" : ""); focused = true }
            .onSubmit { model.goTo(text) }
            .onExitCommand { model.editingPath = false }
            .onKeyPress(.tab) { complete(); return .handled }
            .onChange(of: focused) { if !focused, model.editingPath { model.editingPath = false } }
            .task(id: text) {
                let typed = text, base = model.folder
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                let found = await Task.detached(priority: .userInitiated) { FolderListing.completions(typed, from: base) }.value
                if !Task.isCancelled { matches = found.filter { $0 != typed } }
            }
            .overlay(alignment: .topLeading) { if !matches.isEmpty { list(shape) } }
            .accessibilityLabel("Path")
    }

    private func list(_ shape: RoundedRectangle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.self) { match in
                Button { model.goTo(match) } label: {
                    Text(match).font(ink.mono(12)).foregroundStyle(ink.text2).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 24).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(shape.fill(ink.background))
        .overlay { shape.strokeBorder(ink.line2) }
        .offset(y: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folders")
    }

    /// Tab: what every match shares, when that is longer than what is typed; else the first match.
    private func complete() {
        guard let first = matches.first else { return }
        let shared = matches.dropFirst().reduce(first) { $0.commonPrefix(with: $1, options: .caseInsensitive) }
        text = shared.count > text.count ? shared : first
    }
}

/// The list or the grid, or a quiet line: a folder that does not read, an empty one, a search with no hits.
private struct FilesContent: View {
    @Environment(\.ink) private var ink
    let model: FilesModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let problem = model.problem {
                note(problem, finder: true)
            } else if model.shown.isEmpty {
                if model.hits != nil { note("Nothing here holds “\(model.query)”.") }
                else if model.loaded { note("Empty folder") }
            } else if model.mode == .list {
                list
            } else {
                grid
            }
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in key(press) }
        .onChange(of: model.folder, initial: true) { focused = true }
        .onChange(of: model.renaming) { if model.renaming == nil { focused = true } }
        .onChange(of: model.editingPath) { if !model.editingPath { focused = true } }
        // Search hits come from many folders, so empty space is no folder to drop into while they show.
        .dropDestination(for: URL.self) { urls, _ in model.hits == nil && model.drop(urls, on: model.folder) } isTargeted: { _ in }
        .contextMenu {
            if !FilesModel.inTrash(model.folder) {
                Button("New Folder") { model.newFolder() }
                FilesNewFileMenu(model: model)
                Button("Paste Here") { model.paste(moving: false) }
                Button("Move Here") { model.paste(moving: true) }
                Divider()
            }
            FilesFolderMenu(url: model.folder, model: model)
            FilesUndoItem(model: model)
        }
    }

    /// The list's keys, only while the list or grid has focus and no name is being edited (a key typed in the search or
    /// rename field never moves the selection or a file): the arrows step (left and right in the grid), Space Quick
    /// Looks, and once per press Return renames, Cmd+Backspace trashes, Cmd+C copies, Cmd+X cuts (Esc unmarks), Cmd+V
    /// moves what was cut or pastes a copy, Cmd+Option+V moves, Cmd+Shift+N makes a folder, Cmd+Z undoes. Pilot has no
    /// Edit menu, so these keys are the window's own.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard model.renaming == nil else { return .ignored }
        let mods = press.modifiers.intersection([.command, .option, .shift, .control])
        // Cmd+arrows are the window's (open, up); only a bare arrow steps.
        if mods.isEmpty {
            switch press.key {
            case .downArrow: model.step(1); return .handled
            case .upArrow: model.step(-1); return .handled
            case .rightArrow, .leftArrow:
                guard model.mode == .grid else { return .ignored }
                model.step(press.key == .rightArrow ? 1 : -1)
                return .handled
            default: break
            }
        }
        guard press.phase == .down else { return .ignored }
        switch (press.key, press.characters.lowercased(), mods) {
        case (.space, _, []): if let item = model.selection { model.quickLook(item) }
        // The window's Cmd+Down and Cmd+Up where their key equivalents miss them.
        case (.downArrow, _, .command): if let item = model.selection { model.open(item) }
        case (.upArrow, _, .command): model.up()
        // The window's Cmd+Shift+. where its key equivalent misses it: Shift+. arrives as ">" on most layouts.
        case (_, ">", [.command, .shift]): model.showHidden.toggle()
        case (.return, _, []): model.beginRename()
        case (.delete, _, .command): model.trash()
        case (_, "a", .command): model.selectAll()
        case (_, "c", .command): model.copy()
        case (_, "x", .command): model.cut()
        case (.escape, _, []):
            guard !FilesCut.shared.urls.isEmpty else { return .ignored }
            FilesCut.shared.clear()
        case (_, "v", .command): model.paste(moving: false)
        case (_, "v", [.command, .option]): model.paste(moving: true)
        case (_, "n", [.command, .shift]): model.newFolder()
        case (_, "z", .command): model.undo()
        default: return .ignored
        }
        return .handled
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                header("Name", sort: .name).frame(maxWidth: .infinity, alignment: .leading)
                header("Size", sort: .size).frame(width: 80, alignment: .trailing)
                header("Modified", sort: .modified).frame(width: 140, alignment: .leading)
            }
            .font(ink.mono(10.5, weight: .medium)).tracking(1.2).foregroundStyle(ink.muted).lineLimit(1)
            .padding(.horizontal, 24).frame(height: 30)
            ink.line.frame(height: 1)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) { ForEach(model.shown) { FilesRow(item: $0, model: model) } }.padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
    }

    private static let sortHelp: [FolderListing.Sort: String] = [.name: "Sort by name", .modified: "Sort by date modified, newest first",
                                                                  .size: "Sort by size, largest first (folders once their size is worked out)"]

    private func header(_ title: String, sort: FolderListing.Sort) -> some View {
        Button { model.sort = sort } label: {
            HStack(spacing: 3) {
                Text(title.uppercased())
                if model.sort == sort && model.hits == nil { Image(systemName: sort == .name ? "chevron.up" : "chevron.down").font(ink.ui(7, .bold)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.sort == sort ? ink.text2 : ink.muted)
        .help(Self.sortHelp[sort] ?? "")
    }

    private var grid: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(model.shown) { FilesTile(item: $0, model: model) }
            }
            .padding(16)
        }
    }

    /// A folder that does not read (with Show in Finder), an empty one, or a search with no hits.
    private func note(_ text: String, finder: Bool = false) -> some View {
        let folder = model.folder
        return EmptyState(title: text, action: finder ? ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([folder]) }) : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right-click's Undo, named for what it puts back; Cmd+Z's path.
private struct FilesUndoItem: View {
    let model: FilesModel
    var body: some View {
        Divider()
        Button(model.nextUndo.map { "Undo \($0)" } ?? "Undo") { model.undo() }.disabled(model.nextUndo == nil)
            // The pilot command or another window may have changed the journal since this window last read it.
            .onAppear { model.refreshUndo() }
    }
}

/// New file's rows for the right-click: Text, Markdown, the Templates folder's files, then the folder itself.
private struct FilesNewFileMenu: View {
    let model: FilesModel
    var body: some View {
        Menu("New File") {
            ForEach(model.templates) { template in Button(template.title) { model.newFile(template) } }
            Divider()
            Button("Templates Folder…") { model.openTemplates() }
        }
    }
}

/// Copy path's three forms for the right-click, each named by what it copies.
private struct FilesCopyPathMenu: View {
    let model: FilesModel
    let urls: [URL]
    var body: some View {
        Menu(urls.count == 1 ? "Copy Path" : "Copy Paths") {
            ForEach(FolderListing.PathForm.allCases, id: \.self) { form in
                Button(form.title) { model.copyPaths(urls, as: form) }
            }
        }
    }
}

/// An item's presses in the list and the grid: a click picks it, a double-click opens it (a folder here), a drag carries
/// it (onto a folder here moves it, through FileOps), a folder takes drops, and the right-click has the Folder widget's
/// read-only actions, then Rename, Copy, Move to Trash and Undo.
private struct FilesPress: ViewModifier {
    let item: FolderItem
    let model: FilesModel

    func body(content: Content) -> some View {
        content
            // Cut, not yet moved: dimmed, as Finder dims a hidden file.
            .opacity(FilesCut.shared.paths.contains(item.id) ? 0.45 : 1)
            .contentShape(.rect)
            .onTapGesture(count: 2) { model.open(item) }
            .simultaneousGesture(TapGesture().onEnded { model.select(item, modifiers: NSEvent.modifierFlags) })
            .draggable(containerItemID: item.id)
            .modifier(FolderDrop(item: item, model: model))
            .contextMenu {
                ForEach(model.actions(item), id: \.title) { action in Button(action.title, action: action.run) }
                if item.isFolder { Button("Open in New Window") { model.newWindow(item.url) } }
                Button("Info") { FilePreviewWindow.open(item.url) }
                FilesCopyPathMenu(model: model, urls: model.selections(for: item).map(\.url))
                Divider()
                if !FilesModel.inTrash(item.url.deletingLastPathComponent()) {
                    Button("Rename") { model.beginRename(item) }
                    if item.isFolder {
                        Button(model.isFavourite(item.url) ? "Remove Favourite" : "Add to Favourites") { model.toggleFavourite(item.url) }
                        Button("Change Folder Design…") { model.changeFolderDesign(model.selections(for: item).filter(\.isFolder).map(\.url)) }
                    }
                }
                Button("Copy") { model.copy(item) }
                Button("Cut") { model.cut(item) }
                if model.selections(for: item).allSatisfy({ FilesModel.inTrash($0.url.deletingLastPathComponent()) }) {
                    Button("Delete Immediately…", role: .destructive) { model.trash(item) }
                } else {
                    Button("Move to Trash") { model.trash(item) }
                }
                FilesUndoItem(model: model)
            }
            .help(item.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.isFolder ? "\(item.name), folder" : "\(item.name), \(item.kind), \(FolderListing.size(item.size))")
            .accessibilityAddTraits(model.selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Select") { model.select(item) }
            .accessibilityAction(named: "Open") { model.open(item) }
    }
}

/// A folder's row or tile takes files dropped on it, into that folder; a file's takes none (the drop falls to the shown
/// folder).
private struct FolderDrop: ViewModifier {
    let item: FolderItem
    let model: FilesModel

    func body(content: Content) -> some View {
        if item.isFolder {
            content.modifier(FilesDropTarget(url: item.url, model: model))
        } else {
            content
        }
    }
}

/// Shared by folder rows, the sidebar and every path segment. Hovering only navigates; drop alone writes.
private struct FilesDropTarget: ViewModifier {
    @Environment(\.ink) private var ink
    let url: URL
    let model: FilesModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in model.drop(urls, on: url) } isTargeted: { targeted = $0 }
            .overlay { if targeted { Rectangle().strokeBorder(ink.accent, lineWidth: 2).allowsHitTesting(false) } }
            .task(id: targeted) {
                guard targeted, model.canSpring(into: url) else { return }
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, model.canSpring(into: url) else { return }
                model.go(url)
            }
    }
}

/// An item's name in its row or tile, or the field editing it.
private struct FilesName: View {
    @Environment(\.ink) private var ink
    let item: FolderItem
    let model: FilesModel
    let size: CGFloat

    var body: some View {
        if model.renaming == item.id {
            RenameField(item: item, model: model, size: size)
        } else {
            Text(item.name).font(ink.ui(size)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The item's name being edited in place: Return renames through FileOps, Escape or a click elsewhere keeps the name.
private struct RenameField: View {
    @Environment(\.ink) private var ink
    let item: FolderItem
    let model: FilesModel
    let size: CGFloat
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.plain).font(ink.ui(size)).foregroundStyle(ink.text)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: ink.radius(4), style: .continuous).fill(ink.background))
            .overlay { RoundedRectangle(cornerRadius: ink.radius(4), style: .continuous).strokeBorder(ink.accent) }
            .focused($focused)
            .onAppear { name = item.name; focused = true }
            .onSubmit { model.rename(item, to: name) }
            .onExitCommand { model.renaming = nil }
            .onChange(of: focused) { if !focused, model.renaming == item.id { model.renaming = nil } }
            .accessibilityLabel("Name of \(item.name)")
    }
}

private struct FilesRow: View {
    @Environment(\.ink) private var ink
    let item: FolderItem
    let model: FilesModel

    var body: some View {
        let picked = model.selectedIDs.contains(item.id)
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                FilesIcon(item: item, model: model, side: 18, lit: picked, thumbnail: true)
                FilesName(item: item, model: model, size: 13.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(model.sizeLabel(item)).frame(width: 80, alignment: .trailing)
            Text(FolderListing.date(item.modified)).frame(width: 140, alignment: .leading)
        }
        .font(ink.mono(12)).foregroundStyle(ink.text2).lineLimit(1)
        .padding(.horizontal, 16).frame(height: 30)
        .modifier(PickedFill(on: picked))
        .modifier(PickedFrame(on: model.selected == item.id, model: model))
        .modifier(FilesPress(item: item, model: model))
    }
}

/// The picked row or tile tells the model where it sits, for Cmd+K's picker.
private struct PickedFrame: ViewModifier {
    let on: Bool
    let model: FilesModel
    func body(content: Content) -> some View {
        content.background {
            if on { Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.pickedFrame = $0 } }
        }
    }
}

private struct FilesTile: View {
    @Environment(\.ink) private var ink
    let item: FolderItem
    let model: FilesModel
    @State private var picture: NSImage?

    var body: some View {
        let picked = model.selectedIDs.contains(item.id)
        VStack(spacing: 8) {
            Group {
                // A picture fills the tile; a document's page or a video's frame shows whole.
                if let picture {
                    let shape = RoundedRectangle(cornerRadius: ink.radius(6), style: .continuous)
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: FilesModel.isImage(item) ? .fill : .fit)
                        .frame(maxWidth: 120, maxHeight: 84)
                        .clipShape(shape).overlay { shape.strokeBorder(ink.text.opacity(0.1)) }
                } else {
                    FilesIcon(item: item, model: model, side: 64)
                }
            }
            .frame(width: 120, height: 84)
            FilesName(item: item, model: model, size: 12.5).multilineTextAlignment(.center)
        }
        .padding(10).frame(maxWidth: .infinity)
        .modifier(PickedFill(on: picked, radius: 10))
        .modifier(PickedFrame(on: model.selected == item.id, model: model))
        .modifier(FilesPress(item: item, model: model))
        // QuickLook's thumbnail for any file it draws one for (pictures, video, documents); folders and apps keep their icon.
        .task(id: "\(item.id) \(item.modified?.timeIntervalSince1970 ?? 0)") {
            guard FilesModel.thumbnails(item) else { return }
            picture = nil
            let made = await model.picture(item.url, pixels: 240, modified: item.modified)
            if !Task.isCancelled { picture = made }
        }
    }
}

/// An item's own icon as Finder draws it (a folder's colour, a custom icon, an app's), made off the main thread and
/// kept while the window is open; its kind's glyph (DESIGN.md: each kind its own icon) stands in until it is made.
private struct FilesIcon: View {
    @Environment(\.ink) private var ink
    let item: FolderItem
    let model: FilesModel
    let side: CGFloat
    var lit = false
    var thumbnail = false
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: FolderListing.symbol(item)).font(.system(size: side * 0.75)).foregroundStyle(lit ? ink.accent : ink.muted)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .task(id: "\(model.iconEpoch) \(item.id) \(item.modified?.timeIntervalSince1970 ?? 0)") {
            let fallback = await model.picture(item.url, pixels: Int(side * 2), icon: true)
            guard !Task.isCancelled else { return }
            icon = fallback
            if thumbnail, FilesModel.thumbnails(item),
               let made = await model.picture(item.url, pixels: Int(side * 2), modified: item.modified), !Task.isCancelled { icon = made }
        }
    }
}

/// The inspector, always open: the selection (else the shown folder) as a large preview, its name, "kind · size", its
/// facts, and at the foot Open, Quick Look and More. The preview is the inspector's width and as tall as the picture's
/// shape allows (Sven, 2026-11-04: bigger), QuickLook's thumbnail for pictures, video and documents, else the item's icon.
private struct FilesInspector: View {
    @Environment(\.ink) private var ink
    let model: FilesModel
    @State private var inspection: FilesInspection?
    @State private var picture: NSImage?
    @State private var icon: NSImage?

    static let padding: CGFloat = 18
    /// The preview's width, and its height without a picture and at a picture's flattest and tallest.
    static let previewWidth = FilesView.inspectorWidth - 2 * padding
    static let previewHeight: CGFloat = 240, previewHeights: ClosedRange<CGFloat> = 170...340

    /// As tall as the picture is at the full width, within `previewHeights`.
    private var height: CGFloat {
        guard let size = picture?.size, size.width > 0 else { return Self.previewHeight }
        return min(Self.previewHeights.upperBound, max(Self.previewHeights.lowerBound, Self.previewWidth * size.height / size.width))
    }

    var body: some View {
        let item = model.subject
        VStack(alignment: .leading, spacing: 0) {
            // The look is an overlay, so a picture never widens the column.
            ink.well.frame(maxWidth: .infinity).frame(height: height).overlay { look }
                .clipShape(RoundedRectangle(cornerRadius: ink.radius(10), style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: ink.radius(10), style: .continuous).strokeBorder(ink.line2) }
            Text(item.name).font(ink.ui(15, .semibold)).foregroundStyle(ink.text).lineLimit(2).truncationMode(.middle).padding(.top, 16)
            Text(item.size.map { "\(item.kind) · \(FolderListing.size($0))" } ?? item.kind).font(ink.ui(12.5)).foregroundStyle(ink.muted)
                .lineLimit(1).padding(.top, 3)
            VStack(spacing: 9) {
                ForEach(inspection?.facts ?? [], id: \.label) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(fact.label).font(ink.ui(12.5)).foregroundStyle(ink.muted)
                        Spacer(minLength: 8)
                        Text(fact.value).font(ink.mono(12)).foregroundStyle(ink.text2).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 12)
            if model.selection != nil { buttons(item) }
        }
        .padding(.horizontal, Self.padding).padding(.top, 44).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(model.iconEpoch) \(item.id) \(item.modified?.timeIntervalSince1970 ?? 0)") { await load(item) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    @ViewBuilder private var look: some View {
        if let picture {
            Image(nsImage: picture).resizable().scaledToFit()
        } else if case .lines(let lines)? = inspection?.preview?.look {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).font(ink.mono(10.5)).foregroundStyle(ink.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 128, height: 128)
        }
    }

    private func buttons(_ item: FolderItem) -> some View {
        HStack(spacing: 8) {
            Button { model.open(item) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
                .buttonStyle(.pilotPrimary)
            Button { model.quickLook(item) } label: { Label("Quick Look", systemImage: "eye") }.buttonStyle(.pilot)
            Menu {
                ForEach(WidgetFolder.actions(item).filter { $0.title != "Open" && $0.title != "Quick Look" }, id: \.title) { action in
                    Button(action.title, action: action.run)
                }
            } label: { Image(systemName: "ellipsis").font(ink.ui(13, .semibold)).foregroundStyle(ink.text2).frame(width: 34, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .background(RoundedRectangle(cornerRadius: ink.radius(7), style: .continuous).strokeBorder(ink.line2))
                .help("More").accessibilityLabel("More")
        }
    }

    /// Reads where the selection rests: a short wait, cancelled by the next pick.
    /// The item's icon, then for a picture, a video or a document (not text, which shows its lines) QuickLook's
    /// thumbnail over it; both off the main thread and kept while the window is open.
    private func load(_ item: FolderItem) async {
        (picture, inspection, icon) = (nil, nil, nil)
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        let read = await Task.detached(priority: .userInitiated) { FilesInspection.read(item) }.value
        guard !Task.isCancelled else { return }
        inspection = read
        let look = read.preview?.look
        if look != .picture {
            let made = await model.picture(item.url, pixels: 256, icon: true)
            guard !Task.isCancelled else { return }
            icon = made
        }
        guard look == .picture || (look == .icon && FilesModel.thumbnails(item)) else { return }
        if let made = await model.picture(item.url, pixels: 640, modified: item.modified), !Task.isCancelled { picture = made }
    }
}

/// The toolbar's key help: every key the window takes (FilesView.keys and FilesContent.key), Finder's where it has one.
private struct FilesKeysHelp: View {
    @Environment(\.ink) private var ink

    static let keys: [(keys: String, does: String)] = [
        ("⌘-click", "Toggle a file in the selection"),
        ("⇧-click", "Select a range"),
        ("⌘A", "Select all"),
        ("Space", "Quick Look, again to close"),
        ("⌘K", "File actions"),
        ("⌘I", "Preview and info"),
        ("⌘↓  ⌘O", "Open"),
        ("⌘↑", "Enclosing folder"),
        ("⌘[  ⌘]", "Back, forward"),
        ("⇧⌘.", "Show or hide hidden files"),
        ("↩", "Rename"),
        ("⌘⌫", "Move to Trash"),
        ("⌘C", "Copy"),
        ("⌘X", "Cut, Esc to keep it"),
        ("⌘V", "Move what was cut here, else paste a copy"),
        ("⌥⌘V", "Move here"),
        ("⇧⌘N", "New folder"),
        ("⌥⌘N", "New file, from a template"),
        ("⌘L", "Type a path"),
        ("⌘Z", "Undo"),
        ("⌘F", "Search"),
        ("⌘1  ⌘2", "List, grid"),
        ("⌘N", "New window"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InstrumentEyebrow(text: "Keys").padding(.bottom, 3)
            ForEach(Self.keys, id: \.keys) { key in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(key.keys).font(ink.mono(12)).foregroundStyle(ink.text).frame(width: 78, alignment: .leading)
                    Text(key.does).font(ink.ui(12.5)).foregroundStyle(ink.text2)
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keys")
    }
}
