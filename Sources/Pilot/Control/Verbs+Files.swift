import Foundation
import PilotCore

/// What `pilot files` reaches (CLI W13): the menu's file index and its state. The tests hand in their own, so the helper
/// never starts and nothing of Sven's home is read.
@MainActor
final class ControlFiles {
    /// The index's answer, best first, or nil without Full Disk Access; the helper may drop it for a newer search.
    var search: @MainActor (FileSearch.Ask, @escaping ([FileSearch.Hit]?) -> Void) -> Void = { FileIndex.shared.search($0, reply: $1) }
    var running: @MainActor () -> Bool = { FileIndex.shared.isRunning }
    /// Lists a folder, so it runs off the main thread.
    var fullDiskAccess: @Sendable () async -> Bool = { await Task.detached { FileIndex.hasFullDiskAccess() }.value }
    var home = NSHomeDirectory()
    /// How long a search may wait: the first start reads the saved index (about 2 s) or walks home (about 5 s).
    var deadline: Duration = .seconds(30)
    /// Text in images and its reader's counts; reached on the first request, so a test sets its own before then.
    lazy var imageText = ImageTextSettings.shared
    lazy var imageTextCounts: () -> (read: Int, waiting: Int) = { (ImageTextReader.shared.read, ImageTextReader.shared.waiting) }
    /// Pilot Files' writer and its undo journal, the one the window's Cmd+Z takes from too.
    var ops = FileOps.shared
    /// Every writing subcommand asks here first.
    var gate = AllowPrompt.gate
}

extension SettingsSchema {
    /// Files › File search › Text in images' switch. Off clears the text index, as on the page.
    func registerImageText(_ text: ImageTextSettings) {
        register([
            .bool("files.imageText", "Files finds images by the words in them", page: "files", standard: true,
                  read: { text.enabled }, write: { text.enabled = $0 }),
        ])
    }
}

extension ControlVerbs {
    /// Tools › Files: the file index and Convert.
    func registerFiles(_ files: ControlFiles, convert: ControlConvert) {
        registerFileSearch(files)
        registerImageTextFolders(files)
        registerConvert(convert)
        registerFolderDesigns()
    }

    /// Files › Folders (P43), read-only: the designs, and the folders Pilot dressed with the look each has now.
    private func registerFolderDesigns() {
        let looks = FolderDesigns.looks
        register(ControlCollection("folder-designs", help: "The folder designs Pilot draws (Files › Folders), then Your designs (yours:…), then own "
                                   + "for a picture of yours; read-only.", list: {
            .array((FolderDesign.all + YourFolderDesigns.standard.list().map(\.design) + [.own]).map { .object(["design": .string($0.id), "title": .string($0.title)]) })
        }))
        register(ControlCollection("dressed-folders", help: "Folders Pilot dressed (Files › Folders), each with the look it has now: pilot, "
                                   + "custom when its icon was replaced since, plain when it is gone; read-only.", list: {
            let yours = YourFolderDesigns.standard.list().map(\.design)
            return .array(looks.records().map { record in
                let look = switch looks.look(of: URL(filePath: record.path, directoryHint: .isDirectory)) {
                case .pilot(let design): design == record.design ? "pilot" : "pilot \(FolderDesign.wearing(design, yours: yours))"
                case .custom: "custom"
                case .plain: "plain"
                }
                return .object(["folder": .string(record.path), "design": .string(record.design),
                                "title": .string(FolderDesign.wearing(record.design, yours: yours)), "look": .string(look)])
            })
        }))
    }

    /// Text in images' folders, as the page's chips: add one in your home, remove one, remove --reset for the shipped four.
    private func registerImageTextFolders(_ files: ControlFiles) {
        let rows: @Sendable @MainActor () -> JSONValue = { .array(files.imageText.folders.map { .object(["folder": .string($0)]) }) }
        register(ControlCollection("image-text-folders", help: "Folders whose images Files reads the words of (Text in images); "
                                   + "remove --reset puts back Desktop, Downloads, Documents and Pictures.",
                                   fields: [.init("folder", help: "a folder in your home, like ~/Pictures")],
                                   rowKey: "folder", list: { rows() },
                                   add: { args throws(ControlError) in
            let typed = args.value("folder")!
            if let refusal = files.imageText.add(typed) { throw ControlError(.badValue, "--folder: \(refusal)") }
            return .object(["folder": .string(files.imageText.folders.last ?? typed)])
        }, remove: { args throws(ControlError) in
            if let refusal = ControlVerb.unknownFlag(args.flags, known: ["reset"], in: "pilot remove image-text-folders") { throw refusal }
            if args.flags.contains("reset") {
                files.imageText.reset()
                return rows()
            }
            let word = try args.word(0, "folder"), folders = files.imageText.folders
            guard let entry = folders.first(where: { $0 == word || $0 == FileExclusions.entry(word, home: files.home) }) else {
                throw ControlError(.badValue, "no folder \(word); there are \(folders.isEmpty ? "none" : folders.joined(separator: ", "))")
            }
            files.imageText.remove(entry)
            return .object(["folder": .string(entry)])
        }))
    }

    /// `files`: the menu's Files view, through Pilot's file index (Cardinal's engine, ~/Library and the never-index list
    /// left out). A search starts the index as the menu's does; it stops again after 10 min without one.
    private func registerFileSearch(_ files: ControlFiles) {
        let filters = ["kind": "folders, documents, images, video, audio, code, archives, apps, or an extension (pdf)",
                       "in": "desktop, documents, downloads, icloud, or a folder (~/code)", "when": "today, week, month",
                       "from": "a word in where the file came from: the site (github.com), else the app that saved it (whatsapp)"]
        register(ControlVerb("files", help: "Finds files by name as the menu's Files view does, best first (at most 20); with no words, the index's state. "
                             + "copy, move, rename, trash and new-folder change files after Allow, and undo puts back the last of them (Pilot Files); "
                             + "each is refused, changing nothing, when one item's undo would be too long to ask; "
                             + "open shows pictures in Pilot's image viewer.",
                             usage: "pilot files <words…> [--kind <kind>] [--in <place>] [--when <when>] [--from <source>] [--hidden] | files"
                                 + " | files copy|move <item…> <folder> [--keep-both|--replace] | files rename <item> <name> | files trash <item…>"
                                 + " | files new-folder <folder> [<name>] | files undo | files open <image…>   (files -- <words…> searches for those words)",
                             flags: [.init("kind", help: filters["kind"]!), .init("in", help: filters["in"]!), .init("when", help: filters["when"]!),
                                     .init("from", help: filters["from"]!),
                                     .init("hidden", help: "dot names and bundle insides too, as Show hidden and system files", takesValue: false),
                                     .init("keep-both", help: "copy, move: a name already in the folder gets a number added", takesValue: false),
                                     .init("replace", help: "copy, move: the item already in the folder goes to the Trash first (undo brings it back)",
                                           takesValue: false)],
                             schema: { .object(["filters": .object(filters.mapValues(JSONValue.string)),
                                                "operations": .object(Self.fileOperations.mapValues(JSONValue.string))]) },
                             index: { .object(["filters": .array(filters.keys.sorted().map(JSONValue.string)),
                                               "operations": .array(Self.fileOperations.keys.sorted().map(JSONValue.string))]) },
                             detail: { word in
                                 filters[word].map { "--\(word) (or \(word):<value> among the words): \($0)" }
                                     ?? Self.fileOperations[word].map { "files \(word): \($0)" }
                                     ?? (word == "open" ? "files open: \(Self.openHelp)" : nil)
                             }) { call throws(ControlError) in
            // Open shows a picture and writes nothing, so it never asks Allow (ADR 0013).
            if call.words.first == "open" { return try await Self.openImage(call) }
            // An operation is the first word as typed; after -- it is a search word.
            if let first = call.words.first, Self.fileOperations[first] != nil {
                return try await Self.operate(first, call, files)
            }
            let args = call.arguments()
            if let refusal = ControlVerb.unknownFlag(args.flags, known: ["kind", "in", "when", "from", "hidden"], in: "pilot files <words…>") {
                throw refusal
            }
            guard !args.positional.isEmpty else { return await Self.indexState(files) }
            // The flags go through the words' own prefixes, as typing kind:pdf in the menu does.
            var typed = FileFilters.typed(args.positional.joined(separator: " "), home: files.home)
            for (flag, facet) in [("kind", FileFilters.Facet.kind), ("in", .place), ("when", .when)] {
                guard let value = try args.has(flag) ? args.required(flag) : nil else { continue }
                let given = FileFilters.typed("\(flag):\(value)", home: files.home).filters
                guard given.isSet(facet) else { throw ControlError(.badValue, "no --\(flag) \(value); \(filters[flag]!)") }
                typed.filters = given.merged(with: typed.filters)
            }
            typed.filters.hidden = args.has("hidden")
            // A typed from: wins over --from, as the other filters' words win over their flags.
            var (words, from) = FileSearch.typedFrom(typed.text)
            if from == nil, args.has("from") { from = try args.required("from") }
            guard let text = FileSearch.query(for: words) else {
                throw ControlError(.badValue, "a search is at least \(MenuNavigator.minimumQuery) characters, as in the menu")
            }
            let ask = FileSearch.Ask(text: text, filters: typed.filters, from: from)
            guard let found = try await Self.search(ask, files) else {
                throw ControlError(.notReady, "Pilot has no Full Disk Access, so the index is not running; pilot run system.openFullDiskAccess opens its switch")
            }
            return .object(["files": .array(found.map { file in
                .object(["path": .string(file.path), "name": .string(URL(fileURLWithPath: file.path).lastPathComponent),
                         "edited": file.edited.map { .string($0.ISO8601Format()) } ?? .null, "from": file.from.map(JSONValue.string) ?? .null])
            })])
        })
    }

    static let openHelp = "pilot files open <image…>: shows PNG, JPEG, HEIC, GIF, WebP, TIFF or BMP pictures in Pilot's image viewer, "
        + "as a Finder open with Pilot does: one window, stepping through the pictures given when there are several, else the "
        + "folder's; answers the window count, the pictures it steps through and the size the first was read at; anything else is refused"

    /// `pilot files open <image…>`: the pictures in one image viewer (Q158, Q161), listed and the first read before the
    /// answer, which says how many viewers are open, the pictures it steps through, its size and the size it was read at
    /// (the screen's, never the whole file).
    private static func openImage(_ call: ControlCall) async throws(ControlError) -> JSONValue {
        let words = Array(call.words.dropFirst())
        guard !words.isEmpty else { throw ControlError(.badRequest, "usage: pilot files open <image…>") }
        let cwd = call.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var urls: [URL] = []
        for word in words {
            let url = URL(fileURLWithPath: (word as NSString).expandingTildeInPath, relativeTo: cwd).absoluteURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw ControlError(.badValue, "no file at \(url.path)") }
            guard ViewerImages.viewable(url) else {
                throw ControlError(.badValue, "\(url.lastPathComponent) is not a picture the viewer opens (PNG, JPEG, HEIC, GIF, WebP, TIFF or BMP)")
            }
            urls.append(url)
        }
        guard let model = ImageViewer.show(urls) else { throw ControlError(.badValue, "Pilot cannot read \(urls[0].lastPathComponent)") }
        await model.settled()
        if let problem = model.problem { throw ControlError(.badValue, problem) }
        guard let image = model.image else { throw ControlError(.timeout, "\(model.file.lastPathComponent) was still being read") }
        return .object(["windows": .number(Double(ImageViewer.openCount)), "opened": .string(model.file.path),
                        "index": .number(Double(model.index + 1)), "of": .number(Double(model.files.count)),
                        "steps": .array(model.files.map { .string($0.lastPathComponent) }),
                        "pixels": .string("\(Int(model.pixels.width))x\(Int(model.pixels.height))"),
                        "shown": .string("\(image.width)x\(image.height)"), "screenLongest": .number(Double(model.longest)),
                        "frames": .number(Double(model.frames)), "zoom": .number((model.zoom * 100).rounded() / 100)])
    }

    /// The subcommands that write (Pilot Files' FileOps, spec pilot-1.1 T6), each with what it does.
    static let fileOperations: [String: String] = [
        "copy": "pilot files copy <item…> <folder>: copies each item into the folder; a name already there is refused, "
            + "and --keep-both or --replace answers it; refused, changing nothing, onto a volume with no Trash (its undo could never run)",
        "move": "pilot files move <item…> <folder>: moves each item into the folder, a name already there as copy; across volumes "
            + "it copies, checks the copy matches, then sends the original to the Trash, and is refused onto a volume with no Trash",
        "rename": "pilot files rename <item> <name>: renames it in its folder; a name already taken is refused",
        "trash": "pilot files trash <item…>: sends each item to the Trash; refused, changing nothing, when an item's undo would be "
            + "too long to ask (a very deep path or long name), since Pilot runs only what it can undo",
        "new-folder": "pilot files new-folder <folder> [<name>]: makes a folder in it, untitled folder when no name is given",
        "undo": "pilot files undo: puts back the last copy, move, rename, trash or new folder, newest first; when its Allow "
            + "would be too long to show whole, it puts back the newest steps that fit and the next undo does the rest. A step "
            + "that can't run for now (its drive not mounted, a folder read-only) stays to try again; one whose item is gone or "
            + "whose place is taken is dropped, and older undos go on",
    ]

    /// One writing subcommand: its words planned as FileOps plans them (paths resolved, items pinned), then Allow on that
    /// exact plan, then FileOps runs it only while it still matches. The answer says where each item is now, where any
    /// trashed one went, and what the next undo puts back.
    private static func operate(_ name: String, _ call: ControlCall, _ files: ControlFiles) async throws(ControlError) -> JSONValue {
        let args = ControlArguments(Array(call.words.dropFirst()), switches: call.switches)
        let place = "pilot files \(name)", words = args.positional
        let clashing = name == "copy" || name == "move"
        if let refusal = ControlVerb.unknownFlag(args.flags, known: clashing ? ["keep-both", "replace"] : [], in: place) { throw refusal }
        if args.has("keep-both"), args.has("replace") { throw ControlError(.badRequest, "\(place) takes --keep-both or --replace, not both") }
        let clash: FileOps.Clash = args.has("keep-both") ? .keepBoth : args.has("replace") ? .replace : .ask
        let cwd = call.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let url = { (path: String) in
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).absoluteURL.standardizedFileURL
        }
        let usage = ControlError(.badRequest, "usage: \(fileOperations[name]!.prefix { $0 != ":" })")
        let request: FileOps.Request
        switch name {
        case "copy", "move":
            guard words.count >= 2 else { throw usage }
            let sources = words.dropLast().map(url), folder = url(words.last!)
            request = name == "move" ? .move(sources, into: folder, clash) : .copy(sources, into: folder, clash)
        case "rename":
            guard words.count == 2 else { throw usage }
            request = .rename(url(words[0]), to: words[1])
        case "trash":
            guard !words.isEmpty else { throw usage }
            request = .trash(words.map(url))
        case "new-folder":
            guard (1...2).contains(words.count) else { throw usage }
            request = .newFolder(in: url(words[0]), named: words.count == 2 ? words[1] : nil)
        default:
            guard words.isEmpty else { throw usage }
            request = .undo
        }
        let ops = files.ops
        let plan = try await faulted { try await ops.plan(request) }
        let done = try await files.gate.allow(plan.ask, peer: call.peer) { () throws(ControlError) in
            try await faulted { try await ops.perform(plan) }
        }
        let shown = { (url: URL) in JSONValue.string(url.path(percentEncoded: false)) }
        return .object(["done": .string(done.title), "items": .array(done.items.map(shown)), "trashed": .array(done.trashed.map(shown)),
                        "nextUndo": await ops.nextUndo.map(JSONValue.string) ?? .null])
    }

    /// FileOps' refusal as the command's error: a clash is taken, a plan changed while Allow was up denied (as the gate's
    /// own re-check words it), a cause for now (a drive not mounted, a read-only folder) not ready, the rest a bad value;
    /// its words as they are.
    private static func faulted<T>(_ body: () async throws -> T) async throws(ControlError) -> T {
        do { return try await body() } catch let failure as FileOps.Failure {
            let code: ControlError.Code = switch failure.kind {
            case .clash: .taken
            case .changed: .denied
            case .unavailable: .notReady
            default: .badValue
            }
            throw ControlError(code, failure.message)
        } catch { throw ControlError(.badValue, error.localizedDescription) }
    }

    private static func indexState(_ files: ControlFiles) async -> JSONValue {
        let counts = files.imageTextCounts()
        return .object(["fullDiskAccess": .bool(await files.fullDiskAccess()), "running": .bool(files.running()),
                        "idleStop": .number(FileIndex.idleStop),
                        "imageText": .object(["on": .bool(files.imageText.enabled), "read": .number(Double(counts.read)),
                                              "waiting": .number(Double(counts.waiting))]),
                        "note": .string("a search starts the index; it stops after \(Int(FileIndex.idleStop / 60)) min without one")])
    }

    /// The index's answer, or timeout when none came by the deadline: the menu's own search took the helper's answer.
    private static func search(_ ask: FileSearch.Ask, _ files: ControlFiles) async throws(ControlError) -> [FileSearch.Hit]? {
        let answer = Once<[FileSearch.Hit]??>()
        let found = await withCheckedContinuation { continuation in
            answer.continuation = continuation
            answer.clock = Task { [deadline = files.deadline] in
                try? await Task.sleep(for: deadline)
                answer.give(.none)
            }
            files.search(ask) { answer.give(.some($0)) }
        }
        guard let found else { throw ControlError(.timeout, "the index did not answer in \(files.deadline.components.seconds) s (a menu search may have taken its answer); ask again") }
        return found
    }

    /// The first of the reply and the clock to answer; the later one is dropped.
    @MainActor private final class Once<T: Sendable> {
        var continuation: CheckedContinuation<T, Never>?
        var clock: Task<Void, Never>?

        func give(_ value: T) {
            guard let continuation else { return }
            self.continuation = nil
            clock?.cancel()
            continuation.resume(returning: value)
        }
    }
}
