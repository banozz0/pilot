import AVFoundation
import CoreImage
import ImageIO
import PilotCore
import UniformTypeIdentifiers

// The video editor's one way of drawing a frame (P71), shared by the preview and the export so what plays is what is
// written: Core Image in a small custom compositor (AVVideoComposition's Core Image handler is deprecated and cannot
// make the canvas bigger than the recording). The backdrop (fill and shadow) is drawn once per edit; each frame is then
// the camera's part of the cropped frame, scaled into the backdrop's spot and rounded there.

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
    /// The source frame's height, pixels: Core Image counts up from the bottom.
    private let sourceHeight: CGFloat
    private let fine: Bool

    /// `picture` is a picture fill's, made by `backdropPicture` (read and blurred once, never per frame); `fine` scales
    /// with high-quality downsampling (the export's), else plainly (the preview's). `size` draws the canvas exactly that
    /// big (an export's even size), else `out` times the full one.
    init(edit: VideoEdit, pointer: CursorTrack?, source: CGSize, out: CGFloat = 1, size: CGSize? = nil, exported: Bool, picture: CGImage?, fine: Bool) {
        self.edit = edit
        self.pointer = pointer?.path
        self.exported = exported
        self.fine = fine
        sourceHeight = source.height
        var layout = VideoLayout(source: source, crop: edit.crop, backdrop: edit.backdrop, out: out)
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
        let view = edit.camera(at: t, cursor: pointer)
        // The camera's part of the frame in source pixels, bottom-left.
        let part = CGRect(x: crop.minX + view.minX * crop.width, y: sourceHeight - (crop.minY + view.maxY * crop.height),
                          width: view.width * crop.width, height: view.height * crop.height)
        let move = CGAffineTransform(translationX: -part.minX, y: -part.minY)
            .concatenating(CGAffineTransform(scaleX: place.width / max(part.width, 1), y: place.height / max(part.height, 1)))
            .concatenating(CGAffineTransform(translationX: place.minX, y: place.minY))
        var video = image.clampedToExtent().cropped(to: part)
        video = fine ? video.transformed(by: move, highQualityDownsample: true) : video.transformed(by: move)
        video = video.cropped(to: place)
        let all = CGRect(origin: .zero, size: layout.canvas)
        guard let background else { return video.cropped(to: all) }
        if let mask {
            return video.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask]).cropped(to: all)
        }
        return background.composited(over: video).cropped(to: all)
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

/// The export (P71): the recording trimmed and sped up in a composition, drawn by the plan, written as MP4 (H.264 or
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
            let (composition, source) = try await trimmed(asset, edit: edit)
            let full = VideoLayout(source: source, edit: edit).canvas
            let plan = VideoPlan(edit: edit, pointer: pointer, source: source, size: size.pixels(full, format: format), exported: true,
                                 picture: picture, fine: true)
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

    /// The kept part of every track, from zero, scaled to the speed; and the picture's size in pixels.
    static func trimmed(_ asset: AVAsset, edit: VideoEdit) async throws -> (AVComposition, CGSize) {
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: edit.trimIn, preferredTimescale: 600), end: CMTime(seconds: edit.trimOut, preferredTimescale: 600))
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard let video = videos.first else { throw Problem.noVideo }
        let size = try await video.load(.naturalSize)
        for track in videos.prefix(1) + (try await asset.loadTracks(withMediaType: .audio)) {
            guard let into = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try into.insertTimeRange(range, of: track, at: .zero)
        }
        if edit.speed != 1 {
            let kept = CMTimeRange(start: .zero, duration: range.duration)
            composition.scaleTimeRange(kept, toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / edit.speed))
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
