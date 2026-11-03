import AppKit
import ImageIO
import PilotCore
import SwiftUI

/// Look › Wallpaper (story 160, Sven 2026-10-10: "where do I even set which wallpapers cycle?"): each screen with its
/// wallpaper now, its place in the cycle and Previous and Next; the folders and images that cycle as chips with Add and
/// Reset, the same for every screen or each screen its own (Sven 2026-10-17), under its row; workspaces on their screen's
/// folders or each its own (Sven 2026-10-19, Q333), a row per workspace; Browse as gallery (P90); By name or Shuffle; the screen in front or every screen; and Change on its own. Self-contained, so the layout
/// rework can move it; it reads the screens on appear and after every step.
struct WallpaperBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: WallpaperSettings
    /// Each screen and its wallpaper now; a render passes its own and nothing is read.
    @State private var screens: [WallpaperScreen]
    @State private var count: Int?
    private let reads: Bool
    let nicknames: DisplayNicknames
    /// The workspaces with a row while each can have its own folders; nil reads Pilot's list.
    private let names: [String]?
    /// The row the desktop's Hyper + right-click › Wallpaper settings… asked for, and the row it lights a moment.
    let focus: Focus?
    @State private var lit: Lit?
    private enum Lit: Equatable { case screen(String), workspace(String) }

    /// A screen by its display UUID, and the workspace it shows (Q333): that workspace's row lights while each workspace
    /// has its own, else the screen's.
    struct Focus: Equatable {
        let display: String?, workspace: String?
    }

    init(settings: WallpaperSettings = .shared, screens: [WallpaperScreen]? = nil, count: Int? = nil, nicknames: DisplayNicknames = .shared,
         workspaces: [String]? = nil, focus: Focus? = nil) {
        self.settings = settings
        self.nicknames = nicknames
        names = workspaces
        self.focus = focus
        _screens = State(initialValue: screens ?? [])
        _count = State(initialValue: count)
        reads = screens == nil
    }

    enum Info {
        static let images = "Folders cycle every image inside them and their subfolders; an image you add cycles on its own. Each screen only gets images of its own shape, unless none fit or Only images that fit the screen is off."
        static let shared = "Screens without folders of their own cycle these. " + images
        static let folders = "The same folders on every screen, or each screen its own, picked under its row. A screen without its own uses the shared ones."
        static let fit = "On, a portrait screen steps through tall images and a wide screen through wide ones, all of them when none fit. Off, every screen steps through every image; a wide one shows its middle on a portrait screen."
        static let own = "This screen's own folders and images. With none, it uses the shared ones; Reset goes back to them."
        static let workspaces = "Every workspace shows its screen's wallpaper, or each workspace its own, picked under Workspaces. Switching to a workspace with its own puts the image it last showed back on its screen; one without gets the screen's usual wallpaper back."
        static let workspaceOwn = "This workspace's own folders and images, cycled on its screen while it shows. With none, it uses its screen's; Reset goes back to them."
        static let order = "By name steps in file-name order. Shuffle mixes them once and keeps that order, so Previous goes back; Shuffle again mixes anew."
        static let scope = "Which screens Next wallpaper and Previous change: the one the window in front is on, or every screen at once."
        static let interval = "Steps every screen to its next image on its own. Waits while the screen is locked or asleep."
        static let screen = "This screen's wallpaper now and, dimmed, the one Next gives. Previous and Next step this screen alone."
    }

    var body: some View {
        KitBlock(title: "Wallpaper", symbol: "photo.on.rectangle",
                 note: "What Next wallpaper and Previous step through, and when the wallpaper changes on its own.") {
            BindKey(action: "system.nextWallpaper")
        } content: {
            ForEach(Array(screens.enumerated()), id: \.element.id) { i, screen in
                BlockRow(first: i == 0) { screenRow(screen) }.focusBorder(on: screen.displayUUID.map { lit == .screen($0) } ?? false, radius: ink.style.radii.control)
            }
            BlockRow(first: screens.isEmpty) {
                label("Folders", Info.folders)
                Segments(selection: $settings.folders, options: [(.shared, "Same for every screen"), (.perScreen, "Each screen its own")],
                         label: "Folders")
            }
            BlockRow {
                label("Workspaces", Info.workspaces)
                Segments(selection: $settings.workspaces, options: [(.shared, "Same as global"), (.perWorkspace, "Per workspace")],
                         label: "Workspaces")
            }
            if settings.workspaces == .perWorkspace {
                ForEach(workspaceNames, id: \.self) { workspace in
                    BlockRow { workspaceRow(workspace) }.focusBorder(on: lit == .workspace(workspace), radius: ink.style.radii.control)
                }
            }
            BlockRow {
                label("Only images that fit the screen", Info.fit)
                Toggle("Only images that fit the screen", isOn: $settings.fitShape).toggleStyle(.pilotSwitch).labelsHidden()
            }
            BlockRow { sourcesRow }
            BlockRow {
                label("Order", Info.order)
                if settings.order == .shuffle {
                    Button("Shuffle again") { settings.shuffleAgain() }.buttonStyle(.pilot)
                }
                Segments(selection: $settings.order, options: [(.name, "By name"), (.shuffle, "Shuffle")], label: "Order")
            }
            BlockRow {
                label("Screens", Info.scope)
                Segments(selection: $settings.scope, options: [(.focusedScreen, "Screen in front"), (.everyScreen, "Every screen")], label: "Screens")
            }
            BlockRow {
                label("Change on its own", Info.interval)
                Picker("Change on its own", selection: $settings.interval) {
                    ForEach(WallpaperCycle.intervals, id: \.self) { Text(WallpaperCycle.intervalName($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .task(id: Reading(urls: settings.urls, folders: settings.folders, own: settings.screenSources, workspaces: settings.workspaces,
                          workspaceOwn: settings.workspaceSources, fit: settings.fitShape, order: settings.order, seed: settings.seed)) {
            if reads { await read() }
        }
        .onReceive(NotificationCenter.default.publisher(for: WallpaperSwitch.changed)) { _ in
            if reads { Task { await read() } }
        }
        .onChange(of: focus, initial: true) { lit = focus.flatMap(row) }
        .task(id: lit) {
            guard lit != nil, (try? await Task.sleep(for: ExtensionsPageView.litFor)) != nil else { return }
            withAnimation(Kit.change) { lit = nil }
        }
    }

    /// The row `focus` lights: its workspace's while each workspace has its own and that one has a row, else its screen's.
    private func row(_ focus: Focus) -> Lit? {
        if settings.workspaces == .perWorkspace, let workspace = focus.workspace, workspaceNames.contains(workspace) {
            return .workspace(workspace)
        }
        return focus.display.map(Lit.screen)
    }

    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoMark(text: info)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func screenRow(_ screen: WallpaperScreen) -> some View {
        let unique = screens.filter { $0.displayUUID == screen.displayUUID }.count == 1
        let label = nicknames.label(systemName: screen.name, displayUUID: unique ? screen.displayUUID : nil)
        return VStack(alignment: .leading, spacing: 6) {
            screenLine(screen, label: label)
            if settings.folders == .perScreen { ownSources(screen) }
        }
        .padding(.vertical, 6)
    }

    private func screenLine(_ screen: WallpaperScreen, label: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                picture(screen.thumb, portrait: screen.portrait)
                // What Next gives, dimmed (Sven 2026-10-10: "so he sees what Next will give").
                if let next = screen.next {
                    picture(next, portrait: screen.portrait).opacity(0.45)
                        .help(screen.nextName.map { "Next: \($0)" } ?? "Next")
                        .accessibilityLabel(screen.nextName.map { "Next wallpaper: \($0)" } ?? "Next wallpaper")
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) { Text(label).lineLimit(1).help(label); InfoMark(text: Info.screen) }
                Text(screen.detail).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { step(screen, forward: false) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.pilot).accessibilityLabel("Previous wallpaper on \(label)").help("Previous wallpaper")
            Button { step(screen, forward: true) } label: { Text("Next") }
                .buttonStyle(.pilot).accessibilityLabel("Next wallpaper on \(label)")
        }
    }

    /// The screen's own folders as chips with Reset and Add…, or that it uses the shared ones.
    private func ownSources(_ screen: WallpaperScreen) -> some View {
        let own = screen.displayUUID.map(settings.ownSources) ?? []
        return ownLine(own, info: Info.own, display: screen.displayUUID,
                       none: screen.displayUUID == nil ? "The shared folders: macOS gives this screen no lasting id" : "The shared folders")
    }

    /// A workspace's name with its own folders as chips with Reset and Add…, or that it uses its screen's.
    private func workspaceRow(_ workspace: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Engine.shared?.presets.contents.title(for: workspace) ?? WorkspacePreset.unnamed(workspace)).lineLimit(1)
                .frame(width: 96, alignment: .leading)
            ownLine(settings.workspaceOwn(workspace), info: Info.workspaceOwn, workspace: workspace, none: "The screen's folders")
        }
        .padding(.vertical, 6)
    }

    /// "Images from" with `own` as chips, or `none` when it has none, and Reset and Add… for a screen or workspace.
    private func ownLine(_ own: [String], info: String, display: String? = nil, workspace: String? = nil, none: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 6) {
                Text("Images from").font(ink.ui(12)).foregroundStyle(ink.muted)
                InfoMark(text: info)
            }
            Group {
                if own.isEmpty {
                    Text(none).font(ink.ui(12)).foregroundStyle(ink.muted)
                } else {
                    chips(own, display: display, workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if display != nil || workspace != nil {
                if !own.isEmpty {
                    Button("Reset") { withAnimation(Kit.change) { settings.reset(display: display, workspace: workspace) } }.buttonStyle(.pilot)
                }
                Button("Add…") { add(display: display, workspace: workspace) }.buttonStyle(.pilot)
            }
        }
    }

    /// Pilot's workspaces, or the ones a render passes.
    private var workspaceNames: [String] { names ?? Engine.shared?.workspaceList.names ?? Workspaces.kept(in: .pilot()) }

    private func chips(_ paths: [String], display: String?, workspace: String? = nil) -> some View {
        Flow(spacing: 6, lineSpacing: 6) {
            ForEach(paths, id: \.self) { path in
                Chip(text: Self.chipName(path), symbol: WallpaperCycle.isImage(URL(filePath: path)) ? "photo" : "folder", tag: true) {
                    withAnimation(Kit.change) { settings.remove(path, display: display, workspace: workspace) }
                }
                .help(path)
            }
        }
    }

    private func picture(_ image: NSImage?, portrait: Bool) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(ink.muted)
            }
        }
        .frame(width: portrait ? 30 : 72, height: 44).clipShape(.rect(cornerRadius: ink.radius(4)))
        .overlay { RoundedRectangle(cornerRadius: ink.radius(4)).strokeBorder(ink.text.opacity(0.12)) }
    }

    private var sourcesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if settings.folders == .shared { label("Images from", Info.images) } else { label("Shared folders", Info.shared) }
                if let count { Text(count == 1 ? "1 image" : "\(count) images").font(ink.ui(12)).foregroundStyle(ink.muted) }
                if !settings.isStandard { Button("Reset") { withAnimation(Kit.change) { settings.reset() } }.buttonStyle(.pilot) }
                Button("Browse as gallery") { GalleryWindow.shared.openWallpapers(display: focus?.display) }.buttonStyle(.pilot)
                    .help("The wallpaper folders as a grid of pictures: click one to make it the wallpaper.")
                Button("Add…") { add(display: nil) }.buttonStyle(.pilot)
            }
            chips(settings.sources, display: nil)
            if settings.sources.isEmpty {
                Text("None picked: ~/Pictures/Wallpapers cycles.").font(ink.ui(12)).foregroundStyle(ink.muted)
            }
        }
        .padding(.vertical, 8)
    }

    /// A folder by its path from home, an image by its file name.
    static func chipName(_ path: String) -> String {
        WallpaperCycle.isImage(URL(filePath: path)) ? URL(filePath: path).lastPathComponent : AppConfigs.tilde(path, home: NSHomeDirectory())
    }

    /// Adds to the shared folders, or to the screen with this display UUID's own, or to the workspace's own.
    private func add(display: String?, workspace: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .folder]
        panel.allowsMultipleSelection = true
        panel.directoryURL = WallpaperCycle.standardFolder.deletingLastPathComponent()
        panel.prompt = "Add"
        panel.message = "Pick folders of wallpapers, or single images."
        guard panel.runModal() == .OK else { return }
        settings.add(panel.urls, display: display, workspace: workspace)
    }

    private func step(_ screen: WallpaperScreen, forward: Bool) {
        guard let target = NSScreen.screens.first(where: { WallpaperScreen.number($0) == screen.id }) else { return }
        WallpaperSwitch.step(forward: forward, screens: [target], settings: settings)
    }

    private struct Reading: Equatable {
        let urls: [URL]
        let folders: WallpaperCycle.Folders
        let own: [String: [String]]
        let workspaces: WallpaperCycle.Workspaces
        let workspaceOwn: [String: [String]]
        let fit: Bool
        let order: WallpaperCycle.Order
        let seed: UInt64
    }

    /// Lists each set of folders once, then each screen's wallpaper, its place, a small picture of it and of the one Next gives,
    /// all off the main thread. The wallpaper is the one a step just set, not macOS's read, which trails it.
    private func read() async {
        let shared = settings.urls, order = settings.order, seed = settings.seed, fit = settings.fitShape
        let now = NSScreen.screens.map { screen in
            let display = DisplayIdentity.uuid(of: screen)
            return (id: WallpaperScreen.number(screen) ?? 0, name: screen.localizedName, shape: WallpaperSwitch.shape(of: screen),
                    current: WallpaperSwitch.current(on: screen), displayUUID: display, urls: settings.urls(for: display))
        }
        let result = await Task.detached {
            let lists = WallpaperSettings.imageLists(now.map(\.urls) + [shared], order: order, seed: seed)
            let shape = WallpaperSwitch.shapes.shape
            let rows = now.map { screen in
                let images = lists[screen.urls] ?? []
                let place = WallpaperCycle.place(of: screen.current, in: images, shape: shape, screen: screen.shape, fit: fit)
                let next = WallpaperCycle.step(images, shape: shape, screen: screen.shape, fit: fit, current: screen.current, forward: true)?.url
                return WallpaperScreen(id: screen.id, name: screen.name, portrait: screen.shape == .portrait,
                                       detail: WallpaperScreen.detail(current: screen.current, place: place),
                                       thumb: screen.current.flatMap { WallpaperScreen.thumbnail($0) },
                                       next: next.flatMap { WallpaperScreen.thumbnail($0) },
                                       nextName: next?.deletingPathExtension().lastPathComponent, displayUUID: screen.displayUUID)
            }
            return (rows, lists[shared]?.count ?? 0)
        }.value
        guard !Task.isCancelled else { return }
        screens = result.0
        count = result.1
    }
}

/// One screen in the Wallpaper block: its name, its wallpaper now and where that sits in the cycle.
struct WallpaperScreen: Identifiable, @unchecked Sendable {
    let id: UInt32
    let name: String
    let portrait: Bool
    /// "dunes.jpg · 3 of 12", or why it is not in the cycle.
    let detail: String
    let thumb: NSImage?
    /// The image Next gives, and its name.
    let next: NSImage?
    let nextName: String?
    let displayUUID: String?

    nonisolated init(id: UInt32, name: String, portrait: Bool, detail: String, thumb: NSImage?, next: NSImage?, nextName: String?, displayUUID: String? = nil) {
        self.id = id
        self.name = name
        self.portrait = portrait
        self.detail = detail
        self.thumb = thumb
        self.next = next
        self.nextName = nextName
        self.displayUUID = displayUUID
    }

    nonisolated static func detail(current: URL?, place: (place: Int, count: Int)?) -> String {
        guard let current else { return "No wallpaper file" }
        let name = current.lastPathComponent
        return place.map { "\(name) · \($0.place) of \($0.count)" } ?? "\(name) · not in the cycle"
    }

    nonisolated static func number(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A 160 px picture of the image from its file, made once per file: a step's new image was the last read's next one.
    nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let made = thumbnails.object(forKey: key) { return made }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
        else { return nil }
        let made = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(made, forKey: key)
        return made
    }

    nonisolated(unsafe) private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 16
        return cache
    }()
}
