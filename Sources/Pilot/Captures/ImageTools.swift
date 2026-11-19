import AppKit
import ImageScale
import ImageIO
import OSLog
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// Resize (Sven, Q246): the capture editor's Image size chip and Finder's Resize with Pilot. A resize is vImage's Lanczos
/// in Pilot, off the main thread, a second at most. Results go beside the original as "<name> <w>x<h>.<ext>", never over
/// a file.

/// Finder's Resize with Pilot: a small panel over the front window, Pilot not activated, its settings on it; the result
/// lands beside each original and a tip offers Show.
@MainActor
enum ImageTools {
    private static var panel: KeyPanel?
    /// False in tests: the panel is made, never ordered onto Sven's screen.
    static var onScreen = true
    /// The open panel's content, for tests.
    private(set) static var shown: ImageToolCard?

    /// The service's files, the images among them; nothing opens without one.
    static func offer(_ urls: [URL], tip: @MainActor (String) -> Void = { HUD.tip($0) }) {
        let images = urls.filter { url in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }
        guard let first = images.first, let pixels = ImageFiles.size(first) else { return tip("Pilot cannot read that image") }
        close()
        let card = ImageToolCard(files: images, target: ResizeTarget(width: pixels.width, height: pixels.height),
                                 resize: { target in resize(images, to: target) }, cancel: { close() })
        shown = card
        let p = HUD.makePanel(card.fixedSize())
        p.escape = { close() }
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
            imageToolsLog.notice("resize: \(written.count) of \(files.count) written")
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

let imageToolsLog = Logger(subsystem: "dev.banozz.pilot", category: "resize")
