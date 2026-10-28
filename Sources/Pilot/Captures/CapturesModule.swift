import Foundation
import OSLog
import PilotCore

let clog = Logger(subsystem: "dev.banozz.pilot", category: "captures")

/// Captures through Pilot's own capture (PilotCapture, spec `capture.html`); screen recording (Hyper+Shift+A) is Pilot's
/// own recorder (story 192).
@MainActor
enum CapturesModule {
    static func register(into registry: inout ActionRegistry) {
        // The capture keys (SPEC.md story 25): Hyper+S area, A full screen, D scrolling, X OCR; Hyper+Shift+S the window
        // (spec `capture.html`, free on 2026-10-16).
        capture(&registry, "area", "Capture area", Key("s"), .area)
        capture(&registry, "fullscreen", "Capture full screen", Key("a"), .fullScreen)
        capture(&registry, "scrolling", "Capture scrolling", Key("d"), .scroll)
        capture(&registry, "ocr", "Capture text", Key("x"), .ocr)
        capture(&registry, "activeWindow", "Capture a window", Key("s", .shift), .window)
        capture(&registry, "screenRecording", "Screen recording", Key("a", .shift), .record)
        add(&registry, "editLast", "Edit the last capture", Key("e", .alt)) { DispatchQueue.main.async { editLast() } }
        add(&registry, "pinLast", "Pin the last capture", nil) { DispatchQueue.main.async { pinLast() } }
        // P71: pick a recording and open it in the video editor (the Captures menu's Edit video…).
        add(&registry, "editVideo", "Edit video…", nil) { DispatchQueue.main.async { VideoEditor.pick() } }
        add(&registry, "toggleDesktopIcons", "Hide desktop icons in captures", nil) { DispatchQueue.main.async { toggleDesktopIcons() } }
        add(&registry, "restoreThumbnail", "Show the last thumbnail again", nil) {
            DispatchQueue.main.async { if !CaptureThumbnails.restore() { HUD.tip("No thumbnail to show again yet.") } }
        }
        capture(&registry, "repeatArea", "Capture the last area again", Key("s", .alt), .repeatArea)
        capture(&registry, "scrollingUp", "Capture scrolling, upward", nil, .scrollUp)
        capture(&registry, "delayed", "Capture after a delay", nil, .delayed)
        // P72, after Snapzy's; no key in either preset.
        capture(&registry, "smartElement", "Capture a UI element", nil, .smartElement)
        capture(&registry, "subject", "Capture a subject", nil, .subject)
        capture(&registry, "markup", "Capture and mark up", nil, .markup)
        // Q369: the one colour picker, on the key the System colour picker it replaced had (RetiredActions).
        capture(&registry, "pickColour", "Pick a colour with the magnifier", Key("c", shift: true), .colour)
        // Toolbox for Mac's QR tools (Q386), in Trigger beside the colour picker; no key in either preset. Both reads
        // open the drag-an-area snip, never the clipboard (Sven, Build 82).
        add(&registry, "makeQR", "Make a QR code", nil) { DispatchQueue.main.async { QRCodes.make() } }
        capture(&registry, "readQR", "Read a QR code", nil, .qr)
        capture(&registry, "readQRScreen", "Read QR on screen", nil, .qr)
        add(&registry, "pauseRecording", "Pause or resume the recording", Key("a", .alt)) {
            DispatchQueue.main.async { Recorder.shared.pauseOrResume() }
        }
        // The menu's Trigger → Capture (story 25), on the key Omarchy's keymap gives the capture menu.
        add(&registry, "menu", "Capture menu", Key("c", .ctrl)) { PilotMenu.shared.toggle(branch: .capture) }
    }

    /// A PilotCapture request, run after the tap's callback: a capture reads the screen and writes files.
    private static func capture(_ registry: inout ActionRegistry, _ id: String, _ label: String, _ key: Key?, _ request: PilotCapture.Request) {
        add(&registry, id, label, key) { DispatchQueue.main.async { PilotCapture.shared.run(request) } }
    }

    private static func add(_ registry: inout ActionRegistry, _ id: String, _ label: String, _ key: Key?,
                            run: @escaping @Sendable @MainActor () -> Void) {
        do { try registry.register(Action(id: "captures.\(id)", label: label, module: .captures, defaultKey: key, run: run)) }
        catch { clog.error("captures.\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    /// Desktop icons out of captures and recordings, or back in them (Q189); the desktop itself never changes.
    static func toggleDesktopIcons() {
        let store = CaptureSettingsStore.shared
        store.settings.hideDesktopIcons.toggle()
        HUD.tip(store.settings.hideDesktopIcons ? "Desktop icons are left out of captures and recordings." : "Desktop icons are in captures again.")
    }

    /// Whether a file the menu lists is one of Pilot's captures, which Return opens in the editor (CP10).
    static func isCapture(_ path: String) -> Bool {
        let folder = CaptureSettingsStore.shared.folder(.capture).standardizedFileURL.path(percentEncoded: false)
        let file = URL(filePath: path).standardizedFileURL
        return file.deletingLastPathComponent().path(percentEncoded: false) == folder && ["png", "jpg", "jpeg"].contains(file.pathExtension.lowercased())
    }

    /// Opens a capture file in the editor, its scale from its DPI; Done writes back over it.
    static func edit(_ path: String) {
        Task { @MainActor in if await !open(URL(filePath: path)) { HUD.tip("That capture could not be opened.") } }
    }

    /// A capture file in the editor, read off the main thread; false when it could not be read.
    static func open(_ url: URL) async -> Bool {
        let loaded = await Task.detached { Pins.load(url).map(Unchecked.init) }.value
        guard let (image, scale) = loaded?.value else { return false }
        CaptureEditor.show(image, scale: scale, file: url, capture: PilotCapture.shared)
        return true
    }

    /// The capture just taken in the editor (Sven on build 54: with thumbnails it no longer opens on its own): the newest
    /// thumbnail on screen, else the newest capture in the captures folder.
    static func editLast() {
        Task { @MainActor in
            if await !editLast(in: CaptureSettingsStore.shared.folder(.capture)) { HUD.tip("No capture to edit yet.") }
        }
    }

    /// False when there is no thumbnail up and no capture in `folder`; the file is found and read off the main thread.
    static func editLast(in folder: URL) async -> Bool {
        if CaptureThumbnails.editNewest() { return true }
        guard let file = await Task.detached(operation: { Pins.newestFile(in: folder) }).value else { return false }
        return await open(file)
    }

    /// The newest capture in the captures folder, pinned over every window (CP9); read off the main thread.
    static func pinLast() {
        let folder = CaptureSettingsStore.shared.folder(.capture)
        Task { @MainActor in
            let newest = await Task.detached { Pins.newest(in: folder).map(Unchecked.init) }.value
            guard let (image, scale) = newest?.value else { return HUD.tip("No capture to pin yet.") }
            Pins.pin(image, scale: scale)
        }
    }
}
