import AppKit
import Foundation

/// Pilot Files' one writer (spec pilot-1.1 T6, T55): copy, move, rename, Trash, new folder and new file, each kept in an undo journal that
/// `pilot files undo` and the window's Cmd+Z both take from (`shared`). A request is planned first, changing nothing: every
/// path resolved (symlinked folders included) and every item pinned by device and inode, so the Allow shows the exact plan.
/// `perform` plans again and runs only a plan that still matches, checking each item's identity again before it touches
/// it. FileOps never permanently deletes: a name clash is refused unless the caller keeps both or sends the one there to the Trash, an
/// undo of a copy or a new folder sends it to the Trash, a move across volumes copies, checks the copy, then sends the
/// source to the Trash, and an undo never moves across volumes. Anything Pilot runs can be undone: a plan is refused when
/// the undo of any one of its steps could not be asked on its own or would need a Trash its volume lacks, and a Trash whose
/// real place makes its undo too long to ask is put back and refused. One operation runs at a time; none on the main thread.
public actor FileOps {
    /// Sends one item to the Trash and answers where it went, so an undo can bring it back.
    public typealias Trash = @Sendable (URL) async throws -> URL
    /// The Trash folder for items in a folder, for the length of an undo's question, or nil when its volume has no Trash
    /// Pilot can use (so an undo that sends an item there could never run); nothing is made.
    public typealias TrashFolder = @Sendable (URL) -> URL?

    public static let shared = FileOps()
    /// Characters an undo's question allows on top of a trashed item's name for the name the Trash may give it when one
    /// like it is already there (a time such as " 10.42.31 PM", a number, or both).
    static let trashSuffix = 32
    /// The most operations an undo reaches back; older ones drop off.
    public static let depth = 50

    /// What a name already taken in the target folder does.
    public enum Clash: Sendable, Equatable { case ask, keepBoth, replace }

    /// What the caller asks for, as typed; `plan` resolves it.
    public enum Request: Sendable, Equatable {
        case copy([URL], into: URL, Clash)
        case move([URL], into: URL, Clash)
        case rename(URL, to: String)
        case trash([URL])
        case newFolder(in: URL, named: String?)
        /// A new file in the folder named `named`, or "named 2" and on when that is taken: empty, or a copy of the bytes of
        /// `template`, a plain file in Pilot's Templates folder (`isTemplate`). Either way a new plain file, never a link,
        /// and nothing else is touched.
        case newFile(in: URL, named: String, template: URL?)
        /// The last operation in the journal.
        case undo
    }

    /// A refusal or a failure, in words the pilot command prints. Nothing was changed unless `message` says what was.
    public struct Failure: Error, Sendable, Equatable {
        /// `gone`: an undo's item is no longer the one Pilot left, so that step can never run. `changed`: the plan is not
        /// the one Allow showed, so nothing ran. `unavailable`: a cause that can pass (a drive not mounted, a folder that
        /// can't be written to), so an undo's step it stops stays to be tried again.
        public enum Kind: Sendable { case clash, missing, refused, gone, changed, failed, unavailable }
        public let kind: Kind, message: String
        init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    }

    /// What one operation or undo did: its title, where each item is now, and where each trashed one went.
    public struct Done: Sendable, Equatable {
        public let title: String
        public let items: [URL]
        public let trashed: [URL]
        /// Successful moves, including rename and undo: folder shortcuts follow the folder, not its old spelling.
        public var moved: [URL: URL] = [:]
    }

    /// Which item it is, whatever path reaches it: its device and inode (lstat's, so a link is itself).
    public struct Identity: Hashable, Sendable { let device: UInt64, inode: UInt64 }

    /// A moved folder and its descendants under their new path, including paths reached through a parent alias.
    public static func relocated(_ url: URL, by moves: [URL: URL]) -> URL {
        guard !moves.isEmpty else { return url }
        let origins = moves.keys.sorted { $0.path.count > $1.path.count }
        var parent = url.path, suffix = ""
        // Foundation leaves a missing path unresolved after rename. Walk up until its existing alias resolves. The walk is
        // on the path string and stops at "/": a URL from a listing (NSURL-backed) steps from / to /.. and on forever,
        // which hung the Files window after a paste (build 2379).
        while true {
            let path = URL(filePath: parent).resolvingSymlinksInPath().path + suffix
            if let from = origins.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }), let to = moves[from] {
                return URL(filePath: to.path + path.dropFirst(from.path.count), directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
            }
            if parent == "/" || parent.isEmpty { return url }
            suffix = "/" + (parent as NSString).lastPathComponent + suffix
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    /// The item at `url` itself (lstat: a link is the link), or nil when nothing is there: what Cut keeps, so the move it
    /// asks for runs only on the very items it marked (`Plan.sources`).
    public static func identity(of url: URL) -> Identity? { try? status(url.path(percentEncoded: false), follow: false) }

    /// The largest file a template can be: New file copies it whole.
    public static let templateLimit: Int64 = 100_000_000

    /// Whether `url` can be a New file template: a plain file (no link, folder or package) of at most `templateLimit`.
    public static func isTemplate(_ url: URL) -> Bool {
        var info = Darwin.stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFREG && Int64(info.st_size) <= templateLimit
    }

    /// The item a journal step left, as an undo finds it again: its identity and its volume's UUID, so a drive mounted again
    /// under a new device number still finds its items (same inode, same volume).
    struct Pin: Sendable {
        let id: Identity, volume: String?
        /// Whether `device`, the device of the volume at `folder`, is this pin's volume: the same number, or the same UUID.
        func on(_ device: UInt64, at folder: URL) -> Bool {
            device == id.device || (volume != nil && FileOps.volume(folder) == volume)
        }
    }

    /// One place: a resolved folder pinned by identity, a name in it, and the item there (nil for a place to fill).
    struct Spot: Equatable, Sendable {
        let folder: URL, folderID: Identity, name: String, item: Identity?
        var url: URL { folder.appending(path: name) }
        var path: String { url.path(percentEncoded: false) }
        func named(_ name: String) -> Spot { Spot(folder: folder, folderID: folderID, name: name, item: nil) }
    }

    /// One change a plan makes.
    enum Change: Equatable, Sendable {
        case copy(Spot, to: Spot)
        /// rename(2) on one volume; `caseOnly` when the target already finds the item itself (its letter case alone changes).
        case move(Spot, to: Spot, caseOnly: Bool)
        /// Across volumes: copy, check the copy matches, then the original to the Trash.
        case moveAcross(Spot, to: Spot)
        case trash(Spot)
        case makeFolder(Spot)
        /// A new plain file: empty, or the template's bytes.
        case makeFile(Spot, template: Spot?)

        var line: String {
            switch self {
            case let .copy(from, to): "\(from.path) → \(to.path)"
            case let .move(from, to, _): "\(from.path) → \(to.path)"
            case let .moveAcross(from, to): "\(from.path) → \(to.path) (another volume: copied, checked, then the original to the Trash)"
            case let .trash(item): "\(item.path) → the Trash"
            case let .makeFolder(new): "new folder \(new.path)"
            case let .makeFile(new, template): "new file \(new.path)" + (template.map { " from the template \($0.path)" } ?? "")
            }
        }
    }

    /// A request resolved: what Allow shows (`title`, `lines`) and exactly what `perform` runs.
    public struct Plan: Sendable, Equatable {
        public let request: Request
        public let title: String
        let changes: [Change]
        /// The journal entry an undo puts back.
        let entry: Int?
        /// The items the request names, by identity, in its order: what it copies or moves, or what a Trash request sends
        /// there (not the item a Replace sends to the Trash first). Cut checks they are the ones it marked before it runs
        /// the plan (`perform` checks each again just before it moves).
        public var sources: [Identity] {
            let trashing = if case .trash = request { true } else { false }
            return changes.compactMap { change in
                switch change {
                case let .copy(from, _), let .move(from, _, _), let .moveAcross(from, _): from.item
                case let .trash(from): trashing ? from.item : nil
                case .makeFolder, .makeFile: nil
                }
            }
        }
        /// Each change as source → target, each item going to the Trash and each new folder, in the order they run.
        public var lines: [String] { changes.map(\.line) }
        /// The question Allow shows for this plan; an undo is cut to the steps whose question fits (`undoing`).
        public var ask: ControlGate.Ask { ControlGate.Ask(title, lines: lines) }
    }

    private enum Step: Sendable {
        /// A copy, a new folder or a new file; undone by sending it to the Trash.
        case made(URL, Pin)
        /// A move or a rename; undone by moving it back.
        case moved(from: URL, to: URL, Pin)
        /// Sent to the Trash, which put it at `to`; undone by moving it back. `copy`: the cross-volume move's copy (its
        /// `made` step) that this original's Trash completes; that copy's undo is dropped with this one's.
        case trashed(from: URL, to: URL, Pin, copy: Identity?)
    }

    private struct Entry: Sendable {
        let id: Int, title: String
        var steps: [Step]
    }

    private let bin: Trash
    private let binFolder: TrashFolder
    private var journal: [Entry] = []
    private var nextID = 1
    /// True while an operation runs: the actor is reentrant at each Trash call, so a second one is refused, not interleaved.
    private var busy = false
    private let files = FileManager.default

    public init(trash: @escaping Trash = FileOps.systemTrash, trashFolder: @escaping TrashFolder = FileOps.systemTrashFolder) {
        bin = trash; binFolder = trashFolder
    }

    /// The Trash: macOS's, through NSWorkspace.recycle; in an isolated test run (the sandbox host) a folder in the run's
    /// throwaway Pilot folder, so no agent run ever reaches ~/.Trash. An item root owns (an App Store app) is refused the
    /// plain move: macOS asks for an administrator then, as Finder does (AdminTrash).
    public static let systemTrash: Trash = { url in
        if isIsolatedTestRun { return try throwawayTrash(url) }
        do { return try await recycle(url) } catch where AdminTrash.asks(error) { return try await AdminTrash.move(url) }
    }

    /// The Trash for a caller that cannot wait (the catalogue's installers): FileManager's, or in an isolated test run the
    /// throwaway folder `systemTrash` uses, so a sandbox remove never reaches ~/.Trash.
    public static func trashNow(_ url: URL) throws {
        if isIsolatedTestRun { _ = try throwawayTrash(url); return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Where `systemTrash` would put an item from `folder`, resolved as an undo reads it: the volume's Trash folder
    /// (`volumeTrash`), or in an isolated test run the throwaway folder on that volume with its eight-character subfolder;
    /// nil when the volume has no Trash Pilot can use.
    public static let systemTrashFolder: TrashFolder = { folder in
        isIsolatedTestRun ? throwawayRoot(folder)?.appending(path: "XXXXXXXX", directoryHint: .isDirectory) : volumeTrash(folder)
    }

    /// The Trash folder of `folder`'s volume as recycle finds or makes it: ~/.Trash, iCloud Drive's, or the volume's
    /// .Trashes/<uid>, which a volume has only once something went to its Trash (FileManager answers nil until then). Nil
    /// when the volume can't have one: read-only, not local (a network share's Trash deletes), its .Trashes not a folder,
    /// or none there and its top folder can't be written to.
    static func volumeTrash(_ folder: URL) -> URL? {
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false) {
            return real(trash) ?? trash
        }
        guard let values = try? folder.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]),
              let volume = values.volume.flatMap(real), values.volumeIsReadOnly != true, values.volumeIsLocal != false else { return nil }
        // No trailing slash: ".Trashes/" never finds a plain file there.
        let trashes = volume.appending(path: ".Trashes", directoryHint: .notDirectory)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: trashes.path(percentEncoded: false), isDirectory: &isFolder) {
            guard isFolder.boolValue else { return nil }
        } else if access(volume.path(percentEncoded: false), W_OK) != 0 { return nil }
        return trashes.appending(path: "\(getuid())", directoryHint: .isDirectory)
    }

    /// An isolated test run's throwaway Trash for items in `folder`, on their own volume as a real Trash is: the run's Pilot
    /// folder's Trash, or on another volume (the sandbox's disk images) its top folder's .pilot-sandbox-trash; nil when the
    /// volume has no Trash (`volumeTrash`), as a real Trash would refuse.
    private static func throwawayRoot(_ folder: URL) -> URL? {
        guard volumeTrash(folder) != nil else { return nil }
        let support = real(PilotFolder.support) ?? PilotFolder.support
        guard let device = try? status(folder.path(percentEncoded: false), follow: true) else { return nil }
        if device.device == (try? status(support.path(percentEncoded: false), follow: true))?.device {
            return support.appending(path: "Trash", directoryHint: .isDirectory)
        }
        guard let volume = (try? folder.resourceValues(forKeys: [.volumeURLKey]))?.volume.flatMap(real) else { return nil }
        return volume.appending(path: ".pilot-sandbox-trash", directoryHint: .isDirectory)
    }

    /// PILOT_SANDBOX_TRASH_PAD=<n>, read only in an isolated test run: the throwaway Trash puts each item n characters
    /// deeper than `systemTrashFolder` says, as a real Trash's place can be longer than its estimate (the backstop's proof).
    static let trashPad = isIsolatedTestRun ? max(0, Int(ProcessInfo.processInfo.environment["PILOT_SANDBOX_TRASH_PAD"] ?? "") ?? 0) : 0

    @MainActor private static func recycle(_ url: URL) async throws -> URL {
        guard let went = try await NSWorkspace.shared.recycle([url]).values.first else {
            throw Failure(.failed, "the Trash did not say where \(url.path(percentEncoded: false)) went")
        }
        return went
    }

    private static func throwawayTrash(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        guard let root = throwawayRoot(folder) else {
            throw Failure(.failed, "the volume of \(url.path(percentEncoded: false)) has no Trash")
        }
        var bin = root.appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
        // The pad as folders of at most 200 characters, each "/" counting toward it.
        var pad = trashPad
        while pad > 0 {
            let part = max(2, min(pad, 201))
            bin = bin.appending(path: String(repeating: "p", count: part - 1), directoryHint: .isDirectory)
            pad -= part
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let went = bin.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: went)
        return went
    }

    // MARK: Plan

    /// The operation an undo puts back next, or nil when there is none.
    public var nextUndo: String? { journal.last?.title }

    /// `request` resolved into the changes it makes, or the refusal; nothing on disk changes. An operation is refused when
    /// the undo of any one of its steps could not be asked on its own (`undoable`). An undo plans the newest steps that can
    /// run and whose question fits; when its newest step can't for good (its item gone or changed since, its place taken,
    /// its folder gone), that step is dropped from the journal here (the journal only), so it never blocks the older ones;
    /// when it can't for now (`unavailable`), it stays to be tried again. Nothing is dropped while another operation runs.
    public func plan(_ request: Request) throws -> Plan {
        let plan = try planning(request)
        if plan.entry == nil { try undoable(plan) }
        return plan
    }

    private func planning(_ request: Request) throws -> Plan {
        switch request {
        case let .copy(sources, folder, clash), let .move(sources, folder, clash):
            let moving = if case .move = request { true } else { false }
            let changes = try placements(sources, into: folder, moving: moving, clash: clash)
            let placed = changes.compactMap { change -> Spot? in
                switch change {
                case let .copy(from, _), let .move(from, _, _), let .moveAcross(from, _): from
                case .trash, .makeFolder, .makeFile: nil
                }
            }
            let verb = moving ? "Move" : "Copy"
            return Plan(request: request, title: placed.count == 1 ? "\(verb) \(placed[0].name)" : "\(verb) \(placed.count) items",
                        changes: changes, entry: nil)
        case let .rename(item, name):
            let change = try renaming(item, to: name)
            guard case let .move(from, _, _) = change else { preconditionFailure("a rename is a move") }
            return Plan(request: request, title: "Rename \(from.name) to \(name)", changes: [change], entry: nil)
        case let .trash(items):
            let spots = try present(items)
            for item in spots {
                if let holder = spots.first(where: { $0 != item && lineage(item.folder).contains($0.item!) }) {
                    throw Failure(.refused, "\(item.path) is inside \(holder.path), which goes to the Trash too; name only one")
                }
            }
            return Plan(request: request, title: spots.count == 1 ? "Move \(spots[0].name) to the Trash" : "Move \(spots.count) items to the Trash",
                        changes: spots.map(Change.trash), entry: nil)
        case let .newFolder(folder, name):
            let target = try newFolderTarget(folder, name)
            return Plan(request: request, title: "New folder \(target.name)", changes: [.makeFolder(target)], entry: nil)
        case let .newFile(folder, name, template):
            if let refusal = Self.badName(name) { throw Failure(.refused, refusal) }
            let folder = try folderSpot(folder)
            let source = try template.map { template in
                guard Self.isTemplate(template) else {
                    throw Failure(.refused, "\(template.lastPathComponent) is not a plain file of at most \(Self.templateLimit / 1_000_000) MB; only one can be a template")
                }
                return try present([template])[0]
            }
            let target = folder.named(unused(folder.folder.appending(path: name), taken: []))
            return Plan(request: request, title: "New file \(target.name)", changes: [.makeFile(target, template: source)], entry: nil)
        case .undo:
            guard let entry = journal.last else { throw Failure(.missing, "nothing to undo") }
            do {
                let (title, changes) = try undoing(entry)
                return Plan(request: request, title: title, changes: changes, entry: entry.id)
            } catch let failure as Failure {
                throw dropping(entry, failure)
            }
        }
    }

    /// `failure` of the undo of `entry` (the journal's last), its newest step's. A cause for good drops that step alone (and
    /// a cross-volume copy it completes), so older undos are reached; a cause for now keeps it to be tried again. While
    /// another operation runs nothing is dropped.
    private func dropping(_ entry: Entry, _ failure: Failure) -> Failure {
        guard !busy, journal.last?.id == entry.id, let step = entry.steps.last else { return failure }
        guard permanent(failure, step) else {
            return Failure(failure.kind, "nothing undone: \(failure.message); that step stays, so undo again once it can run")
        }
        let what = drop(journal.count - 1)
        return Failure(failure.kind, "nothing undone: \(failure.message), so that step of the undo of \(entry.title) is dropped: \(what)"
                       + (journal.last.map { "; the next undo is \($0.title)" } ?? ""))
    }

    /// Whether `failure` of `step`'s undo is for good: its item gone or changed, its place taken, its folder gone, a move
    /// back across volumes or a question too long; not while the volume that held its item is not mounted.
    private func permanent(_ failure: Failure, _ step: Step) -> Bool {
        guard [.gone, .clash, .missing, .refused].contains(failure.kind) else { return false }
        return !unmounted(Self.place(step), Self.pin(step))
    }

    /// Drops the newest step of journal entry `at`, and with a cross-volume original's Trash the copy's step it completes,
    /// so no later undo sends the only copy outside the Trash there too; answers what is left as it is.
    private func drop(_ at: Int) -> String {
        let step = journal[at].steps.removeLast()
        var what = "Pilot leaves \(Self.place(step).path(percentEncoded: false)) as it is"
        if case let .trashed(_, _, _, copy?) = step, let paired = journal[at].steps.lastIndex(where: { Self.pin($0).id == copy }) {
            what += ", and its copy \(Self.place(journal[at].steps.remove(at: paired)).path(percentEncoded: false)) too"
        }
        if journal[at].steps.isEmpty { journal.remove(at: at) }
        return what
    }

    /// Runs `approved` once it still matches a fresh plan of its request: an item swapped, moved or renamed while Allow was
    /// up, or another operation run since, refuses it and nothing runs. Each item's identity is checked again just before it
    /// moves; the steps that ran before a failure stay in the journal, so an undo puts back whatever ran.
    public func perform(_ approved: Plan) async throws -> Done {
        guard !busy else { throw Failure(.refused, "another file operation is running; nothing was changed. Try again when it ends") }
        busy = true
        defer { busy = false }
        let now: Plan
        do { now = try plan(approved.request) } catch let failure as Failure {
            throw Failure(.changed, "changed while asking, so not run: \(failure.message)")
        }
        guard now == approved else {
            throw Failure(.changed, "changed while asking, so not run: \(approved.title): " + (now.lines == approved.lines
                ? "an item or folder it names was swapped for another since Allow showed it"
                : "it now plans \(now.lines.joined(separator: "; "))"))
        }
        if let entry = approved.entry { return try await undo(approved, entry) }
        var steps: [Step] = []
        do {
            let undoTitle = Self.undoTitle(approved.title, 1, of: Self.stepCount(approved.changes))
            for change in approved.changes { try await apply(change, &steps, undoTitle: undoTitle) }
        } catch {
            keep(approved.title, steps)
            let failure = error as? Failure ?? Failure(.failed, error.localizedDescription)
            throw Failure(failure.kind, steps.isEmpty ? failure.message : "\(failure.message); undo puts back the \(steps.count) steps done")
        }
        keep(approved.title, steps)
        return done(approved.title, steps)
    }

    // MARK: Inside

    /// Every source's change into `folder`, a replaced item's Trash first; or the refusal. Clashes are collected first, so an
    /// ask names them all. The guards compare identities, never spellings: a case variant, a symlinked route or a hard link
    /// to the same item is that item.
    private func placements(_ sources: [URL], into folder: URL, moving: Bool, clash: Clash) throws -> [Change] {
        let destination = try folderSpot(folder)
        let spots = try present(sources)
        // The destination and every folder above it: a source among them would go inside itself.
        let above = Set(lineage(destination.folder))
        // Every source and every folder holding one: an item there can't be replaced.
        let held = Set(spots.flatMap { lineage($0.folder) + [$0.item!] })
        var changes: [Change] = [], clashes: [String] = [], taken: Set<String> = []
        for source in spots {
            if above.contains(source.item!) { throw Failure(.refused, "\(source.path) can't go inside itself (\(destination.folder.path(percentEncoded: false)))") }
            if moving, source.folderID == destination.folderID {
                throw Failure(.refused, "\(source.path) is already in \(destination.folder.path(percentEncoded: false))")
            }
            var target = destination.named(source.name)
            let key = source.name.lowercased()
            let there = try? identity(target.url)
            if there != nil || taken.contains(key) {
                switch clash {
                case .ask: clashes.append(source.name)
                case .keepBoth: target = destination.named(unused(target.url, taken: taken))
                case .replace:
                    guard let there, !taken.contains(key) else {
                        throw Failure(.refused, "two items named \(source.name) go to \(destination.folder.path(percentEncoded: false)); keep both instead")
                    }
                    guard !held.contains(there) else {
                        throw Failure(.refused, "\(target.path) is \(source.path) itself or a folder holding one of the items, so it can't be replaced; keep both instead")
                    }
                    changes.append(.trash(Spot(folder: destination.folder, folderID: destination.folderID, name: source.name, item: there)))
                }
            }
            taken.insert(target.name.lowercased())
            if !moving { changes.append(.copy(source, to: target)) }
            else if source.item!.device == destination.folderID.device { changes.append(.move(source, to: target, caseOnly: false)) }
            else { changes.append(.moveAcross(source, to: target)) }
        }
        if !clashes.isEmpty {
            let names = clashes.joined(separator: ", ")
            throw Failure(.clash, "\(names) already \(clashes.count == 1 ? "exists" : "exist") in \(destination.folder.path(percentEncoded: false)); "
                          + "nothing was \(moving ? "moved" : "copied"). Keep both (a number is added) or replace (the one there goes to the Trash)")
        }
        return changes
    }

    /// The rename's move, or the refusal. Its target finding the item itself is a new letter case when only the case differs,
    /// else a hard link to it: a clash, since rename(2) onto a link of the same file does nothing.
    private func renaming(_ item: URL, to name: String) throws -> Change {
        let item = try present([item])[0]
        if let refusal = Self.badName(name) { throw Failure(.refused, refusal) }
        guard name != item.name else { throw Failure(.refused, "\(name) is already its name") }
        let target = item.named(name)
        let caseOnly = name.lowercased() == item.name.lowercased()
        if let there = try? identity(target.url), !(caseOnly && there == item.item) {
            throw Failure(.clash, "\(name) already exists in \(item.folder.path(percentEncoded: false))"
                          + (there == item.item ? " as another name (a hard link) for the same file" : "") + "; nothing was renamed. Pick another name")
        }
        return .move(item, to: target, caseOnly: caseOnly)
    }

    private func newFolderTarget(_ folder: URL, _ name: String?) throws -> Spot {
        let folder = try folderSpot(folder)
        if let name, let refusal = Self.badName(name) { throw Failure(.refused, refusal) }
        let target = folder.named(name ?? unused(folder.folder.appending(path: "untitled folder"), taken: []))
        if (try? identity(target.url)) != nil {
            throw Failure(.clash, "\(target.name) already exists in \(folder.folder.path(percentEncoded: false)); nothing was made. Pick another name")
        }
        return target
    }

    /// The line an undo shows for putting the item named `name` in Trash folder `bin` back as `item`: `Change.line` of the
    /// move `undoing` plans, so an estimate or a backstop measures what Allow will show.
    static func putBack(_ bin: URL, _ name: String, to item: Spot) -> String {
        Change.move(Spot(folder: bin, folderID: item.folderID, name: name, item: nil), to: item, caseOnly: false).line
    }

    /// The title of an undo of `count` of the `total` steps of the operation titled `title`.
    static func undoTitle(_ title: String, _ count: Int, of total: Int) -> String {
        count == total ? "Undo \(title)" : "Undo \(title), the last \(count) of its \(total) steps"
    }

    /// How many journal steps `changes` record: one each, two for a move across volumes (its copy, its original's Trash).
    static func stepCount(_ changes: [Change]) -> Int {
        changes.reduce(0) { count, change in if case .moveAcross = change { count + 2 } else { count + 1 } }
    }

    /// Refuses `plan` when the undo of any one step it records could not be asked on its own: each step's undo line as
    /// `undoing` words it, a trashed item's place estimated from its volume's Trash folder, its name and `trashSuffix`, under
    /// the longest title its undo can have. Refuses it too when a step's undo needs a Trash (a copy's or a new folder's, or
    /// a trashed item's way back) on a volume with none Pilot can use. So whatever runs can always be undone, one step at a
    /// time if need be; `apply`'s backstop catches a Trash whose real place is longer than this estimate.
    private func undoable(_ plan: Plan) throws {
        var undos: [(of: String, line: String, fromTrash: Bool)] = []
        func noTrash(_ spot: Spot) -> Failure {
            Failure(.refused, "\(plan.title) is not run: \(spot.folder.path(percentEncoded: false)) is on a volume with no Trash Pilot can use "
                    + "(read-only, a network share, or its .Trashes can't be made), so the undo of \(spot.path) could never run; "
                    + "Pilot runs only what it can undo, so nothing was changed")
        }
        func toTrash(_ spot: Spot) throws -> String {
            guard binFolder(spot.folder) != nil else { throw noTrash(spot) }
            return "\(spot.path) → the Trash"
        }
        func trashed(_ item: Spot) throws -> String {
            guard let bin = binFolder(item.folder) else { throw noTrash(item) }
            return Self.putBack(bin, item.name + String(repeating: "_", count: Self.trashSuffix), to: item)
        }
        for change in plan.changes {
            switch change {
            case let .copy(_, to): undos.append((to.path, try toTrash(to), false))
            case let .move(from, to, _): undos.append((from.path, "\(to.path) → \(from.path)", false))
            case let .moveAcross(from, to):
                undos.append((to.path, try toTrash(to), false))
                undos.append((from.path, try trashed(from), true))
            case let .trash(item): undos.append((item.path, try trashed(item), true))
            case let .makeFolder(new), let .makeFile(new, _): undos.append((new.path, try toTrash(new), false))
            }
        }
        // One step asked alone, the others still in the journal: "Undo <title>, the last 1 of its <n> steps".
        let title = Self.undoTitle(plan.title, 1, of: Self.stepCount(plan.changes))
        for undo in undos {
            if let tooLong = ControlGate.Ask(title, lines: [undo.line]).tooLong {
                throw Failure(.refused, "\(plan.title) is not run: the undo of \(undo.of) could not be asked (\(tooLong)"
                              + (undo.fromTrash ? ", counting its volume's Trash folder, its name and \(Self.trashSuffix) characters for a name the Trash may give it" : "")
                              + "); Pilot runs only what it can undo, so nothing was changed. A shorter path or name fits")
            }
        }
    }

    /// An undo's title and changes: its newest steps, each a made item to the Trash or a moved or trashed one back where it
    /// was, for as long as each can run and the question Allow shows for them stays within ControlGate.Ask.longest and
    /// mostLines (a step put back from the Trash names two paths, so its undo asks more than its operation did). The rest
    /// stay for the next undo, which goes on from there. The newest step itself is thrown when it can't: its item not the
    /// one Pilot left is gone; a place taken again, a folder gone, a move back across volumes or a question too long alone
    /// is refused (each for good); a drive not mounted or a folder that can't be written to is unavailable (for now).
    private func undoing(_ entry: Entry) throws -> (title: String, changes: [Change]) {
        var changes: [Change] = [], leaving: Set<String> = []
        let title = { (count: Int) in Self.undoTitle(entry.title, count, of: entry.steps.count) }
        for step in entry.steps.reversed() {
            let change: Change
            do { change = try undoing(step, leaving) } catch where !changes.isEmpty { break }
            let candidate = title(changes.count + 1)
            if let tooLong = ControlGate.Ask(candidate, lines: (changes + [change]).map(\.line)).tooLong {
                guard !changes.isEmpty else { throw Failure(.refused, "putting back \(change.line) can't be asked: \(tooLong)") }
                break
            }
            changes.append(change)
            switch change {
            case let .trash(item), let .move(item, _, _): leaving.insert(item.path)
            case .copy, .moveAcross, .makeFolder, .makeFile: break
            }
        }
        return (title(changes.count), changes)
    }

    /// One step's undo, `leaving` the places the newer steps of the same undo empty; or why it can't run.
    private func undoing(_ step: Step, _ leaving: Set<String>) throws -> Change {
        switch step {
        case let .made(url, was):
            let item = try pinned(url, was)
            try writable(item.folder)
            return .trash(item)
        case let .moved(back, now, was), let .trashed(back, now, was, _):
            let item = try pinned(now, was)
            guard let folder = Self.real(back.deletingLastPathComponent()), let folderID = try? folderIdentity(folder) else {
                let gone = back.deletingLastPathComponent()
                if unmounted(gone, was) {
                    throw Failure(.unavailable, "the drive that held \(gone.path(percentEncoded: false)) is not mounted")
                }
                throw Failure(.missing, "the folder \(gone.path(percentEncoded: false)) is gone")
            }
            let target = Spot(folder: folder, folderID: folderID, name: back.lastPathComponent, item: nil)
            let caseOnly = folderID == item.folderID && target.name.lowercased() == item.name.lowercased()
            if let there = try? identity(target.url), !(caseOnly && there == item.item), !leaving.contains(target.path) {
                throw Failure(.clash, "\(target.path) is taken again, so \(item.name) is not put back over it")
            }
            // The item's device as it is now: a drive mounted again under a new number is still the same volume.
            guard folderID.device == item.item!.device else {
                throw Failure(.refused, "\(target.folder.path(percentEncoded: false)) is on another volume than \(item.path) now; an undo never copies")
            }
            try writable(item.folder); try writable(folder)
            return .move(item, to: target, caseOnly: caseOnly)
        }
    }

    /// Where a step left its item.
    private static func place(_ step: Step) -> URL {
        switch step {
        case let .made(url, _), let .moved(_, url, _), let .trashed(_, url, _, _): url
        }
    }

    /// Which item a step left there.
    private static func pin(_ step: Step) -> Pin {
        switch step {
        case let .made(_, was), let .moved(_, _, was), let .trashed(_, _, was, _): was
        }
    }


    /// Puts back journal entry `id` as `plan` says, newest step first, each step leaving the journal as it runs. A step that
    /// fails for good (its item gone, its place taken) is dropped alone, with a cross-volume copy it completes, so it never
    /// blocks older undos; one that fails for now (a drive not mounted, a folder that can't be written to, anything else)
    /// stays with the rest for the next undo.
    private func undo(_ plan: Plan, _ id: Int) async throws -> Done {
        var ran: [Step] = []
        for change in plan.changes {
            do {
                try await apply(change, &ran, undoTitle: nil)
            } catch {
                let failure = error as? Failure ?? Failure(.failed, error.localizedDescription)
                let rest: String
                if let at = journal.lastIndex(where: { $0.id == id }), let step = journal[at].steps.last, permanent(failure, step) {
                    rest = "so that step is dropped: \(drop(at))" + (journal.last.map { "; the next undo is \($0.title)" } ?? "")
                } else {
                    rest = ran.isEmpty ? "that step stays, so undo again once it can run" : "that step and the older ones stay for the next undo"
                }
                throw Failure(failure.kind, (ran.isEmpty ? "nothing undone: " : "undo stopped after \(ran.count) of its steps: ") + "\(failure.message), \(rest)")
            }
            if let at = journal.lastIndex(where: { $0.id == id }) {
                journal[at].steps.removeLast()
                if journal[at].steps.isEmpty { journal.remove(at: at) }
            }
        }
        return done(plan.title, ran)
    }

    /// Runs one change, its items checked against the plan's identities just before, and records what it did. `undoTitle`:
    /// the title of an operation's undo of one step, for its Trash backstop (`binned`); nil while an undo runs.
    private func apply(_ change: Change, _ steps: inout [Step], undoTitle: String?) async throws {
        switch change {
        case let .copy(from, to):
            try check(from); try vacant(to)
            try files.copyItem(at: from.url, to: to.url)
            steps.append(.made(to.url, try pin(to.url)))
        case let .move(from, to, caseOnly):
            try check(from)
            let same = caseOnly && (try? identity(to.url)) == from.item
            if !same { try vacant(to) }
            // An undo bringing an item out of a Trash folder: a privacy block there can be Full Disk Access. lstat and
            // access(2) there work without it (spec pilot-1.1 T6, fix4-fda.log); the move back out is not proved either way.
            let fromTrash = undoTitle == nil && from.folder.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
            try Self.rename(from.url, to.url, exclusive: !same, blocked: fromTrash
                ? "if macOS blocks Pilot in the Trash, turn on Full Disk Access for Pilot (System Settings, Privacy & Security) and undo again" : nil)
            steps.append(.moved(from: from.url, to: to.url, try pin(to.url)))
        case let .moveAcross(from, to):
            try check(from); try vacant(to)
            try files.copyItem(at: from.url, to: to.url)
            let copy = try pin(to.url)
            steps.append(.made(to.url, copy))
            guard files.contentsEqual(atPath: from.path, andPath: to.path) else {
                throw Failure(.failed, "the copy of \(from.name) on the other volume does not match it, so the original stays")
            }
            try check(from)
            let went = try await bin(from.url)
            try binned(from, went, copy: copy.id, undoTitle, &steps)
        case let .trash(item):
            try check(item)
            let went = try await bin(item.url)
            try binned(item, went, copy: nil, undoTitle, &steps)
        case let .makeFolder(new):
            try vacant(new)
            try files.createDirectory(at: new.url, withIntermediateDirectories: false)
            steps.append(.made(new.url, try pin(new.url)))
        case let .makeFile(new, template):
            try vacant(new)
            // Made with O_EXCL and O_NOFOLLOW, so never over an item or through a link put there since `vacant`; recorded
            // as soon as it exists, so a copy that fails half way is still undone.
            let made = try Self.createPlain(new.url)
            defer { close(made) }
            var info = Darwin.stat()
            guard fstat(made, &info) == 0 else { throw Failure(.failed, "\(new.name) was made but can't be read back: \(String(cString: strerror(errno)))") }
            // The file this call made, by its descriptor: whatever the name points at by now.
            let id = Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
            steps.append(.made(new.url, Pin(id: id, volume: Self.volume(new.folder))))
            if let template { try Self.copyBytes(of: template, into: made) }
        }
    }

    /// Records `item`'s Trash, which put it at `went`, once the undo of that alone can be asked (the backstop behind
    /// `undoable`'s estimate: a Trash's real place can be longer, as iCloud Drive's is). When it can't, the item is put back
    /// where it was, if it is still the one sent, and nothing of it is recorded; the refusal names it. When it can't be put
    /// back, its step is recorded anyway and the refusal says where it is. Earlier steps stay in the journal either way.
    private func binned(_ item: Spot, _ went: URL, copy: Identity?, _ undoTitle: String?, _ steps: inout [Step]) throws {
        // The item's identity if it can't be read there now: a same-volume Trash keeps the inode, so its undo still finds it.
        let pin = (try? pin(went)) ?? Pin(id: item.item!, volume: Self.volume(item.folder))
        let step = Step.trashed(from: item.url, to: went, pin, copy: copy)
        guard let undoTitle else { steps.append(step); return }
        let folder = went.deletingLastPathComponent()
        let line = Self.putBack(Self.real(folder) ?? folder, went.lastPathComponent, to: item)
        guard let tooLong = ControlGate.Ask(undoTitle, lines: [line]).tooLong else {
            steps.append(step); return
        }
        let wentPath = went.path(percentEncoded: false)
        do {
            guard (try? identity(went)) == item.item else { throw Failure(.gone, "what is there is not the item sent") }
            try vacant(item)
            try Self.rename(went, item.url, exclusive: true)
        } catch {
            steps.append(step)
            let why = (error as? Failure)?.message ?? error.localizedDescription
            throw Failure(.refused, "\(item.path) went to the Trash at \(wentPath), where its undo can't be asked (\(tooLong)), "
                          + "and it could not be put back (\(why)); it is in the Trash there, so take it out by hand")
        }
        throw Failure(.refused, "\(item.path) is back where it was, not in the Trash: the Trash put it at \(wentPath), "
                      + "where its undo could not be asked (\(tooLong)); Pilot runs only what it can undo. A shorter path or name fits"
                      + (copy != nil ? ". Its copy on the other volume stays; undo sends that copy to the Trash" : ""))
    }

    private func done(_ title: String, _ steps: [Step]) -> Done {
        var items: [URL] = [], trashed: [URL] = []
        var moved: [URL: URL] = [:]
        for step in steps {
            switch step {
            case let .made(url, _): items.append(url)
            case let .moved(from, url, _): items.append(url); moved[from] = url
            case let .trashed(_, to, _, _): trashed.append(to)
            }
        }
        return Done(title: title, items: items, trashed: trashed, moved: moved)
    }

    private func keep(_ title: String, _ steps: [Step]) {
        guard !steps.isEmpty else { return }
        journal.append(Entry(id: nextID, title: title, steps: steps))
        nextID += 1
        if journal.count > Self.depth { journal.removeFirst(journal.count - Self.depth) }
    }

    // MARK: Places and identities

    /// Each item as a spot: its folder resolved (symlinks and all) and pinned, the item itself pinned, a link as itself.
    /// Naming one item twice, by any route, is refused.
    private func present(_ items: [URL]) throws -> [Spot] {
        guard !items.isEmpty else { throw Failure(.refused, "no items") }
        var seen: Set<Identity> = []
        return try items.map {
            let url = $0.standardizedFileURL, name = url.lastPathComponent
            guard !name.isEmpty, name != "/", name != ".", name != ".." else { throw Failure(.refused, "\(url.path(percentEncoded: false)) is not an item in a folder") }
            guard let folder = Self.real(url.deletingLastPathComponent()), let folderID = try? folderIdentity(folder),
                  let item = try? identity(folder.appending(path: name)) else {
                throw Failure(.missing, "nothing at \(url.path(percentEncoded: false))")
            }
            let spot = Spot(folder: folder, folderID: folderID, name: Self.onDisk(name, in: folder) ?? name, item: item)
            guard seen.insert(item).inserted else { throw Failure(.refused, "\(spot.path) is named twice") }
            return spot
        }
    }

    /// The folder `url` names, resolved and pinned, as a spot whose name is a placeholder (`named` fills it).
    private func folderSpot(_ url: URL) throws -> Spot {
        let url = url.standardizedFileURL
        var isFolder: ObjCBool = false
        guard let folder = Self.real(url), files.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue,
              let folderID = try? folderIdentity(folder) else {
            throw Failure(.missing, "no folder at \(url.path(percentEncoded: false))")
        }
        return Spot(folder: folder, folderID: folderID, name: "", item: nil)
    }

    /// The spot at `url`, which must hold the item `was`, as it is now: the same identity, or the same inode on the same
    /// volume (its UUID) under a new device number, as a drive mounted again gets; else it is gone.
    private func pinned(_ url: URL, _ was: Pin) throws -> Spot {
        guard let folder = Self.real(url.deletingLastPathComponent()), let folderID = try? folderIdentity(folder),
              let now = try? identity(folder.appending(path: url.lastPathComponent)),
              now.inode == was.id.inode, was.on(now.device, at: folder) else {
            if unmounted(url, was) {
                throw Failure(.unavailable, "the drive that held \(url.path(percentEncoded: false)) is not mounted")
            }
            throw Failure(.gone, "\(url.path(percentEncoded: false)) is not the item Pilot left there (moved, renamed or replaced since)")
        }
        return Spot(folder: folder, folderID: folderID, name: url.lastPathComponent, item: now)
    }

    /// Refuses unless the spot's folder and item are still the ones the plan pinned.
    private func check(_ spot: Spot) throws {
        guard (try? folderIdentity(spot.folder)) == spot.folderID, (try? identity(spot.url)) == spot.item else {
            throw Failure(.gone, "\(spot.path) is not the item Allow showed (moved, renamed or replaced since); it was not touched")
        }
    }

    /// Refuses unless the spot's folder is still the pinned one and nothing takes the name.
    private func vacant(_ spot: Spot) throws {
        guard (try? folderIdentity(spot.folder)) == spot.folderID else {
            throw Failure(.gone, "\(spot.folder.path(percentEncoded: false)) is not the folder Allow showed (moved, renamed or replaced since)")
        }
        if (try? identity(spot.url)) != nil { throw Failure(.clash, "\(spot.path) is taken, so nothing is put over it") }
    }

    /// Refuses, for now, unless `folder` can be written to (a read-only folder or volume can be made writable again).
    private func writable(_ folder: URL) throws {
        guard access(folder.path(percentEncoded: false), W_OK) != 0 else { return }
        throw Failure(.unavailable, "\(folder.path(percentEncoded: false)) can't be written to (\(String(cString: strerror(errno))))")
    }

    /// Whether `url` is missing because the volume that held it (`was`) is not mounted there now: nothing is at `url` and
    /// the nearest folder above it that exists is on another volume, by device and by UUID (a drive mounted again under a
    /// new device number is mounted). An item there, whatever its volume, is not.
    private func unmounted(_ url: URL, _ was: Pin) -> Bool {
        var at = url.path(percentEncoded: false)
        if (try? Self.status(at, follow: false)) != nil { return false }
        while true {
            if let id = try? Self.status(at, follow: true) {
                return !was.on(id.device, at: URL(filePath: at))
            }
            if at == "/" || at.isEmpty { return true }
            at = (at as NSString).deletingLastPathComponent
        }
    }

    /// `folder` and every folder above it, by identity.
    private func lineage(_ folder: URL) -> [Identity] {
        var out: [Identity] = [], at = folder.path(percentEncoded: false)
        while true {
            if let id = try? Self.status(at, follow: true) { out.append(id) }
            if at == "/" || at.isEmpty { return out }
            at = (at as NSString).deletingLastPathComponent
        }
    }

    /// The item at `url` itself (lstat: a link is the link).
    private func identity(_ url: URL) throws -> Identity { try Self.status(url.path(percentEncoded: false), follow: false) }
    /// The item at `url` as a journal step keeps it: its identity and its folder's volume UUID.
    private func pin(_ url: URL) throws -> Pin { Pin(id: try identity(url), volume: Self.volume(url.deletingLastPathComponent())) }
    /// The UUID of the volume `folder` is on, read fresh (a new URL each time: resource values are cached per URL).
    fileprivate static func volume(_ folder: URL) -> String? {
        (try? URL(filePath: folder.path(percentEncoded: false), directoryHint: .isDirectory).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }
    /// The folder at `url` (stat: a resolved folder's path holds no link, and a link put there since reads as another item).
    private func folderIdentity(_ url: URL) throws -> Identity { try Self.status(url.path(percentEncoded: false), follow: true) }

    private static func status(_ path: String, follow: Bool) throws -> Identity {
        var info = Darwin.stat()
        guard (follow ? stat(path, &info) : lstat(path, &info)) == 0 else { throw Failure(.missing, "nothing at \(path)") }
        return Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
    }

    /// The name `typed` has on disk in `folder` (its letter case and Unicode form as stored, the item itself, not a link's
    /// target), or nil when the volume names another link of the item (a hard link) or can't say.
    static func onDisk(_ typed: String, in folder: URL) -> String? {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(bitPattern: ATTR_CMN_NAME),
                               volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + 1024)
        let path = folder.appending(path: typed).path(percentEncoded: false)
        guard getattrlist(path, &request, &buffer, buffer.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return nil }
        let name: String? = buffer.withUnsafeBytes { raw in
            let reference = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset), end = start + Int(reference.attr_length) - 1
            guard reference.attr_length > 0, start >= 4, end <= raw.count else { return nil }
            return String(decoding: raw[start..<end], as: UTF8.self)
        }
        guard let name, name.compare(typed, options: .caseInsensitive) == .orderedSame else { return nil }
        return name
    }

    /// `url` with every symlink and dot resolved (realpath(3)), or nil when it does not exist.
    static func real(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: false)
    }

    /// A new, empty plain file at `url`, opened for writing: never over an item there and never through a link.
    private static func createPlain(_ url: URL) throws -> Int32 {
        let made = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard made >= 0 else {
            let code = errno
            if code == EEXIST { throw Failure(.clash, "\(url.path(percentEncoded: false)) is taken, so nothing is put over it") }
            throw Failure(code == EACCES || code == EPERM || code == EROFS ? .unavailable : .failed,
                          "\(url.lastPathComponent) can't be made: \(String(cString: strerror(code)))")
        }
        return made
    }

    /// The bytes of the template `spot` into `made`: opened without following a link and checked to be the very plain
    /// file planned, at most `templateLimit`, so the template itself is only read.
    private static func copyBytes(of spot: Spot, into made: Int32) throws {
        // O_NONBLOCK: a pipe swapped in since the plan never holds the actor; fstat refuses it.
        let source = open(spot.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw Failure(.gone, "the template \(spot.path) can't be read: \(String(cString: strerror(errno)))") }
        defer { close(source) }
        var info = Darwin.stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) <= templateLimit,
              Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino) == spot.item else {
            throw Failure(.gone, "the template \(spot.path) is not the plain file planned (changed since); the new file stays empty, and undo takes it back")
        }
        copyQuarantine(from: source, to: made)
        var buffer = [UInt8](repeating: 0, count: 1 << 20), copied: Int64 = 0
        while true {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            guard read >= 0 else { throw Failure(.failed, "the template \(spot.name) did not read: \(String(cString: strerror(errno)))") }
            if read == 0 { return }
            copied += Int64(read)
            guard copied <= templateLimit else { throw Failure(.failed, "the template \(spot.name) grew past \(templateLimit / 1_000_000) MB while copied") }
            var at = 0
            while at < read {
                let wrote = buffer.withUnsafeBytes { write(made, $0.baseAddress! + at, read - at) }
                guard wrote > 0 else { throw Failure(.failed, "the new file did not take the template's bytes: \(String(cString: strerror(errno)))") }
                at += wrote
            }
        }
    }

    /// The template's com.apple.quarantine flag on the new file, so a downloaded template's copy still opens with macOS's
    /// check; its other extended attributes are left behind. None there, nothing done.
    private static func copyQuarantine(from source: Int32, to made: Int32) {
        let name = "com.apple.quarantine"
        let size = fgetxattr(source, name, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        let read = value.withUnsafeMutableBytes { fgetxattr(source, name, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return }
        _ = value.withUnsafeBytes { fsetxattr(made, name, $0.baseAddress, read, 0, 0) }
    }

    /// rename(2), never across volumes (no copy) and, `exclusive`, never over an item already there. `blocked`: what the
    /// refusal adds when a privacy block (EPERM) stops it.
    private static func rename(_ from: URL, _ to: URL, exclusive: Bool, blocked: String? = nil) throws {
        guard renamex_np(from.path(percentEncoded: false), to.path(percentEncoded: false), exclusive ? UInt32(RENAME_EXCL) : 0) == 0 else {
            let code = errno
            switch code {
            case EXDEV: throw Failure(.refused, "\(to.deletingLastPathComponent().path(percentEncoded: false)) is on another volume; nothing was copied")
            case EEXIST: throw Failure(.clash, "\(to.path(percentEncoded: false)) is taken, so nothing is put over it")
            case EACCES, EPERM, EROFS:
                throw Failure(.unavailable, "\(from.lastPathComponent) can't be moved: \(String(cString: strerror(code)))"
                              + (code == EPERM ? blocked.map { "; " + $0 } ?? "" : ""))
            default: throw Failure(.failed, "\(from.lastPathComponent): \(String(cString: strerror(code)))")
            }
        }
    }

    /// `url`'s name, or "name 2.ext", "name 3.ext" and on, the first neither in its folder nor in `taken` (lower-case names).
    private func unused(_ url: URL, taken: Set<String>) -> String {
        let folder = url.deletingLastPathComponent()
        let there = ((try? files.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).map { $0.lowercased() }
        return NotesFolder.freeName(url.lastPathComponent, taken: taken.union(there))
    }

    /// Why `name` can't be a file's name, or nil.
    static func badName(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return "\"\(name)\" can't be a name" }
        if name.contains("/") || name.contains("\0") { return "a name can't hold / (\(name))" }
        if name.utf8.count > 255 { return "a name is at most 255 bytes" }
        return nil
    }
}

/// CDXC:Files 2026-11-08 DECISION:
/// Sven approved Empty Bin and Delete Immediately with an explicit irreversible confirmation.
/// These never enter FileOps' undo journal. The native caller supplies system Trash roots, never an arbitrary folder.
public enum TrashDeletion {
    public struct Plan: Sendable {
        fileprivate let entries: [Entry]
        public var count: Int { entries.count }
        public var name: String { count == 1 ? entries[0].url.lastPathComponent : "\(count) items" }
    }

    fileprivate struct Stamp: Equatable, Sendable {
        let identity: FileOps.Identity
        let directory: Bool
        let modified: timespec, changed: timespec
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity && lhs.directory == rhs.directory && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    fileprivate struct Entry: Sendable {
        let url: URL, root: URL, parent: URL
        let rootID: FileOps.Identity, parentID: FileOps.Identity
        let contents: [String: Stamp]
    }

    /// nil snapshots all current top-level items; an explicit group may name descendants, never a Trash root itself.
    /// Later arrivals are not added to this plan. No path is followed through a symlinked Trash root or final item.
    public static func plan(_ selected: [URL]?, roots: [URL]) throws -> Plan {
        var allowed: [URL: FileOps.Identity] = [:]
        for root in roots {
            guard root.isFileURL, root.lastPathComponent == ".Trash"
                || (root.deletingLastPathComponent().lastPathComponent == ".Trashes" && root.lastPathComponent == String(geteuid())) else {
                throw Failure("Not a system Trash folder; nothing deleted.")
            }
            var info = Darwin.stat()
            if lstat(root.path(percentEncoded: false), &info) != 0 {
                if errno == ENOENT { continue }
                throw Failure("Cannot read the Trash: \(String(cString: strerror(errno))). Nothing deleted.")
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
                throw Failure("The Trash folder changed or is not yours; nothing deleted.")
            }
            let real = root.resolvingSymlinksInPath()
            allowed[real] = try stamp(real).identity
        }
        let urls = try selected ?? allowed.keys.sorted { $0.path < $1.path }.flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        var entries: [Entry] = []
        for url in urls.sorted(by: { $0.path.count < $1.path.count }) {
            guard url.isFileURL, ![".", ".."].contains(url.lastPathComponent) else {
                throw Failure("Only files in the Trash can be deleted immediately.")
            }
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let item = parent.appending(path: url.lastPathComponent).standardizedFileURL
            guard let root = allowed.keys.first(where: { item.path.hasPrefix($0.path + "/") }), let rootID = allowed[root] else {
                throw Failure("\(url.lastPathComponent) is not inside a recognized Trash folder; nothing deleted.")
            }
            if entries.contains(where: { item.path == $0.url.path || item.path.hasPrefix($0.url.path + "/") }) { continue }
            entries.append(Entry(url: item, root: root, parent: parent, rootID: rootID,
                                 parentID: try stamp(parent).identity, contents: try tree(item)))
        }
        return Plan(entries: entries)
    }

    /// Called only after confirmation of this exact plan. Recheck the whole group before deleting its first item.
    /// FileManager removes a symbolic link itself, not its target. Partial failures report how much was deleted.
    public static func perform(_ plan: Plan) throws -> Int {
        for entry in plan.entries { try check(entry) }
        var deleted = 0
        var failures: [String] = []
        for entry in plan.entries {
            do { try check(entry) } catch {
                failures.append("Stopped: \(error.localizedDescription)")
                break
            }
            do {
                try FileManager.default.removeItem(at: entry.url)
                deleted += 1
            } catch {
                failures.append("\(entry.url.lastPathComponent) may be partially deleted: \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw Failure("Permanently deleted \(deleted) complete \(deleted == 1 ? "item" : "items") of \(plan.count). \(failures.joined(separator: " ")) Locked or permission-protected items may need unlocking or administrator approval in Finder. This cannot be undone.")
        }
        return deleted
    }

    private static func check(_ entry: Entry) throws {
        guard try stamp(entry.root).identity == entry.rootID,
              entry.parent.resolvingSymlinksInPath().path == entry.parent.path,
              try stamp(entry.parent).identity == entry.parentID,
              try tree(entry.url) == entry.contents else {
            throw Failure("\(entry.url.lastPathComponent) or its folder changed since confirmation. Ask again.")
        }
    }

    /// Snapshot every descendant without following links. A deep edit or arrival refuses the whole folder.
    private static func tree(_ url: URL) throws -> [String: Stamp] {
        var pending = [url], contents: [String: Stamp] = [:]
        while let next = pending.popLast() {
            let info = try stamp(next)
            contents[next.path] = info
            if info.directory {
                pending += try FileManager.default.contentsOfDirectory(at: next, includingPropertiesForKeys: nil)
            }
        }
        return contents
    }

    private static func stamp(_ url: URL) throws -> Stamp {
        var info = Darwin.stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            throw Failure("Cannot read \(url.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        return Stamp(identity: FileOps.Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino),
                     directory: info.st_mode & S_IFMT == S_IFDIR,
                     modified: info.st_mtimespec, changed: info.st_ctimespec)
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
