import AppKit
import OSLog
import PilotCore
import UniformTypeIdentifiers
import WebApps

let alog = Logger(subsystem: "dev.banozz.pilot", category: "apps")

/// Apps by role, any app, web apps, the menu, emoji and clipboard (SPEC.md stories 17 to 21). LaunchServices,
/// never a posted key into another app.
@MainActor
enum AppsModule {
    static func id(_ name: String) -> String { "apps.\(name)" }
    /// Hyper+Space: the id stays apps.launcher, so binds.json files keep their row.
    static let menuID = id("launcher")

    /// `show` opens a place in Pilot's window; a test passes a fake.
    static func register(into registry: inout ActionRegistry,
                         show: @escaping @Sendable @MainActor (AppPlace) -> Void = { AppWindowController.shared.open($0) }) {
        // Today's Hammerspoon keys (My binds); Hyper+B is Zen itself there (MyBinds), so the browser role has no key.
        let roles: [(AppRole, Key?)] = [
            (.terminal, Key("return")), (.browser, nil), (.files, Key("f")), (.notes, nil), (.music, nil),
            (.mail, nil), (.calendar, nil), (.messages, nil), (.passwords, Key("p")), (.activityMonitor, nil),
            (.editor, Key("n")),   // Hammerspoon's Hyper+N opened VS Code by name
            (.ai, nil), (.agent, nil),
        ]
        for (role, key) in roles {
            add(&registry, role.rawValue, role.label, key) {
                let value = resolved(role)
                if role == .notes && value == AppRolePicks.pilot { return NotesPanel.shared.toggle() }
                let ok: Bool
                switch role.target(value) {
                case .web(let url): openWeb(url); ok = true
                case .command(let command): ok = openAgent(command)
                case .app(let bundle): ok = role == .terminal ? newTerminalWindow(bundle) : open(bundle: bundle)
                }
                alog.notice("\(role.rawValue, privacy: .public) → \(value, privacy: .public) \(ok ? "opened" : "not installed", privacy: .public)")
            }
        }
        add(&registry, "launcher", "Pilot menu", Key("space")) { PilotMenu.shared.toggle() }
        add(&registry, "appsMenu", "Apps menu", nil) { PilotMenu.shared.toggle(branch: .apps) }
        // Command-Tab's next and previous app, no switcher shown (Arrows preset, Sven's Q439).
        AppOrder.shared.start()
        add(&registry, "nextApp", "Next app", nil, keywords: AppOrder.keywords) { AppOrder.shared.switchApp(next: true) }
        add(&registry, "previousApp", "Previous app", nil, keywords: AppOrder.keywords) { AppOrder.shared.switchApp(next: false) }
        // The menu's own emoji grid (P39), no longer Apple's Character Viewer behind a posted Ctrl+Cmd+Space.
        add(&registry, "emoji", "Emoji picker", Key("e")) { PilotMenu.shared.toggle(branch: .emoji) }
        add(&registry, "clipboard", "Clipboard history", Key("v")) { ClipboardHistory.shared.toggle() }
        // ClipBook's Option+V, either side, carried before it goes (card agent-bo-95422770); Hyper+V stays, and a bind holds
        // one key, so it is the same panel a second time, as the vim pair repeats focus.
        add(&registry, "clipboardOptionV", "Clipboard history, Option+V", Key("v", .alt, hyper: false)) { ClipboardHistory.shared.toggle() }
        // Paste as plain text from any app (card agent-bo-95423072); Hyper+Alt+V is free in My binds and the Omarchy preset.
        add(&registry, "pastePlain", "Paste as plain text", Key("v", .alt)) { ClipboardHistory.shared.pastePlain() }
        add(&registry, "webApp", "Make a web app", nil) { show(AppPlace(.webApps)) }
        // Every Update and Clean run, kept (story 153); Update's and Clean's own Reports rows open it too.
        add(&registry, "reports", "Update and Clean reports", nil) { show(AppPlace(.reports)) }
        add(&registry, "lazygit", "lazygit: pick a repo", Key("g", .shift)) { pickRepo() }
        // Vicinae's Bitwarden extension, rebuilt (card agent-bo-95422774): the app's own menu items and bw generate. Pilot
        // never unlocks the vault and never sees, says or logs an item or a password.
        add(&registry, "bitwardenSearch", "Bitwarden: search vault", nil) { bitwarden(Bitwarden.search, front: true) }
        add(&registry, "bitwardenGenerator", "Bitwarden: password generator", nil) { bitwarden(Bitwarden.generator, front: true) }
        add(&registry, "bitwardenLock", "Bitwarden: lock all vaults", nil) { bitwarden(Bitwarden.lock, front: false) }
        // Card agent-bo-95422814: the logins for the page in front, typed into its focused field; when bw is locked, a
        // visible terminal unlocks it and Pilot keeps the session in memory only, until forgotten or Pilot quits.
        add(&registry, "bitwardenFill", "Bitwarden: fill login", nil) { BitwardenFillAction.run() }
        add(&registry, "bitwardenForget", "Bitwarden: forget the fill session", nil) { BitwardenFillAction.forget() }
        add(&registry, "generatePassword", "Generate a password", nil) {
            passwordGenerator.clearAfter = .seconds(PasswordSettings.shared.clearAfter)
            Task { await passwordGenerator.run() }
            alog.notice("generate password: asked bw")   // never the password itself
        }
    }

    /// Bitwarden's menu item; search and the generator bring the app forward first, as they open in its window.
    private static func bitwarden(_ route: DriveRoute, front: Bool) {
        guard front else { return DriveModule.run(route) }
        guard open(bundle: Bitwarden.bundle) else { return HUD.tip("Bitwarden is not installed.") }
        pressWhenRunning(route, tries: 25)
    }

    /// Waits for Bitwarden to finish launching, up to 5 s for a cold launch, then lets its window come forward and presses.
    private static func pressWhenRunning(_ route: DriveRoute, tries: Int) {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Bitwarden.bundle && $0.isFinishedLaunching }
        guard running || tries == 0 else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pressWhenRunning(route, tries: tries - 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DriveModule.run(route) }
    }

    /// Its length, symbols and clearing from Defaults › Passwords (story 160).
    private static let passwordGenerator = Bitwarden.Generator(generate: {
        try await Bitwarden.Generator.runBW(PasswordSettings.shared.arguments)
    }) { HUD.tip($0) }

    private static func add(_ registry: inout ActionRegistry, _ id: String, _ label: String, _ key: Key?, keywords: String? = nil,
                            run: @escaping @Sendable @MainActor () -> Void) {
        do { try registry.register(Action(id: Self.id(id), label: label, module: .apps, defaultKey: key, keywords: keywords, run: run)) }
        catch { alog.error("\(Self.id(id), privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    // MARK: any app, any URL (story 19)

    /// Actions the Binds screen and the presets make (PilotCore's AppLink): `apps.open:<bundle id>`, `apps.web:<url>`,
    /// `apps.url:<bundle id>:<url>` and `apps.private:<bundle id>`. Not in the registry; the bind store keeps the id and
    /// the engine rebuilds the action from it.
    static func openID(bundle: String) -> String { AppLink.open(bundle: bundle).id }
    /// Each role's action id → the app it opens today (the menu's keys, bind hints). Not Agent's: a command is no app, and
    /// finding it reads the disk on every app switch (BindNudger).
    static func roleApps() -> [String: String] {
        Dictionary(uniqueKeysWithValues: AppRole.allCases.filter { $0 != .agent }.map { (id($0.rawValue), resolved($0)) })
    }
    /// Nil unless the URL has a host.
    static func webID(_ url: String) -> String? { URL(string: url)?.host == nil ? nil : AppLink.web(url: url).id }
    /// The other way: the bundle id or URL a picker id holds, nil for any other action.
    static func bundle(in id: String) -> String? { if case .open(let bundle) = AppLink(id: id) { bundle } else { nil } }
    static func page(in id: String) -> String? { if case .web(let url) = AppLink(id: id) { url } else { nil } }

    static func dynamic(_ id: String) -> Action? {
        switch AppLink(id: id) {
        case .open(let bundle):
            return Action(id: id, label: displayName(bundle), module: .apps) {
                alog.notice("open \(bundle, privacy: .public) \(open(bundle: bundle) ? "opened" : "not installed", privacy: .public)")
            }
        case .web(let raw):
            guard let url = URL(string: raw), url.host != nil else { return nil }
            return Action(id: id, label: url.host ?? raw, module: .apps) { openWeb(url) }
        case .url(let bundle, let raw):
            guard let url = URL(string: raw), url.host != nil else { return nil }
            return Action(id: id, label: "\(url.host ?? raw) in \(displayName(bundle))", module: .apps) { open(url, in: bundle) }
        case .privateWindow(let bundle):
            return Action(id: id, label: "Private window in \(displayName(bundle))", module: .apps) { privateWindow(bundle) }
        case nil:
            return nil
        }
    }

    /// A page or a file in one app, as Hammerspoon's "… in Zen" binds did, whatever the default is; false when the app is gone.
    @discardableResult
    static func open(_ url: URL, in bundle: String) -> Bool {
        guard let app = Self.url(forBundle: bundle) else {
            alog.notice("\(LinkToken.redact(url.absoluteString), privacy: .public): \(bundle, privacy: .public) not installed")
            return false
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
            if let error { alog.error("\(LinkToken.redact(url.absoluteString), privacy: .public) in \(bundle, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        alog.notice("\(LinkToken.redact(url.absoluteString), privacy: .public) → \(bundle, privacy: .public)")
        return true
    }

    /// The browser's own binary with its private-window flag: Firefox's family hands it to the running instance.
    static func privateWindow(_ bundle: String) {
        guard let flag = AppLink.privateFlag(bundle: bundle), let binary = url(forBundle: bundle).flatMap(Bundle.init(url:))?.executableURL else {
            alog.notice("private window: \(bundle, privacy: .public) has none Pilot knows")
            return HUD.tip("Pilot knows no private window for this browser.")
        }
        run(binary.path, [flag], what: "private window \(bundle)")
    }

    // MARK: Ghostty commands (Hammerspoon's lazygit picker)

    /// A new Ghostty window running `arguments`. --window-save-state=never, or the window inherits a saved fullscreen
    /// state and lands on a Space of its own (Hammerspoon's note, 2026-09-10).
    static func ghostty(_ arguments: [String], what: String) {
        guard let app = url(forBundle: "com.mitchellh.ghostty") else { return alog.notice("\(what, privacy: .public): Ghostty not installed") }
        run(app.appendingPathComponent("Contents/MacOS/ghostty").path, ["--window-save-state=never"] + arguments, what: what)
    }

    /// Hyper+Shift+G: lazygit on a repo under ~/code (or the folder picked on Defaults › Folders), newest first, picked
    /// in the menu's list.
    static func pickRepo() {
        let code = PilotFolders.shared.reposURL
        Task {
            // Off the main actor: one stat per folder under the repos folder, a .git's modification date or no repo.
            let rows = await Task.detached {
                return ((try? FileManager.default.contentsOfDirectory(at: code, includingPropertiesForKeys: nil)) ?? [])
                    .compactMap { dir in
                        (try? dir.appendingPathComponent(".git").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                            .map { (dir, $0) }
                    }
                    .sorted { $0.1 > $1.1 }
                    .map { MenuEntry(title: $0.0.lastPathComponent, target: .action($0.0.path), detail: $0.0.path) }
            }.value
            pick(rows)
        }
    }

    private static func pick(_ rows: [MenuEntry]) {
        PilotMenu.shared.pick(rows, title: "lazygit") { row in
            guard case .action(let path) = row.target else { return }
            ghostty(["--working-directory=\(path)", "--command=/opt/homebrew/bin/lazygit"], what: "lazygit \(row.title)")
        }
    }

    private static func run(_ path: String, _ arguments: [String], what: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        do { try p.run(); alog.notice("\(what, privacy: .public) started") }
        catch { alog.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    /// Every app the picker can offer: name and bundle id, from the usual application folders and the rest of the home
    /// folder (`homeApps`), plus Finder, which lives in CoreServices; no dot-named helper (.Karabiner-VirtualHIDDevice-Manager).
    static func installedApps() -> [(name: String, bundle: String)] {
        if let scanned, scanned.stamps == stamps(scanned.folders) { return scanned.apps }
        let home = homeApps(), found = scan(home: home.apps)
        let apps = byName(found.map { ($0.name, $0.bundle) })
        let folders = appFolders + home.folders
        scanned = (folders, stamps(folders), apps, Dictionary(uniqueKeysWithValues: found.map { ($0.bundle, $0.url) }))
        return apps
    }
    /// The last scan, the folders it read and their change dates: an app added, removed or renamed changes its folder's,
    /// so each menu open reads every bundle again only then. `files` opens an app LaunchServices has not met yet.
    private static var scanned: (folders: [String], stamps: [Date?], apps: [(name: String, bundle: String)], files: [String: URL])?
    nonisolated private static func stamps(_ folders: [String]) -> [Date?] {
        folders.map { try? URL(filePath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    }

    /// installedApps with each app's file, unsorted; reads only the disk, so it runs off the main actor too.
    nonisolated static func installedAppFiles() -> [(name: String, bundle: String, url: URL)] { scan().map { ($0.name, $0.bundle, $0.url) } }

    /// Apps kept elsewhere in the home folder, as Raycast lists them (OpenRGB left in Downloads), with the folders read:
    /// a bundle in any folder of home, or one folder further down Downloads, Desktop and Documents (an unzipped release's
    /// folder); never inside a package, ~/Library, a dot folder (the Trash), a link or a build tool's tree. Spotlight is
    /// off on Sven's Mac (2026-10-24) and the file index runs only while the menu is used, so this reads the disk: about 30 folders,
    /// whose change dates each menu open compares in about a millisecond. Desktop, Documents and Downloads are read only
    /// with Full Disk Access: without it macOS asks in Pilot's name.
    nonisolated static func homeApps() -> (folders: [String], apps: [(dir: String, entry: String)]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let deeper: Set<String> = ["Downloads", "Desktop", "Documents"]
        let skipped = Set(["Library", "Applications"]).union(FileIndex.hasFullDiskAccess() ? [] : deeper)
        var folders: [String] = [], apps: [(dir: String, entry: String)] = [], level = [URL(filePath: NSHomeDirectory())]
        for depth in 0..<3 {
            var next: [URL] = []
            for dir in level {
                guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { continue }
                folders.append(dir.path)
                let descends = depth == 0 || depth == 1 && deeper.contains(dir.lastPathComponent)
                for url in entries {
                    let name = url.lastPathComponent
                    if url.pathExtension == "app" { apps.append((dir.path, name)); continue }
                    guard descends, depth > 0 || !skipped.contains(name), !toolFolders.contains(name),
                          let v = try? url.resourceValues(forKeys: keys),
                          v.isDirectory == true, v.isPackage != true, v.isSymbolicLink != true else { continue }
                    next.append(url)
                }
            }
            level = next
        }
        return (folders, apps)
    }
    /// The never-index list's folder names (node_modules, DerivedData, target …) and a build's output: their apps are
    /// copies, never Sven's.
    nonisolated private static let toolFolders = Set(FileExclusions.defaults.filter { !$0.contains("/") }).union(["build"])

    /// When the app at `url` was last opened, as Spotlight keeps it (kMDItemLastUsedDate); nil when it has no date.
    nonisolated static func lastUsed(_ url: URL) -> Date? {
        MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
    }

    /// The application folders first, so a copy of an app elsewhere in home (`home`) never stands in for the one there.
    nonisolated private static func scan(home: [(dir: String, entry: String)] = homeApps().apps) -> [(name: String, bundle: String, url: URL, info: [String: Any]?)] {
        let dirs = appFolders
        var seen = Set<String>(), out: [(name: String, bundle: String, url: URL, info: [String: Any]?)] = []
        let listed = dirs.flatMap { dir in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { (dir, $0) } }
        for (dir, entry) in listed + [("/System/Library/CoreServices", "Finder.app")] + home where entry.hasSuffix(".app") && !entry.hasPrefix(".") {
            guard let b = Bundle(path: dir + "/" + entry), let id = b.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append((entry.replacingOccurrences(of: ".app", with: ""), id, b.bundleURL, b.infoDictionary))
        }
        return out
    }

    /// The bundle id each of `names` belongs to (C8, Always float names from before it took bundle ids), case ignored: the
    /// running app macOS shows by that name, else the installed app whose file, display or bundle name it is. A name no
    /// app has is left out.
    static func bundles(named names: [String]) -> [String: String] {
        let running = NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { (name: app.localizedName ?? "", bundle: $0) } }
        var installed: [(name: String, bundle: String)]?
        var out: [String: String] = [:]
        for name in names {
            func named(_ app: (name: String, bundle: String)) -> Bool { app.name.caseInsensitiveCompare(name) == .orderedSame }
            if let app = running.first(where: named) { out[name] = app.bundle; continue }
            installed = installed ?? scan().flatMap { app in
                ([app.name] + ["CFBundleDisplayName", "CFBundleName"].compactMap { app.info?[$0] as? String }).map { (name: $0, bundle: app.bundle) }
            }
            out[name] = installed?.first(where: named)?.bundle
        }
        return out
    }

    /// Every app macOS opens any of `types` with, each once, by name.
    static func apps(opening types: [UTType]) -> [(name: String, bundle: String)] {
        named(types.flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) })
    }

    /// Every app macOS opens any of `urls` with (a scheme's links), each once, by name.
    static func apps(opening urls: [URL]) -> [(name: String, bundle: String)] {
        named(urls.flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) })
    }

    private static func named(_ apps: [URL]) -> [(name: String, bundle: String)] {
        var seen = Set<String>()
        return byName(apps.compactMap { url in
            Bundle(url: url)?.bundleIdentifier.flatMap { seen.insert($0).inserted ? (name: appName(at: url), bundle: $0) : nil }
        })
    }

    private static func byName(_ apps: [(name: String, bundle: String)]) -> [(name: String, bundle: String)] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Installed apps a person launches plus every running one, so apps outside the application folders (Finder) can
    /// take a rule too: Add app's choices in Workspaces and Focus sessions.
    static func pickableApps() -> [(name: String, bundle: String)] {
        let installed = scan().filter { isPickable($0.url, info: $0.info) }.map { (name: $0.name, bundle: $0.bundle) }
        let known = Set(installed.map(\.bundle))
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
            app.bundleIdentifier.flatMap { known.contains($0) ? nil : (name: app.localizedName ?? $0, bundle: $0) }
        }
        return byName(installed + running)
    }

    /// An app a person launches: not dot-named (.Karabiner-VirtualHIDDevice-Manager), not an agent or background-only
    /// helper (LSUIElement, LSBackgroundOnly), not an app inside another app's bundle.
    static func isPickable(_ url: URL, info: [String: Any]?) -> Bool {
        func on(_ key: String) -> Bool { (info?[key] as? Bool) == true || (info?[key] as? String) == "1" }
        return !url.lastPathComponent.hasPrefix(".") && !url.deletingLastPathComponent().pathComponents.contains { $0.hasSuffix(".app") }
            && !on("LSUIElement") && !on("LSBackgroundOnly")
    }

    // MARK: mechanisms

    /// LaunchServices' file for the app, else the last installedApps scan's: an app in a home folder never opened yet.
    static func url(forBundle bundle: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) ?? scanned?.files[bundle]
    }
    static func isInstalled(_ bundle: String) -> Bool { url(forBundle: bundle) != nil }

    /// An app's icon, read the first time it is asked for and kept small (`small`), so the menu's rows read only the icons
    /// they draw; a miss is kept too. Bounded (story 154): past `iconLimit` apps the cache lets the oldest go.
    static func icon(bundle: String) -> NSImage? {
        let key = bundle as NSString
        if let cached = icons.object(forKey: key) { return cached.image }
        let icon = url(forBundle: bundle).map { small(NSWorkspace.shared.icon(forFile: $0.path)) }
        icons.setObject(Kept(icon), forKey: key)
        return icon
    }
    /// An app's icon by its name (an Always float name, Stats' busiest apps, a workspace's apps): the running app's, else
    /// the app of that name in the usual folders (story 154), kept small; a miss is kept until an app launches.
    static func icon(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = namedIcons.object(forKey: key) { return cached.image }
        if launches == nil {
            launches = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                         object: nil, queue: .main) { _ in MainActor.assumeIsolated { namedIcons.removeAllObjects() } }
        }
        let icon = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon.map(small)
            ?? appFolders.lazy.map { "\($0)/\(name).app" }.first(where: FileManager.default.fileExists(atPath:)).map(icon(file:))
            ?? scanned?.apps.first { $0.name == name }.flatMap { scanned?.files[$0.bundle] }.map { icon(file: $0.path) }
        namedIcons.setObject(Kept(icon), forKey: key)
        return icon
    }
    /// An app's icon at a native menu's 16 pt, sharing its small bitmap, kept per app.
    static func menuIcon(bundle: String) -> NSImage? {
        let key = bundle as NSString
        if let cached = menuIcons.object(forKey: key) { return cached }
        guard let copy = icon(bundle: bundle)?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        menuIcons.setObject(copy, forKey: key)
        return copy
    }
    private final class Kept {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    nonisolated static let appFolders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    static let iconLimit = 400
    private static func bounded<Value>(limit: Int = iconLimit) -> NSCache<NSString, Value> {
        let cache = NSCache<NSString, Value>()
        cache.countLimit = limit
        return cache
    }
    private static let icons: NSCache<NSString, Kept> = bounded(), namedIcons: NSCache<NSString, Kept> = bounded()
    private static let menuIcons: NSCache<NSString, NSImage> = bounded()
    private static var launches: NSObjectProtocol?
    /// The largest side a list draws an app icon at, in pixels: 36 pt at 2x (Toybox's menu rows draw 34 pt).
    static let iconPixels = 72
    /// `icon` drawn once into one bitmap `iconPixels` square, about 20 KB, in place of the icon's every size.
    static func small(_ icon: NSImage) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: iconPixels, pixelsHigh: iconPixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return icon }
        // The context draws in the bitmap's pixels; the image then says it is half that in points, a Retina picture.
        let pixels = CGFloat(iconPixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: pixels / 2, height: pixels / 2)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
    /// A file's icon for the menu's file results: its type's, kept by extension so a new search costs no lookup; a
    /// folder or a bundle (no extension, .app) its own, kept by path. Nothing reads the disk while a row draws.
    static func icon(file path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let own = ext.isEmpty || ext == "app"
        let key = (own ? path : "." + ext) as NSString
        if let cached = fileIcons.object(forKey: key) { return cached }
        let icon = own ? small(NSWorkspace.shared.icon(forFile: path)) : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        fileIcons.setObject(icon, forKey: key)
        return icon
    }
    private static let fileIcons: NSCache<NSString, NSImage> = bounded()
    /// Stickers and GIFs' row pictures by path (Stickers.thumbnail), made as the branch reads its folder.
    private static var thumbnails: [String: NSImage] = [:]
    static var thumbnailPaths: Set<String> { Set(thumbnails.keys) }
    static func thumbnail(_ path: String) -> NSImage? { thumbnails[path] }
    static func keepThumbnails(_ made: [(String, CGImage)]) {
        for (path, image) in made { thumbnails[path] = NSImage(cgImage: image, size: .zero) }
    }
    /// GIPHY's previews by GIF id (story 164), animated GIFs kept as their bytes so the row plays them: a search scrolled
    /// to its last page and the one before, as each search brings new ones. The menu drops the pages after the first as
    /// it closes.
    private static let webThumbnails: NSCache<NSString, NSImage> = bounded(limit: Giphy.most + Giphy.limit)
    static func webThumbnail(_ id: String) -> NSImage? { webThumbnails.object(forKey: id as NSString) }
    static func dropWebThumbnails(_ ids: [String]) { for id in ids { webThumbnails.removeObject(forKey: id as NSString) } }
    static func keepWebThumbnails(_ made: [String: Data]) {
        for (id, data) in made { if let image = NSImage(data: data) { webThumbnails.setObject(image, forKey: id as NSString) } }
    }
    static func appName(_ bundle: String) -> String? { url(forBundle: bundle).map(appName(at:)) }
    /// The app's name, or for an app this Mac lacks its bundle id's last word raised (card agent-bo-95423023):
    /// com.madda.ghostex reads Ghostex, never the id.
    static func displayName(_ bundle: String) -> String { appName(bundle) ?? idName(bundle) }
    static func idName(_ bundle: String) -> String {
        let word = bundle.split(separator: ".").last.map(String.init) ?? bundle
        return word.prefix(1).uppercased() + word.dropFirst()
    }
    static func appName(at url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Launch-or-focus: a running app is activated, a stopped one launched.
    @discardableResult
    static func open(bundle: String, newInstance: Bool = false) -> Bool {
        guard let url = url(forBundle: bundle) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { alog.error("open \(bundle, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }

    /// Hyper+Return: a new window of the terminal, every time. Running: activate and press its File > New Window
    /// (the Command+N menu item, through Accessibility). Not running: launching opens one.
    static func newTerminalWindow(_ bundle: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
            return open(bundle: bundle)
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !AXMenu.press(pid: app.processIdentifier, cmdChar: "N") {
                alog.notice("terminal: no Command+N menu item, opening a new instance")
                open(bundle: bundle, newInstance: true)
            }
        }
        return true
    }

    /// Agent's key (Q462): the coding agent's command in a new window of the Terminal key's app, in the home folder; the
    /// window closes when the agent quits cleanly.
    static func openAgent(_ command: String) -> Bool {
        guard let path = Self.command(command) else {
            HUD.tip("No coding agent found: install Claude Code or Codex.")
            return false
        }
        VisibleTerminal.run("cd && \(VisibleRun.quoted(path))", title: AppRolePicks.name(command) { _ in nil }, onSuccess: "true",
                            in: resolved(.terminal))
        return true
    }

    /// A command's path: on Pilot's PATH, else where Homebrew and the vendors' installers put commands.
    static func command(_ name: String) -> String? {
        AICommand.find(name, path: path, isExecutable: FileManager.default.isExecutableFile(atPath:))
    }
    private static let path = ProcessInfo.processInfo.environment["PATH"]

    /// A URL as an app: the web app Pilot stamped for that site, then a Safari web app for it, else the default
    /// browser. A web app opens at its own start page, not at the bound path.
    static func openWeb(_ url: URL) {
        if let webApp = WebAppDirectory.app(for: url) {
            alog.notice("web \(LinkToken.redact(url.absoluteString), privacy: .public) → web app \(webApp.bundleID, privacy: .public)")
            NSWorkspace.shared.openApplication(at: webApp.location, configuration: .init()) { _, error in
                if let error { alog.error("web app \(webApp.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
            return
        }
        if let host = url.host, let webApp = safariWebApp(host: host) {
            alog.notice("web \(host, privacy: .public) → web app \(webApp.lastPathComponent, privacy: .public)")
            NSWorkspace.shared.openApplication(at: webApp, configuration: .init()) { _, _ in }
            return
        }
        alog.notice("web \(LinkToken.redact(url.absoluteString), privacy: .public) → default browser")
        NSWorkspace.shared.open(url)
    }

    /// Safari's "Add to Dock" web apps are bundles in ~/Applications with a com.apple.Safari.WebApp bundle id; the
    /// site URL is a string somewhere in their Info.plist, so match on host rather than on a key name.
    private static func safariWebApp(host: String) -> URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
        for entry in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where entry.pathExtension == "app" {
            guard let b = Bundle(url: entry), b.bundleIdentifier?.hasPrefix("com.apple.Safari.WebApp") == true,
                  let info = b.infoDictionary else { continue }
            if strings(in: info).contains(where: { URL(string: $0)?.host?.lowercased() == host.lowercased() }) { return entry }
        }
        return nil
    }

    private static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String: [s]
        case let d as [String: Any]: d.values.flatMap(strings)
        case let a as [Any]: a.flatMap(strings)
        default: []
        }
    }

    // MARK: defaults (story 18)

    /// Sven's pick on Defaults › Apps for keys while installed (AppRolePicks). Else a role macOS keeps a default for
    /// (browser, mail, calendar) asks macOS at each press, so the key opens the default as it is now, however it was
    /// changed (Sven: the browser always opens as the default browser); any other is resolved once and remembered, and
    /// again when the remembered app is gone. The editor follows Sven's pick and the Mac's text default as they change
    /// (EditorChoice).
    static func resolved(_ role: AppRole) -> String {
        if role == .editor { return EditorChoice.shared.app }
        if let pick = AppRolePicks.shared.app(role) { return pick }
        if !role.defaultHandlers.isEmpty { return automatic(role) }
        let key = cacheKey(role)
        if let cached = cache.string(forKey: key), has(role, cached) { return cached }
        let bundle = automatic(role)
        cache.set(bundle, forKey: key)
        alog.notice("default \(role.rawValue, privacy: .public) = \(bundle, privacy: .public)")
        return bundle
    }

    /// What Automatic gives a role now: its first known app (Agent: command) here, else macOS's default, else its last resort.
    static func automatic(_ role: AppRole) -> String { role.resolve(installed: { has(role, $0) }, handler: defaultApp(for:)) }

    /// Whether a role's app, website or command is on this Mac.
    static func has(_ role: AppRole, _ value: String) -> Bool { AppRolePicks.shared.has(role, value) }

    /// Drops the remembered app, so the next use resolves the role again (a new default browser, card agent-bo-95422842).
    static func forget(_ role: AppRole) { cache.removeObject(forKey: cacheKey(role)) }
    private static let cache = UserDefaults.pilot()
    private static func cacheKey(_ role: AppRole) -> String { "defaultApp.\(role.rawValue)" }

    /// The bundle id of the app macOS opens a URL or a kind of file with.
    static func defaultApp(for handler: DefaultHandler) -> String? {
        let app: URL? = switch handler {
        case .url(let s): URL(string: s).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        case .contentType(let id): UTType(id).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        }
        return app.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
