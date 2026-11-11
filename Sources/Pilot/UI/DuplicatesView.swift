import AppKit
import Observation
import PilotCore
import SwiftUI

/// Files › Duplicates (Homy-style Files, T5): identical files and the space they take. Scan runs only when pressed,
/// never on its own; each group keeps one copy, picked by `keeper` and changed with its Keep, and Move to Trash asks
/// once with the count and size before moving the rest. Nothing is deleted: Finder's Put Back returns any of them.
/// A copy inside a package (an .rtfd, an iMovie or Photos library) is the package's own, so it is never listed.
@Observable @MainActor
final class DuplicatesModel {
    /// `moving`: the Trash is taking the extras; Scan, Keep and Move to Trash wait for it.
    enum State: Equatable { case ready, scanning, noAccess, stopped, scanned, moving }

    /// Identical files, with the copy kept; `id` is its place in the scan, kept while copies leave it.
    struct Group: Identifiable, Equatable {
        let id: Int
        var size: Int64
        var files: [FileSearch.Hit]
        var kept: String
        var extras: [FileSearch.Hit] { files.filter { $0.path != kept } }
    }

    typealias Scan = (@escaping (DuplicateScan.Result) -> Void) -> Void
    typealias Recycle = ([URL]) async throws -> Void

    private(set) var state = State.ready
    private(set) var groups: [Group] = []
    /// Groups the scan left out past the 200 that free the most.
    private(set) var more = 0
    /// Move to Trash's question is up.
    var asking = false
    /// The last move: files moved and bytes they took.
    private(set) var moved: (files: Int, bytes: Int64)?
    private(set) var problem: String?

    @ObservationIgnored private let scanner: Scan
    @ObservationIgnored private let recycle: Recycle

    init(scan: @escaping Scan = { FileIndex.shared.scanDuplicates(reply: $0) },
         recycle: @escaping Recycle = { _ = try await NSWorkspace.shared.recycle($0) }) {
        self.scanner = scan
        self.recycle = recycle
    }

    /// The copy a group keeps unless Sven picks another (Q48): the shortest name, then the shallowest folder, then the
    /// oldest, then the path, so a scan run twice keeps the same one.
    static func keeper(_ files: [FileSearch.Hit]) -> String {
        func rank(_ hit: FileSearch.Hit) -> (Int, Int, Date, String) {
            let url = URL(fileURLWithPath: hit.path)
            return (url.lastPathComponent.count, url.pathComponents.count, hit.edited ?? .distantFuture, hit.path)
        }
        return files.min { rank($0) < rank($1) }?.path ?? ""
    }

    /// Every copy but the kept ones.
    var extras: [FileSearch.Hit] { groups.flatMap(\.extras) }
    /// What moving the extras frees.
    var freed: Int64 { groups.reduce(0) { $0 + $1.size * Int64($1.extras.count) } }

    func scan() {
        guard state != .scanning, state != .moving else { return }
        state = .scanning
        moved = nil
        problem = nil
        scanner { [weak self] result in self?.scanned(result) }
    }

    private func scanned(_ result: DuplicateScan.Result) {
        switch result {
        case .found(let scan):
            var packages: [String: Bool] = [:]
            groups = scan.groups
                .map { group in group.files.filter { !Self.insidePackage($0.path, known: &packages) } }
                .enumerated()
                .compactMap { i, files in
                    files.count > 1 ? Group(id: i, size: scan.groups[i].size, files: files, kept: Self.keeper(files)) : nil
                }
            more = scan.more
            state = .scanned
        case .noAccess: state = .noAccess
        case .stopped: state = .stopped
        }
    }

    /// Whether a folder above the file is a package Finder shows as one file; each folder asked once a scan.
    static func insidePackage(_ path: String, known: inout [String: Bool]) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        guard folder != path, folder != "/", !folder.isEmpty else { return false }
        if let package = known[folder] { return package }
        let package = NSWorkspace.shared.isFilePackage(atPath: folder) || insidePackage(folder, known: &known)
        known[folder] = package
        return package
    }

    func keep(_ path: String, in group: Group.ID) {
        guard state == .scanned, let i = groups.firstIndex(where: { $0.id == group }), groups[i].files.contains(where: { $0.path == path }) else { return }
        groups[i].kept = path
    }

    /// Move to Trash pressed: the question goes up when there is something to move.
    func askToTrash() { asking = state == .scanned && !extras.isEmpty }

    /// Whether a file is still as the scan read it: a plain file of the group's size, modified the same second. A file
    /// changed since may no longer be a copy.
    static func unchanged(_ hit: FileSearch.Hit, size: Int64) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: hit.path), a[.type] as? FileAttributeType == .typeRegular,
              (a[.size] as? NSNumber)?.int64Value == size, let edited = hit.edited, let modified = a[.modificationDate] as? Date
        else { return false }
        return Int(modified.timeIntervalSince1970) == Int(edited.timeIntervalSince1970)
    }

    /// The question answered yes: each group's extras go to the Trash, but only while its kept copy is unchanged since
    /// the scan, so no group loses its last copy, and only the extras unchanged too. Files gone since leave their
    /// groups; a group down to one copy leaves the list.
    func confirmTrash() async {
        asking = false
        guard state == .scanned else { return }
        state = .moving
        defer { state = .scanned }
        let fm = FileManager.default
        // Each group's extras to move, with the group's size at hand for what they free.
        let moving = groups.map { group -> (size: Int64, files: [FileSearch.Hit]) in
            let kept = group.files.first { $0.path == group.kept }.map { Self.unchanged($0, size: group.size) } ?? false
            return (group.size, kept ? group.extras.filter { Self.unchanged($0, size: group.size) } : [])
        }
        let paths = Set(moving.flatMap { $0.files.map(\.path) })
        let stayed = extras.filter { fm.fileExists(atPath: $0.path) && !paths.contains($0.path) }.count
        problem = stayed == 0 ? nil
            : "\(stayed == 1 ? "1 copy" : "\(stayed) copies") stayed: a file changed since the scan. Scan again to check them."
        if !paths.isEmpty {
            do { try await recycle(paths.sorted().map { URL(fileURLWithPath: $0) }) } catch { problem = error.localizedDescription }
        }
        // Only what Pilot sent and is gone counts as moved, not a file Sven moved himself since the scan.
        let gone = moving.map { ($0.size, $0.files.filter { !fm.fileExists(atPath: $0.path) }.count) }
        let count = gone.reduce(0) { $0 + $1.1 }
        moved = count == 0 ? nil : (count, gone.reduce(0) { $0 + $1.0 * Int64($1.1) })
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { !fm.fileExists(atPath: $0.path) }
            guard group.files.count > 1 else { return nil }
            if !group.files.contains(where: { $0.path == group.kept }) { group.kept = Self.keeper(group.files) }
            return group
        }
    }
}

struct DuplicatesView: View {
    @Environment(\.ink) private var ink
    @State var model = DuplicatesModel()
    /// The rows' pictures, dropped with the page.
    @State private var thumbnails = FileThumbnails()

    static let intro = "Identical files in your home folder. Nothing moves until you say so."
    static let introInfo = "Found by their contents. Hidden files, what is inside apps, libraries and other packages, git repos and the never-index list are left out."

    var body: some View {
        KitPage(intro: Self.intro, info: Self.introInfo) {
            KitBlock(title: "Duplicates", symbol: "doc.on.doc", trailing: { scanButton }) { summary }
            ForEach(model.groups) { group in
                KitBlock(title: "\(Self.bytes(group.size)) · \(group.files.count) copies") {
                    // Identical copies look alike: one thumbnail a group, and only for as many groups as the cache
                    // holds, so the rows never take turns evicting each other's.
                    let picture = group.id < FileThumbnails.limit ? group.files.first?.path : nil
                    ForEach(Array(group.files.enumerated()), id: \.element.path) { i, file in
                        row(file, in: group, first: i == 0, picture: picture.flatMap(thumbnails.image))
                    }
                }
            }
        }
        .confirmationDialog(Text(Self.question(model.extras.count, model.freed)), isPresented: $model.asking) {
            Button("Move to Trash", role: .destructive) { Task { await model.confirmTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One copy of each stays. Finder's Put Back returns any of them; the space comes back when the Trash is emptied.")
        }
    }

    static func bytes(_ n: Int64) -> String { RemoveList.size(n) }

    static func question(_ files: Int, _ bytes: Int64) -> String {
        "Move \(ExtensionsPageView.plural(files, "file")) (\(Self.bytes(bytes))) to the Trash?"
    }

    private var scanButton: some View {
        Button(model.state == .scanned ? "Scan again" : "Scan") { model.scan() }
            .buttonStyle(.pilot)
            .disabled(model.state == .scanning || model.state == .moving)
    }

    @ViewBuilder private var summary: some View {
        BlockRow(first: true) {
            switch model.state {
            case .ready:
                note("Scan reads only the files that share a size with another; a first scan of a full home folder takes a minute or two.")
            case .scanning:
                ProgressView().controlSize(.small)
                note("Reading the files that share a size…")
            case .noAccess:
                note("Pilot needs Full Disk Access to read your files.")
                Spacer()
                Button("Allow…") { AppWindowController.shared.open(.permissions) }.buttonStyle(.pilot)
            case .stopped:
                note("The scan stopped before it finished. Scan again to start over.")
            case .scanned where model.groups.isEmpty:
                note("No duplicates found.")
            case .scanned, .moving:
                let extras = model.extras.count
                TitledText(title: Text("\(Self.bytes(model.freed)) to free").font(ink.ui(13.5, .semibold)),
                           detail: "\(ExtensionsPageView.plural(model.groups.count, "group")), \(extras) \(extras == 1 ? "copy" : "copies") to move")
                    .padding(.vertical, 6)
                Spacer()
                if model.state == .moving { ProgressView().controlSize(.small) }
                InfoMark(text: "Keeps the copy marked Kept in each group and moves the others, after asking; Finder's Put Back returns them.")
                Button("Move to Trash…") { model.askToTrash() }.buttonStyle(.pilotDestructive).disabled(extras == 0 || model.state == .moving)
            }
        }
        if let moved = model.moved {
            BlockRow { note("Moved \(ExtensionsPageView.plural(moved.files, "file")) to the Trash, \(Self.bytes(moved.bytes)).") }
        }
        if let problem = model.problem {
            BlockRow { Text(problem).font(ink.ui(12)).foregroundStyle(ink.yellow) }
        }
        if model.more > 0 {
            BlockRow { note("Showing the \(model.groups.count) groups that free the most; \(model.more) more after these are cleared.") }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
    }

    private func row(_ file: FileSearch.Hit, in group: DuplicatesModel.Group, first: Bool, picture: NSImage?) -> some View {
        let kept = file.path == group.kept
        let url = URL(fileURLWithPath: file.path)
        let folder = AppConfigs.tilde(url.deletingLastPathComponent().path, home: NSHomeDirectory())
        // With the year: the oldest copy is the one kept, and copies are often years apart.
        let date = file.edited.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return BlockRow(first: first) {
            Image(nsImage: picture ?? AppsModule.icon(file: file.path))
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
            TitledText(title: Text(url.lastPathComponent).font(ink.ui(13)), detail: folder + date)
                .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.keep(file.path, in: group.id) } label: {
                Label(kept ? "Kept" : "Keep this", systemImage: kept ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.pilot)
            .disabled(model.state == .moving)
            .help(kept ? "This copy stays" : "Keep this copy instead; the others go to the Trash")
            .accessibilityLabel(kept ? "Kept: \(url.lastPathComponent)" : "Keep \(url.lastPathComponent) instead")
        }
    }
}
