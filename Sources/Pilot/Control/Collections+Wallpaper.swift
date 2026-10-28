import AppKit
import PilotCore

/// Look › Wallpaper from the pilot command (W19): the folders and images that cycle, each screen's wallpaper with its
/// place and what Next gives, Previous and Next per screen, Shuffle again and Reset, through the store the block binds
/// to; with `--screen`, a screen's own folders, with `--workspace`, a workspace's. Order, screens, folders, workspaces and
/// interval are `pilot set wallpaper.*`. Needs no engine.
@MainActor
struct WallpaperControl {
    /// One screen as the block lists it.
    struct Screen: Sendable {
        let id: UInt32
        let name: String
        let shape: WallpaperCycle.Shape
        let current: URL?
        var displayUUID: String? = nil
    }

    var settings: WallpaperSettings = .shared
    var nicknames: DisplayNicknames = .shared
    /// The screens and their wallpapers now; a test passes its own, so nothing reads or sets Sven's.
    var screens: @MainActor () -> [Screen] = {
        NSScreen.screens.map { Screen(id: WallpaperScreen.number($0) ?? 0, name: $0.localizedName, shape: WallpaperSwitch.shape(of: $0),
                                      current: WallpaperSwitch.current(on: $0), displayUUID: DisplayIdentity.uuid(of: $0)) }
    }
    /// Next or Previous on the screens with these ids, as the block's buttons step one; nil steps the ones
    /// wallpaper.scope names, as the key does.
    var step: @MainActor (_ forward: Bool, _ ids: [UInt32]?) -> Void = { forward, ids in
        guard let ids else { return WallpaperSwitch.step(forward: forward) }
        WallpaperSwitch.step(forward: forward, screens: NSScreen.screens.filter { WallpaperScreen.number($0).map(ids.contains) ?? false })
    }
    /// A step lists the images first, so it is watched a little longer than a run.
    var readback = RunReadback(wait: .seconds(2))
    /// Asks before a source outside ~/Pictures is read: Pilot reads with Full Disk Access (Sven, W19 v2, as W5 and W15).
    var gate = AllowPrompt.gate
    /// The folder whose sources are added without asking, compared with every link resolved.
    var pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]

    /// Each screen's wallpaper, its place in its own cycle, the image Next gives and the folders it cycles, as the block's
    /// rows show them; the images are listed off the main thread.
    func screenRows() async -> [JSONValue] {
        let order = settings.order, seed = settings.seed, fit = settings.fitShape, now = screens()
        let lists = now.map { settings.urls(for: $0.displayUUID) }
        let own = now.map { screen in screen.displayUUID.map(settings.ownSources) ?? [] }
        let labels = now.map { screen in
            let unique = now.filter { $0.displayUUID == screen.displayUUID }.count == 1
            return nicknames.label(systemName: screen.name, displayUUID: unique ? screen.displayUUID : nil)
        }
        return await Task.detached {
            let listed = WallpaperSettings.imageLists(lists, order: order, seed: seed), shape = WallpaperSwitch.shapes.shape
            return now.enumerated().map { index, screen -> JSONValue in
                let images = listed[lists[index]] ?? []
                let place = WallpaperCycle.place(of: screen.current, in: images, shape: shape, screen: screen.shape, fit: fit)
                let next = WallpaperCycle.step(images, shape: shape, screen: screen.shape, fit: fit, current: screen.current, forward: true)?.url
                var row: [String: JSONValue] = ["screen": .string(screen.name), "label": .string(labels[index]),
                                "id": .number(Double(screen.id)), "portrait": .bool(screen.shape == .portrait),
                                "current": screen.current.map { .string($0.path) } ?? .null,
                                "place": place.map { .number(Double($0.place)) } ?? .null, "count": place.map { .number(Double($0.count)) } ?? .null,
                                "detail": .string(WallpaperScreen.detail(current: screen.current, place: place)),
                                "next": next.map { .string($0.path) } ?? .null,
                                "sources": .array(lists[index].map { .string($0.path) }), "ownSources": .array(own[index].map(JSONValue.string))]
                if let uuid = screen.displayUUID { row["displayUUID"] = .string(uuid) }
                return .object(row)
            }
        }.value
    }

    /// The picked folders and images with how many images each holds, counted off the main thread: the shared ones, or
    /// the screen with this display UUID's own, or the workspace's own.
    func sourceRows(display: String? = nil, workspace: String? = nil) async -> [JSONValue] {
        let sources = settings.sources(for: display, workspace: workspace)
        return await Task.detached { sources.map(Self.sourceRow) }.value
    }

    /// The screen `--screen` names, by name or id.
    func screen(_ name: String) throws(ControlError) -> Screen {
        let screens = screens()
        guard let screen = screens.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || String($0.id) == name }) else {
            throw ControlError(.badValue, "--screen is one of \(screens.map(\.name).joined(separator: ", ")), not \(name)")
        }
        return screen
    }

    /// The display UUID of the screen `--screen` names, which its own folders are kept by; nil with no --screen.
    func display(_ args: ControlArguments) throws(ControlError) -> String? {
        guard let name = args.value("screen") else { return nil }
        guard args.value("workspace") == nil else { throw ControlError(.badValue, "--screen or --workspace, not both") }
        let screen = try screen(name)
        guard let uuid = screen.displayUUID else { throw ControlError(.badValue, "\(screen.name) has no lasting id from macOS: it takes the shared folders") }
        return uuid
    }

    /// The workspace `--workspace` names, by its number, whose own folders an edit changes; nil with no --workspace.
    func workspace(_ args: ControlArguments) throws(ControlError) -> String? {
        guard let name = args.value("workspace") else { return nil }
        let kept = Workspaces.kept(in: .pilot())
        guard kept.contains(name) else { throw ControlError(.badValue, "--workspace is one of \(kept.joined(separator: ", ")), not \(name)") }
        return name
    }

    nonisolated static func sourceRow(_ path: String) -> JSONValue {
        let url = URL(filePath: path), image = WallpaperCycle.isImage(url)
        return .object(["path": .string(path), "name": .string(WallpaperBlock.chipName(path)), "kind": .string(image ? "image" : "folder"),
                        "images": .number(Double(WallpaperCycle.images(in: [url]).count))])
    }

    /// A path typed full or from ~, standardized as the sources keep it; nil for a relative one, which Pilot would read
    /// against its own folder.
    static func full(_ typed: String) -> String? {
        let expanded = (typed as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(filePath: expanded).standardizedFileURL.path : nil
    }

    /// `path` with every link resolved (realpath); nil when it is not there.
    nonisolated static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The question adding `path` asks before anything reads it, nil when it resolves to inside ~/Pictures. A path not
    /// there resolves to nothing, so it asks too: whether it exists is looked at only after Allow. Read again after the
    /// Allow, so a link changed while asking denies.
    func addAsk(_ path: String) -> ControlGate.Ask? {
        if let real = Self.real(path), let home = Self.real(pictures.path),
           URL(filePath: real).pathComponents.starts(with: URL(filePath: home).pathComponents) { return nil }
        let image = WallpaperCycle.isImage(URL(filePath: path))
        return ControlGate.Ask(image ? "Add wallpaper image" : "Add wallpaper folder",
                               "Pilot reads \(ControlGate.Ask.visible(Self.real(path) ?? path)) and cycles \(image ? "it" : "its images"); its image names and count come back")
    }

    /// A source as the block's Add… panel gives one, after Allow when outside ~/Pictures: a folder or an image file that
    /// is there, kept with its links resolved, so what cycles is what was asked about.
    func source(_ typed: String, peer: ControlPeer?) async throws(ControlError) -> String {
        guard let path = Self.full(typed) else { throw ControlError(.badValue, "\(typed) is not a full path: give it from / or ~/") }
        try await gate.allow(addAsk(path), peer: peer) { () throws(ControlError) in }
        var isFolder: ObjCBool = false
        guard let real = Self.real(path), FileManager.default.fileExists(atPath: real, isDirectory: &isFolder),
              isFolder.boolValue || WallpaperCycle.isImage(URL(filePath: real)) else {
            throw ControlError(.badValue, "\(typed) is neither a folder nor an image: give the full path (or ~/…) of one that exists")
        }
        return URL(filePath: real).standardizedFileURL.path
    }
}

extension ControlVerbs {
    /// `wallpaper-sources`, `wallpaper-screens` and `pilot wallpaper next|previous|shuffle|reset`.
    func registerWallpaper(_ app: WallpaperControl = WallpaperControl()) {
        let settings = app.settings
        register(ControlCollection(
            "wallpaper-sources", help: "The folders and images Next wallpaper cycles (Look › Wallpaper), each with its image count; "
                + "with none, ~/Pictures/Wallpapers cycles. add asks Allow unless the path, links resolved, is inside ~/Pictures. "
                + "pilot wallpaper reset puts ~/Pictures/Wallpapers back alone. --screen <name or id> adds and removes that "
                + "screen's own, which it cycles while wallpaper.folders is perScreen; wallpaper-screens lists them. --workspace <number> "
                + "adds and removes that workspace's own, shown on its screen while wallpaper.workspaces is perWorkspace.",
            fields: [.init("path", help: "a folder (its images and its subfolders' cycle) or one image, full path or ~/…"),
                     .init("screen", help: "a screen by name or id (pilot list wallpaper-screens): its own folders, not the shared ones", required: false),
                     .init("workspace", help: "a workspace by number: its own folders, not the shared ones", required: false)],
            rowKey: "path", asks: [.add],
            list: { .array(await app.sourceRows()) },
            askerAdd: { args, peer throws(ControlError) in
                let display = try app.display(args), workspace = try app.workspace(args)
                let path = try await app.source(args.value("path")!, peer: peer)
                settings.add([URL(filePath: path)], display: display, workspace: workspace)
                return await Task.detached { WallpaperControl.sourceRow(path) }.value
            },
            askerRemove: { args, _ throws(ControlError) in
                let word = try args.word(0, "path")
                let display = try app.display(args), workspace = try app.workspace(args)
                let sources = settings.sources(for: display, workspace: workspace)
                // As typed, or as it was kept: standardized, with its links resolved.
                let full = WallpaperControl.full(word), real = full.flatMap(WallpaperControl.real).map { URL(filePath: $0).standardizedFileURL.path }
                guard let path = sources.first(where: { $0 == word || $0 == full || $0 == real }) else {
                    throw ControlError(.badValue, "no wallpaper source \(word); there are \(sources.isEmpty ? "none" : sources.joined(separator: ", "))")
                }
                settings.remove(path, display: display, workspace: workspace)
                return .string(path)
            }))
        register(ControlCollection(
            "wallpaper-screens", help: "Each screen's wallpaper, its place in its cycle, the image Next gives, the folders it cycles and "
                + "its own (Look › Wallpaper); read-only.",
            rowKey: "screen", list: { .array(await app.screenRows()) }))

        let help = [
            ("next", "pilot wallpaper next [--screen <name or id>]: the next image on that screen, as its Next button; with no --screen, on the screens wallpaper.scope names, as the key does. Answers the tip and every screen's row after."),
            ("previous", "pilot wallpaper previous [--screen <name or id>]: the image before, as the chevron does."),
            ("shuffle", "pilot wallpaper shuffle: Shuffle again, mixing the order anew; only while wallpaper.order is shuffle."),
            ("reset", "pilot wallpaper reset [--screen <name or id> | --workspace <number>]: Reset, ~/Pictures/Wallpapers alone again, or that screen back on the shared folders, or that workspace back on its screen's; answers its sources."),
        ]
        let words = help.map(\.0), detail = Dictionary(uniqueKeysWithValues: help)
        let subcommands: @Sendable @MainActor () -> JSONValue = { .object(["subcommands": .array(words.map(JSONValue.string))]) }
        register(ControlVerb("wallpaper", help: "Steps a screen's wallpaper, shuffles the cycle again or resets its folders, as Look › Wallpaper does.",
                             usage: "pilot wallpaper next|previous [--screen <name or id>] | shuffle | reset [--screen <name or id> | --workspace <number>]",
                             flags: [.init("screen", help: "next, previous and reset only: the screen, by name or id (pilot list wallpaper-screens)"),
                                     .init("workspace", help: "reset only: the workspace, by number")],
                             schema: subcommands, index: subcommands, detail: { detail[$0] }) { call throws(ControlError) in
            let args = call.arguments()
            let word = try args.word(0, words.joined(separator: ", "))
            if !["next", "previous", "reset"].contains(word), let refusal = ControlVerb.unknownFlag(args.flags, known: [], in: "pilot wallpaper \(word)") {
                throw refusal
            }
            switch word {
            case "next", "previous":
                let ids = try args.value("screen").map { name throws(ControlError) in [try app.screen(name).id] }
                let tips = await app.readback.watch { app.step(word == "next", ids) }
                return .object(["hud": Self.hud(tips), "screens": .array(await app.screenRows())])
            case "shuffle":
                guard settings.order == .shuffle else {
                    throw ControlError(.badValue, "Shuffle again mixes a shuffled order; wallpaper.order is \(settings.order.rawValue) (pilot set wallpaper.order shuffle)")
                }
                settings.shuffleAgain()
                return .object(["screens": .array(await app.screenRows())])
            case "reset":
                let display = try app.display(args), workspace = try app.workspace(args)
                settings.reset(display: display, workspace: workspace)
                return .array(await app.sourceRows(display: display, workspace: workspace))
            default:
                throw ControlError(.badRequest, "pilot wallpaper \(words.joined(separator: ", ")), not \(word)")
            }
        })
    }
}
