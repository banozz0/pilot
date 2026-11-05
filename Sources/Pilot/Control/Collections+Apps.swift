import Foundation
import PilotCore
import WebApps

/// What the apps' collections reach (AI helper T9): Install's record and flow, the web apps folder, the role picks and
/// the extensions folder. Each is reached on the first request, never at launch; a test sets its own before then, so
/// nothing installs, nothing lands in ~/Applications and no terminal opens.
@MainActor
final class AppCollectionStores {
    lazy var gate = AllowPrompt.gate
    lazy var installed = InstalledStore.standard
    /// Whether a catalogue entry for the package is installed already, as Install's own row says it.
    lazy var packageInstalled: @MainActor (Package) -> Bool = { p in InstallModule.catalogue.first { $0.key == p.key }.map(InstallModule.isInstalled) ?? false }
    /// The visible terminal Install runs its command in.
    lazy var run: InstallModule.Run = InstallModule.visibleRun
    lazy var webApps = WebAppStamper.applicationsFolder
    /// Install → Web App's build: the site's icon fetched, the app stamped into the folder, signed as Pilot is.
    lazy var stamp: @MainActor (WebAppSpec, URL) async throws -> URL = { try await WebAppStamper.install($0, into: $1) }
    lazy var trash: @MainActor (URL) throws -> URL = WebAppDirectory.trash
    lazy var picks = AppRolePicks.shared
    lazy var editor = EditorChoice.shared
    lazy var extensions = Extension.folder
    /// The name the web app form fills in for a blank one, fetched from the site (WebAppSpec.suggestedName).
    lazy var suggest: @MainActor (URL) async -> String = { await WebAppSpec.suggestedName(for: $0) }
    /// Rebuild and Rebuild all on Install › Web apps: running ones quit first, each rebuilt off the main thread.
    lazy var rebuild: @MainActor ([InstalledWebApp]) async -> [WebAppRebuild.Outcome] = { await WebAppRebuild.all($0) }
    /// The editor picker's apps (every app that opens plain text and source code) and what Automatic gives a role key.
    lazy var editorChoices: @MainActor () -> [(name: String, bundle: String)] = EditorChoice.choices
    lazy var automatic: @MainActor (AppRole) -> String = AppsModule.automatic
    lazy var appName: @MainActor (String) -> String? = AppsModule.appName
    /// Open with's file kinds read and set through LaunchServices; `forget` lets the browser and mail keys follow a change.
    lazy var defaultApps: any DefaultAppsSystem = LaunchServicesDefaults()
    lazy var forget: @MainActor (AppRole) -> Void = AppsModule.forget
    /// `list apps`: the installed apps with their files, and when each was last opened, read off the main actor.
    lazy var installedApps: @Sendable () -> [(name: String, bundle: String, url: URL)] = AppsModule.installedAppFiles
    lazy var lastUsed: @Sendable (URL) -> Date? = AppsModule.lastUsed
}

extension ControlVerbs {
    /// Packages, web apps, the apps the role keys open and the installed extensions as collections. Installing or
    /// removing a package or a web app waits on the Allow gate, which stands in for Install's confirm step; the command
    /// then runs in Install's visible terminal as a click there would run it. Extensions install through `ext` (T10).
    func registerAppCollections(_ s: AppCollectionStores = AppCollectionStores()) {
        register(ControlCollection("apps", help: "Every installed app: its name, bundle id and when it was last opened (Spotlight's), the most recent first.",
                                   rowKey: "bundle", list: { () throws(ControlError) in
            let installed = s.installedApps, lastUsed = s.lastUsed
            // The folder scan and Spotlight's dates both read the disk: off the main actor, which runs the tap.
            let rows = await Task.detached {
                installed().map { app in (name: app.name, bundle: app.bundle, used: lastUsed(app.url)) }
                    .sorted { a, b in
                        guard a.used != b.used else { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                        return (a.used ?? .distantPast) > (b.used ?? .distantPast)
                    }
            }.value
            return .array(rows.map { app in
                .object(["name": .string(app.name), "bundle": .string(app.bundle), "lastUsed": app.used.map { .string($0.ISO8601Format()) } ?? .null])
            })
        }))
        register(ControlCollection("packages", help: "Apps and tools Pilot installed (installed.json); add installs one, remove removes it, each after Allow.",
                                   fields: [.init("package", help: "cask:<name>, formula:<name>, uv:, npm:, mas:<id>, pipx:, cargo: or go:<module>")],
                                   rowKey: "package", list: { () throws(ControlError) in
            let all: [String: Date]
            do { all = try s.installed.load() } catch { throw ControlError(.badValue, "installed.json does not read: \(error.localizedDescription)") }
            return .array(all.sorted { $0.key < $1.key }.map { key, date in
                var row: [String: JSONValue] = ["package": .string(key), "installed": .string(date.ISO8601Format())]
                row["via"] = Package(key: key).map { .string($0.via) }
                return .object(row)
            })
        }, askerAdd: { args, peer throws(ControlError) in
            let package = try Self.package(args.value("package")!, "--package")
            if s.packageInstalled(package) { return .object(["package": .string(package.key), "installed": .bool(true), "ran": .null]) }
            return try await s.gate.allow(.install(.package, package.install), peer: peer) { () throws(ControlError) in
                InstallModule.pick(package.key, confirm: { _, _, go in go() }, run: s.run)
                return Self.started(package, package.install, "installed.json records it once the command ends with exit 0")
            }
        }, askerRemove: { args, peer throws(ControlError) in
            let package = try Self.package(try args.word(0, "package"), "package")
            return try await s.gate.allow(.remove(.package, package.remove), peer: peer) { () throws(ControlError) in
                InstallModule.remove(RemoveRow(source: .package(package), name: package.name), confirm: { _, _, go in go() }, run: s.run)
                return Self.started(package, package.remove, "installed.json forgets it once the command ends with exit 0")
            }
        }))

        register(ControlCollection("webapps", help: "Sites stamped as apps in ~/Applications; add builds one, remove moves it to the Trash, each after Allow. pilot webapp ideas and rebuild do the rest of Install › Web apps.",
                                   fields: [.init("name", help: "the app's name, e.g. Linear; left out, the site's own name, as the form fills it", required: false),
                                            .init("url", help: "https://… the site it opens")],
                                   rowKey: "name", list: { .array(WebAppDirectory.list(in: s.webApps).map { .object(Self.row($0)) }) },
                                   askerAdd: { args, peer throws(ControlError) in
            let url = args.value("url")!
            func parse(_ name: String) throws(ControlError) -> WebAppSpec {
                do { return try WebAppSpec(name: name, url: url) } catch {
                    throw ControlError(.badValue, (error as? WebAppError) == .emptyName ? "--name: say what the app is called" : "--url: \(url) is not an http or https site")
                }
            }
            // A name left out is the site's own, as Create app fills a blank one: the URL is checked before the page is fetched.
            var name = args.value("name") ?? ""
            if name.isEmpty { name = await s.suggest(try parse("-").url) }
            let spec = try parse(name)
            // The stamp replaces whatever sits at its path for good: only an earlier web app may be there, named in the prompt.
            let target = s.webApps.appending(path: spec.appFileName)
            if FileManager.default.fileExists(atPath: target.path), WebAppDirectory.read(target) == nil {
                throw ControlError(.badValue, "--name: \(target.path(percentEncoded: false)) is an app Pilot did not stamp, so it is kept; pick another name")
            }
            // Read again once Allow is pressed: anything changed at the path meanwhile denies.
            return try await s.gate.allow(.install(.webApp, Self.stamping(spec, at: target)), peer: peer) { () throws(ControlError) in
                let app: URL
                do { app = try await s.stamp(spec, s.webApps) } catch { throw ControlError(.badValue, "\(spec.name) was not built: \(error)") }
                guard let built = WebAppDirectory.read(app) else { throw ControlError(.badValue, "\(spec.name) was built at \(app.path) but does not read back") }
                return .object(Self.row(built))
            }
        }, askerRemove: { args, peer throws(ControlError) in
            let word = try args.word(0, "web app")
            let apps = WebAppDirectory.list(in: s.webApps)
            guard let app = apps.first(where: { $0.name == word || $0.bundleID == word }) else {
                throw ControlError(.badValue, "no web app \(word); there are \(apps.isEmpty ? "none" : apps.map(\.name).joined(separator: ", "))")
            }
            return try await s.gate.allow(.remove(.webApp, "\(app.name): move \(app.location.lastPathComponent) to the Trash"), peer: peer) { () throws(ControlError) in
                do { _ = try s.trash(app.location) } catch { throw ControlError(.badValue, "\(app.name) could not go to the Trash: \(error.localizedDescription)") }
                return .object(Self.row(app))
            }
        }))

        register(ControlCollection("roles", help: "The app each role key opens (Open with › Apps for keys, the editor), what Automatic gives and the picker's choices; add picks one, remove goes back to Automatic.",
                                   fields: [.init("role", help: "one of \(Self.roles.map(\.rawValue).joined(separator: ", "))"),
                                            .init("app", help: "a bundle id: for a key any installed app (Other app…) or a https:// site, for agent a command (claude, codex), for the editor one of its choices")],
                                   rowKey: "role", list: { .array(Self.roles.map { .object(Self.row($0, s)) }) },
                                   add: { args throws(ControlError) in
            let role = try Self.role(args.value("role")!), app = args.value("app")!
            if role == .editor {
                // The editor's picker offers only the apps that open text and source code.
                let choices = s.editorChoices()
                guard choices.contains(where: { $0.bundle == app }) else {
                    throw ControlError(.badValue, "--app: \(app) is not an editor choice; there are \(choices.map(\.bundle).joined(separator: ", "))")
                }
            } else if !s.picks.has(role, app) || (app == AppRolePicks.pilot && role != .notes && role != .files) {
                let (what, give) = role == .agent ? ("command", "a coding agent's command") : ("app", "an installed app's bundle id or a https:// site")
                throw ControlError(.badValue, "--app: no \(what) \(app) is installed; give \(give)")
            }
            Self.setPick(role, app, s)
            return .object(Self.row(role, s))
        }, remove: { args throws(ControlError) in
            let role = try Self.role(try args.word(0, "role"))
            Self.setPick(role, nil, s)
            return .object(Self.row(role, s))
        }))

        register(ControlCollection("extensions", help: "Installed extensions with their commands' action ids; read-only.",
                                   list: {
            // Off the main actor, as the menu reads them: every manifest is parsed.
            let folder = s.extensions
            return .array(await Task.detached { Extension.find(in: folder).extensions }.value.map { .object(Self.row($0)) })
        }))

        registerWebApps(s)
        registerDefaultApps(s)
    }

    /// The roles with a pick: the keys of Open with › Apps for keys, then the editor.
    private static let roles = AppRolePicks.roles + [.editor]

    private static func role(_ word: String) throws(ControlError) -> AppRole {
        guard let role = roles.first(where: { $0.rawValue == word }) else {
            throw ControlError(.badValue, "--role: no role \(word); there are \(roles.map(\.rawValue).joined(separator: ", "))")
        }
        return role
    }

    private static func package(_ key: String, _ field: String) throws(ControlError) -> Package {
        guard let package = Package(key: key) else {
            throw ControlError(.badValue, "\(field): \(key) is not a package key like cask:obsidian or formula:hello")
        }
        return package
    }

    /// A command handed to the visible terminal: it is running, not done.
    private static func started(_ p: Package, _ command: String, _ record: String) -> JSONValue {
        .object(["package": .string(p.key), "ran": .string(command), "note": .string("runs in a terminal window; \(record)")])
    }

    /// What building `spec` at `target` does, as the prompt says it: the site, and the web app it replaces when one is there.
    private static func stamping(_ spec: WebAppSpec, at target: URL) -> String {
        let site = "\(spec.name), \(spec.url.absoluteString)"
        if let old = WebAppDirectory.read(target) { return "\(site), replacing the web app \(old.name) (\(old.url.absoluteString)) there" }
        return FileManager.default.fileExists(atPath: target.path) ? "\(site), over \(target.lastPathComponent), not a web app" : site
    }

    static func row(_ w: InstalledWebApp) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["name": .string(w.name), "url": .string(w.url.absoluteString), "bundle": .string(w.bundleID),
                                        "path": .string(w.location.path(percentEncoded: false))]
        row["action"] = AppsModule.webID(w.url.absoluteString).map { .string($0) }
        return row
    }

    /// The editor keeps its own pick (EditorChoice); the role keys share AppRolePicks. Nil is Automatic.
    private static func setPick(_ role: AppRole, _ app: String?, _ s: AppCollectionStores) {
        if role == .editor { s.editor.pick = app } else { s.picks.set(role, app) }
    }

    /// A role, its pick, the app its key opens now (the editor always has one, a role key none until one is
    /// installed), the app Automatic gives, and the picker's apps as the page lists them.
    private static func row(_ role: AppRole, _ s: AppCollectionStores) -> [String: JSONValue] {
        let (pick, app) = role == .editor ? (s.editor.pick, s.editor.app) : (s.picks.picks[role], s.picks.app(role))
        let name = { AppRolePicks.name($0, role: role, appName: s.appName) }
        let choices = role == .editor ? s.editorChoices() : s.picks.choices(role).map { (name: name($0), bundle: $0) }
        var row: [String: JSONValue] = ["role": .string(role.rawValue), "pick": .string(pick ?? "automatic"),
                                        "automatic": .string(role == .editor ? s.editor.automatic : s.automatic(role)),
                                        "choices": .array(choices.map { .object(["bundle": .string($0.bundle), "name": .string($0.name)]) })]
        row["app"] = app.map { .string($0) }
        return row
    }

    private static func row(_ e: Extension) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(e.id), "title": .string(e.title),
                                        "commands": .array(e.listed.map { c in
            var command: [String: JSONValue] = ["name": .string(c.name), "title": .string(c.title), "mode": .string(c.mode.rawValue),
                                                "action": .string(c.actionID)]
            command["keyword"] = c.keyword.map { .string($0) }
            return .object(command)
        })]
        row["version"] = e.version.map { .string($0) }
        return row
    }
}
