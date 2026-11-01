import AppKit
import CoreMedia
import Darwin
import Observation
import PilotCore
import ScreenCaptureKit
import VideoToolbox

/// How the Window shelf draws a window (ADR 0012's 2026-10-30 amendment, Q662): its icon and title, a still, or live.
enum ShelfPictureMode: String, CaseIterable, Sendable {
    case off, stills, live

    var title: String { rawValue.capitalized }
}

/// The shelf's captures, behind a protocol so tests never capture or ask Screen Recording.
protocol ShelfCapturing: Sendable {
    /// Whether Screen Recording is granted, read without a prompt.
    func allowed() -> Bool
    /// One still of each of these windows, `width` pixels wide at most; a window that closed is left out. `refused`:
    /// macOS turned a capture down although the grant reads as given (a fresh grant applies once Pilot reopens).
    func stills(_ ids: [Int], width: Int) async -> (images: [Int: ShelfStill], refused: Bool)
    /// A live picture of one window, `width` pixels wide at most, two frames a second.
    @MainActor func live(_ id: Int, width: Int, frame: @escaping @MainActor (CGImage) -> Void,
                         ended: @escaping @MainActor () -> Void) async -> ShelfLiveStart
}

/// How a live picture's start went.
enum ShelfLiveStart {
    case started(any ShelfLiveCapture)
    /// The window is gone, or the stream would not start.
    case failed
    /// macOS turned it down although the grant reads as given (a fresh grant applies once Pilot reopens).
    case refused
}

/// A running live picture.
@MainActor
protocol ShelfLiveCapture: AnyObject {
    func stop()
}

/// The shelf's window pictures (spec pilot-1-1 T13, T14; Q690). Stills is the default, and captures only once Screen
/// Recording is granted: nothing asks it until Sven presses Allow, in the shelf's one offer or in Settings, or picks
/// Stills or Live there (a capture press, ADR 0012). Its state is read at each shelf refresh while pictures are on, and
/// without the grant the shelf draws icons. Off reads and captures nothing: no Screen Recording read, no ScreenCaptureKit
/// call.
/// - Stills (Q641): a still of each shelved window the shelf has none of (the first show of a workspace), one of a
///   window the moment it leaves the stage (taken at the click when a card swaps it out, for the Fly; after the swap
///   otherwise), and every 2 s while the pointer is on the shelf; nothing at rest. A minimized window gets one only as
///   it leaves the stage, never again: ScreenCaptureKit may have no picture of it.
/// - A still is the card's own pixels on its screen, a quarter more for the turn and the hover's lift (`width(scale:)`):
///   ScreenCaptureKit takes the window at up to three times that and one high-quality pass shrinks it (ShelfStill), so
///   a window thirty times the card's width still reads as type and lines, not speckle (the 1x stills Sven saw: one
///   GPU pass from 3,440 pt to 204 px).
/// - Live: a stream per shelved window on a shown Stage workspace, at card size and two frames a second, stopped
///   when it goes back to the stage or closes, its workspace hides or shows the desktop, the mode changes or the screen
///   is out of use.
/// - The other workspaces' folded cards get Stills' pictures in either mode: one of each window with none, and fresh
///   ones while the pointer is on the shelf in Stills.
@Observable @MainActor
final class ShelfPictures: ScreenPausing {
    static let shared = ShelfPictures()

    private(set) var mode: ShelfPictureMode
    /// Each window's picture, one observed holder per window, so a live frame redraws its own thumbnail alone.
    @ObservationIgnored private var pictures: [Int: ShelfPicture] = [:]
    /// Pictures are on and Screen Recording is not granted: the shelf draws icons and Settings says where to allow it.
    private(set) var lacksPermission = false
    /// Screen Recording reads as granted but macOS refused a capture: Pilot must reopen to use a fresh grant (Build 71).
    private(set) var needsReopen = false
    /// The shelf offered Screen Recording once and Sven answered, Allow or Not now (Q690); Settings keeps its own row.
    private(set) var offered: Bool
    /// Screen Recording was read for the shelf at least once, so General can say what it read.
    private(set) var checked = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let capture: any ShelfCapturing
    /// Screen Recording asked as a capture press asks it (ADR 0012): macOS's prompt the first time, the pane after.
    @ObservationIgnored var ask: @MainActor () -> Void = { PilotCapture.shared.askScreenRecording() }
    @ObservationIgnored private var screens: [ShelfScreen] = []
    @ObservationIgnored private var staged: Set<Int> = []
    @ObservationIgnored private var inUse = true
    @ObservationIgnored private var hover: (screen: String, task: Task<Void, Never>)?
    /// Each live stream's start, so a stream that ended late never clears the one that replaced it.
    @ObservationIgnored private var starts: [Int: UUID] = [:]
    @ObservationIgnored private var taking: Set<Int> = []
    @ObservationIgnored private var streams: [Int: any ShelfLiveCapture] = [:]
    @ObservationIgnored private var wanted: Set<Int> = []
    /// Windows a card's click just pictured as they left the stage: the refresh after the swap takes no second still.
    @ObservationIgnored private var leftWith: Set<Int> = []

    static let key = "shelf.pictures"
    static let offeredKey = "shelf.pictures.offered"
    /// A card's width in points: the shelf's room less its margins (ShelfGroup).
    static let cardWidth = CGFloat(PilotBlock.shelfWidth) - 28
    /// A picture's pixels across on a screen of backing `scale`: the card's width there and a quarter more, so the 10°
    /// turn's near edge and the hover's 1.04 lift never scale it up.
    static func width(scale: CGFloat) -> Int { Int((cardWidth * scale * 1.25).rounded()) }
    /// A live picture's pixels across: the card's own, as before the stills' headroom, so Live's streams cost what they did.
    static func liveWidth(scale: CGFloat) -> Int { Int((cardWidth * scale).rounded()) }
    static let hoverEvery: Duration = .seconds(2)
    /// What Live's row and `pilot set shelf.pictures live` say before it turns on (Q662).
    // TODO(T14, Sven's test list): add the measured cost, Pilot's memory and CPU with Live on and four shelved windows
    // against Off, read from `pilot status --part shelf` on his build: "…than stills: about N MB and N % CPU with four."
    static let liveWarning = "Live pictures keep a capture running for each shelved window: more memory and CPU than stills."

    init(defaults: UserDefaults = .pilot(), capture: any ShelfCapturing = SCShelfCapture()) {
        self.defaults = defaults
        self.capture = capture
        mode = defaults.string(forKey: Self.key).flatMap(ShelfPictureMode.init(rawValue:)) ?? .stills
        offered = defaults.bool(forKey: Self.offeredKey)
    }

    /// The shelf's offer: pictures on, Screen Recording missing, and not answered yet.
    var offering: Bool { lacksPermission && !offered }

    /// Allow, on the shelf or in Settings: macOS's prompt the first time, Privacy & Security after.
    func allow() {
        answerOffer()
        ask()
    }

    /// The offer's Allow or Not now: it never shows again.
    func answerOffer() {
        offered = true
        defaults.set(true, forKey: Self.offeredKey)
    }

    /// Settings' choice: Stills or Live asks Screen Recording when it is not granted (ADR 0012, amended 2026-10-30).
    func set(_ next: ShelfPictureMode) {
        guard next != mode else { return }
        mode = next
        defaults.set(next.rawValue, forKey: Self.key)
        stopAll()
        drop { _ in true }
        taking = []
        lacksPermission = false
        needsReopen = false
        if next != .off, !capture.allowed() { ask() }
        follow(screens)
    }

    /// The shelf's screens after each refresh.
    func follow(_ next: [ShelfScreen]) {
        let wasStaged = staged
        screens = next
        staged = Set(next.flatMap(\.staged))
        if let hover, !next.contains(where: { $0.id == hover.screen }) { stopHover() }
        guard mode != .off, inUse else {
            drop { _ in true }
            return stopAll()
        }
        checked = true
        guard capture.allowed() else {
            stopAll()
            if !lacksPermission { lacksPermission = true; drop { _ in true } }
            return
        }
        lacksPermission = false
        let shelved = next.flatMap(\.shelved), minimized = Set(next.flatMap(\.minimized)), folded = next.flatMap(\.folded)
        let pictured = Set(shelved + folded)
        guard !needsReopen else { return drop { !pictured.contains($0) } } // refused until Pilot reopens: no retries
        // The other workspaces' cards: a still of each window that has none, in Live too.
        let unpictured = folded.filter { image(of: $0) == nil }
        // A window a click already pictured as it left (leaving) takes none now.
        let left = leftWith
        leftWith = []
        if mode == .stills {
            take(shelved.filter { wasStaged.contains($0) && !left.contains($0) || image(of: $0) == nil && !minimized.contains($0) } + unpictured)
        } else {
            run(Set(shelved).subtracting(minimized))
            take(unpictured)
        }
        drop { !pictured.contains($0) }
    }

    /// The picture of window `id`, nil while it has none; a view reading it redraws when that window's picture changes.
    func image(of id: Int) -> CGImage? { holder(id).image }

    /// Window `id`'s corner radius as a share of its width (ShelfStill.corner), 0 while it has no picture.
    func corner(of id: Int) -> CGFloat { holder(id).corner }

    /// Window `id`'s picture with its corner, nil while it has none.
    func still(of id: Int) -> ShelfStill? { holder(id).image.map { ShelfStill(image: $0, corner: holder(id).corner) } }

    private func holder(_ id: Int) -> ShelfPicture {
        if let held = pictures[id] { return held }
        let held = ShelfPicture()
        pictures[id] = held
        return held
    }

    private func set(_ still: ShelfStill, of id: Int) {
        let held = holder(id)
        held.image = still.image
        if held.corner != still.corner { held.corner = still.corner }
    }

    /// A live frame: the picture changes, the window's corner stays as its last still read it.
    private func set(_ image: CGImage, of id: Int) { holder(id).image = image }

    /// The backing scale of the screen whose shelf pictures window `id`: the sharpest screen's while none does.
    private func scale(of id: Int) -> CGFloat {
        screens.first { $0.pictured.contains(id) || $0.staged.contains(id) }?.display?.backingScaleFactor
            ?? NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    /// Forgets the pictures of the windows `gone` says: a window back on the stage or closed keeps no still. The holders
    /// stay, since a thumbnail drawn from one goes on watching it.
    private func drop(_ gone: (Int) -> Bool) {
        for (id, held) in pictures where gone(id) && held.image != nil { held.image = nil }
    }

    /// The pointer on one screen's shelf: its Stills refresh every 2 s until it leaves (Q641). Each round checks the
    /// pointer is still over that shelf, since a panel ordered out under it may never say it left.
    func hovering(_ on: Bool, on screen: String) {
        stopHover()
        guard on, mode == .stills, inUse, !lacksPermission, !needsReopen else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, mode == .stills, inUse, !lacksPermission, !needsReopen,
                      let shown = screens.first(where: { $0.id == screen }), shown.holdsPointer else { self?.stopHover(); return }
                take(shown.shelved.filter { !shown.minimized.contains($0) } + shown.folded)
                try? await Task.sleep(for: Self.hoverEvery)
            }
        }
        hover = (screen, task)
    }

    private func stopHover() {
        hover?.task.cancel()
        hover = nil
    }

    func pause() {
        inUse = false
        stopAll()
    }

    func resume() {
        inUse = true
        follow(screens)
    }

    private func take(_ ids: [Int]) {
        let ids = ids.filter { !taking.contains($0) }
        guard !ids.isEmpty else { return }
        taking.formUnion(ids)
        // One capture per screen scale: each window at its own shelf's pixels.
        for (scale, batch) in Dictionary(grouping: ids, by: scale(of:)) {
            Task {
                let got = await capture.stills(batch, width: Self.width(scale: scale))
                taking.subtract(batch)
                guard mode != .off, inUse else { return }
                if got.refused { needsReopen = true }
                let pictured = Set(screens.flatMap(\.pictured))
                for (id, still) in got.images where pictured.contains(id) && streams[id] == nil { set(still, of: id) }
            }
        }
    }

    /// A card's click in Stills (the Fly, ADR 0012's "one picture of a window as it leaves the centre"): a still of each
    /// window on the stage now, kept as its shelf card's picture once the swap shelves it. Nothing in Off or Live (Live's
    /// streams are its only captures of the stage's windows), nor while not allowed, refused until Pilot reopens or the
    /// screen is out of use; `then` gets what arrived, empty then.
    func leaving(_ ids: [Int], then: @escaping @MainActor ([Int: ShelfStill]) -> Void) {
        let ids = ids.filter { !taking.contains($0) }
        guard mode == .stills, inUse, !lacksPermission, !needsReopen, !ids.isEmpty, capture.allowed() else { return then([:]) }
        taking.formUnion(ids)
        let width = Self.width(scale: ids.first.map(scale(of:)) ?? 2)
        Task {
            let got = await capture.stills(ids, width: width)
            taking.subtract(ids)
            guard mode == .stills, inUse else { return then([:]) }
            if got.refused { needsReopen = true }
            for (id, still) in got.images where streams[id] == nil {
                set(still, of: id)
                leftWith.insert(id)
            }
            then(got.images)
        }
    }

    /// Live: a stream for each window in `ids`, none for any other.
    private func run(_ ids: Set<Int>) {
        wanted = ids
        for (id, stream) in streams where !ids.contains(id) {
            stream.stop()
            streams[id] = nil
            starts[id] = nil
        }
        for id in ids where streams[id] == nil && !taking.contains(id) {
            taking.insert(id)
            let start = UUID()
            starts[id] = start // before the start, so a stream that ends at once still clears its place
            let width = Self.liveWidth(scale: scale(of: id))
            Task { [weak self, capture] in
                let begun = await capture.live(id, width: width, frame: { [weak self] image in
                    guard let self, mode == .live, wanted.contains(id) else { return }
                    set(image, of: id)
                }, ended: { [weak self] in
                    guard let self, starts[id] == start else { return }
                    streams[id] = nil
                    starts[id] = nil
                })
                guard let self else {
                    if case .started(let stream) = begun { stream.stop() }
                    return
                }
                taking.remove(id)
                switch begun {
                case .started(let stream):
                    guard mode == .live, inUse, wanted.contains(id), streams[id] == nil, starts[id] == start else {
                        if starts[id] == start { starts[id] = nil }
                        return stream.stop()
                    }
                    streams[id] = stream
                case .refused:
                    if starts[id] == start { starts[id] = nil }
                    needsReopen = true
                case .failed:
                    if starts[id] == start { starts[id] = nil }
                }
            }
        }
    }

    private func stopAll() {
        stopHover()
        wanted = []
        streams.values.forEach { $0.stop() }
        streams = [:]
        starts = [:]
    }

    /// `pilot status --part shelf`'s pictures: the mode, whether Screen Recording is missing (read only while pictures
    /// are on), how many stills and live pictures run, and what Pilot costs now: its memory footprint and its CPU share
    /// over `over` (T14's measure, Live on with four shelved windows).
    func status(over: Duration = .seconds(2)) async -> JSONValue {
        let start = ProcessCost.now()
        try? await Task.sleep(for: over)
        let end = ProcessCost.now()
        // What the pictures hold now: each one's pixels, four bytes each.
        let held = pictures.values.compactMap(\.image).reduce(0) { $0 + $1.width * $1.height * 4 }
        return .object(["mode": .string(mode.rawValue), "lacksScreenRecording": .bool(lacksPermission), "needsReopen": .bool(needsReopen),
                        "stills": .number(Double(mode == .stills ? pictures.values.count { $0.image != nil } : 0)), "live": .number(Double(streams.count)),
                        "picturesKB": .number(Double(held / 1024)),
                        "pilotMemoryMB": .number((Double(end.footprint) / 1_048_576).rounded()),
                        "pilotCPUPercent": .number(end.cpuPercent(since: start))])
    }
}

/// One window's picture.
@Observable @MainActor
final class ShelfPicture {
    var image: CGImage?
    /// The window's corner radius as a share of its width (ShelfStill.corner).
    var corner: CGFloat = 0
}

/// One window's still as the shelf keeps it: the picture at its card's pixels, and the window's own corner radius as a
/// share of its width, read off the capture's clear corner (macOS draws each window's corner; a capture without the
/// shadow leaves the pixels outside it clear), so a card and its Fly round as that window does.
struct ShelfStill: @unchecked Sendable {
    let image: CGImage
    let corner: CGFloat

    /// What ScreenCaptureKit is asked for to make a still `width` pixels across: three times that, at most 1,024 (twice
    /// it on Retina, where the card is already 510), never more than the window's own pixels. Its own scaler then
    /// shrinks a 3,440 pt window about 4.5 times, not 17, and `init(capture:width:)` does the rest in one filtered pass.
    static func captureWidth(_ width: Int, window pixels: Int) -> Int {
        max(1, min(pixels, min(width * 3, max(1024, width * 2))))
    }

    init(image: CGImage, corner: CGFloat) {
        self.image = image
        self.corner = corner
    }

    /// `capture` shrunk to `width` pixels across in one high-quality pass (a smaller capture is kept at its size), and
    /// its corner read off the capture itself, where it is several pixels round; nil when it cannot be drawn.
    init?(capture: CGImage, width: Int) {
        let width = min(width, capture.width)
        let height = max(1, Int((CGFloat(capture.height) * CGFloat(width) / CGFloat(max(capture.width, 1))).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: capture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(capture, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        self.init(image: image, corner: Self.corner(of: capture))
    }

    /// The window's corner radius as a share of the capture's width: how far the clear corner reaches along the top-left
    /// diagonal, summed as coverage so a radius of a few pixels still reads to a fraction of one. A circle's corner meets
    /// the diagonal at r(1 - 1/√2) from the edge. 0 for a capture with no clear corner.
    static func corner(of capture: CGImage) -> CGFloat {
        let side = min(64, capture.width / 4, capture.height / 4)
        guard side > 2 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let read: CGFloat? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // The capture's top-left `side` square at its own pixels: the image drawn so its top edge meets the context's.
            context.draw(capture, in: CGRect(x: 0, y: CGFloat(side - capture.height), width: CGFloat(capture.width), height: CGFloat(capture.height)))
            var clear: CGFloat = 0
            for t in 0..<side {
                let alpha = CGFloat(bytes[(t * side + t) * 4 + 3]) / 255
                clear += 1 - alpha
                if alpha > 0.99 { break }
            }
            return clear
        }
        guard let clear = read, clear > 0.05 else { return 0 }
        return clear / (1 - 1 / 2.squareRoot()) / CGFloat(capture.width)
    }
}

/// Pilot's own memory footprint (what Activity Monitor's Memory shows) and CPU time, read twice for a share.
struct ProcessCost {
    let footprint: UInt64
    let cpu: UInt64
    let at: UInt64

    static func now() -> ProcessCost {
        // The footprint as Activity reads it (ActivityMonitor.readProcesses).
        var info = rusage_info_v0()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0) }
        }
        return ProcessCost(footprint: ok == 0 ? info.ri_phys_footprint : 0,
                           cpu: clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID), at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// The CPU share between `start` and this reading, in percent of one core, to a tenth.
    func cpuPercent(since start: ProcessCost) -> Double {
        guard at > start.at else { return 0 }
        return (Double(cpu - start.cpu) / Double(at - start.at) * 1000).rounded() / 10
    }
}

/// The real captures: ScreenCaptureKit only. A shelved window waits in the hide corner, so windows are looked up on
/// screen or not, as the menu bar's pictures are (SCMenuBarCapture); each capture is the window alone, at thumbnail size.
struct SCShelfCapture: ShelfCapturing {
    func allowed() -> Bool { CGPreflightScreenCaptureAccess() }

    func stills(_ ids: [Int], width: Int) async -> (images: [Int: ShelfStill], refused: Bool) {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { return ([:], Self.refused(error)) }
        var out: [Int: ShelfStill] = [:]
        for window in content.windows where ids.contains(Int(window.windowID)) {
            // Its own pixels: the scale of the screen it was last on (its frame is in the display space, top-left
            // origin; a screen's in AppKit's), else Retina's.
            let f = window.frame, top = NSScreen.screens.first?.frame.maxY ?? 0
            let place = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
            let scale = NSScreen.screens.first { $0.frame.intersects(place) }?.backingScaleFactor ?? 2
            let config = Self.config(window.frame.size, width: ShelfStill.captureWidth(width, window: Int(window.frame.width * scale)))
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                       configuration: config)
                if !Self.isBlank(image), let still = ShelfStill(capture: image, width: width) { out[Int(window.windowID)] = still }
            } catch {
                if Self.refused(error) { return (out, true) }
            }
        }
        return (out, false)
    }

    /// A picture with nothing in it, as a minimized window may give: the shelf keeps the icon instead. Read at 8 × 8.
    private static func isBlank(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let context = CGContext(data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
    }

    /// macOS turned the capture down: granted, it applies only once Pilot reopens (PilotCapture.failed, Build 71).
    private static func refused(_ error: Error) -> Bool { (error as? SCStreamError)?.code == .userDeclined }

    @MainActor
    func live(_ id: Int, width: Int, frame: @escaping @MainActor (CGImage) -> Void,
              ended: @escaping @MainActor () -> Void) async -> ShelfLiveStart {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { return Self.refused(error) ? .refused : .failed }
        guard let window = content.windows.first(where: { Int($0.windowID) == id }) else { return .failed }
        let config = Self.config(window.frame.size, width: width)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        let output = ShelfStreamOutput(frame: frame, ended: ended)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: ShelfStreamOutput.queue)
            try await stream.startCapture()
        } catch {
            shelflog.error("live picture of \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return Self.refused(error) ? .refused : .failed
        }
        return .started(ShelfLiveStream(stream: stream, output: output))
    }

    /// A window's capture `width` pixels across, its shape kept, no cursor or shadow: a card is that wide and crops a
    /// tall window to its top, so the width alone sets the scale.
    private static func config(_ size: CGSize, width: Int) -> SCStreamConfiguration {
        let scale = CGFloat(width) / max(size.width, 1)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = .clear
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }
}

/// One live picture's stream, stopped once.
@MainActor
private final class ShelfLiveStream: ShelfLiveCapture {
    private var stream: SCStream?
    private let output: ShelfStreamOutput

    init(stream: SCStream, output: ShelfStreamOutput) {
        self.stream = stream
        self.output = output
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        let job = Unchecked(stream)
        Task { try? await job.value.stopCapture() }
    }
}

/// A live picture's frames, made images on the stream's own queue and handed to the main actor.
private final class ShelfStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.banozz.pilot.shelf.live", qos: .utility)
    private let frame: @MainActor (CGImage) -> Void
    private let ended: @MainActor () -> Void

    init(frame: @escaping @MainActor (CGImage) -> Void, ended: @escaping @MainActor () -> Void) {
        self.frame = frame
        self.ended = ended
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only frames with new pixels, as the recorder takes them; an idle frame repeats the last.
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        let frame = frame, picture = Unchecked(image)
        Task { @MainActor in frame(picture.value) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        shelflog.notice("live picture stopped: \(String(describing: error), privacy: .public)")
        let ended = ended
        Task { @MainActor in ended() }
    }
}
