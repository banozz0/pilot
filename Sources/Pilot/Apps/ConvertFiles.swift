import AppKit
import OSLog
import PilotCore

/// Convert's ways in (card agent-bo-95423211, story 139): Finder's Convert with Pilot… and a file row's Convert to…
/// open the menu's picker on the formats the files share; a format waiting for ffmpeg or cwebp offers Install's confirm
/// step instead. One conversion runs at a time, off the main thread, under a progress tip with Cancel; Convert asked for
/// again meanwhile brings that tip back, so Cancel is never lost to Escape or another tip (Moody Q_vGXHee5vE). The
/// finished tip offers Reveal.
@MainActor
enum ConvertFiles {
    typealias Start = @MainActor (_ urls: [URL], _ format: ConvertFormat, _ converter: Converter) -> Void
    static var job: Task<Void, Never>?
    private(set) static var progressText = ""
    private static var progressTip: TipModel?
    /// Shows a lasting tip and returns it; tests swap in one that shows nothing.
    static var showLasting: @MainActor (String, HUD.TipAction) -> TipModel? = { HUD.tip($0, seconds: .infinity, action: $1); return HUD.tipModel }

    static func offer(_ urls: [URL], converter: Converter = .installed(), pick: FileActions.Pick = FileActions.menuPick,
                      install: @escaping @MainActor (String) -> Void = { InstallModule.pick($0) }, start: @escaping Start = { ConvertFiles.start($0, to: $1, with: $2) },
                      tip: @MainActor (String) -> Void = { HUD.tip($0) }) {
        guard let first = urls.first else { return }
        guard job == nil else { return showProgress() }
        let options = converter.options(for: urls)
        guard !options.isEmpty else {
            return tip(urls.count == 1 ? "Pilot cannot convert \(first.lastPathComponent)" : "These files have no format in common to convert to")
        }
        let rows = Convert.rows(options)
        pick(rows, "Convert \(urls.count == 1 ? first.lastPathComponent : "\(urls.count) files") to") { row in
            guard let option = rows.firstIndex(of: row).map({ options[$0] }) else { return }
            if let tool = option.needs, let package = tool.package {
                convertLog.notice("convert: \(option.format.title, privacy: .public) needs \(tool.rawValue, privacy: .public), offering Install")
                install(package.key)
            } else {
                start(urls, option.format, converter)
            }
        }
    }

    /// Converts under the progress tip; Cancel stops the file in hand, keeping the ones finished. The run it returns
    /// answers the outcome, which `pilot convert` waits on (CLI W13); nil when every file is already in the format.
    @discardableResult
    static func start(_ urls: [URL], to format: ConvertFormat, with converter: Converter) -> Task<ConvertBatch.Outcome, Never>? {
        let batch = ConvertBatch(urls, to: format)
        guard !batch.urls.isEmpty else { HUD.tip(batch.summary(.init())); return nil }
        convertLog.notice("convert: \(batch.urls.count) to \(format.title, privacy: .public)")
        progressText = batch.progress(0)
        showProgress()
        let run = Task { await batch.run(with: converter) { done in updateProgress(batch.progress(done)) } }
        job = Task {
            defer { job = nil; progressTip = nil }
            let outcome = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
            if outcome.cancelled { convertLog.notice("convert: cancelled") }
            outcome.failed.forEach { convertLog.error("convert: \($0.0.path, privacy: .public) failed, \($0.1, privacy: .public)") }
            let written = outcome.written
            HUD.tip(batch.summary(outcome), seconds: 8,
                    action: written.isEmpty ? nil : HUD.TipAction(title: "Reveal") { NSWorkspace.shared.activateFileViewerSelecting(written) })
        }
        return run
    }

    /// The running job's progress tip, shown again with its Cancel.
    static func showProgress() {
        progressTip = showLasting(progressText, HUD.TipAction(title: "Cancel") { job?.cancel() })
    }

    /// The next file's line, on the progress tip while it is still the one up.
    static func updateProgress(_ text: String) {
        progressText = text
        if let progressTip { HUD.updateTip(text, on: progressTip) }
    }
}

/// Pilot's services (Info.plist NSServices), NSApp's one services provider: Finder's Convert with Pilot… hands the files
/// on its pasteboard to the picker, anything else there left out; Fix with Pilot, on selected text anywhere, gives the
/// text back fixed by Quick AI (QuickFix), and the app puts it over the selection; Ask Pilot AI hands the text to the
/// selection box and returns at once (no return type: the app would wait, spinning, while Sven reads the answer); Read
/// Aloud with Pilot hands the text to Read aloud (story 190), the same way; Resize with Pilot and Upscale with Pilot hand
/// Finder's images to their panel (Q247).
final class PilotServices: NSObject {
    private let offer: @MainActor ([URL]) -> Void
    private let fix: @MainActor (String) -> String?
    private let ask: @MainActor (String) -> Void
    private let read: @MainActor (String) -> Void
    private let images: @MainActor (ImageTools.Mode, [URL]) -> Void

    init(offer: @escaping @MainActor ([URL]) -> Void = { ConvertFiles.offer($0) },
         fix: @escaping @MainActor (String) -> String? = { QuickFix.shared.fixForService($0) },
         ask: @escaping @MainActor (String) -> Void = { SelectionBox.shared.open(service: $0) },
         read: @escaping @MainActor (String) -> Void = { ReadAloud.shared.read(service: $0) },
         images: @escaping @MainActor (ImageTools.Mode, [URL]) -> Void = { ImageTools.offer($0, $1) }) {
        self.offer = offer
        self.fix = fix
        self.ask = ask
        self.read = read
        self.images = images
    }

    /// The pasteboard's text, or nil with `missing` as the service's error when it has none but whitespace.
    private func text(_ pasteboard: NSPasteboard, _ error: AutoreleasingUnsafeMutablePointer<NSString?>, missing: String) -> String? {
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = missing as NSString
            return nil
        }
        return text
    }

    @MainActor @objc func askText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        text(pasteboard, error, missing: "No text selected").map(ask)
    }

    @MainActor @objc func readText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        text(pasteboard, error, missing: "No text selected").map(read)
    }

    @MainActor @objc func fixText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = text(pasteboard, error, missing: "No text to fix") else { return }
        guard let fixed = fix(text) else {
            error.pointee = "Not fixed"
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(fixed, forType: .string)
    }

    @MainActor @objc func resizeImages(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        files(pasteboard, error, missing: "No images").map { images(.resize, $0) }
    }

    @MainActor @objc func upscaleImages(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        files(pasteboard, error, missing: "No images").map { images(.upscale, $0) }
    }

    /// The pasteboard's files, anything else there left out, or nil with `missing` as the service's error when it has none.
    private func files(_ pasteboard: NSPasteboard, _ error: AutoreleasingUnsafeMutablePointer<NSString?>, missing: String) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = missing as NSString
            convertLog.error("services: no files on the pasteboard")
            return nil
        }
        convertLog.notice("services: \(urls.count) files")
        return urls
    }

    @MainActor @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        files(pasteboard, error, missing: "No files to convert").map(offer)
    }
}

private let convertLog = Logger(subsystem: "dev.banozz.pilot", category: "convert")
