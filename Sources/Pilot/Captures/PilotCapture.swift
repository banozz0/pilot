import Clipboard
import AppKit
import ImageIO
import ImageScale
import Observation
import OSLog
import PilotCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The capture settings, saved as they change: the engine the capture keys use and the two folders (Q157, Q163).
@Observable @MainActor
final class CaptureSettingsStore {
    static let shared = CaptureSettingsStore()

    var settings: CaptureSettings { didSet { save() } }
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "capture.settings"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(CaptureSettings.self, from: $0) } ?? .default
    }

    func folder(_ kind: CaptureKind) -> URL { settings.folder(kind) }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}

/// Pilot's own capture (spec `capture.html` CP2, CP3): a press grabs every display at once through ScreenCaptureKit,
/// then full screen saves the one under the pointer, while area and window lay the frozen stills out to pick from. The
/// result is copied and saved to the captures folder. Nothing here asks Screen Recording, or its state, before a press
/// (ADR 0012, amended 2026-10-16). Every capture logs how long the grab and the overlay took, the targets being 17 ms and
/// 165 ms.
@MainActor
final class PilotCapture {
    static let shared = PilotCapture()

    /// `qr` is Read a QR code's screen area (QRCodes): Capture text's overlay, its codes shown in a panel.
    enum Request: String { case area, window, fullScreen, record, scroll, scrollUp, ocr, qr, repeatArea, delayed, smartElement, subject, markup, colour }

    let grabber: any ScreenGrabbing
    let store: CaptureSettingsStore
    private let defaults: UserDefaults
    /// The image and file a capture produced; the app copies, saves and tips, a test records.
    var deliver: @MainActor (CGImage, CGFloat) -> Void
    /// Says what happened in one line; the app's HUD tip.
    var tell: @MainActor (String, HUD.TipAction?) -> Void
    /// Where a capture or a colour is copied; a test's own board.
    var pasteboard: NSPasteboard = .general
    /// Reads text and codes (Hyper+X, the editor's Read text); a fake in tests.
    var reader: any LineReading = CaptureText.standard
    /// Cuts the subject out (Capture subject, P72); a fake in tests.
    var subjects: any SubjectCutting = CaptureText.subjects
    private(set) var overlay: CaptureOverlay?
    /// False in tests: the overlay is made, never put on Sven's screen.
    var overlaysVisible = true
    /// How long a grab may take before the press is given up, so a hung ScreenCaptureKit never leaves the keys dead.
    var grabTimeout: Duration = .seconds(5)
    /// A delayed capture's tick (CP10); a test's is short.
    var delayStep: Duration = .seconds(1)
    /// The delayed capture counting down, which its key again cancels.
    private(set) var counting: Task<Void, Never>?
    private static let lastAreaKey = "capture.lastArea"

    /// The last area captured, on its display, kept across launches: Hyper+Alt+S takes it again.
    var lastArea: LastArea? {
        get { defaults.data(forKey: Self.lastAreaKey).flatMap { try? JSONDecoder().decode(LastArea.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.lastAreaKey) }
    }
    /// Records what the overlay picks for Hyper+Shift+A (story 192).
    let recorder: Recorder
    private var grabbing = false
    /// Which press is grabbing; a grab that answers after its press was given up is dropped.
    private var attempt = 0
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "captures")
    private static let askedKey = "capture.askedScreenRecording"

    init(grabber: any ScreenGrabbing = SCScreenGrabber(), store: CaptureSettingsStore = .shared, defaults: UserDefaults = .pilot(),
         recorder: Recorder = .shared,
         deliver: (@MainActor (CGImage, CGFloat) -> Void)? = nil,
         tell: @escaping @MainActor (String, HUD.TipAction?) -> Void = { HUD.tip($0, seconds: $1 == nil ? 3 : 8, action: $1) }) {
        self.grabber = grabber
        self.store = store
        self.recorder = recorder
        self.defaults = defaults
        self.tell = tell
        self.deliver = { _, _ in }
        self.deliver = deliver ?? { [unowned self] image, scale in Task { await self.saveAndEdit(image, scale: scale) } }
    }

    /// A capture key pressed. A second press while the overlay shows closes it, so a key never leaves it up; the record
    /// key while a recording runs or counts down stops it. `taken` runs once a full screen's still is grabbed (the
    /// keyboard lock's Screenshot, whose screen hides the thumbnail).
    func run(_ request: Request, taken: (@MainActor () -> Void)? = nil) {
        if let overlay { return overlay.close() }
        if request == .record, recorder.isActive { return recorder.stop() }
        if request == .scroll || request == .scrollUp, let scrolling { return scrolling.end() }
        if request == .scroll || request == .scrollUp { scrollingUp = request == .scrollUp }
        if request == .ocr || request == .qr { readingCodes = request == .qr }
        if request == .delayed { return delayed() }
        if request == .repeatArea, lastArea == nil { return tell("No area captured yet: drag one with Hyper+S first.", nil) }
        guard !grabbing, permitted() else { return }
        // A tip still showing (the last capture's, a countdown's) is not part of the screen Sven means to capture.
        HUD.dismissTip()
        grabbing = true
        attempt += 1
        let mine = attempt, start = ContinuousClock.now
        Task { @MainActor [grabTimeout] in
            try? await Task.sleep(for: grabTimeout)
            guard grabbing, attempt == mine else { return }
            Self.log.error("capture \(request.rawValue, privacy: .public): the grab took over \(Self.ms(grabTimeout), privacy: .public) ms, given up")
            attempt += 1
            grabbing = false
            tell("The screen did not answer. Press again.", nil)
        }
        Task { @MainActor in
            do {
                let grabs = try await grabber.displays()
                guard attempt == mine else { return }
                defer { grabbing = false }
                let grabbed = ContinuousClock.now - start
                guard !grabs.isEmpty else { return tell("Nothing to capture: no display answered.", nil) }
                if request == .repeatArea, let last = lastArea {
                    // The same rectangle on the same display; the display under the pointer when that one is gone.
                    let grab = grabs.first { $0.id == last.display } ?? Self.underPointer(grabs)
                    Self.log.notice("capture repeatArea: grab \(Self.ms(grabbed), privacy: .public) ms")
                    return finish(.area(grab, last.rect.intersection(CGRect(origin: .zero, size: grab.frame.size))))
                }
                if request == .fullScreen {
                    let grab = Self.underPointer(grabs)
                    Self.log.notice("capture fullScreen: grab \(Self.ms(grabbed), privacy: .public) ms")
                    deliver(grab.image, grab.scale)
                    taken?()
                    return
                }
                let windows = (try? await grabber.windows()) ?? []
                show(grabs, windows: windows, mode: request == .window ? .window : .area, purpose: Self.purpose(request),
                     smart: request == .smartElement)
                Self.log.notice("capture \(request.rawValue, privacy: .public): grab \(Self.ms(grabbed), privacy: .public) ms, shown \(Self.ms(ContinuousClock.now - start), privacy: .public) ms")
            } catch {
                guard attempt == mine else { return }
                grabbing = false
                failed(error)
            }
        }
    }

    /// A delayed capture (CP10): a count of Captures › Delay seconds in a tip, then the frozen overlay as Hyper+S's, so
    /// a menu or a hover state opened meanwhile is in it. Its key again cancels the count.
    private func delayed() {
        if let counting {
            counting.cancel()
            self.counting = nil
            return tell("Capture cancelled.", nil)
        }
        let seconds = max(1, store.settings.delay)
        tell("Capturing in \(seconds)…", nil)
        counting = Task { @MainActor [delayStep] in
            for n in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: delayStep)
                if Task.isCancelled { return }
                if n > 0 { tell("Capturing in \(n)…", nil) }
            }
            counting = nil
            run(.area)
        }
    }

    /// Screen Recording granted, else Pilot's own line on why with Allow (the first time) or where to allow it (after).
    /// Asked only here, at a press.
    func permitted() -> Bool {
        if grabber.allowed() { return true }
        if defaults.bool(forKey: Self.askedKey) {
            tell("Screen Recording is off for Pilot. Allow it in Privacy & Security, then press again.",
                 HUD.TipAction(title: "Open") { PermissionDragPanel.openScreenRecording() })
        } else {
            tell("Captures need Screen Recording. Pilot captures only when you press a capture key.",
                 HUD.TipAction(title: "Allow…") { [self] in askFirstTime() })
        }
        return false
    }

    /// Onboarding's Allow, which counts as a capture press (ADR 0012, amended 2026-10-28): macOS's prompt the first
    /// time, the pane with the drag helper after.
    func askScreenRecording() {
        guard !grabber.allowed() else { return }
        if defaults.bool(forKey: Self.askedKey) { return PermissionDragPanel.openScreenRecording() }
        askFirstTime()
    }

    /// macOS's prompt, remembered as asked so the next press says where to allow it.
    private func askFirstTime() {
        defaults.set(true, forKey: Self.askedKey)
        grabber.ask()
    }

    private func failed(_ error: Error) {
        Self.log.error("capture: \(String(describing: error), privacy: .public)")
        if (error as? SCStreamError)?.code == .userDeclined {
            // Granted but refused: macOS applies a fresh grant only once Pilot reopens (Sven, Build 71).
            if grabber.allowed() {
                tell("Quit and reopen Pilot to finish allowing Screen Recording.",
                     HUD.TipAction(title: "Quit & Reopen") { PermissionDragPanel.relaunch() })
            } else {
                tell("Screen Recording is off for Pilot. Allow it in Privacy & Security, then press again.",
                     HUD.TipAction(title: "Open") { PermissionDragPanel.openScreenRecording() })
            }
        } else {
            tell("The capture failed: \(error.localizedDescription)", nil)
        }
    }

    /// What the overlay a request opens is for.
    static func purpose(_ request: Request) -> CaptureOverlay.Purpose {
        switch request {
        case .record: .record
        case .scroll, .scrollUp: .scroll
        case .ocr, .qr: .ocr
        case .subject: .subject
        case .markup: .markup
        case .colour: .colour
        default: .capture
        }
    }

    private func show(_ grabs: [DisplayGrab], windows: [CaptureSelection.Window], mode: CaptureSelection.Mode, purpose: CaptureOverlay.Purpose,
                      smart: Bool = false) {
        let overlay = CaptureOverlay(grabs: grabs, windows: windows, mode: mode, purpose: purpose, smart: smart, visible: overlaysVisible) { [weak self] outcome in
            guard let self else { return }
            if let take = self.areaTaker(purpose) {
                self.overlay = nil
                if case .area(let grab, let rect) = outcome { take(grab, rect) }
            } else if purpose == .record {
                self.overlay = nil
                if let source = RecordingSource.picked(outcome) {
                    self.recorder.start(source, settings: self.store.settings, folder: self.store.folder(.recording))
                } else if case .area = outcome {
                    self.tell("Nothing to record: the area had no width or no height.", nil)
                }
            } else {
                self.finish(outcome)
            }
        }
        self.overlay = overlay
        overlay.show()
    }

    /// What takes the area a text, scrolling or subject pick ends with; nil for the purposes that take more than an area.
    private func areaTaker(_ purpose: CaptureOverlay.Purpose) -> ((DisplayGrab, CGRect) -> Void)? {
        switch purpose {
        case .ocr: read
        case .scroll: scroll
        case .subject: cutSubject
        default: nil
        }
    }

    /// Reads an area's text and codes onto the pasteboard (Hyper+X), off the main thread; nothing is saved.
    private func read(_ grab: DisplayGrab, _ rect: CGRect) {
        guard let cut = grab.crop(rect) else { return tell("Nothing read: the area had no width or no height.", nil) }
        let codes = readingCodes
        Task { @MainActor in
            let lines = await Self.read(cut, scale: grab.scale, with: reader)
            if codes { return QRCodes.show(lines, from: "that area") }
            if !lines.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(ReadLines.copied(lines), forType: .string)
            }
            Self.log.notice("capture text: \(lines.count, privacy: .public) lines")
            tell(CaptureText.said(lines), nil)
        }
    }

    /// Capture subject (P72): the area's subjects with the background made transparent, copied and saved as any
    /// capture; Vision runs in pilot-text, off the main thread. An area with none says so and saves nothing.
    private func cutSubject(_ grab: DisplayGrab, _ rect: CGRect) {
        guard let cut = grab.crop(rect) else { return tell("Nothing captured: the area had no width or no height.", nil) }
        tell("Cutting out the subject…", nil)
        // Encoded at once, so the display's still is let go before the helper's run, which can take a minute on a new build.
        let scale = grab.scale, png = Self.encoding(cut, scale: scale)
        Task { @MainActor in
            let start = ContinuousClock.now
            let image = await Self.subject(of: png, with: subjects)
            Self.log.notice("capture subject: \(image.map { "\($0.width)×\($0.height)" } ?? "none", privacy: .public), \(Self.ms(ContinuousClock.now - start), privacy: .public) ms")
            guard let image else { return tell("No subject found in that area.", nil) }
            HUD.dismissTip()
            deliver(image, scale)
        }
    }

    /// `image` encoded as PNG off the main thread, holding it only until it is encoded.
    static func encoding(_ image: CGImage, scale: CGFloat) -> Task<Data?, Never> {
        let still = Unchecked(image)
        return Task.detached(priority: .userInitiated) { png(still.value, scale: scale) }
    }

    /// The subjects of the picture `png` encodes, on a clear background and cropped to them, decoded off the main thread.
    static func subject(of png: Task<Data?, Never>, with cutter: any SubjectCutting) async -> CGImage? {
        guard let png = await png.value, let out = await cutter.subject(in: png) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            CGImageSourceCreateWithData(out as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Unchecked.init)
        }.value?.value
    }

    /// `image`'s lines and codes, encoded and read off the main thread.
    static func read(_ image: CGImage, scale: CGFloat, with reader: any LineReading) async -> [ReadLine] {
        guard let png = await encoding(image, scale: scale).value else { return [] }
        return await reader.lines(in: png)
    }

    /// The scrolling capture under way, which Hyper+D again ends.
    private(set) var scrolling: ScrollCapture?
    /// The next scrolling capture goes up (Capture scrolling, upward).
    private var scrollingUp = false
    /// The next text read is Read a QR code's: its codes go to a panel, not the pasteboard.
    private var readingCodes = false

    /// Starts a scrolling capture of `rect` on `grab`'s display; its stitched image is copied and saved as any capture.
    private func scroll(_ grab: DisplayGrab, _ rect: CGRect) {
        let area = rect.intersection(CGRect(origin: .zero, size: grab.frame.size)).integral
        guard area.width >= 8, area.height >= 8 else { return tell("Nothing captured: the area had no width or no height.", nil) }
        let capture = ScrollCapture(area: area, display: grab.id, scale: grab.scale, displayFrame: grab.frame, auto: store.settings.autoScroll,
                                    upward: scrollingUp) { [weak self] image, why in
            guard let self else { return }
            self.scrolling = nil
            if let image { self.deliver(image, grab.scale) } else if let why { self.tell(why, nil) }
        }
        scrolling = capture
        guard overlaysVisible else { return }
        let screen = NSScreen.screens.first { $0.displayID == grab.id }?.frame ?? CGRect(origin: .zero, size: grab.frame.size)
        Task { await capture.start(frame: screen) }
    }

    /// The overlay is done: it has closed itself; take what it picked.
    private func finish(_ outcome: CaptureOverlay.Result) {
        overlay = nil
        switch outcome {
        case .cancelled: break
        case .area(let grab, let rect):
            guard let image = grab.crop(rect) else {
                return tell("Nothing captured: the area had no width or no height.", nil)
            }
            lastArea = LastArea(display: grab.id, rect: rect)
            deliver(image, grab.scale)
        case .window(let id, _, let grab):
            Task { @MainActor in
                do { deliver(try await grabber.window(id, scale: grab.scale), grab.scale) } catch { failed(error) }
            }
        case .colour(let hex):
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)
            tell("Copied \(hex)", nil)
        case .marked(let image, let scale):
            deliver(image, scale)
        }
    }

    /// The display the pointer is on, else the first.
    static func underPointer(_ grabs: [DisplayGrab]) -> DisplayGrab {
        let p = NSEvent.mouseLocation
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: p.x, y: primary - p.y)
        return grabs.first { $0.frame.contains(flipped) } ?? grabs[0]
    }

    static func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

    // MARK: Output

    /// Every capture: copied and saved, then what Captures › After capture says (build 54): a thumbnail in the corner,
    /// the editor at once, or the copy alone with its tip.
    func saveAndEdit(_ image: CGImage, scale: CGFloat) async {
        let after = store.settings.afterCapture
        let file = await save(image, scale: scale, tip: after == .copy)
        let still = Unchecked(image)
        let follow: @MainActor () -> Void = { [afterCapture] in afterCapture(still.value, scale, file, after) }
        if let holdAfter { holdAfter(follow) } else { follow() }
    }

    /// Set while something covers the screen (the keyboard lock's Screenshot): it gets what follows a saved capture, the
    /// thumbnail or the editor, to run once the screen is clear.
    var holdAfter: (@MainActor (@escaping @MainActor () -> Void) -> Void)?

    /// What follows a saved capture; a test's records it.
    var afterCapture: @MainActor (CGImage, CGFloat, URL?, CaptureSettings.AfterCapture) -> Void = { image, scale, file, after in
        switch after {
        case .thumbnail: CaptureThumbnails.show(image, scale: scale, file: file, capture: .shared)
        case .editor: CaptureEditor.show(image, scale: scale, file: file, capture: .shared)
        case .copy: break
        }
    }

    /// Copies the capture and saves it as PNG in the captures folder, its DPI set from its scale so it opens at its size;
    /// the file, or nil when it was not saved. The encoding and the write run off the main thread, where the Hyper tap's
    /// run loop source is; the pasteboard and the tip come back to it. No tip when the editor opens instead.
    @discardableResult
    func save(_ image: CGImage, scale: CGFloat, tip: Bool = true) async -> URL? {
        let folder = store.folder(.capture), still = Unchecked(image)
        let saved = await Task.detached(priority: .userInitiated) { Self.encodeAndWrite(still.value, scale: scale, in: folder) }.value
        guard let png = saved.png else { tell("The capture could not be encoded.", nil); return nil }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        switch saved.file {
        case .success(let url):
            Self.log.notice("capture saved: \(url.lastPathComponent, privacy: .public), \(image.width)×\(image.height)")
            CaptureHistoryStore.shared.note(url, kind: .capture)
            if tip {
                tell("Copied, and saved to \(Self.shortPath(folder))", HUD.TipAction(title: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                })
            }
            return url
        case .failure(let error):
            Self.log.error("capture not saved: \(error.localizedDescription, privacy: .public)")
            tell("Copied, but not saved: \(error.localizedDescription)", nil)
            return nil
        }
    }

    /// `png` written next to `file` as its name plus `suffix` ("Capture … edited.png"), or under a new capture name in
    /// `folder` when there is no file; never over another file. Off the main thread.
    nonisolated static func write(_ png: Data, near file: URL?, in folder: URL, suffix: String) -> URL? {
        guard let file else { return try? encodeAndWrite(png: png, in: folder).get() }
        return ImageFiles.write(png, in: file.deletingLastPathComponent(), stem: file.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "png")
    }

    /// The PNG, and the file it went to: never over another file, the next free name taken when one appears meanwhile.
    nonisolated static func encodeAndWrite(_ image: CGImage, scale: CGFloat, in folder: URL) -> (png: Data?, file: Result<URL, Error>) {
        guard let png = png(image, scale: scale) else { return (nil, .failure(CocoaError(.fileWriteUnknown))) }
        return (png, encodeAndWrite(png: png, in: folder))
    }

    nonisolated static func encodeAndWrite(png: Data, in folder: URL) -> Result<URL, Error> {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var tries = 0
            while true {
                let url = CaptureFiles.freeURL(.capture, in: folder, at: Date())
                do {
                    try png.write(to: url, options: .withoutOverwriting)
                    return .success(url)
                } catch CocoaError.fileWriteFileExists where tries < 5 {
                    tries += 1
                }
            }
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// `~/Pictures/Pilot` as "Pictures/Pilot"; a folder outside home as its full path.
    static func shortPath(_ url: URL) -> String {
        let home = NSHomeDirectory() + "/"
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
    }
}
