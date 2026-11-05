import AppKit
import AVFoundation
import Observation
import OSLog
import PilotCore
import ScreenCaptureKit
import SwiftUI

/// What a recording records (story 192): one display, one app's windows on a display, or an area of a display in its
/// points. Never two displays at once (Sven, 2026-10-16).
enum RecordingSource: Equatable {
    case display(CGDirectDisplayID)
    case app(pid_t, on: CGDirectDisplayID)
    case area(CGRect, on: CGDirectDisplayID)

    var display: CGDirectDisplayID {
        switch self {
        case .display(let id), .app(_, let id), .area(_, let id): id
        }
    }

    /// The overlay's pick as a source: an area the size of the display is the display; a window is its app.
    static func picked(_ result: CaptureOverlay.Result) -> RecordingSource? {
        switch result {
        case .area(let grab, let rect):
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return rect.size == grab.frame.size ? .display(grab.id) : .area(rect, on: grab.id)
        case .window(_, let owner, let grab):
            return owner > 0 ? .app(owner, on: grab.id) : .display(grab.id)
        case .cancelled, .colour, .marked: return nil
        }
    }
}

/// Pilot's screen recorder (spec `capture.html` CP13, CP14; Sven: "as simple as possible: start, pause, resume and stop").
/// An SCStream feeds RecordingWriter on one serial queue; pause and resume are stamped with the host clock the stream
/// stamps its samples with, so the file has no hole. While it records, the top bar shows a red dot, the time, pause and
/// stop (Q162); with the bar off, a capsule at the top of the recorded display does. Only the capsule stays out of the
/// recording: Pilot's top bar and windows are in it (Sven, build 52). A stream error or a disk under 1 GB free stops it and keeps what was recorded.
@Observable @MainActor
final class Recorder {
    static let shared = Recorder()

    /// Starting covers the Microphone question and the stream starting up: a second press then cancels, never starts a
    /// second stream.
    enum Phase: Equatable { case idle, starting, counting(Int), recording, paused }

    private(set) var phase: Phase = .idle
    /// The control's timer: the same cut as the file's, started at the stream's start.
    private(set) var clock = RecordingClock()
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: RecordingOutput?
    @ObservationIgnored private var capsule: NSPanel?
    @ObservationIgnored private var diskWatch: Timer?
    @ObservationIgnored private var screenWatch: NSObjectProtocol?
    /// The pointer watchers while recording (P71, T29): moves and clicks in other apps and in Pilot's own windows.
    @ObservationIgnored private var clickWatch: [Any] = []
    @ObservationIgnored private var countdown: Task<Void, Never>?
    /// The file being finished after a stop, which quitting waits for.
    @ObservationIgnored private(set) var closing: Task<Void, Never>?
    /// Which start is running: a stop or a second start moves it on, and a start that finds it moved gives up.
    @ObservationIgnored private var session = 0
    @ObservationIgnored var tell: @MainActor (String, HUD.TipAction?) -> Void = { HUD.tip($0, seconds: $1 == nil ? 3 : 8, action: $1) }
    /// Whether the top bar shows, or Capture in the macOS menu bar with the recording's time, so the capsule stands in only
    /// when neither does.
    @ObservationIgnored var barShows: @MainActor () -> Bool = { Engine.shared?.topBar.isOn ?? false || BarItemsStore.shared.shows(.capture, in: .menuBar) }
    /// Microphone's state and its question; a test's fakes.
    @ObservationIgnored var micStatus: @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    @ObservationIgnored var askMic: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    /// What follows a saved recording (P71): its thumbnail, the video editor, or the file copied, as Captures › After
    /// capture says; a test's fake.
    @ObservationIgnored var saved: @MainActor (URL) -> Void = { VideoEditor.recorded($0) }
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "recording")
    static let minimumFree: Int64 = 1_000_000_000

    var isActive: Bool { phase != .idle }

    /// The recording as the bars and the dropdown say it: its phase, and its time in whole seconds; nil while idle.
    var reading: BarRecording? {
        let seconds = clock.elapsed(at: Self.now()).rounded(.down)
        return switch phase {
        case .idle: nil
        case .starting: .starting
        case .counting(let n): .counting(n)
        case .recording: .recording(seconds)
        case .paused: .paused(seconds)
        }
    }

    #if DEBUG
    /// A render's state: `phase` with `elapsed` seconds on the timer, no stream.
    func pose(_ phase: Phase, elapsed: Double) {
        self.phase = phase
        clock = RecordingClock()
        let now = Self.now()
        _ = clock.place(now - elapsed, track: 0, starts: true)
        if phase == .paused { clock.pause(at: now) }
    }
    #endif

    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Hyper+Shift+A while recording, starting or counting down; `then` runs once the file is closed (quitting waits on
    /// it), or at once when there is none.
    func stop(then done: (@MainActor () -> Void)? = nil) {
        switch phase {
        case .idle:
            guard let closing else { done?(); return }
            Task { @MainActor in await closing.value; done?() }
        case .starting, .counting:
            session += 1
            countdown?.cancel()
            end()
            tell("Recording cancelled.", nil)
            done?()
        case .recording, .paused:
            finish(reason: nil, then: done)
        }
    }

    /// Hyper+Alt+A, or the control's button.
    func pauseOrResume() {
        guard let output, phase == .recording || phase == .paused else { return }
        let now = Self.now()
        if phase == .recording {
            clock.pause(at: now)
            output.queue.async { output.writer.pause(at: now) }
            phase = .paused
        } else {
            clock.resume(at: now)
            // Where the pointer is now: it may have moved while paused, and a still one sends no moves.
            let at = CGEvent(source: nil)?.location
            output.queue.async {
                output.writer.resume(at: now)
                if let at { output.move(at, time: now) }
            }
            phase = .recording
        }
        Self.log.notice("recording \(self.phase == .paused ? "paused" : "resumed", privacy: .public) at \(RecordingClock.label(self.clock.elapsed(at: now)), privacy: .public)")
    }

    /// Starts recording `source` with `settings`, into `folder`, after the countdown. Microphone is asked here, the first
    /// time Mic is picked, and only then.
    func start(_ source: RecordingSource, settings: CaptureSettings, folder: URL) {
        guard phase == .idle else { return }
        guard Self.free(at: folder) ?? Self.minimumFree >= Self.minimumFree else {
            return tell("Not recording: less than 1 GB is free where recordings go.", nil)
        }
        session += 1
        let id = session
        phase = .starting
        Task { @MainActor in
            let allowed = await micAllowed(settings.audio)
            guard live(id) else { return }
            guard allowed else { return end() }
            showControl(on: source.display)
            countdown = Task { @MainActor in
                for n in stride(from: settings.countdown, to: 0, by: -1) {
                    guard live(id) else { return }
                    phase = .counting(n)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                guard live(id) else { return }
                phase = .starting
                await begin(source, settings: settings, folder: folder, id: id)
            }
        }
    }

    /// Whether start `id` is still the one running.
    private func live(_ id: Int) -> Bool { session == id && phase != .idle }

    /// Microphone granted, asked now when it never was; else a tip naming where to allow it, and no recording. With no
    /// microphone picked nothing is read or asked.
    private func micAllowed(_ audio: CaptureSettings.Audio) async -> Bool {
        guard audio.mic else { return true }
        switch micStatus() {
        case .authorized: return true
        case .notDetermined:
            if await askMic() { return true }
        default: break
        }
        tell("Not recording: Microphone is off for Pilot. Allow it, or pick another sound on Captures.",
             MicrophoneGrant.open)
        return false
    }

    /// The stream and the file. After each wait it checks the start is still wanted: one stopped meanwhile stops its
    /// stream and leaves no file.
    private func begin(_ source: RecordingSource, settings: CaptureSettings, folder: URL, id: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard live(id) else { return }
            guard let display = content.displays.first(where: { $0.displayID == source.display }) else { throw Problem.displayGone }
            // Only the capsule stands out of the recording; Pilot's top bar, with its red dot, and its windows are in it.
            let capsuleID = capsule.map { UInt32($0.windowNumber) }
            // And the desktop icons, when Captures › Hide desktop icons is on.
            let mine = content.windows.filter { $0.windowID == capsuleID } + (settings.hideDesktopIcons ? content.desktopIcons() : [])
            // The display's own pixels, or its points (Captures › Resolution).
            let scale = settings.recordResolution == .points ? 1 : NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            let fps = settings.recordFPS == 30 ? 30 : 60
            let filter: SCContentFilter
            var points = CGSize(width: display.width, height: display.height)
            // The recorded frame in the global top-left space the pointer's places are in (P71).
            var frame = CGDisplayBounds(display.displayID)
            let config = SCStreamConfiguration()
            switch source {
            case .display:
                filter = SCContentFilter(display: display, excludingWindows: mine)
            case .app(let pid, _):
                guard let app = content.applications.first(where: { $0.processID == pid }) else { throw Problem.appGone }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            case .area(let rect, _):
                filter = SCContentFilter(display: display, excludingWindows: mine)
                config.sourceRect = rect
                points = rect.size
                frame = rect.offsetBy(dx: frame.minX, dy: frame.minY)
            }
            let size = RecordingWriter.encodable(CGSize(width: points.width * scale, height: points.height * scale))
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 8
            // T29: the pointer stays out of the pixels; its places, clicks and shapes go on the track and the export draws
            // it (R1–R4). Clicks are not marked either: Apple's showMouseClicks "will not be affected by showsCursor" and
            // "currently applies when pixelFormat is set to BGRA" (SCStream.h, SDK 27.2), so on these 420v frames it never
            // drew; the editor's Click ring (R4) does.
            config.showsCursor = false
            config.showMouseClicks = false
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.capturesAudio = settings.audio.system
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.captureMicrophone = settings.audio.mic

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = CaptureFiles.freeURL(.recording, in: folder, at: Date())
            let writer = try RecordingWriter(url: url, size: size, fps: fps, quality: settings.recordQuality.level,
                                             system: settings.audio.system, mic: settings.audio.mic)
            CaptureHistoryStore.shared.note(url, recording: source)
            // Captures › Show clicks starts this recording's Click ring on (R4).
            writer.drawsPointer(frame: frame.size, look: PointerLook(clickRing: settings.showClicks))
            let shapes = PointerShapes()
            if let shape = shapes.read(at: Self.now(), force: true) { writer.shape(shape) }
            let output = RecordingOutput(writer: writer, frame: frame) { [weak self] error in
                Task { @MainActor in self?.finish(reason: nil, error: error) }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            if settings.audio.system { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue) }
            if settings.audio.mic { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue) }
            try await stream.startCapture()
            guard live(id) else {
                // Stopped while the stream started: no recording, no file.
                try? await stream.stopCapture()
                await output.cancel()
                return
            }
            self.stream = stream
            self.output = output
            clock = RecordingClock()
            _ = clock.place(Self.now(), track: 0, starts: true)
            phase = .recording
            watchPointer(output, shapes: shapes)
            watchDisk(folder)
            watchDisplay(display.displayID)
            Self.log.notice("recording \(String(describing: source), privacy: .public) at \(Int(size.width))×\(Int(size.height)), sound \(settings.audio.rawValue, privacy: .public), \(fps) fps, quality \(settings.recordQuality.rawValue, privacy: .public)")
        } catch {
            guard live(id) else { return }
            Self.log.error("recording did not start: \(String(describing: error), privacy: .public)")
            end()
            tell((error as? SCStreamError)?.code == .userDeclined ? "Screen Recording is off for Pilot. Allow it in Privacy & Security, then press again."
                 : "The recording did not start: \(error.localizedDescription)", nil)
        }
    }

    enum Problem: Error, LocalizedError {
        case displayGone, appGone

        var errorDescription: String? {
            switch self {
            case .displayGone: "That display is gone."
            case .appGone: "That app quit."
            }
        }
    }

    /// Stops the stream and closes the file, whatever stopped it; what was recorded is kept. One tip says how it ended:
    /// `reason` when Pilot stopped it on its own (the disk, the display), the stream's error when it stopped by itself.
    private func finish(reason: String?, error: Error? = nil, then done: (@MainActor () -> Void)? = nil) {
        guard let output, phase == .recording || phase == .paused else { done?(); return }
        let stream = self.stream
        let length = clock.elapsed(at: Self.now())
        end()
        if let error { Self.log.error("recording stopped by the stream: \(String(describing: error), privacy: .public)") }
        if let reason { Self.log.notice("recording stopped: \(reason, privacy: .public)") }
        closing = Task { @MainActor in
            try? await stream?.stopCapture()
            do {
                let seconds = try await output.close()
                let url = output.writer.url
                Self.log.notice("recording saved: \(url.lastPathComponent, privacy: .public), \(RecordingClock.label(seconds), privacy: .public)")
                let pointer = output.writer.pointer
                // Written before the editor can open on it, off the main thread. The prune keeps the track of every
                // recording still in a folder Pilot saved one to: a drawn track is its only pointer.
                let folders = CaptureHistoryStore.shared.recordingFolders()
                await Task.detached(priority: .userInitiated) { try? pointer.save(for: url, in: VideoEditor.pointerFolder, alsoIn: folders) }.value
                let head = reason.map { "Recording stopped (\($0)) and saved" } ?? (error == nil ? "Recording saved" : "Recording stopped and saved")
                // The thumbnail, the editor or the copy says it was saved; a recording that stopped on its own says why.
                if reason != nil || error != nil {
                    tell("\(head) · \(RecordingClock.label(seconds))", HUD.TipAction(title: "Edit video") { VideoEditor.open(url) })
                }
                saved(url)
            } catch {
                Self.log.error("recording not saved after \(RecordingClock.label(length), privacy: .public): \(String(describing: error), privacy: .public)")
                tell(error.localizedDescription, nil)
            }
            closing = nil
            done?()
        }
    }

    private func end() {
        phase = .idle
        stream = nil
        output = nil
        countdown = nil
        diskWatch?.invalidate()
        diskWatch = nil
        if let screenWatch { NotificationCenter.default.removeObserver(screenWatch) }
        screenWatch = nil
        clickWatch.forEach(NSEvent.removeMonitor)
        clickWatch = []
        capsule?.orderOut(nil)
        capsule = nil
    }

    /// The pointer while recording (P71, T29): its moves and clicks, for the editor's zoom and for the export to draw it,
    /// and its shape when it changes. Watched by NSEvent monitors only while the stream runs (never the bind tap, ADR
    /// 0001), stamped with the host clock the frames are, and placed on the writer's queue. The frames can't carry the
    /// moves any more: with the pointer out of them, a pointer moving over a still screen makes none.
    private func watchPointer(_ output: RecordingOutput, shapes: PointerShapes) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let seen: (NSEvent) -> Void = { event in
            guard let at = event.cgEvent?.location else { return }
            let now = Self.now()
            let click = clicks.contains(NSEvent.EventTypeMask(type: event.type))
            let shape = shapes.read(at: now, force: click)
            output.queue.async {
                if let shape { output.writer.shape(shape) }
                if click { output.click(at, time: now) } else { output.move(at, time: now) }
            }
        }
        let kinds = clicks.union([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
        clickWatch = [NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: seen),
                      NSEvent.addLocalMonitorForEvents(matching: kinds) { seen($0); return $0 }].compactMap { $0 }
    }

    /// Every 10 s, give or take 2 (story 142: a lean timer wakes with the others).
    private func watchDisk(_ folder: URL) {
        diskWatch = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk(folder) }
        }
        diskWatch?.tolerance = 2
    }

    private func checkDisk(_ folder: URL) {
        guard let free = Self.free(at: folder), free < Self.minimumFree else { return }
        finish(reason: "less than 1 GB free")
    }

    /// The recorded display unplugged: stop and keep what was recorded, rather than wait on the stream's own error.
    private func watchDisplay(_ id: CGDirectDisplayID) {
        screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !NSScreen.screens.contains(where: { $0.displayID == id }) else { return }
                self?.finish(reason: "its display went away")
            }
        }
    }

    static func free(at folder: URL) -> Int64? {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// The capsule, made before the stream so the stream leaves it out with Pilot's other windows; only with the bar off.
    private func showControl(on display: CGDirectDisplayID) {
        guard !barShows(), let screen = NSScreen.screens.first(where: { $0.displayID == display }) ?? NSScreen.main else { return }
        let host = NSHostingView(rootView: RecordingControl(recorder: self, capsule: true).styled(.hud).pilotTheme())
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        let f = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: f.midX - host.frame.width / 2, y: f.maxY - host.frame.height - 8))
        panel.orderFrontRegardless()
        capsule = panel
    }
}

/// The stream's samples into the writer, on the writer's own queue; a stream that stops on its own reports it.
final class RecordingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: RecordingWriter
    let queue = DispatchQueue(label: "dev.banozz.pilot.recording")
    /// The recorded frame in global top-left points, which the pointer's places are made fractions of.
    let frame: CGRect
    private let stopped: @Sendable (Error) -> Void
    /// When a move was last kept, host seconds: at most 120 a second.
    private var lastMove = -Double.infinity
    /// Whether the pointer's first place is on the track: read with the first frame, since a still one sends no moves.
    private var seeded = false

    init(writer: RecordingWriter, frame: CGRect, stopped: @escaping @Sendable (Error) -> Void) {
        self.writer = writer
        self.frame = frame
        self.stopped = stopped
    }

    /// A click at `at` (global top-left points) at host `time`; on the queue.
    func click(_ at: CGPoint, time: Double) { writer.point(fraction(at), at: time, click: true) }

    /// The pointer moved to `at` (global top-left points) at host `time`; on the queue. At most 120 a second kept: a
    /// minute of steady moving is a few hundred kilobytes of track.
    func move(_ at: CGPoint, time: Double) {
        guard time - lastMove >= 1.0 / 120 else { return }
        lastMove = time
        writer.point(fraction(at), at: time, click: false)
    }

    private func fraction(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - frame.minX) / max(frame.width, 1), y: (p.y - frame.minY) / max(frame.height, 1))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Only frames with new pixels; an idle frame repeats the last.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            writer.append(sample, .video)
            // The pointer's place with the first frame; the monitors send each move after it (T29).
            if !seeded, let at = CGEvent(source: nil)?.location {
                seeded = true
                move(at, time: sample.presentationTimeStamp.seconds)
            }
        case .audio: writer.append(sample, .system)
        case .microphone: writer.append(sample, .mic)
        @unknown default: return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { stopped(error) }

    /// Finishes the file on the writer's queue, after every sample already queued.
    func close() async throws -> Double {
        let writer = self.writer
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        return try await writer.finish()
    }

    /// Drops the file: a recording stopped before it began.
    func cancel() async {
        let writer = self.writer
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { writer.cancel(); done.resume() } }
    }
}

/// The system pointer's shape while recording (T29): read at most 5 times a second, and at once on a click; a shape seen
/// before comes from the cache, so only a new one is drawn into a PNG. macOS 27 still answers `currentSystemCursor`,
/// which Apple marks deprecated and says will one day be nil (NSCursor.h): then every shape is the arrow.
@MainActor
final class PointerShapes {
    /// Pixels a point the PNG is drawn at: enough for R2's 3× on a Retina recording.
    static let scale: CGFloat = 6
    private var cache: [Int: CursorTrack.Shape] = [:]
    private var lastRead = -Double.infinity
    private var lastKey: Int?
    private var warned = false

    /// The pointer's shape when it differs from the last one read; nil when it is the same or it is too soon to look.
    func read(at now: Double, force: Bool = false) -> CursorTrack.Shape? {
        guard force || now - lastRead >= 0.2 else { return nil }
        lastRead = now
        let system = Self.system()
        let cursor = system ?? NSCursor.arrow
        if system == nil, !warned {
            warned = true
            Recorder.log.notice("recording: the system pointer's shape is not readable; the export draws the arrow")
        }
        let image = cursor.image
        var hasher = Hasher()
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(image.size.width)
        hasher.combine(image.size.height)
        if let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data { hasher.combine(pixels as Data) }
        let key = hasher.finalize()
        guard key != lastKey else { return nil }
        lastKey = key
        if let known = cache[key] { return known }
        guard let shape = Self.shape(cursor) else { return nil }
        cache[key] = shape
        return shape
    }

    /// `NSCursor.currentSystem`, reached by name: Apple deprecates it with no replacement for another app's pointer.
    private static func system() -> NSCursor? {
        NSCursor.perform(NSSelectorFromString("currentSystemCursor"))?.takeUnretainedValue() as? NSCursor
    }

    /// `cursor` as a track keeps it: a PNG at `scale` pixels a point, its size and hot spot in points.
    static func shape(_ cursor: NSCursor) -> CursorTrack.Shape? {
        let size = cursor.image.size
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        cursor.image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let picture = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else { return nil }
        return CursorTrack.Shape(png: png, scale: Double(scale), size: size, hot: cursor.hotSpot)
    }
}

/// The recording's control (Q162): a red dot, the time, pause or resume, and stop; in the top bar, or in a capsule when
/// the bar is off. While counting down it shows the count.
struct RecordingControl: View {
    @Environment(\.style) private var style
    let recorder: Recorder
    var capsule = false

    var body: some View {
        HStack(spacing: 6) {
            switch recorder.phase {
            case .idle: EmptyView()
            case .starting:
                Circle().fill(Color.red.opacity(0.5)).frame(width: 8, height: 8)
                Text("Starting…")
            case .counting(let n):
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Recording in \(n)").monospacedDigit()
            case .recording, .paused:
                Circle().fill(recorder.phase == .paused ? Color(style.colors.text3) : .red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(RecordingClock.label(recorder.clock.elapsed(at: Recorder.now()))).monospacedDigit()
                }
                Button { recorder.pauseOrResume() } label: { Image(systemName: recorder.phase == .paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(.plain).help(recorder.phase == .paused ? "Resume" : "Pause")
                Button { recorder.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain).help("Stop and save")
            }
        }
        .font(style.font(\.caption))
        .padding(.horizontal, capsule ? 12 : 8).padding(.vertical, capsule ? 6 : 0)
        .background { if capsule { Capsule().fill(Color(style.colors.panel)) } }
        .overlay { if capsule { Capsule().strokeBorder(Color(style.colors.line)) } }
    }
}
