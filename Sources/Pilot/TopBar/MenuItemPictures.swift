import AppKit
import Observation
import OSLog
import ScreenCaptureKit

/// One stretch of the macOS menu bar as captured: a window over the items, its frame in global points from the top left.
struct CapturedBar: @unchecked Sendable {
    let frame: CGRect
    let image: CGImage
}

/// The menu bar's pixels, behind a protocol so tests never capture the screen or ask Screen Recording.
protocol MenuBarCapturing: Sendable {
    /// Whether Screen Recording is granted, asked without a prompt.
    func allowed() -> Bool
    /// Asks Screen Recording: macOS's prompt, once.
    func ask()
    /// Every menu bar window over `frames` but `ownPid`'s, captured.
    func capture(over frames: [CGRect], ownPid: pid_t) async throws -> [CapturedBar]
}

/// Other apps' menu bar items as macOS draws them (Sven's yes, 2026-10-10, ADR 0012), for the top bar's drawer only.
/// Off until Show exact menu bar items is on: before that nothing here asks Screen Recording, its state or the screen.
/// On, each MenuApps scan (the drawer opening, a hover, an app launching or quitting; never a timer) captures the menu
/// bar's windows over the items, as few as macOS has (macOS 27 draws every item in MenuBarAgent's one bar window,
/// macOS 26 gives each its own), and crops each item at its own frame, cut to its marks. An item whose crop comes back
/// empty (the bar hidden, macOS not drawing it) keeps the picture it last had, else draws its glyph (MenuAppGlyph).
@Observable @MainActor
final class MenuItemPictures {
    struct Picture: Equatable {
        /// A template (MenuItemPictures.ink) for a grey item, drawn in the bar's glyph colour; a coloured one as it is.
        let image: NSImage
        static func == (a: Self, b: Self) -> Bool { a.image === b.image }
    }

    private(set) var pictures: [MenuItemHandle: Picture] = [:]
    @ObservationIgnored private let capturer: any MenuBarCapturing
    @ObservationIgnored private let isOn: @MainActor () -> Bool
    @ObservationIgnored private let ownPid: pid_t
    @ObservationIgnored private var capturing = false
    /// Items asked for during a capture, captured once it ends, so a launch or the drawer opening is never missed.
    @ObservationIgnored private var queued: [MenuApps.Item]?
    nonisolated private static let log = Logger(subsystem: "dev.banozz.pilot", category: "menu-pictures")

    init(capturer: any MenuBarCapturing = SCMenuBarCapture(), ownPid: pid_t = ProcessInfo.processInfo.processIdentifier,
         isOn: @escaping @MainActor () -> Bool = { BarItemsStore.shared.settings.exactMenuItems }) {
        self.capturer = capturer
        self.ownPid = ownPid
        self.isOn = isOn
    }

    func picture(_ item: MenuApps.Item) -> Picture? { pictures[item.handle] }

    static let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Show exact menu bar items turned on or off: on asks macOS's Screen Recording prompt, unless it is granted; off
    /// drops every picture at once.
    func toggled() {
        if lacksPermission { capturer.ask() }
        if !isOn() { pictures = [:] }
    }

    /// Whether the toggle is on and Screen Recording is not granted, for the toggle's row.
    var lacksPermission: Bool { isOn() && !capturer.allowed() }

    /// Captures and crops `items` afresh; with the toggle off or Screen Recording not granted, drops every picture and
    /// asks nothing more.
    func refresh(_ items: [MenuApps.Item]) async {
        guard isOn(), capturer.allowed() else {
            if !pictures.isEmpty { pictures = [:] }
            return
        }
        guard !capturing else { queued = items; return }
        capturing = true
        defer {
            capturing = false
            if let next = queued { queued = nil; Task { await refresh(next) } }
        }
        let placed = items.compactMap { item in item.frame.map { (item.handle, $0) } }
        guard !placed.isEmpty else { return }
        let bars: [CapturedBar]
        do {
            bars = try await capturer.capture(over: placed.map(\.1), ownPid: ownPid)
        } catch {
            Self.log.error("capture failed: \(String(describing: error), privacy: .public)")
            return
        }
        // The pixel passes off the main thread.
        let cropped = await Task.detached(priority: .utility) {
            placed.compactMap { handle, frame in
                Self.crop(frame, from: bars).map { image in
                    // The item's frame across the crop's pixels gives each pixel's points, kept for the inked part alone.
                    let unit = frame.width / CGFloat(image.width), inked = Self.trimmed(image)
                    let size = NSSize(width: CGFloat(inked.width) * unit, height: CGFloat(inked.height) * unit)
                    return Cropped(handle: handle, picture: Self.picture(inked, size: size))
                }
            }
        }.value
        // An item with no crop keeps its last picture; a gone item's goes.
        var fresh: [MenuItemHandle: Picture] = [:]
        for (handle, _) in placed { fresh[handle] = pictures[handle] }
        for crop in cropped { fresh[crop.handle] = crop.picture }
        Self.log.info("captured \(bars.count) bar windows, \(cropped.count) of \(placed.count) items pictured")
        pictures = fresh
    }

    private struct Cropped: @unchecked Sendable {
        let handle: MenuItemHandle
        let picture: Picture
    }

    /// The item's stretch of the first bar window over it that drew it: the window's full height, the item's width,
    /// skipping a window that drew nothing there or filled it (a backdrop).
    nonisolated static func crop(_ item: CGRect, from bars: [CapturedBar]) -> CGImage? {
        for bar in bars where bar.frame.minX <= item.minX + 1 && bar.frame.maxX >= item.maxX - 1 && bar.frame.width > 0 {
            let scale = CGFloat(bar.image.width) / bar.frame.width
            let rect = CGRect(x: ((item.minX - bar.frame.minX) * scale).rounded(), y: 0,
                              width: (item.width * scale).rounded(), height: CGFloat(bar.image.height))
            guard let cropped = bar.image.cropping(to: rect), case let ink = coverage(cropped), ink > 0.005, ink < 0.9 else { continue }
            return cropped
        }
        return nil
    }

    /// A crop as a Picture at `size` points, with its template when it drew in greys.
    nonisolated static func picture(_ image: CGImage, size: NSSize) -> Picture {
        let mask = ink(image), picture = NSImage(cgImage: mask ?? image, size: size)
        picture.isTemplate = mask != nil
        return Picture(image: picture)
    }

    /// The item's marks as a template's alpha, or nil when it drew in colour (a tenth of its solid pixels vivid). macOS
    /// draws a status item black on a light menu bar and white on a dark one, its readings in a lighter grey, with the
    /// wallpaper's tint; Pilot's bar is neither, so black items stood black on a red bar (Sven, 2026-10-11). Each pixel
    /// keeps its alpha times how far it stands from the bar it was drawn for: dark marks (the solid pixels' mean below
    /// half) by their darkness, light ones by their lightness, stretched so the strongest is full ink. A badge's hole
    /// (a light mark inside a dark tile) stays a hole.
    nonisolated static func ink(_ image: CGImage) -> CGImage? {
        rgba(image) { context, data in
            let w = image.width, h = image.height
            var luma = [Double](repeating: 0, count: w * h)
            var solid = 0, vivid = 0, sum = 0.0, low = 1.0, high = 0.0
            for i in 0..<(w * h) {
                let a = Double(data[i * 4 + 3])
                guard a > 0 else { continue }
                let r = Double(data[i * 4]) / a, g = Double(data[i * 4 + 1]) / a, b = Double(data[i * 4 + 2]) / a
                luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                guard a > 128 else { continue }
                if max(r, g, b) - min(r, g, b) > 0.35 { vivid += 1 }
                (solid, sum, low, high) = (solid + 1, sum + luma[i], min(low, luma[i]), max(high, luma[i]))
            }
            guard solid > 0, vivid * 10 < solid else { return nil }
            let dark = sum / Double(solid) < 0.5
            for i in 0..<(w * h) where data[i * 4 + 3] > 0 {
                let strength = dark ? (1 - luma[i]) / max(1 - low, 0.01) : luma[i] / max(high, 0.01)
                // Black at the new alpha, premultiplied.
                data[i * 4 + 3] = UInt8((Double(data[i * 4 + 3]) * min(max(strength, 0), 1)).rounded())
                (data[i * 4], data[i * 4 + 1], data[i * 4 + 2]) = (0, 0, 0)
            }
            return context.makeImage()
        } ?? nil
    }

    /// The crop cut to its marks: macOS's own room round an item and the bar's height above and below it go, so the
    /// drawer spaces and centres each item as the bar does its own (Sven on build 82: the pictures sat cramped); the
    /// crop as it is when nothing there is drawn.
    nonisolated static func trimmed(_ image: CGImage) -> CGImage {
        let box = rgba(image) { _, data -> CGRect? in
            let w = image.width, h = image.height
            var (minX, minY, maxX, maxY) = (w, h, -1, -1)
            for y in 0..<h {
                for x in 0..<w where data[(y * w + x) * 4 + 3] > 0 {
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
            return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        } ?? nil
        return box.flatMap { image.cropping(to: $0) } ?? image
    }

    /// The share of the image's pixels more than half opaque.
    nonisolated static func coverage(_ image: CGImage) -> Double {
        rgba(image) { _, data in
            let count = image.width * image.height
            var opaque = 0
            for i in 0..<count where data[i * 4 + 3] > 128 { opaque += 1 }
            return Double(opaque) / Double(count)
        } ?? 0
    }

    /// `body` over the image drawn into a premultiplied RGBA context of its own size, top row first, and that context's
    /// bytes, alive for as long as `body` runs; nil when the image has no pixels.
    nonisolated private static func rgba<T>(_ image: CGImage, _ body: (CGContext, UnsafeMutablePointer<UInt8>) -> T) -> T? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                    space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return withExtendedLifetime(context) { body(context, data) }
    }
}

/// The real capture: ScreenCaptureKit's windows (on screen or not) in the menu bar's levels (24, the bar; 25, the
/// status items) over the items, each captured on its own at the screen's scale. Called only with Screen Recording
/// granted (MenuItemPictures).
struct SCMenuBarCapture: MenuBarCapturing {
    func allowed() -> Bool { CGPreflightScreenCaptureAccess() }
    /// macOS's prompt, and the Screen Recording list with the drag panel beside it: a row left by an older signature of
    /// Pilot keeps the prompt from showing (Sven, Build 71).
    func ask() {
        guard !CGRequestScreenCaptureAccess() else { return }
        Task { @MainActor in PermissionDragPanel.openScreenRecording() }
    }

    func capture(over frames: [CGRect], ownPid: pid_t) async throws -> [CapturedBar] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = content.windows.filter { window in
            [24, 25].contains(window.windowLayer) && window.frame.height <= 44 && window.frame.minY <= 1
                && window.owningApplication?.processID != ownPid
                && frames.contains { $0.minX >= window.frame.minX - 1 && $0.maxX <= window.frame.maxX + 1 }
        }
        let scale = await MainActor.run { NSScreen.screens.map(\.backingScaleFactor).max() ?? 2 }
        var bars: [CapturedBar] = []
        for window in windows {
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.backgroundColor = .clear
            config.pixelFormat = kCVPixelFormatType_32BGRA
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                          configuration: config) else { continue }
            bars.append(CapturedBar(frame: window.frame, image: image))
        }
        return bars
    }
}
