import Foundation
import Security
import PilotCore

/// Where widgets live (ADR 0016): each in `Widgets/<id>/`, its trust record and settings in `WidgetData/<id>/`, its
/// placements in `widgets.json`, all under Pilot's folder, so a test run and the sandbox host keep to their own. Files
/// only, no state: every read is fresh, so a trust record is never cached past the run it gates.
struct WidgetStore: Sendable {
    let widgets: URL, data: URL, placementsFile: URL
    /// Whether a run is handed its password settings from the Keychain: never for a check's test run of an outside
    /// folder, whose id is the folder's own claim.
    let passwords: Bool

    static let live = WidgetStore(root: PilotFolder.support)

    init(root: URL, passwords: Bool = true) {
        self.passwords = passwords
        widgets = root.appending(path: "Widgets", directoryHint: .isDirectory)
        data = root.appending(path: "WidgetData", directoryHint: .isDirectory)
        placementsFile = root.appending(path: "widgets.json")
    }

    /// A folder in Widgets that does not read as a widget, with why.
    struct Broken: Equatable, Sendable { let folder: String, why: String }

    /// Every folder in Widgets: the widgets by id, and the broken ones. A link, or a folder not named as its id, is broken:
    /// a trust record is kept by id and bound to the real folder.
    func installed() -> (widgets: [Widget], broken: [Broken]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: widgets.path)) ?? []
        var found: [Widget] = [], broken: [Broken] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            switch read(name) {
            case .success(let widget): found.append(widget)
            case .failure(let problems): broken.append(Broken(folder: name, why: problems.description))
            }
        }
        return (found, broken)
    }

    /// The widget `id`: one of Pilot's ready widgets, or an installed one; nil when there is none or it is broken.
    func widget(_ id: String) -> Widget? {
        ReadyWidgets.isReady(id) ? ReadyWidgets.widget(id) : try? read(id).get()
    }

    private func read(_ name: String) -> Result<Widget, Widget.Problems> {
        let folder = widgets.appending(path: name, directoryHint: .isDirectory)
        guard !ReadyWidgets.isReady(name) else { return .failure(Widget.Problems(reasons: ["\(name) is one of Pilot's ready widgets' ids"])) }
        guard Widget.identity(of: folder) != nil else { return .failure(Widget.Problems(reasons: ["it is not a folder (a link is not read)"])) }
        do {
            let widget = try Widget(folder: folder)
            guard widget.id == name else { return .failure(Widget.Problems(reasons: ["its folder is named \(name) but its id is \(widget.id)"])) }
            return .success(widget)
        } catch { return .failure(error) }
    }

    /// Whether `folder` is one of the Widgets folder's own folders, by file identity: it is a real folder (not a link), and
    /// the folder it sits in, every link above resolved, is the Widgets folder itself, however the path spells it.
    func holds(_ folder: URL) -> Bool {
        guard Widget.identity(of: folder) != nil,
              let root = Widget.identity(of: widgets.resolvingSymlinksInPath()),
              let parent = Widget.identity(of: folder.deletingLastPathComponent().resolvingSymlinksInPath()) else { return false }
        return parent == root
    }

    // MARK: Trust

    private func folder(_ id: String) -> URL { data.appending(path: id, directoryHint: .isDirectory) }

    func trustFile(_ id: String) -> URL { folder(id).appending(path: "trust.json") }

    /// The widget's trust now, read from its record and its folder's identity: locked with no record, a broken one, or
    /// one written for another folder (Q676). Pilot's bundled desk widgets are trusted: they are the app's own files.
    func trust(of widget: Widget) -> Widget.Trust {
        if ReadyWidgets.isDesk(widget) { return .trusted }
        guard holds(widget.folder) else { return .locked }
        return Widget.trust(Widget.readTrust(trustFile(widget.id)), folder: Widget.identity(of: widget.folder))
    }

    /// Gives `widget` its level, bound to its folder as it is now. Pilot's own surfaces call it (New widget, the builder,
    /// `/widget`, Duplicate to edit, Trust this widget, an import's lock); no `pilot` verb does, so no agent call raises a
    /// widget's trust.
    func setTrust(_ level: Widget.Trust, for widget: Widget) throws {
        guard holds(widget.folder), let identity = Widget.identity(of: widget.folder) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: widget.folder.path])
        }
        try FileManager.default.createDirectory(at: folder(widget.id), withIntermediateDirectories: true)
        try Widget.encode(Widget.TrustRecord(level: level, device: identity.device, inode: identity.inode)).write(to: trustFile(widget.id), options: .atomic)
    }

    /// A widget's files ready to import: a folder as it is, or a .zip unpacked into a temporary folder of its own (T22).
    /// `remove()` when done; for a folder it removes nothing.
    struct Unpacked: Sendable {
        let folder: URL, scratch: URL?
        func remove() { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
    }

    /// A folder as it is; a .zip through `unpack`; anything but a file on this Mac (a dropped web link) is refused.
    func open(_ source: URL) async throws(Widget.Problems) -> Unpacked {
        guard source.isFileURL else { throw Widget.Problems(reasons: ["it is not a folder or a .zip on this Mac"]) }
        return source.pathExtension.lowercased() == "zip" ? try await unpack(source) : Unpacked(folder: source, scratch: nil)
    }

    /// Lists the .zip's entries first (one `zipinfo -s`: each entry's kind and the unpacked total) and refuses it with a
    /// link, a path that leaves it, more than 200 files (folders and __MACOSX not counted) or 10 MB unpacked; then `ditto` unpacks it, and the widget is
    /// its top (or its one top folder) holding widget.json, Finder's __MACOSX left out. importFolder then walks and copies
    /// it as any folder.
    @concurrent func unpack(_ archive: URL) async throws(Widget.Problems) -> Unpacked {
        func refuse(_ why: String) -> Widget.Problems { Widget.Problems(reasons: [why]) }
        let names: [String], listed: [String]
        do {
            names = try await ChildProcess.run("/usr/bin/zipinfo", ["-1", archive.path], timeout: .seconds(30), limit: 1_000_000)
                .split(separator: "\n").map(String.init)
            listed = try await ChildProcess.run("/usr/bin/zipinfo", ["-s", archive.path], timeout: .seconds(30), limit: 1_000_000)
                .split(separator: "\n").map(String.init)
        } catch { throw refuse("it does not read as a .zip") }
        // Two header lines ("Archive:", "Zip file size:"), a line an entry, starting with its kind and permissions
        // ("lrwxr-xr-x", "?rw-------" when the archive kept none), and the total last.
        guard listed.count >= 3, listed[0].hasPrefix("Archive:") else { throw refuse("it does not read as a .zip") }
        let kinds = Array(listed.dropFirst(2).dropLast())
        guard names.count == kinds.count else { throw refuse("its entries do not list one a line") }
        // Files, as the folder walk counts them: a folder's own entry is not one.
        let files = names.count { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") }
        guard files <= Widget.mostFiles else { throw refuse("it has \(files) files, more than the \(Widget.mostFiles) a widget may have") }
        for (name, line) in Swift.zip(names, kinds) {
            if line.hasPrefix("l") { throw refuse("\(name) is a symlink") }
            guard Widget.isSafeEntry(name.hasSuffix("/") ? String(name.dropLast()) : name) else { throw refuse("\(name) leaves the folder") }
        }
        // "4 files, 21 bytes uncompressed, …"
        let total = listed.last?.split(separator: ",").first { $0.contains("uncompressed") }.flatMap { Int($0.split(separator: " ").first ?? "") }
        guard let total, total <= Widget.widgetLimit else { throw refuse("it unpacks past the \(Widget.widgetLimit / 1_000_000) MB a widget may be") }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pilot-widget-zip-\(UUID().uuidString)", directoryHint: .isDirectory)
        let made = Unpacked(folder: scratch, scratch: scratch)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            _ = try await ChildProcess.run("/usr/bin/ditto", ["-x", "-k", archive.path, scratch.path], timeout: .seconds(30))
            let top = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
            let candidates = [scratch] + (top.count == 1 ? [scratch.appending(path: top[0], directoryHint: .isDirectory)] : [])
            guard let folder = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: Widget.manifestName).path) }) else {
                throw refuse("it holds no widget.json at its top or in its one folder")
            }
            // Finder's resource forks are not the widget's.
            try? FileManager.default.removeItem(at: folder.appending(path: "__MACOSX"))
            return Unpacked(folder: folder, scratch: scratch)
        } catch {
            made.remove()
            throw (error as? Widget.Problems) ?? refuse("it did not unpack")
        }
    }

    // MARK: Duplicate and uninstall

    /// Duplicate to edit (Q671): a copy in Widgets under a free id (`<id>-copy`, `-copy-2` …), read through the import's
    /// checks (no links, nothing leaving the folder, the limits), its widget.json given the new id. A ready widget's or a
    /// running one's copy is made here; a locked widget's copy stays locked, so a copy never skips Trust this widget.
    func duplicate(_ widget: Widget) async throws(Widget.Problems) -> Widget {
        let fm = FileManager.default
        let staging = widgets.appending(path: ".staging", directoryHint: .isDirectory)
        let source: URL, cleanup: URL?
        if Widget.isReserved(widget.id) {
            // A ready widget in code: its manifest is written out first. A desk widget copies from the app's folder.
            let made = staging.appending(path: "ready-\(UUID().uuidString)", directoryHint: .isDirectory)
            source = made.appending(path: widget.id, directoryHint: .isDirectory)
            cleanup = made
            do {
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
                try ReadyWidgets.manifest(widget.id).write(to: source.appending(path: Widget.manifestName))
            } catch { throw Widget.Problems(reasons: ["it did not copy: \(error.localizedDescription)"]) }
        } else {
            source = widget.folder; cleanup = nil
        }
        defer { if let cleanup { try? fm.removeItem(at: cleanup) } }
        let level: Widget.Trust = Widget.isReserved(widget.id) || ReadyWidgets.isDesk(widget) || trust(of: widget).runs ? .madeHere : .locked
        let staged = try await Widget.stage(source, into: staging)
        defer { staged.remove() }
        let id = try freeID(copying: widget.id)
        do {
            let manifest = staged.copy.appending(path: Widget.manifestName)
            guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: manifest)) else { throw CocoaError(.fileReadCorruptFile) }
            fields["id"] = .string(id)
            if case .string(let title)? = fields["title"] { fields["title"] = .string(String("\(title) copy".prefix(60))) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(JSONValue.object(fields)).write(to: manifest, options: .atomic)
            let target = widgets.appending(path: id, directoryHint: .isDirectory)
            try fm.moveItem(at: staged.copy, to: target)
            let copy = try Widget(folder: target)
            try setTrust(level, for: copy)
            return copy
        } catch let problems as Widget.Problems {
            throw problems
        } catch {
            throw Widget.Problems(reasons: ["it did not copy: \(error.localizedDescription)"])
        }
    }

    /// A free id for a copy of `id`: `<id>-copy`, `-copy-2` …, from a base cut short enough to stay a valid id, never
    /// one Pilot keeps for its ready widgets (`pilot` would make `pilot-copy`), as every id entering the Widgets folder
    /// must be: a ready widget's copy drops its `pilot-` or `desk-`.
    func freeID(copying id: String) throws(Widget.Problems) -> String {
        let kept = [Widget.reservedPrefix, ReadyWidgets.deskPrefix].first { id.hasPrefix($0) }
        var base = String((kept.map { String(id.dropFirst($0.count)) } ?? id).prefix(50))
        while base.hasSuffix("-") { base.removeLast() }
        if ReadyWidgets.isReady("\(base)-copy") || base.isEmpty { base = "my-\(base)".trimmingCharacters(in: ["-"]) }
        return try freeID(for: "\(base)-copy")
    }

    /// `base`, else `base-2`, `base-3` …: the first that is a valid id, not Pilot's, and free, with no folder in Widgets
    /// and no WidgetData an uninstalled widget's settings and passwords still wait under (a new widget would inherit them).
    func freeID(for base: String) throws(Widget.Problems) -> String {
        let free = (0..<100).lazy.map { $0 == 0 ? base : "\(base)-\($0 + 1)" }
            .first { Widget.isID($0) && !ReadyWidgets.isReady($0) && !FileManager.default.fileExists(atPath: self.widgets.appending(path: $0).path)
                && !FileManager.default.fileExists(atPath: self.data.appending(path: $0).path) }
        guard let free else { throw Widget.Problems(reasons: ["no free id from \(base)"]) }
        return free
    }

    /// Uninstall: the widget's folder to the Trash and its placements gone; its WidgetData (settings, trust record) and
    /// Keychain items stay, so installing it again picks its settings up (a new folder is locked: the record is bound to
    /// the old one). A ready widget is never uninstalled, only taken off the desktop.
    func uninstall(_ widget: Widget, trash: @Sendable (URL) throws -> Void) throws {
        guard !Widget.isReserved(widget.id), holds(widget.folder) else { throw CocoaError(.fileWriteNoPermission) }
        try trash(widget.folder)
        try save(placements().filter { $0.widget != widget.id })
    }

    /// What a widget with `id` is handed of what was saved under that id before (by a widget installed now, or one
    /// uninstalled, whose WidgetData and Keychain items stay): one line counting the saved settings and every password
    /// stored under the id's service (asked without reading them; unknown when the Keychain does not answer), or nil
    /// when nothing waits. An import takes
    /// its id from the outside widget.json, so the Install and Import questions and Trust this widget say this before it
    /// can run.
    func inherits(_ widget: Widget) -> String? {
        let saved: [String: JSONValue] = (try? Data(contentsOf: settingsFile(widget.id)))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        // Every password stored under the id, not only the fields this widget.json declares now: a trusted widget may add
        // a field later and would be handed what waits under it. A Keychain that does not answer is unknown, never none.
        let passwords = savedPasswords(widget.id)
        guard !saved.isEmpty || passwords != 0 else { return nil }
        // Counts, not names, so the line stays within the questions' budget (Widget.longestCommand).
        let counted = passwords.map { "\($0) password\($0 == 1 ? "" : "s")" } ?? "passwords unknown"
        return "Saved under \(widget.id) from before, which it can read once trusted: \(saved.count) setting\(saved.count == 1 ? "" : "s"), \(counted)"
    }

    /// The Keychain service a widget's passwords are saved under; written and counted by this one name.
    static func service(_ id: String) -> String { "dev.banozz.pilot.widget.\(id)" }

    /// How many passwords the Keychain holds under the widget's service, any account, nil when it does not answer (locked,
    /// or an unlock cancelled): one attributes-only query that reads no secret. A test hands in its own count, so nothing
    /// touches Sven's Keychain. It may wait on the Keychain, so callers run it off the main thread.
    var savedPasswords: @Sendable (String) -> Int? = { id in
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: WidgetStore.service(id),
                                      kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var found: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &found) {
        case errSecSuccess: return (found as? [Any])?.count ?? 0
        case errSecItemNotFound: return 0
        default: return nil
        }
    }

    // MARK: Settings

    func settingsFile(_ id: String) -> URL { folder(id).appending(path: "settings.json") }

    /// A password setting's Keychain item: service `dev.banozz.pilot.widget.<id>`, account the field's name.
    static func keychain(_ id: String, _ field: String) -> KeychainItem {
        KeychainItem(service: service(id), account: field, label: "Pilot widget \(id): \(field)")
    }

    /// Each setting's value: the placement's own (Edit widget), else the widget's as saved, else its default; passwords
    /// left out (they are only in the Keychain, one for every placement of the widget).
    func values(of widget: Widget, placement: Widget.Placement? = nil) -> [String: JSONValue] {
        let saved: [String: JSONValue] = (try? Data(contentsOf: settingsFile(widget.id)))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        let own = placement?.values ?? [:]
        var values: [String: JSONValue] = [:]
        for field in widget.settings where field.kind != .password {
            if let value = own[field.name] ?? saved[field.name] ?? field.initial { values[field.name] = value }
        }
        return values
    }

    /// Saves one setting: a password to the Keychain (nil removes it), anything else to settings.json.
    func set(_ value: JSONValue?, field name: String, of widget: Widget) throws {
        guard let field = widget.settings.first(where: { $0.name == name }) else { throw CocoaError(.keyValueValidation) }
        if field.kind == .password { return try Self.keychain(widget.id, name).write(value?.string) }
        var saved: [String: JSONValue] = (try? Data(contentsOf: settingsFile(widget.id)))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        saved[name] = value
        try FileManager.default.createDirectory(at: folder(widget.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(saved).write(to: settingsFile(widget.id), options: .atomic)
    }

    /// What a run is handed on stdin: the values with each password read from the Keychain. Reads the Keychain, so it
    /// runs off the main thread.
    @concurrent func runSettings(of widget: Widget, placement: Widget.Placement? = nil) async -> [String: JSONValue] {
        var values = values(of: widget, placement: placement)
        for field in widget.settings where passwords && field.kind == .password {
            if let password = Self.keychain(widget.id, field.name).read() { values[field.name] = .string(password) }
        }
        return values
    }

    // MARK: Placements

    func placements() -> [Widget.Placement] { readPlacements() ?? [] }

    /// The placements as the file holds them: none when there is no file yet, nil when it is there but does not read
    /// (half written, damaged), so nothing is dropped on a read that failed.
    func readPlacements() -> [Widget.Placement]? {
        guard FileManager.default.fileExists(atPath: placementsFile.path) else { return [] }
        return (try? Data(contentsOf: placementsFile)).flatMap { try? JSONDecoder().decode([Widget.Placement].self, from: $0) }
    }

    func save(_ placements: [Widget.Placement]) throws {
        try FileManager.default.createDirectory(at: placementsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(placements).write(to: placementsFile, options: .atomic)
    }

    // MARK: Import

    /// Imports a folder (Q680): walked without following a link, refused with any link, any path leaving it or the
    /// gallery's limits broken, copied file by file into a staging folder beside Widgets, read as a widget there, then
    /// moved in as `Widgets/<id>/`; a widget already there goes to the Trash first. It arrives locked, bound to its new
    /// folder, so a re-import locks a trusted widget again.
    func importFolder(_ source: URL, expecting id: String? = nil, trash: @Sendable (URL) throws -> Void) async throws(Widget.Problems) -> Widget {
        let staged = try await Widget.stage(source, into: widgets.appending(path: ".staging", directoryHint: .isDirectory))
        defer { staged.remove() }
        return try importStaged(staged, expecting: id, trash: trash)
    }

    /// Moves a copy already staged (one of Pilot's own, which nothing else writes) into Widgets as `<id>/`, locked. What an
    /// Allow named is what installs: a copy whose id is not the one asked about is refused, and so is a ready widget's id, here
    /// where a folder enters Widgets.
    func importStaged(_ staged: Widget.Staged, expecting id: String? = nil, trash: @Sendable (URL) throws -> Void) throws(Widget.Problems) -> Widget {
        if let id, staged.widget.id != id { throw Widget.Problems(reasons: ["it changed while it was asked about: its id is now \(staged.widget.id)"]) }
        guard !ReadyWidgets.isReady(staged.widget.id) else {
            throw Widget.Problems(reasons: ["\(staged.widget.id) is one of Pilot's ready widgets' ids"])
        }
        let target = widgets.appending(path: staged.widget.id, directoryHint: .isDirectory)
        do {
            if FileManager.default.fileExists(atPath: target.path) { try trash(target) }
            try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staged.copy, to: target)
            let widget = try Widget(folder: target)
            try setTrust(.locked, for: widget)
            return widget
        } catch {
            throw (error as? Widget.Problems) ?? Widget.Problems(reasons: ["it did not install: \(error.localizedDescription)"])
        }
    }
}
