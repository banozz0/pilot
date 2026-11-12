import AppKit
import PilotCore
import ScreenCaptureKit

/// One display as grabbed at the press: its frame in global points (top left of the main display, y down), its scale
/// and its pixels.
struct DisplayGrab: @unchecked Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage
}

extension DisplayGrab {
    /// `rect`, in the display's points, cut from the still on whole pixels; nil when it has none.
    func crop(_ rect: CGRect) -> CGImage? {
        let pixels = CaptureSelection.pixels(rect, scale: scale, within: CGSize(width: image.width, height: image.height))
        return pixels.isEmpty ? nil : image.cropping(to: pixels)
    }
}

/// The screen's pixels, behind a protocol so tests never capture the screen or ask Screen Recording (ADR 0012, as
/// amended 2026-10-16: nothing here runs before a capture key is pressed).
protocol ScreenGrabbing: Sendable {
    /// Whether Screen Recording is granted, asked without a prompt.
    func allowed() -> Bool
    /// Asks Screen Recording: macOS's prompt, once.
    func ask()
    /// Every display, grabbed at once, everything on it: Pilot's top bar, its extension items and its windows too (Sven,
    /// build 52). The capture overlay is not up yet when the grab runs; only the desktop icons go, when Captures says so.
    func displays() async throws -> [DisplayGrab]
    /// The on-screen windows of other apps, front first, frames in global points.
    func windows() async throws -> [CaptureSelection.Window]
    /// One window alone, its shadow trimmed, at `scale`.
    func window(_ id: UInt32, scale: CGFloat) async throws -> CGImage
}

/// ScreenCaptureKit's display and window objects, or a still, handed to the task that works on them.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum GrabError: Error, LocalizedError {
    case noWindow

    var errorDescription: String? { "That window closed before it was captured." }
}

/// The real grab: ScreenCaptureKit only (`SCScreenshotManager`), never `CGWindowListCreateImage`, obsolete since macOS 15.
struct SCScreenGrabber: ScreenGrabbing {
    func allowed() -> Bool { CGPreflightScreenCaptureAccess() }
    /// macOS's prompt, and the Screen Recording list with the drag panel beside it: a row left by an older signature of
    /// Pilot keeps the prompt from showing (Sven, Build 71).
    func ask() {
        guard !CGRequestScreenCaptureAccess() else { return }
        Task { @MainActor in PermissionDragPanel.openScreenRecording() }
    }

    /// Whether Captures › Hide desktop icons is on, read at each grab; a test's own.
    var hidesIcons: @Sendable () async -> Bool = { await MainActor.run { CaptureSettingsStore.shared.settings.hideDesktopIcons } }

    func displays() async throws -> [DisplayGrab] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let icons = await hidesIcons() ? content.desktopIcons() : []
        let scales = await MainActor.run {
            Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s.backingScaleFactor) } }, uniquingKeysWith: { a, _ in a })
        }
        return try await withThrowingTaskGroup(of: DisplayGrab.self) { group in
            for d in content.displays {
                let scale = scales[d.displayID] ?? 2
                // ScreenCaptureKit's objects are not Sendable; each task reads its own display and the shared list only.
                let job = Unchecked((d, icons))
                group.addTask {
                    let (display, icons) = job.value
                    let config = SCStreamConfiguration()
                    config.width = Int(CGFloat(display.width) * scale)
                    config.height = Int(CGFloat(display.height) * scale)
                    config.showsCursor = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    let filter = SCContentFilter(display: display, excludingWindows: icons)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return DisplayGrab(id: display.displayID, frame: display.frame, scale: scale, image: image)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }

    func windows() async throws -> [CaptureSelection.Window] {
        // The window server's front-to-back order; ScreenCaptureKit's list has none. Frames and ids need no permission.
        // Pilot's own windows (its app window, the editor, a pin) can be picked like any other (Sven, build 52).
        // A see-through window clicks pass through is not one Sven means, and it captures as nothing: Pilot's own window
        // border sits just outside the focused window, an agent's cursor overlay covers a whole display (build 2354's
        // blank window capture). Pilot's are known by their flag; another app's are measured below. A window never shown
        // has no number (-1), which UInt32 traps on (build 2359's crash), so only real numbers count.
        let clickThrough = await MainActor.run {
            Set(NSApp.windows.filter(\.ignoresMouseEvents).compactMap { UInt32(exactly: $0.windowNumber) })
        }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [CaptureSelection.Window] = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32, !clickThrough.contains(id),
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return CaptureSelection.Window(id: id, frame: frame, owner: w[kCGWindowOwnerPID as String] as? Int32 ?? 0)
        }
        let seeThrough = await Self.seeThrough(windows)
        return seeThrough.isEmpty ? windows : windows.filter { !seeThrough.contains($0.id) }
    }

    /// The windows of background apps (not in the Dock, not Pilot) that are almost all transparent: overlays such as a
    /// cursor layer or a border. Each is grabbed once, small, at the press; an ordinary app's windows are never grabbed.
    private static func seeThrough(_ windows: [CaptureSelection.Window]) async -> Set<UInt32> {
        let me = getpid()
        let suspects = Set(windows.filter { w in
            w.owner > 0 && w.owner != me && NSRunningApplication(processIdentifier: w.owner)?.activationPolicy != .regular
        }.map(\.id))
        guard !suspects.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let found = Unchecked(content.windows.filter { suspects.contains($0.windowID) })
        return await withTaskGroup(of: UInt32?.self) { group in
            for index in found.value.indices {
                group.addTask {
                    let window = found.value[index]
                    let config = SCStreamConfiguration()
                    // About 128 pixels across: enough to tell a filled window from a line round its edge.
                    let scale = min(1, 128 / max(window.frame.width, 1))
                    config.width = max(Int(window.frame.width * scale), 1)
                    config.height = max(Int(window.frame.height * scale), 1)
                    config.showsCursor = false
                    config.backgroundColor = .clear
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                           configuration: config)
                    return image.map(coverage).map { $0 < 0.05 } == true ? window.windowID : nil
                }
            }
            return await group.reduce(into: []) { if let id = $1 { $0.insert(id) } }
        }
    }

    /// How much of `image` is covered, 0 to 1: its alpha summed over every pixel.
    static func coverage(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return 0 }
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return 1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Double(alpha.reduce(0) { $0 + Int($1) }) / Double(w * h * 255)
    }

    func window(_ id: UInt32, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw GrabError.noWindow }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = .clear
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let alone = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        // Grabbed alone, a see-through window (blur, glass) has nothing behind it and comes out flat grey (Ghostex's,
        // build 2363). So the window is taken as the screen shows it, its display's pixels over its frame with only the
        // windows in front of it left out, and cut to its own shape; an opaque window comes out the same either way.
        guard let display = content.displays.first(where: { $0.frame.contains(window.frame) }) else { return alone }
        let front = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(id)) as? [[String: Any]] ?? []
        var hidden = Set(front.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        if await hidesIcons() { hidden.formUnion(content.desktopIcons().map(\.windowID)) }
        let region = SCStreamConfiguration()
        region.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        region.width = config.width
        region.height = config.height
        region.showsCursor = false
        region.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { hidden.contains($0.windowID) })
        guard let screen = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: region) else { return alone }
        return Self.cut(screen, to: alone) ?? alone
    }

    /// `screen` cut to the shape of `window`, the same window grabbed alone at the same size: where the window covers
    /// its frame fully the screen's pixel, elsewhere (its rounded corners and their edge) the window's own, so an opaque
    /// window comes out exactly as grabbed alone. Nil when the sizes differ.
    static func cut(_ screen: CGImage, to window: CGImage) -> CGImage? {
        let w = window.width, h = window.height, stride = w * 4
        guard screen.width == w, screen.height == h, w > 0, h > 0 else { return nil }
        let space = screen.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, info = CGImageAlphaInfo.premultipliedLast.rawValue
        var own = [UInt8](repeating: 0, count: stride * h)
        guard let alone = CGContext(data: &own, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: space, bitmapInfo: info),
              let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: space, bitmapInfo: info),
              let pixels = out.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        alone.draw(window, in: CGRect(x: 0, y: 0, width: w, height: h))
        out.draw(screen, in: CGRect(x: 0, y: 0, width: w, height: h))
        for p in Swift.stride(from: 0, to: stride * h, by: 4) where own[p + 3] < 255 {
            for c in 0..<4 { pixels[p + c] = own[p + c] }
        }
        return out.makeImage()
    }
}

extension SCShareableContent {
    /// Finder's desktop-icon windows (DesktopIcons), which Captures › Hide desktop icons leaves out of every capture.
    func desktopIcons() -> [SCWindow] {
        windows.filter { DesktopIcons.holdsIcons(bundle: $0.owningApplication?.bundleIdentifier, layer: $0.windowLayer) }
    }
}

extension NSScreen {
    /// The Core Graphics display this screen shows.
    var displayID: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}
