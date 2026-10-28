import Clipboard
import Foundation
import ImageIO
import Observation
import OSLog
import PilotCore
import Synchronization

private let tlog = Logger(subsystem: "dev.banozz.pilot", category: "files")

/// Reads the words in Text in images' images into the text index (Homy-style Files, Sven 2026-10-12). A pass lists the
/// folders (png, jpg, heic, webp; the never-index list and bundle insides left out), drops the rows of images gone,
/// and reads only images new or changed since by path, size and modified time, newest first. The menu opening starts a
/// pass at most once in 5 minutes, and NSBackgroundActivityScheduler hourly. Vision reads in pilot-text's batch mode,
/// a child at background priority, so its memory leaves with it (story 142); one at a time, about 0.4 s an image.
/// The first full pass waits for external power: on battery until then only images newer than the index are read.
/// Low Power Mode or a serious thermal state stops a pass; the next one carries on where it stopped. Skipped: images
/// under 64×64 (icons) or over 50 MB, stored with no text, and iCloud-only files, which reading would download.
@Observable @MainActor
final class ImageTextReader {
    static let shared = ImageTextReader()

    nonisolated static let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    static let menuEvery: TimeInterval = 5 * 60
    nonisolated static let minPixels = 64
    nonisolated static let maxBytes: Int64 = 50 * 1024 * 1024

    /// Images read in the folders, and waiting to be read, as of the last pass: Text in images' count.
    private(set) var read = 0
    private(set) var waiting = 0

    /// What the Mac allows right now; the tests pass their own.
    struct Conditions: Sendable {
        var onPower = true
        var lowPower = false
        var hot = false

        /// No image is read: Low Power Mode, or a serious thermal state.
        var blocked: Bool { lowPower || hot }

        /// A Mac with no battery is always on power.
        static func now() -> Conditions {
            let info = ProcessInfo.processInfo
            return Conditions(onPower: SystemReader.battery()?.pluggedIn ?? true, lowPower: info.isLowPowerModeEnabled,
                              hot: info.thermalState == .serious || info.thermalState == .critical)
        }
    }

    @ObservationIgnored private let settings: ImageTextSettings
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let reading: any ImageTextReading
    @ObservationIgnored private let conditions: @Sendable () -> Conditions
    @ObservationIgnored private let fullDiskAccess: @Sendable () -> Bool
    @ObservationIgnored private let excluded: () -> [String]
    @ObservationIgnored private let dataless: @Sendable (String) -> Bool
    @ObservationIgnored private let home: String
    @ObservationIgnored private let hourly: Bool
    @ObservationIgnored private var index: ImageTextIndex?
    @ObservationIgnored private var pass: Task<Void, Never>?
    /// Counts the passes started, so a pass stopped by Clear or a settings change never touches the next one's state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastMenuPass: Date?
    /// Whether Pilot held Full Disk Access at the last pass, asked once at the first search before one ran. Without it no
    /// pass can see which images are gone (listing the folders would raise macOS's prompts), so the search finds none.
    @ObservationIgnored private var access: Bool?
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?

    static let standardFile = PilotFolder.support.appending(path: "image-text.sqlite")

    init(settings: ImageTextSettings = .shared, file: URL = ImageTextReader.standardFile,
         reading: any ImageTextReading = ImageTextReader.standardReading(),
         conditions: @escaping @Sendable () -> Conditions = Conditions.now,
         fullDiskAccess: @escaping @Sendable () -> Bool = FileIndex.hasFullDiskAccess,
         excluded: @escaping () -> [String] = { FileSearchSettings.shared.excluded },
         dataless: @escaping @Sendable (String) -> Bool = ImageTextReader.isDataless,
         home: String = NSHomeDirectory(), hourly: Bool = !isTestRun) {
        self.settings = settings
        self.file = file
        self.reading = reading
        self.conditions = conditions
        self.fullDiskAccess = fullDiskAccess
        self.excluded = excluded
        self.dataless = dataless
        self.home = home
        self.hourly = hourly
    }

    /// pilot-text's batch mode when the bundle holds it, else Vision in this process (swift run), as HelperText does.
    static func standardReading() -> any ImageTextReading {
        if FileManager.default.isExecutableFile(atPath: HelperText.bundled.path) { return BatchText(helper: HelperText.bundled.path) }
        return RecognizerText(recognizer: VisionText())
    }

    /// The Hyper+Space menu opened: a pass unless one ran in the last 5 minutes, and the hourly pass set up. The pass
    /// started, nil when none was.
    @discardableResult
    func menuOpened(now: Date = Date()) -> Task<Void, Never>? {
        guard settings.enabled else { return nil }
        scheduleHourly()
        if let lastMenuPass, now.timeIntervalSince(lastMenuPass) < Self.menuEvery { return nil }
        lastMenuPass = now
        return start()
    }

    /// Text in images changed: switched off clears the index and stops reading; otherwise a pass reads the folders
    /// as they are now.
    func settingsChanged() {
        guard settings.enabled else { return clear() }
        stopPass()
        start()
    }

    /// Stops reading and deletes the index file: Clear text index, and Text in images switched off.
    func clear() {
        stopPass()
        scheduler?.invalidate()
        scheduler = nil
        lastMenuPass = nil
        index = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        read = 0
        waiting = 0
        tlog.notice("image text: index cleared")
    }

    /// The images whose words hold every typed word, at most `limit`: none while Text in images is off.
    func search(_ typed: String, limit: Int = 10) -> [ImageTextHit] {
        if access == nil { access = fullDiskAccess() }
        guard settings.enabled, access == true, let index = openIndex() else { return [] }
        do { return try index.search(typed, limit: limit) } catch {
            tlog.error("image text search: \(Self.logged(error), privacy: .public)")
            return []
        }
    }

    /// Starts a pass unless one runs; the running one otherwise.
    @discardableResult
    func start() -> Task<Void, Never> {
        if let pass { return pass }
        generation += 1
        let mine = generation
        let task = Task {
            await runPass(mine)
            if self.generation == mine { self.pass = nil }
        }
        pass = task
        return task
    }

    /// A stopped pass's late progress and index are dropped: the generation moved on.
    private func stopPass() {
        pass?.cancel()
        pass = nil
        generation += 1
    }

    /// The access check, the index's opening and the pass run off the main thread, which the tap runs on.
    private func runPass(_ mine: Int) async {
        guard settings.enabled else { return }
        let job = Pass(index: index, file: file, fullDiskAccess: fullDiskAccess, folders: settings.paths, excluded: excluded(),
                       dataless: dataless, home: home, reading: reading, conditions: conditions) { [weak self] read, waiting in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.read = read
                self.waiting = waiting
            }
        }
        let work = Task.detached(priority: .background) { await job.run() }
        let (opened, access) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard generation == mine else { return }
        self.access = access
        if index == nil { index = opened }
    }

    private func openIndex() -> ImageTextIndex? {
        if let index { return index }
        do { index = try ImageTextIndex(file: file) } catch {
            tlog.error("image text index: \(Self.logged(error), privacy: .public)")
        }
        return index
    }

    private func scheduleHourly() {
        guard hourly, scheduler == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.banozz.pilot.image-text")
        scheduler.repeats = true
        scheduler.interval = 60 * 60
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] done in
            Task { @MainActor in
                await self?.start().value
                done(.finished)
            }
        }
        self.scheduler = scheduler
    }

    /// One pass, off the main thread.
    private struct Pass: Sendable {
        /// The open index, else its file to open.
        let index: ImageTextIndex?
        let file: URL
        let fullDiskAccess: @Sendable () -> Bool
        let folders: [String]
        let excluded: [String]
        let dataless: @Sendable (String) -> Bool
        let home: String
        let reading: any ImageTextReading
        let conditions: @Sendable () -> Conditions
        let progress: @Sendable (Int, Int) -> Void

        /// The index it read into, nil when it opened none, and whether Pilot holds Full Disk Access. A pass stopped by
        /// Clear or a settings change writes nothing more and never makes the file again: cancellation is checked
        /// before the file is opened and before each write.
        func run() async -> (ImageTextIndex?, Bool) {
            guard fullDiskAccess() else {
                tlog.notice("image text: no Full Disk Access yet, so no image is read")
                return (index, false)
            }
            var opened = index
            do {
                try Task.checkCancellation()
                let index = try self.index ?? ImageTextIndex(file: file)
                opened = index
                let listed = ImageTextReader.list(folders, excluded: excluded, home: home, dataless: dataless)
                // Images gone leave the search on every pass, Low Power Mode too (acceptance check 2).
                let known = try index.entries()
                try Task.checkCancellation()
                try index.remove(known.keys.filter { listed[$0] == nil })
                let now = conditions()
                guard !now.blocked else {
                    tlog.notice("image text: Low Power Mode or hot, so no image is read")
                    return (index, true)
                }
                let pending = listed.filter { $0.value.entry != known[$0.key] }
                let readable = pending.filter { !$0.value.dataless }
                // Before the first full pass is done, battery reads only images newer than the index; a full pass stops
                // when the Mac is unplugged.
                let firstPassDone = index.firstPassDone, created = index.created, full = now.onPower || firstPassDone
                let allowed = full ? readable : readable.filter { $0.value.entry.modified >= created }
                // Unchanged images count as read; `done` counts this pass's.
                let unchanged = listed.count - pending.count
                var done = 0
                progress(unchanged, readable.count)
                let newest = allowed.sorted { $0.value.entry.modified > $1.value.entry.modified }
                let skipped = newest.filter { ImageTextReader.skips($0.key, size: $0.value.entry.size) }
                try Task.checkCancellation()
                try index.set(skipped.map { ($0.key, $0.value.entry, "") })
                done += skipped.count
                progress(unchanged + done, readable.count - done)
                let left = Set(skipped.map(\.key))
                let queue = newest.map(\.key).filter { !left.contains($0) }
                var readNow = 0
                for try await (path, text) in reading.read(queue) {
                    guard let found = allowed[path] else { continue }
                    try Task.checkCancellation()
                    try index.set([(path, found.entry, text)])
                    readNow += 1
                    done += 1
                    progress(unchanged + done, readable.count - done)
                    let now = conditions()
                    if now.blocked || (full && !firstPassDone && !now.onPower) { break }
                }
                if !Task.isCancelled, allowed.count == readable.count, readNow == queue.count { index.firstPassDone = true }
                tlog.info("image text: \(listed.count, privacy: .public) images, \(readable.count - done, privacy: .public) waiting")
            } catch is CancellationError {
            } catch {
                tlog.error("image text pass: \(ImageTextReader.logged(error), privacy: .public)")
            }
            return (opened, true)
        }
    }

    struct Listed: Sendable {
        let entry: ImageTextIndex.Entry
        let dataless: Bool
    }

    /// The images in `folders`, by path: hidden files, bundle insides and the never-index list (`node_modules`, or a
    /// path in home written `~/Library`) left out, a folder on it or inside one too.
    nonisolated static func list(_ folders: [String], excluded: [String], home: String,
                                 dataless: (String) -> Bool = isDataless) -> [String: Listed] {
        let names = Set(excluded.filter { !$0.contains("/") }), paths = Set(excluded.filter { $0.hasPrefix("~/") })
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var found: [String: Listed] = [:]
        for folder in folders where !leftOut(folder, excluded: excluded, home: home) {
            guard let walk = FileManager.default.enumerator(at: URL(filePath: folder), includingPropertiesForKeys: Array(keys),
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                let path = url.path(percentEncoded: false)
                if values.isDirectory == true {
                    if names.contains(url.lastPathComponent) || FileExclusions.entry(path, home: home).map(paths.contains) == true {
                        walk.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, kinds.contains(url.pathExtension.lowercased()),
                      let modified = values.contentModificationDate else { continue }
                found[path] = Listed(entry: .init(size: Int64(values.fileSize ?? 0), modified: modified), dataless: dataless(path))
            }
        }
        return found
    }

    /// Whether a folder is on the never-index list or inside a folder that is: `~/Library/Caches`, `~/x/node_modules/y`.
    nonisolated static func leftOut(_ folder: String, excluded: [String], home: String) -> Bool {
        var path = folder
        while path.hasPrefix(home + "/") {
            if let entry = FileExclusions.entry(path, home: home), excluded.contains(entry) { return true }
            if excluded.contains((path as NSString).lastPathComponent) { return true }
            path = (path as NSString).deletingLastPathComponent
        }
        return false
    }

    /// An iCloud-only file: reading it would download it.
    nonisolated static func isDataless(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// An error as the log may show it: a child's exit status, never its output, which holds screenshots' words (a
    /// child killed by a signal leaves stderr empty, so ChildProcess.Failure carries its stdout).
    nonisolated static func logged(_ error: any Error) -> String {
        switch error {
        case let failure as ChildProcess.Failure: "\(failure.tool) exited \(failure.status)"
        case let timedOut as ChildProcess.TimedOut: timedOut.description
        case let sqlite as ImageTextIndex.Failure: "\(sqlite)"
        default: "\(type(of: error))"
        }
    }

    /// Whether an image is left unread: over 50 MB, under 64×64 pixels, or no image ImageIO can size.
    nonisolated static func skips(_ path: String, size: Int64) -> Bool {
        guard size <= maxBytes else { return true }
        guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return true }
        return width < minPixels || height < minPixels
    }
}

/// Reads images' text, one at a time, in the order given: each path with what it holds as it is read. Ending the
/// stream early stops the reading.
protocol ImageTextReading: Sendable {
    func read(_ paths: [String]) -> AsyncThrowingStream<(String, String), any Error>
}

/// pilot-text's batch mode, a child for every 100 images so Vision's memory never builds up: paths in on stdin as JSON
/// lines, a JSON line out per image. Five minutes for its first image (Vision compiles its model on a new build's
/// first, 60 to 85 s on 2026-10-11), 10 s for each after it, before it is stopped. A child that fails or is stopped
/// gives the image it was on with no text, so that image is stored and never retried before older ones, then ends
/// the stream with its error; the next pass carries on after it.
struct BatchText: ImageTextReading {
    static let chunk = 100
    let helper: String

    struct Line: Codable {
        let path: String
        let text: String
    }

    func read(_ paths: [String]) -> AsyncThrowingStream<(String, String), any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for start in stride(from: 0, to: paths.count, by: Self.chunk) {
                    let chunk = paths[start..<min(start + Self.chunk, paths.count)]
                    let encoder = JSONEncoder()
                    var input = Data()
                    for path in chunk { if let line = try? encoder.encode(path) { input += line + Data("\n".utf8) } }
                    let answered = Mutex(0)
                    do {
                        _ = try await ChildProcess.run(helper, ["batch"], input: input, timeout: .seconds(300 + 10 * chunk.count)) { line in
                            guard let read = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return }
                            answered.withLock { $0 += 1 }
                            continuation.yield((read.path, read.text))
                        }
                    } catch {
                        if !(error is CancellationError) {
                            let at = chunk.startIndex + answered.withLock { $0 }
                            tlog.error("pilot-text batch: \(ImageTextReader.logged(error), privacy: .public)")
                            if at < chunk.endIndex { continuation.yield((chunk[at], "")) }
                        }
                        return continuation.finish(throwing: error)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reads in this process with a TextRecognizing: Vision under swift run, a fake in the tests.
struct RecognizerText: ImageTextReading {
    let recognizer: any TextRecognizing

    /// Each image is read when the pass asks for it, so a pass that stops reads none ahead.
    func read(_ paths: [String]) -> AsyncThrowingStream<(String, String), any Error> {
        let next = Mutex(0)
        return AsyncThrowingStream { [recognizer] in
            let at = next.withLock { n in defer { n += 1 }; return n }
            guard at < paths.count, !Task.isCancelled else { return nil }
            let path = paths[at]
            let text = if let data = try? Data(contentsOf: URL(filePath: path)) { await recognizer.text(in: data) } else { "" }
            return (path, text)
        }
    }
}
