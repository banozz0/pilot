#if DEBUG
import AppKit
import AVFoundation
import Foundation
import ImageScale
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// T29 (Q807): Pilot draws the pointer on export. A fixture clip with no pointer in its pixels (VideoFixture, `pointer:
/// false`) and a made-up drawn track (`shape`, a fixed block: never the Mac's own pointer, which a cursor set changes) go
/// through VideoExport at 720p, and each
/// control is read back from a known frame against an export with no track: the pointer drawn at its place (all off),
/// twice as big (R2), gone once still (R3), a ring on a click (R4), a shaking pointer steadied (R1, at full size). An older
/// recording (its pointer in its pixels, a track that is not drawn) gets no second pointer. Not opt-in: it writes only
/// temporary files, kept with their frames in PILOT_RENDER_DIR/video-pointer when that is set.
@MainActor
@Suite("Video pointer drawn on export")
struct VideoPointerExport {
    /// Fractions of the frame: moving in till 1 s, still at `rest` till the click at 2 s, a 0.5 s move to `end`, then
    /// still to the end.
    static let rest = CGPoint(x: 0.5, y: 0.5), end = CGPoint(x: 0.72, y: 0.3)
    static let click = 2.0

    /// The tests' pointer shape, the same on any Mac: a magenta block 16 × 24 points with its hot spot 4 and 6 points in,
    /// so the box it is drawn in is known exactly, and it stands out from every grey of the fixture page.
    static let shape: CursorTrack.Shape = {
        let size = CGSize(width: 16, height: 24), scale = 6.0
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        return CursorTrack.Shape(png: png, scale: scale, size: size, hot: CGPoint(x: 4, y: 6))
    }()

    /// Where `shape` is drawn for a hot spot at `at`, `k` export pixels a point of the recorded screen, from the top left.
    static func shapeBox(at: CGPoint, k: CGFloat) -> CGRect {
        CGRect(x: at.x - shape.hot.x * k, y: at.y - shape.hot.y * k, width: shape.size.width * k, height: shape.size.height * k)
    }

    /// Whether `box` is `want` to within `slack` pixels on each edge (smoothing and the encoder blur an edge a little).
    static func near(_ box: CGRect, _ want: CGRect, slack: CGFloat = 3) -> Bool {
        !box.isNull && abs(box.minX - want.minX) <= slack && abs(box.minY - want.minY) <= slack
            && abs(box.maxX - want.maxX) <= slack && abs(box.maxY - want.maxY) <= slack
    }

    static func track(drawn: Bool, shape: CursorTrack.Shape?) -> CursorTrack {
        var moves: [CursorTrack.Point] = []
        for i in 0...60 {
            let k = Double(i) / 60
            moves.append(CursorTrack.Point(t: k, x: 0.3 + (rest.x - 0.3) * k, y: 0.4 + (rest.y - 0.4) * k))
        }
        for i in 1...30 {
            let k = Double(i) / 30
            moves.append(CursorTrack.Point(t: click + 0.5 * k, x: rest.x + (end.x - rest.x) * k, y: rest.y + (end.y - rest.y) * k))
        }
        let clicks = [CursorTrack.Point(t: click, x: rest.x, y: rest.y)]
        guard drawn, let shape else { return CursorTrack(moves: moves, clicks: clicks) }
        return CursorTrack(moves: moves, clicks: clicks, drawn: true, frame: CaptureFixture.size, shapes: [shape],
                           shapeChanges: [CursorTrack.ShapeChange(t: 0, shape: 0)])
    }

    @Test("Each pointer control draws on a fixture export; an older recording gets no second pointer")
    func controls() async throws {
        let env = ProcessInfo.processInfo.environment
        let kept = env["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appending(path: "video-pointer") }
        let folder = kept ?? FileManager.default.temporaryDirectory.appending(path: "pilot-video-pointer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if kept == nil { try? FileManager.default.removeItem(at: folder) } }

        let bare = folder.appending(path: "fixture-no-pointer.mov"), baked = folder.appending(path: "fixture-baked-pointer.mov")
        try await VideoFixture.clip(to: bare, seconds: 6, fps: 30, pointer: false)
        try await VideoFixture.clip(to: baked, seconds: 6, fps: 30)
        let drawn = Self.track(drawn: true, shape: Self.shape), older = Self.track(drawn: false, shape: nil)

        func export(_ name: String, clip: URL, track: CursorTrack?, _ look: PointerLook = PointerLook()) async throws -> URL {
            let asset = AVURLAsset(url: clip, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var edit = VideoEdit(duration: try await asset.load(.duration).seconds)
            edit.pointer = look
            let target = folder.appending(path: "\(name).mp4")
            try? FileManager.default.removeItem(at: target)
            try await VideoExport.run(asset, edit: edit, pointer: track, picture: nil, format: .h264, size: .p720, to: target) { _ in }
            return target
        }
        let none = try await export("none", clip: bare, track: nil)
        let plain = try await export("drawn-all-off", clip: bare, track: drawn)
        let big = try await export("drawn-size-2x", clip: bare, track: drawn, PointerLook(size: 2))
        let hidden = try await export("drawn-hide-still", clip: bare, track: drawn, PointerLook(hideStill: true))
        let ringed = try await export("drawn-click-ring", clip: bare, track: drawn, PointerLook(clickRing: true))
        let noneBaked = try await export("older-none", clip: baked, track: nil)
        let olderAll = try await export("older-smooth-3x-hide", clip: baked, track: older, PointerLook(smooth: true, size: 3, hideStill: true))

        // A frame of each, at `t`, with the box where it differs from the export with no track.
        // `near` keeps the box to that far round `around` (a fraction of the frame): an encode's noise elsewhere stays out.
        func changed(_ file: URL, from base: URL, at t: Double, _ name: String, around: CGPoint? = nil, near: CGFloat = 120,
                     threshold: Int = 48) async throws -> (box: CGRect, size: CGSize) {
            let a = try await Self.frame(file, at: t), b = try await Self.frame(base, at: t)
            if let kept { try #require(ImageFormat.png.encode(a)).write(to: kept.appending(path: "\(name)-\(String(format: "%.1f", t))s.png")) }
            let size = CGSize(width: a.width, height: a.height)
            let window = around.map { CGRect(x: $0.x * size.width - near, y: $0.y * size.height - near, width: 2 * near, height: 2 * near) }
            return (Self.difference(a, b, threshold: threshold, within: window), size)
        }
        func px(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }

        // All off, at rest: the shape's hot spot on the pointer's place, the shape exactly where its hot spot puts it.
        let at = try await changed(plain, from: none, at: 1.5, "drawn-all-off", around: Self.rest)
        let place = px(Self.rest, at.size)
        print("video-pointer: all off at 1.5 s, drawn \(Self.text(at.box)) for the pointer at \(Self.text(place)) in \(Self.text(at.size))")
        #expect(!at.box.isNull && at.box.insetBy(dx: -3, dy: -3).contains(place), "no pointer at its place: \(at.box)")
        // A point of the recorded screen (the fixture page's) at the export's size.
        let want = Self.shapeBox(at: place, k: at.size.width / CaptureFixture.size.width)
        #expect(Self.near(at.box, want), "the shape is drawn at \(at.box), not \(want)")

        // R2: twice the size.
        let twice = try await changed(big, from: none, at: 1.5, "drawn-size-2x", around: Self.rest)
        let ratio = twice.box.height / max(at.box.height, 1)
        print("video-pointer: R2 2× at 1.5 s, \(Self.text(twice.box)), \(String(format: "%.2f", ratio))× the height at 1×")
        #expect(ratio > 1.7 && ratio < 2.3, "2× is \(ratio)× as tall")

        // R3: still since 2.5 s, gone by 4.4 s; still drawn with it off.
        let gone = try await changed(hidden, from: none, at: 5, "drawn-hide-still"), shown = try await changed(plain, from: none, at: 5, "drawn-all-off")
        print("video-pointer: R3 at 5.0 s, hidden \(Self.text(gone.box)), with it off \(Self.text(shown.box))")
        #expect(gone.box.isNull && !shown.box.isNull, "hide when still: \(gone.box) vs \(shown.box)")
        let moving = try await changed(hidden, from: none, at: 1.5, "drawn-hide-still")
        #expect(!moving.box.isNull, "the pointer is hidden before it has been still long enough")

        // R4: 0.2 s after the click, T4's ripple round the click's place, wider than the pointer.
        // The ring wears the theme's effect colour: Tokyo Night's pale blue on the fixture's white page differs by less than
        // Lagoon's cyan did, so its shape is read at a lower threshold, near the click, where no encode noise reaches.
        let ring = try await changed(ringed, from: plain, at: Self.click + 0.2, "drawn-click-ring", around: Self.rest, threshold: 16)
        let clickAt = px(Self.rest, ring.size)
        print("video-pointer: R4 at 2.2 s, ring \(Self.text(ring.box)) round the click at \(Self.text(clickAt))")
        #expect(abs(ring.box.midX - clickAt.x) < 4 && abs(ring.box.midY - clickAt.y) < 4, "the ring is not round the click: \(ring.box)")
        #expect(ring.box.width > 40 && ring.box.width < 100, "the ring is \(ring.box.width) px wide")

        // An older recording keeps its own pointer: no second one, whatever the controls say.
        let old = try await changed(olderAll, from: noneBaked, at: 1.5, "older-smooth-3x-hide")
        print("video-pointer: older recording at 1.5 s, drawn \(Self.text(old.box))")
        #expect(old.box.isNull, "a pointer was drawn over an older recording: \(old.box)")

        // R1: a pointer gliding right while shaking ±0.01 of the frame's height, up one frame and down the next; full size.
        var shaky: [CursorTrack.Point] = []
        for i in 0...300 {
            let t = Double(i) / 60
            shaky.append(CursorTrack.Point(t: t, x: 0.3 + 0.05 * t, y: 0.5 + (i / 2 % 2 == 0 ? 0.01 : -0.01)))
        }
        let shakyTrack = CursorTrack(moves: shaky, drawn: true, frame: CaptureFixture.size, shapes: [Self.shape])
        func fullExport(_ name: String, smooth: Bool) async throws -> URL {
            let asset = AVURLAsset(url: bare, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var edit = VideoEdit(duration: try await asset.load(.duration).seconds)
            edit.pointer.smooth = smooth
            let target = folder.appending(path: "\(name).mp4")
            try? FileManager.default.removeItem(at: target)
            try await VideoExport.run(asset, edit: edit, pointer: shakyTrack, picture: nil, format: .h264, size: .full, to: target) { _ in }
            return target
        }
        let noneFull = folder.appending(path: "none-full.mp4")
        try? FileManager.default.removeItem(at: noneFull)
        do {
            let asset = AVURLAsset(url: bare, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            try await VideoExport.run(asset, edit: VideoEdit(duration: try await asset.load(.duration).seconds), pointer: nil, picture: nil,
                                      format: .h264, size: .full, to: noneFull) { _ in }
        }
        let raw = try await fullExport("shaky-smooth-off", smooth: false), steady = try await fullExport("shaky-smooth-on", smooth: true)
        // How far the pointer's top moves between the frames at 2.0 s (up) and 2.0 + 1/30 s (down).
        func jump(_ file: URL, _ name: String) async throws -> CGFloat {
            let up = try await changed(file, from: noneFull, at: 2, name, around: CGPoint(x: 0.4, y: 0.5))
            let down = try await changed(file, from: noneFull, at: 2 + 1.0 / 30, name, around: CGPoint(x: 0.4, y: 0.5))
            return abs(down.box.minY - up.box.minY)
        }
        let shake = try await jump(raw, "shaky-smooth-off"), smoothed = try await jump(steady, "shaky-smooth-on")
        print(String(format: "video-pointer: R1 at full size, the pointer jumps %.0f px a frame with Smooth off, %.0f px with it on", shake, smoothed))
        #expect(shake > 15 && smoothed < shake * 0.4, "Smooth off \(shake) px, on \(smoothed) px")
    }

    /// Q821: a new recording is handed out (copy, drag, Save As) as a copy with its pointer drawn in, under the
    /// recording's own name in `.Pilot pointer` beside it, with the recording's own settings (here Click ring on, as
    /// Show clicks sets it); asked again it is the same file, not made again; an older recording is handed out as it is;
    /// a trashed recording's copy is deleted.
    @Test("A new recording is handed out with its pointer drawn in, made once; an older one as it is")
    func handedOut() async throws {
        testApp()
        let env = ProcessInfo.processInfo.environment
        let kept = env["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appending(path: "video-pointer-handout") }
        let folder = kept ?? FileManager.default.temporaryDirectory.appending(path: "pilot-handout-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: folder.appending(path: CaptureHistory.drawnFolder))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if kept == nil { try? FileManager.default.removeItem(at: folder) } }
        let pointers = folder.appending(path: "pointers")

        // A recording as Pilot writes one: an MP4 with no pointer in its pixels, and its drawn track.
        let clip = folder.appending(path: "fixture-no-pointer.mov")
        try await VideoFixture.clip(to: clip, seconds: 6, fps: 30, pointer: false)
        let recording = folder.appending(path: "Recording 2026-11-04 at 12.00.00.mp4"), older = folder.appending(path: "Recording older.mp4")
        for url in [recording, older] {
            try? FileManager.default.removeItem(at: url)
            let asset = AVURLAsset(url: clip, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            try await VideoExport.run(asset, edit: VideoEdit(duration: try await asset.load(.duration).seconds), pointer: nil, picture: nil,
                                      format: .h264, size: .full, to: url) { _ in }
        }
        var track = Self.track(drawn: true, shape: Self.shape)
        track.look = PointerLook(clickRing: true)
        try track.save(for: recording, in: pointers)
        try Self.track(drawn: false, shape: nil).save(for: older, in: pointers)

        let out = try await RecordingHandout.file(for: recording, pointers: pointers)
        print("video-pointer: handed out \(out.path(percentEncoded: false).replacingOccurrences(of: folder.path(percentEncoded: false), with: ""))")
        #expect(out == RecordingHandout.cached(for: recording) && out.lastPathComponent == recording.lastPathComponent)

        // The pointer at its place at 1.5 s, and the recording's Click ring 0.2 s after its click.
        let drawn = try await Self.frame(out, at: 1.5), raw = try await Self.frame(recording, at: 1.5)
        let size = CGSize(width: drawn.width, height: drawn.height), place = CGPoint(x: Self.rest.x * size.width, y: Self.rest.y * size.height)
        let box = Self.difference(drawn, raw, within: CGRect(x: place.x - 120, y: place.y - 120, width: 240, height: 240))
        let ring = Self.difference(try await Self.frame(out, at: Self.click + 0.2), try await Self.frame(recording, at: Self.click + 0.2),
                                   within: CGRect(x: place.x - 120, y: place.y - 120, width: 240, height: 240))
        print("video-pointer: the handed-out file at 1.5 s, pointer \(Self.text(box)) at \(Self.text(place)) in \(Self.text(size)); at 2.2 s \(Self.text(ring))")
        #expect(!box.isNull && box.insetBy(dx: -3, dy: -3).contains(place), "no pointer at its place in the handed-out file: \(box)")
        #expect(ring.width > 60, "no click ring in the handed-out file: \(ring)")
        if let kept { try #require(ImageFormat.png.encode(drawn)).write(to: kept.appending(path: "handed-out-1.5s.png")) }

        // Asked again: the same file, not made again.
        let made = try out.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try await RecordingHandout.file(for: recording, pointers: pointers)
        let madeAgain = try again.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(again == out && madeAgain == made, "asked again, it was made again: \(String(describing: made)) → \(String(describing: madeAgain))")

        // An older recording goes as it is; a trashed recording's copy goes with it.
        let old = try await RecordingHandout.file(for: older, pointers: pointers)
        #expect(old == older)
        RecordingHandout.forget([recording])
        #expect(!FileManager.default.fileExists(atPath: out.path(percentEncoded: false)))
    }

    /// A recording as Pilot writes one (an MP4 with no pointer in its pixels) at `url`, with its drawn track in `pointers`.
    static func recording(_ url: URL, from clip: URL, pointers: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let asset = AVURLAsset(url: clip, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        try await VideoExport.run(asset, edit: VideoEdit(duration: try await asset.load(.duration).seconds), pointer: nil, picture: nil,
                                  format: .h264, size: .full, to: url) { _ in }
        try track(drawn: true, shape: shape).save(for: url, in: pointers)
    }

    /// Fix round 1 (T29 verdict): Copy pressed twice and Save As then Copy each hand out the drawn copy from one export;
    /// one hand-out's Cancel leaves the others with the drawn copy; a recording trashed during its export leaves no copy;
    /// a copy whose recording was deleted outside Pilot, and a stray part file, are swept by the next export; History's
    /// size counts the copy; a handed-out copy handed out again goes as it is (one pointer); Ask AI's frame has the
    /// pointer drawn.
    @Test("Hand-outs share one export, outlive another's Cancel and a deletion, and never draw twice")
    func handOuts() async throws {
        testApp()
        RecordingHandout.tips = false
        defer { RecordingHandout.tips = true }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "pilot-handouts-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let pointers = folder.appending(path: "pointers"), clip = folder.appending(path: "clip.mov")
        try await VideoFixture.clip(to: clip, seconds: 3, fps: 30, pointer: false)
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }

        // Copy twice, and Save As then Copy: every press gets the drawn copy.
        let a = folder.appending(path: "Recording 2026-11-04 at 13.00.00.mp4")
        try await Self.recording(a, from: clip, pointers: pointers)
        var given: [[URL]] = []
        let first = RecordingHandout.handOut([a], pointers: pointers) { given.append($0) }
        let second = RecordingHandout.handOut([a], pointers: pointers) { given.append($0) }
        await first.task?.value
        await second.task?.value
        print("hand-out: two presses gave \(given.map { $0.map(\.lastPathComponent) })")
        #expect(given.count == 2 && given.allSatisfy { $0 == [RecordingHandout.cached(for: a)] }, "two presses: \(given)")
        #expect(RecordingHandout.marked(RecordingHandout.cached(for: a)))

        // One hand-out's Cancel (its job and its export) while a drag waits: the drag still gets the drawn copy.
        let b = folder.appending(path: "Recording 2026-11-04 at 13.01.00.mp4")
        try await Self.recording(b, from: clip, pointers: pointers)
        var cancelledGave = false
        let cancelled = RecordingHandout.handOut([b], pointers: pointers) { _ in cancelledGave = true }
        final class Heard: @unchecked Sendable { var any = false, ended = false }
        let heard = Heard()
        let drag = Task { @MainActor in
            defer { heard.ended = true }
            return try await RecordingHandout.file(for: b, pointers: pointers) { _ in heard.any = true }
        }
        // Until progress or the drag's end, not a fixed 5 s: a loaded Mac starts the export late.
        while !heard.any && !heard.ended { try await Task.sleep(for: .milliseconds(10)) }
        #expect(heard.any, "the export never reported progress")
        cancelled.cancel()
        await cancelled.task?.value
        let dragged = try await drag.value
        print("hand-out: after another's Cancel the drag got \(dragged.lastPathComponent), cancelled one gave \(cancelledGave)")
        #expect(!cancelledGave && dragged == RecordingHandout.cached(for: b))

        // Cancel while the second of two recordings is drawn: nothing is handed out and its export leaves no copy. A
        // Cancel that waits for its own turn on the main actor lands too late under full-suite load, where every
        // @MainActor suite shares it: polls woke after the export was done (build 9; two tries in three, T66). So the
        // second's export waits on the main actor itself: with a click ring its VideoExport.run reads the theme's ring
        // colours there before it writes a frame (VideoRender.swift, `await MainActor.run`). The test only yields, so it
        // is always queued on the main actor; the turn that moves the job on to the second starts its export, and the
        // test's next turn comes before that read. The first is `b`, whose drawn copy is already made, so it is quick.
        let b3 = folder.appending(path: "Recording 2026-11-04 at 13.01.40.mp4")
        try await Self.recording(b3, from: clip, pointers: pointers)
        var ringed = Self.track(drawn: true, shape: Self.shape)
        ringed.look = PointerLook(clickRing: true)
        try ringed.save(for: b3, in: pointers)
        // At the export's priority, so the main actor's order does not rest on priorities.
        let (twoGave, midway) = await Task(priority: .userInitiated) { @MainActor in
            var gave = false
            let two = RecordingHandout.handOut([b, b3], pointers: pointers) { _ in gave = true }
            while two.current != b3 { await Task.yield() }
            let midway = !gave && !exists(RecordingHandout.cached(for: b3))
            two.cancel()
            await two.task?.value
            return (gave, midway)
        }.value
        print("hand-out: two recordings cancelled during the second (its export running at the Cancel: \(midway)): gave \(twoGave), second copy made \(exists(RecordingHandout.cached(for: b3)))")
        #expect(midway && !twoGave && !exists(RecordingHandout.cached(for: b3)))
        try fm.removeItem(at: b3)

        // Trashed while its export runs: the export's copy is not kept. The trash runs inside the export's own progress
        // call (T57): a hand-out's listener hears progress through a main-actor hop, so under load the export could
        // finish, and rightly hand out its copy, before a trash there ran.
        let c = folder.appending(path: "Recording 2026-11-04 at 13.02.00.mp4")
        try await Self.recording(c, from: clip, pointers: pointers)
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let trashed = try await RecordingHandout.draw(c, pointers: pointers) { _ in
            guard !once.done else { return }
            once.done = true
            try? FileManager.default.removeItem(at: c)
            RecordingHandout.forget([c])
        }
        print("hand-out: trashed during its export gave \(trashed.lastPathComponent), copy left: \(exists(RecordingHandout.cached(for: c)))")
        #expect(trashed == c && !exists(RecordingHandout.cached(for: c)))

        // Deleted outside Pilot (no forget) and a part file left by a quit: the next export sweeps both.
        try fm.removeItem(at: a)
        let stray = folder.appending(path: CaptureHistory.drawnFolder).appending(path: ".part-left.mp4")
        try Data([0]).write(to: stray)
        let d = folder.appending(path: "Recording 2026-11-04 at 13.03.00.mp4")
        try await Self.recording(d, from: clip, pointers: pointers)
        _ = try await RecordingHandout.file(for: d, pointers: pointers)
        let left = try fm.contentsOfDirectory(atPath: folder.appending(path: CaptureHistory.drawnFolder).path(percentEncoded: false)).sorted()
        print("hand-out: after a deletion outside Pilot the folder holds \(left)")
        #expect(left == [b.lastPathComponent, d.lastPathComponent])

        // History's size counts the copy with its recording.
        let entry = try #require(CaptureHistory.entries(records: [], captures: folder, recordings: folder).first { $0.url.lastPathComponent == d.lastPathComponent })
        let raw = try #require(try d.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let copy = try #require(try RecordingHandout.cached(for: d).resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("hand-out: History counts \(entry.bytes) bytes = \(raw) + \(copy)")
        #expect(entry.bytes == raw + copy)

        // A handed-out copy handed out again (pasted under the recording's name elsewhere): as it is, one pointer.
        let elsewhere = folder.appending(path: "Desktop")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let pasted = elsewhere.appending(path: d.lastPathComponent)
        try fm.copyItem(at: RecordingHandout.cached(for: d), to: pasted)
        let again = try await RecordingHandout.file(for: pasted, pointers: pointers)
        print("hand-out: a pasted copy handed out again is \(again.path(percentEncoded: false).replacingOccurrences(of: folder.path(percentEncoded: false), with: ""))")
        #expect(RecordingHandout.marked(pasted) && again == pasted && !exists(RecordingHandout.cached(for: pasted)))

        // Ask AI on a recording's thumbnail: its frame with the pointer drawn in.
        let posterAt = 0.2
        let poster = try await Self.frame(d, at: posterAt)
        let asked = await RecordingHandout.frame(poster, of: d, at: posterAt, pointers: pointers)
        let k = posterAt  // the track moves in over its first second
        let place = CGPoint(x: (0.3 + (Self.rest.x - 0.3) * k) * Double(poster.width), y: (0.4 + (Self.rest.y - 0.4) * k) * Double(poster.height))
        let box = Self.difference(asked, poster, within: CGRect(x: place.x - 80, y: place.y - 80, width: 160, height: 160))
        print("hand-out: Ask AI's frame, pointer \(Self.text(box)) at \(Self.text(place))")
        #expect(!box.isNull && box.insetBy(dx: -3, dy: -3).contains(place), "no pointer in Ask AI's frame: \(box)")
    }

    /// Fix rounds 1 and 2 (T29 verdicts): the 201st recording's save prunes old tracks only where the recording is gone:
    /// one moved to a folder Pilot never saved to keeps its track by its bookmark; one in a Trash does not.
    @Test("The 201st recording keeps every living recording's track")
    func prune() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "pilot-prune-\(UUID().uuidString)")
        let pointers = folder.appending(path: "pointers"), sibling = folder.appending(path: "Moved"), trash = folder.appending(path: ".Trash")
        for dir in [pointers, sibling, trash] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: folder) }
        let track = CursorTrack(moves: [CursorTrack.Point(t: 0, x: 0.5, y: 0.5)], drawn: true)
        // 200 tracks, oldest first: #0 a recording then moved to a sibling folder, #1 one still there, #2 one deleted,
        // #3 one then moved to a Trash; the rest recordings still there.
        for i in 0..<200 {
            let rec = folder.appending(path: "Recording \(i).mp4")
            if i != 2 { try Data().write(to: rec) }
            try track.save(for: rec, in: pointers)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 1000))], ofItemAtPath: CursorTrack.file(for: rec, in: pointers).path(percentEncoded: false))
        }
        try fm.moveItem(at: folder.appending(path: "Recording 0.mp4"), to: sibling.appending(path: "Recording 0.mp4"))
        try fm.moveItem(at: folder.appending(path: "Recording 3.mp4"), to: trash.appending(path: "Recording 3.mp4"))
        let newest = folder.appending(path: "Recording 200.mp4")
        try Data().write(to: newest)
        try track.save(for: newest, in: pointers, keep: 199)
        func kept(_ i: Int) -> Bool { CursorTrack.load(for: folder.appending(path: "Recording \(i).mp4"), in: pointers) != nil }
        let count = try fm.contentsOfDirectory(atPath: pointers.path(percentEncoded: false)).count
        print("prune: after the 201st (keep 199), \(count) tracks; moved to a sibling kept \(kept(0)), living kept \(kept(1)), deleted kept \(kept(2)), trashed kept \(kept(3))")
        #expect(kept(0) && kept(1) && !kept(2) && !kept(3) && count == 199)
    }

    /// R1: a pointer shaking 6 px either side of a straight line comes out steady, and still on the click's place.
    @Test("Smooth steadies a shaky pointer and lands on its clicks")
    func smooth() {
        var moves: [CursorTrack.Point] = []
        for i in 0...120 {
            let t = Double(i) / 60
            moves.append(CursorTrack.Point(t: t, x: 0.2 + 0.3 * t, y: 0.5 + (i % 2 == 0 ? 0.003 : -0.003)))
        }
        let click = CursorTrack.Point(t: 1, x: 0.5, y: 0.503)
        let pointer = DrawnPointer(CursorTrack(moves: moves, clicks: [click], drawn: true))
        var raw = 0.0, smooth = 0.0
        for i in 0..<100 {
            let t = 0.3 + Double(i) * 0.0137
            guard abs(t - 1) > DrawnPointer.clickHold else { continue }
            raw = max(raw, abs((pointer.place(at: t, smooth: false)?.y ?? 0) - 0.5))
            smooth = max(smooth, abs((pointer.place(at: t, smooth: true)?.y ?? 0) - 0.5))
        }
        let landed = pointer.place(at: 1, smooth: true)
        print(String(format: "video-pointer: R1 shake %.4f raw, %.4f smoothed; at the click %.4f, %.4f", raw, smooth, landed?.x ?? -1, landed?.y ?? -1))
        #expect(smooth < raw * 0.4, "smoothing left \(smooth) of \(raw)")
        #expect(landed == click.place, "the smoothed pointer is off its click: \(String(describing: landed))")
    }

    /// A track written by Pilot 1.0 has no drawn keys and reads back as not drawn; a drawn one keeps its shapes.
    @Test("Older tracks read as not drawn; drawn tracks keep their shapes")
    func tracks() throws {
        let old = try JSONDecoder().decode(CursorTrack.self, from: Data(#"{"moves":[0,0.5,0.5],"clicks":[]}"#.utf8))
        #expect(!old.drawn && old.shapes.isEmpty && old.frame == nil)
        let shape = CursorTrack.Shape(png: Data([1, 2, 3]), scale: 6, size: CGSize(width: 17, height: 23), hot: CGPoint(x: 4, y: 4))
        let drawn = CursorTrack(moves: [CursorTrack.Point(t: 0, x: 0.5, y: 0.5)], drawn: true, frame: CGSize(width: 920, height: 580),
                                shapes: [shape, shape], shapeChanges: [CursorTrack.ShapeChange(t: 0, shape: 0), CursorTrack.ShapeChange(t: 1.25, shape: 1)])
        let back = try JSONDecoder().decode(CursorTrack.self, from: JSONEncoder().encode(drawn))
        #expect(back == drawn)
        #expect(DrawnPointer(back).shape(at: 1) == 0 && DrawnPointer(back).shape(at: 2) == 1)
    }

    /// The frame at exactly `t` seconds of the movie at `url`.
    nonisolated static func frame(_ url: URL, at t: Double) async throws -> CGImage {
        try await VideoExportTimes.frame(of: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]), at: t)
    }

    /// The box of pixels where `a` and `b` (the same size) differ by more than `threshold` in any channel, from the top
    /// left, only inside `within` when given; null where they agree.
    nonisolated static func difference(_ a: CGImage, _ b: CGImage, threshold: Int = 48, within: CGRect? = nil) -> CGRect {
        let w = a.width, h = a.height
        func bytes(_ image: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            out.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return out
        }
        guard b.width == w, b.height == h else { return .infinite }
        let x = bytes(a), y = bytes(b)
        var box = CGRect.null
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                if let within, !within.contains(CGPoint(x: col, y: row)) { continue }
                if abs(Int(x[i]) - Int(y[i])) > threshold || abs(Int(x[i + 1]) - Int(y[i + 1])) > threshold || abs(Int(x[i + 2]) - Int(y[i + 2])) > threshold {
                    box = box.union(CGRect(x: col, y: row, width: 1, height: 1))
                }
            }
        }
        return box
    }

    nonisolated static func text(_ r: CGRect) -> String {
        r.isNull ? "nothing" : String(format: "%.0f×%.0f at %.0f,%.0f", r.width, r.height, r.minX, r.minY)
    }
    nonisolated static func text(_ p: CGPoint) -> String { String(format: "%.0f,%.0f", p.x, p.y) }
    nonisolated static func text(_ s: CGSize) -> String { String(format: "%.0f×%.0f", s.width, s.height) }
}
#endif
