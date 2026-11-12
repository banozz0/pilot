import Foundation
import Observation
import PilotCore
import Darwin

/// The only theme mutation route. Synchronous commit/recovery on MainActor cannot interleave across an Allow suspension.
@Observable @MainActor
final class ThemeCoordinator {
    private static var live: ThemeCoordinator?
    /// An isolated test run's folder is under /var/folders, a link the pack store's no-follow walk refuses, and its real
    /// /private/var is what ThemeFiles' link resolving (Foundation's) gives back as /var: no folder there serves both. So
    /// the sandbox host takes PILOT_SANDBOX_THEMES=<a throwaway folder with no link in its path> for the theme system, and
    /// as the built-in packs a test bundle lacks its `factory` folder when there is one, else the repo's Packaging/ThemePacks.
    private static let sandbox: (support: URL, factory: String)? = {
        #if DEBUG
        guard isIsolatedTestRun, let folder = ProcessInfo.processInfo.environment["PILOT_SANDBOX_THEMES"], folder.hasPrefix("/") else { return nil }
        let own = folder + "/factory"
        let factory = FileManager.default.fileExists(atPath: own) ? own
            : URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../Packaging/ThemePacks").standardizedFileURL.path
        return (URL(filePath: folder, directoryHint: .isDirectory), factory)
        #else
        return nil
        #endif
    }()
    private static var support: URL { sandbox?.support ?? PilotFolder.support.appending(path: "ThemeSystem") }

    /// Supported Ghostty destination, locally bound and shown in every plan. Portable data cannot replace it.
    static func production() throws -> ThemeCoordinator {
        if let live { return live }
        let packs = support.appending(path: "packs"), state = support.appending(path: "state")
        for directory in [packs, state] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let owner = ThemeCoordinator(store: ThemePackStore(root: packs.path, writableRoot: packs.path, factoryRoot: sandbox?.factory ?? Bundle.main.resourceURL?.appending(path: "ThemePacks").path),
            binding: ThemeBinding(root: isTestRun ? support.appending(path: "test-ghostty").path : NSHomeDirectory() + "/.config/ghostty", config: "config", generated: "pilot-theme.conf"),
            stateRoot: state.path, effects: .init(kind: "files and wallpaper", refresh: { "open a new window or reload the app to see it" },
                                                appearance: { Look.shared.packChanged($0) }, ghostty: { await GhosttyBridge.reloadNow() },
                                                btop: { isTestRun ? 0 : ThemeCoordinator.reloadBtop() }), reload: { intent in
                try await Task.detached {
                    try intent.launch { command in
                        let process = Process(); process.executableURL = URL(fileURLWithPath: command.executable); process.arguments = command.arguments
                        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
                        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        try process.run(); process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw ThemeFailure("reload helper exited \(process.terminationStatus)") }
                        return "reloaded"
                    }
                }.value
            },
            native: .init(read: {
                try BarItemsStore.shared.requireWritable()
                var value = Look.shared.nativeAppearance
                value.bar = .init(BarItemsStore.shared.settings.preset)
                value.cursor = CursorSets.shared.colours.rawValue
                value.dark = MacAppearance.isDark(); value.auto = MacAppearance.isAuto() ? true : nil
                return value
            }, write: { value in
                try BarItemsStore.shared.requireWritable()
                Look.shared.applyNative(value)
                if let bar = value.bar, BarItemsStore.shared.settings.preset != bar.configuration {
                    BarItemsStore.shared.settings.preset = bar.configuration
                }
                if let colours = CursorColours.saved(value.cursor), CursorSets.shared.colours != colours { CursorSets.shared.colours = colours }
            }, baseline: { Look.shared.nativeBaseline }, mode: { try await MacAppearance.switchTo(dark: $0) }), gate: AllowPrompt.gate, style: { Look.shared.style.rawValue }, wallpaper: WallpaperSwitch.themeEffects(),
            detect: isTestRun ? nil : { ThemeCoordinator.detectApps(home: NSHomeDirectory()) },  // A test host never reaches real configs.
            cursorIsSystem: { CursorSets.shared.set == .macOS },
            ghostexColours: isTestRun ? nil : GhostexColours.effects(), appsHome: isTestRun ? nil : NSHomeDirectory())
        owner.shipped = Shipped(wallpapers: ShippedWallpapers(root: support.appending(path: "wallpapers").path, source: CatalogueSource.live), index: {
            let model = ExtensionCatalogueModel.shared
            await model.open()
            if case .failed(let why) = model.load { throw ThemeFailure(why) }
            guard let index = model.index else { throw ThemeFailure("the catalogue did not read") }
            return index
        })
        _ = try owner.recoverAtLaunch()
        live = owner
        return owner
    }

    static func persistedPack() throws -> ThemePack? {
        let path = support.appending(path: "state/ownership.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let ledger = try ThemeLedger.decode(Data(contentsOf: path))
        guard ledger.schema == 1, (ledger.claims.isEmpty && (ledger.wallpapers ?? []).isEmpty && ledger.appearance == nil) == (ledger.selected == nil) else { throw ThemeFailure("corrupt ownership ledger") }
        if let selected = ledger.selected { _ = try ThemePack.decode(ThemeDigest.encoded(selected)) }
        return ledger.selected
    }

    static func legacyAllowed() -> Bool {
        if FileManager.default.fileExists(atPath: support.appending(path: "state/pending.json").path) { return false }
        do { return try persistedPack() == nil }
        catch { return false }
    }

    struct Effects {
        let kind: String
        let refresh: () throws -> String
        let appearance: (ThemePack?) -> Void
        /// Ghostty › Reload Configuration once its files changed: true pressed, false no such item, nil not running.
        var ghostty: () async -> Bool? = { nil }
        /// SIGUSR2 to the person's running btop once its files changed: how many took it.
        var btop: () async -> Int = { 0 }
    }
    /// A real adapter and a recording adapter use this same seam. No singleton/default desktop dependency.
    struct WallpaperEffects {
        let read: () throws -> ThemeWallpaperState
        let write: (ThemeWallpaperMutation) throws -> Void
        /// The screen's own name, for what a person reads. Nil falls back to "Display 1".
        var name: (String) -> String? = { _ in nil }
    }
    /// Ghostex's interface colours. `read` is nil when it is closed; no test host gets the real one.
    struct GhostexEffects {
        let installed: () -> Bool
        /// Ghostex's colours, nil while it is closed, and a setting written: each a child process awaited off the main thread,
        /// so Preview, Apply, Restore and recovery never hold the Hyper tap on Ghostex.
        let read: () async throws -> [String: String]?
        let write: (String, String) async throws -> Void
    }
    struct NativeEffects {
        let read: () throws -> ThemeNativeAppearance
        let write: (ThemeNativeAppearance) throws -> Void
        let baseline: (() throws -> ThemeNativeAppearance)?
        /// macOS's Light or Dark mode, awaited off the main thread; `write` never sets it.
        var mode: ((Bool) async throws -> Void)? = nil
        init(read: @escaping () throws -> ThemeNativeAppearance, write: @escaping (ThemeNativeAppearance) throws -> Void, baseline: (() throws -> ThemeNativeAppearance)? = nil,
             mode: ((Bool) async throws -> Void)? = nil) {
            self.read = read; self.write = write; self.baseline = baseline; self.mode = mode
        }
    }
    /// Production Process and fixture recording vary only here; no portable or recovery executor.
    let reload: (ThemeReloadIntent) async throws -> String
    let native: NativeEffects?
    let wallpaper: WallpaperEffects?
    let store: ThemePackStore
    let binding: ThemeBinding
    let stateRoot: String
    let effects: Effects
    let gate: ControlGate
    let style: () -> String
    let context: () throws -> String
    let fault: (String) throws -> Void
    struct LocalSelection: Codable, Equatable {
        var zed: ThemeBinding?
        var zedOptOut = false
        var obsidian: [ThemeBinding]?
        var obsidianOptOut: Bool?
        var custom: [ThemeMappingBinding]?
        /// Detected vaults switched off: roots to skip, never a read or write target.
        var obsidianOff: [String]?
        /// Detected destinations an Apply wrote. Their claims stay authorized if detection stops finding them.
        var adoptedZed: ThemeBinding?
        var adoptedObsidian: [ThemeBinding]?
        /// Folders an Apply created. Removed once empty and nothing Pilot owns is in them.
        var madeFolders: [String]?
        /// Only an earlier build set this, when Ghostex's terminal still followed themes. Kept so Restore can take that out.
        var ghostex: ThemeBinding?
        /// The "Ghostex follows" switch: its window and sidebar colour. Not the old terminal switch.
        var ghostexInterfaceOff: Bool?
        var adoptedApps: [ThemeAppBinding]?
        var appsOff: [ThemeAppKind]?
        /// Worked out per plan, like `ghostex`; never saved on its own.
        var apps: [ThemeAppBinding]?
    }
    private let initialSelection: LocalSelection
    /// Production only, or a fixture's own home. Nil keeps explicit bindings the only destinations.
    private let detect: (() -> DetectedApps)?
    /// True while Look › Cursor is macOS's own pointer, which colours cannot change.
    private let cursorIsSystem: () -> Bool
    let ghostexColours: GhostexEffects?
    /// Where apps' own configs may be links; nil in a test host.
    private let appsHome: String?
    private let fixtureRoot: String?
    private var fixtureEditor: ThemeDraftSession?
    /// Where a shipped pack's pictures come from (ShippedWallpapers, Sven Q119): the catalogue's copy, fetched by a plan
    /// of that pack; nil in tests and fixtures, which never reach the network.
    struct Shipped {
        let wallpapers: ShippedWallpapers
        let index: @MainActor () async throws -> ExtensionCatalogue.Index
    }
    var shipped: Shipped?
    /// What the ledger and recovery may name: stored bindings plus the detected destinations an Apply took on.
    private func selection() throws -> LocalSelection {
        var local = try stored()
        if local.zed == nil { local.zed = local.adoptedZed }
        local.apps = local.adoptedApps
        if let adopted = local.adoptedObsidian { local.obsidian = Self.merged(local.obsidian ?? [], adding: adopted) }
        return local
    }
    private static func merged(_ vaults: [ThemeBinding], adding more: [ThemeBinding]) -> [ThemeBinding] {
        vaults + more.filter { vault in !vaults.contains { $0.root == vault.root } }
    }
    private func stored() throws -> LocalSelection {
        let bytes = try state("bindings").bytes
        let local = try bytes.map { try JSONDecoder().decode(LocalSelection.self, from: $0) } ?? initialSelection
        if let bytes { try ThemeLedger.validateFields(bytes, field: "custom", encoded: local.custom.map { try ThemeDigest.encoded($0) }) }
        try validateCustom(local)
        if let zed = local.zed {
            guard zed.config == "settings.json", zed.generated == "themes/pilot-theme.json", zed.root.hasPrefix("/"),
                  URL(fileURLWithPath: zed.root).standardizedFileURL.path == zed.root,
                  fixtureRoot.map({ zed.root.hasPrefix($0 + "/") }) ?? true else { throw ThemeFailure("unsafe local Zed binding") }
        }
        let vaults = local.obsidian ?? []
        guard Set(vaults.map(\.root)).count == vaults.count else { throw ThemeFailure("duplicate Obsidian vault bindings") }
        for vault in vaults {
            let configDir = String(vault.config.dropLast("/appearance.json".count))
            guard try ObsidianThemeAdapter.binding(root: vault.root, configDir: configDir) == vault,
                  fixtureRoot.map({ vault.root.hasPrefix($0 + "/") }) ?? true else { throw ThemeFailure("unsafe local Obsidian binding") }
        }
        return local
    }
    private func validateCustom(_ local: LocalSelection) throws {
        let bindings = local.custom ?? []
        guard Set(bindings.map(\.id)).count == bindings.count else { throw ThemeFailure("duplicate custom local binding identity") }
        let protected = [binding.root, stateRoot, store.root, store.writableRoot] + [store.factoryRoot, local.zed?.root].compactMap { $0 } + (local.obsidian ?? []).map(\.root) + bindings.map(\.app)
        var targets: [ThemeSnapshot] = []
        for item in bindings {
            try item.validate()
            guard fixtureRoot.map({ item.root.hasPrefix($0 + "/") && item.app.hasPrefix($0 + "/") }) ?? true,
                  URL(fileURLWithPath: item.app).resolvingSymlinksInPath().path == item.app else { throw ThemeFailure("unsafe custom app binding") }
            _ = try ThemeFiles.read(root: item.app, path: "Contents/Info.plist")
            let target = try ThemeFiles.read(root: item.root, path: item.path)
            guard try !protected.contains(where: { try Self.pathContains($0, target.resolved, missing: true) }) else { throw ThemeFailure("custom destination aliases protected built-in/store/state/app resource") }
            for other in targets where other.root != target.root || other.path != target.path {
                guard try !Self.pathContains(other.resolved, target.resolved, missing: true),
                      try !Self.pathContains(target.resolved, other.resolved, missing: true) else { throw ThemeFailure("custom destination aliases another binding") }
            }
            targets.append(target)
        }
    }

    /// Select local authority separately from editing/importing portable templates. Never executes reload.
    func bindCustom(_ item: ThemeMappingBinding, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard !busy else { throw ControlError(.badValue, "theme mutation already waiting/running") }
        busy = true; defer { busy = false }
        do {
            guard try state("pending").bytes == nil, try ledger().1.selected == nil else { throw ThemeFailure("Restore active appearance/recovery before changing bindings") }
            var next = try stored()
            next.custom = (next.custom ?? []).filter { $0.id != item.id } + [item]
            try validateCustom(next)
            let before = try state("bindings"), ownership = try state("ownership"), pending = try state("pending")
            let target = try ThemeFiles.read(root: item.root, path: item.path), revision = try context(), chosen = next
            return try await gate.allow(.init("Select custom theme destination", "\(item.id): \(item.root)/\(item.path); app \(item.app). Reload configuration only; executes nothing."), peer: peer) { () throws(ControlError) in
                do {
                    guard try self.state("bindings") == before, try self.state("ownership") == ownership, try self.state("pending") == pending,
                          try self.context() == revision, try ThemeFiles.read(root: item.root, path: item.path) == target else { throw ThemeFailure("stale custom binding after Allow") }
                    try self.validateCustom(chosen)
                    _ = try ThemeFiles.write(ThemeDigest.encoded(chosen), over: before)
                    self.plans.removeAll()
                    return .object(["status": .string("custom destination locally selected; no app files or programs changed")])
                } catch { throw ControlError(.badValue, String(describing: error)) }
            }
        } catch let error as ControlError { throw error }
        catch { throw ControlError(.badValue, String(describing: error)) }
    }

    var zedSelection: LocalSelection { get throws { try selection() } }

    /// The CLI's explicit route, beside what detection finds; packs cannot invoke it.
    func bindZed(_ root: String?, optOut: Bool, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard !busy else { throw ControlError(.badValue, "theme mutation already waiting/running") }
        busy = true; defer { busy = false }
        do {
            guard try state("pending").bytes == nil, try ledger().1.selected == nil else { throw ThemeFailure("Restore active appearance/recovery before changing bindings") }
            if let root {
                guard root.hasPrefix("/"), URL(fileURLWithPath: root).standardizedFileURL.path == root,
                      !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      fixtureRoot.map({ root.hasPrefix($0 + "/") }) ?? true else { throw ThemeFailure("unsafe explicit Zed root") }
                _ = try ThemeFiles.read(root: root, path: "settings.json")
                _ = try ThemeFiles.read(root: root, path: "themes/pilot-theme.json")
            }
            let before = try state("bindings"), ownership = try state("ownership"), pending = try state("pending")
            var next = try stored()
            next.zed = root.map { ThemeBinding(root: $0, config: "settings.json", generated: "themes/pilot-theme.json") }; next.zedOptOut = optOut
            try validateCustom(next)
            let chosen = next
            return try await gate.allow(.init("Select Zed theme destination", root ?? (optOut ? "Zed opted out" : "Zed not selected")), peer: peer) { () throws(ControlError) in
                do {
                    guard try self.state("bindings") == before, try self.state("ownership") == ownership, try self.state("pending") == pending else { throw ThemeFailure("stale binding selection") }
                    try self.validateCustom(chosen)
                    _ = try ThemeFiles.write(ThemeDigest.encoded(chosen), over: before)
                    self.plans.removeAll()
                    return .object(["status": .string(optOut ? "Zed opted out; no Zed reads/writes" : "Zed locally selected; installation unknown")])
                } catch { throw ControlError(.badValue, String(describing: error)) }
            }
        } catch let error as ControlError { throw error }
        catch { throw ControlError(.badValue, String(describing: error)) }
    }
    /// Explicitly chosen vault + configured folder, with no registry/discovery or portable authority.
    func bindObsidian(_ root: String?, configDir: String?, optOut: Bool, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard !busy else { throw ControlError(.badValue, "theme mutation already waiting/running") }
        busy = true; defer { busy = false }
        do {
            guard try state("pending").bytes == nil, try ledger().1.selected == nil else { throw ThemeFailure("Restore active appearance/recovery before changing bindings") }
            var next = try stored()
            var observed: [ThemeSnapshot] = []
            if optOut {
                // An opted-out root is only an identifier to remove; it is never a filesystem target.
                next.obsidian = root.map { root in (next.obsidian ?? []).filter { $0.root != root } } ?? []
                if let root, detect != nil { next.obsidianOff = ((next.obsidianOff ?? []).filter { $0 != root } + [root]).sorted() }
                else { next.obsidianOptOut = true }
            } else {
                guard let root, let configDir, fixtureRoot.map({ root.hasPrefix($0 + "/") }) ?? true else { throw ThemeFailure("unsafe explicit Obsidian root") }
                let vault = try ObsidianThemeAdapter.binding(root: root, configDir: configDir)
                observed = try [vault.generated, vault.config].map { try ThemeFiles.read(root: root, path: $0) }
                var vaults = next.obsidian ?? []; vaults.removeAll { $0.root == root }; vaults.append(vault)
                next.obsidian = vaults
            }
            let before = try state("bindings"), ownership = try state("ownership"), pending = try state("pending")
            try validateCustom(next)
            let chosen = next, snapshots = observed, revision = try context()
            return try await gate.allow(.init("Select Obsidian theme vaults", optOut ? "Stop following in \(root ?? "all selected vaults")" : "\(root!) / \(configDir!); pilot-theme.css and individual snippet membership"), peer: peer) { () throws(ControlError) in
                do {
                    guard try self.state("bindings") == before, try self.state("ownership") == ownership, try self.state("pending") == pending else { throw ThemeFailure("stale binding selection") }
                    guard try self.context() == revision else { throw ThemeFailure("stale binding context after Allow") }
                    for target in snapshots {
                        guard try ThemeFiles.read(root: target.root, path: target.path) == target else { throw ThemeFailure("stale binding target after Allow") }
                    }
                    try self.validateCustom(chosen)
                    _ = try ThemeFiles.write(ThemeDigest.encoded(chosen), over: before)
                    self.plans.removeAll()
                    return .object(["status": .string(optOut ? "Obsidian vault opted out; no target reads/writes" : "Obsidian vault locally selected; installation unknown")])
                } catch { throw ControlError(.badValue, String(describing: error)) }
            }
        } catch let error as ControlError { throw error }
        catch { throw ControlError(.badValue, String(describing: error)) }
    }
    /// SIGUSR2 to each process named btop this user owns: btop re-reads btop.conf and its theme on it (its source, v1.4.8;
    /// Omarchy's omarchy-restart-btop does the same), so an open one follows without Ctrl+R. Another user's btop, a root one
    /// included, is never listed. Returns how many took the signal.
    nonisolated static func reloadBtop() -> Int {
        let uid = getuid(), width = MemoryLayout<pid_t>.size
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(size) / width + 16)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * width))
        guard bytes > 0 else { return 0 }
        var signalled = 0
        for pid in pids.prefix(Int(bytes) / width) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "btop" else { continue }
            if kill(pid, SIGUSR2) == 0 { signalled += 1 }
        }
        return signalled
    }
    struct DetectedApps: Equatable {
        var zed: ThemeBinding?
        var vaults: [ThemeBinding] = []
        var apps: [ThemeAppBinding] = []
    }
    private nonisolated static func folder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }
    /// Zed's config folder and Obsidian's listed vaults. The list is data only, never written; anything unreadable means no vaults.
    /// `within` keeps a fixture's detection inside its own folder.
    nonisolated static func detectApps(home: String, within: String? = nil) -> DetectedApps {
        // A fixture looks only in its own home's Applications folder, never the Mac's.
        var found = DetectedApps(apps: ThemeApps.detect(home: home, applications: within == nil ? ["/Applications", home + "/Applications"] : [home + "/Applications"]))
        let zed = home + "/.config/zed"
        if folder(zed) { found.zed = ThemeBinding(root: zed, config: "settings.json", generated: "themes/pilot-theme.json") }
        guard let bytes = (try? ThemeFiles.read(root: home + "/Library/Application Support/obsidian", path: "obsidian.json"))?.bytes, bytes.count < 4_000_000,
              let listed = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["vaults"] as? [String: Any] else { return found }
        for root in Set(listed.values.compactMap({ ($0 as? [String: Any])?["path"] as? String })).sorted() where within.map({ root.hasPrefix($0 + "/") }) ?? true {
            guard let vault = try? ObsidianThemeAdapter.binding(root: root, configDir: ".obsidian"), folder(root + "/.obsidian") else { continue }
            found.vaults.append(vault)
        }
        return found
    }

    /// A destination's file as planned. A detected app's generated file may wait on a folder Apply will make.
    private func observe(_ root: String, _ path: String) throws -> ThemeSnapshot {
        if detect != nil, path == "themes/pilot-theme.json" || path.hasSuffix("/snippets/pilot-theme.css")
                            || appsHome.map({ ThemeApps.roots(home: $0).contains { $0.caseInsensitiveCompare(root) == .orderedSame } }) == true,
           let absent = ThemeFiles.inMissingFolder(root: root, path: path) { return absent }
        return try destination(root, path)
    }
    /// Ghostty's config alone may be a link out of its folder, as dotfiles users have it: the block goes in the real file and
    /// the link stays. Decided here from the fixed binding, never from a journal, and never for any other destination.
    private func linked(_ root: String, _ path: String) -> Bool {
        root == binding.root && path == binding.config || appsHome.map { ThemeApps.linkable(root: root, path: path, home: $0) } == true
    }
    private func destination(_ root: String, _ path: String) throws -> ThemeSnapshot {
        try ThemeFiles.read(root: root, path: path, linkedLeaf: linked(root, path))
    }
    /// A recorded anchor against what is there now. Only Ghostty's linked config has an older form to accept.
    private func anchored(_ recorded: String, _ current: ThemeSnapshot) -> Bool {
        current.anchor == recorded || linked(current.root, current.path) && current.linkedOut && ThemeFiles.withoutLinkIdentity(recorded) == current.anchor
    }
    private func replace(_ bytes: Data?, over target: ThemeSnapshot) throws -> ThemeSnapshot {
        try ThemeFiles.write(bytes, over: target, linkedLeaf: linked(target.root, target.path))
    }

    /// Throws why a detected Zed that Pilot does not own yet cannot take this pack.
    private func checkDetected(zed: ThemeBinding, _ pack: ThemePack) throws {
        let settings = try ThemeFiles.read(root: zed.root, path: zed.config)
        guard try observe(zed.root, zed.generated).bytes == nil else { throw ThemeFailure("a pilot-theme.json from somewhere else is already there") }
        _ = try ZedThemeAdapter.selectors(pack, settings: settings.bytes, absentFollows: true)
    }
    private func checkDetected(app: ThemeAppBinding, _ pack: ThemePack) throws {
        _ = try ThemeApps.prepare(pack, app: app, snapshots: app.paths.map { try observe(app.root, $0) }, claims: [])
    }
    private func checkDetected(vault: ThemeBinding) throws {
        let asset = try observe(vault.root, vault.generated), settings = try ThemeFiles.read(root: vault.root, path: vault.config)
        try ObsidianThemeAdapter.validateExisting(asset.bytes)
        _ = try ThemeJSONC(settings.bytes ?? Data("{}".utf8)).owned(ObsidianThemeAdapter.membershipPath)
    }

    /// What follows now: stored choices, what Pilot still owns, then each detected app not switched off. An app that is
    /// not there adds nothing; one that cannot take this pack is skipped with a warning and never stops the plan.
    private func effective(for pack: ThemePack?) throws -> (local: LocalSelection, notes: [String]) {
        let saved = try stored()
        guard let detect else { return (saved, []) }
        let claims = try ledger().1.claims, owned = Set(claims.map(\.root)).subtracting(goneRoots(saved, claims: claims)), found = detect()
        var local = saved, notes: [String] = []
        func usable(_ name: String, adapter: String, _ check: () throws -> Void) -> Bool {
            guard pack?.adapters[adapter] != nil else { return true }
            do { try check(); return true } catch { notes.append("\(name) skipped: \(error)"); return false }
        }
        if local.zed == nil {
            if let adopted = saved.adoptedZed, owned.contains(adopted.root) { local.zed = adopted }
            else if !saved.zedOptOut, let zed = found.zed, usable("Zed", adapter: "zed", { try checkDetected(zed: zed, pack!) }) { local.zed = zed }
        }
        local.ghostex = saved.ghostex.flatMap { owned.contains($0.root) ? $0 : nil }
        var vaults = Self.merged(saved.obsidian ?? [], adding: (saved.adoptedObsidian ?? []).filter { owned.contains($0.root) })
        if saved.obsidianOptOut != true {
            for vault in found.vaults where !(saved.obsidianOff ?? []).contains(vault.root) && !vaults.contains(where: { $0.root == vault.root })
                && usable("Obsidian vault \(vault.root)", adapter: "obsidian", { try checkDetected(vault: vault) }) {
                vaults.append(vault)
            }
        }
        local.obsidian = vaults.sorted { $0.root < $1.root }
        var apps = (saved.adoptedApps ?? []).filter { owned.contains($0.root) }
        for app in found.apps where !(saved.appsOff ?? []).contains(app.kind) && !apps.contains(where: { $0.root == app.root }) {
            guard let pack else { apps.append(app); continue }
            do { try checkDetected(app: app, pack); apps.append(app) } catch { notes.append("\(app.kind.name) skipped: \(error)") }
        }
        local.apps = apps
        return (local, notes)
    }

    /// Detected destinations Pilot owns whose folder is gone (deleted, moved, a drive unplugged). There is nothing left to
    /// restore, so their claims drop with a warning and no write. A folder that exists but fails its checks still refuses.
    private func goneRoots(_ saved: LocalSelection, claims: [ThemeClaim]) -> Set<String> {
        guard detect != nil else { return [] }
        let known = [saved.adoptedZed?.root, saved.ghostex?.root, binding.root].compactMap { $0 } + (saved.adoptedObsidian ?? []).map(\.root) + (saved.adoptedApps ?? []).map(\.root)
        return Set(known.filter { root in
            var info = stat()
            return claims.contains { $0.root == root } && lstat(root, &info) != 0 && errno == ENOENT
        })
    }

    /// Inside Apply's Allow, before anything is written: makes the folders the plan waited on, and re-reads those files.
    private func makingFolders(_ plan: ThemePlan) throws -> ThemePlan {
        var made = false
        for change in uniqueResources(plan.mutations) where change.target.anchor == ThemeFiles.folderMissing {
            // Two files may wait on one folder: the first made it already, so none is missing for the second.
            guard let folders = ThemeFiles.missingFolders(change.target.resolved) else { throw ThemeFailure("cannot create the folder for \(change.target.resolved)") }
            for folder in folders {
                guard mkdir(folder, 0o755) == 0 else { throw ThemeFailure("cannot create \(folder)") }
                // One at a time, so a later failure cannot leave a folder nobody remembers making.
                var next = try stored()
                next.madeFolders = Array(Set((next.madeFolders ?? []) + [folder])).sorted()
                _ = try ThemeFiles.write(ThemeDigest.encoded(next), over: state("bindings"))
                made = true
            }
        }
        guard made else { return plan }
        func real(_ target: ThemeSnapshot) throws -> ThemeSnapshot {
            target.anchor == ThemeFiles.folderMissing ? try ThemeFiles.read(root: target.root, path: target.path) : target
        }
        var ready = plan
        ready.observations = try plan.observations.map(real)
        ready.mutations = try plan.mutations.map { change in
            var change = change
            change.target = try real(change.target)
            return change
        }
        return ready
    }

    /// Folders Apply made go once they are empty and nothing Pilot owns is in them. Never one Pilot did not make.
    private func removeMadeFolders() {
        guard let saved = try? stored(), let made = saved.madeFolders, let claims = try? ledger().1.claims, let file = try? state("bindings") else { return }
        // Innermost first, so a folder Apply made inside another it made goes before its parent is tried.
        let kept = made.sorted { $0.count > $1.count }.filter { folder in
            claims.contains { ($0.root + "/" + $0.path).hasPrefix(folder + "/") } || (rmdir(folder) != 0 && errno != ENOENT)
        }
        guard kept.count != made.count else { return }
        var next = saved
        next.madeFolders = kept.isEmpty ? nil : kept
        if let bytes = try? ThemeDigest.encoded(next) { _ = try? ThemeFiles.write(bytes, over: file) }
    }

    /// Inside Apply's Allow, before the journal: the detected destinations this plan writes become bound.
    private func adoptDetected(_ plan: ThemePlan) throws {
        guard detect != nil else { return }
        let file = try state("bindings"), saved = try stored()
        var next = saved
        let written = Set(plan.mutations.map(\.target.root)), explicit = saved.obsidian ?? []
        if saved.zed == nil, let zed = plan.zed, written.contains(zed.root) { next.adoptedZed = zed }
        let adopted = plan.obsidian.filter { vault in written.contains(vault.root) && !explicit.contains { $0.root == vault.root } }
        let vaults = Self.merged(adopted, adding: saved.adoptedObsidian ?? []).sorted { $0.root < $1.root }
        next.adoptedObsidian = vaults.isEmpty ? nil : vaults
        let apps = plan.apps.filter { written.contains($0.root) } + (saved.adoptedApps ?? []).filter { app in !plan.apps.contains { $0.root == app.root && written.contains($0.root) } }
        next.adoptedApps = apps.isEmpty ? nil : apps
        if next != saved { _ = try ThemeFiles.write(ThemeDigest.encoded(next), over: file) }
    }

    struct AppFollowing: Encodable {
        struct Vault: Encodable { let root: String; let on: Bool }
        let zedFound, zedOn, obsidianOn, ghostexFound, ghostexOn: Bool
        let vaults: [Vault]
        struct App: Encodable { let kind: String; let name: String; let on: Bool }
        let apps: [App]
    }
    enum AppSwitch { case zed, obsidian, ghostex, vault(String), app(ThemeAppKind) }
    func appFollowing() throws -> AppFollowing {
        let saved = try stored(), found = detect?() ?? DetectedApps()
        return AppFollowing(zedFound: found.zed != nil, zedOn: !saved.zedOptOut, obsidianOn: saved.obsidianOptOut != true, ghostexFound: ghostexColours?.installed() ?? false, ghostexOn: saved.ghostexInterfaceOff != true,
                            vaults: found.vaults.map { .init(root: $0.root, on: !(saved.obsidianOff ?? []).contains($0.root)) },
                            apps: found.apps.map { .init(kind: $0.kind.rawValue, name: $0.kind.name, on: !(saved.appsOff ?? []).contains($0.kind)) })
    }
    /// A personal switch like Zed follows: it only shapes the next plan, whose Apply asks Allow.
    func stageFollows(_ app: AppSwitch, on: Bool) throws -> AppFollowing {
        guard !busy, try state("pending").bytes == nil else { throw ThemeFailure("theme mutation or recovery in progress") }
        var next = try stored()
        switch app {
        case .zed: next.zedOptOut = !on
        case .obsidian: next.obsidianOptOut = !on
        case .ghostex: next.ghostexInterfaceOff = on ? nil : true
        case .app(let kind):
            let off = (next.appsOff ?? []).filter { $0 != kind } + (on ? [] : [kind])
            next.appsOff = off.isEmpty ? nil : off
        case .vault(let root):
            guard root.hasPrefix("/") else { throw ThemeFailure("absolute vault root required") }
            let off = (next.obsidianOff ?? []).filter { $0 != root } + (on ? [] : [root])
            next.obsidianOff = off.isEmpty ? nil : off.sorted()
        }
        _ = try ThemeFiles.write(ThemeDigest.encoded(next), over: state("bindings"))
        plans.removeAll()
        return try appFollowing()
    }

    private var plans: [String: (ThemePlan, String, ThemeAppearanceOwnership?, ThemeAppearanceMutation?)] = [:]
    private var busy = false
    /// What a recovery pass left for finishDue: macOS's mode to switch back to, and Ghostex settings to put back.
    private var modeDue: Bool?
    private var ghostexDue: [ThemeSettingMutation]?
    var message = ""
    var pendingPlan: ThemePlan?

    func appearanceChange(_ plan: ThemePlan) -> ThemeAppearanceMutation? { plans[plan.id]?.3 }

    init(store: ThemePackStore, binding: ThemeBinding, stateRoot: String, effects: Effects, reload: @escaping (ThemeReloadIntent) async throws -> String = { _ in throw ThemeFailure("reload effect unavailable") }, native: NativeEffects? = nil, gate: ControlGate,
         style: @escaping () -> String, context: @escaping () throws -> String = { "local" },
         fault: @escaping (String) throws -> Void = { _ in }, zed: ThemeBinding? = nil, zedOptOut: Bool = false, fixtureRoot: String? = nil, obsidian: [ThemeBinding] = [], obsidianOptOut: Bool = false, custom: [ThemeMappingBinding] = [], wallpaper: WallpaperEffects? = nil, detect: (() -> DetectedApps)? = nil, cursorIsSystem: @escaping () -> Bool = { false }, ghostexColours: GhostexEffects? = nil, appsHome: String? = nil) {
        self.appsHome = appsHome; self.ghostexColours = ghostexColours; self.cursorIsSystem = cursorIsSystem; self.detect = detect; self.wallpaper = wallpaper; self.native = native; self.reload = reload
        self.store = store; self.binding = binding; self.stateRoot = stateRoot; self.effects = effects
        self.gate = gate; self.style = style; self.context = context; self.fault = fault
        self.initialSelection = LocalSelection(zed: zed, zedOptOut: zedOptOut, obsidian: obsidian, obsidianOptOut: obsidianOptOut, custom: custom.isEmpty ? nil : custom); self.fixtureRoot = fixtureRoot
    }

    private func state(_ name: String) throws -> ThemeSnapshot { try ThemeFiles.read(root: stateRoot, path: name + ".json") }
    private func ledger() throws -> (ThemeSnapshot, ThemeLedger) {
        let observed = try state("ownership")
        guard let bytes = observed.bytes else { return (observed, ThemeLedger()) }
        let record = try ThemeLedger.decode(bytes)
        try validate(record)
        return (observed, record)
    }

    private func validate(_ record: ThemeLedger) throws {
        guard record.schema == 1, record.claims.allSatisfy({ $0.codec == 1 && validSelector($0.selector, root: $0.root, path: $0.path) }),
              Set(record.claims.map(\.identity)).count == record.claims.count,
              (record.claims.isEmpty && (record.wallpapers ?? []).isEmpty && record.appearance == nil) == (record.selected == nil) else { throw ThemeFailure("corrupt ownership ledger") }
        try validateWallpapers(record.wallpapers ?? [])
        guard Set((record.ghostexSettings ?? []).map(\.key)).count == (record.ghostexSettings ?? []).count,
              (record.ghostexSettings ?? []).allSatisfy({ GhostexInterface.valid(key: $0.key, values: [$0.original, $0.last]) }) else { throw ThemeFailure("corrupt Ghostex ownership") }
        if let appearance = record.appearance {
            guard native != nil, record.selected != nil else { throw ThemeFailure("unbound native appearance ownership") }
            try appearance.original.validate(); try appearance.last.validate()
            guard appearance.paletteOwned == appearance.following.palette, appearance.materialOwned == appearance.following.material,
                  (appearance.barOwned == true) == (appearance.following.bar == true),
                  appearance.cursorOwned != true || (appearance.following.cursor != false && appearance.original.cursor != nil && appearance.last.cursor == CursorColours.theme.rawValue),
                  appearance.modeOwned != true || (appearance.following.mode != false && appearance.original.dark != nil && appearance.last.dark == record.selected?.dark),
                  appearance.barOwned != true || (appearance.original.bar != nil && appearance.last.bar?.configuration == record.selected?.barPreset?.configuration && record.selected?.barPreset != nil),
                  !appearance.paletteOwned || appearance.last.palette == .pack(record.selected!),
                  !appearance.materialOwned || appearance.last.material == record.selected?.material else { throw ThemeFailure("inconsistent native component ownership") }
        }
        let ghostty = record.claims.filter { $0.root == binding.root && [binding.config, binding.generated].contains($0.path) }
        // Ownership may be partial: a part the person changed since was let go and the rest stays Pilot's.
        guard Set(ghostty.map(\.path)).count == ghostty.count else { throw ThemeFailure("duplicate Ghostty ownership") }
        let local = try selection()
        var remaining = record.claims.filter { !ghostty.contains($0) }
        for destination in [local.zed, local.ghostex].compactMap({ $0 }) + (local.obsidian ?? []) {
            let claims = remaining.filter { $0.root == destination.root && [destination.config, destination.generated].contains($0.path) }
            guard Set(claims.map(\.identity)).count == claims.count else { throw ThemeFailure("duplicate app ownership") }
            remaining.removeAll { claims.contains($0) }
        }
        for app in local.apps ?? [] {
            let claims = remaining.filter { $0.root == app.root && app.paths.contains($0.path) }
            guard Set(claims.map(\.identity)).count == claims.count else { throw ThemeFailure("duplicate app ownership") }
            remaining.removeAll { claims.contains($0) }
        }
        for item in local.custom ?? [] {
            let claims = remaining.filter { $0.bindingID == item.id && $0.root == item.root && $0.path == item.path }
            guard claims.allSatisfy({ claim in
                guard let mapping = record.selected?.customMappings?.first(where: { $0.id == item.id }) else { return false }
                return customSelector(claim.selector, matches: mapping)
            }) else { throw ThemeFailure("custom ownership selector changed") }
            remaining.removeAll { claims.contains($0) }
        }
        guard remaining.isEmpty else { throw ThemeFailure("unbound ownership") }
        try validateOverlaps(record.claims.map { ($0.root, $0.path, $0.selector) })
        if let selected = record.selected { _ = try ThemePack.decode(ThemeDigest.encoded(selected)) }
    }

    private func validSelector(_ selector: ThemeSelector, root: String, path: String) -> Bool {
        func ghosttyOwned(_ destination: ThemeBinding) -> Bool {
            switch selector {
            case .file: return path == destination.generated
            case .block(let begin, let end, let prefix):
                return path == destination.config && begin == GhosttyThemeAdapter.begin && end == GhosttyThemeAdapter.end && (0...2).contains(prefix)
            case .jsonValue, .jsonMembership, .blockAfter: return false
            }
        }
        if root == binding.root, ghosttyOwned(binding) { return true }
        guard let local = try? selection() else { return false }
        if let zed = local.zed, root == zed.root {
            switch selector {
            case .file: if path == zed.generated { return true }
            case .jsonValue(let keys): if path == zed.config && [["theme"], ["theme", "dark"], ["theme", "light"]].contains(keys) { return true }
            default: break
            }
        }
        if let ghostex = local.ghostex, root == ghostex.root, ghosttyOwned(ghostex) { return true }
        for app in local.apps ?? [] where root == app.root && ThemeApps.valid(selector, path: path, app: app) { return true }
        for vault in local.obsidian ?? [] where root == vault.root {
            switch selector {
            case .file: if path == vault.generated { return true }
            case .jsonMembership(let keys, let element, _):
                if path == vault.config && keys == ObsidianThemeAdapter.membershipPath && element == ObsidianThemeAdapter.element { return true }
            default: break
            }
        }
        return (local.custom ?? []).contains { item in
            guard root == item.root, path == item.path else { return false }
            // Exact template selector is additionally checked against selected pack in validate(record).
            switch selector {
            case .file: return true
            case .jsonValue(let keys): return !keys.isEmpty && keys.allSatisfy { !$0.isEmpty && !$0.utf8.contains(0) }
            case .block(let begin, let end, let prefix): return !begin.isEmpty && !end.isEmpty && begin != end && (0...1).contains(prefix)
            default: return false
            }
        }
    }

    private func customSelector(_ selector: ThemeSelector, matches mapping: ThemeMapping) -> Bool {
        if case .block(_, _, let prefix) = selector { return selector == mapping.selector(prefix: prefix) }
        return selector == mapping.selector()
    }

    private func validateOverlaps(_ claims: [(String, String, ThemeSelector)]) throws {
        for (index, claim) in claims.enumerated() {
            for other in claims.dropFirst(index + 1) where claim.0 == other.0 && claim.1 == other.1 {
                guard !claim.2.overlaps(other.2) else { throw ThemeFailure("overlapping ownership selectors") }
            }
        }
    }

    var ownsGhostty: Bool {
        // Corrupt/unreadable/pending state must also block legacy writers, never unlock them.
        do { return try state("pending").bytes != nil || ledger().1.selected != nil }
        catch { return true }
    }

    func selected() throws -> ThemePack? { try ledger().1.selected }
    func wallpaperClaims() throws -> [ThemeWallpaperClaim] { try ledger().1.wallpapers ?? [] }

    /// Every part a theme carries follows it and Restore default undoes it (Sven Q108); macOS's mode is the one choice
    /// left. A staged file from before, with a part kept personal, loads as following.
    func following() throws -> ThemeFollowing {
        var value = ThemeFollowing(); value.material = true; value.bar = true
        value.mode = try staged().mode
        return value
    }
    private func staged() throws -> ThemeFollowing {
        guard let data = try state("components").bytes else { return .init() }
        let value = try JSONDecoder().decode(ThemeFollowing.self, from: data)
        try ThemeLedger.validateFields(data, encoded: ThemeDigest.encoded(value))
        return value
    }

    /// Only stages Look's Follow light and dark; the next immutable plan observes these bytes, no effects occur here.
    func stageMode(follow: Bool) throws -> ThemeFollowing {
        guard !busy else { throw ThemeFailure("theme mutation already waiting/running") }
        var value = try staged(); value.mode = follow
        _ = try ThemeFiles.write(ThemeDigest.encoded(value), over: state("components"))
        return try following()
    }

    /// Old schema-1 owns a pack palette already, while Look retained its pre-pack stock ID.
    /// Only local composition supplies that baseline; migration never adopts the applied pack as its original.
    private func appearanceOwnership(_ record: ThemeLedger, current: ThemeNativeAppearance?) throws -> ThemeAppearanceOwnership? {
        if let value = record.appearance { return value }
        guard let pack = record.selected, let current else { return nil }
        guard current.palette == .pack(pack), let baseline = try native?.baseline?() else { throw ThemeFailure("legacy native baseline unavailable or later personal palette; Restore recovery retained") }
        try baseline.validate()
        return .init(original: baseline, last: current, following: .init(), paletteOwned: true, materialOwned: false)
    }

    private func appearancePlan(_ pack: ThemePack?, old owned: ThemeAppearanceOwnership?, following: ThemeFollowing) throws -> (ThemeAppearanceOwnership?, ThemeAppearanceMutation?, [String]) {
        guard let native else { return (nil, nil, []) }  // No Look here: nothing of it to take.
        let current = try native.read(); try current.validate()
        // A part the person changed since is theirs: let go, so Restore leaves it and Apply takes it as the new original.
        let kept = owned?.changed(in: current) ?? []
        let old = owned?.releasing(kept)
        guard pack != nil || old != nil else { return (nil, nil, kept) }
        var original = old?.original ?? current, after = current
        let ownsPalette = pack != nil && following.palette, ownsMaterial = pack?.material != nil && following.material
        if ownsPalette {
            if old?.paletteOwned != true { original.palette = current.palette }
            after.palette = .pack(pack!)
        } else if old?.paletteOwned == true { after.palette = original.palette.current }  // A retired original comes back as its successor.
        if ownsMaterial, let material = pack?.material {
            if old?.materialOwned != true { original.material = current.material }
            after.material = material
        } else if old?.materialOwned == true { after.material = original.material }
        let ownsBar = pack?.barPreset != nil && current.bar != nil && following.bar == true
        if ownsBar, let preset = pack?.barPreset {
            if old?.barOwned != true { original.bar = current.bar }
            after.bar = .init(preset.configuration)
        } else if old?.barOwned == true { after.bar = original.bar }
        // macOS's own pointer takes no colours, so a theme claims nothing there (review blocker 4).
        let ownsCursor = pack != nil && following.cursor != false && current.cursor != nil && !cursorIsSystem()
        if ownsCursor {
            if old?.cursorOwned != true { original.cursor = current.cursor }
            after.cursor = CursorColours.theme.rawValue
        } else if old?.cursorOwned == true { after.cursor = original.cursor }
        let ownsMode = pack != nil && following.mode != false && current.dark != nil && current.auto != true  // Auto stays Auto.
        if ownsMode {
            if old?.modeOwned != true { original.dark = current.dark }
            after.dark = pack!.dark
        } else if old?.modeOwned == true { after.dark = original.dark }
        guard after.palette.compatible(with: style()) else { throw ThemeFailure("original/personal palette incompatible with current style; choose its compatible style before Restore") }
        // What the theme took, so the ledger's following matches what it owns.
        var took = following; took.material = ownsMaterial; took.bar = ownsBar ? true : nil
        let next = pack.map { _ in ThemeAppearanceOwnership(original: original, last: after, following: took, paletteOwned: ownsPalette, materialOwned: ownsMaterial, barOwned: ownsBar ? true : nil, cursorOwned: ownsCursor ? true : nil, modeOwned: ownsMode ? true : nil) }
        return (next, .init(before: current, after: after, palette: ownsPalette || old?.paletteOwned == true, material: ownsMaterial || old?.materialOwned == true, bar: ownsBar || old?.barOwned == true ? true : nil, cursor: ownsCursor || old?.cursorOwned == true ? true : nil, mode: ownsMode || old?.modeOwned == true ? true : nil), kept)
    }

    private func validateAppearanceJournal(_ journal: ThemeJournal) throws {
        let before = try journal.beforeLedger.map(ThemeLedger.decode) ?? ThemeLedger()
        guard let bytes = journal.afterLedger else { throw ThemeFailure("missing recovery ledger") }
        let after = try ThemeLedger.decode(bytes)
        guard let change = journal.appearance else {
            guard before.appearance == after.appearance else { throw ThemeFailure("unjournaled native ownership change") }; return
        }
        guard native != nil else { throw ThemeFailure("unbound native recovery") }
        try change.before.validate(); try change.after.validate()
        // Parts the person changed since were let go by the plan, exactly as appearancePlan masks them.
        let keptLook = journal.keptLook ?? []
        guard keptLook.allSatisfy(ThemeAppearanceOwnership.parts.contains) else { throw ThemeFailure("inconsistent kept native journal") }
        let oldAppearance = try appearanceOwnership(before, current: change.before)?.releasing(keptLook)
        if let old = oldAppearance {
            guard (!old.paletteOwned || old.last.palette == change.before.palette),
                  (!old.materialOwned || old.last.material == change.before.material),
                  (old.barOwned != true || old.last.bar == change.before.bar),
                  (old.cursorOwned != true || old.last.cursor == change.before.cursor),
                  (old.modeOwned != true || old.last.dark == change.before.dark) else { throw ThemeFailure("inconsistent native pre-state") }
        }
        if let old = oldAppearance {
            // Releasing one component has the same original-state invariant as full Restore.
            guard old.barOwned != true || after.appearance?.barOwned == true || change.after.bar == old.original.bar,
                  old.cursorOwned != true || after.appearance?.cursorOwned == true || change.after.cursor == old.original.cursor,
                  old.modeOwned != true || after.appearance?.modeOwned == true || change.after.dark == old.original.dark,
                  !old.paletteOwned || after.appearance?.paletteOwned == true || change.after.palette == old.original.palette.current,
                  !old.materialOwned || after.appearance?.materialOwned == true || change.after.material == old.original.material else { throw ThemeFailure("inconsistent native release") }
        }
        if let next = after.appearance {
            guard next.last == change.after,
                  change.palette == (next.paletteOwned || oldAppearance?.paletteOwned == true),
                  change.material == (next.materialOwned || oldAppearance?.materialOwned == true),
                  (change.bar == true) == (next.barOwned == true || oldAppearance?.barOwned == true),
                  (change.cursor == true) == (next.cursorOwned == true || oldAppearance?.cursorOwned == true),
                  next.cursorOwned != true || next.original.cursor == (oldAppearance?.cursorOwned == true ? oldAppearance!.original.cursor : change.before.cursor),
                  (change.mode == true) == (next.modeOwned == true || oldAppearance?.modeOwned == true),
                  next.modeOwned != true || next.original.dark == (oldAppearance?.modeOwned == true ? oldAppearance!.original.dark : change.before.dark),
                  next.barOwned != true || next.original.bar == (oldAppearance?.barOwned == true ? oldAppearance!.original.bar : change.before.bar),
                  !next.paletteOwned || next.original.palette == (oldAppearance?.paletteOwned == true ? oldAppearance!.original.palette : change.before.palette),
                  !next.materialOwned || next.original.material == (oldAppearance?.materialOwned == true ? oldAppearance!.original.material : change.before.material) else { throw ThemeFailure("inconsistent native original/last") }
        } else {
            guard let old = oldAppearance, change.palette == old.paletteOwned, change.material == old.materialOwned,
                  (change.bar == true) == (old.barOwned == true),
                  (change.cursor == true) == (old.cursorOwned == true),
                  (change.mode == true) == (old.modeOwned == true) else { throw ThemeFailure("inconsistent native release") }
        }
        guard change.palette || change.before.palette == change.after.palette,
              change.material || change.before.material == change.after.material,
              change.bar == true || change.before.bar == change.after.bar,
              change.cursor == true || change.before.cursor == change.after.cursor,
              change.mode == true || change.before.dark == change.after.dark else { throw ThemeFailure("unowned native mutation") }
    }

    /// Local read/write destinations are never taken from portable data, including in the private host.
    func editorPath(_ path: String, output: Bool = false) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              fixtureRoot.map({ path.hasPrefix($0 + "/") }) ?? true else { throw ThemeFailure("explicit local editor path required") }
        if output {
            let local = try selection()
            let protected = [stateRoot, store.root, store.writableRoot, binding.root] + [store.factoryRoot, local.zed?.root].compactMap { $0 } + (local.obsidian ?? []).map(\.root) + (local.custom ?? []).map(\.root)
            guard try !protected.contains(where: { try Self.pathContains($0, path, missing: true) }) else { throw ThemeFailure("export overlaps protected store/state/app destination") }
        }
    }

    func export(_ id: String, to path: String) throws {
        try editorPath(path, output: true)
        try store.export(id, to: path, fault: { stage in
            try fault(stage)
            try editorPath(path, output: true)
        })
    }

    /// Isolated CLI drives the same native operation state/handler; no view or production discovery.
    func fixtureDraft(_ words: [String]) async throws -> JSONValue {
        guard let fixtureRoot, native != nil, wallpaper != nil else { throw ThemeFailure("explicit recording editor fixture required") }
        if fixtureEditor == nil { fixtureEditor = ThemeDraftSession() }
        let editor = fixtureEditor!
        switch words.first {
        case "open" where words.count == 2: editor.draft = try store.draft(words[1])
        case "title" where words.count == 2: editor.draft?.pack.title = words[1]
        case "identity" where words.count == 2: editor.draft?.pack.id = words[1]
        case "cancel" where words.count == 1: editor.draft = nil
        case "close" where words.count == 1: editor.invalidate()
        case "attach" where words.count == 3:
            try editorPath(words[1])
            guard ThemePack.validID(words[2]) else { throw ThemeFailure("invalid fixture barrier identity") }
            let path = words[1], barrier = fixtureRoot + "/attach-" + words[2]
            await editor.attach([path], ifCurrent: editor.generation, read: { paths, draft in
                try Data().write(to: URL(fileURLWithPath: barrier + "-asked"))
                for _ in 0..<1000 {
                    if FileManager.default.fileExists(atPath: barrier + "-go") {
                        return try await Task.detached { try ThemePackStore.attaching(paths, to: draft) }.value
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw ThemeFailure("fixture attachment barrier timed out")
            })
        case "status" where words.count == 1: break
        default: throw ThemeFailure("unknown fixture editor operation")
        }
        return .object(["draft": try editor.draft.map { try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded($0)) } ?? .null,
                        "loading": .bool(editor.loading), "error": .string(editor.error)])
    }

    @discardableResult func saveDraft(_ draft: ThemePackStore.Draft, replacing revision: String? = nil) throws -> ThemePackStore.Loaded {
        guard !busy else { throw ThemeFailure("theme mutation already waiting/running") }
        busy = true; defer { busy = false }
        if revision != nil, try store.draft(draft.pack.id).files.filter({ $0.key != "PROVENANCE.md" }) != draft.files.filter({ $0.key != "PROVENANCE.md" }) {
            if try wallpaperUses(store.load(draft.pack.id).folder) {
                let previous = try store.draft(draft.pack.id)
                guard previous.files.filter({ $0.key != "PROVENANCE.md" }) == draft.files.filter({ $0.key != "PROVENANCE.md" }) else {
                    throw ThemeFailure("Wallpaper files are in use by current appearance or Restore. Start with Duplicate before changing images, or Restore and choose other wallpaper first. Draft not saved; nothing applied.")
                }
            }
        }
        // No plan is regenerated here. Existing plans detect changed exact content before/after Allow.
        return try store.save(draft, replacing: revision, fault: fault)
    }

    /// Whether the wallpaper on screen, or one Restore puts back, is in this folder. `missing` locates a file since removed
    /// by the folder that held it; without it a missing, broken or unreadable reference counts as in use, as nothing proves
    /// its bytes are safe to replace.
    private func wallpaperUses(_ folder: String, missing: Bool = false) throws -> Bool {
        var paths: [String] = []
        for claim in try ledger().1.wallpapers ?? [] {
            for value in [claim.original, claim.last] {
                switch value { case .sources(let values): paths += values; case .image(let path): if let path { paths.append(path) } }
            }
        }
        func strings(_ value: JSONValue) -> [String] {
            switch value {
            case .string(let value): [value]
            case .array(let values): values.flatMap(strings)
            case .object(let values): values.values.flatMap(strings)
            default: []
            }
        }
        if let current = try wallpaper?.read() {
            try current.validate()
            paths += current.sources + current.displays.compactMap(\.image) + current.preferences.values.flatMap(strings)
        }
        return paths.filter { $0.hasPrefix("/") }.contains { path in
            (try? Self.pathContains(folder, path, missing: missing) || Self.pathContains(path, folder, missing: missing)) ?? true
        }
    }

    /// Deletes a pack a person made. The applied pack, and one holding a wallpaper on screen or one Restore puts back, stay:
    /// Restore needs nothing else from a pack's folder, as the ledger keeps every colour it sets (ThemeLedger.selected,
    /// ThemeNativePalette.pack).
    func delete(_ id: String) throws {
        guard !busy else { throw ThemeFailure("theme mutation already waiting/running") }
        busy = true; defer { busy = false }
        guard !store.isPilots(id) else { throw ThemePackStore.pilotsOwn(id) }
        guard let loaded = try? store.load(id) else { throw ThemeFailure("No theme pack is named \(id); pilot theme list-all shows them.") }
        guard try ledger().1.selected?.id != id else { throw ThemeFailure("\(loaded.pack.title) is the theme applied now. Apply another theme or Restore default first, then delete it.") }
        guard try !wallpaperUses(loaded.folder, missing: true) else {
            throw ThemeFailure("\(loaded.pack.title)'s wallpaper is on screen or is what Restore puts back. Pick another wallpaper or Restore default first, then delete it.")
        }
        try store.delete(id)
    }

    /// Compare filesystem identities along resolved ancestry, including aliases of any ancestor.
    /// Only export may project absent suffixes, using the actual volume's case policy.
    private static func pathContains(_ ancestor: String, _ descendant: String, missing: Bool = false) throws -> Bool {
        func locate(_ path: String) throws -> (String, [String]) {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ThemeFailure("ambiguous local reference") }
            var current = path, suffix: [String] = []
            while true {
                if let resolved = realpath(current, nil) {
                    defer { free(resolved) }
                    return (String(cString: resolved), suffix)
                }
                let failure = errno
                var info = stat()
                guard missing, failure == ENOENT, lstat(current, &info) != 0, errno == ENOENT, current != "/" else { throw ThemeFailure("broken/unreadable local reference") }
                let url = URL(fileURLWithPath: current)
                suffix.insert(url.lastPathComponent, at: 0); current = url.deletingLastPathComponent().path
            }
        }
        func identity(_ path: String) throws -> String {
            var info = stat()
            guard stat(path, &info) == 0 else { throw ThemeFailure("local reference changed") }
            return "\(info.st_dev):\(info.st_ino)"
        }
        let a = try locate(ancestor), d = try locate(descendant), expected = try identity(a.0)
        if !a.1.isEmpty {
            guard try identity(d.0) == expected, a.1.count <= d.1.count else { return false }
            let sensitive = pathconf(a.0, _PC_CASE_SENSITIVE)
            guard sensitive == 0 || sensitive == 1 else { throw ThemeFailure("unknown filesystem name policy") }
            return zip(a.1, d.1).allSatisfy { pair in sensitive == 1 ? pair.0 == pair.1 : pair.0.compare(pair.1, options: .caseInsensitive) == .orderedSame }
        }
        var current = d.0
        while true {
            if try identity(current) == expected { return true }
            if current == "/" { return false }
            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
    }

    func duplicate(_ source: String, id: String, title: String) throws -> ThemePackStore.Loaded {
        var draft = try store.draft(source); draft.pack.id = id; draft.pack.title = title
        return try saveDraft(draft)
    }

    /// Reopen durable ownership before the existing scheduler's first effect after restart.
    static func prepareWallpaperCycle() throws {
        guard live != nil || ["ownership.json", "pending.json"].contains(where: {
            FileManager.default.fileExists(atPath: support.appending(path: "state/" + $0).path)
        }) else { return }
        let owner = try production()
        guard !owner.busy, try owner.state("pending").bytes == nil else { throw ThemeFailure("theme mutation/recovery in progress") }
    }

    /// The existing scheduler supplies the effect; its managed assignments use the same durable recovery journal.
    static func cycleWallpaper(display: String?, before: String?, after: String, show: () throws -> Bool) -> Bool {
        do {
            try prepareWallpaperCycle()
            guard let owner = live, let display else { return try show() }
            return try owner.advanceCycle(display: display, before: before, after: after, show: show)
        } catch { looklog.error("wallpaper cycle incomplete: \(String(describing: error), privacy: .public)"); return false }
    }

    private func advanceCycle(display: String, before: String?, after: String, show: () throws -> Bool) throws -> Bool {
        guard !busy, try state("pending").bytes == nil else { throw ThemeFailure("theme mutation/recovery in progress") }
        let (file, old) = try ledger()
        let claims = old.wallpapers ?? []
        guard let index = claims.firstIndex(where: { $0.target == .display(display) }) else { return try show() }
        let observed = try wallpaper?.read()
        guard Self.stillTheme(claims[index], now: .image(before), among: claims),
              let collection = claims.first(where: { $0.target == .sources }), case .sources(let images) = collection.last,
              images.contains(after), try observed?.value(.sources) == collection.last,
              try observed?.value(.display(display)) == .image(before) else {
            throw ThemeFailure("wallpaper cycle ownership conflict; later choice preserved")
        }
        var next = old
        next.epoch += 1
        next.wallpapers![index] = .init(target: .display(display), original: claims[index].original, last: .image(after))
        let bytes = try ThemeDigest.encoded(next)
        let change = ThemeWallpaperMutation(target: .display(display), before: .image(before), after: .image(after))
        let journal = ThemeJournal(schema: 1, beforeLedger: file.bytes, afterLedger: bytes, mutations: [], wallpapers: [change])
        try fault("cycle-journal")
        _ = try ThemeFiles.write(ThemeDigest.encoded(journal), over: state("pending"))
        do {
            try fault("cycle-effect")
            guard try wallpaper?.read() == observed else { throw ThemeFailure("stale wallpaper cycle before effect") }
            guard try show(), try wallpaper?.read().value(.display(display)) == .image(after) else { throw ThemeFailure("cycle assignment not verified") }
            try fault("cycle-after-effect")
            _ = try ThemeFiles.write(bytes, over: file)
            try fault("cycle-after-ledger")
            _ = try ThemeFiles.write(nil, over: state("pending"))
            return true
        } catch {
            _ = try recover()
            if try ledger().0.bytes == bytes, try wallpaper?.read().value(.display(display)) == .image(after) { return true }
            throw error
        }
    }

    /// The main-thread proof (coordinator's brief): "child" waits on a real child process the way production waits on
    /// osascript and Ghostex, "block" holds the main thread the way a synchronous wait would. Nothing else waits.
    nonisolated static func fixtureWait(_ how: String?) async throws {
        if how == "child" { _ = try await ChildProcess.run("/bin/sleep", ["1.5"], timeout: .seconds(5)) }
    }
    nonisolated static func fixtureBlock(_ how: String?) {
        guard how == "block" else { return }
        let child = Process(), done = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["1.5"]; child.terminationHandler = { _ in done.signal() }
        if (try? child.run()) != nil { done.wait() }
    }

    /// Private-host proof of the scheduler seam; production composition has no fixture root or recording state.
    func fixtureCycle(display: String, selection: String) async throws -> JSONValue {
        guard let fixtureRoot, let wallpaper else { throw ThemeFailure("explicit recording fixture cycle required") }
        let observed = try wallpaper.read()
        guard let target = observed.displays.first(where: { $0.id == display }),
              case .image(let before) = try observed.value(.display(display)) else { throw ThemeFailure("explicit recording fixture display required") }
        let after: String
        let stepping = ["next", "previous"].contains(selection)
        if stepping {
            let urls = observed.sources.map { URL(fileURLWithPath: $0) }
            let order = observed.preferences["order"]?.string.flatMap(WallpaperCycle.Order.init) ?? .name
            let seed = observed.preferences["seed"]?.string.flatMap(UInt64.init) ?? 0
            let fit = observed.preferences["fitShape"] == .bool(true)
            let pick = try await Task.detached {
                guard urls.allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(fixtureRoot + "/") }) else { throw ThemeFailure("fixture cycle source escapes root") }
                let images = WallpaperSettings.imageLists([urls], order: order, seed: seed)[urls] ?? []
                guard images.allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(fixtureRoot + "/") }) else { throw ThemeFailure("fixture cycle image escapes root") }
                return WallpaperCycle.step(images, shape: ImageShapes().shape, screen: target.portrait ? .portrait : .landscape,
                    fit: fit, current: before.map { URL(fileURLWithPath: $0) }, forward: selection == "next")
            }.value
            guard let pick else { throw ThemeFailure("no fixture cycle images") }
            after = pick.url.path
        } else { after = selection } // Retained explicit fault/recovery probes, never used as selection-policy proof.
        guard after.hasPrefix(fixtureRoot + "/"), stepping || observed.sources.contains(after) else { throw ThemeFailure("fixture cycle outside collection") }
        if FileManager.default.fileExists(atPath: fixtureRoot + "/cycle.hold") {
            try Data().write(to: URL(fileURLWithPath: fixtureRoot + "/cycle.ready"))
            for _ in 0..<250 {
                if !FileManager.default.fileExists(atPath: fixtureRoot + "/cycle.hold") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !FileManager.default.fileExists(atPath: fixtureRoot + "/cycle.hold") else { throw ThemeFailure("fixture cycle selection timed out") }
        }
        guard try wallpaper.read() == observed else { throw ThemeFailure("stale fixture cycle selection") }
        let applied = try advanceCycle(display: display, before: before, after: after) {
            try self.writeWallpaper(.init(target: .display(display), before: .image(before), after: .image(after)))
            return true
        }
        return .object(["assignment": .string(applied ? "verified" : "unchanged"), "image": .string(after), "effects": .string(effects.kind)])
    }

    /// The Carousel's pick on the private recording host (spec desktop-controls T8): the ledger seam a step and
    /// WallpaperSwitch.pick use, with the recording effect, never NSWorkspace and never an Allow.
    func fixtureCarouselPick(display: String, image: String) throws -> Bool {
        guard fixtureRoot != nil, let wallpaper, case .image(let before) = try wallpaper.read().value(.display(display)) else {
            throw ThemeFailure("explicit recording fixture display required")
        }
        return try advanceCycle(display: display, before: before, after: image) {
            try self.writeWallpaper(.init(target: .display(display), before: .image(before), after: .image(image)))
            return true
        }
    }

    /// Private recording host drives the exact native compatible-style memory, never Look.shared/settings/desktop.
    func fixtureStyle(_ next: String) throws -> JSONValue {
        guard let fixtureRoot, let native, !busy, PilotStyle(rawValue: next) != nil else { throw ThemeFailure("explicit native fixture/style required") }
        let file = try state("style-choices")
        var memory = try file.bytes.map { try JSONDecoder().decode(ThemeStyleMemory.self, from: $0) } ?? .init()
        let current = try native.read()
        let chosen = try memory.select(from: style(), to: next, current: current.palette)
        let control = try ThemeFiles.read(root: fixtureRoot, path: "control.json")
        guard let bytes = control.bytes else { throw ThemeFailure("missing fixture controls") }
        var values = try JSONDecoder().decode([String: String].self, from: bytes); values["style"] = next
        _ = try ThemeFiles.write(ThemeDigest.encoded(values), over: control)
        var next = current; next.palette = chosen
        try native.write(next)
        _ = try ThemeFiles.write(ThemeDigest.encoded(memory), over: file)
        return try describeStyle(chosen)
    }
    private func describeStyle(_ chosen: ThemeNativePalette) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(chosen))
    }

    /// Exercises the native picker's actual resolver and segment selection without constructing a view or live Look.
    func fixtureColour(_ raw: String) throws -> JSONValue {
        guard fixtureRoot != nil, wallpaper != nil, let choice = ColourChoice(rawValue: raw) else { throw ThemeFailure("explicit recording fixture colour required") }
        let resolved: PilotTheme?
        if let native {
            switch try native.read().palette {
            case .pack(let pack): resolved = pack.appearance(keeping: .standard)
            case .stock(let id): resolved = PilotTheme.named(id)
            }
        } else { resolved = try selected()?.appearance(keeping: .standard) }
        let theme = ColourChoicePicker.effectTheme("lagoon", resolved: resolved)
        let custom = ColourChoicePicker.selecting(true, choice: choice, theme: theme)
        let renderer = CursorEffectColours.of("lagoon", colour: choice, resolved: resolved)
        return .object(["custom": custom.map { .string($0.rawValue) } ?? .null,
                        "renderer": .string(ColourAnswer.hex(renderer.effectRGB)), "theme": .string(ColourAnswer.hex(theme))])
    }

    private func protectedLegacy(ghostty: Bool, files: Bool) throws -> ThemeSnapshot? {
        if !ghostty {
            guard files else { return nil }
            // Any file target must still protect an existing legacy include, even when
            // Ghostty is not requested. Only an absent unrelated root is optional.
            var info = stat()
            if lstat(binding.root, &info) != 0 {
                guard errno == ENOENT else { throw ThemeFailure("cannot inspect protected Ghostty root") }
                return nil
            }
        }
        return try ThemeFiles.read(root: binding.root, path: "pilot.conf")
    }

    private func checkDestinations(_ targets: [ThemeSnapshot], legacy: ThemeSnapshot?) throws {
        for target in targets {
            guard !([stateRoot, store.root, store.writableRoot] + [store.factoryRoot].compactMap { $0 }).contains(where: { target.resolved.hasPrefix($0 + "/") }) else { throw ThemeFailure("target overlaps theme state/pack inputs") }
        }
        let resources = targets + (legacy.map { [$0] } ?? [])
        for (i, resource) in resources.enumerated() {
            for other in resources.dropFirst(i + 1) {
                if resource.root == other.root && resource.path == other.path { continue }
                guard resource.resolved != other.resolved,
                      resource.inode == nil || resource.inode != other.inode else { throw ThemeFailure("overlapping bound/protected legacy destinations") }
            }
        }
    }

    private func resource(_ snapshot: ThemeSnapshot) -> String { ThemeResource.identity(snapshot.root, snapshot.path) }
    private func same(_ claim: ThemeClaim, _ target: ThemeSnapshot, _ selector: ThemeSelector) -> Bool {
        claim.root == target.root && claim.path == target.path && claim.selector == selector
    }
    private func restoration(_ claim: ThemeClaim, _ current: ThemeSnapshot) throws -> ThemeMutation {
        var bytes = try ThemeRegions.replacing(claim.selector, in: current.bytes, with: claim.original)
        if claim.originalFileAbsent {
            if case .block = claim.selector, bytes?.isEmpty == true { bytes = nil }
            if case .jsonMembership = claim.selector, bytes == Data("{}".utf8) { bytes = nil }
            if case .jsonValue = claim.selector, ThemeRegions.emptyObject(bytes) { bytes = nil }
        }
        return ThemeMutation(target: current, selector: claim.selector, before: claim.last, after: claim.original, replacement: bytes, release: true, bindingID: claim.bindingID)
    }

    /// `bound`: the display must be connected now. A claim on a screen that's gone grants nothing and is let go at the
    /// next plan, so only effects need it.
    private func validateWallpaper(_ target: ThemeWallpaperTarget, _ values: [ThemeWallpaperValue], bound: Bool = true) throws {
        guard let wallpaper else { throw ThemeFailure("wallpaper ownership has no local effect binding") }
        let state = try wallpaper.read(); try state.validate()
        // Only locally observed display IDs grant destinations, including during journal recovery.
        if bound, case .display(let id) = target, !state.displays.contains(where: { $0.id == id }) { throw ThemeFailure("unbound wallpaper display") }
        for value in values {
            switch (target, value) {
            case (.sources, .sources(let paths)):
                guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else { throw ThemeFailure("corrupt wallpaper sources") }
            case (.display, .image(let path)):
                guard path?.hasPrefix("/") == true, !path!.utf8.contains(0) else { throw ThemeFailure("unsupported/corrupt wallpaper baseline") }
            default: throw ThemeFailure("wallpaper target/value mismatch")
            }
        }
    }

    private func validateWallpapers(_ claims: [ThemeWallpaperClaim]) throws {
        for (index, claim) in claims.enumerated() {
            guard !claims.dropFirst(index + 1).contains(where: { $0.target == claim.target }) else { throw ThemeFailure("duplicate wallpaper ownership") }
            try validateWallpaper(claim.target, [claim.original, claim.last], bound: false)
        }
    }

    /// Whether a claimed wallpaper is still the theme's: as Pilot last set it, a screen moved on to another of the
    /// theme's own images (the cycle, a gallery pick or a workspace switch), or a collection of only the theme's images
    /// in another order. The images are the ledger's, not the live collection, which may be the person's own by now.
    private static func stillTheme(_ claim: ThemeWallpaperClaim, now: ThemeWallpaperValue, among claims: [ThemeWallpaperClaim]) -> Bool {
        if now == claim.last { return true }
        guard case .sources(let images)? = claims.first(where: { $0.target == .sources })?.last else { return false }
        switch (claim.target, now) {
        case (.display, .image(let path?)): return images.contains(path)
        case (.sources, .sources(let paths)): return !paths.isEmpty && paths.allSatisfy(images.contains)
        default: return false
        }
    }

    /// `keep`: a shipped pack whose pictures are not here (ShippedWallpapers) leaves every screen as it is: the claims
    /// still the theme's are held as the ledger has them, with no mutation, so Restore still puts each original back.
    private func wallpaperPlan(_ loaded: ThemePackStore.Loaded?, record: ThemeLedger, state: ThemeWallpaperState?, keep: Bool = false) throws -> (changes: [ThemeWallpaperMutation], kept: [ThemeWallpaperTarget], held: [ThemeWallpaperClaim]) {
        let claims = record.wallpapers ?? []
        guard let state else {
            guard claims.isEmpty else { throw ThemeFailure("missing wallpaper state/effect binding") }; return ([], [], [])
        }
        // What the person changed since (another image, their own collection, a pin) stays theirs and only its claim
        // goes, so one changed screen never stops the rest of an Apply or Restore.
        var owned: [ThemeWallpaperClaim] = [], kept: [ThemeWallpaperTarget] = []
        for claim in claims {
            // A pinned screen is the person's; one no longer connected can't be set or put back, so its claim goes too.
            if case .display(let id) = claim.target, state.displays.first(where: { $0.id == id })?.pinned != false { kept.append(claim.target); continue }
            let now = try state.value(claim.target)
            if Self.stillTheme(claim, now: now, among: claims) { owned.append(.init(target: claim.target, original: claim.original, last: now)) }
            else { kept.append(claim.target) }
        }
        var changes: [ThemeWallpaperMutation] = []
        // With their own collection in place, the theme's images would have nothing to cycle from: none are set.
        if let loaded, !loaded.images.isEmpty, !kept.contains(.sources) {
            changes.append(.init(target: .sources, before: .sources(state.sources), after: .sources(loaded.images)))
            let order = state.preferences["order"]?.string.flatMap(WallpaperCycle.Order.init) ?? .name
            let seed = state.preferences["seed"]?.string.flatMap(UInt64.init) ?? 0
            let fit = state.preferences["fitShape"] == .bool(true)
            let images = WallpaperCycle.ordered(loaded.images.map { URL(fileURLWithPath: $0) }, order: order, seed: seed)
            for display in state.displays where !display.pinned && display.image != nil && !kept.contains(.display(display.id)) {
                let shape: WallpaperCycle.Shape = display.portrait ? .portrait : .landscape
                let pick = WallpaperCycle.step(images, shape: { loaded.portraits.contains($0.path) ? .portrait : .landscape }, screen: shape, fit: fit, current: nil, forward: true)
                if let pick { changes.append(.init(target: .display(display.id), before: .image(display.image), after: .image(pick.url.path))) }
            }
        }
        // Zero images releases previous wallpaper ownership, or leaves an unmanaged wallpaper unchanged.
        if keep { return (changes, kept, claims.filter { claim in owned.contains { $0.target == claim.target } }) }
        for claim in owned where !changes.contains(where: { $0.target == claim.target }) {
            changes.append(.init(target: claim.target, before: claim.last, after: claim.original, release: true))
        }
        return (changes, kept, [])
    }

    private func writeWallpaper(_ change: ThemeWallpaperMutation) throws {
        try validateWallpaper(change.target, [change.before, change.after])
        guard let wallpaper, try wallpaper.read().value(change.target) == change.before else { throw ThemeFailure("stale wallpaper before effect") }
        try wallpaper.write(change)
        guard try wallpaper.read().value(change.target) == change.after else { throw ThemeFailure("wallpaper effect not verified") }
    }

    private func recoverWallpapers(_ mutations: [ThemeWallpaperMutation], committed: Bool) throws -> (rows: [JSONValue], conflict: Bool) {
        var rows: [JSONValue] = [], conflict = false
        for (index, change) in mutations.enumerated().reversed() {
            do {
                guard !mutations.dropFirst(index + 1).contains(where: { $0.target == change.target }) else { throw ThemeFailure("duplicate wallpaper recovery target") }
                try validateWallpaper(change.target, [change.before, change.after])
                let current = try wallpaper!.read().value(change.target)
                if committed { guard current == change.after else { throw ThemeFailure("committed wallpaper changed; retained") } }
                else if current != change.before {
                    guard current == change.after else { throw ThemeFailure("later wallpaper edit; retained") }
                    try fault("wallpaper-rollback:\(index)")
                    try writeWallpaper(.init(target: change.target, before: change.after, after: change.before))
                }
                rows.append(.object(["wallpaper": .string(String(describing: change.target)), "rollback": .string(committed ? "not attempted; it stays as applied" : "not needed; it is as it was")]))
            } catch {
                conflict = true
                rows.append(.object(["wallpaper": .string(String(describing: change.target)), "rollback": .string("conflicted/failed: \(error)")]))
            }
        }
        return (rows, conflict)
    }

    /// What a person reads about a plan: every file and setting by name, every skipped app with why, and nothing internal.
    struct ThemeReview {
        let entries: [ThemeAllowText.Entry]
        let skipped, details, short, next, kept: [String]
        var changes: [String] { entries.map(\.line) }
    }
    /// Shown in Preview, not asked in Allow: nothing about the cursor changes.
    static let modeSkipped = "macOS mode skipped: Appearance is set to Auto, so it stays as it is. To have it follow, pick Light or Dark in System Settings › Appearance"
    static let cursorSkipped = "Cursor skipped: macOS's own pointer stays, so it takes no theme colours. To have it follow, pick a design in Look › Cursor"
    /// What a plan leaves as the person changed it, in Preview's words or, `done`, the result's.
    func keptWords(_ plan: ThemePlan, done: Bool, appearance: ThemeAppearanceMutation? = nil) -> [String] {
        var lines: [String] = []
        let names = ["palette": "Pilot colours", "material": "glass", "bar": "top bar layout", "cursor": "cursor colours", "mode": "Light or Dark mode"]
        for part in plan.keptLook {
            let name = names[part] ?? part
            let retaken = plan.packID != nil && [appearance?.palette, appearance?.material, appearance?.bar, appearance?.cursor, appearance?.mode][ThemeAppearanceOwnership.parts.firstIndex(of: part)!] == true
            if retaken { lines.append(done ? "The \(name) you chose after the theme took this theme; Restore puts yours back." : "The \(name) you chose after the theme take this theme; Restore puts yours back.") }
            else { lines.append(done ? "Kept the \(name) you chose after the theme." : "The \(name) you chose after the theme stay as they are.") }
        }
        let vaults = plan.obsidian.map(\.root)
        for claim in plan.keptFiles {
            let line: String
            if case .jsonMembership = claim.selector, vaults.contains(claim.root) {
                let vault = Self.vaultLabel(claim.root, among: vaults)
                line = done ? "Kept the Pilot snippet off in Obsidian vault \(vault)." : "The Pilot snippet stays off in Obsidian vault \(vault): you turned it off. Turn it on under CSS snippets in Obsidian's Appearance settings to see the theme there."
            } else {
                let file = AppConfigs.tilde(claim.resolved, home: NSHomeDirectory())
                line = done ? "Kept your change to \(file)." : "Your change to \(file) stays: you edited Pilot's part after the theme, so Pilot leaves it alone."
            }
            if !lines.contains(line) { lines.append(line) }
        }
        let connected = Set(plan.wallpaperState?.displays.map(\.id) ?? [])
        let gone = plan.keptWallpapers.filter { if case .display(let id) = $0 { !connected.contains(id) } else { false } }
        if !gone.isEmpty {
            let place = gone.count == 1 ? "a screen that's" : "\(gone.count) screens that are"
            lines.append(done ? "Let go of the wallpaper on \(place) no longer connected." : "Pilot lets go of the wallpaper on \(place) no longer connected: it can't set or put it back there.")
        }
        let kept = plan.keptWallpapers.filter { !gone.contains($0) }
        if kept.contains(.sources) { lines.append(done ? "Kept your own wallpaper collection." : "Your own wallpaper collection stays: you changed it after the theme.") }
        let screens = kept.filter { $0 != .sources }.count
        if screens > 0 {
            let place = screens == 1 ? "one screen" : "\(screens) screens"
            lines.append(done ? "Kept your wallpaper on \(place)." : "Your wallpaper on \(place) stays: you changed it after the theme.")
        }
        return lines
    }
    func review(_ plan: ThemePlan, appearance: ThemeAppearanceMutation?) -> ThemeReview {
        var entries: [ThemeAllowText.Entry] = [], short: [String] = [], next: [String] = []
        if let appearance {
            let parts = [appearance.palette ? "colours" : nil, appearance.material ? "glass" : nil, appearance.bar == true ? "top bar layout" : nil, appearance.cursor == true ? "cursor colours" : nil].compactMap { $0 }
            if !parts.isEmpty { entries.append(.init(name: "Pilot: " + parts.joined(separator: ", "))); short.append("Pilot") }
            if appearance.mode == true, appearance.before.dark != appearance.after.dark, let dark = appearance.after.dark {
                entries.append(.init(name: "macOS: \(dark ? "Dark" : "Light") mode")); short.append("macOS \(dark ? "Dark" : "Light") mode")
            }
        }
        var unnamed = 0
        for change in plan.wallpapers {
            switch change.target {
            case .sources:
                if case .sources(let paths) = change.after { entries.append(.init(name: "Wallpaper collection: \(paths.count) images")) }
            case .display(let id):
                unnamed += 1
                entries.append(.init(name: "Wallpaper on \(wallpaper?.name(id) ?? "Display \(unnamed)")", screen: true))
            }
        }
        if !plan.wallpapers.isEmpty { short.append("wallpaper") }
        var roots: [String] = []
        for change in plan.mutations where !roots.contains(change.target.root) { roots.append(change.target.root) }
        let vaults = Set(plan.obsidian.map(\.root))
        for root in roots {
            let files = plan.mutations.filter { $0.target.root == root }
            let name: String
            if root == binding.root { name = "Ghostty" }  // Apply and Restore reload it themselves; the result says if they couldn't.
            else if root == plan.zed?.root { name = "Zed" }
            else if vaults.contains(root) { name = "Obsidian vault " + vaultLabel(root, among: plan.obsidian.map(\.root)); if !next.contains("Reload Obsidian to see it.") { next.append("Reload Obsidian to see it.") } }
            else if let app = plan.apps.first(where: { $0.root == root }) { name = app.kind.name; if let line = app.kind.followUp { next.append(line) } }
            else if let id = files.first?.bindingID { name = "Custom app " + id }
            else { name = "Ghostex terminal" }
            var seen: [String] = []
            for file in files where !seen.contains(file.target.resolved) { seen.append(file.target.resolved) }
            entries.append(.init(name: name, paths: seen, linked: files.contains { $0.target.linkedOut }))
            short.append(name)
        }
        if !plan.ghostex.isEmpty {
            let colour = plan.ghostex.first { $0.key == "customSidebarTitlebarBackgroundTintColor" }?.after
            let settings = plan.ghostex.compactMap { GhostexInterface.names[$0.key] }.joined(separator: ", ")
            // Named by the ground Ghostex draws, not the tint it is given, which no palette holds.
            let to = plan.selection.flatMap { pack in colour == (try? GhostexInterface.tint(pack)) ? pack.palette["background"].map { " to \($0)" } : nil } ?? ""
            entries.append(.init(name: "Ghostex window and sidebar\(to)", note: ": \(settings). Terminal colours stay Ghostex's own"))
            short.append("Ghostex")
        }
        let skipped = plan.warnings.filter { $0.contains(" skipped") }
        return .init(entries: entries, skipped: skipped, details: plan.warnings.filter { !skipped.contains($0) }, short: short, next: next,
                     kept: keptWords(plan, done: false, appearance: appearance))
    }
    /// What a person reads when a file Pilot set is no longer the one it set: moved, or a link pointed elsewhere. A change
    /// inside it is kept instead (keptWords).
    private func changedSince(_ claim: ThemeClaim) -> String {
        "conflict: \(claim.root)/\(claim.path) changed since the theme was applied, so Pilot left it alone"
    }

    /// Whether a theme is on the apps now, which is when Restore has something to do.
    func appliedTheme() throws -> (id: String?, any: Bool) {
        let record = try ledger().1
        return (record.selected.map { PilotTheme.retired[$0.id] ?? $0.id }, !record.claims.isEmpty || !(record.wallpapers ?? []).isEmpty || record.appearance != nil || !(record.ghostexSettings ?? []).isEmpty)
    }

    /// A vault's folder name, or with its parent when another vault has the same folder name.
    nonisolated static func vaultLabel(_ root: String, among roots: [String]) -> String {
        let url = URL(fileURLWithPath: root), name = url.lastPathComponent
        guard roots.filter({ URL(fileURLWithPath: $0).lastPathComponent == name }).count > 1 else { return name }
        return "\(name) (in \(url.deletingLastPathComponent().lastPathComponent))"
    }
    private func vaultLabel(_ root: String, among roots: [String]) -> String { Self.vaultLabel(root, among: roots) }

    /// What this plan does in Ghostex. A value changed since Pilot set it stays that person's, whatever the plan is.
    private func ghostexPlan(_ pack: ThemePack?, record: ThemeLedger, off: Bool, state ghostexState: [String: String]?, warnings: inout [String]) throws -> (state: [String: String]?, changes: [ThemeSettingMutation], claims: [ThemeSettingClaim]) {
        let claims = record.ghostexSettings ?? []
        guard let ghostexColours else { return (nil, [], claims) }
        let wanted = off ? nil : try pack.map(GhostexInterface.values)
        guard ghostexColours.installed() else {
            if !claims.isEmpty { warnings.append("Ghostex is no longer installed, so Pilot forgets its colours") }
            else if wanted != nil { warnings.append("Ghostex skipped: not installed") }
            return (nil, [], [])
        }
        guard let state = ghostexState else {
            if !claims.isEmpty { warnings.append("Ghostex skipped: it is closed, so its colour stays for now. Open it, then Apply or Restore again") }
            else if wanted != nil { warnings.append("Ghostex skipped: it is not running") }
            return (nil, [], claims)
        }
        var changes: [ThemeSettingMutation] = [], next: [ThemeSettingClaim] = [], kept: [String] = []
        for key in GhostexInterface.keys {
            guard let current = state[key] else { continue }
            let claim = claims.first { $0.key == key }
            if let claim, current != claim.last { kept.append(key); continue }
            if let after = wanted?[key] {
                next.append(.init(key: key, original: claim?.original ?? current, last: after))
                if after != current { changes.append(.init(key: key, before: current, after: after)) }
            } else if let claim, current != claim.original {
                changes.append(.init(key: key, before: current, after: claim.original))
            }
        }
        if !kept.isEmpty { warnings.append("Ghostex: \(kept.compactMap { GhostexInterface.names[$0] }.joined(separator: ", ")) changed since Pilot set it, so it stays yours") }
        if wanted != nil, !changes.isEmpty {
            warnings += ["Ghostex: a terminal background set to Theme follows this colour"]
        }
        return (state, changes, next)
    }

    /// Recovery never waits on Ghostex: a rollback it owes is left for finishDue, which awaits it off the main thread and
    /// hands its rows back here as `settled`.
    private func recoverGhostex(_ mutations: [ThemeSettingMutation], committed: Bool, settled: (rows: [JSONValue], conflict: Bool)?) -> (rows: [JSONValue], conflict: Bool) {
        guard !mutations.isEmpty else { return ([], false) }
        guard !committed else { return ([.object(["ghostex": .string("not attempted; committed")])], false) }
        if let settled { return settled }
        guard ghostexColours != nil else { return ([.object(["ghostex": .string("skipped: Ghostex not running")])], false) }
        ghostexDue = mutations
        return ([.object(["ghostex": .string("rollback waits on Ghostex, off the main thread")])], true)
    }
    private func rollbackGhostex(_ mutations: [ThemeSettingMutation]) async -> (rows: [JSONValue], conflict: Bool) {
        do {
            // Closed or gone: nothing can be set, and nothing recorded says Pilot owns these, so there is nothing to hold on to.
            guard let ghostexColours, var state = try await ghostexColours.read() else { return ([.object(["ghostex": .string("skipped: Ghostex not running")])], false) }
            var rows: [JSONValue] = [], conflict = false
            for (index, change) in mutations.enumerated().reversed() {
                if state[change.key] == change.before { rows.append(.object(["ghostex": .string(change.key), "rollback": .string("not needed")])); continue }
                guard state[change.key] == change.after else {
                    conflict = true; rows.append(.object(["ghostex": .string(change.key), "rollback": .string("conflicted: later edit retained")])); continue
                }
                try fault("ghostex-rollback:\(index)")
                try await ghostexColours.write(change.key, change.before)
                guard let after = try await ghostexColours.read(), after[change.key] == change.before else { throw ThemeFailure("Ghostex rollback not verified") }
                state = after
                rows.append(.object(["ghostex": .string(change.key), "rollback": .string("attempted; verified")]))
            }
            return (rows, conflict)
        } catch { return ([.object(["ghostex": .string("rollback conflicted/failed: \(error)")])], true) }
    }

    private func validateWallpaperJournal(_ journal: ThemeJournal) throws {
        let mutations = journal.wallpapers ?? []
        let before = try journal.beforeLedger.map(ThemeLedger.decode) ?? ThemeLedger()
        guard let bytes = journal.afterLedger else { throw ThemeFailure("missing recovery after-ledger") }
        let after = try ThemeLedger.decode(bytes)
        let claims = before.wallpapers ?? [], kept = journal.keptWallpapers ?? []
        for (index, change) in mutations.enumerated() {
            guard !mutations.dropFirst(index + 1).contains(where: { $0.target == change.target }) else { throw ThemeFailure("duplicate wallpaper journal target") }
            try validateWallpaper(change.target, [change.before, change.after])
            let old = claims.first { $0.target == change.target }, new = after.wallpapers?.first { $0.target == change.target }
            if change.release {
                guard let old, new == nil, Self.stillTheme(old, now: change.before, among: claims), change.after == old.original else { throw ThemeFailure("inconsistent wallpaper release journal") }
            } else {
                guard let new, new.last == change.after, new.original == (old?.original ?? change.before),
                      old == nil || Self.stillTheme(old!, now: change.before, among: claims) else { throw ThemeFailure("inconsistent wallpaper ownership journal") }
            }
        }
        // A kept claim only goes: it was owned before, nothing is written for it and nothing owns it after.
        for (index, target) in kept.enumerated() {
            guard !kept.dropFirst(index + 1).contains(target), claims.contains(where: { $0.target == target }),
                  !mutations.contains(where: { $0.target == target }), after.wallpapers?.contains(where: { $0.target == target }) != true else { throw ThemeFailure("inconsistent kept wallpaper journal") }
        }
        for claim in claims + (after.wallpapers ?? []) {
            if !mutations.contains(where: { $0.target == claim.target }) && !kept.contains(claim.target) {
                guard before.wallpapers?.first(where: { $0.target == claim.target }) == after.wallpapers?.first(where: { $0.target == claim.target }) else { throw ThemeFailure("unjournaled wallpaper ownership change") }
            }
        }
    }

    func plan(_ id: String?) async throws -> ThemePlan {
        // Ghostex answers through a child process, awaited before anything else is read, so the rest plans in one main-actor turn.
        let ghostex = try await ghostexColours?.read()
        var note: String?
        if let id { note = await fetchShipped(id) }
        return try plan(id, ghostex: ghostex, shippedNote: note)
    }

    /// A shipped pack's pictures fetched from the catalogue before its plan reads them; why there are none to use, else nil.
    private func fetchShipped(_ id: String) async -> String? {
        guard let shipped, let loaded = try? store.load(id), ShippedWallpapers.wants(loaded) else { return nil }
        // A copy fetched before is used offline; none leaves the wallpaper as it is.
        func had() -> Bool { !shipped.wallpapers.picturing(loaded).images.isEmpty }
        do {
            guard let theme = try await shipped.index().theme(id) else {
                return had() ? nil : "\(loaded.pack.title)'s wallpapers are not in Pilot's catalogue yet."
            }
            let wallpapers = shipped.wallpapers
            try await Task.detached { try await wallpapers.fetch(theme, for: loaded) }.value
            return nil
        } catch {
            log.notice("theme: \(id, privacy: .public)'s wallpapers not fetched: \(ExtensionCatalogue.Problem.reason(error), privacy: .public)")
            return had() ? nil : "\(loaded.pack.title)'s wallpapers could not be downloaded. \(ExtensionCatalogue.Problem.reason(error))"
        }
    }
    private func plan(_ id: String?, ghostex ghostexState: [String: String]?, shippedNote: String? = nil) throws -> ThemePlan {
        guard try state("pending").bytes == nil else { throw ThemeFailure("pending recovery; restart/recover before planning") }
        let (recordFile, kept) = try ledger()
        let loaded = try id.map { try shipped?.wallpapers.picturing(store.load($0)) ?? store.load($0) }, (local, notes) = try effective(for: loaded?.pack)
        let gone = goneRoots(try stored(), claims: kept.claims)
        var record = kept
        record.claims.removeAll { gone.contains($0.root) }
        if let pack = loaded?.pack {
            guard Set(pack.adapters.keys).isSubset(of: ["ghostty", "zed", "obsidian"]),
                  pack.adapters.values.allSatisfy({ $0 == .object([:]) }) else { throw ThemeFailure("unsupported adapter data; palette-only Ghostty/Zed/Obsidian mappings") }
            if !pack.compatible(with: style()) { throw ThemeFailure("incompatible style") }
            if detect == nil, pack.adapters["zed"] != nil, local.zed == nil, !local.zedOptOut { throw ThemeFailure("Zed not selected/bound; select an explicit configuration root or explicitly opt out; installation unknown") }
        }
        if detect == nil, loaded?.pack.adapters["obsidian"] != nil, (local.obsidian ?? []).isEmpty, local.obsidianOptOut != true {
            throw ThemeFailure("Obsidian not selected/bound; choose explicit vault and config folder or opt out; installation unknown")
        }
        // Ghostty counts as a detected app: with no config folder and nothing owned, it is skipped silently.
        let ghosttyOwned = record.claims.contains { $0.root == binding.root }
        let ghostty = ghosttyOwned || loaded?.pack.adapters["ghostty"] != nil && (detect == nil || Self.folder(binding.root))
        var targets = try ghostty ? [binding.generated, binding.config].map { try destination(binding.root, $0) } : []
        if let zed = local.zed, loaded?.pack.adapters["zed"] != nil && !local.zedOptOut || record.claims.contains(where: { $0.root == zed.root }) {
            guard zed.config == "settings.json", zed.generated == "themes/pilot-theme.json" else { throw ThemeFailure("unsupported Zed destination binding") }
            targets += try [zed.generated, zed.config].map { try observe(zed.root, $0) }
        }
        for vault in local.obsidian ?? [] where loaded?.pack.adapters["obsidian"] != nil || record.claims.contains(where: { $0.root == vault.root }) {
            targets += try [vault.generated, vault.config].map { try observe(vault.root, $0) }
        }
        if let oldGhostex = local.ghostex { targets += try [oldGhostex.generated, oldGhostex.config].map { try ThemeFiles.read(root: oldGhostex.root, path: $0) } }
        let appsOff = local.appsOff ?? []
        for app in local.apps ?? [] where loaded != nil && !appsOff.contains(app.kind) || record.claims.contains(where: { $0.root == app.root }) {
            targets += try app.paths.map { try observe(app.root, $0) }
        }
        let custom = (local.custom ?? []).filter { item in
            loaded?.pack.customMappings?.contains(where: { $0.id == item.id }) == true || record.claims.contains(where: { $0.bindingID == item.id })
        }
        for item in custom {
            targets.append(try ThemeFiles.read(root: item.root, path: item.path))
        }
        targets = targets.reduce(into: []) { result, target in
            if !result.contains(where: { $0.root == target.root && $0.path == target.path }) { result.append(target) }
        }
        let legacy = try protectedLegacy(ghostty: ghostty, files: !targets.isEmpty)
        try checkDestinations(targets, legacy: legacy)
        // A region that still says what Pilot wrote (an editor may reformat it) is Pilot's, taken as it reads now. One the
        // person changed keeps their change: only that claim goes, and nothing writes there this time.
        var keptFiles: [ThemeClaim] = []
        var adapterClaims: [ThemeClaim] = []
        for claim in record.claims {
            guard let current = targets.first(where: { $0.root == claim.root && $0.path == claim.path }),
                  anchored(claim.anchor, current), current.resolved == claim.resolved else { throw ThemeFailure(changedSince(claim)) }
            let now = try ThemeRegions.owned(claim.selector, in: current.bytes)
            adapterClaims.append(claim.reading(now))
            if !ThemeRegions.sameMeaning(claim.selector, now, claim.last) { keptFiles.append(claim) }
        }
        record.claims = adapterClaims.filter { claim in !keptFiles.contains { $0.identity == claim.identity } }
        var changes: [ThemeMutation] = []
        var warnings = (ghostty ? ["Ghostty: other config files or launch flags can still change its colours", "Ghostty: your fonts and Pilot's older settings stay"] : []) + notes
            + gone.sorted().map { "\($0) no longer exists, so Pilot leaves it out and writes nothing" }
            + targets.filter(\.linkedOut).map { "\($0.root)/\($0.path) is a link: Pilot's block goes in the real file, \($0.resolved), and the link stays" }
            + targets.filter { $0.anchor == ThemeFiles.folderMissing }.map { "Apply creates \(URL(fileURLWithPath: $0.resolved).deletingLastPathComponent().path); Restore removes it if still empty" }
        if ghostty, let pack = loaded?.pack, pack.adapters["ghostty"] != nil {
            changes += try GhosttyThemeAdapter.prepare(pack.adapter("ghostty"), binding: binding, snapshots: Array(targets.prefix(2)), claims: adapterClaims.filter { $0.root == binding.root })
        }
        if let oldGhostex = local.ghostex { warnings.append("Ghostex terminal colours no longer follow themes: Pilot removes its earlier change from \(oldGhostex.root)") }
        if let pack = loaded?.pack, pack.adapters["zed"] != nil, !local.zedOptOut, let zed = local.zed {
            let asset = targets.first { $0.root == zed.root && $0.path == zed.generated }!
            let settings = targets.first { $0.root == zed.root && $0.path == zed.config }!
            let (selectors, notices) = try ZedThemeAdapter.selectors(pack, settings: settings.bytes, absentFollows: detect != nil)
            warnings += notices
            guard asset.bytes == nil || adapterClaims.contains(where: { same($0, asset, .file) }) else { throw ThemeFailure("unclaimed generated Zed theme collision") }
            let generated = try ZedThemeAdapter.asset(pack), value = try ThemeDigest.encoded(ZedThemeAdapter.name(pack))
            changes.append(ThemeMutation(target: asset, selector: .file, before: asset.bytes, after: generated, replacement: generated))
            for selector in selectors {
                changes.append(ThemeMutation(target: settings, selector: selector, before: try ThemeRegions.owned(selector, in: settings.bytes), after: value,
                                             replacement: try ThemeRegions.replacing(selector, in: settings.bytes, with: value)))
            }
        } else if detect == nil || local.zedOptOut { warnings.append(local.zedOptOut ? "Zed skipped: you turned it off" : "Zed skipped: not found, or this theme has no Zed colours") }
        if let pack = loaded?.pack, pack.adapters["obsidian"] != nil {
            if detect == nil || !(local.obsidian ?? []).isEmpty { warnings += ObsidianThemeAdapter.warnings }
            let generated = try ObsidianThemeAdapter.asset(pack), value = try ThemeDigest.encoded(ObsidianThemeAdapter.element)  // One snippet for every vault.
            for vault in local.obsidian ?? [] where detect == nil || (local.obsidianOptOut != true && !(local.obsidianOff ?? []).contains(vault.root)) {
                let asset = targets.first { $0.root == vault.root && $0.path == vault.generated }!
                let settings = targets.first { $0.root == vault.root && $0.path == vault.config }!
                let document = try ThemeJSONC(settings.bytes ?? Data("{}".utf8))
                let previous = adapterClaims.first { $0.root == vault.root && $0.path == vault.config }
                let selector: ThemeSelector
                if let previous { selector = previous.selector }
                else {
                    let container = try document.owned(ObsidianThemeAdapter.membershipPath)
                    selector = .jsonMembership(path: ObsidianThemeAdapter.membershipPath, element: ObsidianThemeAdapter.element, removeEmptyContainer: container == nil)
                }
                try ObsidianThemeAdapter.validateExisting(asset.bytes)
                changes += [ThemeMutation(target: asset, selector: .file, before: asset.bytes, after: generated, replacement: generated),
                            ThemeMutation(target: settings, selector: selector, before: try ThemeRegions.owned(selector, in: settings.bytes), after: value,
                                          replacement: try ThemeRegions.replacing(selector, in: settings.bytes, with: value))]
            }
            if (local.obsidian ?? []).isEmpty, detect == nil || local.obsidianOptOut == true { warnings.append("Obsidian skipped: you turned it off") }
        } else if detect == nil { warnings.append("Obsidian skipped: this theme has no Obsidian colours") }
        var reloads: [ThemeReloadIntent] = []
        for mapping in loaded?.pack.customMappings ?? [] {
            guard let item = local.custom?.first(where: { $0.id == mapping.id }),
                  let target = targets.first(where: { $0.root == item.root && $0.path == item.path }) else { throw ThemeFailure("missing local custom binding: \(mapping.id)") }
            let previous = adapterClaims.first { $0.bindingID == item.id && $0.root == item.root && $0.path == item.path }
            if let previous, !customSelector(previous.selector, matches: mapping) { throw ThemeFailure("Restore before changing custom ownership selector") }
            changes.append(try mapping.prepare(palette: loaded!.pack.palette, target: target, previous: previous))
            warnings.append("Custom app \(mapping.id): changes \(item.root)/\(item.path)")
            if let command = item.reload {
                let relative = String(command.executable.dropFirst(item.app.count + 1))
                let program = try ThemeFiles.read(root: item.app, path: relative)
                guard program.bytes != nil, program.resolved == command.executable else { throw ThemeFailure("missing/aliased local reload executable") }
                reloads.append(.init(binding: item, executable: program, app: try ThemeFiles.read(root: item.app, path: "Contents/Info.plist")))
            } else { warnings.append("\(mapping.id): reload the app yourself to see it") }
        }
        if let pack = loaded?.pack {
            for app in local.apps ?? [] where !appsOff.contains(app.kind) {
                let prepared = try ThemeApps.prepare(pack, app: app, snapshots: targets.filter { $0.root == app.root }, claims: adapterClaims.filter { $0.root == app.root })
                changes += prepared.changes; warnings += prepared.notes
            }
        }
        changes.removeAll { change in keptFiles.contains { same($0, change.target, change.selector) } }
        // Retire selectors no longer supplied (including dark->light) before composing the resource's single write.
        let releases = try record.claims.filter { claim in !changes.contains(where: { same(claim, $0.target, $0.selector) }) }.map { claim in
            try restoration(claim, targets.first { $0.root == claim.root && $0.path == claim.path }!)
        }
        changes = releases + changes
        try validateOverlaps(changes.map { ($0.target.root, $0.target.path, $0.selector) })
        changes = try changes.map { change in
            let group = changes.filter { resource($0.target) == resource(change.target) }
            return ThemeMutation(target: change.target, selector: change.selector, before: change.before, after: change.after,
                                 replacement: try composedResource(group, claims: record.claims), release: change.release, bindingID: change.bindingID)
        }
        // Assets precede selectors on Apply (even a retired dark selector); Restore does the reverse.
        changes = changes.enumerated().sorted { lhs, rhs in
            func priority(_ change: ThemeMutation) -> Int {
                if case .file = change.selector { return change.release == true ? 2 : 0 }; return 1
            }
            let a = priority(lhs.element), b = priority(rhs.element)
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
        let wallpaperState = try wallpaper?.read()
        try wallpaperState?.validate()
        guard wallpaperState?.preferences["cycling"] != .bool(true) else { throw ThemeFailure("wallpaper cycle in progress; plan again") }
        let components = try following()
        let nativePlan = try appearancePlan(loaded?.pack, old: appearanceOwnership(record, current: native?.read()), following: components)
        let unpictured = loaded.map { ShippedWallpapers.wants($0) && $0.images.isEmpty } ?? false
        let (wallpapers, keptWallpapers, heldWallpapers) = try wallpaperPlan(components.wallpapers ? loaded : nil, record: record, state: wallpaperState, keep: unpictured)
        if loaded != nil, cursorIsSystem(), components.cursor != false, nativePlan.1?.cursor != true {
            warnings.append(Self.cursorSkipped)
        }
        if loaded != nil, components.mode != false, nativePlan.1?.before.auto == true { warnings.append(Self.modeSkipped) }
        if let change = nativePlan.1, change.cursor == true, change.before.cursor != change.after.cursor {
            warnings.append("Cursor colours: \(change.before.cursor ?? "unknown") → \(change.after.cursor ?? "unknown"), applied with the theme; Restore puts your previous choice back")
        }
        let ghostexPlan = try ghostexPlan(loaded?.pack, record: record, off: local.ghostexInterfaceOff == true, state: ghostexState, warnings: &warnings)
        if loaded?.images.isEmpty == false, wallpaper == nil { warnings.append("Wallpaper skipped: Pilot can't set it here") }
        if let loaded, unpictured, components.wallpapers {
            warnings.append("Wallpaper kept; its colours apply: \(shippedNote ?? "\(loaded.pack.title)'s wallpapers are not downloaded.")")
        }
        let appObservations = try custom.map { try ThemeFiles.read(root: $0.app, path: "Contents/Info.plist") }
        let plan = ThemePlan(id: UUID().uuidString, packID: id, revision: loaded?.revision, binding: binding, style: style(),
                             ledger: recordFile, protectedLegacy: legacy, zed: local.zed, zedOptOut: local.zedOptOut, observations: targets + appObservations + [try state("bindings"), try state("components")],
                             obsidian: local.obsidian ?? [], obsidianOptOut: local.obsidianOptOut ?? false, mutations: changes, selection: loaded?.pack, warnings: warnings, wallpaperState: wallpaperState, wallpapers: wallpapers, keptWallpapers: keptWallpapers, heldWallpapers: heldWallpapers, keptFiles: keptFiles, keptLook: nativePlan.2, reloads: reloads, ghostexState: ghostexPlan.state, ghostex: ghostexPlan.changes, ghostexClaims: ghostexPlan.claims, apps: local.apps ?? [])
        if plans.count >= 32 { plans.removeAll() }
        plans[plan.id] = (plan, try context(), nativePlan.0, nativePlan.1)
        return plan
    }

    private func fresh(_ plan: ThemePlan, contextRevision: String, appearance: ThemeAppearanceMutation?) async throws {
        // The one wait, first: every other check below then runs in the same main-actor turn as the commit after it.
        let ghostex = try await ghostexColours?.read()
        if let appearance { guard try native?.read() == appearance.before else { throw ThemeFailure("stale native appearance/personal override") } }
        let local = try effective(for: plan.selection).local
        guard plan.obsidian == (local.obsidian ?? []), plan.obsidianOptOut == (local.obsidianOptOut ?? false), plan.binding == binding, plan.zed == local.zed, plan.zedOptOut == local.zedOptOut, plan.apps == (local.apps ?? []), plan.style == style(), try context() == contextRevision,
              try state("pending").bytes == nil, try ledger().0 == plan.ledger else { throw ThemeFailure("stale plan context/ledger") }
        guard try wallpaper?.read() == plan.wallpaperState else { throw ThemeFailure("stale wallpaper state/bindings/overrides") }
        guard ghostex == plan.ghostexState else { throw ThemeFailure("Ghostex's colours changed since Preview; preview again") }
        if let id = plan.packID { guard try store.load(id).revision == plan.revision else { throw ThemeFailure("stale pack/assets") } }
        guard try protectedLegacy(ghostty: plan.observations.contains { $0.root == binding.root }, files: !plan.mutations.isEmpty) == plan.protectedLegacy else { throw ThemeFailure("stale protected legacy resource") }
        for target in plan.observations + plan.reloads.map(\.executable) {
            guard try observe(target.root, target.path) == target else { throw ThemeFailure("stale target plan") }
        }
    }

    /// One press in Pilot's own window (Sven, after testing 2180): plan and apply at once, with no Allow, since Sven is the
    /// one pressing; the result names what changed, and Restore undoes it. The pilot CLI, a link and an agent go through
    /// plan, then apply, which always asks.
    func press(_ id: String?) async throws(ControlError) -> JSONValue {
        let planned: ThemePlan
        do { planned = try await plan(id) } catch { throw ControlError(.badValue, String(describing: error)) }
        return try await apply(planned.id, peer: nil, pressed: true)
    }
    /// The sandbox's stand-in for Look's button: the same press, only on a fixture host.
    func fixturePress(_ id: String?) async throws(ControlError) -> JSONValue {
        guard fixtureRoot != nil else { throw ControlError(.badValue, "fixture host required") }
        return try await press(id)
    }

    func apply(_ planID: String, peer: ControlPeer?, pressed: Bool = false) async throws(ControlError) -> JSONValue {
        guard !busy else { throw ControlError(.badValue, "theme mutation already waiting/running") }
        guard let (plan, revision, ownership, appearance) = plans.removeValue(forKey: planID) else { throw ControlError(.badValue, "unknown/spent plan; plan again") }
        busy = true; defer { busy = false; removeMadeFolders() }  // Also after a throw: an empty folder from a failed Apply goes.
        do { try await fresh(plan, contextRevision: revision, appearance: appearance) }
        catch { throw ControlError(.badValue, String(describing: error)) }
        // The plan's identity is the spent key above, not anything shown here.
        let words = review(plan, appearance: appearance)
        let ask = ControlGate.Ask(plan.packID == nil ? "Restore default appearance" : "Apply theme",
                                  ThemeAllowText.fit(lead: plan.selection?.title ?? "Your previous look", entries: words.entries, skipped: words.skipped.filter { $0 != Self.cursorSkipped && $0 != Self.modeSkipped } + words.kept, limit: ControlGate.Ask.longest - 150, home: NSHomeDirectory()))
        let committed = try await gate.allow(pressed ? nil : ask, peer: peer) { () throws(ControlError) in
            do {
                try await fresh(plan, contextRevision: revision, appearance: appearance)
                let ready = try self.makingFolders(plan)
                try self.adoptDetected(ready)
                return try await self.commit(ready, ownership: ownership, appearance: appearance)
            } catch { throw ControlError(.badValue, String(describing: error)) }
        }
        guard case .object(var result) = committed, ["applied", "restored"].contains(result["status"]?.string ?? "") else { return committed }
        if plan.mutations.contains(where: { $0.target.root == binding.root }) {
            // Its menu item, never its key (ADR 0001). Colours reload in open windows (Ghostty's config docs).
            switch await effects.ghostty() {
            case true?: result["ghostty"] = .string("reloaded")
            case nil: result["ghostty"] = .string("not running; it reads the theme when it opens")
            case false?:
                result["ghostty"] = .string("no Reload Configuration menu item")
                result["next"] = .array([.string("Reload Ghostty's configuration (Cmd+Shift+,) to see it: Pilot couldn't find its menu item.")] + (result["next"].flatMap { if case .array(let rows) = $0 { rows } else { nil } } ?? []))
            }
        }
        if plan.apps.contains(where: { app in app.kind == .btop && plan.mutations.contains { $0.target.root == app.root } }) {
            let count = await effects.btop()
            result["btop"] = .string(count > 0 ? "reloaded \(count) running" : "not running; it reads the theme when it starts")
        }
        guard result["status"] == .string("applied") else { return .object(result) }
        var outcomes: [JSONValue] = []
        for intent in plan.reloads {
            guard let command = intent.binding.reload else { continue }
            let detail = "\(intent.binding.app) runs \(String(decoding: (try? ThemeDigest.encoded(command)) ?? Data(), as: UTF8.self)). The theme's files have already changed"
            do {
                let committedLedger = try ledger().0, committedBindings = try state("bindings")
                let committedFiles = try uniqueResources(plan.mutations).map { change in
                    let current = try self.destination(change.target.root, change.target.path)
                    guard current.bytes == change.replacement, current.anchor == change.target.anchor, current.resolved == change.target.resolved else { throw ThemeFailure("files changed after commit; reload not run") }
                    return current
                }
                let outcome = try await gate.allow(.init("Reload custom theme app", detail), peer: peer) { () async throws(ControlError) -> String in
                    do {
                        guard try self.state("bindings") == committedBindings,
                              try self.context() == revision,
                              try self.ledger().0 == committedLedger,
                              try ThemeFiles.read(root: intent.executable.root, path: intent.executable.path) == intent.executable,
                              try self.state("pending").bytes == nil else { throw ThemeFailure("stale reload authority after Allow") }
                        for target in committedFiles + plan.observations.filter({ $0.root == intent.binding.app }) {
                            guard try self.destination(target.root, target.path) == target else { throw ThemeFailure("files/app identity changed before reload; command not run") }
                        }
                        if let id = plan.packID { guard try self.store.load(id).revision == plan.revision else { throw ThemeFailure("stale pack before reload") } }
                        try self.fault("reload")
                        return try await self.reload(intent)
                    } catch { throw ControlError(.badValue, String(describing: error)) }
                }
                outcomes.append(.object(["binding": .string(intent.binding.id), "outcome": .string(outcome)]))
            } catch {
                outcomes.append(.object(["binding": .string(intent.binding.id), "outcome": .string((error as? ControlError)?.code == .denied ? "declined, so it did not run. Reload the app yourself to see it" : "failed: \(error). The theme is in place; reload the app yourself")]))
            }
        }
        result["reloads"] = .array(outcomes)
        return .object(result)
    }

    /// The effects that wait on another app (macOS's mode, Ghostex) are awaited off the main thread; every check and the
    /// ledger write after them run back on it.
    private func commit(_ plan: ThemePlan, ownership: ThemeAppearanceOwnership?, appearance: ThemeAppearanceMutation?) async throws -> JSONValue {
        let (oldFile, old) = try ledger()
        if plan.mutations.isEmpty && plan.wallpapers.isEmpty && plan.keptWallpapers.isEmpty && plan.heldWallpapers.isEmpty && appearance == nil && old.claims.isEmpty && plan.ghostex.isEmpty && plan.ghostexClaims == (old.ghostexSettings ?? []) { return .object(["status": .string("unchanged"), "files": .string("unchanged"), "refresh": .string("not needed"), "warning": .string(plan.warnings.joined(separator: "; "))]) }
        try validateComposition(plan.mutations, claims: old.claims)
        var next = old; next.epoch += 1; next.selected = plan.selection; next.appearance = ownership
        next.claims = plan.packID == nil ? [] : plan.mutations.filter { $0.release != true }.map { change in
            let prior = old.claims.first { same($0, change.target, change.selector) }
            var claim = ThemeClaim(root: change.target.root, path: change.target.path, resolved: change.target.resolved,
                              anchor: change.target.anchor, selector: change.selector,
                              original: prior == nil ? change.before : prior!.original, last: change.after, codec: 1,
                              originalFileAbsent: prior?.originalFileAbsent ?? (change.target.bytes == nil))
            claim.bindingID = change.bindingID
            return claim
        }
        let wallpaperClaims = plan.wallpapers.filter { !$0.release }.map { change in
            ThemeWallpaperClaim(target: change.target, original: old.wallpapers?.first { $0.target == change.target }?.original ?? change.before, last: change.after)
        }
        let claimed = wallpaperClaims + plan.heldWallpapers
        next.wallpapers = claimed.isEmpty ? nil : claimed
        next.ghostexSettings = plan.ghostexClaims.isEmpty ? nil : plan.ghostexClaims
        if next.claims.isEmpty && next.wallpapers == nil && next.appearance == nil { next.selected = nil }  // Everything it owned has gone.
        let nextBytes = try ThemeDigest.encoded(next)
        let journal = ThemeJournal(schema: 1, beforeLedger: oldFile.bytes, afterLedger: nextBytes, mutations: plan.mutations, wallpapers: plan.wallpapers.isEmpty ? nil : plan.wallpapers, appearance: appearance, ghostexSettings: plan.ghostex.isEmpty ? nil : plan.ghostex, keptWallpapers: plan.keptWallpapers.isEmpty ? nil : plan.keptWallpapers, keptFiles: plan.keptFiles.isEmpty ? nil : plan.keptFiles,
                                   keptLook: plan.keptLook.isEmpty ? nil : plan.keptLook)
        let pending = try state("pending")
        try fault("journal")
        _ = try ThemeFiles.write(ThemeDigest.encoded(journal), over: pending)
        var recovered: JSONValue?
        var warning: String?
        do {
            for (i, change) in uniqueResources(plan.mutations).enumerated() {
                try fault("write:\(i)")
                _ = try replace(change.replacement, over: change.target)
                try fault("after-write:\(i)")
            }
            for (index, change) in plan.wallpapers.enumerated() {
                try fault("wallpaper:\(index)")
                try writeWallpaper(change)
                try fault("after-wallpaper:\(index)")
            }
            if let appearance {
                try fault("native")
                // Look's parts first, with nothing awaited since this read; macOS's mode last. A stop between leaves the theme's
                // parts with the old mode, the one in-between state recovery accepts (review 3, blocker 1).
                guard try native?.read() == appearance.before else { throw ThemeFailure("later personal appearance edit") }
                try native!.write(appearance.after)
                var parts = appearance.after; parts.dark = appearance.before.dark
                guard try native?.read() == parts else { throw ThemeFailure("native appearance not verified") }
                try fault("after-native")
                if appearance.mode == true, let dark = appearance.after.dark, appearance.before.dark != dark, native!.mode != nil {
                    try await switchMode(dark)
                    try fault("after-mode")
                }
                // After the mode wait only the owned parts count: an edit to a part the theme leaves alone is the person's.
                guard try appearance.matches(native!.read(), appearance.after) else { throw ThemeFailure("native appearance not verified") }
            }
            for (index, change) in plan.ghostex.enumerated() {
                try fault("ghostex:\(index)")
                try await ghostexColours!.write(change.key, change.after)
                try fault("after-ghostex:\(index)")
            }
            if !plan.ghostex.isEmpty {
                let state = try await ghostexColours!.read()
                guard plan.ghostex.allSatisfy({ state?[$0.key] == $0.after }) else { throw ThemeFailure("Ghostex colours not verified") }
            }
            try fault("ledger")
            _ = try ThemeFiles.write(nextBytes, over: oldFile)
            try fault("after-ledger")
            try fault("cleanup")
            _ = try ThemeFiles.write(nil, over: state("pending"))
            try fault("after-cleanup")
        } catch {
            let reason = String(describing: error)
            var recovery = try recover()
            if let rest = await finishDue() { recovery = rest }
            var verified = false, failure = reason
            if try ledger().0.bytes == nextBytes {
                do {
                    let targets = try uniqueResources(plan.mutations).map { try destination($0.target.root, $0.target.path) }
                    try checkDestinations(targets, legacy: protectedLegacy(ghostty: plan.observations.contains { $0.root == binding.root }, files: !plan.mutations.isEmpty))
                    verified = try plan.mutations.allSatisfy { change in
                        let current = targets.first { $0.root == change.target.root && $0.path == change.target.path }!
                        let owned = try ThemeRegions.owned(change.selector, in: current.bytes)
                        return current.anchor == change.target.anchor && current.resolved == change.target.resolved && owned == change.after && preservesExistence(current.bytes, of: change.replacement) && ThemeRegions.preservesContainer(change.selector, in: current.bytes, of: change.replacement)
                    }
                    if verified { verified = try plan.wallpapers.allSatisfy { try wallpaper?.read().value($0.target) == $0.after } }
                    if verified, let appearance { verified = try native?.read() == appearance.after }
                } catch { failure += "; commit verification: \(error)" }
            }
            guard verified else {
                return .object(["status": .string("failed"), "files": .string("see recovery"), "error": .string(failure), "recovery": recovery, "refresh": .string("not attempted"), "wallpaper": .string("see recovery")])
            }
            recovered = recovery; warning = reason
        }
        if native == nil { effects.appearance(plan.selection) }
        var result: [String: JSONValue] = ["status": .string(plan.packID == nil ? "restored" : "applied"), "files": .string("verified"), "epoch": .number(Double(next.epoch))]
        let words = review(plan, appearance: appearance)
        result["changed"] = .array(words.short.map(JSONValue.string)); result["next"] = .array(words.next.map(JSONValue.string))
        result["changes"] = .array(words.entries.map { .string($0.name) })  // Shown after a press: what changed, row by row.
        result["kept"] = .array(keptWords(plan, done: true, appearance: appearance).map(JSONValue.string))
        result["wallpaper"] = .string(plan.wallpapers.isEmpty ? "unchanged" : "assignments verified; " + effects.kind)
        result["warning"] = .string(plan.warnings.joined(separator: "; "))
        if let recovered { result["recovery"] = recovered }
        if let warning { result["warning"] = .string(warning + "; " + plan.warnings.joined(separator: "; ")) }
        do { try fault("effect"); result["refresh"] = .string(try effects.refresh()) }
        catch { result["refresh"] = .string("failed: \(error); reload needed"); result["rollback"] = .string("not attempted; files committed") }
        return .object(result)
    }

    private func uniqueResources(_ mutations: [ThemeMutation]) -> [ThemeMutation] {
        var seen = Set<String>()
        return mutations.filter { seen.insert(resource($0.target)).inserted }
    }

    /// Both Apply and recovery derive the whole resource from the saved bytes and owned selectors.
    /// A journal's replacement never grants authority over unrelated snapshot bytes.
    private func composedResource(_ changes: [ThemeMutation], claims: [ThemeClaim]) throws -> Data? {
        guard let first = changes.first else { throw ThemeFailure("empty resource composition") }
        var bytes = first.target.bytes
        for change in changes {
            guard change.target == first.target,
                  try ThemeRegions.owned(change.selector, in: first.target.bytes) == change.before else {
                throw ThemeFailure("inconsistent resource snapshot/owned before state; journal retained")
            }
            bytes = try ThemeRegions.replacing(change.selector, in: bytes, with: change.after)
            if change.release == true, let prior = claims.first(where: { same($0, change.target, change.selector) }), prior.originalFileAbsent {
                if case .block = change.selector, bytes?.isEmpty == true { bytes = nil }
                if case .jsonMembership = change.selector, bytes == Data("{}".utf8) { bytes = nil }
                if case .jsonValue = change.selector, ThemeRegions.emptyObject(bytes) { bytes = nil }
            }
        }
        return bytes
    }

    private func validateComposition(_ mutations: [ThemeMutation], claims: [ThemeClaim]) throws {
        for first in uniqueResources(mutations) {
            let group = mutations.filter { resource($0.target) == resource(first.target) }
            let expected = try composedResource(group, claims: claims)
            guard group.allSatisfy({ $0.replacement == expected }) else {
                throw ThemeFailure("inconsistent resource before/after composition; journal retained")
            }
        }
    }

    /// Later nonempty unrelated bytes may keep a resource alive, but empty never substitutes for absent.
    private func preservesExistence(_ bytes: Data?, of expected: Data?) -> Bool {
        expected == nil ? bytes?.isEmpty != true : bytes != nil
    }

    /// Reconcile a durable pending journal. Rollback only regions still matching this operation, never unrelated bytes.
    /// What recovery owes and never waits for itself: macOS's mode and Ghostex's colours, each a child process awaited
    /// off the main thread here, Ghostex first, the mode before the rest; then recovery runs again to finish. Launch starts
    /// it without waiting; a failed Apply or Restore waits for it.
    @discardableResult func finishDue() async -> JSONValue? {
        guard modeDue != nil || ghostexDue != nil else { return nil }
        let dark = modeDue, ghostex = ghostexDue
        modeDue = nil; ghostexDue = nil
        var settled: (rows: [JSONValue], conflict: Bool)?
        if let ghostex { settled = await rollbackGhostex(ghostex) }
        do {
            if let dark { try await switchMode(dark) }
            return try recover(ghostex: settled)
        } catch { return .object(["status": .string("recovery retained"), "rows": .array([.object(["native": .string("conflicted/failed: \(error)")])])]) }
    }
    func recoverAtLaunch() throws -> JSONValue {
        let result = try recover()
        if modeDue != nil || ghostexDue != nil { Task { await finishDue() } }
        return result
    }
    /// macOS's mode, awaited off the main thread. A switch that throws yet lands late counts: the mode is read once more.
    private func switchMode(_ dark: Bool) async throws {
        do { try await native!.mode!(dark) }
        catch { guard try native!.read().dark == dark else { throw error } }
    }

    @discardableResult func recover(ghostex settled: (rows: [JSONValue], conflict: Bool)? = nil) throws -> JSONValue {
        modeDue = nil; ghostexDue = nil
        let (currentLedger, record) = try ledger()
        let pending = try state("pending")
        guard let bytes = pending.bytes else {
            if native == nil { effects.appearance(record.selected) }
            return .object(["status": .string("clean")])
        }
        let journal = try JSONDecoder().decode(ThemeJournal.self, from: bytes)
        guard journal.schema == 1, (!journal.mutations.isEmpty || !(journal.wallpapers ?? []).isEmpty || journal.appearance != nil || !(journal.ghostexSettings ?? []).isEmpty
                                    || !(journal.keptWallpapers ?? []).isEmpty || !(journal.keptFiles ?? []).isEmpty || !(journal.keptLook ?? []).isEmpty),
              (journal.ghostexSettings ?? []).allSatisfy({ GhostexInterface.valid(key: $0.key, values: [$0.before, $0.after]) }),
              journal.mutations.allSatisfy({ validSelector($0.selector, root: $0.target.root, path: $0.target.path) }),
              Set(journal.mutations.map { resource($0.target) + ":" + ((try? ThemeDigest.encoded($0.selector)).map(ThemeDigest.of) ?? "invalid") }).count == journal.mutations.count else { throw ThemeFailure("corrupt recovery journal") }
        try validateOverlaps(journal.mutations.map { ($0.target.root, $0.target.path, $0.selector) })
        for bytes in [journal.beforeLedger, journal.afterLedger].compactMap({ $0 }) { try validate(ThemeLedger.decode(bytes)) }
        let beforeClaims = try journal.beforeLedger.map(ThemeLedger.decode)?.claims ?? []
        let afterClaims = try journal.afterLedger.map(ThemeLedger.decode)?.claims ?? []
        let custom = try selection().custom ?? []
        for change in journal.mutations where custom.contains(where: { $0.root == change.target.root && $0.path == change.target.path }) {
            guard let id = change.bindingID, custom.contains(where: { $0.id == id && $0.root == change.target.root && $0.path == change.target.path }) else { throw ThemeFailure("unbound custom recovery identity") }
            let before = beforeClaims.first { same($0, change.target, change.selector) && $0.bindingID == id }
            let after = afterClaims.first { same($0, change.target, change.selector) && $0.bindingID == id }
            if change.release == true {
                guard let before, after == nil, ThemeRegions.sameMeaning(change.selector, change.before, before.last), change.after == before.original else { throw ThemeFailure("inconsistent custom release journal") }
            } else {
                guard let after, after.last == change.after, after.original == (before == nil ? change.before : before!.original),
                      before == nil || ThemeRegions.sameMeaning(change.selector, change.before, before!.last) else { throw ThemeFailure("inconsistent custom original/last journal") }
            }
        }
        try validateWallpaperJournal(journal)
        try validateAppearanceJournal(journal)
        try ThemeLedger.validateNativeFields(bytes, appearance: journal.appearance.map { try ThemeDigest.encoded($0) })
        let resources = uniqueResources(journal.mutations)
        try validateComposition(journal.mutations, claims: beforeClaims)
        let committed = currentLedger.bytes == journal.afterLedger
        guard committed || currentLedger.bytes == journal.beforeLedger else { throw ThemeFailure("recovery ledger conflict; retained") }
        // No appearance effect precedes validation of every embedded authority record.
        if native == nil { effects.appearance(record.selected) }
        let ghostty = (beforeClaims + afterClaims).contains { $0.root == binding.root } || resources.contains { $0.target.root == binding.root }
        let legacy = try protectedLegacy(ghostty: ghostty, files: !resources.isEmpty)
        try checkDestinations(try resources.map { try destination($0.target.root, $0.target.path) }, legacy: legacy)
        var rows: [JSONValue] = [], conflict = false
        for (i, change) in journal.mutations.enumerated().reversed() {
            do {
                // A journal cannot add destination authority, even if damaged or edited.
                guard validSelector(change.selector, root: change.target.root, path: change.target.path) else { throw ThemeFailure("unsafe journal destination") }
                let current = try destination(change.target.root, change.target.path)
                try checkDestinations([current], legacy: legacy)
                guard anchored(change.target.anchor, current), current.resolved == change.target.resolved else { throw ThemeFailure("target identity conflict") }
                let owned = try ThemeRegions.owned(change.selector, in: current.bytes)
                if committed {
                    guard owned == change.after, preservesExistence(current.bytes, of: change.replacement) && ThemeRegions.preservesContainer(change.selector, in: current.bytes, of: change.replacement) else { throw ThemeFailure("committed target changed") }
                    rows.append(.object(["path": .string(current.root + "/" + current.path), "rollback": .string("not attempted; committed state verified")]))
                } else if owned == change.before {
                    guard preservesExistence(current.bytes, of: change.target.bytes) && ThemeRegions.preservesContainer(change.selector, in: current.bytes, of: change.target.bytes) else { throw ThemeFailure("pre-state resource existence changed; recovery retained") }
                    rows.append(.object(["path": .string(current.root + "/" + current.path), "rollback": .string("not needed; pre-state verified")]))
                } else {
                    guard owned == change.after else { throw ThemeFailure("later owned edit") }
                    if case .block = change.selector, owned == nil, change.before != nil, current.bytes != change.replacement {
                        throw ThemeFailure("absent block placement changed; recovery retained")
                    }
                    try fault("rollback:\(i)")
                    var restore = try ThemeRegions.replacing(change.selector, in: current.bytes, with: change.before)
                    let singleSelector = journal.mutations.filter { resource($0.target) == resource(change.target) }.count == 1
                    if current.bytes == change.replacement, singleSelector { restore = change.target.bytes }
                    let restored = try replace(restore, over: current)
                    guard try ThemeRegions.owned(change.selector, in: restored.bytes) == change.before,
                          preservesExistence(restored.bytes, of: change.target.bytes) && ThemeRegions.preservesContainer(change.selector, in: restored.bytes, of: change.target.bytes) else { throw ThemeFailure("rollback owned region/resource existence not verified") }
                    rows.append(.object(["path": .string(current.root + "/" + current.path), "rollback": .string("attempted; verified")]))
                }
            } catch {
                conflict = true
                rows.append(.object(["path": .string(change.target.root + "/" + change.target.path), "rollback": .string("conflicted/failed: \(error)")]))
            }
        }
        let wallpaperRows = try recoverWallpapers(journal.wallpapers ?? [], committed: committed)
        rows += wallpaperRows.rows; conflict = conflict || wallpaperRows.conflict
        let ghostexRows = recoverGhostex(journal.ghostexSettings ?? [], committed: committed, settled: settled)
        rows += ghostexRows.rows; conflict = conflict || ghostexRows.conflict
        if let change = journal.appearance {
            do {
                let current = try native!.read()
                if committed { guard change.matches(current, change.after) else { throw ThemeFailure("committed native appearance changed") } }
                else if !change.matches(current, change.before) {
                    // macOS's mode goes back first, on its own, awaited off the main thread (finishDue); this pass then puts back the rest.
                    var reached = change.after
                    if current.dark == change.before.dark { reached.dark = current.dark }
                    guard change.matches(current, reached) else { throw ThemeFailure("later personal appearance edit") }
                    try fault("native-rollback")
                    if change.mode == true, let dark = change.before.dark, current.dark != dark, native!.mode != nil { modeDue = dark }
                    else {
                        try native!.write(change.merging(change.before, into: current))
                        guard try change.matches(native!.read(), change.before) else { throw ThemeFailure("native rollback not verified") }
                    }
                }
                if let dark = modeDue {
                    conflict = true; rows.append(.object(["native": .string("macOS switching back to \(dark ? "Dark" : "Light") mode; the rest follows")]))
                } else { rows.append(.object(["native": .string("verified; personal items and fonts untouched")])) }
            } catch {
                conflict = true; rows.append(.object(["native": .string("conflicted/failed: \(error)")]))
            }
        }
        var cleanup = "retained"
        if !conflict {
            do { try fault("recovery-cleanup"); _ = try ThemeFiles.write(nil, over: pending); cleanup = "cleared" }
            catch { cleanup = "retained: \(error)" }
        }
        return .object(["status": .string(conflict ? "recovery retained" : (committed ? "committed verified" : "rollback verified")),
                        "rows": .array(rows), "journal": .string(cleanup), "refresh": .string("unverified; reload needed; recovery executes no refresh")])
    }
}

/// Separate composition, called before Engine, live settings, Keychain or production registration.
struct ThemeFixture: Decodable {
    let root, packs, writablePacks, state, socket, effects, control: String
    let binding: ThemeBinding
    let zed: ThemeBinding?
    let zedOptOut: Bool?
    let obsidian: [ThemeBinding]?
    let obsidianOptOut: Bool?
    let detectHome: String?
    let cursorIsMacOS: Bool?
    let ghostexSettings: String?
    let factoryPacks, wallpaperState, cursorRoot, nativeState: String?
    let wallpaperBindings: [String]?
    let nativeBaseline: ThemeNativeAppearance?
    let custom: [ThemeMappingBinding]?
    /// A catalogue/ folder inside the root a shipped pack's pictures are fetched from (ShippedWallpapers), into
    /// <root>/wallpapers; nil fetches none.
    let catalogue: String?

    @MainActor static func serve(_ manifest: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard !env.keys.contains(where: { $0.hasPrefix("PILOT_SANDBOX") }), env["CFFIXED_USER_HOME"] == nil,
              env["PILOT_LIVE"] == nil, env["PILOT_FOCUS"] == nil else { throw ThemeFailure("incompatible fixture environment") }
        let manifestBytes = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let config = try JSONDecoder().decode(Self.self, from: manifestBytes)
        try ThemeLedger.validateFields(manifestBytes, field: "custom", encoded: config.custom.map { try ThemeDigest.encoded($0) })
        guard config.root.hasPrefix("/"), URL(fileURLWithPath: config.root).resolvingSymlinksInPath().path == config.root,
              config.effects == "recording", config.socket.utf8.count < 100,
              URL(fileURLWithPath: config.socket).resolvingSymlinksInPath().path == config.socket,
              ![config.packs, config.writablePacks, config.state, config.binding.root].contains(where: { config.socket.hasPrefix($0 + "/") }),
              config.socket != config.control, config.socket != manifest,
              [config.packs, config.writablePacks, config.state, config.socket, config.control, config.binding.root].allSatisfy({ $0.hasPrefix(config.root + "/") }),
              config.packs != config.state, config.binding.root != config.state,
              ThemeFiles.relative(config.binding.config), ThemeFiles.relative(config.binding.generated) else { throw ThemeFailure("fixture requires explicit isolated roots/binding/private socket/recording effects") }
        if let zed = config.zed {
            guard zed.root.hasPrefix(config.root + "/"), !config.socket.hasPrefix(zed.root + "/"), zed.config == "settings.json", zed.generated == "themes/pilot-theme.json" else { throw ThemeFailure("unsafe fixture Zed binding") }
        }
        for vault in config.obsidian ?? [] {
            let configDir = String(vault.config.dropLast("/appearance.json".count))
            guard try ObsidianThemeAdapter.binding(root: vault.root, configDir: configDir) == vault,
                  vault.root.hasPrefix(config.root + "/"), !config.socket.hasPrefix(vault.root + "/") else { throw ThemeFailure("unsafe fixture Obsidian binding") }
        }
        if let home = config.detectHome { guard home.hasPrefix(config.root + "/") else { throw ThemeFailure("unsafe fixture detection home") } }
        for directory in [config.packs, config.writablePacks, config.state, config.binding.root] + [config.zed?.root, config.detectHome].compactMap({ $0 }) + (config.obsidian ?? []).map(\.root) {
            guard URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == directory else { throw ThemeFailure("fixture root symlink") }
        }
        for path in [config.factoryPacks, config.wallpaperState, config.cursorRoot, config.nativeState, config.catalogue].compactMap({ $0 }) {
            guard path.hasPrefix(config.root + "/"), URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
                  !config.socket.hasPrefix(path + "/"), path != config.socket else { throw ThemeFailure("unsafe fixture wallpaper/factory/cursor path") }
        }
        guard (config.wallpaperState == nil) == (config.wallpaperBindings == nil),
              Set(config.wallpaperBindings ?? []).count == (config.wallpaperBindings ?? []).count else { throw ThemeFailure("explicit fixture display bindings required") }
        // This optional transport proof composition never changes production registration/gates.
        let agentSkills: [AISkill]?
        if let path = env["PILOT_THEME_AGENT_SKILLS"] {
            guard path.hasPrefix(config.root + "/"), URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
                  config.nativeState != nil, config.wallpaperState != nil else { throw ThemeFailure("explicit isolated agent skills/native/wallpaper stores required") }
            let loaded = AISkills.load { name in
                guard let read = try? ThemeFiles.read(root: path, path: name + "/SKILL.md"),
                      read.resolved == path + "/" + name + "/SKILL.md", let bytes = read.bytes else { return nil }
                return String(data: bytes, encoding: .utf8)
            }
            guard loaded.map(\.name) == AISkills.names else { throw ThemeFailure("missing/incompatible fixture skill resources") }
            agentSkills = AISkills.guides(loaded)
        } else { agentSkills = nil }
        @Sendable func controls() throws -> [String: String] {
            let relative = String(config.control.dropFirst(config.root.count + 1))
            guard let data = try ThemeFiles.read(root: config.root, path: relative).bytes else { throw ThemeFailure("missing fixture control") }
            return try JSONDecoder().decode([String: String].self, from: data)
        }
        let gate = ControlGate { ask, peer in
            do {
                let values = try controls()
                if agentSkills != nil {
                    // The model can request an operation, but only the separate proof host
                    // writes this response inside the protected state root. Match a fresh
                    // question and the socket's actual peer; caller-supplied yes is inert.
                    guard let peer, peer.pid > 0, peer.uid == getuid() else { return false }
                    let question = UUID().uuidString
                    let request: JSONValue = .object(["id": .string(question), "title": .string(ask.title),
                        "detail": .string(ask.detail), "pid": .number(Double(peer.pid)), "uid": .number(Double(peer.uid))])
                    let response = try ThemeFiles.read(root: config.state, path: "agent-response.json")
                    _ = try ThemeFiles.write(ThemeDigest.encoded(request), over: ThemeFiles.read(root: config.state, path: "agent-request.json"))
                    var allowed = false
                    for _ in 0..<(values["agentWait"] == "yes" ? 100 : 1) {
                        let current = try ThemeFiles.read(root: config.state, path: "agent-response.json")
                        if current != response, let bytes = current.bytes,
                           case .object(let answer) = try JSONDecoder().decode(JSONValue.self, from: bytes),
                           answer["id"] == .string(question), answer["pid"] == .number(Double(peer.pid)),
                           answer["title"] == .string(ask.title) {
                            allowed = answer["allow"] == .bool(true); break
                        }
                        if values["agentWait"] != "yes" { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let event = try ThemeFiles.read(root: config.state, path: "agent-gates.jsonl")
                    let record: JSONValue = .object(["request": request, "allowed": .bool(allowed), "authority": .string("separate fixture host response only")])
                    _ = try ThemeFiles.write((event.bytes ?? Data()) + ThemeDigest.encoded(record) + Data([10]), over: event)
                    return allowed
                }
                print("THEME Allow asked: \(ask.text)"); fflush(stdout)
                let isReload = ask.title == "Reload custom theme app"
                if values[isReload ? "reloadHold" : "hold"] == "yes" {
                    let asked = config.root + (isReload ? "/reload-asked" : "/asked"), go = config.root + (isReload ? "/reload-go" : "/go")
                    try Data(ask.text.utf8).write(to: URL(fileURLWithPath: asked))
                    for _ in 0..<250 {
                        if FileManager.default.fileExists(atPath: go) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard FileManager.default.fileExists(atPath: go) else { return false }
                }
                if ask.title == "Reload custom theme app" { return values["reloadAllow"] == "yes" }
                return values["allow"] == "yes"
            } catch { return false }
        }
        let fixtureCatalogue: CursorCatalogue?
        if let root = config.cursorRoot {
            guard let bytes = try ThemeFiles.read(root: root, path: "cursors.json").bytes else { throw ThemeFailure("missing fixture cursor catalogue") }
            fixtureCatalogue = try JSONDecoder().decode(CursorCatalogue.self, from: bytes)
        } else { fixtureCatalogue = nil }
        let samples = fixtureCatalogue.map { CursorSamples(folder: nil, catalogue: $0) }
        func recordAppearance(_ pack: ThemePack?, stock: String? = nil) {
            let appearance = pack?.appearance(keeping: .standard) ?? stock.flatMap(PilotTheme.named) ?? .standard
            print("THEME appearance: \(pack?.id ?? "baseline") ground=\(appearance.ground)"); fflush(stdout)
            if let catalogue = fixtureCatalogue {
                do {
                    let palettes = catalogue.sets.mapValues { $0.palette(.theme, theme: appearance.id, resolved: appearance) }
                    let cached = catalogue.sets.keys.reduce(into: [String: JSONValue]()) { result, id in
                        guard let set = CursorSetID(rawValue: id), let samples else { return }
                        result[id] = .object(samples.palette(set, .theme, theme: appearance.id, custom: .init(set: set), resolved: appearance).mapValues(JSONValue.string))
                    }
                    let effects = CursorEffectColours.of(appearance.id, resolved: appearance)
                    let roles = ["ground": appearance.ground, "sidebar": appearance.sidebar, "surface": appearance.surface, "raised": appearance.raised,
                        "line": appearance.line, "line2": appearance.line2, "text": appearance.text, "text2": appearance.text2, "text3": appearance.text3,
                        "accent": appearance.accent, "second": appearance.second, "third": appearance.third, "good": appearance.good, "amber": appearance.amber, "problem": appearance.problem]
                    let record: JSONValue = .object(["id": .string(appearance.id), "roles": .object(roles.mapValues { .string(ColourAnswer.hex($0)) }),
                        "graphs": .array(appearance.graphs.map { .string(ColourAnswer.hex($0)) }), "selection": .number(appearance.selection.alpha),
                        "cursor": .object(palettes.mapValues { .object($0.mapValues(JSONValue.string)) }), "cachedCursor": .object(cached), "effect": .string(ColourAnswer.hex(effects.effectRGB)),
                        "radius": .number(appearance.radius), "face": .string(appearance.face.family), "focus": .string(appearance.focus.rawValue)])
                    _ = try ThemeFiles.write(ThemeDigest.encoded(record), over: ThemeFiles.read(root: config.state, path: "appearance.json"))
                } catch { print("THEME appearance recording failed: \(error)"); fflush(stdout) }
            }
        }
        let wallpaper: ThemeCoordinator.WallpaperEffects?
        if let path = config.wallpaperState {
            let relative = String(path.dropFirst(config.root.count + 1))
            func readWallpaper() throws -> ThemeWallpaperState {
                guard let bytes = try ThemeFiles.read(root: config.root, path: relative).bytes else { throw ThemeFailure("missing fixture wallpaper state") }
                let state = try JSONDecoder().decode(ThemeWallpaperState.self, from: bytes)
                try state.validate()
                guard Set(state.displays.map(\.id)) == Set(config.wallpaperBindings!),
                      (state.sources + state.displays.compactMap(\.image)).allSatisfy({ $0.hasPrefix(config.root + "/") }) else { throw ThemeFailure("fixture wallpaper outside explicit root/display bindings") }
                return state
            }
            _ = try readWallpaper() // Prove fake bindings/state before constructing any host or running Apply.
            wallpaper = .init(read: readWallpaper, write: { change in
                guard try controls()["wallpaperFail"] != "before" else { throw ThemeFailure("recording effect refused before assignment") }
                let file = try ThemeFiles.read(root: config.root, path: relative), before = try readWallpaper()
                var sources = before.sources, displays = before.displays
                switch (change.target, change.after) {
                case (.sources, .sources(let paths)): sources = paths
                case (.display(let id), .image(let image)):
                    displays = displays.map { $0.id == id ? .init(id: $0.id, workspace: $0.workspace, portrait: $0.portrait, image: image, pinned: $0.pinned) : $0 }
                default: throw ThemeFailure("invalid recording wallpaper effect")
                }
                let next = ThemeWallpaperState(sources: sources, displays: displays, preferences: before.preferences)
                guard (next.sources + next.displays.compactMap(\.image)).allSatisfy({ $0.hasPrefix(config.root + "/") }) else { throw ThemeFailure("recording effect escapes fixture") }
                _ = try ThemeFiles.write(ThemeDigest.encoded(next), over: file)
                let log = try ThemeFiles.read(root: config.state, path: "wallpaper-effects.jsonl")
                _ = try ThemeFiles.write((log.bytes ?? Data()) + ThemeDigest.encoded(change) + Data([10]), over: log)
                guard try controls()["wallpaperFail"] != "after" else { throw ThemeFailure("recording effect failed after assignment") }
            })
        } else { wallpaper = nil }
        // Records calls in the fixture's file. No process runs, so a proof can never reach the real Ghostex.
        var ghostexColours: ThemeCoordinator.GhostexEffects? = nil
        if let path = config.ghostexSettings {
            guard path.hasPrefix(config.root + "/") else { throw ThemeFailure("unsafe fixture Ghostex state") }
            let relative = String(path.dropFirst(config.root.count + 1))
            func fake() throws -> [String: JSONValue] {
                guard let bytes = try ThemeFiles.read(root: config.root, path: relative).bytes,
                      case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: bytes) else { throw ThemeFailure("missing fixture Ghostex state") }
                return fields
            }
            func values() throws -> [String: String]? {
                let fields = try fake()
                guard fields["running"] == .bool(true), case .object(let found)? = fields["values"] else { return nil }
                // Colourfulness is a number, as the real CLI lists it.
                return found.compactMapValues { switch $0 { case .string(let text): text; case .number(let value): GhostexInterface.text(value); default: nil } }
            }
            ghostexColours = .init(installed: { (try? fake())?["installed"] == .bool(true) }, read: {
                try await ThemeCoordinator.fixtureWait(controls()["ghostexWait"]); return try values()
            }, write: { key, value in
                try await ThemeCoordinator.fixtureWait(controls()["ghostexWait"])
                guard try controls()["ghostexFail"] != key, var found = try values() else { throw ThemeFailure("recording Ghostex set refused: \(key)") }
                found[key] = value
                var fields = try fake()
                fields["values"] = .object(Dictionary(uniqueKeysWithValues: found.map { key, text in
                    (key, GhostexInterface.numbers.contains(key) ? Double(text).map(JSONValue.number) ?? .string(text) : .string(text))
                }))
                _ = try ThemeFiles.write(ThemeDigest.encoded(fields), over: ThemeFiles.read(root: config.root, path: relative))
                let log = try ThemeFiles.read(root: config.state, path: "ghostex-effects.jsonl")
                _ = try ThemeFiles.write((log.bytes ?? Data()) + ThemeDigest.encoded(["set", key, value]) + Data([10]), over: log)
            })
        }
        let native: ThemeCoordinator.NativeEffects?
        if let path = config.nativeState {
            let relative = String(path.dropFirst(config.root.count + 1))
            func readNative() throws -> ThemeNativeAppearance {
                guard let bytes = try ThemeFiles.read(root: config.root, path: relative).bytes else { throw ThemeFailure("missing native fixture state") }
                let value = try JSONDecoder().decode(ThemeNativeAppearance.self, from: bytes)
                try value.validate()
                guard try JSONDecoder().decode(JSONValue.self, from: bytes) == (try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(value))) else { throw ThemeFailure("unknown native fixture fields") }
                return value
            }
            _ = try readNative()
            try config.nativeBaseline?.validate()
            func writeNative(_ value: ThemeNativeAppearance) throws {
                try value.validate()
                _ = try ThemeFiles.write(ThemeDigest.encoded(value), over: ThemeFiles.read(root: config.root, path: relative))
                let file = try ThemeFiles.read(root: config.state, path: "native-effects.jsonl")
                _ = try ThemeFiles.write((file.bytes ?? Data()) + ThemeDigest.encoded(value) + Data([10]), over: file)
            }
            native = .init(read: readNative, write: { value in
                ThemeCoordinator.fixtureBlock(try controls()["modeWait"])
                let state = try readNative(); var value = value; value.dark = state.dark; value.auto = state.auto  // As in production, write never sets macOS's mode.
                try writeNative(value)
                switch value.palette { case .pack(let pack): recordAppearance(pack); case .stock(let id): recordAppearance(nil, stock: id) }
            }, baseline: config.nativeBaseline.map { value in { value } }, mode: { dark in
                try await ThemeCoordinator.fixtureWait(controls()["modeWait"])
                var value = try readNative(); value.dark = dark; try writeNative(value)
                // "late": the switch lands but reports failure, as a slow System Events can after osascript gives up.
                if try controls()["modeWait"] == "late" { throw ThemeFailure("recording mode switch reported failure") }
            })
        } else { native = nil }
        let coordinator = ThemeCoordinator(store: ThemePackStore(root: config.packs, writableRoot: config.writablePacks, factoryRoot: config.factoryPacks), binding: config.binding,
            stateRoot: config.state, effects: .init(kind: "recording only", refresh: {
                let file = try ThemeFiles.read(root: config.state, path: "effects.json")
                let record = (file.bytes ?? Data()) + Data("recorded Ghostty/Zed/Obsidian refresh; reload needed\n".utf8)
                _ = try ThemeFiles.write(record, over: file)
                return "recorded; reload needed (no live refresh)"
            }, appearance: { recordAppearance($0) }, ghostty: {
                // Recorded only: a fixture never presses a real menu. The control file plays a closed or menu-less Ghostty.
                let state = (try? controls())?["ghostty"]
                if state == "closed" { return nil }
                if state == "missing" { return false }
                if let file = try? ThemeFiles.read(root: config.state, path: "ghostty-reloads.log") {
                    _ = try? ThemeFiles.write((file.bytes ?? Data()) + Data("Ghostty › Reload Configuration\n".utf8), over: file)
                }
                return true
            }, btop: {
                // Recorded only: a fixture never signals a real process. The control file says how many are running.
                let running = (try? controls())?["btop"].flatMap { Int($0) } ?? 1
                if running > 0, let file = try? ThemeFiles.read(root: config.state, path: "btop-reloads.log") {
                    _ = try? ThemeFiles.write((file.bytes ?? Data()) + Data("btop SIGUSR2 ×\(running)\n".utf8), over: file)
                }
                return running
            }), reload: { intent in
                // Pause after the asynchronous handoff, before the same final validation as production.
                try await Task.detached {
                    let values = try controls()
                    if values["launchHold"] == "yes" {
                        try Data("detached launch handoff".utf8).write(to: URL(fileURLWithPath: config.root + "/launch-asked"))
                        for _ in 0..<1000 {
                            if FileManager.default.fileExists(atPath: config.root + "/launch-go") { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        guard FileManager.default.fileExists(atPath: config.root + "/launch-go") else { throw ThemeFailure("fixture launch barrier timed out") }
                    }
                    return try intent.launch { command in
                        let file = try ThemeFiles.read(root: config.state, path: "reload-effects.jsonl")
                        let ownership = try ThemeFiles.read(root: config.state, path: "ownership.json")
                        guard ownership.bytes != nil, try ThemeFiles.read(root: config.state, path: "pending.json").bytes == nil else { throw ThemeFailure("reload recorder requires committed files/ledger") }
                        let record: JSONValue = .object(["command": try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(command)), "ledgerDigest": .string(ThemeDigest.of(ownership.bytes!)), "pendingAbsent": .bool(true)])
                        _ = try ThemeFiles.write((file.bytes ?? Data()) + ThemeDigest.encoded(record) + Data([10]), over: file)
                        guard try controls()["reloadFail"] != "yes" else { throw ThemeFailure("recording reload failed; app refresh unverified") }
                        return "recorded only; no process executed; app refresh unverified"
                    }
                }.value
            }, native: native, gate: gate, style: { (try? controls()["style"]) ?? "invalid" }, context: {
                ThemeDigest.of(try Data(contentsOf: URL(fileURLWithPath: manifest)))
            }, fault: { stage in
                let values = try controls()
                if values["editorHold"] == stage {
                    try Data(stage.utf8).write(to: URL(fileURLWithPath: config.root + "/editor-asked"))
                    for _ in 0..<1000 {
                        if FileManager.default.fileExists(atPath: config.root + "/editor-go") { break }
                        usleep(10_000)
                    }
                    guard FileManager.default.fileExists(atPath: config.root + "/editor-go") else { throw ThemeFailure("fixture writer barrier timed out") }
                }
                if values["crash"] == stage { fflush(stdout); _exit(86) }
                if values["fail"]?.split(separator: "+").contains(Substring(stage)) == true { throw ThemeFailure("injected \(stage)") }
            }, zed: config.zed, zedOptOut: config.zedOptOut ?? false, fixtureRoot: config.root, obsidian: config.obsidian ?? [], obsidianOptOut: config.obsidianOptOut ?? false, custom: config.custom ?? [], wallpaper: wallpaper,
            detect: config.detectHome.map { home in { ThemeCoordinator.detectApps(home: home, within: config.root) } },
            cursorIsSystem: { config.cursorIsMacOS == true }, ghostexColours: ghostexColours, appsHome: config.detectHome)
        _ = try coordinator.zedSelection // Validate every explicit fixture binding before exposing a socket.
        if let catalogue = config.catalogue.map({ URL(filePath: $0, directoryHint: .isDirectory) }) {
            let source = ExtensionCatalogue.Source.folder(catalogue)
            coordinator.shipped = ThemeCoordinator.Shipped(wallpapers: ShippedWallpapers(root: config.root + "/wallpapers", source: source),
                                          index: { try ExtensionCatalogue.index(await source.fetch(ExtensionCatalogue.indexPath, ExtensionCatalogue.indexLimit)) })
        }
        let verbs = ControlVerbs(); verbs.registerCore(); verbs.registerThemes { coordinator }
        if env["PILOT_THEME_CAROUSEL"] == "1" { verbs.registerCarousel(.fixture(coordinator, root: config.root)) }  // T8's proof only.
        if let agentSkills { verbs.registerGuides(skills: { agentSkills }) }
        let socket = ControlSocket(path: URL(fileURLWithPath: config.socket), verbs: verbs)
        guard socket.start() else { throw ThemeFailure("fixture socket refused") }
        defer { socket.stop() }
        print("THEME FIXTURE ONLY: Engine=absent settings=absent Keychain=absent production-registry=absent effects=recording fallback=none")
        print("THEME roots: \(config.root); socket: \(config.socket); verbs: \(verbs.sorted.map(\.name).joined(separator: ","))")
        print("THEME recovery: \(try coordinator.recoverAtLaunch())"); fflush(stdout)
        let hold = URL(fileURLWithPath: config.socket + ".hold")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let start = Date()
        while FileManager.default.fileExists(atPath: hold.path), Date().timeIntervalSince(start) < 600 { try await Task.sleep(for: .milliseconds(100)) }
    }
}
