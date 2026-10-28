import Foundation

/// `pilot ext test` (AI helper T10): the extension catalogue's `scripts/check.py` in Swift, word for word, so a folder
/// that passes here passes there; Pilot's own reason, as the Extensions page says it, comes first. Then one run of each
/// command through ExtensionRun, as the catalogue's `tests/harness.py` Sandbox runs it: Pilot's time limits and fixed
/// environment, HOME, TMPDIR and the data and cache folders in a temporary folder removed after.
public enum ExtensionCheck {
    /// check.py's limits: files, bytes a file, bytes in all (MiB, where the installer's ExtensionCatalogue.fileLimit is 2 MB).
    static let mostFiles = 200, fileLimit = 2 * 1024 * 1024, totalLimit = 10 * 1024 * 1024
    static let shebang = "#!/usr/bin/env python3"
    private static let modes: Set<String> = ["no-view", "list", "detail"], filters: Set<String> = ["pilot", "self"]
    private static let preferenceTypes: Set<String> = ["text", "password", "checkbox", "dropdown", "app", "file", "folder"]

    /// Why `folder` is not a catalogue-ready extension, in check.py's words; none when it is. A folder Pilot does not
    /// read as an extension gives its Extensions page reason first.
    static func problems(in folder: URL) -> [String] {
        var problems: [String] = []
        do { _ = try Extension(folder: folder) } catch {
            problems.append((error as? Extension.Problem)?.reason ?? error.localizedDescription)
        }
        for problem in catalogue(folder) where !problems.contains(problem) { problems.append(problem) }
        return problems
    }

    /// check.py's `check(folder)`.
    static func catalogue(_ folder: URL) -> [String] {
        let manifest: JSONValue
        do { manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: Extension.manifestName))) }
        catch CocoaError.fileReadNoSuchFile { return ["no extension.json"] }
        catch { return [Extension.Problem.unreadable("not JSON").reason] }
        typealias P = Extension.Problem
        guard case .object(let m) = manifest else { return ["extension.json is not an object"] }
        var problems: [String] = []
        if case .string(let id)? = m["id"], Extension.isName(id) {
            if folder.lastPathComponent != id { problems.append("folder name \(folder.lastPathComponent) is not its id \(id)") }
        } else {
            problems.append(P.badID(py(m["id"])).reason)
        }
        if !isText(m["title"]) { problems.append("title is missing") }
        if let runtime = m["runtime"], runtime != .string("process") { problems.append(P.unknownRuntime(py(runtime)).reason) }
        if !isEmoji(m["icon"]) { problems.append("icon must be one emoji") }
        if case .string(let v)? = m["version"], v.wholeMatch(of: /(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/) != nil {} else {
            problems.append("version must be x.y.z")
        }
        if !isText(m["description"]) { problems.append("description is missing") }
        if case .array(let examples)? = m["examples"], (1...Extension.mostExamples).contains(examples.count), examples.allSatisfy(isText) {} else {
            problems.append("examples must be a list of 1 to \(Extension.mostExamples) concrete uses")
        }
        if !isList(m["requires"] ?? .array([]), of: { if case .string(let s) = $0 { !s.isEmpty } else { false } }) {
            problems.append("requires must be a list of names")
        }
        if !permissionsFit(m["permissions"] ?? .object([:])) {
            problems.append("permissions must hold lists network, files, actions and a boolean clipboard")
        }
        commands(folder, m, &problems)
        preferences(m, &problems)
        surfaces(m, &problems)
        files(folder, &problems)
        return problems
    }

    private static func permissionsFit(_ value: JSONValue) -> Bool {
        guard case .object(let p) = value else { return false }
        return ["network", "files", "actions"].allSatisfy { isList(p[$0] ?? .array([])) { _ in true } } && isBool(p["clipboard"] ?? .bool(false))
    }

    private static func commands(_ folder: URL, _ m: [String: JSONValue], _ problems: inout [String]) {
        typealias P = Extension.Problem
        guard case .array(let commands)? = m["commands"], !commands.isEmpty else { return problems.append(P.noCommands.reason) }
        var names = Set<String>(), keywords = Set<String>()
        for command in commands {
            let c = if case .object(let o) = command { o } else { [String: JSONValue]() }
            guard case .string(let name)? = c["name"], case .string? = c["title"], case .string(let mode)? = c["mode"],
                  case .string(let run)? = c["run"] else {
                problems.append("a command needs name, title, mode and run as strings")
                continue
            }
            if !Extension.isName(name) { problems.append(P.badCommandName(name).reason) }
            if !names.insert(name).inserted { problems.append(P.duplicateCommand(name).reason) }
            if !modes.contains(mode) { problems.append(P.unknownMode(command: name, mode: mode).reason) }
            program(folder, run, name, &problems)
            let session = truthy(c["session"])
            let filter = c["filter"] ?? .string(session ? "self" : "pilot")
            if case .string(let f) = filter, filters.contains(f) {} else {
                problems.append(P.unknownFilter(command: name, filter: py(filter)).reason)
            }
            if session, !(mode == "list" && filter == .string("self")) { problems.append(P.sessionNeedsOwnList(command: name).reason) }
            if let hidden = c["hidden"], !isBool(hidden) { problems.append("command \(name): hidden must be true or false") }
            if let icon = c["icon"], !isEmoji(icon) { problems.append("command \(name): icon must be one emoji") }
            if let keyword = c["keyword"] {
                if case .string(let word) = keyword, Extension.isName(word) {
                    if mode != "no-view" { problems.append("command \(name): only a no-view command takes a keyword") }
                    else if keywords.contains(word) { problems.append("two commands with keyword \"\(word)\"") }
                } else {
                    problems.append("command \(name): keyword must be one word of lowercase letters, digits and hyphens")
                }
                let word = if case .string(let word) = keyword { word } else { "" }
                keywords.insert(word)
            }
        }
        if commands.allSatisfy({ if case .object(let c) = $0 { truthy(c["hidden"]) } else { false } }) {
            problems.append("every command is hidden: nothing shows in Hyper+Space")
        }
    }

    /// check.py's `check_program`: an executable regular file inside the folder, symlinks resolved; a Python one starts
    /// with the shebang that finds macOS's python3.
    private static func program(_ folder: URL, _ run: String, _ command: String, _ problems: inout [String]) {
        let root = folder.resolvingSymlinksInPath().path, url = folder.appending(path: run).resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard !run.hasPrefix("/"), url.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              !isFolder.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            return problems.append(Extension.Problem.missingProgram(command: command, run: run).reason)
        }
        guard url.pathExtension == "py" else { return }
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: 256) } ?? Data()
        // Bytes up to the first LF only, as check.py's readline: a CRLF line keeps its CR and fails, as it does there.
        let first = String(decoding: head.prefix { $0 != 0x0A }, as: UTF8.self)
        if first != shebang { problems.append("command \(command): \(run) must start \(shebang)") }
    }

    private static func preferences(_ m: [String: JSONValue], _ problems: inout [String]) {
        typealias P = Extension.Problem
        guard case .array(let preferences)? = m["preferences"] else { return }
        var names = Set<String>()
        for preference in preferences {
            let p = if case .object(let o) = preference { o } else { [String: JSONValue]() }
            guard case .string(let name)? = p["name"], case .string? = p["title"], case .string(let kind)? = p["type"] else {
                problems.append("a preference needs name, type and title as strings")
                continue
            }
            guard preferenceTypes.contains(kind) else {
                problems.append(P.unknownPreferenceType(preference: name, type: kind).reason)
                continue
            }
            // check.py's `p.get("data") or []`: anything else truthy is not a list of options.
            let options: [JSONValue] = if case .array(let a)? = p["data"] { a } else if truthy(p["data"]) { [.null] } else { [] }
            if kind == "dropdown" {
                guard !options.isEmpty else {
                    problems.append(P.noOptions(preference: name).reason)
                    continue
                }
                guard options.allSatisfy({ if case .object(let o) = $0, case .string? = o["title"], case .string? = o["value"] { true } else { false } }) else {
                    problems.append("preference \(name): each option needs title and value as strings")
                    continue
                }
            }
            if name.wholeMatch(of: /[A-Za-z0-9_-]+/) == nil { problems.append(P.badPreferenceName(name).reason) }
            if !names.insert(name).inserted { problems.append(P.duplicatePreference(name).reason) }
            if let given = p["default"], given != .null, !fits(kind, options, given) { problems.append(P.badDefault(preference: name).reason) }
            if let required = p["required"], !isBool(required) { problems.append("preference \(name): required must be true or false") }
        }
    }

    private static func fits(_ kind: String, _ options: [JSONValue], _ value: JSONValue) -> Bool {
        switch (kind, value) {
        case ("checkbox", .bool): true
        case ("checkbox", _): false
        case ("dropdown", .string(let s)): options.contains { if case .object(let o) = $0 { o["value"] == .string(s) } else { false } }
        case ("dropdown", _): false
        case (_, .string): true
        default: false
        }
    }

    private static func surfaces(_ m: [String: JSONValue], _ problems: inout [String]) {
        guard let surfaces = m["surfaces"], surfaces != .null else { return }
        guard case .object(let declared) = surfaces, Set(declared.keys).isSubset(of: ["page", "bar"]) else {
            return problems.append("surfaces must be an object with page and bar")
        }
        let names: Set<String> = if case .array(let commands)? = m["commands"] {
            Set(commands.compactMap { if case .object(let c) = $0, case .string(let n)? = c["name"] { n } else { nil } })
        } else { [] }
        for kind in declared.keys.sorted().reversed() {   // page, then bar, as the manifests write them
            guard case .object(let surface)? = declared[kind], case .string(let command)? = surface["command"], names.contains(command) else {
                problems.append("surfaces.\(kind) must name one of its commands")
                continue
            }
            let floor = kind == "page" ? 10.0 : 60.0
            if let every = surface["every"] {
                if case .number(let n) = every, n >= floor {} else { problems.append("surfaces.\(kind): every must be at least \(Int(floor)) seconds") }
            }
        }
    }

    private static func files(_ folder: URL, _ problems: inout [String]) {
        let found = listing(folder)
        if found.count > mostFiles { problems.append("\(found.count) files, more than \(mostFiles)") }
        for file in found where file.size > fileLimit { problems.append("\(file.path) is over \(fileLimit >> 20) MB") }
        if found.reduce(0, { $0 + $1.size }) > totalLimit { problems.append("over \(totalLimit >> 20) MB in all") }
    }

    /// One file an install copies: its path inside the folder, its size and whether it runs.
    /// Its device and inode as listed, so a read that finds another file there (a link swapped in since) is refused.
    struct Listed { let path: String, url: URL, size: Int, executable: Bool, device: dev_t, inode: ino_t }

    /// The catalogue's `build-index.py files()`: every regular file in `folder`, hidden ones, `__pycache__` and `.pyc`
    /// left out and symlinks never followed, by path.
    static func listing(_ folder: URL) -> [Listed] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .isExecutableKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        let root = folder.standardizedFileURL.path + "/"
        var found: [Listed] = []
        for case let url as URL in walk {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true, values.isSymbolicLink != true {
                if name.hasPrefix(".") || name == "__pycache__" { walk.skipDescendants() }
                continue
            }
            guard !name.hasPrefix("."), !name.hasSuffix(".pyc"), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            found.append(Listed(path: path, url: url, size: values.fileSize ?? 0, executable: values.isExecutable == true, device: info.st_dev, inode: info.st_ino))
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func isText(_ v: JSONValue?) -> Bool { if case .string(let s)? = v { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false } }
    private static func isBool(_ v: JSONValue) -> Bool { if case .bool = v { true } else { false } }
    private static func isEmoji(_ v: JSONValue?) -> Bool { if case .string(let s)? = v { ScriptCommand.isEmoji(s) } else { false } }
    private static func isList(_ v: JSONValue, of element: (JSONValue) -> Bool) -> Bool { if case .array(let a) = v { a.allSatisfy(element) } else { false } }

    /// Python's truth: what `if value:` takes as yes.
    private static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: false
        case .bool(let b)?: b
        case .number(let n)?: n != 0
        case .string(let s)?: !s.isEmpty
        case .array(let a)?: !a.isEmpty
        case .object(let o)?: !o.isEmpty
        }
    }

    /// A value as check.py's `%s` prints it.
    private static func py(_ v: JSONValue?) -> String {
        switch v {
        case nil, .null?: "None"
        case .bool(let b)?: b ? "True" : "False"
        case .number(let n)?: n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s)?: s
        case let other?: String(decoding: (try? JSONEncoder().encode(other)) ?? Data(), as: UTF8.self)
        }
    }
}

// MARK: One run of each command

extension ExtensionCheck {
    /// One command's run: what it ran as (its mode, or the surface that names it), whether Pilot read an answer, the first
    /// line it printed and, when Pilot read none or it did not run, why.
    public struct Run: Equatable, Sendable {
        public let command: String, ranAs: String, ok: Bool, first: String
        public let why: String?
    }

    /// Runs each of `ext`'s commands once, one after another as harness.py does: a surface's command with its surface
    /// named, a list or detail with an empty search, a no-view one with no input. Its inputs come from ExtensionStorage
    /// on a temporary data and cache folder, with no saved values and no Keychain, so a preference is its default. A run
    /// fails when it is too slow, exits with an error, says nothing Pilot reads as an answer, or prints a line outside the
    /// protocol (stricter than Pilot, which shows a no-view command's plain last line: harness.py's rule). A command
    /// answering with its own error message has answered. With a required preference that has no default nothing runs,
    /// as Pilot would run nothing, and every command fails: the extension does not work as installed.
    public static func runs(_ ext: Extension, environment pilot: [String: String] = ProcessInfo.processInfo.environment) async -> [Run] {
        let box = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        for folder in ["home", "tmp"] { try? FileManager.default.createDirectory(at: box.appending(path: folder), withIntermediateDirectories: true) }
        let environment = ["HOME": box.appending(path: "home").path, "TMPDIR": box.appending(path: "tmp").path + "/", "USER": pilot["USER"] ?? NSUserName()]
        let inputs: ExtensionRun.Inputs
        do { inputs = try ExtensionStorage(data: box.appending(path: "data"), cache: box.appending(path: "cache"), keychain: NoKeychain()).inputs(for: ext) }
        catch {
            let why = (error as? ExtensionStorage.Unset).map { "not run: \($0.message(in: ext))" } ?? "not run: \(error.localizedDescription)"
            return ext.commands.map { Run(command: $0.name, ranAs: kind(of: $0, in: ext).ranAs, ok: false, first: "", why: why) }
        }
        var runs: [Run] = []
        for command in ext.commands { runs.append(await run(command, in: ext, inputs: inputs, environment: environment)) }
        return runs
    }

    /// How Pilot runs `command`: the surface naming it, else its mode; its time limit and whether it gets a search.
    private static func kind(of command: Extension.Command, in ext: Extension) -> (surface: Extension.Surface.Kind?, ranAs: String, timeout: Duration, query: String?) {
        if let surface = [ext.bar, ext.page].compactMap(\.self).first(where: { $0.command.name == command.name })?.kind {
            return (surface, surface.rawValue, surface == .bar ? ExtensionRun.barTimeout : ExtensionRun.pageTimeout, nil)
        }
        return command.mode == .noView ? (nil, command.mode.rawValue, ExtensionRun.noViewTimeout, nil)
            : (nil, command.mode.rawValue, ExtensionRun.listTimeout, "")
    }

    private static func run(_ command: Extension.Command, in ext: Extension, inputs: ExtensionRun.Inputs, environment: [String: String]) async -> Run {
        let (surface, ranAs, timeout, query) = kind(of: command, in: ext)
        func run(ok: Bool, _ first: String = "", why: String? = nil) -> Run { Run(command: command.name, ranAs: ranAs, ok: ok, first: first, why: why) }
        let output: String
        do { output = try await ExtensionRun.output(command, query: query, surface: surface, inputs: inputs, environment: environment, timeout: timeout) }
        catch { return run(ok: false, why: ExtensionRun.reason(error, timeout: timeout)) }
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let first = String((lines.first ?? "").prefix(200))
        let decoder = JSONDecoder()
        let types = lines.map { line -> String? in
            guard case .object(let o)? = try? decoder.decode(JSONValue.self, from: Data(line.utf8)), case .string(let type)? = o["type"] else { return nil }
            return type
        }
        if let plain = types.firstIndex(of: nil) { return run(ok: false, first, why: "printed a line outside the protocol: \(lines[plain].prefix(120))") }
        // Its own error message is an answer: Pilot shows it as the command meant.
        if types.contains("error") { return run(ok: true, first) }
        let why: String? = switch (surface, command.mode) {
        case (let kind?, _): if case .error(let reason) = ExtensionRun.surfaceAnswer(output, kind: kind) { reason } else { nil }
        case (nil, .noView): if case .error(let reason) = ExtensionRun.outcome(of: output) { reason } else { nil }
        case (nil, _): if case .error(let reason) = ExtensionRun.answer(output) { reason } else { nil }
        }
        return run(ok: why == nil, first, why: why)
    }

    /// `ext test` reads no Keychain: a password preference is unset, as on a Mac where it was never typed.
    private struct NoKeychain: ExtensionKeychain {
        func password(extension id: String, preference name: String) -> String? { nil }
        func setPassword(_ password: String?, extension id: String, preference name: String) throws {}
        func hasPassword(extension id: String, preference name: String) -> Bool { false }
    }
}

// MARK: Templates and a local install

/// `pilot ext new`: a working extension made from one of Pilot's templates (`ext-template/<mode>` in its Resources),
/// Python 3 stdlib only, one `main.py`, passing ExtensionCheck as made.
public enum ExtensionTemplate: String, CaseIterable, Sendable {
    case list, noView = "no-view", detail, bar

    /// The templates' own id and title, replaced in the copy's manifest.
    static let id = "example", title = "Example"

    /// Copies the template into `parent/<id>`, its manifest naming `id` and `title` ("dash-board" titles "Dash board"),
    /// and returns the folder. Throws when `id` is not a name, the template is missing, or `parent/<id>` already exists.
    public func make(id: String, title: String? = nil, templates: URL, in parent: URL) throws -> URL {
        let fm = FileManager.default
        guard Extension.isName(id) else { throw Extension.Problem.badID(id) }
        let source = templates.appending(path: rawValue), target = parent.appending(path: id)
        guard fm.fileExists(atPath: source.appending(path: Extension.manifestName).path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        guard !fm.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path]) }
        try fm.copyItem(at: source, to: target)
        do {
            let manifest = target.appending(path: Extension.manifestName)
            let quoted = String(decoding: try JSONEncoder().encode(title ?? ScriptCommand.title(file: id)), as: UTF8.self).dropFirst().dropLast()
            let text = try String(contentsOf: manifest, encoding: .utf8)
                .replacing("\"id\": \"\(Self.id)\"", with: "\"id\": \"\(id)\"")
                .replacing("\"title\": \"\(Self.title)", with: "\"title\": \"\(quoted)")
            try text.write(to: manifest, atomically: true, encoding: .utf8)
            // A copy that lost its modes (a patch, a zip) still runs.
            for file in ExtensionCheck.listing(target) where file.path.hasSuffix(".py") {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.url.path)
            }
            guard try Extension(folder: target).id == id else { throw Extension.Problem.badID(id) }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return target
    }
}

extension ExtensionCheck {
    /// An extension read once into a temporary copy, for `ext install`: the check, the question and the install all read
    /// these bytes, never the source folder again, so what is asked about is what installs.
    public struct Staged: Sendable {
        /// The folder it was read from, and the copy, named as that folder, in a temporary folder of its own.
        public let source: URL, copy: URL
        /// Why the copy is not a catalogue-ready extension (ExtensionCheck's words); empty when it is.
        public let problems: [String]
        /// The copy as Pilot reads it, and as a catalogue entry, every file with its sha256; nil when `problems` holds any.
        public let ext: Extension?, entry: ExtensionCatalogue.Entry?

        /// Removes the copy and its temporary folder.
        public func remove() { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    }

    /// Reads `folder` into a temporary copy, off the main actor: each file once, with its sha256, checked as it is read
    /// against the catalogue index's own rules for an entry (ExtensionCatalogue's `entry(_ line:)`): each path safe inside
    /// the folder, a manifest, at most `mostFiles` files of `fileLimit` bytes each and `extensionLimit` in all. Symlinks
    /// are never followed or copied. Throws a Problem, leaving nothing behind, when a rule fails or a file does not read.
    @concurrent public static func stage(_ folder: URL) async throws -> Staged {
        typealias C = ExtensionCatalogue
        let listed = listing(folder)
        if let unsafe = listed.first(where: { !C.isSafe($0.path) }) { throw C.Problem.failed("file path \"\(unsafe.path)\" leaves its folder") }
        guard listed.contains(where: { $0.path == Extension.manifestName }) else { throw C.Problem.failed("it has no \(Extension.manifestName)") }
        guard listed.count <= C.mostFiles else { throw C.Problem.failed("it has \(listed.count) files, more than the \(C.mostFiles) an extension may have") }
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appending(path: "pilot-ext-install-\(UUID().uuidString)").appending(path: folder.lastPathComponent)
        do {
            var total = 0
            let files = try listed.map { file in
                // Sizes as read, not as listed: a file that grew since is held to the limits too.
                let data = try read(file, limit: C.fileLimit)
                total += data.count
                guard total <= C.extensionLimit else { throw C.Problem.failed("it is larger than the \(C.extensionLimit / 1_000_000) MB an extension may be") }
                let url = copy.appending(path: file.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
                return C.File(path: file.path, sha256: C.sha256(data), size: data.count, executable: file.executable)
            }
            let problems = problems(in: copy)
            guard problems.isEmpty else { return Staged(source: folder, copy: copy, problems: problems, ext: nil, entry: nil) }
            let ext = try Extension(folder: copy)
            let entry = C.Entry(id: ext.id, title: ext.title, icon: ext.icon, version: ext.version ?? "", description: ext.description,
                                commands: ext.commands.map { .init(name: $0.name, title: $0.title, mode: $0.mode) },
                                permissions: ext.permissions, files: files)
            return Staged(source: folder, copy: copy, problems: [], ext: ext, entry: entry)
        } catch {
            try? fm.removeItem(at: copy.deletingLastPathComponent())
            throw error
        }
    }

    /// `file`'s bytes, opened without following a link and refused unless it is still the regular file listing() saw
    /// (Moody on W15): a file or a folder above it swapped for a link since is another inode, so nothing it leads to is read.
    /// More than `limit` bytes is tooBig.
    static func read(_ file: Listed, limit: Int) throws -> Data {
        typealias C = ExtensionCatalogue
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw C.Problem.failed("\(file.path) changed while it was read") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_dev == file.device, info.st_ino == file.inode else {
            throw C.Problem.failed("\(file.path) changed while it was read")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw C.Problem.tooBig(path: file.path, limit: limit) }
        return data
    }

    /// Installs a staged copy, off the main actor: ExtensionInstaller's own checks, rename and Trash, each file read from
    /// the copy and checked against its sha256. Nil entry (a copy that failed the check) installs nothing.
    @concurrent public static func install(_ staged: Staged, extensions: URL, trash: @escaping @Sendable (URL) throws -> Void) async throws -> Extension {
        guard let entry = staged.entry else { throw ExtensionCatalogue.Problem.failed(staged.problems.joined(separator: "; ")) }
        let source = ExtensionCatalogue.Source { path, limit in
            let prefix = "extensions/\(entry.id)/"
            guard path.hasPrefix(prefix) else { throw ExtensionCatalogue.Problem.failed("\(path) is not in \(staged.copy.path)") }
            let file = String(path.dropFirst(prefix.count))
            let data = try Data(contentsOf: staged.copy.appending(path: file))
            // The installer asks for at most the size `entry` listed: more is a file changed since.
            guard data.count <= limit else { throw ExtensionCatalogue.Problem.mismatch(path: file) }
            return data
        }
        return try await ExtensionInstaller(extensions: extensions, source: source, trash: trash).install(entry)
    }

    /// The folders an install of `id` into `extensions` sends to the Trash, as ExtensionInstaller finds them; throws its
    /// folderTaken when a folder named `id` holds something else.
    public static func replaced(_ id: String, in extensions: URL) throws -> [URL] {
        try ExtensionInstaller(extensions: extensions).replaced(id)
    }
}
