import AVFoundation
import CoreImage
import ImageIO
import PilotCore
import UniformTypeIdentifiers

// The video editor's one way of drawing a frame (P71), shared by the preview and the export so what plays is what is
// written: Core Image in a small custom compositor (AVVideoComposition's Core Image handler is deprecated and cannot
// make the canvas bigger than the recording). The backdrop (fill and shadow) is drawn once per edit; each frame is then
// its blurs (R8), then the click rings (R4) and the pointer Pilot draws (T29, R1–R3), then the camera's part of the
// cropped frame (a shape's window of it, R9), scaled into the backdrop's spot and rounded there, averaged over the
// shutter while the camera moves (R10). The pointer goes on in the recording's own pixels, so crop, shape, zoom and size
// treat it as they would a recorded one.

/// One edit's frame recipe at one size. Immutable and Sendable: the composition's handler runs it on AVFoundation's
/// queues.
final class VideoPlan: @unchecked Sendable {
    let edit: VideoEdit
    let pointer: CursorTrack?
    let layout: VideoLayout
    /// Whether a frame's time is the export's (trimmed and sped up) or the recording's own (the preview plays it whole).
    let exported: Bool
    /// The fill and the shadow round the spot, the spot itself clear; nil without a backdrop.
    private let background: CIImage?
    /// The spot's rounded corners, as an alpha mask, for a see-through ground only: an opaque one laid over the frame
    /// rounds it by itself. Nil when neither is needed.
    private let mask: CIImage?
    /// The video's place on the canvas, Core Image's bottom-left pixels.
    private let place: CGRect
    /// The source frame's size, pixels: Core Image counts up from the bottom.
    private let source: CGSize
    private let fine: Bool
    /// The pointer as the frames draw it (T29): a drawn track's places and shapes, or only the clicks for R4; nil when
    /// nothing is drawn.
    private let drawn: DrawnPointer?
    /// Each of the track's shapes, read from its PNG once.
    private let shapes: [CIImage]
    /// The recording's pixels a point of the screen it recorded: the pointer's and the ring's size.
    private let pixelsPerPoint: CGFloat
    /// The click ring's colours: the theme's halo colours (T4).
    private let ring: CursorEffectColours

    /// `picture` is a picture fill's, made by `backdropPicture` (read and blurred once, never per frame); `fine` scales
    /// with high-quality downsampling (the export's), else plainly (the preview's). `size` draws the canvas exactly that
    /// big (an export's even size), else `out` times the full one. `ring` is the theme's halo colours, Lagoon's when nil.
    init(edit: VideoEdit, pointer: CursorTrack?, source: CGSize, out: CGFloat = 1, size: CGSize? = nil, exported: Bool, picture: CGImage?, fine: Bool,
         ring: CursorEffectColours? = nil) {
        self.edit = edit
        self.pointer = pointer?.path
        self.exported = exported
        self.fine = fine
        self.source = source
        drawn = pointer.flatMap { $0.drawn || !$0.clicks.isEmpty ? DrawnPointer($0) : nil }
        shapes = pointer?.drawn == true ? pointer?.shapes.map { CIImage(data: $0.png) ?? .empty() } ?? [] : []
        pixelsPerPoint = pointer?.frame.map { source.width / max($0.width, 1) } ?? VideoLayout.pointScale(source)
        self.ring = ring ?? .of("lagoon")
        var layout = VideoLayout(source: source, crop: edit.crop, backdrop: edit.backdrop, shape: edit.shape, out: out)
        if let size { layout = layout.fitted(to: size) }
        self.layout = layout
        let canvas = layout.canvas, spot = layout.spot
        place = CGRect(x: spot.minX, y: canvas.height - spot.maxY, width: spot.width, height: spot.height)
        if let backdrop = edit.backdrop {
            background = Self.background(backdrop, canvas: canvas, spot: place, scale: layout.scale, picture: picture).map { CIImage(cgImage: $0) }
            let opaque = switch backdrop.fill {
            case .colour, .gradient: true
            case .image, .capture: picture != nil
            case .clear: false
            }
            let r = min(backdrop.radius * layout.scale, min(spot.width, spot.height) / 2)
            mask = !opaque && r > 0.5 ? CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: place), "inputRadius": r, "inputColor": CIColor.white,
            ])?.outputImage : nil
        } else {
            background = nil
            mask = nil
        }
    }

    /// The export's frame for `image` (the recording's frame) at `time`: the export's time when `exported`, else the
    /// recording's.
    func frame(_ image: CIImage, at time: Double) -> CIImage {
        let t = exported ? edit.source(at: time) : time
        let crop = layout.crop, place = self.place
        let drawn = pointered(blurred(image, at: t), at: t).clampedToExtent()
        // The camera's part of the frame (source pixels, bottom-left) scaled into the spot.
        func shot(_ view: CGRect) -> CIImage {
            let part = CGRect(x: crop.minX + view.minX * crop.width, y: source.height - (crop.minY + view.maxY * crop.height),
                              width: view.width * crop.width, height: view.height * crop.height)
            let move = CGAffineTransform(translationX: -part.minX, y: -part.minY)
                .concatenating(CGAffineTransform(scaleX: place.width / max(part.width, 1), y: place.height / max(part.height, 1)))
                .concatenating(CGAffineTransform(translationX: place.minX, y: place.minY))
            let video = drawn.cropped(to: part)
            return (fine ? video.transformed(by: move, highQualityDownsample: true) : video.transformed(by: move)).cropped(to: place)
        }
        // R10: the camera at each of the shutter's times, a shot about every 4 pixels the frame's edge moves; one shot
        // while it stands still (within a tenth of a pixel).
        func view(_ at: Double) -> CGRect { edit.camera(at: at, cursor: pointer, window: layout.window) }
        func moved(_ v: CGRect, from a: CGRect) -> CGFloat {
            let kx = place.width / max(a.width, 0.0001), ky = place.height / max(a.height, 0.0001)
            return max(abs(v.minX - a.minX) * kx, abs(v.maxX - a.maxX) * kx, abs(v.minY - a.minY) * ky, abs(v.maxY - a.maxY) * ky)
        }
        // The shutter's ends tell how far the camera moves; the preview takes the fewest shots, so it plays smoothly.
        let ends = edit.shutterTimes(at: t, taps: 2)
        let move = ends.count < 2 ? 0 : moved(view(ends[1]), from: view(ends[0]))
        let video: CIImage
        if move < 0.1 {
            video = shot(view(t))
        } else {
            let taps = fine ? min(VideoEdit.mostShutterTaps, max(VideoEdit.shutterTaps, Int(move / 4))) : VideoEdit.shutterTaps
            let views = edit.shutterTimes(at: t, taps: taps).map(view)
            // A running mean: each new shot weighs 1/(n+1) against the ones before.
            video = views.enumerated().dropFirst().reduce(shot(views[0])) { mean, next in
                mean.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: shot(next.element), kCIInputTimeKey: 1 / Double(next.offset + 1)])
            }.cropped(to: place)
        }
        let all = CGRect(origin: .zero, size: layout.canvas)
        guard let background else { return video.cropped(to: all) }
        if let mask {
            return video.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask]).cropped(to: all)
        }
        return background.composited(over: video).cropped(to: all)
    }

    /// R8: `image` with each area blurred at the recording's `t` blurred, hard enough that a line of text in it can't be
    /// read: the radius follows the area's shorter side.
    private func blurred(_ image: CIImage, at t: Double) -> CIImage {
        var image = image
        for area in edit.blurred(at: t) {
            let r = CGRect(x: area.minX * source.width, y: source.height - area.maxY * source.height,
                           width: area.width * source.width, height: area.height * source.height).integral
            let radius = min(64, max(12, min(r.width, r.height) * 0.35))
            image = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: r).composited(over: image)
        }
        return image
    }

    /// T29: `image` (the recording's frame) with a ring on each click still playing at `t` (R4), then, on a recording
    /// that kept the pointer out, the pointer: smoothed (R1), at its size (R2), faded while still (R3).
    private func pointered(_ image: CIImage, at t: Double) -> CIImage {
        guard let drawn else { return image }
        let look = edit.pointer, k = pixelsPerPoint
        var out = image
        // A place on the frame (a fraction from its top left) in Core Image's bottom-left pixels.
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * source.width, y: source.height - p.y * source.height) }
        if look.clickRing {
            for click in drawn.rings(at: t) {
                guard let tile = Self.ringTile(age: click.age, scale: k, colours: ring) else { continue }
                let at = pixel(click.place), half = tile.extent.width / 2
                out = tile.transformed(by: CGAffineTransform(translationX: at.x - half, y: at.y - half)).composited(over: out)
            }
        }
        if drawn.track.drawn, let p = drawn.place(at: t, smooth: look.smooth), let i = drawn.shape(at: t), shapes.indices.contains(i) {
            let alpha = look.hideStill ? drawn.shown(at: t) : 1
            if alpha > 0.002 {
                let shape = drawn.track.shapes[i], s = k * look.size, at = pixel(p)
                // The shape's hot spot (points from its top left) on the pointer's place.
                var cursor = shapes[i].transformed(by: CGAffineTransform(scaleX: s / shape.scale, y: s / shape.scale)
                    .concatenating(CGAffineTransform(translationX: at.x - shape.hot.x * s, y: at.y - (shape.size.height - shape.hot.y) * s)))
                if alpha < 1 { cursor = cursor.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)]) }
                out = cursor.composited(over: out)
            }
        }
        return out.cropped(to: image.extent)
    }

    /// R4: one click's ring `age` seconds in, as T4's ripple draws it, in a square tile `scale` pixels a point.
    static func ringTile(age: Double, scale: CGFloat, colours: CursorEffectColours) -> CIImage? {
        let room: CGFloat = 36, side = Int((2 * room * scale).rounded(.up))
        guard side > 0, let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        var state = CursorEffectState()
        state.ripple = true
        state.ripples = [CursorEffectState.Ripple(point: CGPoint(x: room, y: room), time: 0, right: false)]
        CursorEffectPainter.draw(state, colours, now: age, in: ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// The backdrop's fill and shadow over the canvas, the spot (`spot` bottom-left pixels) left clear: the capture's
    /// own ground (MarkupRenderer.ground), so a video's backdrop matches a capture's.
    static func background(_ b: Backdrop, canvas: CGSize, spot: CGRect, scale: CGFloat, picture: CGImage?) -> CGImage? {
        guard canvas.width >= 1, canvas.height >= 1,
              let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        MarkupRenderer.ground(b, in: ctx, spot: spot, scale: scale, picture: picture)
        return ctx.makeImage()
    }

    /// `plan`'s composition over `asset`: its frames drawn by the plan into `context`, at the plan's canvas, `fps` frames
    /// a second when given (a GIF's), else the recording's own rate (30 when it has none), tagged BT.709 as recordings are.
    static func composition(_ plan: VideoPlan, over asset: AVAsset, context: CIContext, fps: Int? = nil) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoExport.Problem.noVideo }
        let duration = try await asset.load(.duration)
        let nominal = try await track.load(.nominalFrameRate)
        let rate = fps ?? (nominal > 1 ? min(60, max(15, Int(nominal.rounded()))) : 30)
        let instruction = PlanInstruction(range: CMTimeRange(start: .zero, duration: duration), track: track.trackID, plan: plan, context: context)
        let configuration = AVVideoComposition.Configuration(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2, colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2, customVideoCompositorClass: PlanCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(rate)), instructions: [instruction], renderSize: plan.layout.canvas)
        return AVVideoComposition(configuration: configuration)
    }

    /// One Metal context for every frame of one editor or export, made without caching intermediates.
    static func context() -> CIContext { CIContext(options: [.cacheIntermediates: false, .name: "Pilot video"]) }
}

/// The composition's one instruction: the whole timeline, its one video track, drawn by `plan`.
final class PlanInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let track: CMPersistentTrackID
    let plan: VideoPlan
    let context: CIContext

    init(range: CMTimeRange, track: CMPersistentTrackID, plan: VideoPlan, context: CIContext) {
        timeRange = range
        self.track = track
        requiredSourceTrackIDs = [NSNumber(value: track)]
        self.plan = plan
        self.context = context
    }
}

/// Draws each frame through its instruction's plan with Core Image into a BGRA buffer of the canvas's size.
final class PlanCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
    private static let space = CGColorSpace(name: CGColorSpace.itur_709)

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? PlanInstruction,
              let source = request.sourceFrame(byTrackID: instruction.track),
              let out = request.renderContext.newPixelBuffer() else {
            return request.finish(with: VideoExport.Problem.notWritten("a frame was missing"))
        }
        let image = instruction.plan.frame(CIImage(cvPixelBuffer: source), at: request.compositionTime.seconds)
        let size = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out))
        instruction.context.render(image, to: out, bounds: size, colorSpace: Self.space)
        request.finish(withComposedVideoFrame: out)
    }
}

/// The export (P71): the recording's kept pieces (trim, cuts, each part's speed) in a composition, drawn by the plan, written as MP4 (H.264 or
/// HEVC, sound kept, its pitch kept at any speed) or as a GIF at 15 frames a second. Off the main thread; cancelled with
/// its task, when the half-written file is removed.
enum VideoExport {
    enum Problem: Error, LocalizedError {
        case noVideo, notWritten(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "The recording has no picture."
            case .notWritten(let why): "The export was not written: \(why)"
            }
        }
    }

    /// Writes `edit` of `asset` to `url` as `format` at `size`; `progress` hears 0 to 1 on any thread.
    static func run(_ asset: AVAsset, edit: VideoEdit, pointer: CursorTrack?, picture: CGImage?, format: VideoFormat, size: VideoSize,
                    to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            guard edit.length > 0 else { throw Problem.notWritten("every part is cut") }
            let (composition, source) = try await trimmed(asset, edit: edit)
            let full = VideoLayout(source: source, edit: edit).canvas
            // The theme's halo colours, read only when a ring will draw.
            let ring = edit.pointer.clickRing && pointer?.clicks.isEmpty == false ? await MainActor.run { CursorEffectColours.of(Look.shared.themeID) } : nil
            let plan = VideoPlan(edit: edit, pointer: pointer, source: source, size: size.pixels(full, format: format, shape: edit.shape), exported: true,
                                 picture: picture, fine: true, ring: ring)
            let context = VideoPlan.context()
            if format == .gif {
                try await gif(composition, plan: plan, context: context, length: edit.length, to: url, progress: progress)
            } else {
                try await movie(composition, plan: plan, context: context, hevc: format == .hevc, to: url, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// The edit's pieces of every track one after another from zero, each scaled to its speed as it is laid down (so no
    /// later scale moves an earlier piece); and the picture's size in pixels.
    static func trimmed(_ asset: AVAsset, edit: VideoEdit) async throws -> (AVComposition, CGSize) {
        let composition = AVMutableComposition()
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard let video = videos.first else { throw Problem.noVideo }
        let size = try await video.load(.naturalSize)
        var tracks: [(from: AVAssetTrack, kept: CMTimeRange, into: AVMutableCompositionTrack)] = []
        for track in videos.prefix(1) + (try await asset.loadTracks(withMediaType: .audio)) {
            guard let into = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            tracks.append((track, try await track.load(.timeRange), into))
        }
        var cursor = CMTime.zero
        for piece in edit.pieces {
            let range = CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 600), end: CMTime(seconds: piece.end, preferredTimescale: 600))
            for track in tracks {
                // A track shorter than the piece (sound that ends early) gives what it has, at its place in the piece.
                let part = range.intersection(track.kept)
                guard part.duration > .zero else { continue }
                try track.into.insertTimeRange(part, of: track.from, at: cursor + (part.start - range.start))
            }
            var laid = range.duration
            if piece.rate != 1 {
                laid = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / piece.rate)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: laid)
            }
            cursor = cursor + laid
        }
        return (composition, size)
    }

    private static func movie(_ composition: AVComposition, plan: VideoPlan, context: CIContext, hevc: Bool, to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { throw Problem.notWritten("no exporter for \(preset)") }
        session.videoComposition = try await VideoPlan.composition(plan, over: composition, context: context)
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true
        let watched = Unchecked(session)
        let watch = Task.detached {
            for await state in watched.value.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watch.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
    }

    /// Frames read through the plan at 15 a second, written as a looping GIF (a 13 s 720p GIF took 2.3 s on Sven's M4,
    /// 2026-10-20). Bigger and slower than an MP4 per second, since each frame gets its own colour table.
    private static func gif(_ composition: AVComposition, plan: VideoPlan, context: CIContext, length: Double, to url: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let fps = VideoFormat.gifFPS
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await composition.loadTracks(withMediaType: .video),
                                                         videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await VideoPlan.composition(plan, over: composition, context: context, fps: fps)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Problem.notWritten("the frames could not be read") }
        reader.add(output)
        let frames = max(1, Int((length * Double(fps)).rounded(.up)))
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw Problem.notWritten("the GIF could not be made")
        }
        CGImageDestinationSetProperties(file, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps), kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)]] as CFDictionary
        guard reader.startReading() else { throw Problem.notWritten(reader.error?.localizedDescription ?? "the frames could not be read") }
        var written = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let pixels = sample.imageBuffer,
                  let image = context.createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
            else { continue }
            CGImageDestinationAddImage(file, image, delay)
            written += 1
            progress(min(0.99, sample.presentationTimeStamp.seconds / max(length, 0.01)))
        }
        guard reader.status == .completed, written > 0 else { throw Problem.notWritten(reader.error?.localizedDescription ?? "no frames were read") }
        guard CGImageDestinationFinalize(file) else { throw Problem.notWritten("the GIF could not be finished") }
        progress(1)
    }

    /// Where an export of `recording` goes: beside it as "<name> edited.<ext>", " 2", " 3" when taken.
    static func destination(for recording: URL, format: VideoFormat) -> URL {
        let folder = recording.deletingLastPathComponent(), stem = recording.deletingPathExtension().lastPathComponent + " edited"
        var url = folder.appending(path: "\(stem).\(format.fileExtension)", directoryHint: .notDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(stem) \(n).\(format.fileExtension)", directoryHint: .notDirectory)
            n += 1
        }
        return url
    }
}
