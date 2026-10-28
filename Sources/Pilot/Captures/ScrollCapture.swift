import AppKit
import Observation
import OSLog
import PilotCore
import ScreenCaptureKit
import SwiftUI

/// A scrolling capture (spec `capture.html` CP11; Sven, build 52: auto-scroll, and upward): Sven drags the
/// part that scrolls; an SCStream watches that area and ScrollStitch adds what scrolls into view, below or above. With
/// Captures › Pilot scrolls for you on, Pilot scrolls it itself, half the area at a time, with scroll-wheel events at the
/// area (never a key, so ADR 0001 holds), until three steps add nothing (the end of the page), Esc, Return or a click; a
/// scroll of Sven's own hands over to him. Off, he scrolls himself. An accent frame rings the area and a small control
/// under it shows the height so far, Done and Cancel; the capture ends at Done, Hyper+D again, Esc or Return (the tap
/// takes them, HyperTap.endScrollCapture), three seconds after the last
/// new rows, or at 20,000 pixels, and is then copied and saved like any capture. The stream leaves out the ring, the
/// control and the overlays Pilot draws over other apps (the focused window's border), never Pilot's own windows.
@Observable @MainActor
final class ScrollCapture {
    /// The result's height in pixels so far, and how the last frame went.
    private(set) var height = 0
    private(set) var full = false
    @ObservationIgnored let area: CGRect
    @ObservationIgnored let display: CGDirectDisplayID
    @ObservationIgnored let scale: CGFloat
    @ObservationIgnored private let size: (width: Int, height: Int)
    /// The stitch lives on the frames' queue; the main actor reads it only through `queue`.
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.banozz.pilot.scroll")
    @ObservationIgnored nonisolated(unsafe) private var stitch: ScrollStitch
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: ScrollOutput?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var done: ((CGImage?, String?) -> Void)?
    /// Seconds without a new row, after the first, that end it.
    @ObservationIgnored var quiet: Duration = .seconds(3)
    /// Pilot scrolls the area itself, and which way: up for a chat read from the bottom.
    @ObservationIgnored let upward: Bool
    private(set) var scrolling: Bool
    /// The display's frame in global points (top left of the main display, y down), to aim the scroll at the area.
    @ObservationIgnored let displayFrame: CGRect
    /// Posts one scroll of `delta` points at a global point; a test's fake feeds the next frame instead.
    @ObservationIgnored var post: @MainActor (Int32, CGPoint) -> Void = { ScrollCapture.postScroll($0, at: $1) }
    /// Watches clicks and Sven's own scrolling while it runs; off in tests.
    @ObservationIgnored var watchInput = true
    /// A capture started or stopped watching: the app hands it to the tap, which ends it on Esc or Return.
    static var onWatching: (ScrollCapture?) -> Void = { _ in }
    /// A pause between two of Pilot's scrolls, for the page to draw and the frame to arrive.
    @ObservationIgnored var settle: Duration = .milliseconds(240)
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?
    /// Frames seen, matched and not, for the log line that ends it.
    @ObservationIgnored nonisolated(unsafe) private var counts = (frames: 0, added: 0, unmatched: 0)
    /// Every frame and scroll on disk, only while `ScrollFrameDump.key` is on.
    @ObservationIgnored nonisolated let dump: ScrollFrameDump?
    /// Frames the stitcher could not place, as the main actor has heard; the auto loop reads it to back off.
    private(set) var misses = 0
    /// Marks Pilot's own scroll events, so the input watch tells them from Sven's.
    nonisolated static let marker: Int64 = 0x5049_4C54
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "captures")

    /// `area` in the display's points; `done` gets the stitched image, or nil and why.
    init(area: CGRect, display: CGDirectDisplayID, scale: CGFloat, displayFrame: CGRect = .zero, auto: Bool = false, upward: Bool = false,
         done: @escaping (CGImage?, String?) -> Void) {
        self.area = area
        self.display = display
        self.scale = scale
        self.displayFrame = displayFrame
        self.upward = upward
        scrolling = auto
        size = (max(1, Int((area.width * scale).rounded())), max(1, Int((area.height * scale).rounded())))
        // The right 20 points: where macOS draws the overlay scroll bar while scrolling.
        stitch = ScrollStitch(width: size.width, height: size.height, ignoredRight: Int(20 * scale))
        self.done = done
        dump = ScrollFrameDump.start(area: area, scale: scale, upward: upward)
    }

    var isRunning: Bool { done != nil }

    /// Rings the area, shows the control, then starts the stream; the ring, the control and Pilot's overlays are left out.
    func start(frame screen: CGRect) async {
        showPanels(on: screen)
        // The picker's outline stays on screen a few frames after it closed; a first frame with it in matched nothing
        // after it and kept the page's footer in the body (Sven, build 58: frames 1 and 2 carried it).
        try? await Task.sleep(for: settle)
        guard isRunning else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard isRunning else { return }
            guard let scDisplay = content.displays.first(where: { $0.displayID == display }) else { return finish(nil, "That display is gone.") }
            let config = SCStreamConfiguration()
            config.sourceRect = area
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            // The capture's own ring and control are left out, and every overlay Pilot draws over other apps that clicks
            // pass through: the focused window's border ran along the area's foot (Sven, build 66). Shown ones only: a
            // panel never shown has no window number. Pilot's own windows in the area are captured.
            let ours = Set((panels + NSApp.windows.filter { $0.isVisible && $0.ignoresMouseEvents }).map { UInt32($0.windowNumber) })
            let icons = CaptureSettingsStore.shared.settings.hideDesktopIcons ? content.desktopIcons() : []
            let filter = SCContentFilter(display: scDisplay, excludingWindows: content.windows.filter { ours.contains($0.windowID) } + icons)
            let output = ScrollOutput { [weak self] pixels, width, height in self?.feed(pixels, width: width, height: height) }
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            guard isRunning else { try? await stream.stopCapture(); return }
            self.stream = stream
            self.output = output
            startWatching()
            if scrolling { scrollForSven() }
        } catch {
            Self.log.error("scrolling capture did not start: \(String(describing: error), privacy: .public)")
            finish(nil, "The scrolling capture did not start: \(error.localizedDescription)")
        }
    }

    /// One frame's pixels, on the frames' queue: stitched, and the control told how tall it is now. A first frame of
    /// another size than asked for (ScreenCaptureKit rounds) sets the stitch's size.
    nonisolated func feed(_ pixels: [UInt8], width: Int? = nil, height frameHeight: Int? = nil) {
        if stitch.isEmpty, let width, let frameHeight, width != stitch.width || frameHeight != stitch.frameHeight {
            stitch = ScrollStitch(width: width, height: frameHeight, ignoredRight: stitch.ignoredRight)
        }
        let added = stitch.add(pixels)
        counts.frames += 1
        if case .appended = added { counts.added += 1 }
        if added == .noMatch { counts.unmatched += 1 }
        let height = stitch.height
        dump?.frame(pixels, width: width ?? stitch.width, height: frameHeight ?? stitch.frameHeight, result: "\(added), \(height) px")
        Task { @MainActor in self.progress(added, height: height) }
    }

    private func progress(_ added: ScrollStitch.Added, height: Int) {
        guard isRunning else { return }
        self.height = height
        switch added {
        case .noMatch: misses += 1
        case .appended:
            idle?.cancel()
            idle = Task { @MainActor [quiet] in
                try? await Task.sleep(for: quiet)
                if !Task.isCancelled { self.end() }
            }
        case .full:
            full = true
            end()
        case .first, .unchanged, .noMatch: break
        }
    }

    /// Done, the key again, the quiet after scrolling, or the limit: the stitched image goes on.
    func end() {
        guard isRunning else { return }
        let stream = self.stream
        teardown()
        Task { @MainActor in
            try? await stream?.stopCapture()
            let image = await withCheckedContinuation { (got: CheckedContinuation<Unchecked<CGImage?>, Never>) in
                queue.async { got.resume(returning: Unchecked(Self.image(self.stitch))) }
            }
            let c = self.counts
            Self.log.notice("scrolling capture: \(image.value?.height ?? 0, privacy: .public) px tall\(self.full ? " (the limit)" : "", privacy: .public), \(c.frames, privacy: .public) frames, \(c.added, privacy: .public) added, \(c.unmatched, privacy: .public) unmatched\(self.upward ? ", upward" : "", privacy: .public)")
            finish(image.value, image.value == nil ? "Nothing was captured." : nil)
        }
    }

    /// Cancel: nothing is kept.
    func cancel() {
        guard isRunning else { return }
        let stream = self.stream
        teardown()
        Task { try? await stream?.stopCapture() }
        finish(nil, "Scrolling capture cancelled.")
    }

    private func teardown() {
        idle?.cancel()
        idle = nil
        autoTask?.cancel()
        autoTask = nil
        scrolling = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Set before the monitor, which may never come: one capture runs at a time (PilotCapture.run).
        if watchInput { Self.onWatching(nil) }
        panels.forEach { $0.orderOut(nil) }
        panels = []
        stream = nil
        output = nil
    }

    private func finish(_ image: CGImage?, _ why: String?) {
        teardown()
        let done = self.done
        self.done = nil
        done?(image, why)
    }

    // MARK: Pilot scrolls

    /// Scrolls the area half its height at a time and waits for the page; three steps that add nothing are the end of
    /// it. Sven's own scroll or a click stop it (startWatching), as Esc or Return do (HyperTap.endScrollCapture).
    func scrollForSven() {
        scrolling = true
        // Scroll events go to the window under the pointer: it moves to the area's middle once.
        if watchInput { CGWarpMouseCursorPosition(CGPoint(x: displayFrame.minX + area.midX, y: displayFrame.minY + area.midY)) }
        let centre = CGPoint(x: displayFrame.minX + area.midX, y: displayFrame.minY + area.midY)
        let sign: Int32 = upward ? 1 : -1
        autoTask = Task { @MainActor [settle] in
            var pace = ScrollPace(area: area.height, scale: scale)
            var still = 0
            while !Task.isCancelled, isRunning, scrolling {
                let before = height, missed = misses
                let step = pace.step
                dump?.note("scroll \(step * sign)")
                post(step * sign, centre)
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled, isRunning, scrolling else { return }
                if misses > missed, height == before {
                    // The page went further than the overlap: back to where the last frame matched, then smaller steps.
                    dump?.note("scroll back \(-step * sign)")
                    post(-step * sign, centre)
                    try? await Task.sleep(for: settle)
                    pace.missed()
                    if pace.lost { return end() }
                    continue
                }
                pace.moved(rows: height - before, for: step)
                still = height == before ? still + 1 : 0
                if still >= 3 { return end() }
            }
        }
    }

    /// Sven's own scroll: Pilot stops scrolling and he carries on by hand.
    func handOver() {
        guard scrolling else { return }
        autoTask?.cancel()
        autoTask = nil
        scrolling = false
    }

    /// While it runs: a click elsewhere ends it while Pilot scrolls; Sven's own scroll hands over. A global monitor sees
    /// other apps' events only, so the control's own Done and Cancel stay its own. Esc and Return are the tap's.
    private func startWatching() {
        guard watchInput, monitor == nil else { return }
        Self.onWatching(self)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            let ours = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ScrollCapture.marker
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown, .rightMouseDown: if self.scrolling { self.end() }
                case .scrollWheel where !ours: self.handOver()
                default: break
                }
            }
        }
    }

    /// One step of `delta` points at `point` (global), as a trackpad sends it: small continuous pixel events, marked as
    /// Pilot's. A wheel event not marked continuous is read by apps as lines, ten times or more what was asked, and the
    /// page jumped past the overlap the stitch needs (Sven, build 53: 22 of 23 frames unmatched).
    static func postScroll(_ delta: Int32, at point: CGPoint) {
        for event in scrollEvents(delta, at: point) { event.post(tap: .cghidEventTap) }
    }

    /// The events one step is sent as: continuous, in pixels, at most 30 points each, adding up to `delta`.
    static func scrollEvents(_ delta: Int32, at point: CGPoint) -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        var left = delta, events: [CGEvent] = []
        while left != 0 {
            let piece = left > 0 ? min(left, 30) : max(left, -30)
            left -= piece
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: piece, wheel2: 0, wheel3: 0) else { continue }
            event.location = point
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            events.append(event)
        }
        return events
    }

    /// The stitched rows as an image: ScreenCaptureKit's BGRA, top row first.
    nonisolated static func image(_ stitch: ScrollStitch) -> CGImage? {
        guard !stitch.isEmpty, stitch.height > 0 else { return nil }
        let data = Data(stitch.pixels()) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: stitch.width, height: stitch.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stitch.rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The accent ring just outside the area, which clicks and scrolls pass through, and the control under it (above it
    /// when the area reaches the display's foot).
    private func showPanels(on screen: CGRect) {
        let ring = CGRect(x: screen.minX + area.minX - 3, y: screen.maxY - area.maxY - 3, width: area.width + 6, height: area.height + 6)
        let border = NSPanel(contentRect: ring, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = NSHostingView(rootView: RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: CaptureOverlay.accent()), lineWidth: 2))
        border.orderFrontRegardless()

        let host = NSHostingView(rootView: ScrollControl(capture: self).styled(.hud).pilotTheme())
        host.frame.size = host.fittingSize
        let control = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        control.isOpaque = false
        control.backgroundColor = .clear
        control.hasShadow = false
        control.level = .floating
        control.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        control.contentView = host
        var origin = CGPoint(x: ring.midX - host.frame.width / 2, y: ring.minY - host.frame.height - 8)
        if origin.y < screen.minY + 8 { origin.y = ring.maxY + 8 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - host.frame.width - 8)
        control.setFrameOrigin(origin)
        control.orderFrontRegardless()
        panels = [border, control]
    }
}

/// The stream's frames as tightly packed BGRA rows.
final class ScrollOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let frame: @Sendable ([UInt8], Int, Int) -> Void

    init(frame: @escaping @Sendable ([UInt8], Int, Int) -> Void) { self.frame = frame }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer, let pixels = Self.rows(buffer) else { return }
        frame(pixels, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    }

    /// A BGRA pixel buffer's rows without their padding.
    static func rows(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let row = width * 4
        var out = [UInt8](repeating: 0, count: row * height)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<height { dst.baseAddress!.advanced(by: y * row).copyMemory(from: base.advanced(by: y * stride), byteCount: row) }
        }
        return out
    }
}

/// The scrolling capture's control: what to do, the height so far, Done and Cancel.
struct ScrollControl: View {
    @Environment(\.style) private var style
    let capture: ScrollCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.and.down.text.horizontal")
            Text(capture.scrolling ? (capture.height == 0 ? "Scrolling for you · Esc or Return stops" : "\(capture.height.formatted()) px · Esc or Return stops")
                 : capture.height == 0 ? (capture.upward ? "Scroll up slowly" : "Scroll down slowly") : "\(capture.height.formatted()) px").monospacedDigit()
            Button("Cancel") { capture.cancel() }.buttonStyle(.pilot)
            Button("Done") { capture.end() }.buttonStyle(.pilotPrimary)
        }
        .font(style.font(\.caption))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background { Capsule().fill(Color(style.colors.panel)) }
        .overlay { Capsule().strokeBorder(Color(style.colors.line)) }
    }
}

/// How far Pilot's auto-scroll asks the page to move each step (build 53). Apps scale a scroll their own way, so the
/// step starts at a quarter of the area, then is set from how far the page really moved to aim at 40 % of the area:
/// enough overlap for the stitch, few steps. A step that lost the overlap is undone and halved; under 2 points the
/// page cannot be followed and the capture ends with what it has.
struct ScrollPace: Equatable {
    /// The area's height in points, and pixels a point (the stitch counts pixel rows).
    let area: CGFloat
    let scale: CGFloat
    private(set) var points: CGFloat
    private(set) var lost = false

    init(area: CGFloat, scale: CGFloat) {
        self.area = area
        self.scale = scale
        points = max(8, area * 0.25)
    }

    var step: Int32 { Int32(points.rounded()) }

    /// The page moved `rows` pixel rows for a step of `asked` points: the next step aims at 40 % of the area.
    mutating func moved(rows: Int, for asked: Int32) {
        guard rows > 0, asked != 0 else { return }
        let perPoint = CGFloat(rows) / scale / CGFloat(abs(asked))
        points = min(area * 0.6, max(2, area * 0.4 / perPoint))
    }

    mutating func missed() {
        points /= 2
        if points < 2 { lost = true }
    }
}

/// Hyper+D's frames on disk, for diagnosis (Sven on builds 54 and 55: the Ghostex chat stitched nothing, and a made-up
/// page does not show why). Off unless `defaults write dev.banozz.pilot captureScrollFrames -bool true`; then each
/// scrolling capture writes every frame it is fed as `0001.png`… and a line per frame and per scroll Pilot posts to
/// `log.txt`, in `~/Pictures/Pilot/Scroll frames <time>/`, at most 400 frames. Off, nothing is made or run.
final class ScrollFrameDump: @unchecked Sendable {
    static let key = "captureScrollFrames"
    let folder: URL
    private let queue = DispatchQueue(label: "dev.banozz.pilot.scroll-dump", qos: .utility)
    private var count = 0
    private let started = Date()

    /// Nil while the defaults key is off.
    static func start(area: CGRect, scale: CGFloat, upward: Bool, defaults: UserDefaults = .pilot(),
                      home: URL = URL(filePath: NSHomeDirectory())) -> ScrollFrameDump? {
        guard defaults.bool(forKey: key) else { return nil }
        let name = "Scroll frames " + CaptureFiles.name(.capture, at: Date()).replacingOccurrences(of: "Capture ", with: "").replacingOccurrences(of: ".png", with: "")
        let dump = ScrollFrameDump(folder: home.appending(path: "Pictures/Pilot/\(name)", directoryHint: .isDirectory))
        dump.note("area \(area) points, scale \(scale), \(upward ? "upward" : "down")")
        return dump
    }

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// One line in `log.txt`, with the milliseconds since the start.
    func note(_ line: String) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        queue.async { [folder] in
            let url = folder.appending(path: "log.txt"), data = Data("\(ms) ms  \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// A frame as a PNG (BGRA, rows top first), and what the stitch made of it.
    func frame(_ pixels: [UInt8], width: Int, height: Int, result: String) {
        count += 1
        guard count <= 400 else { return }
        let n = count
        note(String(format: "frame %04d  %@", n, result))
        queue.async { [folder] in
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let file = CGImageDestinationCreateWithURL(folder.appending(path: String(format: "%04d.png", n)) as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(file, image, nil)
            CGImageDestinationFinalize(file)
        }
    }
}
