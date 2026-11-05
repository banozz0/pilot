import AppKit
import Observation
import OSLog
import PilotCore
import UniformTypeIdentifiers

/// Tools › Captures › History's index (P73, after Snapzy): the app each capture and recording came from, noted as Pilot
/// saves it, in `capture-history.json`; the files themselves stay in the folders, which are the history. Local only.
/// Made on first use (a capture, the page, `pilot get`), so nothing loads at launch. The size cap (off by default) sends
/// Pilot's oldest captures and recordings to the Trash once the ones it made pass it, never deleting a file outright.
/// It also holds each area capture's grab (P77, CaptureGrab): the screen it was cut from, for uncrop, in memory only
/// (Sven, Q814), while its thumbnail or editor is up, and let go with the capture.
@Observable @MainActor
final class CaptureHistoryStore {
    static let shared = CaptureHistoryStore()

    /// Gigabytes Pilot's captures and recordings may take (CaptureHistory.caps); 0 keeps everything.
    var capGB: Int {
        didSet {
            defaults.set(capGB, forKey: Self.capKey)
            trimToCap()
        }
    }

    /// Bumped by every note and every file trashed, so an open History page lists again.
    private(set) var revision = 0
    @ObservationIgnored private var records: [CaptureHistory.Record]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: CaptureSettingsStore
    @ObservationIgnored private var trimming = false
    @ObservationIgnored private let trashItem: @Sendable (URL) throws -> Void
    /// The captures whose grab a thumbnail or an editor holds, and how many hold it.
    @ObservationIgnored private var holds: [URL: Int] = [:]
    /// The grabs held, in memory from the save until their last holder closes. Free: the capture's own picture is cut
    /// from the same still and keeps it alive anyway (CGImage cropping keeps its source).
    @ObservationIgnored private var grabs: [URL: CaptureGrab] = [:]

    static let capKey = "capture.historyCap"
    /// The newest notes kept; an older file still lists, without its app.
    static let most = 5_000
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "captures")

    init(file: URL = PilotFolder.support.appending(path: "capture-history.json"), defaults: UserDefaults = .pilot(),
         settings: CaptureSettingsStore = .shared,
         trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.file = file
        self.defaults = defaults
        self.settings = settings
        self.trashItem = trashItem
        records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([CaptureHistory.Record].self, from: $0) } ?? []
        capGB = defaults.integer(forKey: Self.capKey)
    }

    /// A file Pilot just saved, with the app in front (the one captured, as the overlay never takes the front).
    func note(_ url: URL, kind: CaptureKind, app: String? = NSWorkspace.shared.frontmostApplication?.localizedName) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        records.removeAll { $0.path == path }
        records.append(.init(path: path, kind: kind, app: app))
        if records.count > Self.most { records.removeFirst(records.count - Self.most) }
        save()
        revision += 1
        trimToCap()
    }

    /// A recording as it starts: an app's recording is that app's, a display's or an area's the app in front.
    func note(_ url: URL, recording source: RecordingSource) {
        if case .app(let pid, _) = source { note(url, kind: .recording, app: NSRunningApplication(processIdentifier: pid)?.localizedName) }
        else { note(url, kind: .recording) }
    }

    /// A picture Pilot made from a capture (the editor's Done or Save a copy, Combine, an upscale): the app of the file it
    /// came from, never the app in front, which is Pilot's editor by then; none for a picture made from no file. The
    /// editor's Done over a file Pilot neither named nor noted (a Screenshot or IMG of Sven's) is not noted, so it never
    /// comes under the size cap; the page still lists again.
    func note(_ url: URL, madeFrom original: URL?) {
        let path = url.standardizedFileURL.path(percentEncoded: false), from = (original ?? url).standardizedFileURL.path(percentEncoded: false)
        let noted = records.last { $0.path == from }
        if from == path, noted == nil, !CaptureHistory.isPilotName(url.lastPathComponent) { revision += 1; return }
        note(url, kind: .capture, app: noted?.app)
    }

    /// Finder's Resize and Upscale with Pilot write beside any picture: only a result in Pilot's captures folder is history.
    func noteResults(_ urls: [URL]) {
        let folder = settings.folder(.capture).standardizedFileURL
        for url in urls where url.deletingLastPathComponent().standardizedFileURL == folder { note(url, madeFrom: nil) }
    }

    /// Where a recording may be: the recordings folder and each folder Pilot noted one in (a folder changed since).
    func recordingFolders() -> [URL] {
        let noted = records.filter { $0.kind == .recording }.map { URL(filePath: $0.path).deletingLastPathComponent().standardizedFileURL }
        var seen = Set<URL>()
        return ([settings.folder(.recording).standardizedFileURL] + noted).filter { seen.insert($0).inserted }
    }

    /// Every capture and recording, newest first, read off the main thread; notes whose file is gone are let go.
    func entries() async -> [CaptureHistory.Entry] {
        let records = records, captures = settings.folder(.capture), recordings = settings.folder(.recording)
        let listed = await Task.detached(priority: .userInitiated) {
            CaptureHistory.entries(records: records, captures: captures, recordings: recordings)
        }.value
        let there = Set(listed.map(\.id)), scanned = Set(records.map(\.path))
        let kept = self.records.filter { there.contains($0.path) || !scanned.contains($0.path) }
        if kept.count != self.records.count {
            self.records = kept
            save()
        }
        return listed
    }

    /// Moves the files to the Trash, as Finder's Delete does; the number moved.
    @discardableResult
    func trash(_ urls: [URL]) async -> Int {
        let trashItem = trashItem
        let moved = await Task.detached(priority: .userInitiated) {
            urls.filter { url in
                do { try trashItem(url); return true }
                catch {
                    Self.log.error("history: not trashed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        }.value
        // A trashed capture's grab is let go (P77), whoever holds it.
        for url in moved { holds[url.standardizedFileURL] = nil; grabs[url.standardizedFileURL] = nil }
        // A trashed recording's pointer track goes with it (P71).
        let tracks = moved.filter(VideoEditor.isVideo).map { CursorTrack.file(for: $0, in: VideoEditor.pointerFolder) }
        // And its copy with the pointer drawn in (Q821).
        let videos = moved.filter(VideoEditor.isVideo)
        if !tracks.isEmpty { Task.detached(priority: .utility) { tracks.forEach { try? FileManager.default.removeItem(at: $0) }; RecordingHandout.forget(videos) } }
        let gone = Set(moved.map { $0.standardizedFileURL.path(percentEncoded: false) })
        records.removeAll { gone.contains($0.path) }
        save()
        revision += 1
        return moved.count
    }

    /// Past the cap, Pilot's oldest captures and recordings go to the Trash until the rest fit, never the newest, and
    /// never while a recording runs or its file is still being finished (Recorder.end goes idle before the file closes).
    /// Checked again after the scan and before each file, so a recording started or a cap changed meanwhile stops it.
    /// One trim at a time.
    func trimToCap() {
        guard capGB > 0, !trimming, !recording else { return }
        trimming = true
        let cap = capGB
        Task { @MainActor in
            defer { trimming = false }
            let over = CaptureHistory.overCap(await entries(), capBytes: cap * 1_000_000_000)
            var moved = 0
            for entry in over {
                guard capGB == cap, !recording else { break }
                moved += await trash([entry.url])
            }
            if !over.isEmpty { Self.log.notice("history: \(moved) of \(over.count) oldest moved to the Trash, over the \(cap) GB cap") }
        }
    }

    // MARK: Grabs (P77)

    /// Keeps the screen the capture just saved at `url` was cut from, for its thumbnail or editor to take up; any other
    /// grab nobody holds is let go, so no more are kept than the ones held (four thumbnails and the open editors) and
    /// this one.
    func keepGrab(_ grab: CaptureGrab, for url: URL) {
        grabs = grabs.filter { holds[$0.key] != nil }
        grabs[url.standardizedFileURL] = grab
    }

    /// A thumbnail or an editor showing the capture at `url`: its grab stays while one does.
    func holdGrab(_ url: URL?) {
        guard let url else { return }
        holds[url.standardizedFileURL, default: 0] += 1
    }

    /// A thumbnail or an editor of the capture at `url` closed: the last one to go lets its grab go (an editor opened
    /// from its thumbnail takes its hold first).
    func releaseGrab(_ url: URL?) {
        guard let key = url?.standardizedFileURL, let n = holds[key] else { return }
        guard n <= 1 else { holds[key] = n - 1; return }
        holds[key] = nil
        grabs[key] = nil
    }

    /// The capture at `url` was written over (the editor's Done): its grab is let go at once, whoever holds it, so no
    /// editor opens on a screen older than the file; the holds still count down as their holders close.
    func forgetGrab(_ url: URL) { grabs[url.standardizedFileURL] = nil }

    /// The grab held for the capture at `url`, nil with none: the editor is made on it.
    func grab(for url: URL?) -> CaptureGrab? { url.flatMap { grabs[$0.standardizedFileURL] } }

    /// A recording starting, running, paused or still closing its file (PilotApp's quit waits on the same).
    private var recording: Bool { Recorder.shared.isActive || Recorder.shared.closing != nil }

    /// Written whole off the main thread, atomically; at 5,000 notes about half a megabyte.
    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let file = file
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The file on the pasteboard as Finder copies it, and a picture's own bytes beside it, so an app that takes only
    /// pictures pastes it too; the bytes are read off the main thread. `file` stands in for the entry's own (a
    /// recording's copy with its pointer drawn in, Q821).
    static func copy(_ entry: CaptureHistory.Entry, file: URL? = nil, to pasteboard: NSPasteboard = .general) async {
        let url = file ?? entry.url
        let data = entry.kind == .capture ? await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value : nil
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let data { item.setData(data, forType: .init((UTType(filenameExtension: url.pathExtension) ?? .png).identifier)) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

/// Combine images (P73): the picked captures drawn into one picture (CombineLayout), at the first one's scale, gaps clear,
/// read and drawn off the main thread. Nil when a file could not be read.
enum CaptureCombine {
    static func combine(_ urls: [URL], direction: CombineLayout.Direction, gap points: CGFloat) async -> (CGImage, CGFloat)? {
        await Task.detached(priority: .userInitiated) { draw(urls, direction: direction, gap: points).map(Unchecked.init) }.value?.value
    }

    nonisolated static func draw(_ urls: [URL], direction: CombineLayout.Direction, gap points: CGFloat) -> (CGImage, CGFloat)? {
        let loaded = urls.compactMap(Pins.load)
        guard loaded.count == urls.count, let (_, scale) = loaded.first else { return nil }
        let (frames, size) = CombineLayout.layout(loaded.map { CGSize(width: $0.0.width, height: $0.0.height) }, direction: direction,
                                                  gap: points * scale)
        let space = loaded[0].0.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        for ((image, _), frame) in zip(loaded, frames) where frame != .zero {
            ctx.draw(image, in: CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height))
        }
        return ctx.makeImage().map { ($0, scale) }
    }
}
