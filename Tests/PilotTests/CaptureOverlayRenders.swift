#if DEBUG
import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The capture overlay (spec `capture.html` CP3) drawn offscreen over a made-up still: an area mid-drag with its size,
/// window mode with the hovered window ringed, and the pointer in a corner, where the loupe flips inside the display.
/// Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter CaptureOverlayRenders`
@MainActor
@Suite("Capture overlay renders")
struct CaptureOverlayRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let size = CGSize(width: 1200, height: 750)
    static let windows = [CaptureSelection.Window(id: 1, frame: CGRect(x: 140, y: 110, width: 560, height: 380)),
                          CaptureSelection.Window(id: 2, frame: CGRect(x: 620, y: 260, width: 460, height: 360))]

    /// A desktop: a gradient, two "windows" with title bars and a few lines of "text", at 2x.
    static func still() -> CGImage {
        let scale = 2, w = Int(size.width) * scale, h = Int(size.height) * scale
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1), CGColor(red: 0.55, green: 0.32, blue: 0.5, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Core Graphics draws from the bottom left; the overlay's points run from the top left.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
        for (i, window) in windows.reversed().enumerated() {
            let frame = flip(window.frame)
            ctx.setFillColor(CGColor(gray: i == 0 ? 0.96 : 0.9, alpha: 1))
            ctx.fill(frame)
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28))
            for (j, colour) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                                CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
                ctx.setFillColor(colour)
                ctx.fillEllipse(in: CGRect(x: frame.minX + 12 + CGFloat(j) * 18, y: frame.maxY - 20, width: 12, height: 12))
            }
            ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
            for line in 0..<8 {
                ctx.fill(CGRect(x: frame.minX + 24, y: frame.maxY - 60 - CGFloat(line) * 26, width: frame.width * (line % 3 == 2 ? 0.45 : 0.8), height: 9))
            }
        }
        return ctx.makeImage()!
    }

    static func states() -> [(String, CaptureSelection)] {
        var drag = CaptureSelection(size: size, windows: windows)
        drag.press(at: CGPoint(x: 180, y: 160))
        drag.move(to: CGPoint(x: 640, y: 420))
        var window = CaptureSelection(size: size, windows: windows, mode: .window, pointer: CGPoint(x: 800, y: 400))
        window.move(to: CGPoint(x: 800, y: 400))
        let corner = CaptureSelection(size: size, windows: windows, pointer: CGPoint(x: 1150, y: 720))
        // Smart selection (Q189): a text line of the front window ringed as the UI element under the pointer.
        var element = CaptureSelection(size: size, windows: windows, pointer: CGPoint(x: 300, y: 190))
        _ = element.key(.smart)
        element.element = CGRect(x: 164, y: 187, width: 448, height: 9)
        return [("1-area-drag", drag), ("2-window", window), ("3-corner-loupe", corner), ("4-smart-element", element)]
    }

    @Test("The overlay draws a drag, a hovered window and the loupe at the display's corner",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("capture-overlay")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let grab = DisplayGrab(id: 1, frame: CGRect(origin: .zero, size: Self.size), scale: 2, image: Self.still())
        for (name, selection) in Self.states() {
            let view = CaptureOverlayView(grab: grab, selection: selection, accent: CaptureOverlay.accent()) { _, _ in }
            let rep = try #require(snapshot(view, scale: 1))
            try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    @Test("Smart on, a loose drag inside the front window snaps to its lines of text; smart off, it stays as dragged")
    func snap() {
        let grab = DisplayGrab(id: 1, frame: CGRect(origin: .zero, size: Self.size), scale: 2, image: Self.still())
        var selection = CaptureSelection(size: Self.size, windows: Self.windows)
        let loose = CaptureSelection.Outcome.area(CGRect(x: 150, y: 145, width: 540, height: 335))
        let plain = CaptureOverlayView(grab: grab, selection: selection, accent: .red) { _, _ in }
        #expect(plain.snapped(loose) == loose)
        _ = selection.key(.smart)
        let view = CaptureOverlayView(grab: grab, selection: selection, accent: .red) { _, _ in }
        // Eight lines from y 161, 26 apart, 9 high; the longest 448 wide from x 164.
        #expect(view.snapped(loose) == .area(CGRect(x: 164, y: 161, width: 448, height: 191)))
        #expect(view.snapped(.window(1)) == .window(1))
    }

    @Test("A asks the app under the pointer for its UI element and rings the smallest; the wheel walks out and back")
    func element() async throws {
        let grab = DisplayGrab(id: 1, frame: CGRect(x: 100, y: 50, width: Self.size.width, height: Self.size.height), scale: 2, image: Self.still())
        let windows = [CaptureSelection.Window(id: 1, frame: CGRect(x: 140, y: 110, width: 560, height: 380), owner: 4242)]
        let view = CaptureOverlayView(grab: grab, selection: CaptureSelection(size: Self.size, windows: windows, pointer: CGPoint(x: 300, y: 190)),
                                      accent: .red) { _, _ in }
        // Global points, as Accessibility gives them: a text line, its group, the window.
        view.findElements = { point, pid in
            pid == 4242 && point == CGPoint(x: 400, y: 240)
                ? [CGRect(x: 264, y: 237, width: 448, height: 9), CGRect(x: 250, y: 200, width: 520, height: 220), CGRect(x: 240, y: 160, width: 560, height: 380)]
                : []
        }
        let a = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                              characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        view.keyDown(with: a)
        #expect(view.selection.smart)
        for _ in 0..<100 where view.selection.element == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.selection.element == CGRect(x: 164, y: 187, width: 448, height: 9))
        let up = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: up)))
        #expect(view.selection.element == CGRect(x: 150, y: 150, width: 520, height: 220))
        let down = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: down)))
        #expect(view.selection.element == CGRect(x: 164, y: 187, width: 448, height: 9))
        view.keyDown(with: a)
        #expect(!view.selection.smart && view.selection.element == nil)
    }

    @Test("The pixel under a point reads back as its hex")
    func hex() {
        let grab = DisplayGrab(id: 1, frame: CGRect(origin: .zero, size: Self.size), scale: 2, image: Self.still())
        let view = CaptureOverlayView(grab: grab, selection: CaptureSelection(size: Self.size), accent: .red) { _, _ in }
        // The front window's title bar, grey 0.8 → #CCCCCC.
        #expect(view.hex(at: CGPoint(x: 400, y: 120)) == "#CCCCCC")
        #expect(view.hex(at: CGPoint(x: 5000, y: 5000)) == nil)
    }
}
#endif
