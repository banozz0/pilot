import AppKit
import Clipboard
import ImageIO
import OSLog
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// Pilot's image viewer (Sven, 2026-11-12, Q158): PNG, JPEG, HEIC, GIF, WebP, TIFF and BMP open here from Finder, Open
/// With, a default Sven picked, `open -a Pilot`, Pilot Files, `pilot files open` and `pilot://view`. One window an open, on
/// a solid ground in the capture editor's look: fitted to the window, zoomed with a pinch, ⌘-scroll, ⌘+ ⌘− ⌘0 or a
/// double-click (100 %), Left and Right through the pictures opened together (several picked in Finder: only those, in
/// Finder's name order; one: its folder's), Space or Esc to close; Mark up opens the capture editor on it, whose Done
/// asks before it writes over the file (Save a copy is the default). Lean (story 142): one picture held, decoded at the
/// screen's size and read whole only for a press that needs it; the folder is a list of names.
@MainActor
enum ImageViewer {
    /// The open viewers. A picture already open in one comes to its front.
    private static var open: [ImageViewerPanel] = []
    /// False in tests and the sandbox: the panel is made, never ordered onto Sven's screen, and Pilot is not activated.
    static var onScreen = true
    static let log = Logger(subsystem: "dev.banozz.pilot", category: "viewer")
    static let sizeKey = "imageViewer.size"
    private static let sizeWatch = EditorLayout.watchSize(of: ImageViewerPanel.self, key: sizeKey)
    static let least = CGSize(width: 640, height: 420)

    static var openCount: Int { open.count }
    /// The open viewer's model showing `file`, for the pilot command and tests.
    static func model(showing file: URL) -> ImageViewerModel? { open.first { $0.model?.file == file.standardizedFileURL }?.model }

    /// The last open's window and when it came: LaunchServices may hand one Finder open of many pictures over in parts,
    /// each its own `application(_:open:)`, and parts within `batchWindow` of it join that window (Sven on build 2392, Q161:
    /// a window a picture, stacked).
    private static var lastOpen: (panel: ImageViewerPanel, at: Date)?
    static let batchWindow: TimeInterval = 0.5

    /// Opens `url` in a viewer, or brings the one showing it forward; nil when it is not a picture the viewer reads.
    @discardableResult
    static func show(_ url: URL) -> ImageViewerModel? { show([url]) }

    /// One open of `urls`: ONE viewer, stepping through just these pictures when there are several (their folder's when
    /// one). A part of the same open (within `batchWindow` of it) joins its window; a single picture already shown in a
    /// viewer brings that one forward; any other open gets a window of its own. Nil when none is a picture it reads.
    @discardableResult
    static func show(_ urls: [URL], now: Date = .now) -> ImageViewerModel? {
        var seen = Set<URL>()
        let files = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { ViewerImages.viewable($0) && FileManager.default.isReadableFile(atPath: $0.path) && seen.insert($0).inserted }
        guard let first = files.first else { return nil }
        if let last = lastOpen, now.timeIntervalSince(last.at) < batchWindow, let model = last.panel.model {
            model.add(files)
            lastOpen = (last.panel, now)
            return model
        }
        if files.count == 1, let panel = open.first(where: { $0.model?.file == first }), let model = panel.model {
            if onScreen { panel.makeKeyAndOrderFront(nil) }
            return model
        }
        _ = sizeWatch
        let look = Look.shared, tokens = look.chromeTokens(.hud)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let longest = Int(max(screen?.frame.width ?? 1440, screen?.frame.height ?? 900) * (screen?.backingScaleFactor ?? 2))
        let model = ImageViewerModel(files: files, longest: longest, backing: screen?.backingScaleFactor ?? 2)
        let size = EditorLayout.opening(room: screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900), least: least,
                                        saved: EditorLayout.saved(sizeKey))
        let panel = ImageViewerPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                     backing: .buffered, defer: false)
        panel.minSize = least
        panel.model = model
        model.close = { [weak panel] in if let panel { close(panel) } }
        // A solid ground, never Glass: what is behind the window must not show through round a picture (Q161).
        let host = NSHostingView(rootView: ImageViewerView(model: model).styled(.hud, look: look).pilotTheme(look: look))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.appearance = NSAppearance(named: tokens.dark ? .darkAqua : .aqua)
        if let f = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)) }
        open.append(panel)
        lastOpen = (panel, now)
        model.start()
        guard onScreen else { return model }
        NSApp.activate()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        log.notice("viewer open: \(files.count) picture(s) opened")
        return model
    }

    /// Mark-up wrote `written`: each viewer on its folder lists it again, and the one showing it reads it anew.
    static func changed(_ written: URL) {
        let file = written.standardizedFileURL, folder = file.deletingLastPathComponent()
        for panel in open {
            guard let model = panel.model, model.file.deletingLastPathComponent() == folder else { continue }
            model.relist(reload: model.file == file)
        }
    }

    static func closeAll() { open.forEach(close) }

    private static func close(_ panel: ImageViewerPanel) {
        panel.model?.stop()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.model = nil
        open.removeAll { $0 === panel }
        if lastOpen?.panel === panel { lastOpen = nil }
    }

    /// Mark up: the picture whole and upright in the capture editor, read off the main thread on the press; its Done asks
    /// before writing over the file (CaptureEditor.show's `original`).
    static func markUp(_ file: URL) async -> Bool {
        let read = await Task.detached(priority: .userInitiated) { ViewerImages.decode(file, longest: nil) }.value
        guard let read else { return false }
        CaptureEditor.show(read.image, scale: read.scale, file: file, capture: .shared, original: true)
        return true
    }
}

/// One viewer's state: the pictures it steps through (those opened together, else the folder's) by name, the one shown, its picture at screen size (or a frame of its
/// animation), and the zoom and pan, which follow the editor's rules (ZoomSteps: the fit up to actual size, 25 % steps to
/// 800 %).
@MainActor @Observable
final class ImageViewerModel {
    private(set) var files: [URL]
    private(set) var index: Int
    /// The pictures opened together, by name, when more than one was: Left and Right step through only these. Nil: the
    /// folder's pictures.
    @ObservationIgnored private var chosen: [URL]?
    /// The picture the last Move to Trash took, which an undo puts back among `chosen`.
    @ObservationIgnored private var trashed: URL?
    /// The picture shown, upright: the screen-size read (`base`), a sharper read while a zoom needs one, or an animation's
    /// frame; nil while it is read or unreadable.
    private(set) var image: CGImage?
    /// The file's own size in pixels, upright, and its points' scale from its DPI (100 % is one of its points a screen point).
    private(set) var pixels: CGSize = .zero
    private(set) var scale: CGFloat = 1
    private(set) var frames = 1
    /// Why the picture shows nothing: unreadable, or gone.
    private(set) var problem: String?
    /// The line at the bottom: what a press did; `undo` adds Undo after a Trash.
    private(set) var hint: String?
    private(set) var undo = false
    /// A press that reads the whole picture is running (Copy text).
    private(set) var busy = false

    private(set) var room: CGRect = .zero
    private(set) var zoom: CGFloat = 1
    private(set) var origin: CGPoint = .zero
    @ObservationIgnored private var fitted = true

    /// The screen's longest side in pixels, and its pixels a point: the viewer's decode size.
    @ObservationIgnored let longest: Int
    @ObservationIgnored let backing: CGFloat
    @ObservationIgnored var close: () -> Void = {}
    /// The screen-size read of the picture shown, which a zoom back to the fit returns to, letting a sharper read go.
    @ObservationIgnored private var base: CGImage?
    /// Each read's number: a read for a picture stepped past arrives late and is dropped.
    @ObservationIgnored private var reading = 0
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var sharpening: Task<Void, Never>?
    @ObservationIgnored private var animation: AnimationStop?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored var ops = FileOps.shared
    @ObservationIgnored var pasteboard: NSPasteboard = .general

    var file: URL { files.indices.contains(index) ? files[index] : files.first ?? URL(fileURLWithPath: "/") }
    /// The picture's size in points: what the zoom scales.
    var size: CGSize { CGSize(width: pixels.width / scale, height: pixels.height / scale) }

    init(files: [URL], longest: Int, backing: CGFloat) {
        let chosen = files.count > 1 ? WallpaperCycle.sortedByName(files) : nil
        self.chosen = chosen
        self.files = chosen ?? files
        self.index = (chosen ?? files).firstIndex(of: files[0]) ?? 0
        self.longest = longest
        self.backing = backing
    }

    /// The folder listed and the picture read, off the main thread, side by side.
    func start() {
        relist(reload: false)
        load()
    }

    /// Returns once the folder listing and the picture's read under way are done (the pilot command, tests).
    func settled() async {
        await listing?.value
        await read?.value
    }

    /// More pictures from the same open: the set grows to hold them, by name, the picture shown kept.
    func add(_ more: [URL]) {
        let set = WallpaperCycle.sortedByName(Array(Set((chosen ?? [file]) + more)))
        guard set != chosen else { return }
        chosen = set
        relist(reload: false)
    }

    /// Lists the pictures again (the ones opened together that are still there, else the folder's), keeping the picture
    /// shown (or the next one when it went); `reload` reads it again too.
    func relist(reload: Bool) {
        let current = file, chosen = chosen
        listing = Task {
            let listed = await Task.detached {
                chosen.map { $0.filter { FileManager.default.fileExists(atPath: $0.path) } } ?? ViewerImages.siblings(of: current)
            }.value
            guard current == file else { return }
            files = listed.isEmpty ? [current] : listed
            index = files.firstIndex(of: current) ?? min(index, files.count - 1)
            if reload { load() }
        }
    }

    // MARK: Reading

    /// Reads the picture shown at screen size, fits it to the room, then plays it when it has frames.
    func load() {
        stopAnimation()
        sharpening?.cancel()
        reading += 1
        let n = reading, url = file, longest = longest
        problem = nil
        read = Task {
            let read = await Task.detached(priority: .userInitiated) { ViewerImages.decode(url, longest: longest) }.value
            guard n == reading else { return }
            guard let read else {
                image = nil
                base = nil
                problem = FileManager.default.fileExists(atPath: url.path) ? "Pilot cannot read \(url.lastPathComponent)" : "\(url.lastPathComponent) is gone"
                return
            }
            (image, base, pixels, scale, frames) = (read.image, read.image, read.pixels, read.scale, read.frames)
            zoom(to: fit)
            if read.frames > 1 { animate(url) }
        }
    }

    /// Plays an animated GIF, WebP or PNG frame by frame through ImageIO, which reads each frame as it is due and calls
    /// the block on the main queue; stops when the picture changes or the window closes.
    private func animate(_ url: URL) {
        let stop = AnimationStop()
        animation = stop
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, frame, halt in
            if stop.stopped { halt.pointee = true; return }
            MainActor.assumeIsolated { self?.image = frame }
        }
    }

    private func stopAnimation() {
        animation?.stopped = true
        animation = nil
    }

    /// The window closed: the animation stops and the picture goes.
    func stop() {
        stopAnimation()
        sharpening?.cancel()
        reading += 1
        image = nil
        base = nil
        hintTask?.cancel()
    }

    /// Past the fit, one sharper read once the screen draws more pixels than the shown picture has (the last zoom of a
    /// pinch wins); back at the fit, the screen-size read again and the sharper one let go.
    private func sharpen() {
        sharpening?.cancel()
        guard frames == 1, let image, let base else { return }
        if fitted { if image !== base { self.image = base }; return }
        let needed = min(Int((max(size.width, size.height) * zoom * backing).rounded(.up)), Int(max(pixels.width, pixels.height)))
        guard needed > max(image.width, image.height) + 8 else { return }
        let n = reading, url = file
        sharpening = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let read = await Task.detached(priority: .userInitiated) { ViewerImages.decode(url, longest: needed) }.value
            guard !Task.isCancelled, n == reading, !fitted, let read else { return }
            self.image = read.image
        }
    }

    // MARK: Stepping

    var canStep: Bool { files.count > 1 }

    /// Left and Right: the folder's previous or next picture, round from the last to the first.
    func step(_ by: Int) {
        guard canStep else { return }
        index = (index + by + files.count) % files.count
        load()
    }

    // MARK: Zoom (ZoomSteps)

    var fit: CGFloat { EditorLayout.fit(size, inside: room.insetBy(dx: EditorLayout.margin, dy: EditorLayout.margin).size) }
    var canZoomIn: Bool { zoom < EditorLayout.zoomMost - 0.001 }
    var canZoomOut: Bool { zoom > fit + 0.001 }

    func setRoom(_ frame: CGRect) {
        guard frame != room else { return }
        room = frame
        zoom(to: fitted ? fit : zoom)
    }

    func zoom(to z: CGFloat, about anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: room.width / 2, y: room.height / 2)
        let next = min(EditorLayout.zoomMost, max(fit, z)), k = next / max(zoom, 0.001)
        fitted = next < fit + 0.001
        if next != zoom { zoom = next }
        pan(to: CGPoint(x: a.x - (a.x - origin.x) * k, y: a.y - (a.y - origin.y) * k))
        sharpen()
    }

    func fitToWindow() { zoom(to: fit) }

    /// A double-click: actual size about the click, or back to the fit from any zoom past it.
    func toggleZoom(about at: CGPoint) {
        if canZoomOut { zoom(to: fit) } else { zoom(to: max(1, fit * 2), about: at) }
    }

    func pan(by d: CGSize) { pan(to: CGPoint(x: origin.x + d.width, y: origin.y + d.height)) }

    private func pan(to o: CGPoint) {
        let next = EditorLayout.clamp(o, content: CGSize(width: size.width * zoom, height: size.height * zoom), room: room.size)
        if next != origin { origin = next }
    }

    // MARK: Presses

    /// Copy: the picture whole as PNG, and its own bytes under its own type when it is not a PNG (a GIF keeps its frames).
    func copy() {
        let url = file
        Task {
            let made = await Task.detached(priority: .userInitiated) { () -> (png: Data?, own: Data?, type: String?) in
                let own = try? Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.identifier
                // A PNG's own bytes are the PNG; any other type is read whole and encoded once.
                if type == UTType.png.identifier { return (own, nil, type) }
                let png = ViewerImages.decode(url, longest: nil).flatMap { PilotCapture.png($0.image, scale: $0.scale) }
                return (png, own, type)
            }.value
            guard made.png != nil || made.own != nil else { return say("\(url.lastPathComponent) could not be copied") }
            pasteboard.clearContents()
            if let png = made.png { pasteboard.setData(png, forType: .png) }
            if let own = made.own, let type = made.type { pasteboard.setData(own, forType: NSPasteboard.PasteboardType(type)) }
            say("Copied")
        }
    }

    /// Copy text: the picture whole read by pilot-text (CaptureText), only on this press; its lines go on the pasteboard.
    func copyText(reader: any LineReading = PilotCapture.shared.reader) {
        guard !busy else { return }
        busy = true
        let url = file
        Task {
            defer { busy = false }
            let read = await Task.detached(priority: .userInitiated) { ViewerImages.decode(url, longest: nil).map(Unchecked.init) }.value
            guard let read = read?.value, let lines = await CaptureText.read(read.image, scale: read.scale, with: reader) else {
                return say("The text could not be read")
            }
            guard !lines.isEmpty else { return say("No text found") }
            pasteboard.clearContents()
            pasteboard.setString(ReadLines.copied(lines), forType: .string)
            say(CaptureText.said(lines))
        }
    }

    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([file]) }

    func markUp() {
        let url = file
        Task { if await !ImageViewer.markUp(url) { say("Pilot cannot read \(url.lastPathComponent)") } }
    }

    /// Move to Trash, through FileOps' shared journal, so ⌘Z here and `pilot files undo` put it back alike; the next picture
    /// shows, and the window closes after the folder's last.
    func trash() {
        let url = file, ops = ops
        Task {
            do {
                _ = try await ops.perform(try await ops.plan(.trash([url])))
            } catch {
                // FileOps' refusal word for word (its message is the description).
                return say(error.localizedDescription)
            }
            files.removeAll { $0 == url }
            chosen?.removeAll { $0 == url }
            trashed = url
            guard !files.isEmpty else { return close() }
            index = min(index, files.count - 1)
            load()
            say("Moved \(url.lastPathComponent) to the Trash", undo: true)
        }
    }

    /// ⌘Z or Undo after a Trash: FileOps' last operation put back, and the picture shown again.
    func undoTrash() {
        guard undo else { return }
        let ops = ops
        Task {
            do {
                let done = try await ops.perform(try await ops.plan(.undo))
                ImageViewer.log.notice("viewer: undo put back \(done.items.count) item(s)")
            } catch {
                return say(error.localizedDescription)
            }
            undo = false
            if let back = trashed, chosen != nil { chosen = WallpaperCycle.sortedByName((chosen ?? []) + [back]) }
            trashed = nil
            relist(reload: false)
            say("Put back")
        }
    }

    func say(_ text: String, undo: Bool = false) {
        hint = text
        self.undo = undo
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo ? 8 : 2.5))
            guard !Task.isCancelled, let self else { return }
            self.hint = nil
            self.undo = false
        }
    }

    /// The panel's keys; true when one was used.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), plain = flags.isDisjoint(with: [.command, .control, .option])
        switch Int64(event.keyCode) {
        case 123 where plain: step(-1)
        case 124 where plain: step(1)
        case KeyCode.escape where plain, 49 where plain: close()
        case 51 where command, 117 where command: trash()
        default:
            guard command, let c = event.charactersIgnoringModifiers?.lowercased() else { return false }
            switch c {
            case "=", "+": zoomIn()
            case "-": zoomOut()
            case "0": fitToWindow()
            case "c": copy()
            case "z": undoTrash()
            case "a" where flags.contains(.shift): markUp()
            case "w": close()
            default: return false
            }
        }
        return true
    }
}

/// The flag an animation's frames check, set when its picture goes.
final class AnimationStop: @unchecked Sendable {
    var stopped = false
}

/// The viewer's panel, as the editor's (EditorPanel): it takes the keys without activating Pilot by itself and hands them to
/// the model; over the picture a pinch and ⌘-scroll zoom about the pointer, and a plain scroll moves a zoomed picture.
final class ImageViewerPanel: NSPanel, BorderedWindow {
    var model: ImageViewerModel?

    override var canBecomeKey: Bool { true }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model, MainActor.assumeIsolated({ model.key(event) }) { return }
        if event.type == .scrollWheel || event.type == .magnify, let model, let height = contentView?.bounds.height,
           MainActor.assumeIsolated({ model.zoom(event, at: CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)) }) { return }
        super.sendEvent(event)
    }
}
