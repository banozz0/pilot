import AppKit
import OSLog
import PilotCore
import WebApps

let ilog = Logger(subsystem: "dev.banozz.pilot", category: "install")

/// Install, Remove and Update (stories 81 to 85, 97 to 100; SPEC.md, Install catalogue): the shipped catalogue, the
/// confirm step that shows the exact command, and the visible terminal that runs it.
@MainActor
enum InstallModule {
    /// The catalogue in the app's Resources; empty, and logged, when the file is missing or broken.
    static let catalogue = BundledJSON.load("install-catalogue", log: ilog, empty: [CatalogueEntry]()) { try InstallCatalogue.parse($0) }

    static func isInstalled(_ entry: CatalogueEntry) -> Bool {
        entry.check.isMet(bundleInstalled: AppsModule.isInstalled, fileExists: FileManager.default.fileExists(atPath:))
    }

    /// Install's rows as the menu opens, each entry's installed-check read now; none while Recommend apps is off, since
    /// the catalogue is the recommendations (Sven 2026-10-09): Install is then its search alone.
    static func menuEntries(recommend: Bool = Recommendations.shared.show) -> [MenuEntry] {
        recommend ? MenuEntries.install(catalogue, installed: Set(catalogue.filter(isInstalled).map(\.id))) : []
    }

    /// The catalogue's icons by package key, for Update's and Remove's rows (Sven 2026-10-09): an entry's app once
    /// installed, else its shipped picture.
    static let catalogueIcons = Dictionary(catalogue.compactMap { e in e.method.package.map { ($0.key, MenuIcon.catalogue(e)) } }) { a, _ in a }

    /// Return on a package row: an installed entry says so, a download opens its page in Zen, anything else asks
    /// first with the exact command, then runs it in the visible terminal; a search row is named as the search showed it.
    /// A search's page (N9) opens with nothing run, the App Store's in the App Store; a GitHub release's file asks with
    /// its download command first, as a package does.
    static func pick(_ key: String, confirm: Confirm = confirm, run: @escaping Run = visibleRun,
                     open: @escaping @MainActor (URL) -> Void = openPage) {
        if let helper = Helper(key: key) { return install(helper, confirm: confirm, run: run) }
        let entry = catalogue.first { $0.key == key }
        if let entry, isInstalled(entry) { return HUD.tip("\(entry.name) is installed") }
        if case .download(let page)? = entry?.method, let url = URL(string: page) {
            ilog.notice("install \(entry?.id ?? "?", privacy: .public): download page")
            AppsModule.open(url, in: MyBinds.zen)
            return
        }
        if let entry, let command = entry.method.scriptCommand {
            let name = "Install \(entry.name)"
            return confirm(name, command) { run(command, name, VisibleRun.waitForReturn) }
        }
        let title = entry?.name ?? InstallSearch.title(key)
        switch InstallSearch.Method(key: key) {
        case .page(let url)?:
            ilog.notice("install \(title ?? "?", privacy: .public): opens \(LinkToken.redact(url.absoluteString), privacy: .public)")
            return open(url)
        case .download(let url)?:
            guard let command = InstallSearch.downloadCommand(url) else { return ilog.error("install: no download for \(key, privacy: .public)") }
            let name = "Install \(title ?? url.lastPathComponent)"
            return confirm(name, command) { run(command, name, VisibleRun.waitForReturn) }
        case .package(let package)?:
            confirmRun("Install \(title ?? package.name)", package.install, hook: "installed", key: package.key, confirm: confirm, run: run)
        case nil: ilog.error("install: no package \(key, privacy: .public)")
        }
    }

    /// A helper's Install (General's Helpers, Clean's Install Mole, Update's install mas, the search's hint): one already
    /// there says so; a formula with Homebrew missing says to install Homebrew first rather than run brew into a wall;
    /// else the confirm step, then the visible terminal, where Homebrew's installer asks for the password itself.
    static func install(_ helper: Helper, confirm: Confirm = confirm, run: @escaping Run = visibleRun,
                        installed: Set<String> = Helper.installed()) {
        let title = "Install \(helper.name)"
        switch helper.step(installed: installed) {
        case .installed: HUD.tip("\(helper.name) is installed")
        case .needsHomebrew: HUD.tip("\(helper.name) installs through Homebrew: install Homebrew first, in Install › Helpers")
        case .installer(let command): confirm(title, command) { run(command, title, VisibleRun.waitForReturn) }
        case .formula(let p): confirmRun(title, p.install, hook: "installed", key: p.key, confirm: confirm, run: run)
        }
    }

    /// A formula helper with Homebrew in one run (Clean's Install Homebrew and Mole, Sven 2026-10-29, Q557): the confirm
    /// step with the chained command, then the visible terminal, which records the formula's install and waits for Return
    /// so Homebrew's next steps are read.
    static func installWithHomebrew(_ helper: Helper, confirm: Confirm = confirm, run: @escaping Run = visibleRun) {
        guard let package = helper.package else { return install(helper, confirm: confirm, run: run) }
        let title = "Install Homebrew and \(helper.name)"
        confirm(title, helper.withHomebrew) { run(helper.withHomebrew, title, "\(hook("installed", key: package.key)); \(VisibleRun.waitForReturn)") }
    }

    /// A search's page: the App Store's in the App Store, anything else in Zen.
    static func openPage(_ url: URL) {
        if url.scheme == "macappstore" { NSWorkspace.shared.open(url) } else { AppsModule.open(url, in: MyBinds.zen) }
    }

    /// The confirm step's shape: title, what will run, and what runs on yes.
    typealias Confirm = @MainActor (_ title: String, _ command: String, _ then: @escaping @MainActor () -> Void) -> Void
    /// The visible terminal's shape: the command, the window's title, and what runs on exit 0.
    typealias Run = @MainActor (_ command: String, _ title: String, _ onSuccess: String) -> Void

    /// Return on a Remove row (story 84): a package asks with its exact command, then runs it in the visible terminal;
    /// an npm tool through its own tree's npm (card agent-bo-95422989); a web app, or an app Homebrew did not install
    /// (card agent-bo-95422979), asks, then goes to the Trash, where Finder can put it back. An app, a cask's app included,
    /// is quit first, and its leftovers offered once it is gone; a web app's too (Q181).
    static func remove(_ row: RemoveRow, confirm: Confirm = confirm, run: @escaping Run = visibleRun,
                       trash: @escaping @MainActor (URL) throws -> URL = WebAppDirectory.trash,
                       askForce: @escaping RemoveApp.AskForce = RemoveApp.menuAskForce) {
        guard !row.system else { return HUD.tip("\(row.name) is part of macOS and can't be removed") }
        let location: URL
        switch row.source {
        case .package(let package) where package.kind == .cask && row.app != nil:
            return RemoveApp.removeCask(row.name, command: package.remove, key: package.key, app: URL(filePath: row.app!), confirm: confirm,
                                        run: run, askForce: askForce)
        case .package(let package):
            return confirmRun("Remove \(row.name)", package.remove, hook: "removed", key: package.key, confirm: confirm, run: run)
        case .npm(let name, let prefix):
            return confirmRun("Remove \(name)", "\(UpdateList.npm("uninstall", prefix: prefix)) \(name)", hook: "removed", key: row.recordKey,
                              confirm: confirm, run: run)
        case .app(let path): return RemoveApp.remove(row.name, at: URL(filePath: path), confirm: confirm, trash: trash, askForce: askForce)
        case .webApp(let id):
            guard let app = WebAppDirectory.list().first(where: { $0.bundleID == id }) else {
                return ilog.error("remove: no web app \(id, privacy: .public)")
            }
            location = app.location
        }
        trashAfterYes(row.name, location, confirm: confirm, trash: trash)
    }

    /// Remove on Install › Web apps (card agent-bo-95422994): the same ask as the menu's Remove; `then` refreshes the
    /// page's list once the app is in the Trash.
    static func remove(_ app: InstalledWebApp, confirm: Confirm = confirm,
                       trash: @escaping @MainActor (URL) throws -> URL = WebAppDirectory.trash, then: @escaping @MainActor () -> Void,
                       leftovers: @escaping @MainActor (AppLeftovers.App) -> Void = RemoveApp.offerLeftovers) {
        trashAfterYes(app.name, app.location, confirm: confirm, trash: trash, then: then, leftovers: leftovers)
    }

    /// A web app to the Trash after the ask, then its leftovers (its WebKit store, which holds its logins, and its
    /// preferences) offered (Q181).
    private static func trashAfterYes(_ name: String, _ location: URL, confirm: Confirm, trash: @escaping @MainActor (URL) throws -> URL,
                                      then: @escaping @MainActor () -> Void = {},
                                      leftovers: @escaping @MainActor (AppLeftovers.App) -> Void = RemoveApp.offerLeftovers) {
        let reading = Task.detached(priority: .userInitiated) { AppLeftovers.App.read(location) }
        confirm("Remove \(name)", "Move \(location.lastPathComponent) to the Trash") {
            AdminTrash.trash(location, plain: trash) { result in
                switch result {
                case .success(let trashed):
                    ilog.notice("removed \(name, privacy: .public) to \(trashed.path, privacy: .public)")
                    Task { if let app = await reading.value { leftovers(app) } }
                case .failure(let error):
                    ilog.error("\(name, privacy: .public) not removed: \(error.localizedDescription, privacy: .public)")
                    HUD.tip(AdminTrash.said(error) ?? "\(name) could not go to the Trash")
                }
                then()
            }
        }
    }

    /// Return on a pinned Update row (card agent-bo-95422979): asks with `brew unpin`, then runs it in the visible
    /// terminal; the next Update lists the formula to update.
    static func unpin(_ row: UpdateRow, confirm: Confirm = confirm,
                      run: @escaping @MainActor (String) -> Void = { VisibleTerminal.run($0, title: "Unpin", onSuccess: "true") }) {
        guard let command = UpdateList.unpin(row) else { return }
        confirm("Unpin \(row.item.name)", command) {
            // Unpinned, the row is one to update: the next open checks again.
            updates.drop()
            run(command)
        }
    }

    /// An update Sven confirmed: the kept rows are wrong once it runs, so the next open checks again (as a clean drops
    /// Mole's preview), and the command runs in the visible terminal with its report.
    static func runUpdate(_ title: String, _ command: String, rows: [UpdateRow]) {
        updates.drop()
        VisibleTerminal.run(command, title: "Update", onSuccess: "true", report: .update(title, command: command, rows: rows))
    }

    /// The confirm step (wireframe sections 9 and 12): what will run, shown before it runs; Cancel runs nothing.
    static func confirm(_ title: String, _ command: String, then go: @escaping @MainActor () -> Void) {
        let yes = MenuEntry(title: title, target: .action("install.go"), detail: command)
        PilotMenu.shared.pick([yes, MenuEntry(title: "Cancel", target: .action("install.cancel"))]) { row in
            guard row == yes else { return ilog.notice("\(title, privacy: .public): cancelled, nothing run") }
            go()
        }
        ilog.notice("\(title, privacy: .public): asking, \(command, privacy: .public)")
    }

    static func visibleRun(_ command: String, _ title: String, _ onSuccess: String) { VisibleTerminal.run(command, title: title, onSuccess: onSuccess) }

    /// Confirm, then the visible terminal, whose success calls pilot://<hook>?package=<key>.
    static func confirmRun(_ title: String, _ command: String, hook: String, key: String, confirm: Confirm, run: @escaping Run) {
        confirm(title, command) { run(command, title, Self.hook(hook, key: key)) }
    }

    /// A visible run's success call back into Pilot: pilot://<hook>?package=<key>, which records the install or removal.
    static func hook(_ hook: String, key: String) -> String { "open -g 'pilot://\(hook)?package=\(key)'" }

    /// Remove's rows: what Homebrew has (`brew info --json=v2 --installed`, read-only, about 2 s and 0.8 MB), with each
    /// npm's global tools read at the same time, marked with the apps Homebrew did not install, Pilot's installs and each
    /// app's Spotlight last-used date, then the web apps; read off the main thread.
    /// Nil when Homebrew's list could not be read, so the next open tries again.
    @concurrent nonisolated static func removeRows() async -> [RemoveRow]? {
        guard let brew = Homebrew.cli("brew") else { return nil }
        async let npm = npmTools()
        var rows: [RemoveRow]
        do { rows = try RemoveList.parse(Data(try await ChildProcess.run(brew, ["info", "--json=v2", "--installed"], timeout: .seconds(60)).utf8)) }
        catch {
            ilog.error("remove: brew's list not read, \(String(describing: error), privacy: .public)")
            return nil
        }
        let webApps = WebAppDirectory.list(), apps = appBundles() + homeAppBundles()
        RemoveList.addApps(&rows, paths: apps, skipping: Set(webApps.map(\.location.path) + [Bundle.main.bundlePath]),
                           appStore: Set(apps.filter(isAppStore)))
        RemoveList.addApps(&rows, paths: systemAppBundles(), skipping: [], system: true)
        rows += await npm
        let pilot = Set(((try? InstalledStore.standard.load()) ?? [:]).keys)
        let used = Dictionary(rows.compactMap(\.app).compactMap { path in
            (NSMetadataItem(url: URL(filePath: path))?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date).map { (path, $0) }
        }, uniquingKeysWith: { a, _ in a })
        RemoveList.mark(&rows, pilot: pilot, lastUsed: used)
        return rows + webApps.map { RemoveRow(source: .webApp(bundleID: $0.bundleID), name: $0.name, app: $0.location.path) }
    }

    /// An app from the App Store: its bundle carries the store's receipt (card agent-bo-95423022).
    nonisolated static func isAppStore(_ app: String) -> Bool { FileManager.default.fileExists(atPath: app + "/Contents/_MASReceipt/receipt") }

    /// Each row's size on disk (card agent-bo-95423022): an app's from Spotlight when it has one, else the folder walked;
    /// off the main thread, after the rows already show, four walks at a time so they never take every thread.
    @concurrent nonisolated static func measure(_ rows: [RemoveRow], size: @escaping @Sendable (String) -> Int64? = diskSize) async -> [RemoveRow] {
        let prefix = Homebrew.prefix ?? "/opt/homebrew", home = NSHomeDirectory()
        var waiting = rows.indices.compactMap { i in rows[i].sizePath(brewPrefix: prefix, home: home).map { (i, $0) } }[...]
        return await withTaskGroup(of: (Int, Int64?).self) { group in
            func next() { if let (i, path) = waiting.popFirst() { group.addTask { (i, Task.isCancelled ? nil : size(path)) } } }
            for _ in 0..<4 { next() }
            var sized = rows
            for await (i, bytes) in group {
                sized[i].size = bytes
                next()
            }
            return sized
        }
    }

    /// A file's or folder's allocated size in bytes: Spotlight's for an app bundle that has one, else every file under it
    /// summed; nil when the path is not there.
    @Sendable nonisolated static func diskSize(_ path: String) -> Int64? {
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if path.hasSuffix(".app"), let bytes = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemPhysicalSize") as? Int64, bytes > 0 {
            return bytes
        }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var total: Int64 = 0
        for case let file as URL in walk {
            if Task.isCancelled { return nil }
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// `npm ls -g --depth=0 --json --long` from every npm found (it exits 1 on a tree with problems; `--long` carries each
    /// package's path, so its tree).
    @concurrent nonisolated static func npmTools(read: @escaping UpdateReader = updateRead) async -> [RemoveRow] {
        await eachNPM(read, ["ls", "-g", "--depth=0", "--json", "--long"], parse: RemoveList.parseNPM, key: \.key)
    }

    /// `arguments` asked of every npm found, at once, exits 0 and 1 read (`npm outdated` exits 1 when it lists anything);
    /// two npms sharing one tree list the same package once.
    @concurrent nonisolated static func eachNPM<Row: Sendable>(_ read: @escaping UpdateReader, _ arguments: [String],
                                                               parse: @escaping @Sendable (Data) -> [Row], key: @Sendable (Row) -> String) async -> [Row] {
        await withTaskGroup(of: [Row].self) { group in
            for npm in CatalogueEntry.Check.copies(of: "npm") {
                group.addTask { parse(Data((await read(npm, arguments, [0, 1]) ?? "").utf8)) }
            }
            var seen = Set<String>(), rows: [Row] = []
            for await found in group { rows += found.filter { seen.insert(key($0)).inserted } }
            return rows
        }
    }

    /// The folders Remove looks in for apps Homebrew did not install.
    nonisolated static let appFolders = [URL(filePath: "/Applications"), WebAppStamper.applicationsFolder]

    /// The app bundles at the top of the application folders that Sven can move to the Trash: never a link (Safari's
    /// lives in the system) or what the folder will not let go of.
    nonisolated static func appBundles(in folders: [URL] = appFolders) -> [String] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []).filter(isTrashableApp).map(\.path)
        }
    }

    /// The apps Apps lists from elsewhere in the home folder (`AppsModule.homeApps`, OpenRGB in Downloads), by the same rule.
    nonisolated static func homeAppBundles() -> [String] {
        AppsModule.homeApps().apps.map { URL(filePath: $0.dir).appending(path: $0.entry) }.filter(isTrashableApp).map(\.path)
    }

    nonisolated private static func isTrashableApp(_ url: URL) -> Bool {
        url.pathExtension == "app" && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            && FileManager.default.isDeletableFile(atPath: url.path)
    }

    /// The apps that are part of macOS, which Remove lists only to say they can't go: /System/Applications and its
    /// Utilities, and /Applications' links into /System (Safari).
    nonisolated static func systemAppBundles() -> [String] {
        let sealed = ["/System/Applications", "/System/Applications/Utilities"].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }.map { "\(folder)/\($0)" }
        }
        let linked = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasSuffix(".app") }
            .map { "/Applications/\($0)" }.filter { URL(filePath: $0).resolvingSymlinksInPath().path.hasPrefix("/System/") }
        return linked + sealed
    }

    /// Update's check, one run the menu's Update reads from the keys or Mac › Update & Clean, kept as Clean's preview is.
    static let updates: UpdateChecker = {
        let checker = UpdateChecker(first: { await updateRows() }, more: { await moreUpdateRows() })
        // The run ends whether or not a menu waits, as Clean's does: a tip when Update is not on screen.
        checker.onFinish = { rows in
            ilog.notice("update: check done, \(rows.map { "\($0.count) rows" } ?? "Homebrew's list unread", privacy: .public)")
            let include = Engine.shared?.settings.updateSelfUpdatingCasks ?? false
            if let tip = UpdateList.tip(rows, includeSelfUpdating: include, showing: PilotMenu.shared.branch?.browsed == .update) { HUD.tip(tip, seconds: 6) }
        }
        return checker
    }()

    /// A read-only list: the tool, its arguments and the exits that count as read; nil when it is missing or fails.
    typealias UpdateReader = @Sendable (_ cli: String?, _ arguments: [String], _ success: Set<Int32>) async -> String?

    /// Update's rows: `brew outdated --json=v2`, the same with `--greedy-auto-updates` to tell which casks update
    /// themselves, and `uv tool list --outdated`, all read-only and at once, off the main thread. Nil when Homebrew's
    /// lists could not be read, so the next open tries again.
    @concurrent nonisolated static func updateRows(read: UpdateReader = updateRead) async -> [UpdateRow]? {
        guard let brew = Homebrew.cli("brew") else { return nil }
        async let plain = read(brew, ["outdated", "--json=v2"], [0])
        async let greedy = read(brew, ["outdated", "--json=v2", "--greedy-auto-updates"], [0])
        async let uv = read(Homebrew.cli("uv"), ["tool", "list", "--outdated"], [0])
        guard let p = await plain, let g = await greedy, var brewRows = try? UpdateList.parse(plain: Data(p.utf8), greedy: Data(g.utf8)) else {
            return nil
        }
        // brew outdated names no app: brew info on the outdated casks does, so each row wears its app's icon.
        let casks = UpdateList.caskTokens(brewRows)
        if !casks.isEmpty, let info = await read(brew, ["info", "--json=v2", "--cask"] + casks, [0]) {
            brewRows = UpdateList.withApps(brewRows, info: Data(info.utf8))
        }
        return brewRows + UpdateList.parseUV(await uv ?? "")
    }

    /// Story 118's rows, which join Homebrew's once read, since softwareupdate and crates.io can take a while:
    /// `softwareupdate --list`, `mas outdated`, `npm outdated -g --json` from every npm found (each its own tree; it
    /// exits 1 when it lists anything), `bun outdated -g` and cargo's crates.io crates, all at once. A list that fails
    /// is logged and left out.
    @concurrent nonisolated static func moreUpdateRows(read: @escaping UpdateReader = updateRead) async -> [UpdateRow] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = ([v.majorVersion, v.minorVersion] + (v.patchVersion > 0 ? [v.patchVersion] : [])).map(String.init).joined(separator: ".")
        async let system = read("/usr/sbin/softwareupdate", ["--list"], [0])
        async let mas = read(Homebrew.cli("mas"), ["outdated"], [0])
        async let bun = read(CatalogueEntry.Check.copies(of: "bun").first, ["outdated", "-g"], [0])
        async let npm = eachNPM(read, ["outdated", "-g", "--json"], parse: UpdateList.parseNPM, key: \.item.key).sorted { $0.item.key < $1.item.key }
        async let cargo = cargoRows(read)
        return UpdateList.parseSoftwareUpdate(await system ?? "", macOS: macOS) + UpdateList.parseMas(await mas ?? "") + (await npm)
            + UpdateList.parseBun(await bun ?? "") + (await cargo)
    }

    /// The real reader, with the tool's own folder first on PATH (npm runs `env node`); nil, logged, when the tool is
    /// missing or fails.
    @concurrent nonisolated static func updateRead(_ cli: String?, _ arguments: [String], _ success: Set<Int32>) async -> String? {
        guard let cli else { return nil }
        do { return try await ChildProcess.run(cli, arguments, environment: ChildProcess.toolEnvironment(cli), timeout: .seconds(120), success: success) } catch {
            ilog.error("update: \(URL(filePath: cli).lastPathComponent, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) failed, \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// cargo's crates.io crates, each asked of crates.io with `cargo search`, at once; one that is current is left out.
    @concurrent nonisolated private static func cargoRows(_ read: @escaping UpdateReader) async -> [UpdateRow] {
        guard let cargo = CatalogueEntry.Check.copies(of: "cargo").first, let list = await read(cargo, ["install", "--list"], [0]) else { return [] }
        return await withTaskGroup(of: UpdateRow?.self) { group in
            for crate in UpdateList.cargoCrates(list) {
                group.addTask {
                    guard let found = await read(cargo, ["search", crate.name, "--limit", "1"], [0]),
                          let latest = UpdateList.cargoLatest(found, crate: crate.name), latest != crate.version else { return nil }
                    return UpdateRow(item: .cargo(crate.name), from: crate.version, to: latest)
                }
            }
            var rows: [UpdateRow] = []
            for await row in group { if let row { rows.append(row) } }
            return rows.sorted { $0.item.key < $1.item.key }
        }
    }

    /// When Homebrew's Cellar or Caskroom, Pilot's record, an application folder (web apps too), a home folder Apps reads
    /// or an npm tree last changed: Remove's rows are read again only when this moves.
    nonisolated static func removeStamp() -> [Date?] {
        let prefix = Homebrew.prefix.map { URL(filePath: $0) }
        let npmTrees = CatalogueEntry.Check.copies(of: "npm").map { URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().appending(path: "lib/node_modules") }
        let paths = [prefix?.appending(path: "Cellar"), prefix?.appending(path: "Caskroom"), InstalledStore.standard.url].compactMap(\.self)
            + appFolders + AppsModule.homeApps().folders.map { URL(filePath: $0) } + npmTrees
        return paths.map { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
    }

    /// pilot://install?package=<key>: the same confirm step for any package, e.g. formula:hello for the live test; nothing
    /// runs until Sven picks Install.
    static func install(_ url: URL) { pick(url.queryValue("package") ?? "") }

    /// pilot://installed?package=<key> and pilot://removed?package=<key>: the visible terminal's success hooks record
    /// the install or forget it.
    static func recordInstalled(_ url: URL) { updateRecord(url, "installed") { try InstalledStore.standard.record($0, at: .now) } }
    static func recordRemoved(_ url: URL) {
        updateRecord(url, "removed") { try InstalledStore.standard.forget($0) }
        // A cask Remove quit and uninstalled: its leftovers now it is gone.
        if let key = url.queryValue("package") { RemoveApp.removed(key) }
    }

    private static func updateRecord(_ url: URL, _ what: String, _ change: (Package) throws -> Void) {
        guard let package = url.queryValue("package").flatMap(Package.init(key:)) else {
            return ilog.error("\(what, privacy: .public): no package in \(LinkToken.redact(url.absoluteString), privacy: .public)")
        }
        do {
            try change(package)
            ilog.notice("\(what, privacy: .public) \(package.key, privacy: .public), recorded")
        } catch {
            ilog.error("\(what, privacy: .public) \(package.key, privacy: .public), record not updated: \(String(describing: error), privacy: .public)")
        }
    }
}

/// A terminal window Sven sees (story 97): `terminal` when given (Agent's key, in the Terminal key's app), else Ghostty
/// when installed, else Terminal, running VisibleRun's script, which closes the window on exit 0 and keeps it open
/// otherwise; another terminal app is handed the script as a file, as a double-click opens a .command. A run with a
/// `report` (Update and Clean, story 153) is kept in Reports; one whose folder cannot be made still runs, unrecorded.
@MainActor
enum VisibleTerminal {
    static func run(_ command: String, title: String, onSuccess: String, report: RunReport? = nil, store: ReportStore = .standard,
                    in terminal: String? = nil) {
        let script = FileManager.default.temporaryDirectory.appending(path: "pilot-run-\(UUID().uuidString).command")
        let folder = report.flatMap { report in
            do { return try store.begin(report) } catch {
                ilog.error("\(title, privacy: .public): report not kept, \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        do {
            try VisibleRun.script(command: command, onSuccess: onSuccess, report: folder).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return ilog.error("\(title, privacy: .public): script not written, \(error.localizedDescription, privacy: .public)")
        }
        let ghostty = "com.mitchellh.ghostty", app = terminal ?? (AppsModule.isInstalled(ghostty) ? ghostty : "com.apple.Terminal")
        if app == ghostty {
            // A Ghostty started for this one window quits with it, rather than idling with no window.
            AppsModule.ghostty(["--quit-after-last-window-closed=true", "--title=\(title)", "--command=/bin/zsh \(script.path)"],
                               what: "\(title) in Ghostty")
        } else if app != "com.apple.Terminal" {
            AppsModule.open(script, in: app)
        } else {
            let settings = script.deletingPathExtension().appendingPathExtension("terminal")
            do { try VisibleRun.terminalSettings(script: script.path).write(to: settings) } catch {
                return ilog.error("\(title, privacy: .public): Terminal settings not written, \(error.localizedDescription, privacy: .public)")
            }
            AppsModule.open(settings, in: "com.apple.Terminal")
            ilog.notice("\(title, privacy: .public) in Terminal")
        }
        ilog.notice("visible run: \(command, privacy: .public)")
    }
}

extension InstallModule {
    /// Web apps an older Pilot made get this one's web app (bug 2026-11-01: Messenger's sign-in left for Chrome): each
    /// that is not running now, and each running one as it quits; none is ever quit for it. Off the main thread.
    static func updateWebApps() {
        update(only: nil)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                  id.hasPrefix(WebAppSpec.bundleIDPrefix) else { return }
            Task { @MainActor in update(only: id) }
        }
    }

    private static func update(only id: String?) {
        Task {
            for outcome in await WebAppRebuild.refreshStale(only: id) {
                ilog.notice("web app update \(outcome.name, privacy: .public): \(outcome.failure ?? "done", privacy: .public)")
            }
        }
    }
}
