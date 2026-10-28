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
        register(ControlVerb("files", help: "Finds files by name as the menu's Files view does, best first (at most 20); with no words, the index's state.",
                             usage: "pilot files <words…> [--kind <kind>] [--in <place>] [--when <when>] [--from <source>] [--hidden] | files",
                             flags: [.init("kind", help: filters["kind"]!), .init("in", help: filters["in"]!), .init("when", help: filters["when"]!),
                                     .init("from", help: filters["from"]!),
                                     .init("hidden", help: "dot names and bundle insides too, as Show hidden and system files", takesValue: false)],
                             schema: { .object(["filters": .object(filters.mapValues(JSONValue.string))]) },
                             index: { .object(["filters": .array(filters.keys.sorted().map(JSONValue.string))]) },
                             detail: { word in
                                 filters[word].map { "--\(word) (or \(word):<value> among the words): \($0)" }
                             }) { call throws(ControlError) in
            let args = call.arguments()
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
