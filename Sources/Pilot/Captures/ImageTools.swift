import AppKit
import CryptoKit
import ImageScale
import OSLog
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// Resize and Upscale (Sven, Q246-Q248): the capture editor's Image size chip and Upscale button, and Finder's Resize with
/// Pilot and Upscale with Pilot. A resize is vImage's Lanczos in Pilot, off the main thread, a second at most. An upscale is
/// Real-ESRGAN on Core ML in pilot-upscale, a child that exits after each image: the model, the Neural Engine's buffers and
/// a 4x image's pixels (about 260 MB for 1080p) leave with it, so Pilot's idle cost stays zero and nothing can stall the
/// tap; Cancel stops the child. Results go beside the original as "<name> 4x.png" (or "<name> 2560x1440.png" for a typed
/// size), never over a file.
@Observable @MainActor
final class UpscaleJob {
    enum Phase: Equatable {
        case idle
        case downloading
        /// The share of the whole run done, and which image it is on.
        case running(Double, String)
        case failed(String)
    }

    /// One image to upscale and where its result goes, "<stem> 4x.<ext>" in `folder`.
    struct Item: Equatable { let image: URL, folder: URL, stem: String }

    /// The size it makes of the image the panel opened on (`size(width:height:)`); several files change by its factor.
    var target = UpscaleTarget(width: 1, height: 1)
    var model: UpscaleModel = .general { didSet { ready = UpscaleModels.compiled(model) != nil } }
    var format: ImageFormat = .png
    private(set) var phase: Phase = .idle
    /// Whether the picked model is on this Mac (Max quality once downloaded): read when the pick changes and after a
    /// download, never in a view's body.
    private(set) var ready = UpscaleModels.compiled(.general) != nil
    @ObservationIgnored private var task: Task<Void, Never>?
    var busy: Bool { task != nil }

    /// Downloads Max quality if it is picked and missing, then upscales each item in turn; `finished` gets what was
    /// written, and the reason when a file failed. Nothing starts while a run is going.
    func start(_ items: [Item], finished: @escaping @MainActor (_ written: [URL], _ failure: String?) -> Void) {
        guard task == nil, !items.isEmpty else { return }
        let (target, model, format) = (target, model, format)
        task = Task { @MainActor in
            defer { task = nil }
            var written: [URL] = []
            do {
                let helper = try UpscaleModels.helper()
                if UpscaleModels.compiled(model) == nil, model.download != nil {
                    phase = .downloading
                    try await UpscaleModels.fetch(model, helper: helper)
                    ready = UpscaleModels.compiled(self.model) != nil
                }
                guard let path = UpscaleModels.compiled(model) else { throw UpscaleModels.Failure("The \(model.title) model is missing") }
                for (n, item) in items.enumerated() {
                    let label = items.count == 1 ? item.image.lastPathComponent : "\(n + 1) of \(items.count)"
                    phase = .running(Double(n) / Double(items.count), label)
                    guard let source = ImageFiles.size(item.image) else { throw UpscaleModels.Failure("Pilot cannot read \(item.image.lastPathComponent)") }
                    let (w, h) = target.applied(width: source.width, height: source.height)
                    let out = try await ChildProcess.run(helper, ["upscale", path.path, "\(w)", "\(h)", format.rawValue, item.image.path,
                                                                  item.folder.path, item.stem], timeout: .seconds(1800)) { line in
                        guard let (done, total) = Self.progress(line) else { return }
                        let share = (Double(n) + Double(done) / Double(total)) / Double(items.count)
                        Task { @MainActor [weak self] in if self?.task != nil { self?.phase = .running(share, label) } }
                    }
                    if let url = Self.written(out) { written.append(url) }
                }
                upscaleLog.notice("upscale: \(written.count) written, \(model.rawValue, privacy: .public) \(target.factor, format: .fixed(precision: 2))x")
                phase = .idle
                finished(written, nil)
            } catch let error where error is CancellationError || Task.isCancelled {
                // A cancelled download throws URLError's cancelled, not CancellationError.
                upscaleLog.notice("upscale: cancelled")
                phase = .idle
                finished(written, nil)
            } catch {
                upscaleLog.error("upscale: \(String(describing: error), privacy: .public)")
                let said = (error as? UpscaleModels.Failure)?.message ?? "The upscale failed"
                phase = .failed(said)
                finished(written, said)
            }
        }
    }

    func cancel() { task?.cancel() }

    /// The panel opens on an image of this size: the preset picked last stays picked, a typed size goes back to 4x.
    func size(width: Int, height: Int) {
        guard (width, height) != (target.originalWidth, target.originalHeight) else { return }
        target = UpscaleTarget(width: width, height: height, times: target.times ?? 4)
    }

    /// "progress 3 45" as (3, 45).
    nonisolated static func progress(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "progress", let done = Int(parts[1]), let total = Int(parts[2]), total > 0 else { return nil }
        return (done, total)
    }

    /// The file the helper says it wrote.
    nonisolated static func written(_ out: String) -> URL? {
        out.split(separator: "\n").last { $0.hasPrefix("wrote ") }.map { URL(filePath: String($0.dropFirst(6))) }
    }
}

/// Where the upscaler and its models are, and Max quality's one download.
enum UpscaleModels {
    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// Application Support/Pilot/Upscale: the downloaded models, compiled.
    static var folder: URL { PilotFolder.support.appending(path: "Upscale", directoryHint: .isDirectory) }

    /// The compiled model, nil while Max quality is not downloaded. General ships compiled in the bundle's Resources
    /// (Scripts/build-app.sh); without the bundle (swift run, the tests) there is none, as with pilot-text.
    static func compiled(_ model: UpscaleModel) -> URL? {
        let url = model == .general ? Bundle.main.resourceURL?.appending(path: "Upscale/\(model.compiledName)") : folder.appending(path: model.compiledName)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// pilot-upscale in the bundle.
    static func helper() throws -> String {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pilot-upscale").path
        guard FileManager.default.isExecutableFile(atPath: bundled) else {
            upscaleLog.notice("pilot-upscale not in the bundle")
            throw Failure("The upscaler is not in this build of Pilot")
        }
        return bundled
    }

    /// Fetches the model's zip from its pinned commit, checks its size and SHA-256 before anything reads it, unpacks it and
    /// compiles it once into `folder`; a failed or cancelled fetch leaves nothing behind.
    static func fetch(_ model: UpscaleModel, helper: String) async throws {
        guard let d = model.download else { return }
        upscaleLog.notice("upscale: downloading \(model.rawValue, privacy: .public), \(d.bytes) bytes")
        let (zip, _) = try await URLSession.shared.download(from: d.url)
        let work = FileManager.default.temporaryDirectory.appending(path: "pilot-upscale-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: zip); try? FileManager.default.removeItem(at: work) }
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == d.bytes, try await sha256(zip) == d.sha256 else {
            upscaleLog.error("upscale: \(model.rawValue, privacy: .public) download failed its check (\(size) bytes)")
            throw Failure("The download did not match its checksum")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await ChildProcess.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: .seconds(120))
        _ = try await ChildProcess.run(helper, ["compile", work.appending(path: d.package).path, folder.appending(path: model.compiledName).path],
                                       timeout: .seconds(600))
    }

    /// A file's SHA-256 in hex, read a megabyte at a time off the main thread.
    nonisolated static func sha256(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Finder's Resize with Pilot and Upscale with Pilot: a small panel over the front window, Pilot not activated, its
/// settings on it; the result lands beside each original and a tip offers Show.
@MainActor
enum ImageTools {
    enum Mode: Equatable { case resize, upscale }

    private static var panel: KeyPanel?
    /// False in tests: the panel is made, never ordered onto Sven's screen.
    static var onScreen = true
    /// The open panel's content, for tests.
    private(set) static var shown: ImageToolCard?

    /// The service's files, the images among them; nothing opens without one.
    static func offer(_ mode: Mode, _ urls: [URL], tip: @MainActor (String) -> Void = { HUD.tip($0) }) {
        let images = urls.filter { url in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }
        guard let first = images.first, let pixels = ImageFiles.size(first) else { return tip("Pilot cannot read that image") }
        close()
        let upscale = UpscaleJob()
        upscale.size(width: pixels.width, height: pixels.height)
        let card = ImageToolCard(mode: mode, files: images, target: ResizeTarget(width: pixels.width, height: pixels.height), job: upscale,
                                 resize: { target in resize(images, to: target) },
                                 upscale: {
                                     upscale.start(images.map { UpscaleJob.Item(image: $0, folder: $0.deletingLastPathComponent(), stem: $0.deletingPathExtension().lastPathComponent) }) { written, failure in
                                         if failure == nil { close() }
                                         report(written, failure: failure, verb: "Upscaled")
                                     }
                                 },
                                 cancel: { upscale.cancel(); close() })
        shown = card
        let p = HUD.makePanel(card)
        p.escape = { upscale.cancel(); close() }
        panel = p
        guard onScreen else { return }
        p.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        shown = nil
    }

    /// Each file resized by the target's factor, in its own format, as "<name> <w>x<h>.<ext>" beside it.
    static func resize(_ files: [URL], to target: ResizeTarget) {
        close()
        Task { @MainActor in
            let written = await Task.detached(priority: .userInitiated) {
                files.compactMap { url -> URL? in
                    guard let image = ImageFiles.load(url) else { return nil }
                    let (w, h) = target.applied(width: image.width, height: image.height)
                    let format = ImageFormat.of(url)
                    guard let out = Resample.image(image, width: w, height: h), let data = format.encode(out) else { return nil }
                    return ImageFiles.write(data, in: url.deletingLastPathComponent(), stem: url.deletingPathExtension().lastPathComponent,
                                            suffix: " \(w)x\(h)", ext: format.fileExtension)
                }
            }.value
            upscaleLog.notice("resize: \(written.count) of \(files.count) written")
            report(written, failure: written.count < files.count ? "Some images could not be resized" : nil, verb: "Resized")
        }
    }

    static func report(_ written: [URL], failure: String?, verb: String) {
        CaptureHistoryStore.shared.noteResults(written)
        let said = written.count == 1 ? "\(verb) to \(written[0].lastPathComponent)" : "\(verb) \(written.count) images"
        HUD.tip(failure.map { written.isEmpty ? $0 : "\(said). \($0)" } ?? said, seconds: 8,
                action: written.isEmpty ? nil : HUD.TipAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting(written) })
    }
}

let upscaleLog = Logger(subsystem: "dev.banozz.pilot", category: "upscale")
