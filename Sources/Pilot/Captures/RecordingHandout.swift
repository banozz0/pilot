import AVFoundation
import CoreImage
import OSLog
import PilotCore
import UniformTypeIdentifiers
import os

/// The file Pilot hands out for a recording (Sven, Q821): a new recording keeps the pointer out of its pixels (T29), so
/// every place that gives one away (the thumbnail's Copy, drag and Save As, After capture › Copy, History's Copy, a
/// file's Copy file, a drag from Gallery or a folder widget) gives a version with the pointer drawn in instead. It is a
/// quick export through VideoRender with the recording's own pointer settings (`CursorTrack.look`), kept beside the
/// recording in a hidden `.Pilot pointer` folder under the recording's own name, so a pasted or dropped file is named as
/// the recording is. It is made again once the recording or its track is newer, and is deleted when the recording goes
/// to the Trash (CaptureHistoryStore.trash, FileActions.trash); each export also sweeps the folder of copies whose
/// recording is gone (deleted or renamed outside Pilot) and of part files no export is writing. History's size cap counts
/// the copy with its recording (CaptureHistory.entries). A drawn copy carries `markName`, so a copy handed out again (one
/// pasted under the recording's name elsewhere) goes as it is, never with a second pointer. An older recording, or one
/// whose track is lost, hands out the raw file as before. Show in Finder shows the recording.
@MainActor
enum RecordingHandout {
    nonisolated static let markName = "dev.banozz.pilot.pointer-drawn"
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "recording")
    /// False in tests: the progress tip is never put on Sven's screen.
    static var tips = true

    /// One export under way, shared by everyone waiting on the same recording, with its progress. Only a hand-out's own
    /// Cancel stops it; a waiter that goes away leaves it running for the rest.
    @MainActor
    private final class Bake {
        var task: Task<URL, Error>?
        var listeners: [UUID: (Double) -> Void] = [:]

        func heard(_ p: Double) { listeners.values.forEach { $0(p) } }
    }

    private static var bakes: [URL: Bake] = [:]
    /// The part files exports are writing now, by path: a sweep leaves these alone.
    private nonisolated static let writing = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Where the drawn copy of `recording` is kept.
    nonisolated static func cached(for recording: URL) -> URL { CaptureHistory.drawnCopy(of: recording) }

    /// The file to hand out for `file`: `file` itself unless it is a recording with a drawn track (in `pointers`), else
    /// its drawn copy, made now when there is none or it is older than the recording or the track. `progress` hears 0 to
    /// 1 while an export runs, and nothing when none does. A failed export hands out the raw file. An export another
    /// hand-out cancelled is started again for this one when `restart` (a hand-out's), else this one stops too (the
    /// thumbnail's draw ahead); otherwise only cancelling this one throws.
    static func file(for file: URL, pointers: URL = VideoEditor.pointerFolder, priority: TaskPriority = .userInitiated,
                     restart: Bool = true, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard VideoEditor.isVideo(file) else { return file }
        let key = file.standardizedFileURL
        while true {
            try Task.checkCancellation()
            let bake = bakes[key] ?? start(key, pointers: pointers, priority: priority)
            let id = UUID()
            if let progress { bake.listeners[id] = progress }
            defer { bake.listeners[id] = nil }
            guard let task = bake.task else { return file }
            do { return try await task.value } catch where restart { continue }
        }
    }

    /// Whether an export of `file` is under way.
    static func drawing(_ file: URL) -> Bool { bakes[file.standardizedFileURL] != nil }

    private static func start(_ file: URL, pointers: URL, priority: TaskPriority) -> Bake {
        let made = Bake()
        let task = Task.detached(priority: priority) {
            try await draw(file, pointers: pointers) { p in Task { @MainActor in made.heard(p) } }
        }
        made.task = task
        bakes[file] = made
        Task { @MainActor in
            _ = try? await task.value
            if bakes[file] === made { bakes[file] = nil }
        }
        return made
    }

    /// Stops the export under way for `file` and lets it go, so the next hand-out starts a new one: a hand-out's Cancel.
    static func stop(_ file: URL) {
        let key = file.standardizedFileURL
        bakes[key]?.task?.cancel()
        bakes[key] = nil
    }

    /// The drawn copy of `file`, made when needed; `file` when it needs none (an older recording, or a copy already
    /// drawn), when the export failed, or when the recording went while it was drawn (its copy is not kept). Throws only
    /// when cancelled.
    nonisolated static func draw(_ file: URL, pointers: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if marked(file) { return file }
        let trackFile = CursorTrack.file(for: file, in: pointers)
        guard let track = CursorTrack.load(for: file, in: pointers), track.drawn else { return file }
        let out = cached(for: file), folder = out.deletingLastPathComponent()
        if fresh(out, after: [file, trackFile]) { return out }
        let part = folder.appending(path: ".part-\(UUID().uuidString).\(file.pathExtension)", directoryHint: .notDirectory)
        let partPath = part.path(percentEncoded: false)
        writing.withLock { _ = $0.insert(partPath) }
        defer { writing.withLock { _ = $0.remove(partPath) } }
        sweep(folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var edit = VideoEdit(duration: try await asset.load(.duration).seconds)
            edit.pointer = track.look ?? PointerLook()
            let started = Date()
            try await VideoExport.run(asset, edit: edit, pointer: track, picture: nil, format: .h264, size: .full, to: part, progress: progress)
            try Task.checkCancellation()
            mark(part)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: part, to: out)
            // Trashed or deleted while it was drawn: the sweep takes its copy too.
            sweep(folder)
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
                log.notice("hand-out: \(file.lastPathComponent, privacy: .public) went while its pointer was drawn")
                return file
            }
            log.notice("hand-out: pointer drawn into \(file.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            return out
        } catch {
            try? FileManager.default.removeItem(at: part)
            if Task.isCancelled { throw CancellationError() }
            log.error("hand-out: the pointer was not drawn into \(file.lastPathComponent, privacy: .public), the raw file goes: \(String(describing: error), privacy: .public)")
            return file
        }
    }

    /// `folder` (a `.Pilot pointer` folder) without the copies whose recording beside it is gone, and without the part
    /// files no export is writing (an export cancelled hard, or Pilot quit mid-export).
    nonisolated static func sweep(_ folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        let parent = folder.deletingLastPathComponent(), busy = writing.withLock { $0 }
        for name in names {
            let url = folder.appending(path: name, directoryHint: .notDirectory)
            let gone = name.hasPrefix(".part-") ? !busy.contains(url.path(percentEncoded: false))
                : !fm.fileExists(atPath: parent.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false))
            if gone { try? fm.removeItem(at: url) }
        }
    }

    /// Whether `file` is a copy Pilot already drew the pointer into.
    nonisolated static func marked(_ file: URL) -> Bool {
        getxattr(file.path(percentEncoded: false), markName, nil, 0, 0, 0) >= 0
    }

    nonisolated static func mark(_ file: URL) {
        _ = setxattr(file.path(percentEncoded: false), markName, "1", 1, 0, 0)
    }

    /// Whether `cache` exists and is no older than each of `sources` that exists.
    nonisolated static func fresh(_ cache: URL, after sources: [URL]) -> Bool {
        func date(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let made = date(cache) else { return false }
        return sources.allSatisfy { source in date(source).map { $0 <= made } ?? true }
    }

    /// The drawn copy of each recording in `urls` deleted: they went to the Trash. Off the main thread: a copy is large.
    nonisolated static func forget(_ urls: [URL]) {
        for url in urls where VideoEditor.isVideo(url) { try? FileManager.default.removeItem(at: cached(for: url)) }
    }

    /// A drag of any file: a recording's drawn copy when it is ready; else, when it has a drawn track and is not a drawn
    /// copy itself, a file the drop waits on while the copy is drawn; else the file itself (no recording, or an older one).
    static func provider(for recording: URL, pointers: URL = VideoEditor.pointerFolder) -> NSItemProvider {
        guard VideoEditor.isVideo(recording) else { return NSItemProvider(contentsOf: recording) ?? NSItemProvider() }
        let trackFile = CursorTrack.file(for: recording, in: pointers), cache = cached(for: recording)
        let tracked = !marked(recording) && CursorTrack.load(for: recording, in: pointers)?.drawn == true
        if !tracked || (bakes[recording.standardizedFileURL] == nil && fresh(cache, after: [recording, trackFile])) {
            return NSItemProvider(contentsOf: tracked ? cache : recording) ?? NSItemProvider()
        }
        let provider = NSItemProvider()
        provider.suggestedName = recording.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: recording.pathExtension) ?? .movie
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let done = Unchecked(done)
            Task { @MainActor in
                // Never cancelled, so this is the drawn copy unless drawing failed.
                let file = (try? await RecordingHandout.file(for: recording, pointers: pointers)) ?? recording
                done.value(file, false, nil)
            }
            return nil
        }
        return provider
    }

    /// One hand-out under its progress tip: Cancel stops it and the file it is drawing now.
    @MainActor
    final class Job {
        var task: Task<Void, Never>?
        /// The file being drawn now.
        var current: URL?

        func cancel() {
            task?.cancel()
            if let current { RecordingHandout.stop(current) }
        }
    }

    /// `files` handed to `give` once each is ready to hand out: at once when none needs drawing, else under a lasting
    /// tip with the export's progress and Cancel. Each hand-out is its own: a second press never stops the first. Cancel
    /// stops this one and its export, and hands out nothing.
    @discardableResult
    static func handOut(_ files: [URL], pointers: URL = VideoEditor.pointerFolder, then give: @escaping @MainActor ([URL]) -> Void) -> Job {
        let job = Job()
        let task = Task { @MainActor in
            var tip: TipModel?
            var out: [URL] = []
            do {
                for file in files {
                    job.current = file
                    out.append(try await self.file(for: file, pointers: pointers) { p in
                        guard tips else { return }
                        let text = "Drawing the pointer into \(file.deletingPathExtension().lastPathComponent) · \(Int((p * 100).rounded())) %"
                        if let tip { HUD.updateTip(text, on: tip) } else {
                            HUD.tip(text, seconds: .infinity, action: HUD.TipAction(title: "Cancel") { job.cancel() })
                            tip = HUD.tipModel
                        }
                    })
                    try Task.checkCancellation()
                }
            } catch {
                log.notice("hand-out: cancelled")
                if let tip, HUD.tipModel === tip { HUD.dismissTip() }
                return
            }
            if let tip, HUD.tipModel === tip { HUD.dismissTip() }
            guard !Task.isCancelled else { return log.notice("hand-out: cancelled") }
            give(out)
        }
        job.task = task
        return job
    }

    /// The thumbnail's Ask AI on a recording: `poster` (its frame at `t`) with the pointer drawn in as the hand-out draws
    /// it, or `poster` as it is when the recording has no drawn track.
    static func frame(_ poster: CGImage, of recording: URL, at t: Double = VideoEditor.posterTime, pointers: URL = VideoEditor.pointerFolder) async -> CGImage {
        let still = Unchecked(poster)
        let ring = CursorEffectColours.of(Look.shared.themeID)
        return await Task.detached(priority: .userInitiated) { () -> CGImage in
            let poster = still.value
            guard !marked(recording), let track = CursorTrack.load(for: recording, in: pointers), track.drawn else { return poster }
            var edit = VideoEdit(duration: t + 1)
            edit.pointer = track.look ?? PointerLook()
            let size = CGSize(width: poster.width, height: poster.height)
            let plan = VideoPlan(edit: edit, pointer: track, source: size, exported: false, picture: nil, fine: true, ring: ring)
            let drawn = plan.frame(CIImage(cgImage: poster), at: t)
            return VideoPlan.context().createCGImage(drawn, from: CGRect(origin: .zero, size: size)) ?? poster
        }.value
    }
}
