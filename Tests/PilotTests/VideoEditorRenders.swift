#if DEBUG
import AppKit
import AVFoundation
import Foundation
import ImageScale
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The record editor in A (Sven, Q806; editors-round-2's record mocks and 12 parity rows): the real VideoEditorView on a
/// made-up recording of the capture editor's billing page (VideoFixture) with a pointer track of three clicks, each
/// inspector tab, a picked zoom following and holding, the backdrop, cropping, an export running in the bar, undo and
/// redo, and the smallest and a large window, in Instrument (Tokyo Night, Folio) and Toybox (toybox-night, toybox). The
/// preview's AVPlayerLayer draws nothing into a snapshot, so each state's preview frame is read through the editor's own
/// composition and shown in its place (VideoEditorView.still). Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter VideoEditorRenders`
extension SharedLook {
@MainActor
@Suite("Video editor renders")
struct VideoEditorRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let size = CGSize(width: 1280, height: 800)
    static let largest = CGSize(width: 1680, height: 1050)

    @Test("The editor renders in Instrument and Toybox, dark and light: each tab, a zoom, crop, an export, redo",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("video-editor")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let movies = URL(fileURLWithPath: home).appending(path: "Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let url = movies.appending(path: "Recording 22.40.mov")
        try await VideoFixture.clip(to: url, seconds: 12, fps: 15)
        let pointers = URL(fileURLWithPath: home).appending(path: "video-editor-pointer")
        try FileManager.default.createDirectory(at: pointers, withIntermediateDirectories: true)
        try VideoFixture.track.save(for: url, in: pointers)
        // A look saved by an earlier run (state 17) would open every state in it.
        let library = BackdropLibrary.shared
        library.setEveryRecording(nil)
        for p in library.videoPresets { library.deleteVideoPreset(p.id) }

        // Each state a model of its own, set up as Sven would leave it, with its preview frame.
        var states: [(name: String, model: VideoEditorModel, still: CGImage?)] = []
        func state(_ name: String, _ setUp: (VideoEditorModel) async throws -> Void) async throws {
            let model = VideoEditorModel(url: url)
            await model.load(pointerFolder: pointers)
            try #require(model.loaded, "\(model.failed ?? "not loaded")")
            try await setUp(model)
            states.append((name, model, await Self.still(model)))
        }
        try await state("1-clip") { m in
            m.trim(in: 1); m.trim(out: 11); m.show(2.4)
        }
        try await state("2-zoom") { m in
            let zoom = try #require(m.edit.zooms.dropFirst().first)
            m.selected = zoom.id
            m.show(zoom.start + 0.8)
        }
        try await state("3-zoom-hold") { m in
            let zoom = try #require(m.edit.zooms.last)
            m.selected = zoom.id
            m.setLevel(2.5)
            m.setFocus(CGPoint(x: 0.8, y: 0.2))
            m.show(zoom.start + 0.8)
        }
        try await state("4-zoom-none") { m in m.tab = .zoom; m.show(4) }
        try await state("5-backdrop") { m in
            m.setBackdrop(Backdrop(fill: .gradient([0x2BC4F0, 0x6E5BF2, 0xC6F432])))
            m.tab = .backdrop
            m.show(3)
        }
        try await state("6-export") { m in
            m.trim(in: 1); m.trim(out: 9); m.setSpeed(1.5)
            m.format = .gif; m.exportSize = .p720
            m.tab = .export
            m.show(2)
        }
        try await state("7-crop") { m in
            m.trim(in: 1)
            m.startCrop()
            m.dragCrop(CGRect(x: 0.2, y: 0.08, width: 0.76, height: 0.8))
            m.show(1)
        }
        try await state("8-exporting") { m in
            m.trim(in: 1); m.trim(out: 11)
            m.startCrop(); m.dragCrop(CGRect(x: 0.22, y: 0.1, width: 0.74, height: 0.78)); m.finishCrop(keep: true)
            m.showExporting(0.42, format: .h264)
            m.show(1)
        }
        try await state("9-history") { m in
            m.setSpeed(2); m.trim(in: 2)
            m.undo()
            m.show(1)
        }
        // Redo's state: one step back and one to go.
        let history = try #require(states.last?.model)
        #expect(history.canUndo && history.canRedo && history.edit.speed == 2 && history.edit.trimIn == 0)
        history.redo()
        #expect(history.edit.trimIn == 2 && !history.canRedo)
        history.undo()
        // T28: split into parts, one cut, one at 4×, the still parts suggested, a blur picked over the live key.
        try await state("13-parts-blur") { m in
            m.show(2); m.split(); m.show(3.4); m.split(); m.show(2.6); m.toggleCut()
            m.show(6); m.split(); m.show(8); m.split(); m.show(7); m.setPartSpeed(4)
            let size = CaptureFixture.size, key = CaptureFixture.keyValue.insetBy(dx: -8, dy: -6)
            m.addBlur(at: 9)
            m.setBlurArea(CGRect(x: key.minX / size.width, y: key.minY / size.height, width: key.width / size.width, height: key.height / size.height))
            m.settle()
            m.show(9.6)
        }
        try await state("14-part-cut") { m in
            m.show(2); m.split(); m.show(3.4); m.split(); m.show(2.6); m.toggleCut()
        }
        // T30: vertical on a gradient mid-zoom (R9), square with motion blur on the Zoom tab (R10), a saved look on the
        // Export tab at 1080p (R12).
        try await state("15-vertical") { m in
            m.setBackdrop(Backdrop(fill: .gradient([0x2BC4F0, 0x6E5BF2, 0xC6F432])))
            m.setShape(.vertical)
            m.tab = .backdrop
            let zoom = try #require(m.edit.zooms.first)
            m.show(zoom.start + 0.9)
        }
        try await state("16-square-motion") { m in
            m.setShape(.square)
            m.setMotionBlur(true)
            m.tab = .zoom
            let zoom = try #require(m.edit.zooms.first)
            m.show(zoom.start + 0.25)
        }
        try await state("17-look-export") { m in
            m.setBackdrop(Backdrop(fill: .gradient([0xF7B267, 0xF25F5C, 0x8E44AD]), pad: 64, radius: 14))
            m.setShape(.vertical)
            let look = BackdropLibrary.shared.saveVideoPreset(m.edit.look)
            BackdropLibrary.shared.setEveryRecording(look)
            m.setShape(.recorded)
            m.applyPreset(look)
            m.exportSize = .p1080
            m.tab = .export
            m.show(1)
        }

        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        for pass in CaptureEditorRenders.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            func write(_ view: VideoEditorView, _ name: String, size: CGSize) throws {
                let rep = try CaptureEditorRenders.draw(view, tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("A-\(name)-\(pass.tag).png"))
            }
            for s in states { try write(VideoEditorView(model: s.model, still: s.still), s.name, size: Self.size) }
            // The smallest window (VideoEditorLayout.minSize) on Clip and on the backdrop panel; a large one on a zoom.
            for (state, name, size) in [("1-clip", "10-smallest-clip", VideoEditorLayout.minSize), ("5-backdrop", "11-smallest-backdrop", VideoEditorLayout.minSize),
                                        ("2-zoom", "12-largest-zoom", Self.largest), ("15-vertical", "18-smallest-vertical", VideoEditorLayout.minSize)] {
                let s = try #require(states.first { $0.name == state })
                try write(VideoEditorView(model: s.model, still: s.still), name, size: size)
            }
        }
        for s in states { s.model.close() }
    }

    /// The preview's frame at the playhead, read through the editor's own composition (its crop, zooms and backdrop),
    /// once the latest one is on the player; the raw frame when no composition is set.
    static func still(_ model: VideoEditorModel) async -> CGImage? {
        // refresh() builds the composition off the main thread; wait for it to settle.
        var last: AVVideoComposition?
        var steady = 0
        for _ in 0..<60 where steady < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = model.player.currentItem?.videoComposition
            steady = now != nil && now === last ? steady + 1 : 0
            last = now
        }
        let generator = AVAssetImageGenerator(asset: model.asset)
        generator.videoComposition = last
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: model.playhead, preferredTimescale: 600)).image
    }
}
}

/// The video edit's times on export (Q807): a fixture clip trimmed, and sped up, through VideoExport (VideoRender.swift)
/// comes out at the length the edit says, read back by AVFoundation. Not opt-in: it writes only temporary files, kept in
/// PILOT_RENDER_DIR/video-times when that is set, so their lengths can be read again.
@MainActor
@Suite("Video export times")
struct VideoExportTimes {
    @Test("A trimmed clip exports at its kept length, at 1× and at 2×", arguments: [1.0, 2.0])
    func trimmed(speed: Double) async throws {
        let env = ProcessInfo.processInfo.environment
        let kept = env["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appending(path: "video-times") }
        let folder = kept ?? FileManager.default.temporaryDirectory.appending(path: "pilot-video-times-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if kept == nil { try? FileManager.default.removeItem(at: folder) } }
        // A fixture per case: the two cases run side by side.
        let source = folder.appending(path: "fixture-for-\(Int(speed))x.mov")
        try await VideoFixture.clip(to: source, seconds: 4, fps: 30)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4) < 0.01, "the fixture is \(duration) s")

        var edit = VideoEdit(duration: duration)
        edit.trim(in: 1, out: 3)
        edit.speed = speed
        let target = folder.appending(path: "trimmed-1-3-at-\(Int(speed))x.mp4")
        try? FileManager.default.removeItem(at: target)
        try await VideoExport.run(asset, edit: edit, pointer: nil, picture: nil, format: .h264, size: .p720, to: target) { _ in }
        let length = try await AVURLAsset(url: target, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]).load(.duration).seconds
        print("video-times: \(target.lastPathComponent) is \(String(format: "%.3f", length)) s, expected \(edit.length) s")
        #expect(abs(length - 2 / speed) <= 1.0 / 30 + 0.005, "\(target.lastPathComponent) is \(length) s, not \(2 / speed) s")
    }

    /// R5, R6, R8 (T28): a 6 s clip split at 1, 2, 3 and 5 s, its 1–2 s part cut and its 3–5 s part at 2×, comes out
    /// 1 + 1 + 1 + 1 = 4 s; a blur over the live key from 5.1 to 5.9 s leaves that line's pixels flat in the export (the
    /// frame at 5.5 s, the export's 3.5 s) while the label above it stays as sharp as in the recording.
    @Test("A clip with a cut and a 2× part exports at its kept length, a blurred frame blurred")
    func cutSpedBlurred() async throws {
        let env = ProcessInfo.processInfo.environment
        let kept = env["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appending(path: "video-times") }
        let folder = kept ?? FileManager.default.temporaryDirectory.appending(path: "pilot-video-cuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if kept == nil { try? FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "fixture-6s.mov")
        try await VideoFixture.clip(to: source, seconds: 6, fps: 30)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds

        var edit = VideoEdit(duration: duration)
        for t in [1.0, 2, 3, 5] {
            let split = edit.split(at: t)
            #expect(split, "no split at \(t) s")
        }
        edit.setCut(edit.part(at: 1.5), true)
        edit.setSpeed(ofPart: edit.part(at: 4), 2)
        let size = CaptureFixture.size, key = CaptureFixture.keyValue
        edit.blurs = [BlurSpan(start: 5.1, end: 5.9, area: CGRect(x: key.minX / size.width, y: key.minY / size.height, width: key.width / size.width, height: key.height / size.height))]
        #expect(abs(edit.length - 4) < 0.000_1, "the edit says \(edit.length) s")
        #expect(abs(edit.output(at: 5.5) - 3.5) < 0.000_1 && abs(edit.source(at: 3.5) - 5.5) < 0.000_1)

        let target = folder.appending(path: "cut-1-2-and-3-5-at-2x.mp4")
        try? FileManager.default.removeItem(at: target)
        try await VideoExport.run(asset, edit: edit, pointer: nil, picture: nil, format: .h264, size: .full, to: target) { _ in }
        let exported = AVURLAsset(url: target, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let length = try await exported.load(.duration).seconds
        print("video-times: \(target.lastPathComponent) is \(String(format: "%.3f", length)) s, expected \(edit.length) s")
        #expect(abs(length - 4) <= 1.0 / 30 + 0.005, "\(target.lastPathComponent) is \(length) s, not 4 s")

        // The same moment from the recording and from the export, at the same size (full: one pixel each).
        let original = try await Self.frame(of: asset, at: 5.5), blurred = try await Self.frame(of: exported, at: 3.5)
        #expect(original.width == blurred.width && original.height == blurred.height, "\(original.width)×\(original.height) vs \(blurred.width)×\(blurred.height)")
        let scale = CGFloat(original.width) / size.width
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral }
        let label = CaptureFixture.run("Live key").rect
        let keyBefore = Self.spread(original, in: px(key)), keyAfter = Self.spread(blurred, in: px(key))
        let labelBefore = Self.spread(original, in: px(label)), labelAfter = Self.spread(blurred, in: px(label))
        print(String(format: "video-blur: the key's spread %.1f in the recording, %.1f in the export; the label's %.1f and %.1f", keyBefore, keyAfter, labelBefore, labelAfter))
        #expect(keyAfter < keyBefore * 0.35, "the key is not blurred: \(keyBefore) → \(keyAfter)")
        #expect(labelAfter > labelBefore * 0.7, "the blur spilled onto the label: \(labelBefore) → \(labelAfter)")
        if let kept {
            for (image, name) in [(original, "frame-5.5s-recording.png"), (blurred, "frame-5.5s-exported-at-3.5s.png")] {
                try #require(ImageFormat.png.encode(image)).write(to: kept.appending(path: name))
            }
        }
    }

    /// The frame at exactly `t` seconds of `asset`.
    nonisolated static func frame(of asset: AVAsset, at t: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    /// How far the grey levels in `rect` (pixels from the top left) stray from their mean: sharp text is high, a blur low.
    nonisolated static func spread(_ image: CGImage, in rect: CGRect) -> Double {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0.0, squares = 0.0, n = 0.0
        for y in max(0, Int(rect.minY))..<min(h, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(w, Int(rect.maxX)) {
                let v = Double(bytes[y * w + x])
                sum += v
                squares += v * v
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return (squares / n - mean * mean).squareRoot()
    }
}

/// R9, R10, R12 (T30, Q807): a fixture clip exported vertical and square at 1080p comes out 1080 × 1920 and 1080 × 1080
/// with Pilot's pointer where the shape's camera puts it, unstretched, also mid-zoom; motion blur softens a zoom easing
/// in and leaves a still camera's frame as it was; a look saved, written out and read back, applied to a second clip of
/// another length, gives the same look and the same export. Not opt-in: temporary files only, kept in
/// PILOT_RENDER_DIR/video-shapes when that is set, so `ffprobe` can read their sizes.
@MainActor
@Suite("Video shapes, motion blur and presets")
struct VideoShapeExport {
    static func folder(_ name: String) throws -> (URL, kept: Bool) {
        let kept = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appending(path: "video-shapes") }
        let folder = kept ?? FileManager.default.temporaryDirectory.appending(path: "pilot-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, kept != nil)
    }

    static func export(_ clip: URL, _ edit: VideoEdit, track: CursorTrack?, size: VideoSize, to target: URL) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: clip, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        try? FileManager.default.removeItem(at: target)
        try await VideoExport.run(asset, edit: edit, pointer: track, picture: nil, format: .h264, size: size, to: target) { _ in }
        return AVURLAsset(url: target, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    static func pixels(_ asset: AVAsset) async throws -> CGSize {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        return try await track.load(.naturalSize)
    }

    @Test("Vertical and square export at 1080 × 1920 and 1080 × 1080, the pointer where the camera puts it")
    func shapes() async throws {
        let (folder, kept) = try Self.folder("video-shapes")
        defer { if !kept { try? FileManager.default.removeItem(at: folder) } }
        let bare = folder.appending(path: "fixture-shapes.mov")
        try await VideoFixture.clip(to: bare, seconds: 4, fps: 30, pointer: false)
        // The baseline keeps the same moves as an older track (nothing drawn), so its camera follows the same pointer.
        let track = VideoPointerExport.track(drawn: true, shape: VideoPointerExport.shape), moves = VideoPointerExport.track(drawn: false, shape: nil)
        let source = try await Self.pixels(AVURLAsset(url: bare))

        for (shape, want) in [(VideoShape.vertical, CGSize(width: 1080, height: 1920)), (.square, CGSize(width: 1080, height: 1080))] {
            var edit = VideoEdit(duration: 4, backdrop: Backdrop(fill: .gradient([0x2BC4F0, 0x6E5BF2])),
                                 zooms: [ZoomSegment(start: 2.6, end: 4, level: 2)])
            edit.shape = shape
            let name = "\(shape.rawValue)-1080p"
            let with = try await Self.export(bare, edit, track: track, size: .p1080, to: folder.appending(path: "\(name).mp4"))
            let without = try await Self.export(bare, edit, track: moves, size: .p1080, to: folder.appending(path: "\(name)-no-pointer.mp4"))
            let got = try await Self.pixels(with)
            print("video-shapes: \(name).mp4 is \(VideoPointerExport.text(got)), want \(VideoPointerExport.text(want))")
            #expect(got == want, "\(name) is \(got)")

            // Where the shape's camera puts the pointer: at rest (1.5 s, no zoom, the frame following it), and mid-zoom
            // after it moved to `end` (3.4 s, zoomed 2× on the pointer).
            let layout = VideoLayout(source: source, edit: edit).fitted(to: want)
            for (t, p) in [(1.5, VideoPointerExport.rest), (3.4, VideoPointerExport.end)] {
                let view = edit.camera(at: t, cursor: track.path, window: layout.window)
                let spot = layout.spot
                let at = CGPoint(x: spot.minX + (p.x - view.minX) / view.width * spot.width, y: spot.minY + (p.y - view.minY) / view.height * spot.height)
                let a = try await VideoPointerExport.frame(with.url, at: t), b = try await VideoPointerExport.frame(without.url, at: t)
                if kept { try #require(ImageFormat.png.encode(a)).write(to: folder.appending(path: "\(name)-\(String(format: "%.1f", t))s.png")) }
                let box = VideoPointerExport.difference(a, b, within: CGRect(x: at.x - 140, y: at.y - 140, width: 280, height: 280))
                print("video-shapes: \(name) at \(t) s, pointer drawn \(VideoPointerExport.text(box)), its hot spot due at \(VideoPointerExport.text(at)), camera \(view)")
                // The shape exactly where its hot spot puts it, unstretched: a point of the recorded screen is 2 recording
                // pixels (the fixture at 2x), then the camera's scale into the spot, the same each way.
                let want = VideoPointerExport.shapeBox(at: at, k: 2 * spot.width / (view.width * source.width))
                #expect(VideoPointerExport.near(box, want), "\(name) at \(t) s: the pointer is drawn at \(box), not \(want)")
            }
        }
    }

    @Test("Motion blur softens a zoom easing in and leaves a still camera as it was")
    func motionBlur() async throws {
        let (folder, kept) = try Self.folder("video-motion")
        defer { if !kept { try? FileManager.default.removeItem(at: folder) } }
        let clip = folder.appending(path: "fixture-motion.mov")
        try await VideoFixture.clip(to: clip, seconds: 4, fps: 30)
        var edit = VideoEdit(duration: 4, zooms: [ZoomSegment(start: 1, end: 3.5, level: 2.5, focus: CGPoint(x: 0.5, y: 0.5))])
        let sharp = try await Self.export(clip, edit, track: nil, size: .full, to: folder.appending(path: "zoom-sharp.mp4"))
        edit.motionBlur = true
        #expect(edit.shutterTimes(at: 1.25).count == VideoEdit.shutterTaps && edit.shutterTimes(at: 1.25).allSatisfy { abs($0 - 1.25) <= VideoEdit.shutter / 2 + 0.000_1 })
        let blurred = try await Self.export(clip, edit, track: nil, size: .full, to: folder.appending(path: "zoom-motion-blur.mp4"))
        // Mid-ease (the zoom eases in over 1–1.5 s) the frame is softer; held in (2.5 s) and before it (0.5 s) it is the same.
        let a = try await VideoPointerExport.frame(sharp.url, at: 1.25), b = try await VideoPointerExport.frame(blurred.url, at: 1.25)
        let whole = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        let edgesSharp = Self.edges(a, in: whole), edgesBlurred = Self.edges(b, in: whole)
        print(String(format: "video-motion: mid-zoom edges %.2f sharp, %.2f with motion blur", edgesSharp, edgesBlurred))
        #expect(edgesBlurred < edgesSharp * 0.85, "motion blur did not soften the zoom: \(edgesSharp) → \(edgesBlurred)")
        if kept {
            for (image, name) in [(a, "zoom-1.25s-sharp.png"), (b, "zoom-1.25s-motion-blur.png")] { try #require(ImageFormat.png.encode(image)).write(to: folder.appending(path: name)) }
        }
        // The encoder's noise differs once earlier frames did, so a still frame is compared by its sharpness and a coarse
        // difference.
        for t in [0.5, 2.5] {
            let c = try await VideoPointerExport.frame(sharp.url, at: t), d = try await VideoPointerExport.frame(blurred.url, at: t)
            let box = VideoPointerExport.difference(c, d, threshold: 40)
            let ec = Self.edges(c, in: whole), ed = Self.edges(d, in: whole)
            print(String(format: "video-motion: still camera at %.1f s, edges %.2f and %.2f, frames differ in ", t, ec, ed) + VideoPointerExport.text(box))
            #expect(box.isNull && abs(ed - ec) < ec * 0.05, "a still camera's frame changed with motion blur at \(t) s: \(box), \(ec) → \(ed)")
        }
    }

    @Test("A saved look, read back and applied to a second clip, gives the same look and the same export")
    func presets() async throws {
        let (folder, kept) = try Self.folder("video-presets")
        defer { if !kept { try? FileManager.default.removeItem(at: folder) } }
        let first = folder.appending(path: "fixture-first-4s.mov"), second = folder.appending(path: "fixture-second-6s.mov")
        try await VideoFixture.clip(to: first, seconds: 4, fps: 30)
        try await VideoFixture.clip(to: second, seconds: 6, fps: 30)

        var a = VideoEdit(duration: 4, backdrop: Backdrop(fill: .gradient([0xF7B267, 0x8E44AD]), pad: 64, radius: 18, shadow: 0.6),
                          zooms: [ZoomSegment(start: 1, end: 2)])
        a.shape = .square
        a.motionBlur = true
        a.pointer = PointerLook(smooth: true, size: 2, clickRing: true)
        a.trim(in: 0.5, out: 3.5)

        // Saved as Pilot keeps it: in the library's defaults, read again by a new library.
        let suite = "pilot-video-presets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BackdropLibrary(defaults: defaults)
        let saved = library.saveVideoPreset(a.look)
        library.setEveryRecording(saved)
        let again = BackdropLibrary(defaults: defaults)
        let preset = try #require(again.everyRecording, "the look for new recordings was not read back")
        #expect(preset.name == "Look 1" && preset.sameLook(a.look), "read back \(preset)")

        var b = VideoEdit(duration: 6)
        b.trim(in: 0.5, out: 5)
        b.apply(preset)
        #expect(b.look.sameLook(a.look), "the second clip's look differs")
        #expect(b.zooms.isEmpty && b.trimIn == 0.5 && b.trimOut == 5, "the look carried the first clip's own edit")

        let outA = try await Self.export(first, a, track: nil, size: .p1080, to: folder.appending(path: "preset-first.mp4"))
        let outB = try await Self.export(second, b, track: nil, size: .p1080, to: folder.appending(path: "preset-second.mp4"))
        let sizeA = try await Self.pixels(outA), sizeB = try await Self.pixels(outB)
        print("video-presets: first \(VideoPointerExport.text(sizeA)), second \(VideoPointerExport.text(sizeB))")
        #expect(sizeA == sizeB && sizeA == CGSize(width: 1080, height: 1080))
        // Same moment of the same page (both trimmed in at 0.5 s), before the first clip's zoom: the same frame, backdrop and all.
        let fa = try await VideoPointerExport.frame(outA.url, at: 0.2), fb = try await VideoPointerExport.frame(outB.url, at: 0.2)
        let box = VideoPointerExport.difference(fa, fb, threshold: 24)
        print("video-presets: frames at 0.2 s differ in \(VideoPointerExport.text(box))")
        #expect(box.isNull, "the second clip's export differs in \(box)")
        if kept { for (image, name) in [(fa, "preset-first-0.2s.png"), (fb, "preset-second-0.2s.png")] { try #require(ImageFormat.png.encode(image)).write(to: folder.appending(path: name)) } }
    }

    /// How sharp `image` is in `rect`: the mean step between grey neighbours across and down.
    nonisolated static func edges(_ image: CGImage, in rect: CGRect) -> Double {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0.0, n = 0.0
        for y in max(0, Int(rect.minY))..<min(h - 1, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(w - 1, Int(rect.maxX)) {
                let v = Int(px[y * w + x])
                sum += Double(abs(v - Int(px[y * w + x + 1])) + abs(v - Int(px[(y + 1) * w + x])))
                n += 1
            }
        }
        return n > 0 ? sum / n : 0
    }
}

/// A made-up screen recording: the capture editor's billing page (CaptureFixture) at 2x, a pointer gliding between the
/// three buttons it clicks, written as H.264 by AVAssetWriter.
@MainActor
enum VideoFixture {
    /// Where the pointer clicks, as fractions of the frame: Update card, Edit, then Copy.
    static let clicks: [CursorTrack.Point] = [
        CursorTrack.Point(t: 1.6, x: Double(CaptureFixture.updateButton.midX / CaptureFixture.size.width), y: Double(CaptureFixture.updateButton.midY / CaptureFixture.size.height)),
        CursorTrack.Point(t: 5.0, x: Double(CaptureFixture.editButton.midX / CaptureFixture.size.width), y: Double(CaptureFixture.editButton.midY / CaptureFixture.size.height)),
        CursorTrack.Point(t: 8.4, x: Double(CaptureFixture.copyButton.midX / CaptureFixture.size.width), y: Double(CaptureFixture.copyButton.midY / CaptureFixture.size.height)),
    ]
    static var track: CursorTrack { CursorTrack(moves: [CursorTrack.Point(t: 0, x: 0.5, y: 0.6)] + clicks + [CursorTrack.Point(t: 12, x: 0.4, y: 0.8)], clicks: clicks) }

    /// `pointer` false leaves the dot out, as a recording that keeps the pointer out of its pixels (T29).
    static func clip(to url: URL, seconds: Double, fps: Int32, pointer: Bool = true) async throws {
        let page = try #require(CaptureFixture.image())
        let w = page.width, h = page.height
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        try #require(writer.startWriting(), "\(writer.error.map(String.init(describing:)) ?? "the writer did not start")")
        writer.startSession(atSourceTime: .zero)
        let track = self.track
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.draw(page, in: CGRect(x: 0, y: 0, width: w, height: h))
            // The pointer, an arrow-ish dot with a white ring, where the track has it (y from the top).
            let t = Double(i) / Double(fps)
            if pointer, let p = track.place(at: t) {
                let at = CGPoint(x: p.x * Double(w), y: (1 - p.y) * Double(h))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: at.x - 14, y: at.y - 14, width: 28, height: 28))
                ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: at.x - 10, y: at.y - 10, width: 20, height: 20))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: fps))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(writer.error.map(String.init(describing:)) ?? "the fixture was not written")")
    }
}
#endif
