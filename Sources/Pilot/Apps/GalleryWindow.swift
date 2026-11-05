import AppKit
import Observation
import OSLog
import PilotCore
import PilotTiler
import SwiftUI

/// A folder as a gallery (P90, Sven Q746): its files as a grid of cards in a window of Pilot's own, images as QuickLook
/// thumbnails at the card's size, Markdown as its title and first lines, anything else as its icon and name; a size
/// slider, Name or Date, a filter. A click previews (FilePreviewWindow) or, opened on the wallpapers (the desktop's
/// Change wallpaper…, Look › Wallpaper's Browse as gallery), sets it as the wallpaper; a right-click has the
/// Folder widget's file actions and, for an image, Set as wallpaper. Read-only but for the wallpaper. The window, its
/// one folder watch and its thumbnails go with its close: nothing runs while it is closed.
@MainActor
final class GalleryWindow {
    static let shared = GalleryWindow()

    private var window: PilotWindow?
    private var model: GalleryModel?
    private var closeObserver: NSObjectProtocol?

    static let size = NSSize(width: 920, height: 640), minSize = NSSize(width: 520, height: 380)
    private static let autosaveName = "PilotGalleryWindow"

    /// The gallery on `folder`, or the open one moved there; `wallpaper` makes a click on an image set it, on the screen
    /// with display UUID `display` (else the window's), with `sources` in the folder menu.
    func open(_ folder: URL, wallpaper: Bool = false, display: String? = nil, sources: [URL] = []) {
        let model = model ?? {
            let made = GalleryModel(folder: folder)
            made.screen = { [weak self] in self?.window?.screen }
            return made
        }()
        model.show(folder, wallpaper: wallpaper, display: display, sources: sources)
        self.model = model
        let app = AppWindowController.shared
        app.applyDockIcon(.dock)
        if window == nil {
            let host = NSHostingView(rootView: GalleryView(model: model).styled(.window).pilotTheme().pilotWindowStyles())
            let w = AppWindowController.makeWindow(content: host, size: Self.size, minSize: Self.minSize)
            w.title = "Gallery"
            w.onQuit = { app.quit() }
            if !w.setFrameUsingName(Self.autosaveName) { w.center() }
            w.setFrameAutosaveName(Self.autosaveName)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(w) }
            }
            window = w
            followLook()
        }
        let shown = window?.isVisible == true
        window?.makeKeyAndOrderFront(nil)
        if !shown { TilerOwnWindows.shown() }
        WindowFocus.bringForward()
        galleryLog.notice("gallery open on \(folder.lastPathComponent, privacy: .public)\(wallpaper ? " (wallpaper)" : "", privacy: .public)")
    }

    /// The wallpapers as a gallery, a click setting one: the first folder that cycles on the screen with this display
    /// UUID (its workspace's own while it has some, as Next reads them), every other one in the folder menu; an image
    /// picked on its own brings its folder.
    func openWallpapers(display: String?, settings: WallpaperSettings = .shared) {
        let folders = WallpaperSettings.containingFolders(settings.urls(for: display))
        open(folders.first ?? WallpaperCycle.standardFolder, wallpaper: true, display: display, sources: folders)
    }

    /// Restyles the window as the theme, style or material changes, while it is open; one watch at a time, as the app
    /// window's (AppWindowController.followLook).
    private func followLook() {
        guard let window else { return }
        AppWindowController.applyLook(.shared, to: window)
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

    /// The window closed: its watch and thumbnails stop, and its tree goes on the run loop's next pass.
    private func closed(_ w: PilotWindow) {
        guard w === window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        model?.close()
        model = nil
        window = nil
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { w.contentView = nil } }
        galleryLog.notice("gallery closed")
    }
}

private let galleryLog = Logger(subsystem: "dev.banozz.pilot", category: "files")

/// What the gallery draws a card as, and its pure rules.
enum Gallery {
    enum Kind: Equatable, Sendable { case folder, image, markdown, other }

    /// The most items a folder lists; the line under the bar says when there were more.
    nonisolated static let cap = 2000
    /// The card widths the slider gives, in points.
    nonisolated static let widths: ClosedRange<Double> = 120...320

    nonisolated static func kind(_ item: FolderItem) -> Kind {
        if item.isFolder { return .folder }
        if WallpaperCycle.isImage(item.url) { return .image }
        return MarkdownHTML.isMarkdown(item.url) ? .markdown : .other
    }

    /// The items whose name holds `query`, any case; all of them for an empty one.
    nonisolated static func filter(_ items: [FolderItem], _ query: String) -> [FolderItem] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    /// A thumbnail's side in pixels for a card `points` wide: the next of four sizes up (Retina), so dragging the slider
    /// makes no new thumbnails until a card outgrows its size.
    nonisolated static func pixels(_ points: Double) -> Int {
        let wanted = Int(points * 2)
        return [320, 480, 640, 800].first { $0 >= wanted } ?? 800
    }

    /// A Markdown file's card: its first heading (else its file name) and its first lines of text, front matter and
    /// marks left out. At most `readLimit` bytes are read.
    struct MarkdownCard: Equatable, Sendable {
        let title: String
        let lines: [String]
    }

    nonisolated static let readLimit = 4096, cardLines = 6

    nonisolated static func markdownCard(_ url: URL) -> MarkdownCard {
        let name = url.deletingPathExtension().lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else { return MarkdownCard(title: name, lines: []) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: readLimit)) ?? Data()
        // A read cut inside a character loses that character, not the card, as FilePreview.lines reads.
        let text = (0...3).lazy.compactMap { String(data: data.dropLast($0), encoding: .utf8) }.first ?? ""
        return markdownCard(text, name: name)
    }

    /// Front matter cut, then Markdown's marks taken off as Read aloud takes them (Notes.words, through
    /// FileAction.speakable); a first line that is a heading is the title.
    nonisolated static func markdownCard(_ text: String, name: String) -> MarkdownCard {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        var words = FileAction.speakable(lines.joined(separator: "\n"), markdown: true).split(separator: "\n").map(String.init)
        let heading = lines.first { !$0.isEmpty }?.hasPrefix("#") == true
        let title = heading && !words.isEmpty ? words.removeFirst() : name
        return MarkdownCard(title: title, lines: Array(words.prefix(cardLines)))
    }
}

/// The gallery's folder, its listing, the card size, sort and filter, and its thumbnails, kept in memory while the
/// window is open (at most `pictureBytes`) and dropped as it closes.
@Observable @MainActor
final class GalleryModel {
    private(set) var folder: URL
    private var history: [URL] = []
    /// Opened on the wallpapers: a click on an image sets it.
    private(set) var picksWallpaper = false
    /// The screen a pick sets, by display UUID: the desktop's clicked one; nil is the window's.
    @ObservationIgnored private(set) var display: String?
    /// The wallpaper folders, listed in the folder menu.
    private(set) var sources: [URL] = []
    private(set) var items: [FolderItem] = [] { didSet { refilter() } }
    /// The items the filter keeps, worked out when the items or the filter change, not on every draw.
    private(set) var shown: [FolderItem] = []
    /// How many items the folder holds, past `Gallery.cap` too.
    private(set) var count = 0
    /// Why the folder did not read.
    private(set) var problem: String?
    var sort: FolderListing.Sort = .name { didSet { if sort != oldValue { reload() } } }
    var query = "" { didSet { if query != oldValue { refilter() } } }
    var cardWidth: Double = 180
    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { folder.path(percentEncoded: false) != "/" }
    private func refilter() { shown = Gallery.filter(items, query) }

    /// Makes a thumbnail; QuickLook in the app, a fake in tests.
    @ObservationIgnored var make: FileThumbnails.Make = FileThumbnails.quickLook
    /// The window's screen, for a pick with no display of its own.
    @ObservationIgnored var screen: () -> NSScreen? = { nil }
    /// Each file's thumbnail at the largest size made, by path.
    @ObservationIgnored private let pictures: NSCache<NSString, Picture> = {
        let cache = NSCache<NSString, Picture>()
        cache.totalCostLimit = GalleryModel.pictureBytes
        return cache
    }()
    /// Thumbnails being made, by path and size: a card that scrolls back in waits for the same one.
    @ObservationIgnored private var pending: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var cards: [String: Gallery.MarkdownCard] = [:]
    @ObservationIgnored private var changes: FolderChanges?
    @ObservationIgnored private var reading: Task<Void, Never>?

    static let pictureBytes = 96 << 20

    private final class Picture {
        let image: NSImage, pixels: Int
        init(_ image: NSImage, pixels: Int) { (self.image, self.pixels) = (image, pixels) }
    }

    init(folder: URL) { self.folder = folder.standardizedFileURL }

    /// Shows `folder`, a fresh history, in the mode the opener asked for.
    func show(_ folder: URL, wallpaper: Bool, display: String?, sources: [URL]) {
        picksWallpaper = wallpaper
        self.display = display
        self.sources = sources
        history = []
        move(to: folder.standardizedFileURL)
    }

    func go(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != folder else { return }
        history.append(folder)
        move(to: url)
    }

    func back() { if let last = history.popLast() { move(to: last) } }
    func up() { if canGoUp { go(folder.deletingLastPathComponent()) } }

    /// Choose folder…: any folder, shown here.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Show"
        panel.message = picksWallpaper ? "Pick a folder of wallpapers." : "Pick a folder to show as a gallery."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        go(url)
    }

    private func move(to url: URL) {
        folder = url
        query = ""
        reload()
        watch()
    }

    /// Reads the folder's own level off the main thread, as the sort says.
    func reload() {
        reading?.cancel()
        let folder = folder, sort = sort
        reading = Task {
            let read = await Task.detached(priority: .userInitiated) {
                Result { try FolderListing.list(folder, sort: sort, cap: Gallery.cap) }
            }.value
            guard !Task.isCancelled, folder == self.folder else { return }
            switch read {
            case .success(let listing):
                (items, count, problem) = (listing.items, listing.count, nil)
            case .failure(let error):
                (items, count, problem) = ([], 0, WidgetFolderModel.problem(error))
            }
        }
    }

    /// One watch on the shown folder's own entries: an image added, renamed or removed shows within a second.
    private func watch() {
        changes?.cancel()
        let watched = folder
        changes = FolderChanges(watched) { [weak self] gone in
            guard let self, self.folder == watched else { return }
            if gone { self.changes = nil }
            self.reload()
        }
    }

    /// The window closed: the watch, the read and every thumbnail go.
    func close() {
        reading?.cancel()
        changes?.cancel()
        changes = nil
        pending.values.forEach { $0.cancel() }
        pending = [:]
        pictures.removeAllObjects()
        cards = [:]
    }

    /// The card's thumbnail, `pixels` a side at most: one made at that size or larger is reused, and one being made is
    /// waited for, kept even when its card scrolled away meanwhile.
    func picture(_ url: URL, pixels: Int) async -> NSImage? {
        let path = url.path
        if let made = pictures.object(forKey: path as NSString), made.pixels >= pixels { return made.image }
        let key = "\(pixels) \(path)"
        let making = pending[key] ?? Task { [make] in
            guard let image = await make(url, pixels) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        }
        pending[key] = making
        let made = await making.value
        pending[key] = nil
        if let made, let image = made.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            pictures.setObject(Picture(made, pixels: pixels), forKey: path as NSString, cost: image.width * image.height * 4)
        }
        return made
    }

    /// A Markdown card's title and lines, read off the main thread once while the window is open.
    func card(_ url: URL) async -> Gallery.MarkdownCard {
        if let made = cards[url.path] { return made }
        let made = await Task.detached(priority: .userInitiated) { Gallery.markdownCard(url) }.value
        cards[url.path] = made
        return made
    }

    /// A click: a folder opens here; an image sets the wallpaper when opened on the wallpapers; anything else previews.
    func press(_ item: FolderItem) {
        switch Gallery.kind(item) {
        case .folder: go(item.url)
        case .image where picksWallpaper: setWallpaper(item.url)
        default: FilePreviewWindow.open(item.url)
        }
    }

    /// The image on the desktop's clicked screen, else the gallery window's: that workspace's while it cycles its own
    /// folders (WallpaperSwitch.set).
    func setWallpaper(_ url: URL) { WallpaperSwitch.set(url, display: display, fallback: screen()) }

    /// A card's right-click: Set as wallpaper and Preview for an image, Preview for any other file, then the Folder
    /// widget's file actions, a folder's Open as gallery opening it here.
    func actions(_ item: FolderItem) -> [(title: String, run: () -> Void)] {
        let url = item.url
        var own: [(title: String, run: () -> Void)] = []
        switch Gallery.kind(item) {
        case .image: own = [("Set as wallpaper", { [weak self] in self?.setWallpaper(url) }), ("Preview", { FilePreviewWindow.open(url) })]
        case .markdown, .other: own = [("Preview", { FilePreviewWindow.open(url) })]
        case .folder: own = [("Open as gallery", { [weak self] in self?.go(url) })]
        }
        // A folder's Open as gallery opens it here, keeping a wallpaper gallery's click.
        return own + WidgetFolder.actions(item).filter { $0.title != "Open as gallery" }
    }
}

/// The gallery's face: the bar (back, up, the folder menu, filter, sort, size) over the grid.
struct GalleryView: View {
    @Environment(\.ink) private var ink
    @Bindable var model: GalleryModel

    var body: some View {
        VStack(spacing: 0) {
            bar.padding(.leading, 78).padding(.trailing, 14).frame(height: 46)
            ink.line.frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ink.line.frame(height: 1)
            status.padding(.horizontal, 14).frame(height: 28)
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            barButton("chevron.left", "Back", on: model.canGoBack) { model.back() }
            barButton("arrow.up", "Enclosing folder", on: model.canGoUp) { model.up() }
            folderMenu
            Spacer(minLength: 8)
            SearchBox(prompt: "Filter", text: $model.query).frame(minWidth: 130, maxWidth: 200)
            Segments(selection: $model.sort, options: [(.name, "Name"), (.modified, "Date")], label: "Sort")
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3").font(ink.ui(10)).foregroundStyle(ink.muted)
                KitSlider(value: $model.cardWidth, range: Gallery.widths, label: "Card size", width: 90)
                Image(systemName: "square.grid.2x2").font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            .help("Card size")
        }
    }

    private func barButton(_ symbol: String, _ label: String, on: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(ink.ui(12, .semibold)).frame(width: 22, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain).foregroundStyle(on ? ink.text : ink.muted.opacity(0.6)).disabled(!on)
        .help(label).accessibilityLabel(label)
    }

    /// The folder's name; its menu lists the wallpaper folders, Choose folder… and Show in Finder.
    private var folderMenu: some View {
        Menu {
            ForEach(model.sources, id: \.path) { source in
                Button(FolderListing.shown(source)) { model.go(source) }
            }
            if !model.sources.isEmpty { Divider() }
            Button("Choose folder…") { model.choose() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder]) }
        } label: {
            Text(model.folder.lastPathComponent.isEmpty ? "/" : model.folder.lastPathComponent).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 280, alignment: .leading)
        .help(FolderListing.shown(model.folder))
    }

    @ViewBuilder private var content: some View {
        let shown = model.shown
        if let problem = model.problem {
            note(problem)
        } else if shown.isEmpty {
            note(model.items.isEmpty ? "This folder is empty." : "No file name holds “\(model.query)”.")
        } else {
            let width = model.cardWidth
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.6), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(shown) { item in
                        GalleryCard(item: item, model: model, faceHeight: (width * 0.66).rounded(), pixels: Gallery.pixels(width * 1.25))
                    }
                }
                .padding(14)
            }
        }
    }

    private func note(_ text: String) -> some View {
        EmptyState(title: text, action: ("Choose folder…", { model.choose() })).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: some View {
        HStack(spacing: 8) {
            Text(model.picksWallpaper ? "Click an image to make it the wallpaper" : "Click to preview, right-click for actions")
                .font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
            Spacer(minLength: 8)
            let shown = model.shown.count
            let counted = model.count == 1 ? "1 item" : "\(model.count) items"
            Text(shown == model.items.count ? counted : "\(shown) of \(counted)").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            if model.count > model.items.count {
                Text("· showing the first \(model.items.count)").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            }
        }
    }
}

/// One card: its face (a thumbnail, a Markdown file's title and lines, or the icon) over its name.
private struct GalleryCard: View {
    @Environment(\.ink) private var ink
    let item: FolderItem
    let model: GalleryModel
    let faceHeight: CGFloat
    let pixels: Int
    @State private var picture: NSImage?
    @State private var card: Gallery.MarkdownCard?
    @State private var icon: NSImage?
    @State private var hovered = false

    private struct Load: Equatable { let path: String, pixels: Int }

    var body: some View {
        let kind = Gallery.kind(item)
        VStack(alignment: .leading, spacing: 6) {
            face(kind)
                .frame(maxWidth: .infinity).frame(height: faceHeight)
                .clipShape(RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous).strokeBorder(ink.text.opacity(0.08)) }
            Text(item.name).font(ink.ui(12)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 2)
        }
        .padding(6)
        .background(hovered ? ink.selected : .clear, in: RoundedRectangle(cornerRadius: ink.radius(10), style: .continuous))
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .onTapGesture { model.press(item) }
        .onDrag { RecordingHandout.provider(for: item.url) }  // a recording with its pointer drawn in (Q821)
        .contextMenu { ForEach(model.actions(item), id: \.title) { action in Button(action.title, action: action.run) } }
        .help(item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
        .task(id: Load(path: item.url.path, pixels: kind == .image ? pixels : 0)) { await load(kind) }
    }

    @ViewBuilder private func face(_ kind: Gallery.Kind) -> some View {
        switch kind {
        case .image:
            ink.selected.overlay {
                if let picture {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(ink.ui(20)).foregroundStyle(ink.muted)
                }
            }
            .clipped()
        case .markdown:
            VStack(alignment: .leading, spacing: 4) {
                Text(card?.title ?? item.url.deletingPathExtension().lastPathComponent).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text)
                    .lineLimit(2)
                ForEach(Array((card?.lines ?? []).enumerated()), id: \.offset) { _, line in
                    Text(line).font(ink.ui(10.5)).foregroundStyle(ink.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ink.selected)
        case .folder, .other:
            ink.selected.overlay {
                if let icon { Image(nsImage: icon).resizable().frame(width: 56, height: 56) }
            }
        }
    }

    private func load(_ kind: Gallery.Kind) async {
        switch kind {
        case .image:
            if let made = await model.picture(item.url, pixels: pixels) { picture = made }
        case .markdown:
            card = await model.card(item.url)
        case .folder:
            if icon == nil { icon = NSWorkspace.shared.icon(forFile: item.url.path) }
        case .other:
            icon = AppsModule.icon(file: item.url.path)
        }
    }
}
