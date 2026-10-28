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
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return CaptureSelection.Window(id: id, frame: frame, owner: w[kCGWindowOwnerPID as String] as? Int32 ?? 0)
        }
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
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
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
