import AppKit
import SwiftUI
import Testing
import CoreML
import Vision

/// Draws `view` into device RGB bytes at `scale` (2 is Retina, as Sven's screens draw), read back with no colour
/// conversion: the renders and the panel look test share it.
@MainActor
func snapshot(_ view: NSView, scale: Int = 1) -> NSBitmapImageRep? {
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    drawingQoS()
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// `view` drawn at its own size in a borderless window that is never shown, after a short sleep that leaves the main
/// actor to the other suites; nil when it cannot be drawn.
@MainActor
func snapshot(rendering view: some View, scale: Int = 2) async throws -> NSBitmapImageRep? {
    let w = hosted(view)
    defer { w.close() }
    try await Task.sleep(for: .milliseconds(30))
    return drawn(w, scale: scale)
}

/// `view` drawn as `snapshot(rendering:)` draws it but within one main-actor turn, so a test that changes shared state
/// such as Look's theme for its drawing has put it back before any other suite runs.
@MainActor
func snapshot(drawing view: some View, scale: Int = 2) -> NSBitmapImageRep? {
    let w = hosted(view)
    defer { w.close() }
    return drawn(w, scale: scale)
}

/// The test process's app, its scroll bars pinned to overlay: on "Show scroll bars: Automatic" a process starts on overlay
/// and moves to legacy ones once macOS sees the mouse, mid-test, and a legacy bar takes a page's width, so two draws of one
/// page differed. Registered, so only this process sees it and nothing is saved.
@MainActor
func testApp() {
    _ = NSApplication.shared
    _ = overlayScrollBars
    drawingQoS()
}

/// The main thread at the QoS Pilot.app's own main thread draws at, user-interactive: a test's runs at default, and on a
/// Mac busy with builds a draw took 1.6 times as long there (card agent-bo-95423300). Dispatch puts it back after each
/// main-actor job, so each host, draw and pump asks again.
@MainActor
func drawingQoS() { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }

private let overlayScrollBars: Void = UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])

/// `view` at its own size in a borderless window that is never shown.
@MainActor
private func hosted(_ view: some View) -> NSWindow {
    testApp()
    let host = NSHostingView(rootView: view)
    host.frame.size = host.fittingSize
    let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView = host
    return w
}

/// The hosted view laid out and drawn.
@MainActor
private func drawn(_ w: NSWindow, scale: Int) -> NSBitmapImageRep? {
    guard let host = w.contentView else { return nil }
    host.layoutSubtreeIfNeeded()
    return snapshot(host, scale: scale)
}

/// `view` drawn as `snapshot(rendering:)` draws it, as its device RGB bytes: two draws of one picture are equal.
@MainActor
func pixels(rendering view: some View) async throws -> Data {
    let rep = try #require(try await snapshot(rendering: view))
    return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
}

/// `view` drawn at its own size after `wait` seconds of the run loop, written to `url` as a 2x PNG: the opt-in renders.
@MainActor
func writeRender(_ view: some View, to url: URL, wait: Double = 0.6) throws {
    try #require(rendered(view, wait: wait).representation(using: .png, properties: [:])).write(to: url)
}

/// `view` drawn at its own size at 2x after `wait` seconds of the run loop, in a borderless window that is never shown.
@MainActor
func rendered(_ view: some View, wait: Double = 0.6) throws -> NSBitmapImageRep {
    let w = hosted(view)
    defer { w.close() }
    PanelTestSupport.pump(wait)
    return try #require(drawn(w, scale: 2))
}

/// The lines of text Vision reads in `rep` on the CPU, each with its box (0 to 1, origin bottom left), left to right.
func recognisedText(in rep: NSBitmapImageRep) throws -> [(text: String, box: CGRect)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // On the CPU: the Neural Engine stalls for a minute or fails (e5rt error 13) on a loaded Mac.
    for (stage, devices) in try request.supportedComputeStageDevices {
        if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) { request.setComputeDevice(cpu, for: stage) }
    }
    try VNImageRequestHandler(cgImage: try #require(rep.cgImage)).perform([request])
    return (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        .compactMap { result in result.topCandidates(1).first.map { ($0.string, result.boundingBox) } }
}
